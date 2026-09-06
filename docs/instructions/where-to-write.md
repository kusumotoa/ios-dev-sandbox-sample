# どのファイルに何を書くか

設定は 2 つに分かれます。**自分のマシンだけで効くもの**と、**チーム全員に配られるもの**です。

## 自分のマシンだけ

clone したディレクトリの直下の `local/` に置きます。gitignore されているので、git の差分になりません。

| 何を | どのファイル | 手順 |
|---|---|---|
| このマシンだけで使うホスト CLI | `local/host-cli.json` | [手順](host-cli.md) |
| このマシンだけの MCP サーバー | `local/host-mcp.json` | [手順](mcp-servers.md) |
| LiteLLM ゲートウェイ経由で使う（任意） | `local/gateway.json` | [手順](litellm.md) |
| 追加で読ませるディレクトリ | `local/read-only-dirs.txt`（全プロジェクト共通） | [手順](read-only-dirs.md) |
| MCP として使えるようにするエージェント | `local/mcp-agents.txt` | [手順](agents/mcp-agents.md) |
| 個人のスキル | `local/skills/` | [README](../../local/README.md#スキル) |
| そのプロジェクト限定のスキル | iOS プロジェクト直下の `.claude/skills/` | — |

トークン類はリポジトリの外（`~/.config/ios-dev-sandbox/secrets/`）に分けてあります。正確なパスは `ios-dev-sandbox status` が出します。

エージェントが残した成果物は `~/.config/ios-dev-sandbox/projects/<プロジェクト名>/artifacts` に溜まります。ホストと同じ絶対パスでマウントされるので、両側から同じパスで開けます。

## チーム全員

**このリポジトリへの PR** で変えます。手元の clone を直接書き換えると自分のマシンでは効きますが、他のメンバーには配られません。

マージ後、各自が次を実行して取り込みます。

```bash
git pull && mise run setup
ios-dev-sandbox apply
```

| 何を | どこ | 手順 |
|---|---|---|
| 使える Xcode MCP ツール | `share/host-mcp.json` の `xcode.tools` | [手順](mcp-servers.md) |
| チーム標準のホスト CLI | `share/host-cli.json` | [手順](host-cli.md) |
| サンドボックスへ提供する MCP サーバー | `share/host-mcp.json` | [手順](mcp-servers.md) |
| 外向きの通信先 | `kits/network-policy/spec.yaml` | [手順](network-policy.md) |
| チーム標準のスキル | `share/skills/` | [README](../../share/README.md#スキル) |
| 入れるプラグイン | `share/claude/plugins.txt`（`<plugin>@<marketplace>` を 1 行ずつ） | [README](../../share/README.md#プラグイン) |
| MCP として使えるようにするエージェント | `share/mcp-agents.txt` | [手順](agents/mcp-agents.md) |
| ステータスライン | `share/claude/statusline.sh` | — |
| エージェントへの説明 | `share/AGENTS.md` | — |

ここに並ぶファイルはサンドボックスの境界そのものです。レビューなしに変わらないよう、[ブランチ保護](recommended/branch-protection.md)を掛けておくことを勧めます。

## 用語

| | |
|---|---|
| kit | `kits/<名前>/spec.yaml` に書いた「サンドボックスに何を入れるか」の宣言。sbx がサンドボックスの作成時に 1 つずつ実行します。エラーや `status` に出てくる `kits` はこのディレクトリのことです |
| sbx | [Docker Sandboxes](https://www.docker.com/ja-jp/products/docker-sandboxes/)。VM 本体を作り、ファイルシステム・ネットワークの隔離を担います |
| ブリッジ（host-bridge） | ホスト側で動く中継プロセス。サンドボックスからの Xcode MCP とホスト CLI の呼び出しを受けます |
