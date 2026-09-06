# sbx に渡す宣言（.sbxenv.yaml）を組み、作成後に変わった入力を見つける。

FINGERPRINT_FILE=created.fingerprint

# gitignore されるものは外す。__pycache__ は kit を使った人のマシンにだけできるので、
# 拾うと同じコミットでも人によって digest が変わり、誰も触っていないのに
# 「kits が変わっています」と言い続ける。
tree_digest() {
  [ -d "$1" ] || { printf 'absent'; return 0; }
  ( cd "$1" && find . -type f ! -name .DS_Store ! -name '*.pyc' \
        ! -path '*/__pycache__/*' -print0 | sort -z \
      | xargs -0 shasum 2>/dev/null ) | shasum | cut -c1-12
}

# 引数は <proj>/<agent>。
sandbox_fingerprint() {
  local agent_dir="$1"
  echo "kits $(tree_digest "$IOS_DEV_SANDBOX_KITS")"
  echo "read-only-dirs $(read_only_dirs | shasum | cut -c1-12)"
  echo "mcp $(mcp_server_names | shasum | cut -c1-12)"
  # 中継コマンドの symlink も作成時に張る。コマンドを足したら作り直しが要るので、
  # MCP と同じく拾う（restart-bridge だけではコンテナに現れない）。
  echo "host-cli $(cat "$HOST_CLI_TEAM" "$HOST_CLI_LOCAL" 2>/dev/null | shasum | cut -c1-12)"
  # env は 20 項目以上ある。個別に数えると足し忘れたものが検出されないので、宣言に
  # 書くブロックそのものを取る。秘密は値ではなく ${VAR} の参照を書くのでテキストには
  # 変化が出ない。参照しているぶんだけ値を足して digest する（値は保存しない）。
  echo "env $({ sbxenv_env_block "$agent_dir" "$(resolve_litellm_kit)"
                printf '%s\n%s\n' "${IOS_DEV_SANDBOX_CLAUDE_TOKEN:-}" \
                                  "${IOS_DEV_SANDBOX_COPILOT_TOKEN:-}"
              } | shasum | cut -c1-12)"
}

stale_inputs() {
  local agent_dir="$1" recorded="$1/$FINGERPRINT_FILE"
  [ -f "$recorded" ] || return 0
  sandbox_fingerprint "$agent_dir" | while read -r key digest; do
    case "$(grep "^$key " "$recorded" | cut -d' ' -f2)" in
      "$digest") ;;
      *) printf '%s ' "$key" ;;
    esac
  done
}

warn_stale_sandbox() {
  local agent_dir="$1" name="$2" stale
  stale=$(stale_inputs "$agent_dir")
  stale="${stale% }"
  [ -n "$stale" ] || return 0
  echo "warning: $stale が '$name' の作成後に変わっています（作成時に固定される設定です）" >&2
  echo "         反映するには: ios-dev-sandbox apply" >&2
}

# 引数は <proj>/<agent>。宣言と state はそこ、artifacts は 1 つ上（共通）。
write_sbxenv() {
  local agent_dir=$1 name=$2 kit ws
  local proj_dir
  proj_dir=$(dirname "$agent_dir")
  mkdir -p "$agent_dir"
  {
    printf 'schemaVersion: "1"\n'
    printf 'name: %s\n' "$name"
    printf 'agent: %s\n\n' "$AGENT"
    yaml_scalar workspace "$(pwd -P)"
    printf '\nadditionalWorkspaces:\n'
    [ -d "$IOS_DEV_SANDBOX_LOCAL_SKILLS" ] && yaml_workspace "$IOS_DEV_SANDBOX_LOCAL_SKILLS" readOnly
    yaml_workspace "$SHARE_DIR" readOnly
    yaml_workspace "$agent_dir/state"
    yaml_workspace "$proj_dir/artifacts"
    while IFS= read -r ws; do
      yaml_workspace "$ws" readOnly
    done < <(read_only_dirs)

    printf '\nkits:\n'
    # litellm はテンプレートなので repo のものは渡さず、宛先を埋めた複製だけ渡す。
    local litellm_kit
    litellm_kit=$(resolve_litellm_kit)
    for kit in "$IOS_DEV_SANDBOX_KITS"/*/; do
      [ "${kit%/}" != "$LITELLM_KIT_TEMPLATE" ] || continue
      # 相手がいなければ mcp-agents は載せない。install は何もしないが、
      # kit を渡すと permissions の claude.ai と registry.npmjs.org が開いたままになる
      # （ネットワーク許可を kit に scope する意味が無くなる）。
      [ "${kit%/}" != "$MCP_AGENTS_KIT" ] || [ -n "$(mcp_agents)" ] || continue
      # requires: agent: を宣言する kit は、その agent のときだけ載せる。
      # 合わないまま渡すと sbx が 400 で作成ごと拒否する。
      local wants
      wants=$(sed -n '/^requires:/,/^[^ ]/p' "${kit}spec.yaml" 2>/dev/null \
              | sed -n 's/^  agent: *//p' | head -1)
      [ -z "$wants" ] || [ "$wants" = "$AGENT" ] || continue
      yaml_item "${kit%/}"
    done
    [ -z "$litellm_kit" ] || yaml_item "$litellm_kit"
    local IFS=:
    for kit in ${IOS_DEV_SANDBOX_EXTRA_KITS:-}; do
      [ -n "$kit" ] && yaml_item "$kit"
    done
    unset IFS

    printf '\n'
    sbxenv_env_block "$agent_dir" "$litellm_kit"
  } > "$agent_dir/.sbxenv.yaml"
  chmod 600 "$agent_dir/.sbxenv.yaml"
}

# 宣言の env ブロック。作成時の指紋も同じものを見るので、ここだけを直せば両方に効く。
# 引数は <proj>/<agent> と、載せる litellm kit の複製（無ければ空）。
sbxenv_env_block() {
  local agent_dir=$1 litellm_kit=$2 proj_dir
  proj_dir=$(dirname "$agent_dir")
  {
    printf 'env:\n'
    yaml_entry IOS_DEV_SANDBOX_LOCAL_SKILLS "$([ -d "$IOS_DEV_SANDBOX_LOCAL_SKILLS" ] && printf %s "$IOS_DEV_SANDBOX_LOCAL_SKILLS")"
    yaml_entry IOS_DEV_SANDBOX_TEAM_SKILLS "$([ -d "$TEAM_SKILLS" ] && printf %s "$TEAM_SKILLS")"
    yaml_entry IOS_DEV_SANDBOX_TEAM_SETTINGS "$([ -f "$TEAM_CLAUDE_SETTINGS" ] && printf %s "$TEAM_CLAUDE_SETTINGS")"
    yaml_entry IOS_DEV_SANDBOX_TEAM_STATUSLINE "$([ -f "$TEAM_STATUSLINE" ] && printf %s "$TEAM_STATUSLINE")"
    yaml_entry IOS_DEV_SANDBOX_TEAM_PLUGINS "$([ -f "$TEAM_PLUGINS" ] && printf %s "$TEAM_PLUGINS")"
    yaml_entry IOS_DEV_SANDBOX_TEAM_AGENTS "$([ -f "$TEAM_AGENTS" ] && printf %s "$TEAM_AGENTS")"
    yaml_entry IOS_DEV_SANDBOX_MCP_AGENTS "$(mcp_agents)"
    yaml_entry IOS_DEV_SANDBOX_AGENT "$AGENT"
    # copilot だけ設定ごと state に置く。コンテナからはホストと同じパスで見える。
    local agent_home
    case "$AGENT" in
      copilot) agent_home="$agent_dir/state/$AGENT_HOME" ;;
      *)       agent_home="/home/agent/$AGENT_HOME" ;;
    esac
    yaml_entry IOS_DEV_SANDBOX_AGENT_HOME "$agent_home"
    yaml_entry IOS_DEV_SANDBOX_AGENT_SESSIONS "$AGENT_SESSIONS"
    [ "$AGENT" = codex ] && yaml_entry CODEX_SQLITE_HOME "$agent_dir/state/db"
    [ "$AGENT" = copilot ] && yaml_entry COPILOT_HOME "$agent_home"
    # gh に渡している PAT は Copilot に通らない。COPILOT_GITHUB_TOKEN は GH_TOKEN
    # より優先されるので、Copilot 用の PAT だけをここで上書きする。
    [ "$AGENT" = copilot ] && yaml_entry COPILOT_GITHUB_TOKEN '${IOS_DEV_SANDBOX_COPILOT_TOKEN:-}'
    yaml_entry IOS_DEV_SANDBOX_STATE_DIR "$agent_dir/state"
    yaml_entry IOS_DEV_SANDBOX_ARTIFACTS "$proj_dir/artifacts"
    # 秘密は値を書かず参照だけ書く（sbx env run が呼び出し時の環境変数で埋める）。
    # 値を書くと宣言ファイルの数だけ平文の複製が散らばる。
    # ゲートウェイ経由のときは鍵をプロキシが差し込む（sbx が apiKeyHelper を書く）。
    # OAuth トークンも渡すと Claude Code が「両方ある」と警告するので、片方だけにする。
    [ -n "$litellm_kit" ] || yaml_entry CLAUDE_CODE_OAUTH_TOKEN '${IOS_DEV_SANDBOX_CLAUDE_TOKEN:-}'
    yaml_entry IOS_DEV_SANDBOX_LITELLM "$([ -n "$litellm_kit" ] && printf 1 || printf 0)"
    local brave_path
    brave_path=$(gateway_value braveSearchPath)
    yaml_entry IOS_DEV_SANDBOX_GATEWAY_HOST "$(gateway_value host)"
    yaml_entry IOS_DEV_SANDBOX_GATEWAY_BRAVE_PATH "$brave_path"
    # codex の env_http_headers はヘッダの値ではなく環境変数の「名前」を書く形式。
    # 中身はダミーでよい（プロキシが宛先ごとに本物へ差し替える）。
    yaml_entry LITELLM_MCP_AUTH_HEADER "$([ -n "$brave_path" ] && printf 'Bearer proxy-managed')"
    yaml_entry IOS_DEV_SANDBOX_CODEX_MODEL "$(gateway_value codexModel)"
  }
}

yaml_quote() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

yaml_scalar() { printf '%s: "%s"\n' "$1" "$(yaml_quote "$2")"; }
yaml_item()   { printf '  - "%s"\n' "$(yaml_quote "$1")"; }
yaml_entry()  { printf '  %s: "%s"\n' "$1" "$(yaml_quote "$2")"; }

yaml_workspace() {
  printf '  - path: "%s"\n' "$(yaml_quote "$1")"
  [ "${2:-}" = readOnly ] && printf '    readOnly: true\n'
  return 0
}
