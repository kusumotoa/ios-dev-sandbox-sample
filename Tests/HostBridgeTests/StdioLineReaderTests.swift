import Foundation
import Testing
@testable import HostBridge

@Suite("stdio の行読み")
struct StdioLineReaderTests {
    @Test(.timeLimit(.minutes(1))) func splitsMessagesOnNewlines() async throws {
        let pipe = Pipe()
        let reader = StdioLineReaderContext(handle: pipe.fileHandleForReading, label: "test.split")
        let stream = reader.lines()

        try pipe.fileHandleForWriting.write(contentsOf: Data("one\ntw".utf8))
        try pipe.fileHandleForWriting.write(contentsOf: Data("o\n".utf8))
        try pipe.fileHandleForWriting.close()

        var lines: [String] = []
        for await line in stream {
            lines.append(String(decoding: line, as: UTF8.self))
        }

        #expect(lines == ["one", "two"])
        reader.stop()
    }

    // stop() で明示的に終わらせないと、失敗ではなく永久に止まる。
    @Test(.timeLimit(.minutes(1))) func stopEndsTheStreamWithoutFurtherInput() async {
        let pipe = Pipe()
        let reader = StdioLineReaderContext(handle: pipe.fileHandleForReading, label: "test.stop")
        let stream = reader.lines()

        reader.stop()

        for await _ in stream {}
    }

    // 改行を出さないまま書き続ける相手がいると、上限が無ければブリッジのメモリを
    // 際限なく食う。長すぎる行は捨てて、その後の行はそのまま読めること。
    @Test(.timeLimit(.minutes(1))) func 長すぎる行は捨てて次から読み直す() async throws {
        let pipe = Pipe()
        let limit = 64 * 1024
        let reader = StdioLineReaderContext(handle: pipe.fileHandleForReading, label: "test.huge",
                                            maxLineBytes: limit)
        let stream = reader.lines()

        let writer = pipe.fileHandleForWriting
        Task.detached {
            try? writer.write(contentsOf: Data("first\n".utf8))
            // 上限を超えるまで改行なしで流す。
            try? writer.write(contentsOf: Data(repeating: UInt8(ascii: "x"), count: limit * 3))
            try? writer.write(contentsOf: Data("\nlast\n".utf8))
            try? writer.close()
        }

        var lines: [String] = []
        for await line in stream {
            lines.append(String(decoding: line, as: UTF8.self))
        }
        reader.stop()

        #expect(lines.first == "first")
        #expect(lines.last == "last")
        // 捨てた行が混ざっていないこと。
        #expect(lines.allSatisfy { $0.count < 1000 })
        #expect(lines == ["first", "last"])
    }
}
