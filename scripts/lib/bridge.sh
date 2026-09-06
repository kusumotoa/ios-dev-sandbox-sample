# host-bridge と、mcpbridge が繋ぐ Xcode を起こす。

find_xcode_project() {
  local candidate
  for candidate in *.xcworkspace *.xcodeproj; do
    if [ -e "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

start_headless_xcode() {
  local developer_dir="$1" project="$2"
  local mcp_server="$developer_dir/usr/bin/mcp-server"
  [ -x "$mcp_server" ] || return 0

  # cmd | grep -q は SIGPIPE + pipefail で判定が反転する。変数に入れてから見る。
  mcp_running() {
    local out
    out=$("$mcp_server" status --format json 2>/dev/null || true)
    grep -q '"running" : true' <<<"$out"
  }

  if ! mcp_running; then
    echo "ヘッドレスの Xcode MCP サーバーを起動します..."
    "$mcp_server" start \
      || { echo "warning: mcp-server を起動できません。Xcode アプリを開いたままにしてください" >&2; return 0; }
    local waited=0
    until mcp_running; do
      sleep 1
      waited=$((waited + 1))
      [ "$waited" -lt 30 ] || { echo "warning: mcp-server が 30 秒で起動しません" >&2; break; }
    done
  fi

  "$mcp_server" open "$PWD/$project" \
    || echo "warning: mcp-server がプロジェクトを開けません: $PWD/$project" >&2
}

# 応答があれば本文、無ければ空。呼ぶ側は -n で見る。
bridge_health() {
  curl -sf "http://127.0.0.1:$BRIDGE_PORT/health" 2>/dev/null || true
}

listening_bridge_pid() {
  lsof -nP -iTCP:"$BRIDGE_PORT" -sTCP:LISTEN -t 2>/dev/null | head -1 || true
}

# :19721 を握っているブリッジの持ち主。stale_bridge_pid は「入れ替えるべき pid」を
# 返す契約で、別 clone のものや ps が読めないときも空になるため、status には使えない。
bridge_owner() {
  local pid path
  pid=$(listening_bridge_pid || true)
  [ -n "$pid" ] || { printf 'none'; return 0; }
  path=$(ps -p "$pid" -o comm= 2>/dev/null || true)
  if [ -z "$path" ]; then
    printf 'unknown'
  elif [ "$path" = "$IOS_DEV_SANDBOX_BRIDGE" ]; then
    printf 'ours'
  elif [ -e "$path" ]; then
    printf 'other:%s' "$path"
  else
    printf 'stale'
  fi
}

# 入れ替えるべき pid だけを返す。動いているのが自分のものか、別の clone のものか、
# 判別できないときは空（＝そのまま使う）。
stale_bridge_pid() {
  local owner
  owner=$(bridge_owner)
  case "$owner" in
    stale) listening_bridge_pid ;;
    other:*)
      echo "warning: :${BRIDGE_PORT} は別の host-bridge が使っています（${owner#other:}）。" >&2
      echo "         このプロジェクトもそれを使います。入れ替えるなら ios-dev-sandbox restart-bridge。" >&2 ;;
  esac
  return 0
}

stop_stale_bridge() {
  local pid=$1 waited=0
  echo "取り残された host-bridge (pid ${pid}) を入れ替えます..."
  kill "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null; do
    sleep 0.2
    waited=$((waited + 1))
    if [ "$waited" -ge 50 ]; then
      die "host-bridge (pid ${pid}) が止まりません。手で終了してからやり直してください"
    fi
  done
}

wait_for_free_bridge_port() {
  local waited=0
  while [ -n "$(listening_bridge_pid)" ]; do
    sleep 0.2
    waited=$((waited + 1))
    if [ "$waited" -ge 50 ]; then
      die ":${BRIDGE_PORT} が空きません。掴んでいるプロセスを手で終了してください"
    fi
  done
}

start_bridge() {
  [ -x "$IOS_DEV_SANDBOX_BRIDGE" ] || return 0
  [ -f "$HOST_CLI_TEAM" ] || return 0

  if [ -n "$(bridge_health)" ]; then
    local stale
    stale=$(stale_bridge_pid)
    if [ -z "$stale" ]; then
      return 0
    fi
    stop_stale_bridge "$stale"
  fi

  mkdir -p "$LOG_DIR"
  local log="$LOG_DIR/host-bridge.log"
  echo "host-bridge を :$BRIDGE_PORT で起動します..."
  # ホスト CLI のラッパーは ios-dev-sandbox を PATH から呼ぶが、ブリッジは起動したシェルの
  # PATH を継ぐ。無いと黙って cwd（= workspace）に落とすので、自分の置き場を渡す。
  #
  # 秘密は外して起動する。ブリッジは使わないのに、cmd_run 経由だと
  # export_runtime_env が exec の直前に export した値を継ぎ、CommandRunner が
  # それをそのまま全ホスト CLI の子プロセスへ渡してしまう（起動経路によって
  # 漏れたり漏れなかったりする）。
  #
  # 127.0.0.1 で待ち受ける。サンドボックスからは host.docker.internal 経由でも
  # ループバックに届くので 0.0.0.0 は要らず、開けると同じ LAN の別マシンから
  # /health が読める。
  env -u IOS_DEV_SANDBOX_CLAUDE_TOKEN \
      -u IOS_DEV_SANDBOX_COPILOT_TOKEN \
      IOS_DEV_SANDBOX_BIN_DIR="$SELF_DIR" \
  nohup "$IOS_DEV_SANDBOX_BRIDGE" --host 127.0.0.1 --port "$BRIDGE_PORT" \
    --cli-config "$(resolve_host_cli)" --cli-local-config "$HOST_CLI_LOCAL" \
    --mcp-config "$HOST_MCP_TEAM" --mcp-local-config "$HOST_MCP_LOCAL" \
    --oauth-dir "$SECRETS_DIR/mcp-oauth" \
    --token-dir "$MCP_TOKEN_DIR" \
    >"$log" 2>&1 &
  for _ in $(seq 1 50); do
    [ -n "$(bridge_health)" ] && return 0
    sleep 0.2
  done
  die "host-bridge が起動しません（$log を参照）"
}

# 動いているブリッジは allowlist と host-mcp.json を起動時に読んだきりなので、
# 設定を反映するには入れ替えるしかない。apply からも呼ぶ。
restart_bridge() {
  [ -x "$IOS_DEV_SANDBOX_BRIDGE" ] || die "host-bridge がありません: $IOS_DEV_SANDBOX_BRIDGE"
  [ -f "$HOST_CLI_TEAM" ] || die "チーム標準の allowlist がありません: $HOST_CLI_TEAM"
  # --host を決め打ちにしない。0.0.0.0 で待ち受けていた頃のプロセスが残っていても
  # 止められるようにする（残ると新しい方が起動できない）。
  pkill -f 'host-bridge --host' 2>/dev/null || true
  wait_for_free_bridge_port
  start_bridge
}

cmd_restart_bridge() {
  restart_bridge
  local health
  health=$(bridge_health)
  [ -n "$health" ] || die "ブリッジが起動しません"
  printf '%s\n' "$health"
}
