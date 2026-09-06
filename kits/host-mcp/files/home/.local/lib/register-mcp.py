"""MCP サーバーを agent の設定ファイルへ登録する。

claude は ~/.claude.json、copilot は $COPILOT_HOME/mcp-config.json（ともに JSON の
mcpServers）、codex は ~/.codex/config.toml（TOML）。書式が違うだけで、登録する
中身は同じ。

    register-mcp bridge  <agent> <path> <base URL>
        host-bridge の /health を読み、出ているサーバーを全部登録する。

    register-mcp agent   <書く相手> <path> <名前> <コマンド> [引数...]
        別のエージェントを stdio の MCP として 1 つ登録する。

    register-mcp http    <agent> <path> <名前> <URL> <ヘッダ名> <ヘッダ値>
        HTTP の MCP を 1 つ登録する。

    register-mcp gateway <path> <名前> <URL>
        ゲートウェイの MCP を 1 つ登録する（codex 専用）。codex はヘッダの値を直接
        書けず、環境変数の「名前」を書く（env_http_headers）。

    register-mcp provider <path> <ゲートウェイのホスト> [モデル名]
        codex の推論の宛先をゲートウェイへ向ける（codex 専用）。
"""
import json
import os
import re
import sys
import tempfile
import urllib.request

BRIDGE_TIMEOUT = 10


def server_names(base: str) -> list[str]:
    with urllib.request.urlopen(f"{base}/health", timeout=BRIDGE_TIMEOUT) as response:
        return sorted(json.load(response).get("servers", []))


def _write(path: str, text: str) -> None:
    """別ファイルに書いてから差し替える。open(path, "w") は先に truncate するので、
    途中で落ちると MCP の登録や codex の provider 設定ごと空になる。"""
    directory = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=directory)
    try:
        with os.fdopen(fd, "w") as handle:
            handle.write(text)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def _load_json(path: str) -> dict:
    return json.load(open(path)) if os.path.exists(path) else {}


def _write_json(agent: str, path: str, servers: dict) -> None:
    """copilot は type と tools を省けない。claude はどちらも書かない。"""
    config = _load_json(path)
    known = config.setdefault("mcpServers", {})
    for name, spec in servers.items():
        if agent == "copilot":
            spec = {"tools": ["*"],
                    "type": "local" if "command" in spec else "http",
                    **spec}
        known[name] = spec
    _write(path, json.dumps(config, ensure_ascii=False, indent=2))


def _drop_tables(existing: str, prefixes: list[str]) -> list[str]:
    """同名の見出しとその中身を落とす。TOML は見出しの前に空白を許すので lstrip して
    から見る。残すと同じ表を 2 回宣言した TOML になり、codex が設定ごと読めなくなる。"""
    kept, skip = [], False
    for line in existing.split("\n"):
        head = line.lstrip()
        if head.startswith("["):
            skip = any(head.startswith(p) for p in prefixes)
        if not skip:
            kept.append(line)
    return kept


def _write_codex(path: str, names: list[str], tables: str) -> None:
    prefixes = [p for n in names for p in (f"[mcp_servers.{n}]", f"[mcp_servers.{n}.")]
    existing = open(path).read() if os.path.exists(path) else ""
    out = "\n".join(_drop_tables(existing, prefixes)).rstrip() + "\n"
    _write(path, out + tables)


def register_bridge(agent: str, path: str, base: str) -> None:
    names = server_names(base)
    if not names:
        print("[host-mcp] 登録するサーバーがありません", file=sys.stderr)
        return
    if agent != "codex":
        _write_json(agent, path, {
            name: {
                "type": "http",
                "url": f"{base}/mcp/{name}",
            }
            for name in names})
    else:
        tables = "".join(
            f'\n[mcp_servers.{name}]\n'
            f'type = "http"\n'
            f'url = "{base}/mcp/{name}"\n'
            for name in names)
        _write_codex(path, names, tables)
    print(f"[host-mcp] MCP を登録しました: {' '.join(names)}")


def register_agent(agent: str, path: str, name: str, argv: list[str]) -> None:
    if agent != "codex":
        _write_json(agent, path, {name: {"command": argv[0], "args": argv[1:]}})
    else:
        args = ", ".join(json.dumps(a) for a in argv[1:])
        _write_codex(path, [name],
                     f'\n[mcp_servers.{name}]\n'
                     f'command = {json.dumps(argv[0])}\n'
                     f'args = [{args}]\n')
    print(f"[host-mcp] {name} を MCP として登録しました")


def register_http(agent: str, path: str, name: str, url: str,
                  header: str, value: str) -> None:
    _write_json(agent, path, {name: {"type": "http", "url": url,
                                     "headers": {header: value}}})
    print(f"[host-mcp] {name} を登録しました")


def register_provider(path: str, host: str, model: str = "") -> None:
    """推論の宛先をゲートウェイへ向ける。config.toml には MCP の登録も入るので
    上書きせず、既存を保ったまま差し替える。model を書かなければ codex の既定名を使う
    （空文字を書くと壊れる）。"""
    existing = open(path).read() if os.path.exists(path) else ""
    lines = _drop_tables(existing, ["[model_providers.llm_gateway]",
                                    "[model_providers.llm_gateway."])
    # 落とすのはトップレベルの model / model_provider だけ。表の中まで消すと
    # [profiles.<名前>] のモデル指定を巻き添えにする。
    head = next((i for i, l in enumerate(lines) if l.lstrip().startswith("[")), len(lines))
    lines = [l for i, l in enumerate(lines)
             if i >= head or not re.match(r"\s*(model|model_provider)\s*=", l)]

    top = ['model_provider = "llm_gateway"']
    if model:
        top.insert(0, f"model = {json.dumps(model)}")
    # トップレベルのキーは最初の見出しより前に置く。後ろに書くとその表の中身になる。
    head = next((i for i, l in enumerate(lines) if l.lstrip().startswith("[")), len(lines))
    body = "\n".join(lines[:head] + top + lines[head:]).rstrip() + "\n"

    _write(path, body + f'\n[model_providers.llm_gateway]\n'
                        f'name = "LLM gateway"\n'
                        f'base_url = "https://{host}"\n'
                        f'env_key = "LITELLM_API_KEY"\n')
    print(f"[host-mcp] codex をゲートウェイ経由にしました"
          f"{f'（model: {model}）' if model else '（model 未指定 — codex の既定名で要求します）'}")


def register_gateway(path: str, name: str, url: str) -> None:
    _write_codex(path, [name],
                 f'\n[mcp_servers.{name}]\n'
                 f'url = {json.dumps(url)}\n'
                 f'env_http_headers = {{ "x-litellm-api-key" = "LITELLM_MCP_AUTH_HEADER" }}\n'
                 f'enabled = true\n')
    print(f"[host-mcp] {name} を登録しました")


def main() -> int:
    match sys.argv[1:]:
        case ["bridge", agent, path, base]:
            action = lambda: register_bridge(agent, path, base)
        case ["agent", agent, path, name, *argv] if argv:
            action = lambda: register_agent(agent, path, name, argv)
        case ["http", agent, path, name, url, header, value]:
            action = lambda: register_http(agent, path, name, url, header, value)
        case ["gateway", path, name, url]:
            action = lambda: register_gateway(path, name, url)
        case ["provider", path, host, *rest] if len(rest) <= 1:
            action = lambda: register_provider(path, host, rest[0] if rest else "")
        case _:
            print(__doc__.strip(), file=sys.stderr)
            return 2
    try:
        action()
    except Exception as error:
        # サーバーの実体が無くても、設定が壊れていても、サンドボックスの作成は
        # 阻害しない。登録できなかったことだけ伝える。
        print(f"[host-mcp] 登録できません（{sys.argv[1]}）: {error}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
