import Foundation
import Logging

/// 安全性の前提: `buffer` `continuation` `isStopped` に触れるのは `queue` の中だけ。
/// actor では代われない。`readabilityHandler` が同期コールバックのため。
final class StdioLineReaderContext: @unchecked Sendable {
    /// 1 行の上限。改行を出さないまま書き続ける相手がいると、ここが無ければ
    /// ブリッジのメモリを際限なく食う。ブリッジは全サンドボックスで共有している。
    static let defaultMaxLineBytes = 16 * 1_048_576

    let queue: DispatchQueue
    private let maxLineBytes: Int
    private var buffer = Data()
    private let handle: FileHandle
    private let logger: Logger?
    private var continuation: AsyncStream<Data>.Continuation?
    private var isStopped = false
    /// 長すぎる行を捨てている間は true。次の改行まで読み飛ばす。
    private var skipping = false

    init(handle: FileHandle, label: String, logger: Logger? = nil,
         maxLineBytes: Int = StdioLineReaderContext.defaultMaxLineBytes) {
        self.handle = handle
        self.logger = logger
        self.maxLineBytes = maxLineBytes
        self.queue = DispatchQueue(label: label)
    }

    func lines() -> AsyncStream<Data> {
        AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            self.queue.async { [self] in
                guard !self.isStopped else {
                    self.handle.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                self.continuation = continuation
                self.handle.readabilityHandler = { [weak self] fileHandle in
                    guard let self else {
                        fileHandle.readabilityHandler = nil
                        continuation.finish()
                        return
                    }
                    self.queue.async {
                        let chunk = fileHandle.availableData
                        guard !chunk.isEmpty else {
                            fileHandle.readabilityHandler = nil
                            self.continuation = nil
                            continuation.finish()
                            return
                        }
                        self.buffer.append(chunk)

                        while let newlineIndex = self.buffer.firstIndex(of: UInt8(ascii: "\n")) {
                            let lineData = Data(self.buffer[self.buffer.startIndex..<newlineIndex])
                            self.buffer = Data(self.buffer[(newlineIndex + 1)...])
                            if self.skipping {
                                self.skipping = false
                            } else if !lineData.isEmpty {
                                continuation.yield(lineData)
                            }
                        }

                        if self.buffer.count > self.maxLineBytes {
                            if !self.skipping {
                                self.logger?.warning(
                                    "1 行が \(self.maxLineBytes) バイトを超えたので捨てます")
                            }
                            self.skipping = true
                            self.buffer.removeAll(keepingCapacity: false)
                        }
                    }
                }
            }

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.handle.readabilityHandler = nil }
            }
        }
    }

    /// EOF はハンドラの中でしか観測できない。終わらせずに外すと読み手が取り残される。
    func stop() {
        queue.async {
            self.isStopped = true
            self.handle.readabilityHandler = nil
            self.continuation?.finish()
            self.continuation = nil
        }
    }
}

/// ハンドルの持ち主は 1 つずつ。stdin は `writeQueue`、stdout は
/// `stdoutReader`、stderr は `stderrQueue`。
final class MCPBridgeProcess: Sendable {
    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let logger: Logger
    private let stdoutReader: StdioLineReaderContext
    private let writeQueue = DispatchQueue(label: "mcpbridge.stdin")
    private let stderrQueue = DispatchQueue(label: "mcpbridge.stderr")

    init(xcrunPath: String, developerDir: String?, logger: Logger) {
        self.logger = logger
        self.stdinPipe = Pipe()
        self.stdoutPipe = Pipe()
        self.stderrPipe = Pipe()

        self.stdoutReader = StdioLineReaderContext(
            handle: stdoutPipe.fileHandleForReading,
            label: "mcpbridge.stdout",
            logger: logger
        )

        process = Process()
        process.executableURL = URL(fileURLWithPath: xcrunPath)
        process.arguments = ["mcpbridge"]

        if let developerDir {
            var env = ProcessInfo.processInfo.environment
            env["DEVELOPER_DIR"] = developerDir
            process.environment = env
        }

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    func start() throws {
        try process.run()
        logger.info("mcpbridge started (pid: \(process.processIdentifier))")
        startReadingStderr()
    }

    func messages() -> AsyncStream<Data> {
        stdoutReader.lines()
    }

    func send(_ data: Data) {
        guard process.isRunning else {
            logger.warning("Dropped message: mcpbridge is not running")
            return
        }
        let message = data.last == UInt8(ascii: "\n") ? data : data + [UInt8(ascii: "\n")]
        writeQueue.async { [stdinPipe, logger] in
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: message)
            } catch {
                logger.warning("Dropped message: mcpbridge stdin closed (\(error.localizedDescription))")
            }
        }
    }

    func terminate() {
        stdoutReader.stop()
        stderrQueue.async { [stderrPipe] in
            stderrPipe.fileHandleForReading.readabilityHandler = nil
        }
        if process.isRunning {
            process.terminate()
            logger.info("mcpbridge terminated (pid: \(process.processIdentifier))")
        }
    }


    private func startReadingStderr() {
        stderrQueue.async { [stderrPipe, logger] in
            stderrPipe.fileHandleForReading.readabilityHandler = { fileHandle in
                let chunk = fileHandle.availableData
                guard !chunk.isEmpty else {
                    fileHandle.readabilityHandler = nil
                    return
                }
                if let text = String(data: chunk, encoding: .utf8) {
                    logger.warning("mcpbridge stderr: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
        }
    }
}
