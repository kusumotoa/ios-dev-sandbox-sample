# 設計上の制約

触るときに知らないと壊すものだけを書く。経緯や撤回された判断は git log にある。

## ブリッジ

**SIGPIPE はプロセス全体で無視する。** NSFileHandle の非 throwing `write(_:)` はキャッチ
できない ObjC 例外を投げるので使わない。クライアントが先に閉じるとブリッジごと落ちる。

**ポート 19721 は変更できない。** kit が URL とネットワーク許可の両方に焼き込んでいる。

**待ち受けは 127.0.0.1 で、ブリッジ自身は認証を持たない。** サンドボックスからは
`host.docker.internal` 宛でもループバックに届くので `0.0.0.0` は要らない（開けると
同じ LAN の別マシンから `/health` で allowlist が読める）。誰が繋げるかは sbx の
ネットワークポリシーが決める。既定は deny で、`kits/host-mcp` が `localhost:19721` を
宣言したサンドボックスだけが通る。ホスト上の同一ユーザーのプロセスは元から任意の
コマンドを実行できるため、ここに認証を足しても守れるものが増えない。

**`DEVELOPER_DIR` はリクエストごとに `xcode-select` を読み直す。** 起動時に固定すると、
ホストで Xcode を切り替えたときにブリッジの再起動が要る。

## 境界

**設定はマウントされる workspace の外に置く。** 中に置くと、エージェントが自分のマウントや
kit を書き換えられる。

**ネットワーク許可は kit に scope する。** サンドボックス全体に開けると、その kit を外しても
穴が残る。

**サブコマンドは引数の先頭位置でのみ判定する。** 先頭のフラグを読み飛ばすと
`tool --foo sqlite delete` のような形で allowlist を抜けられる。フラグが来たら拒否する。

**allowlist は tracked な `share/host-cli.json` とマシン固有の `local/host-cli.json` の
2 層。** ローカル側はチーム標準と同名のエントリを持てず、`allowedSubcommands` を緩められない。

**ビルドとテストはホストで任意コードを実行する。塞がない。** ワークスペースは読み書き可で
マウントするので、エージェントは `project.pbxproj` の Run Script build phase や
`.xcconfig` の `PRE_ACTION`、SPM の build plugin を書き足せる。`BuildProject` /
`RunAllTests` を呼べば、それがホストの Xcode の子プロセスとして macOS ユーザー権限で
走る。Xcode の App Sandbox 設定は**ビルド成果物のアプリ**を縛るもので、ビルド中の
スクリプトには効かない。

塞ぐならビルドを allowlist から外すしかなく、それでは iOS 開発のサンドボックスとして
成立しない。**守るのは「渡していないリポジトリ・ネットワーク・GitHub の書き込み先に
エージェントが手を伸ばすこと」で、「渡したリポジトリをビルドすること」は守らない。**
信頼していないリポジトリを開かせない、という前提の上に立っている。`host-cli.json` の
「任意のコードを実行できる操作は載せない」はホスト CLI の allowlist の方針であって、
ビルドはその外にある。

**`tools` を書かない MCP サーバーは全ツールを通す。** 絞る機構はあるので、サーバーごとに
判断する。`atlassian` は絞っていない。削除の手段が無く、更新されても Confluence 側で
前の版に戻せるため。どれが絞られているかは `ios-dev-sandbox tools` と `status` の
`mcp servers:` 行に出す。設定を開かないと分からない状態にしない。

## GitHub

**PAT は書き込み用と読み取り専用の 2 本に分け、`/usr/local/bin/gh` のラッパーで切り替える。**
サービスシークレットは `api.github.com` 宛の `Authorization` を上書きするので、両方を custom
secret にする必要がある。

**書き込み可能なリポジトリは手で列挙せず、作成時に PAT のスコープから引く。** kit が
`/user/repos` を読み、`permissions.push` が真のものを控える。fine-grained PAT はスコープ外を
返さないので、一覧は定義上スコープと一致する。手で列挙すると、スコープ外を載せたときに
ラッパーが書き込み用を選んで 404 になり、読み取り専用でなら読めたものが読めなくなる。

**引けなかったら一覧を作らず、サンドボックスの作成ごと失敗させる。** ページの取り漏らしは
「書けるはずのリポジトリが黙って読み取り専用になる」形で出る。書き込み時の 403 や 404 からは
原因に辿り着けないので、転んだ方が気づける。PAT 未設定（401）はそもそも使っていないだけなので
続行する。

**コミット署名はホストの GPG 鍵に stdin で委譲する。** 秘密鍵はコンテナに入れない。

## Xcode MCP

**`share/host-mcp.json` の xcode の tools から `XcodeOpenWorkspace`・`XcodeListWorkspaces`・
`XcodeSwitch*` は外せない。** `XcodeOpenWorkspace` は Xcode 側の承認ゲートで、一度呼ぶまで
他は全て `This agent isn't approved to use Xcode's tools yet` で弾かれる。
`XcodeListWorkspaces` はヘッドレスで `workspaceIdentifier` を解決でき、`XcodeSwitch*` が
無いと `XcodeList*` が飾りになる。

## ホストと持ち込まないもの

**ホストの `~/.claude` はマウントしない。** 必要なものはリポジトリから配る。

| | 置き場 |
|---|---|
| チーム標準（tracked、PR レビュー） | `share/` |
| 個人（gitignore） | `local/` |
| 秘密 | `~/.config/ios-dev-sandbox/secrets/`（リポジトリの外） |

**秘密だけはリポジトリのディレクトリに置かない。** `local/` は gitignore されているが、
ignore は事故で外れる。トークンが 1 度でも tracked になれば失効させるしかない。

**`local/` は `git clean -xdf` で消える。** `.build/` を消すつもりの clean や `git stash -a` が
一緒に持っていく。消えても起動はするが、ローカルの allowlist・MCP・ゲートウェイが黙って
無くなる。

**個人スキルを `local/skills` に集めるとき、ディレクトリごとの symlink は効くが、中に個別の
symlink を張っても届かない。** リンク先がコンテナにマウントされないため。

## agent の切り替え

`IOS_DEV_SANDBOX_AGENT` で claude か codex か copilot を選ぶ（既定は claude）。
サブコマンドは引数の先頭位置でしか判定しないので、フラグでは受けない。

**サンドボックスは agent ごとに立ち、project ディレクトリは workspace 単位で 1 つ。**
サンドボックス名は sbx 上で一意が要るので `-codex` のように接尾辞を付ける（claude は
無し）。project ディレクトリの中で agent ごとに分けるのは宣言（`.sbxenv.yaml`）・作成時の
指紋・state だけ。artifacts はプロジェクトの成果物で、どの agent が撮ったかは関係ないので
共通。`.claimed-workspace` も共通。

```
<proj>/
  artifacts/              共通
  .claimed-workspace      共通
  claude/  .sbxenv.yaml  created.fingerprint  state/{projects, plugins}
  codex/   .sbxenv.yaml  created.fingerprint  state/{sessions, archived, db}
  copilot/ .sbxenv.yaml  created.fingerprint  state/home
```

| | claude | codex | copilot |
|---|---|---|---|
| サンドボックス | `<name>` | `<name>-codex` | `<name>-copilot` |
| 設定の置き場 | `~/.claude` | `~/.codex` | `<proj>/copilot/state/home`（`COPILOT_HOME`） |
| MCP の登録先 | `~/.claude.json` | `~/.codex/config.toml`（TOML） | `mcp-config.json` |
| 指示 | `AGENTS.md` ＋ `CLAUDE.md`（参照 1 行） | `AGENTS.md` | `copilot-instructions.md` |
| スキル | `~/.claude/skills` | `~/.agents/skills`（sbx が用意する） | `$COPILOT_HOME/skills` |
| 履歴 | `claude/state/projects` | `codex/state/sessions` ＋ `archived` | 設定ごと `home` の中 |
| プラグイン | `claude/state/plugins` | 機構が無い | 機構はあるが未対応 |

**copilot だけ設定ごと state に置く。** 会話が `session-store.db` という単体ファイルで、
設定と同じディレクトリに同居する。履歴だけを bind で切り出せないので、`COPILOT_HOME` を
state の中に向けて丸ごとホスト側にした。bind が要らないぶん kit の実行順序にも依存しない。

**copilot には書き込み用 PAT に `Copilot Requests` を足して使う。**
`gh` 用の PAT をそのまま渡しても通らない。PAT を分けても守れるものは無い。書き込み用 PAT は
サンドボックスの環境変数に生で入っていて、`gh` ラッパーの切り替えは境界ではなく既定の
使い分けだからだ（上記）。分けると PAT が 1 本増えるだけになる。

ただし `Copilot Requests` は **resource owner が本人の fine-grained PAT にしか出ない**
（GitHub の仕様。Account permissions はトークン所有者が resource owner のときだけ）。
書き込み用 PAT を組織所有で作っている場合だけ、copilot 用に個人所有でもう 1 本要る。
`COPILOT_GITHUB_TOKEN` は `GH_TOKEN` より優先されるので、そちらに載せる。

**copilot の既定の `~/.copilot` は使わない。** sbx がそこへホストの個人スキルの古い
コピーを rw で被せてくる。`COPILOT_HOME` を移すと探索先から外れる。被せられた側を消しに
行くとホストのファイルを壊すので触らない。

**ブリッジは共通。** どちらも `http://host.docker.internal:19721/mcp/<名前>` を叩くので、
Xcode MCP は登録の書式を変えるだけでそのまま使える。

**ブリッジはランチャーの置き場を PATH の先頭に足す。** ホスト CLI のラッパーは
`ios-dev-sandbox` を PATH から呼ぶが、ブリッジは起動したシェルの PATH を継ぐ。
`~/.local/bin` の無いシェルから上げると見つからず、ラッパーは黙って cwd に倒れる。
`IOS_DEV_SANDBOX_BIN_DIR` で渡し、`@@BIN@@` と同じく SELF_DIR に解決する。

**`requires: agent:` を宣言する kit は、その agent のときだけ載せる。** 合わないまま渡すと
sbx が 400 で作成ごと拒否する。いま宣言しているのは `claude-config`。

**litellm kit はテンプレートで、ランチャーが宛先を埋めた複製を渡す。** credentials の
inject と permissions.network は spec に静的に書く必要があり、設定から差し替えられない。
社内のホスト名を tracked な spec に書かせないため、`litellm-gateway.placeholder.invalid` を
`local/gateway.json` の host で埋めて `LOG_DIR/kits/litellm/` に書き出す（`@@BIN@@` と同じ
流儀）。host か鍵が無ければ kit を載せない。載せると sbx が `apiKeyHelper` を書くので、
そのときは `CLAUDE_CODE_OAUTH_TOKEN` を渡さない（両方あると Claude Code が警告する）。

**codex の索引は `CODEX_SQLITE_HOME` で置き場ごと渡す。** ファイル名が版で変わるため
（`thread_history_1.sqlite` / `state_5.sqlite`）、名前を決め打ちしない。

**codex に履歴の自動削除は無い。** claude の `cleanupPeriodDays` に相当するものがなく、
`codex delete <id>` の手動だけ。ファイルを直接消すと索引とずれて `codex resume` から
見えなくなるので、独自の削除機能は設けない。

## 別のエージェントを同居させる

`share/mcp-agents.txt` と `local/mcp-agents.txt`（和集合）に書いたエージェントをコンテナへ入れ、メインの
agent に stdio の MCP サーバーとして登録する。**自分自身は入れない**（sbx が入れている）。

| 相手 | MCP サーバーとして | 入れ方 |
|---|---|---|
| codex | `codex mcp-server` | pnpm `--config.minimumReleaseAge=10080`（7 日） |
| claude | `claude mcp serve` | 公式インストーラの `stable`（約 1 週間遅れ） |

**claude を npm で入れてはいけない。** ネイティブバイナリを postinstall で置く仕組みで、
pnpm の既定はそれを実行しない（実測: `claude native binary not installed`）。公式は
`sudo npm -g` も非推奨としている。`minimumReleaseAge` と両立しないため、代わりに
`stable` チャンネルで古い版を選ぶ。

**インストーラは bash 専用。** dash に食わせると 9 行目で構文エラーになる。

**`su` にパイプを渡すときは二重引用符で包む。** 単引用符だとブロックスカラー内で外れ、
パイプが `su` の外に出て root 側で実行される。

**ゲートウェイ経由なら codex の宛先も kit が書く。** 書かないと codex は
`api.openai.com` を向く。`codexModel` はここで `~/.codex/config.toml` の `model` になる。
**書く主体はメインか MCP かで変わる。** 自分がメインなら litellm kit、MCP として同居
させるなら mcp-agents kit。mcp-agents のループは自分自身を飛ばすので、メインの codex は
mcp-agents では処理されない。ここを取り違えると、メインの codex だけ設定が書かれない。

**claude も同じで、MCP として入るときは mcp-agents kit が `~/.claude/settings.json` を書く。**
litellm kit はメインのエージェントで分岐するので、メインが codex なら claude 側は書かれない。
書かないと 2 つ起きる。まず `claude mcp serve` の initialize と tools/list は成功し、
Bash や Read など推論の要らないツールは使えるまま、推論を要求したときだけ落ちる
（「動かない」ではなく「考えられない」）。もう一つ、`api.anthropic.com` は組み込みの
`agent: claude` kit が許可していてメインが codex でも到達できるので、迂回を止めて
いるのは経路ではなく鍵が無いことだけになる。宛先を書くのは、それを設定として塞ぐ意味も
ある。

**`config.toml` は上書きしない。** MCP の登録も同じファイルに入るので、`>` で書くと
消える。`register-mcp.py provider` が既存を保ったまま差し替える。TOML のトップレベル
キー（`model` / `model_provider`）は最初の表の見出しより前に置く必要があり、末尾に
足すとその表の中身になる。

**pnpm が取りに行く `registry.npmjs.org` は kit が宣言する。** マシンごとの `sbx policy`
プリセットがたまたま許しているのに頼らない。

**`codex mcp-server` は非推奨だが、まだ使う。** 0.149.1 から警告が出る。`minimumReleaseAge`
で実際に入るのがその 0.149.1 なので、警告は最初から出る。後継とされる
`codex app-server` は **MCP プロトコルを話さない**（実測: `initialize` に応答しない。
`--listen stdio://` も同じ）。公式の移行先は「Claude Code 用の Codex プラグイン」で、
MCP として直接繋ぐ経路ではない。切り替えると機能が失われるので、削除されるまで
`mcp-server` を使う。

**ゲートウェイの MCP は agent で書式が違う。** claude はヘッダの値を直接書くが、codex は
環境変数の「名前」を書く（`env_http_headers`）。値はダミーでよく、プロキシが宛先ごとに
本物へ差し替える。

```toml
[mcp_servers.brave-search]
url = "https://<gateway>/brave_search/mcp"
env_http_headers = { "x-litellm-api-key" = "LITELLM_MCP_AUTH_HEADER" }
enabled = true
```

## プラグイン

**実体はリポジトリに置かず、`share/claude/plugins.txt` に `<plugin>@<marketplace>` を 1 行ずつ書く。**
kit が `claude plugin install` を叩き、実体は `<proj>/claude/state/plugins` に残る。marketplace 経由
なので更新が追える。

**公式 marketplace は「対話起動の初回」にしか自動登録されない。** 非対話の kit では明示的に
`claude plugin marketplace add anthropics/claude-plugins-official` を叩かないと、install が
not found で落ちる。

**kit の install は PATH が限られる。** `command -v claude` が解決できず、警告も出さずに
成功扱いで終わる。絶対パスへのフォールバックが要る。

## 状態

**会話履歴は `<proj>/<agent>/state/<履歴>` を agent の履歴ディレクトリに bind する。** state は virtiofs
なので起動直後はまだ見えないことがある。見えるまで待ち、駄目なら作成を失敗させる（黙って
履歴を失うより転んだ方が気づける）。

**サンドボックスは「いつの設定で作られたか」を記録して照合する。** kit と env は作成時固定
なので、設定を変えても作り直すまで効かない。**env の指紋は宣言に書くブロックそのものを
取る**（`sbxenv_env_block` を write_sbxenv と共有する）。項目を個別に列挙すると、足した
項目を指紋に入れ忘れて、変えたのに「作成時と一致」と言い続けることになる。秘密は値では
なく `${VAR}` の参照を書くのでテキストには変化が出ない。参照しているぶんだけ値を足す。

**秘密は `.sbxenv.yaml` に値を書かず、`${VAR:-}` の参照だけ書く。** 宣言は project × agent の
数だけあるので、値を書くと平文の複製が散らばる。`sbx env run` が呼び出し時の環境変数で
埋める。平文の本体は `~/.config/ios-dev-sandbox/secrets/`（0600）の 1 箇所。Keychain に
しても `security` コマンドで同じユーザーの別プロセスから読めるので、守れる範囲は変わらない。

**成果物はワークスペースの外の `<proj>/artifacts/` に置く。** スクリーンショットやログが
ユーザーのリポジトリに混ざらないようにする。

**`.claimed-workspace` は「この置き場はどの workspace のものか」を書いた 1 行。** 置き場の
名前はディレクトリ名から作るので、別の場所の同名プロジェクトと衝突する。中身の絶対パスが
自分と違えば、後から来た側がハッシュ付きの別の置き場へ回る。

**その所有ファイルは `local/read-only-dirs.txt` と見間違えない名前にする。** 1 文字違いだと
取り違えたときに置き場の解決が壊れ、会話履歴が別のディレクトリへ逃げる。

**サンドボックス名はディレクトリ名。別の場所の同名プロジェクトと衝突したときだけパスの
ハッシュを付ける。** 先に取った側の名前は動かさない。

**サンドボックス専用の git 設定は `~/.gitconfig` に置く。** workspace はホストと同一パスで
マウントされるので、`.git/config` はホストと同じファイル。

## エージェントへの指示

**kit の `agentInstructions` はコンテナに届かない。** `share/AGENTS.md` を kit が install 時に
agent の設定ディレクトリへ置く。claude はそれを `CLAUDE.md` の `@AGENTS.md` で参照し、
copilot は `copilot-instructions.md` の名前で読む。

**gh は版を焼き込まず、公開 7 日以上の最新を実行時に選ぶ。** 出たばかりの版を掴まない。

