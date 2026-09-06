# サンドボックスを作る・入る・作り直す。

cmd_run() {
  require_sbx_ls

  local project
  project=$(find_xcode_project) || die "\
$PWD に .xcodeproj / .xcworkspace がありません
ios-dev-sandbox は iOS プロジェクトのディレクトリで実行してください"

  export_runtime_env
  # 認証が要る agent は先に止める。無いまま作ると、実際に使おうとした瞬間まで
  # 気づかない（claude は /login があるので警告だけ）。
  if [ "$AGENT" = copilot ] && [ -z "$IOS_DEV_SANDBOX_COPILOT_TOKEN" ]; then
    die "\
copilot の認証がありません: $COPILOT_TOKEN_FILE
書き込み用 PAT に Copilot Requests（Account タブ）を足して、同じ値を
ios-dev-sandbox copilot-login で登録してください。書き込み用 PAT が
組織所有なら Copilot Requests を足せないので、個人アカウント所有で
もう 1 本作ります（docs/instructions/agents/copilot.md）"
  fi
  local developer_dir
  developer_dir=$(resolve_developer_dir)
  start_headless_xcode "$developer_dir" "$project"
  start_bridge

  local name proj_dir agent_dir
  name=$(sandbox_name)
  proj_dir=$(project_dir)
  agent_dir=$(agent_dir "$proj_dir")

  validate_read_only_dirs

  local existing_workspace
  existing_workspace=$(sandbox_workspace "$name")

  if [ -z "$existing_workspace" ] \
      && [ ! -x "$developer_dir/usr/bin/mcp-server" ] \
      && ! pgrep -xq Xcode; then
    echo "warning: 選択中の Xcode はヘッドレス非対応で、Xcode アプリも起動していません。" >&2
    echo "         Xcode を開くまで、サンドボックス内の Xcode ツールは失敗します。" >&2
  fi

  mkdir -p "$agent_dir/state" "$proj_dir/artifacts"
  write_sbxenv "$agent_dir" "$name"

  if [ -n "$existing_workspace" ]; then
    warn_stale_sandbox "$agent_dir" "$name"
  else
    claim_project_dir "$proj_dir" "$(pwd -P)"
    sandbox_fingerprint "$agent_dir" > "$agent_dir/$FINGERPRINT_FILE"
  fi
  exec sbx env run "$agent_dir" "$@"
}

cmd_apply() {
  require_sbx_ls
  local name
  name=$(sandbox_name)
  if [ -n "$(sandbox_workspace "$name")" ]; then
    echo "サンドボックス '$name' を作り直して設定を反映します"
    echo "会話履歴はホストに残りますが、自動では再開しません。続きからやるには"
    case "$AGENT" in
      codex) echo "コンテナ内で codex resume を実行してください" ;;
      copilot) echo "コンテナ内で copilot の履歴から選び直してください" ;;
      *) echo "コンテナ内で /resume を選ぶか、claude --continue を実行してください" ;;
    esac
    sbx rm "$name" --force
  fi
  # start_bridge は健全なブリッジがあれば何もしないので、入れ替えないと新しい
  # サンドボックスが古い /health を見て古い顔ぶれを登録し、指紋だけ新しくなって
  # 「変わっています」の警告が消える。
  restart_bridge
  cmd_run "$@"
}

init_gateway_local() {
  if [ -f "$GATEWAY_LOCAL" ]; then
    echo "作成済み: $GATEWAY_LOCAL"
    return 0
  fi
  mkdir -p "$(dirname "$GATEWAY_LOCAL")"
  cat > "$GATEWAY_LOCAL" <<'EOF'
{
  "_comment": "LiteLLM ゲートウェイ経由で使う人だけ書きます。書き方は docs/instructions/litellm.md。host が空なら何も起きません。",
  "host": "",
  "braveSearchPath": "",
  "codexModel": ""
}
EOF
  echo "$GATEWAY_LOCAL を作成しました（ゲートウェイを使う人だけ host を書きます）"
}

cmd_init() {
  local proj_dir
  proj_dir=$(project_dir)
  claim_project_dir "$proj_dir" "$(pwd -P)"
  echo "$proj_dir を確保しました"

  init_gateway_local
}

# artifacts はプロジェクト共通。どの agent のサンドボックスから呼ばれても同じ場所を返す。
cmd_artifacts_path() {
  local proj_dir
  proj_dir=$(project_dir)
  declares_workspace "$proj_dir" "$(pwd -P)" || die "\
ここから作られたサンドボックスがありません: $(pwd -P)
artifacts-path はワークスペースの中で実行してください"
  mkdir -p "$proj_dir/artifacts"
  printf '%s\n' "$proj_dir/artifacts"
}
