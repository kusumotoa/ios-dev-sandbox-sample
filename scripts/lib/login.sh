# トークンの登録。どれも 1 回だけで、全サンドボックスで共有される。

cmd_login() {
  command -v claude >/dev/null || die "ホストに claude CLI がありません"
  # 先に作る。ブラウザ認証の後に落ちるとやり直しになる。
  mkdir -p -m 700 "$SECRETS_DIR"

  echo "'claude setup-token' を実行します（ブラウザでサインイン）..."
  local output token
  output=$(claude setup-token | tee /dev/tty) || die "claude setup-token が失敗しました"
  # grep の空振りを握らないと、pipefail + set -e が次行の die より先に殺す。
  # ブラウザ認証を済ませた直後に理由も出ずに終わることになる。
  token=$(printf '%s' "$output" | grep -oE 'sk-ant-[A-Za-z0-9_-]+' | tail -1 || true)
  [ -n "$token" ] || die "setup-token の出力にトークンが見つかりません"

  (umask 077 && printf '%s' "$token" > "$CLAUDE_TOKEN_FILE")
  echo "$CLAUDE_TOKEN_FILE に保存しました"
  echo "新しいサンドボックスは自動で認証されます。既存のものへは 'ios-dev-sandbox apply' で反映してください"
}

# サンドボックスの中では login できない。copilot は認証を keychain に置きたがり、
# 無いときは平文で良いかを対話で訊く。sbx exec は TTY を渡せずそこで必ず落ちる。
cmd_copilot_login() {
  mkdir -p -m 700 "$SECRETS_DIR"
  # 端末が無ければ標準入力から読む（pbpaste | ... で履歴に残さずに渡せる）。
  if [ ! -t 0 ]; then
    local piped
    read -r piped || true
    [ -n "$piped" ] || die "標準入力が空です"
    save_copilot_token "$piped"
    return 0
  fi
  cat <<'EOS'
Copilot 用の fine-grained PAT を貼り付けてください。
https://github.com/settings/personal-access-tokens/new

  Resource owner      自分の個人アカウント（組織を選ばない）
  Repository access   Public repositories
  Permissions         Account タブ → Add permissions → Copilot Requests

Copilot Requests は個人アカウント所有の fine-grained PAT にしか出ません。組織を
選ぶと候補に現れないので、そこだけ間違えないでください。

リポジトリの権限は要りません。gh に渡している PAT は対象リポジトリだけに絞って
ありますが、権限の広いトークンを同じサンドボックスに置くと、エージェントが API を
直接叩けるためその制限が意味を失います。

EOS
  local token
  read -rsp "PAT: " token
  echo
  save_copilot_token "$token"
}

save_copilot_token() {
  local token=$1
  [ -n "$token" ] || die "空です"
  case "$token" in
    github_pat_*) ;;
    ghp_*) die "classic では Copilot Requests を付けられません。fine-grained を作ってください" ;;
    *) die "PAT の形式ではありません" ;;
  esac

  (umask 077 && printf '%s' "$token" > "$COPILOT_TOKEN_FILE")
  echo "$COPILOT_TOKEN_FILE に保存しました"
  echo "IOS_DEV_SANDBOX_AGENT=copilot ios-dev-sandbox apply で反映してください"
}

cmd_github_login() {
  require_sbx
  cat <<'EOS'
Fine-grained PAT を貼り付けてください（GitHub → Settings → Developer settings →
Fine-grained tokens → Generate new token）。作業対象のリポジトリだけに絞り、
Contents / Pull requests / Issues の read & write を付けます。これはサンドボックスが
使う認証情報で、あなた個人のログインではありません。Workflows は付けないでください
（エージェントに .github/workflows を書き換えさせないため。docs/instructions/github-auth.md）。

動いているサンドボックスにも即座に効きます。

EOS
  sbx secret set github || die "sbx secret set github が失敗しました"
  echo "完了"
}

cmd_litellm_login() {
  require_sbx
  cat <<'EOS'
社内 LiteLLM の API キーを貼り付けてください
（ゲートウェイの管理画面で発行。発行し直しの周期は運用に依ります）。

直接 Anthropic を使う人はこの登録は不要です。登録するとゲートウェイ経由に切り替わります。

EOS
  sbx secret set litellm-api-key || die "sbx secret set litellm-api-key が失敗しました"
  echo "完了。'ios-dev-sandbox apply' でサンドボックスに反映してください"
}

cmd_mcp_token() {
  [ -n "${1:-}" ] || die "使い方: ios-dev-sandbox mcp-token <サーバー名>"
  local name=$1 declared token
  declared=$(mcp_server_names | grep -Fx "$name" || true)
  [ -n "$declared" ] || die "'$name' は host-mcp.json に定義されていません"

  printf 'トークンを貼り付けてください（表示されません）: ' >&2
  IFS= read -rs token || die "読み取れませんでした"
  printf '\n' >&2
  [ -n "$token" ] || die "空のトークンは登録しません"

  mkdir -p "$MCP_TOKEN_DIR"
  (umask 077 && printf '%s\n' "$token" > "$MCP_TOKEN_DIR/$name")
  echo "登録しました: $MCP_TOKEN_DIR/$name"
  echo "動いているサンドボックスにも次の呼び出しから効きます"
}

cmd_mcp_auth() {
  [ -n "${1:-}" ] || die "使い方: ios-dev-sandbox mcp-auth <サーバー名>"
  [ -x "$IOS_DEV_SANDBOX_BRIDGE" ] || die "host-bridge がありません: $IOS_DEV_SANDBOX_BRIDGE"
  "$IOS_DEV_SANDBOX_BRIDGE" auth "$1" \
    --mcp-config "$HOST_MCP_TEAM" --mcp-local-config "$HOST_MCP_LOCAL" \
    --oauth-dir "$SECRETS_DIR/mcp-oauth" --token-dir "$MCP_TOKEN_DIR"
}
