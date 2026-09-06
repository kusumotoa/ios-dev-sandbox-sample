#!/usr/bin/env bash
# サンドボックス（Linux）のステータスライン。ホストでは使わないので GNU の
# コマンドだけを前提にしてよい。ホスト側は各自の ~/.claude/statusline.sh。

readonly COLOR_WHITE="\033[37m"
readonly COLOR_RED="\033[31m"
readonly COLOR_YELLOW="\033[33m"
readonly COLOR_GREEN="\033[32m"
readonly COLOR_RESET="\033[0m"

# 標準入力は 1 度しか読めないので、最初にまとめて受ける。
readonly INPUT=$(cat)
readonly MODEL_DISPLAY=$(echo "$INPUT" | jq -r '.model.display_name')
readonly CURRENT_DIR=$(echo "$INPUT" | jq -r '.workspace.current_dir')

build_bar() {
  local pct=$1
  local filled=$(( pct * 10 / 100 ))
  local empty=$(( 10 - filled ))
  local bar=""
  [ "$filled" -gt 0 ] && printf -v fill "%${filled}s" && bar="${fill// /▓}"
  [ "$empty" -gt 0 ] && printf -v pad "%${empty}s" && bar="${bar}${pad// /░}"
  echo "$bar"
}

pct_color() {
  local pct=$1
  if [ "$pct" -ge 90 ]; then echo "$COLOR_RED"
  elif [ "$pct" -ge 70 ]; then echo "$COLOR_YELLOW"
  else echo "$COLOR_GREEN"
  fi
}

format_unix_ts() {
  local ts=$1
  local now
  now=$(date +%s)
  local diff=$(( ts - now ))

  if [ "$diff" -le 0 ]; then
    echo "expired"
  elif [ "$diff" -lt 3600 ]; then
    echo "$(( diff / 60 ))m"
  elif [ "$diff" -lt 86400 ]; then
    local h=$(( diff / 3600 ))
    local m=$(( (diff % 3600) / 60 ))
    echo "${h}h${m}m"
  else
    date -d "@$ts" "+%m/%d" 2>/dev/null || echo "$ts"
  fi
}

get_git_info() {
  git rev-parse &>/dev/null || return

  local branch
  branch=$(git branch --show-current 2>/dev/null)
  if [ -z "$branch" ]; then
    local hash
    hash=$(git rev-parse --short HEAD 2>/dev/null)
    branch="HEAD (${hash})"
  fi

  local staged modified
  staged=$(git diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
  modified=$(git diff --numstat 2>/dev/null | wc -l | tr -d ' ')

  local suffix=""
  [ "$staged" -gt 0 ] && suffix="${suffix} ${COLOR_GREEN}+${staged}${COLOR_RESET}"
  [ "$modified" -gt 0 ] && suffix="${suffix} ${COLOR_YELLOW}~${modified}${COLOR_RESET}"

  echo -e " | ${COLOR_WHITE}🌿 ${branch}${COLOR_RESET}${suffix}"
}

get_context_line() {
  local pct
  pct=$(echo "$INPUT" | jq -r '.context_window.used_percentage // 0')
  local pct_int=${pct%.*}
  pct_int=${pct_int:-0}

  local bar color
  bar=$(build_bar "$pct_int")
  color=$(pct_color "$pct_int")

  echo -e "${color}${bar}${COLOR_RESET} ${color}${pct_int}%${COLOR_RESET}"
}

# 5 時間と 7 日の枠。入力に rate_limits が無ければ何も出さない。
get_rate_limits() {
  local has_limits
  has_limits=$(echo "$INPUT" | jq -r '.rate_limits // empty' 2>/dev/null)
  [ -z "$has_limits" ] && return

  local result=""

  local h5_pct h5_resets
  h5_pct=$(echo "$INPUT" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)
  h5_resets=$(echo "$INPUT" | jq -r '.rate_limits.five_hour.resets_at // empty' 2>/dev/null)

  if [ -n "$h5_pct" ]; then
    local h5_int=${h5_pct%.*}
    local h5_color
    h5_color=$(pct_color "$h5_int")
    local h5_reset=""
    [ -n "$h5_resets" ] && h5_reset=" (→$(format_unix_ts "$h5_resets"))"
    result="${result} | ⏱ 5h: ${h5_color}${h5_int}%${COLOR_RESET}${h5_reset}"
  fi

  local h7_pct h7_resets
  h7_pct=$(echo "$INPUT" | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null)
  h7_resets=$(echo "$INPUT" | jq -r '.rate_limits.seven_day.resets_at // empty' 2>/dev/null)

  if [ -n "$h7_pct" ]; then
    local h7_int=${h7_pct%.*}
    local h7_color
    h7_color=$(pct_color "$h7_int")
    local h7_reset=""
    [ -n "$h7_resets" ] && h7_reset=" (→$(format_unix_ts "$h7_resets"))"
    result="${result} | 📅 7d: ${h7_color}${h7_int}%${COLOR_RESET}${h7_reset}"
  fi

  echo -e "$result"
}

get_effort_thinking() {
  local effort thinking result=""

  effort=$(echo "$INPUT" | jq -r '.effort.level // empty' 2>/dev/null)
  thinking=$(echo "$INPUT" | jq -r '.thinking.enabled // empty' 2>/dev/null)

  [ "$thinking" = "true" ] && result="${result} | 🧠"

  if [ -n "$effort" ]; then
    local symbol
    case "$effort" in
      low) symbol="○" ;;
      medium) symbol="◐" ;;
      high) symbol="●" ;;
      xhigh) symbol="◉" ;;
      max) symbol="★" ;;
      *) symbol="?" ;;
    esac
    result="${result} ${symbol} ${effort}"
  fi

  echo -e "$result"
}

main() {
  local parent_dir
  parent_dir="$(basename "$(dirname "$CURRENT_DIR")")/$(basename "$CURRENT_DIR")"

  local git_info effort_info
  git_info=$(get_git_info)
  effort_info=$(get_effort_thinking)

  echo -e "🤖 ${MODEL_DISPLAY} | 📁 ${parent_dir}${git_info}${effort_info}"

  local context_line rate_info
  context_line=$(get_context_line)
  rate_info=$(get_rate_limits)
  echo -e "📊 ${context_line}${rate_info}"
}

main
