# Copilot CLI を使う

`IOS_DEV_SANDBOX_AGENT=copilot` で起動します。**`Copilot Requests` を持つトークンが要ります。** `gh` 用の PAT をそのまま渡しても通りません。

## 1. 書き込み用 PAT に `Copilot Requests` を足す

[GitHub 認証](../github-auth.md)で作った**書き込み用 PAT**を開き、権限を 1 つ足します。

https://github.com/settings/personal-access-tokens

| | 何を選ぶか |
|---|---|
| Permissions | **Account タブ** → Add permissions → **Copilot Requests** |

これで PAT は 2 本（書き込み用・読み取り専用）のままです。増えるのは Copilot の利用権だけで、リポジトリに触れる範囲は変わりません。

なお公式ドキュメントに read/write の別は書かれていません。選択肢が両方出るなら Read-only から試してください。

### 書き込み用 PAT が組織所有なら、別に 1 本作る

`Copilot Requests` は **Resource owner が自分の個人アカウントの fine-grained PAT にしか出ません**（GitHub の仕様で、Account permissions はトークン所有者が resource owner のときだけ選べます）。書き込み用 PAT の resource owner に組織を選んでいる場合はこの権限を足せないので、copilot 用にもう 1 本作ります。

https://github.com/settings/personal-access-tokens/new

| | 何を選ぶか |
|---|---|
| Resource owner | **自分の個人アカウント** |
| Repository access | Public repositories で十分 |
| Permissions | **Account タブ** → Add permissions → **Copilot Requests** |

このときは**リポジトリの権限を付けないでください。** copilot に要るのは自分が誰かを名乗ることと Copilot の利用権だけです。

## 2. 登録する

```bash
pbpaste | ios-dev-sandbox copilot-login     # トークンをコピーした状態で
```

書き込み用 PAT に `Copilot Requests` を足した場合は、**その同じ値**を貼ります。sbx の secret store とは別の置き場なので、PAT は 1 本でも登録は 2 箇所になります。

クリップボード経由ならシェル履歴に残りません。端末から直に貼るなら引数なしで実行します。`~/.config/ios-dev-sandbox/secrets/copilot-token` に 0600 で置かれ、リポジトリには入りません。

## 3. 起動する

```bash
IOS_DEV_SANDBOX_AGENT=copilot ios-dev-sandbox
```

トークンが無いまま起動しようとすると、その場で止まって手順を案内します。`ios-dev-sandbox status`（`IOS_DEV_SANDBOX_AGENT=copilot` を付ける）の検査にも出ます。

## 組織のポリシーで止まることがある

https://github.com/settings/copilot/features の **MCP servers in Copilot** が `Disabled` だと、登録した MCP を全部読み飛ばします。`xcode` を含む全サーバーが使えず、ビルドもシミュレータ操作もできません。

```
[ERROR] Skipping third-party MCP server "xcode" because the MCP third-party policy is not enabled
Error: Access denied by policy settings
```

Copilot CLI 自体にも別のポリシーがあり、MCP を全部外しても `Access denied` になります。**両方の有効化が要ります。** どちらも組織の管理者設定で、トークンやリポジトリの選び方では変わりません（org のリポジトリ・空ディレクトリ・git 管理外の個人プロジェクトの 3 条件で同じ結果を確認しています）。

## 他の agent との違い

| agent | 認証 | 置き場 |
|---|---|---|
| claude | `ios-dev-sandbox login` | `secrets/claude-oauth-token` |
| codex | `sbx secret set openai --oauth`、またはコンテナ内で `codex login` | sbx の secret store |
| copilot | `ios-dev-sandbox copilot-login` | `secrets/copilot-token` |

copilot だけ `GH_TOKEN` を拾います。PAT を 1 本だけ登録した構成では `GH_TOKEN` が入っていて、`Copilot Requests` の付いていないトークンを先に掴んでしまいます。`COPILOT_GITHUB_TOKEN` の方が優先順位が上なので、そちらに載せて上書きしています。

会話履歴・設定・MCP の登録はすべて `<proj>/copilot/state/home` に入り、作り直しても残ります。
