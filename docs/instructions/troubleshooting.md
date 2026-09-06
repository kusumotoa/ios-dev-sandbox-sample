# うまくいかないとき

まず `ios-dev-sandbox status` を見てください。

## 起動できない

| 症状 | 原因と対処 |
|---|---|
| エージェントが使えるツールに `BuildProject` などの Xcode のものが 1 つも無い | サンドボックスを作った瞬間に Xcode へ繋がらず、Xcode 抜きで作られています。Xcode で対象プロジェクトを開いてから `ios-dev-sandbox apply` で作り直します |
| `... に .xcodeproj / .xcworkspace がありません` | iOS プロジェクトのディレクトリで実行してください。トップレベルに `.xcodeproj` / `.xcworkspace` が要ります |

## 認証

| 症状 | 原因と対処 |
|---|---|
| サンドボックス内で `Not logged in` | ホストで `ios-dev-sandbox login`、またはサンドボックス内で `/login` |
| `gh` が `Bad credentials` | [GitHub 認証](github-auth.md)をやり直します（`ios-dev-sandbox github-login`） |

## Xcode のツールが期待どおりに出ない

| 症状 | 原因と対処 |
|---|---|
| Xcode 27 にあるツールが出てこない（`RunProject` など） | Xcode 26.x を使っています。26.x に無いツールはエージェントの一覧に出ません。アプリの起動とスキーム切り替えは Xcode 側で行ってください |
| ツールが 1 件（`DocumentationSearch`）しか出ない | Xcode 側がワークスペースを持っていません。`xcrun mcp-server status --format json` で対象プロジェクトが `openWorkspaces` にあるか確認します |
| `Unknown workspace identifier` | 絶対パスは受け付けません。`XcodeListWorkspaces` が返す `workspace-XXXXXXXX` を使います |

## ホスト CLI

| 症状 | 原因と対処 |
|---|---|
| `command not found` | allowlist に載っていません。[ホスト専用 CLI を増やす](host-cli.md)を見て追加し、サンドボックスを作り直します |
| `host-cli: ... is not allowed` | ブリッジが拒否しています。チーム標準（`share/host-cli.json`）の `allowedSubcommands` を確認してください。ローカル側からは緩められません |
| ローカルの `extra` が効かない | チーム標準と同名だと無視されます（起動ログに警告）。別名にするか、チーム標準への PR を出します |
| ブリッジのログを見たい | `~/.local/state/ios-dev-sandbox/host-bridge.log` |

## 設定を変えたのに反映されない

追加した機能・環境変数・見せるディレクトリは、サンドボックスを**作ったときの内容で固定**されます。あとから設定ファイルを変えても、作り直すまで反映されません。プロジェクトのディレクトリで `ios-dev-sandbox apply` を実行してください（会話履歴は残ります）。

起動時に `warning: kits が ... の作成後に変わっています` と出ていたら、これが原因です（`kits` はこのリポジトリの `kits/` ディレクトリ。[用語](where-to-write.md#用語)）。`status` の `sandbox config` 行でも確認できます。

作り直さずに効くのは次の 3 つだけです。

- `share/skills` / `local/skills` の中身の編集
- `host-cli.json` / `host-mcp.json` の既存エントリの変更（`ios-dev-sandbox restart-bridge` が要ります）
- トークンの差し替え

## ネットワーク

| 症状 | 原因と対処 |
|---|---|
| 特定のドメインに繋がらない | 外向きはデフォルト拒否です。`sbx policy ls` で実効ルールを見て、必要なら[許可先を増やします](network-policy.md)。UDP・ICMP・SSH は開けられません |
