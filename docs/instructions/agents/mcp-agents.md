# 別のエージェントを MCP として使う

`local/mcp-agents.txt` に書いたエージェントが、作業中のエージェントから MCP として使えるようになります。

```
codex
```

チーム全員に配るなら `share/mcp-agents.txt` に書きます。

反映は `ios-dev-sandbox apply` です。ここに書いたエージェントはサンドボックスの
**中に入れる**もので、それを行う kit は作成時にしか走りません。`restart-bridge` は
ホスト側のブリッジを入れ替えるだけなので、コンテナの中身は変わりません。

使えるのは `codex` と `claude` です。`copilot` は MCP サーバーになれないので使えません。自分自身（claude で動いているときの `claude`）は無視されます。

## 認証が別に要ります

**ここが抜けると、登録はされるのに呼んだ時点で失敗します。** 何を登録するかは、
ゲートウェイ経由かどうかで変わります。

| | 直接使う | ゲートウェイ経由 |
|---|---|---|
| `codex` | `sbx secret set openai --oauth` | `ios-dev-sandbox litellm-login` |
| `claude` | `ios-dev-sandbox login` | `ios-dev-sandbox litellm-login` |

ゲートウェイ経由なら宛先が OpenAI や Anthropic ではなくゲートウェイになるので、
そちらの鍵だけで足ります。宛先は kit が設定します。`codex` のモデル名だけは
`local/gateway.json` の `codexModel` で決めます（[手順](../litellm.md)）。

## 呼び方

エージェントに頼めば呼ばれます。

```
この方針について codex の意見も聞いて
```

シェルから直に叩くこともできます。

```bash
codex exec --skip-git-repo-check "<指示>" < /dev/null
```
