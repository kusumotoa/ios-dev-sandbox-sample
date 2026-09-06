# LiteLLM ゲートウェイ経由で使う（任意）

エージェントの宛先を LiteLLM ゲートウェイへ向けます。**使わないなら何も設定は要りません。** `local/gateway.json` の `host` が空か、鍵を登録していなければ、この機能はサンドボックスに入りません。Anthropic に直接つなぐ人や、ゲートウェイを持たない会社の人は、何も設定せずそのまま使えます。

agent によって効く範囲が違います。

| agent | 推論の宛先 | Brave Search MCP |
|---|---|---|
| claude | `~/.claude/settings.json` の `ANTHROPIC_BASE_URL` を書き換える | 登録する |
| codex | `~/.codex/config.toml` の provider を書き換える | 登録する |
| copilot | **変えない**（kit が対応していない） | 登録する |

copilot で推論の宛先を変える経路は用意していません。Copilot CLI は GitHub の Copilot サービスに繋ぐ前提のツールで、任意のエンドポイントへ向けられるかを確かめていないためです。ゲートウェイが提供する Brave Search MCP は copilot でも使えます。

**リポジトリのファイルを自分で書き換える必要はありません。** ゲートウェイのホスト名は `local/gateway.json` に書いた値が、起動時に自動で埋め込まれます。社内のホスト名が git に入らないようにするためです。

## 手順

1. 宛先を書きます。`ios-dev-sandbox init` が雛形を置くので、それを埋めます（clone した中の `local/gateway.json`）。gitignore されているので git の差分にはなりません。

| 鍵 | 何を書くか | 省略したら |
|---|---|---|
| `host` | ゲートウェイの API ホスト名。`https://` は付けない（例: `api.llm-gateway.example.com`）。claude では `ANTHROPIC_BASE_URL`、codex では provider の `base_url` になる | **kit は何もしない**（既定は空） |
| `braveSearchPath` | ゲートウェイが MCP を提供している場合のパス（例: `/brave_search/mcp`）。**ゲートウェイ固有**なので、提供していなければ空のまま | MCP を登録しない |
| `codexModel` | Codex に渡すモデル名。ゲートウェイが公開している名前（例: `gpt-5-mini`）。`local/mcp-agents.txt` に codex を書かないなら空でよい | `model` を書かず Codex の既定名で要求する（ゲートウェイ側にその名前が無いと失敗する） |

どの値も**ゲートウェイの運用者に確認するもの**です。LiteLLM 標準で決まっている名前ではありません。

2. ゲートウェイの管理画面で API キーを発行します（社内の場合は `https://key.<ゲートウェイのドメイン>/`。発行し直しの周期は運用に依ります）。

3. 鍵を登録します。

```bash
ios-dev-sandbox litellm-login
```

4. サンドボックスに反映します。

```bash
ios-dev-sandbox apply
```

作成の途中で sbx が鍵の使用を訊いてくるので、`A`（Approve all）を選びます。

```
This kit wants to use these credentials:
  litellm-api-key API key → sent to <ゲートウェイのホスト名>   (stored)
[A]pprove all · [R]eview each · [N]o:
```

`N` にすると鍵が注入されず、ゲートウェイは 401 を返します。宛先に自分のホスト名が出ていなければ `local/gateway.json` の `host` を確認してください。

## Codex のモデル名

`local/mcp-agents.txt` に `codex` と書いて使う場合、モデル名は上から順に決まります（[手順](agents/mcp-agents.md)）。

1. `local/gateway.json` の `codexModel`
2. 実行時の `--model`
3. どちらも無ければ Codex の既定名

3 になるとゲートウェイがその名前を知らずに失敗するので、**ゲートウェイ経由なら `codexModel` を書くのが確実です**。

## 知っておくこと

- **鍵はサンドボックスに入りません。** コンテナ内に見える値（claude なら `ANTHROPIC_AUTH_TOKEN`）は `proxy-managed` というダミーで、実際の鍵はプロキシが `<ゲートウェイのホスト>` への通信に差し込みます
- モデル名は固定していません。claude なら `~/.claude/settings.json` の `ANTHROPIC_MODEL`（1M context は `claude-sonnet[1m]` のように `[1m]` を付けます）、codex なら `local/gateway.json` の `codexModel` で指定します
- 鍵を登録していないマシンでは kit は何もしません。チーム内で経由する人と直接使う人が混在できます
- 鍵を発行し直したら `ios-dev-sandbox litellm-login` で上書きします。動いているサンドボックスにも即座に効きます（secret は作成時固定ではありません）

