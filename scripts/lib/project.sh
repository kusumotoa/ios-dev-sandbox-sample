# 作業ディレクトリから、対応するサンドボックスと設定の置き場を特定する。

sandbox_workspace() {
  sbx ls --json 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for sandbox in data.get("sandboxes", []):
    if sandbox.get("name") == sys.argv[1]:
        workspaces = sandbox.get("workspaces", [])
        if workspaces:
            primary = workspaces[0]
            for suffix in (":ro", ":rw"):
                if primary.endswith(suffix):
                    primary = primary[: -len(suffix)]
            print(primary)
        break
' "$1" 2>/dev/null || true
}

require_sbx() {
  command -v sbx >/dev/null || die "sbx がありません（brew install docker/tap/sbx）"
}

# sbx ls の失敗と「存在しない」は同じ空になる。先に ls の応答を確かめないと、
# 一瞬の不応答で作成パスに落ちて既存のサンドボックスに衝突する。
require_sbx_ls() {
  require_sbx
  sbx ls --json >/dev/null 2>&1 || die "\
sbx ls が応答しません（sandboxd が起動中か、応答していません）
'sbx ls' が通ることを確認してから、もう一度実行してください"
}

# 全て非 ASCII の名前では空になる（tr はバイト単位）。
path_slug() {
  local slug
  slug=$(basename "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9.-' '-')
  slug="${slug#"${slug%%[a-z0-9]*}"}"          # 先頭に続く . と - を落とす
  while [ -n "$slug" ]; do                     # 末尾も、1 文字ではなく続く限り全部
    case "$slug" in
      *[a-z0-9]) break ;;
      *) slug="${slug%?}" ;;
    esac
  done
  printf '%s' "$slug"
}

path_hash() {
  printf '%s' "$1" | shasum | cut -c1-"${2:-8}"
}

base_name() {
  local base
  base=$(path_slug "$1")
  # パスから作る。固定の語幹だと全ディレクトリが同名になり衝突判定が壊れる。
  [ ${#base} -ge 2 ] || base="sbx-$(path_hash "$1")"
  printf '%s' "$base"
}

# サンドボックスは agent ごとに立つので名前で分ける（sbx 上で一意が要る）。
# project ディレクトリは workspace 単位で共有し、agent の違いはその中で分ける。
sandbox_name() {
  local real base
  real=$(pwd -P)                               # write_project_env が記録するパス
  base=$(base_name "$real")
  # 既定の claude は接尾辞なし。既存のサンドボックスを保つ。
  [ "$AGENT" = claude ] || base="$base-$AGENT"

  local owner
  owner=$(sandbox_workspace "$base")

  if [ -z "$owner" ] || [ "$owner" = "$real" ]; then
    echo "$base"
    return 0
  fi

  local suffix
  suffix=$(path_hash "$real" 6)
  echo "サンドボックス名 '$base' は $owner が使っています" >&2
  echo "このディレクトリには '$base-$suffix' を使います" >&2
  echo "$base-$suffix"
}

# 利用者が書く read-only-dirs と 1 文字違いにしない。取り違えると project_dir が
# digest 付きに退避して会話履歴を見失う。
CLAIM_FILE=.claimed-workspace

claim_file() {
  printf '%s/%s' "$1" "$CLAIM_FILE"
}

claimed_workspace() {
  local file
  file=$(claim_file "$1")
  [ -f "$file" ] || return 0
  sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;p;}' "$file"
}

# 宣言は <proj>/<agent>/.sbxenv.yaml。探す先は AGENTS_ALL の下だけ。* にすると
# artifacts/ も拾い、そこはサンドボックスの中から書けるので、置かれた偽の宣言で
# project ディレクトリの解決を騙せてしまう。
declaration_files() {
  local agent
  DECLARATIONS=()
  for agent in $AGENTS_ALL; do DECLARATIONS+=("$1/$agent/.sbxenv.yaml"); done
}

has_declaration() {
  local f
  declaration_files "$1"
  for f in "${DECLARATIONS[@]}"; do
    if [ -f "$f" ]; then return 0; fi
  done
  return 1
}

declares_workspace() {
  local expected
  expected=$(yaml_scalar workspace "$2")
  declaration_files "$1"
  grep -qxF "$expected" "${DECLARATIONS[@]}" 2>/dev/null
}

claim_project_dir() {
  mkdir -p "$1"
  printf '%s\n' "$2" > "$(claim_file "$1")"
}

project_dir() {
  local real base plain hashed claimed
  real=$(pwd -P)
  base=$(base_name "$real")
  plain="$PROJECTS_DIR/$base"
  hashed="$PROJECTS_DIR/$base-$(path_hash "$real")"

  local out
  claimed=$(claimed_workspace "$plain")
  if [ -n "$claimed" ]; then
    if [ "$claimed" = "$real" ]; then out=$plain; else out=$hashed; fi
  elif has_declaration "$plain"; then
    if declares_workspace "$plain" "$real"; then out=$plain; else out=$hashed; fi
  else
    out=$plain
  fi
  echo "$out"
}

# agent ごとのもの（宣言・作成時の指紋・state）の置き場。
# project ディレクトリが分かっているなら渡す（project_dir を引き直さない）。
agent_dir() {
  printf '%s/%s' "${1:-$(project_dir)}" "$AGENT"
}

# 追加で読ませるディレクトリ。他の local/* と同じくマシン単位で、全プロジェクトに読み取り専用で
# マウントする（そのマシンにある clone のパスなので、プロジェクトごとに分ける意味が無い）。
READ_ONLY_DIRS="$ETC_DIR/read-only-dirs.txt"

read_only_dirs() {
  [ -f "$READ_ONLY_DIRS" ] || return 0
  grep -Ev '^[[:space:]]*(#|$)' "$READ_ONLY_DIRS" || true
}

validate_read_only_dirs() {
  local ws bad=0
  while IFS= read -r ws; do
    case "$ws" in
      /*) [ -d "$ws" ] || { echo "error: read-only-dirs のパスがありません: $ws" >&2; bad=1; } ;;
      *)  echo "error: read-only-dirs は絶対パスで書きます: $ws" >&2; bad=1 ;;
    esac
  done < <(read_only_dirs)
  [ "$bad" -eq 0 ] || die "直すファイル: $READ_ONLY_DIRS"
}
