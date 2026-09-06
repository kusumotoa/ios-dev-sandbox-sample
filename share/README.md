# チーム標準の設定

ここに置いたものは **git に入り、PR レビューを通り、全員に配られます**。個人のマシン
固有のものは隣の `local/`（gitignore）に置いてください。

| ファイル | 何を書くか | 手順 |
|---|---|---|
| `host-cli.json` | サンドボックスから呼べるホストの CLI | [手順](../docs/instructions/host-cli.md) |
| `host-mcp.json` | ホストで動かす MCP サーバー | [手順](../docs/instructions/mcp-servers.md) |
| `AGENTS.md` | サンドボックスの中のエージェントへの説明 | — |
| `mcp-agents.txt` | MCP として使えるようにするエージェント（1 行 1 つ） | [手順](../docs/instructions/agents/mcp-agents.md) |
| `skills/` | チーム標準のスキル | 下記 |

`claude/` の中は **Claude Code のときだけ読まれます**（codex と copilot では無視されます）。

| ファイル | 何を書くか | 手順 |
|---|---|---|
| `claude/settings.json` | Claude Code の設定（保持期間・ステータスライン） | — |
| `claude/statusline.sh` | ステータスラインの実体 | — |
| `claude/plugins.txt` | 入れるプラグインの一覧（1 行 1 つ） | 下記 |

反映するには各自が `git pull && mise run setup` と `ios-dev-sandbox apply` を実行します。
手元の clone を直接書き換えると自分のマシンでは効きますが、他のメンバーには配られません。

## プラグイン

**Claude Code だけの機能です。** codex と copilot では読まれません。

`plugins.txt` に `<plugin>@<marketplace>` を 1 行ずつ書きます。

```
feature-dev@claude-plugins-official
```

サンドボックス作成時に `claude plugin install` が走ります。**実体はリポジトリに置きません。**

各自が足したいものは、コンテナの中で `/plugin install` します。チーム標準と同じく、
サンドボックスを作り直しても残ります。

## スキル

`skills/<name>/SKILL.md` を置きます。個人のスキル（`local/skills/`）と同名の場合は
**個人が優先**され、こちらは影になります。

`.claude-plugin/plugin.json` を含むディレクトリを置くと、スキルではなく
**プラグインとして読まれます**。この置き方をしたものは marketplace を経由しないため、
**あとから自動で更新されません**。更新を追いたいものは、ここではなく `plugins.txt` に
`<plugin>@<marketplace>` の形で書いてください。

