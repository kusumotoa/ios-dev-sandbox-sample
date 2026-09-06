# マシン固有の設定

`share/` がチーム全員に配られるのに対し、ここは**このマシンだけ**の設定を置きます。

**README 以外は git の管理下ではありません。**

| ファイル | 何を書くか | 手順 |
|---|---|---|
| `host-cli.json` | このマシンだけのホスト CLI | [手順](../docs/instructions/host-cli.md) |
| `host-mcp.json` | このマシンだけの MCP サーバー | [手順](../docs/instructions/mcp-servers.md) |
| `gateway.json` | LiteLLM ゲートウェイの宛先 | [手順](../docs/instructions/litellm.md) |
| `mcp-agents.txt` | MCP として使えるようにするエージェント（1 行 1 つ） | [手順](../docs/instructions/agents/mcp-agents.md) |
| `read-only-dirs.txt` | 追加で読ませるディレクトリの絶対パス（1 行 1 つ、全プロジェクト共通） | [手順](../docs/instructions/read-only-dirs.md) |

チーム標準と同名のものは上書きできません。追加だけができます。

## トークン類はここに置きません

`~/.config/ios-dev-sandbox/secrets/`（リポジトリの外）にあります。

## スキル

`skills/` に置いたものが、サンドボックス内のエージェントのスキル置き場に現れます。
ホストの `~/.claude/skills` は**持ち込まれません**。

ホストのスキルを全部使いたいなら、symlink を 1 本張ってください。

```bash
ln -s ~/.claude/skills local/skills
```

選びたい場合は、`local/skills/` を作って中に実体を置きます。**中に symlink を張っても
届きません。**
