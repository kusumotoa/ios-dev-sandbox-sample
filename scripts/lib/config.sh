# share/ と local/ の設定と、リポジトリの外に置いたトークンを読む。

# 差し込む値に & や | が入っていても壊れないよう、sed ではなく python で置く。
# sed は失敗しても $( ) の中では set -e が効かず、0 バイトのファイルが残る。
render_template() {
  python3 - "$@" <<'PY'
import sys
src, dst, placeholder, value = sys.argv[1:5]
open(dst, "w").write(open(src).read().replace(placeholder, value))
PY
}

# @@BIN@@ は SELF_DIR に解決する。固定にすると clone が 2 つあるとき別物を指す。
resolve_host_cli() {
  if [ ! -f "$HOST_CLI_TEAM" ]; then
    printf '%s' "$HOST_CLI_TEAM"
    return 0
  fi
  mkdir -p "$LOG_DIR"
  render_template "$HOST_CLI_TEAM" "$HOST_CLI_RESOLVED" @@BIN@@ "$SELF_DIR" \
    || die "allowlist を解決できません: $HOST_CLI_TEAM"
  printf '%s' "$HOST_CLI_RESOLVED"
}

# litellm kit の宛先は spec に静的に書く必要があり、設定から差し替えられない。社内の
# ホスト名を tracked な spec に書かせず、プレースホルダを local/gateway.json の host で
# 埋めた複製を渡す（@@BIN@@ と同じ）。host か鍵が無ければ空を返し、kit は載せない。
MCP_AGENTS_KIT="$IOS_DEV_SANDBOX_KITS/mcp-agents"
LITELLM_KIT_TEMPLATE="$IOS_DEV_SANDBOX_KITS/litellm"
LITELLM_KIT_RESOLVED="$LOG_DIR/kits/litellm"
LITELLM_PLACEHOLDER=litellm-gateway.placeholder.invalid
resolve_litellm_kit() {
  local host
  host=$(gateway_value host)
  if [ -z "$host" ] || [ "$(litellm_enabled)" != 1 ]; then return 0; fi
  [ -f "$LITELLM_KIT_TEMPLATE/spec.yaml" ] || return 0
  mkdir -p "$LITELLM_KIT_RESOLVED"
  # 書けなければ空を返して kit ごと落とす。中途半端な spec.yaml を渡すと
  # 「kit は載るが宛先が無い」サンドボックスになる。
  render_template "$LITELLM_KIT_TEMPLATE/spec.yaml" "$LITELLM_KIT_RESOLVED/spec.yaml" \
    "$LITELLM_PLACEHOLDER" "$host" || return 0
  printf '%s' "$LITELLM_KIT_RESOLVED"
}

# MCP として使えるようにするエージェント。チーム標準と個人の両方。自分自身は kit 側で外す。
# awk にファイルを直接渡す。cat で繋ぐと、末尾に改行が無いファイルの最終行と次の
# ファイルの先頭行がくっついて 1 語になる。片方しか無いのが既定なので、cat を並べた
# グループが非ゼロを返して pipefail に拾われる形も避ける。
mcp_agents() {
  local files=()
  if [ -f "$MCP_AGENTS_TEAM" ]; then files+=("$MCP_AGENTS_TEAM"); fi
  if [ -f "$MCP_AGENTS_LOCAL" ]; then files+=("$MCP_AGENTS_LOCAL"); fi
  if [ "${#files[@]}" -eq 0 ]; then return 0; fi
  awk '{ sub(/#.*/, ""); gsub(/\r/, "")
         n = split($0, parts, ",")
         for (i = 1; i <= n; i++) {
           name = parts[i]
           gsub(/^[ \t]+|[ \t]+$/, "", name)
           if (name != "" && !seen[name]++) out = (out == "" ? name : out " " name)
         } }
       END { if (out != "") print out }' "${files[@]}"
}

export_runtime_env() {
  export IOS_DEV_SANDBOX_DEVELOPER_DIR="${IOS_DEV_SANDBOX_DEVELOPER_DIR:-}"

  export IOS_DEV_SANDBOX_CLAUDE_TOKEN=""
  if [ -f "$CLAUDE_TOKEN_FILE" ]; then
    IOS_DEV_SANDBOX_CLAUDE_TOKEN=$(cat "$CLAUDE_TOKEN_FILE")
  fi

  export IOS_DEV_SANDBOX_COPILOT_TOKEN=""
  if [ -f "$COPILOT_TOKEN_FILE" ]; then
    IOS_DEV_SANDBOX_COPILOT_TOKEN=$(cat "$COPILOT_TOKEN_FILE")
  fi
}

# host-mcp.json はチーム標準とマシン固有の 2 枚。読み方はどの用途でも同じなので、
# lib/mcp-servers.py にまとめてある。
mcp_servers() {
  python3 "$SELF_DIR/lib/mcp-servers.py" "$HOST_MCP_TEAM" "$HOST_MCP_LOCAL" "$@"
}

mcp_server_tool_counts() { mcp_servers counts; }
mcp_server_names()       { mcp_servers names; }

unauthorized_mcp_servers() {
  mcp_servers unauthorized "$SECRETS_DIR/mcp-oauth" "$MCP_TOKEN_DIR"
}

gateway_value() {
  local key=$1
  if [ -f "$GATEWAY_LOCAL" ]; then
    python3 -c 'import json, sys
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2])
except Exception:
    v = None
print(v if v is not None else "")' "$GATEWAY_LOCAL" "$key" 2>/dev/null | grep . && return 0
  fi
  printf ''
}

litellm_enabled() {
  # cmd | grep -q は SIGPIPE + pipefail で判定が反転する。
  local secret_list
  secret_list=$(sbx secret ls 2>/dev/null || true)
  if grep -q 'litellm-api-key' <<<"$secret_list"; then
    printf '1'
  else
    printf '0'
  fi
}
