# パス・定数・agent の判定。他の部品が使うので最初に読み込む。

# 置き場。どれも環境変数で差し替えられる（実際に使われた値は status に出る）。
SHARE_DIR="${IOS_DEV_SANDBOX_SHARE:-$ROOT/share}"
ETC_DIR="${IOS_DEV_SANDBOX_ETC:-$ROOT/local}"
SECRETS_DIR="${IOS_DEV_SANDBOX_SECRETS:-${XDG_CONFIG_HOME:-$HOME/.config}/ios-dev-sandbox/secrets}"
LOG_DIR="${IOS_DEV_SANDBOX_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/ios-dev-sandbox}"
PROJECTS_DIR="${IOS_DEV_SANDBOX_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/ios-dev-sandbox}/projects"

# kit と中継コマンドが読むので export する。
export IOS_DEV_SANDBOX_BRIDGE="${IOS_DEV_SANDBOX_BRIDGE:-$ROOT/.build/release/host-bridge}"
export IOS_DEV_SANDBOX_KITS="${IOS_DEV_SANDBOX_KITS:-$ROOT/kits}"
export IOS_DEV_SANDBOX_LOCAL_SKILLS="${IOS_DEV_SANDBOX_LOCAL_SKILLS:-$ETC_DIR/skills}"

# AGENTS_ALL は <proj> の下で agent のものが入りうるディレクトリ名。宣言を探す先を
# これに限る（artifacts はサンドボックスの中から書けるので、* で拾うと騙される）。
AGENTS_ALL="claude codex copilot"
AGENT="${IOS_DEV_SANDBOX_AGENT:-claude}"
case "$AGENT" in
  # AGENT_HOME はコンテナ内の設定ディレクトリ、AGENT_SESSIONS はその中の履歴の名前。
  # ホスト側は <proj>/<agent>/state/<AGENT_SESSIONS> に bind するので、名前は両側で同じ。
  claude) AGENT_HOME=.claude; AGENT_SESSIONS=projects ;;
  codex)  AGENT_HOME=.codex;  AGENT_SESSIONS=sessions ;;
  # copilot は設定と履歴が同居していて切り出せないので、<proj>/copilot/state/home に
  # 置き場ごと作る（AGENT_HOME は下で絶対パスになる）。~/.copilot は sbx がホストの古い
  # スキルを rw で被せてくるので使わない。
  copilot) AGENT_HOME=home; AGENT_SESSIONS= ;;
  *) echo "error: 未対応の agent: ${AGENT} — claude か codex か copilot" >&2; exit 1 ;;
esac

# 変更不可。kit がこのポートを URL とネットワーク許可の両方に焼き込んでいる。
BRIDGE_PORT=19721

# チーム標準（share/。変えるにはこのリポジトリへの PR）
HOST_CLI_TEAM="$SHARE_DIR/host-cli.json"
HOST_MCP_TEAM="$SHARE_DIR/host-mcp.json"
TEAM_SKILLS="$SHARE_DIR/skills"
TEAM_AGENTS="$SHARE_DIR/AGENTS.md"
MCP_AGENTS_TEAM="$SHARE_DIR/mcp-agents.txt"
TEAM_CLAUDE_SETTINGS="$SHARE_DIR/claude/settings.json"
TEAM_STATUSLINE="$SHARE_DIR/claude/statusline.sh"
TEAM_PLUGINS="$SHARE_DIR/claude/plugins.txt"

# このマシンだけ（local/。gitignore）
HOST_CLI_LOCAL="$ETC_DIR/host-cli.json"
HOST_MCP_LOCAL="$ETC_DIR/host-mcp.json"
MCP_AGENTS_LOCAL="$ETC_DIR/mcp-agents.txt"
GATEWAY_LOCAL="$ETC_DIR/gateway.json"

# トークン（リポジトリの外）
CLAUDE_TOKEN_FILE="$SECRETS_DIR/claude-oauth-token"
COPILOT_TOKEN_FILE="$SECRETS_DIR/copilot-token"
MCP_TOKEN_DIR="$SECRETS_DIR/mcp-tokens"

# @@BIN@@ を埋めた allowlist の複製。ブリッジに渡す。
HOST_CLI_RESOLVED="$LOG_DIR/host-cli.resolved.json"

die() { echo "error: $*" >&2; exit 1; }

resolve_developer_dir() {
  echo "${IOS_DEV_SANDBOX_DEVELOPER_DIR:-$(xcode-select -p)}"
}
