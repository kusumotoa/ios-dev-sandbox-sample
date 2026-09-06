# host-bridge

`ios-dev-sandbox` がホスト側で動かす唯一の実行ファイル。1 ポート（127.0.0.1:19721）で 2 つの橋を提供する。

```bash
swift build -c release
swift test
```

運用・設定の話はルートの [README.md](../README.md)、なぜそうなっているかは
[decisions.md](decisions.md) にある。ここにはバイナリ自身のインターフェースだけを書く。

コマンドラインオプションは列挙しない（`--help` が唯一の情報源）。

```bash
host-bridge --help
host-bridge auth <サーバー名>   # auth: oauth の MCP をブラウザで認可
```

## /exec（ホスト CLI の実行）

allowlist（`share/host-cli.json` + `local/host-cli.json` の 2 層）に載った macOS CLI を、サンドボックスからの HTTP リクエストで実行する。ローカル側ができるのはチーム標準コマンドの `paths`（バイナリの差し替え）と `extra`（追加コマンド）だけで、チーム標準と同名の `extra` は無視され、`allowedSubcommands` は緩められない。

```
POST /exec           {"command":"mytool","args":["ui"],"cwd":"/abs/path","stdin":null}
                  →  {"exitCode":0,"stdout":"...","stderr":"...","bridgeError":null}
```

実行パスは常に allowlist から取る。リクエストが指定できるのは `name` だけなので、サンドボックスから任意のバイナリを起動することはできない。

`allowedSubcommands` は 2 形式ある。

- フラット配列
- 第 1 階層語 → 許可する第 2 階層語のオブジェクト

判定は引数の先頭位置のみで、先頭フラグは読み飛ばさず拒否する。

`bridgeError` はブリッジ自身が拒否・中断したときだけ入る。コマンドが非ゼロで終了しただけなら `exitCode` に出て `bridgeError` は `null`。allowlist 外は 403、allowlist にあるが未導入は 503 で区別する。

## /mcp/&lt;名前&gt;（ホストの MCP サーバー）

`share/host-mcp.json` + `local/host-mcp.json`（同じ 2 層規則）に宣言したサーバーを streamable HTTP で中継する。バックエンドは 3 種:

- `url`：localhost・リモートの streamable HTTP へ中継。`auth: oauth` なら保存済みトークンを注入し、期限切れはリフレッシュする
- `command`：ホストで stdio MCP を子プロセスとして 1 つ起動して中継。応答は id で引く待機表で捌くので、並行リクエストが混ざらない
- `kind: xcode`：mcpbridge を MCPBridgeSupervisor（xcode-select 追従・再起動またぎの握手再生）ごと抱える

`tools:` の列挙は tools/list の絞り込みと tools/call の拒否の両方に効く。JSON-RPC のバッチ（配列）は解釈せず 400 で拒否する（2025-06-18 の MCP で廃止済み。通すと中の tools/call を検査できない）。

## /health

```
GET  /health         {"status":"ok","commands":[...],"servers":[...]}
```

`commands` は allowlist にあり、かつホストに実際に入っている CLI だけ（リクエストごとのライブ判定）。`servers` は宣言済み MCP サーバー名。無視されたローカル上書きがあると `warnings` が付く。

kit はこれを見て、作成時に中継コマンドと agent の MCP 設定を生成する。書き先は agent ごとに違う。

| agent | 書き先 |
|---|---|
| claude | `.claude.json` |
| codex | `config.toml` |
| copilot | `mcp-config.json` |

独自の認証は持たない。待ち受けは 127.0.0.1 だけで LAN からは届かず、サンドボックスからの到達は sbx のネットワークポリシー（既定 deny。`kits/host-mcp` が `localhost:19721` を宣言したサンドボックスだけが通る）が決める。ホスト上の同一ユーザーのプロセスは元から任意のコマンドを実行できるので、ここで認証しても守れるものが増えない。

`Origin` ヘッダ付きのリクエストは、全エンドポイントで DNS リバインディング対策として拒否する。
