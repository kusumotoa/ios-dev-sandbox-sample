# 解決されたパスと現在の状態を出す。

harness_version() {
  git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo unknown
}

CHECK_FAILURES=0

check_ok()   { printf '  ✓ %s\n' "$1"; }
check_warn() { printf '  △ %s\n' "$1"; }
check_ng()   { printf '  ✗ %s\n' "$1"; CHECK_FAILURES=$((CHECK_FAILURES + 1)); }

container_probe() {
  local name=$1
  [ -n "$name" ] || return 0
  # sbx exec には env: の値がそのまま届くので、kit と同じ変数で組み立てる。
  sbx exec "$name" -- sh -c '
    home="${IOS_DEV_SANDBOX_AGENT_HOME:-/home/agent/.claude}"
    # 置き場は agent ごとに違う。skills / agent-instructions kit と揃えること。
    # copilot は AGENT_SESSIONS が空で、home 自体が state（virtiofs）の中にある。
    case "${IOS_DEV_SANDBOX_AGENT:-claude}" in
      codex)   skills=/home/agent/.agents/skills; instructions="$home/AGENTS.md" ;;
      copilot) skills="$home/skills"; instructions="$home/copilot-instructions.md" ;;
      *)       skills="$home/skills"; instructions="$home/AGENTS.md" ;;
    esac
    printf "agents_md=%s\n" "$([ -f "$instructions" ] && echo yes || echo no)"
    printf "claude_md=%s\n" "$([ -f "$home/CLAUDE.md" ] && echo yes || echo no)"
    # -T はそのパスを含むマウントを探す。copilot の履歴は state マウントの中の
    # ディレクトリで、マウントポイントそのものではないため -T でないと空になる。
    printf "history_bind=%s\n" "$(findmnt -n -o FSTYPE -T "$home/${IOS_DEV_SANDBOX_AGENT_SESSIONS:-}" 2>/dev/null | tail -1)"
    printf "skills=%s\n" "$(ls "$skills" 2>/dev/null | wc -l | tr -d " ")"
  ' 2>/dev/null || true
}

cmd_status() {
  export_runtime_env
  local proj_dir agent_dir host_policy signing developer_dir
  local sandbox config_state stale
  proj_dir=$(project_dir)
  agent_dir=$(agent_dir "$proj_dir")
  developer_dir=$(resolve_developer_dir)
  sandbox=$(sandbox_name 2>/dev/null)

  if [ -f "$agent_dir/$FINGERPRINT_FILE" ]; then
    stale=$(stale_inputs "$agent_dir")
    stale="${stale% }"
    if [ -n "$stale" ]; then
      config_state="$stale が作成後に変わっています — 反映するには: ios-dev-sandbox apply"
    else
      config_state='作成時の設定と一致'
    fi
  elif [ -n "$(sandbox_workspace "$sandbox")" ]; then
    config_state='記録なし（この検査より前に作られたサンドボックス。apply で記録が始まる）'
  else
    config_state='ここから作られたサンドボックスは無い'
  fi

  signing=$(git config --global user.signingkey 2>/dev/null || true)
  if [ -z "$signing" ]; then
    signing='未設定（git config --global user.signingkey <keyid>）'
  elif [ "$(git config --global gpg.format 2>/dev/null || echo openpgp)" != "openpgp" ]; then
    signing="${signing}（gpg.format が openpgp でないため、サンドボックスのコミットは未署名）"
  else
    signing="${signing}（ホストの GPG 鍵で署名）"
  fi

  # grep が空振りすると pipefail が代入に非ゼロを返し、set -e が status を
  # 1 行も出さずに殺す。診断が一番要る場面（sandboxd が応答しない、sbx が無い）で
  # 黙って死ぬので、失敗を握る。
  host_policy=$(sbx policy ls 2>/dev/null \
      | awk '$2 == "local"' \
      | grep -oE 'network: [0-9]+ allow' \
      | head -1 || true)

  echo "sbx:             $(command -v sbx || echo '未導入')"
  echo "bridge:          $IOS_DEV_SANDBOX_BRIDGE"
  echo "DEVELOPER_DIR:   $developer_dir $([ -n "$IOS_DEV_SANDBOX_DEVELOPER_DIR" ] \
      && echo '(固定)' || echo '(xcode-select に追従)')"
  echo "headless Xcode:  $([ -x "$developer_dir/usr/bin/mcp-server" ] \
      && "$developer_dir/usr/bin/mcp-server" status 2>/dev/null | head -2 | tr '\n' ' ' \
      || echo '無し（この Xcode は usr/bin/mcp-server を同梱しない）')"
  echo "version:         $(harness_version)"
  echo "checkout:        $ROOT"
  echo "sandbox name:    ${sandbox}（作り直すには: ios-dev-sandbox apply）"
  echo "sandbox config:  $config_state"
  echo "read-only dirs:  $READ_ONLY_DIRS $([ -f "$READ_ONLY_DIRS" ] && echo "($(read_only_dirs | grep -c .) 件、全プロジェクト共通)" || echo '(無し)')"
  # ツール制限の有無まで出す。tools を書かないサーバーは全ツールを通すので、
  # 設定を開かずに分かるようにする（詳しくは ios-dev-sandbox tools）。
  echo "mcp servers:     $(mcp_server_tool_counts | tr '\n' ' ' | sed 's/ $//')"
  local unauthorized
  unauthorized=$(unauthorized_mcp_servers)
  if [ -n "$unauthorized" ]; then
    printf '%s\n' "$unauthorized" | while IFS="$(printf '\t')" read -r kind names; do
      case "$kind" in
        oauth) echo "                 未認可: ${names}（ios-dev-sandbox mcp-auth <名前> で認可）" ;;
        token) echo "                 未登録: ${names}（ios-dev-sandbox mcp-token <名前> でトークンを登録）" ;;
      esac
    done
  fi
  echo "config:          ${ETC_DIR}（設定。リポジトリの中、gitignore）"
  echo "secrets:         ${SECRETS_DIR}（トークン。リポジトリの外）"
  echo "allowlist team:  $HOST_CLI_TEAM $([ -f "$HOST_CLI_TEAM" ] && echo '(あり、チーム標準)' || echo '(見つからない)')"
  echo "allowlist local: $HOST_CLI_LOCAL $([ -f "$HOST_CLI_LOCAL" ] && echo '(あり — パス差し替え / 追加コマンド)' || echo '(無し — 任意)')"
  echo "net policy team: $IOS_DEV_SANDBOX_KITS/network-policy $([ -f "$IOS_DEV_SANDBOX_KITS/network-policy/spec.yaml" ] && echo '(あり、チーム標準)' || echo '(見つからない)')"
  echo "net policy host: ${host_policy:-不明}（リポジトリ管理外 — sbx policy ls を参照）"
  echo "shared login:    $([ -n "$IOS_DEV_SANDBOX_CLAUDE_TOKEN" ] && echo "あり ($CLAUDE_TOKEN_FILE)" || echo '無し（各サンドボックスで /login するか、ios-dev-sandbox login）')"
  # cmd | grep -q は grep の早期終了で上流が SIGPIPE。pipefail が拾って判定が反転する。
  local secret_list gh_state
  secret_list=$(sbx secret ls --global 2>/dev/null || true)
  gh_state='未設定（ios-dev-sandbox github-login で登録）'
  grep -qi github <<<"$secret_list" && gh_state='設定済み（sbx の secret store）'
  echo "github (gh):     $gh_state"
  echo "commit signing:  $signing"
  local health
  health=$(bridge_health)
  echo "bridge health:   ${health:-停止中（起動時に立ち上がる）}"

  printf '%s' "$health" | python3 -c '
import json, sys
try:
    warnings = json.load(sys.stdin).get("warnings", [])
except Exception:
    sys.exit(0)
for warning in warnings:
    print(f"warning: host CLI allowlist: {warning}", file=sys.stderr)
' || true

  status_checks "$proj_dir" "$sandbox" "$config_state" "$unauthorized"
  [ "$CHECK_FAILURES" -eq 0 ]
}

status_checks() {
  local proj_dir=$1 sandbox=$2 config_state=$3 unauthorized=$4
  echo
  echo "検査:"

  # stale_bridge_pid は「入れ替えるべき pid」を返す契約で、別 clone のブリッジや
  # ps が読めないときも空になる。それを「最新版で動いている」と読むと嘘になるので、
  # 持ち主を別に見る。
  local owner
  owner=$(bridge_owner)
  case "$owner" in
    none)    check_ng "ブリッジが動いていない — ios-dev-sandbox を実行すると起動する" ;;
    ours)    check_ok "ブリッジが最新版で動いている" ;;
    stale)   check_ng "ブリッジが古い版のまま — ios-dev-sandbox restart-bridge" ;;
    other:*) check_warn "別の clone の host-bridge を使っている（${owner#other:}）— 入れ替えるなら ios-dev-sandbox restart-bridge" ;;
    *)       check_warn "ブリッジは動いているが、どれかを確認できない（ps が読めない）" ;;
  esac

  case "$config_state" in
    *一致*)   check_ok "サンドボックスの設定が作成時と一致" ;;
    *変わっ*) check_ng "設定が作成後に変わっている — ios-dev-sandbox apply" ;;
    *)        check_warn "$config_state" ;;
  esac

  if [ -n "$unauthorized" ]; then
    check_warn "認可・登録が済んでいない MCP サーバーがある（上記参照）"
  else
    check_ok "MCP サーバーの認可・登録が揃っている"
  fi

  status_checks_agent_login
  status_checks_container "$sandbox"
  status_checks_github "$sandbox"
}

# agent ごとに認証の要り方が違う。足りないまま起動してもエラーになるのは実際に
# 使おうとした瞬間なので、ここで先に言う。
status_checks_agent_login() {
  case "$AGENT" in
    claude)
      if [ -n "$IOS_DEV_SANDBOX_CLAUDE_TOKEN" ]; then
        check_ok "claude の認証がある"
      else
        check_warn "claude の認証が無い — ios-dev-sandbox login（コンテナ内の /login でも可）"
      fi ;;
    copilot)
      if [ -n "$IOS_DEV_SANDBOX_COPILOT_TOKEN" ]; then
        check_ok "copilot の認証がある"
      else
        check_ng "copilot の認証が無い — ios-dev-sandbox copilot-login
         個人アカウント所有の fine-grained PAT に Copilot Requests を付けて作ります
         （gh 用の PAT では通りません。docs/instructions/agents/copilot.md）"
      fi ;;
    codex)
      # codex の認証は sbx の secret store にあり、こちらからは中身を見られない。
      if sbx secret ls 2>/dev/null | grep -q openai; then
        check_ok "codex の認証がある（sbx の secret）"
      else
        check_warn "codex の認証が見つからない — sbx secret set openai --oauth（コンテナ内の codex login でも可）"
      fi ;;
  esac
}

status_checks_container() {
  local sandbox=$1 probe agents_md claude_md history_bind skills
  probe=$(container_probe "$sandbox")
  if [ -z "$probe" ]; then
    check_warn "サンドボックスが動いていないので中は見ていない"
    return 0
  fi
  agents_md=$(printf '%s\n' "$probe" | sed -n 's/^agents_md=//p')
  claude_md=$(printf '%s\n' "$probe" | sed -n 's/^claude_md=//p')
  history_bind=$(printf '%s\n' "$probe" | sed -n 's/^history_bind=//p')
  skills=$(printf '%s\n' "$probe" | sed -n 's/^skills=//p')

  # CLAUDE.md は AGENTS.md を参照させるためのもので、claude のときだけ置かれる。
  if [ "$agents_md" = yes ] && { [ "$AGENT" != claude ] || [ "$claude_md" = yes ]; }; then
    check_ok "エージェント向けの指示が届いている"
  else
    check_ng "AGENTS.md が置かれていない — ios-dev-sandbox apply"
  fi

  if [ "$history_bind" = virtiofs ]; then
    check_ok "会話履歴がホスト側に保存される"
  else
    check_ng "会話履歴の bind が張られていない — ios-dev-sandbox apply"
  fi

  if [ "${skills:-0}" -gt 0 ] 2>/dev/null; then
    check_ok "スキルが ${skills} 個繋がっている"
  else
    check_warn "スキルが 1 つも無い"
  fi
}

status_checks_github() {
  local name=$1 code
  code=$(sbx exec "$name" -- sh -c '
    if [ -n "${GH_TOKEN_CODE_REPOS_RW:-}" ]; then
        auth="Authorization: Bearer $GH_TOKEN_CODE_REPOS_RW"
    else
        auth="X-Probe: none"
    fi
    curl -sS -o /dev/null -w "%{http_code}" --max-time 10 -H "$auth" https://api.github.com/user
  ' 2>/dev/null || true)
  case "$code" in
    200) check_ok "GitHub の認証が有効" ;;
    "")  check_warn "GitHub の認証を確認できなかった（サンドボックスが動いていない）" ;;
    *)   check_ng "GitHub の認証が通らない（HTTP ${code}） — ios-dev-sandbox github-login" ;;
  esac
}

cmd_tools() {
  [ -f "$HOST_MCP_TEAM" ] || die "host-mcp.json がありません: $HOST_MCP_TEAM"
  mcp_servers tools "${1:-}"
}
