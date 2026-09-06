# エージェントを選ぶ

`IOS_DEV_SANDBOX_AGENT` を付けると、同じ iOS プロジェクトに別のエージェントのサンドボックスが立ちます。Xcode の呼び出しやチーム標準の設定は、どのエージェントでも同じように使えます。

```bash
cd ~/projects/my-ios-app
ios-dev-sandbox                                  # claude  → my-ios-app
IOS_DEV_SANDBOX_AGENT=codex ios-dev-sandbox      # codex   → my-ios-app-codex
IOS_DEV_SANDBOX_AGENT=copilot ios-dev-sandbox    # copilot → my-ios-app-copilot
```

サンドボックス・設定・会話履歴はエージェントごとに分かれるので、並行して使えます（履歴の形式が違うため、相互には読めません）。

## 認証

エージェントごとに別々の認証が要ります。

| agent | 認証 |
|---|---|
| claude | `ios-dev-sandbox login`（ホストで 1 回） |
| codex | `sbx secret set openai --oauth`、またはコンテナ内で `codex login` |
| copilot | 書き込み用 PAT に `Copilot Requests` を足します。[手順](agents/copilot.md) |

`gh` 用に登録した PAT をそのまま copilot に渡しても通りません。理由と手順は [Copilot CLI を使う](agents/copilot.md)。

## copilot は組織のポリシーに阻まれることがある

`https://github.com/settings/copilot/features` の **MCP servers in Copilot** が `Disabled` だと、`xcode` を含む全 MCP が読み飛ばされます。Copilot CLI 自体にも別のポリシーがあり、**両方の有効化が要ります**。

どちらも組織の管理者設定なので、トークンやリポジトリの選び方では変わりません。詳しくは [Copilot CLI を使う](agents/copilot.md)。

## 関連する手順

| | |
|---|---|
| [Copilot CLI を使う](agents/copilot.md) | copilot の認証と、組織のポリシーの確認 |
| [別のエージェントを MCP として使う](agents/mcp-agents.md) | 作業中のエージェントから別のエージェントを呼ぶ |
