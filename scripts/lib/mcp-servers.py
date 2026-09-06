"""host-mcp.json（チーム標準 + マシン固有）を読んで、聞かれたことだけを出す。

    mcp-servers.py <team> <local> counts
    mcp-servers.py <team> <local> names
    mcp-servers.py <team> <local> unauthorized <oauth-dir> <token-dir>
    mcp-servers.py <team> <local> tools [名前]

同じ読み方を shell 側の 4 か所に書き直していたので、ここ 1 つにまとめてある。
"""
import json
import os
import sys


def load_servers(team: str, local: str) -> dict:
    """名前 -> (定義, どちらのファイルか)。

    同名はチーム標準が勝つ。ブリッジ側（ProxyConfiguration.merged）と同じ規則で、
    そちらは local を無視した旨を warning に出す。
    """
    servers: dict[str, tuple[dict, str]] = {}
    for path in (team, local):
        try:
            declared = json.load(open(path)).get("servers", {})
        except Exception:
            continue
        for name, spec in declared.items():
            servers.setdefault(name, (spec, path))
    return servers


def counts(servers: dict) -> int:
    """status の 1 行用。tools を書いていなければ (全許可) と出す。"""
    for name in sorted(servers):
        tools = servers[name][0].get("tools")
        print(f"{name}({len(tools)})" if tools is not None else f"{name}(全許可)")
    return 0


def names(servers: dict) -> int:
    print("\n".join(sorted(servers)))
    return 0


def unauthorized(servers: dict, oauth_dir: str, token_dir: str) -> int:
    """認可・トークンの登録が済んでいないサーバーを "<種類>\t<名前> ..." で出す。"""
    missing: dict[str, list[str]] = {"oauth": [], "token": []}
    for name in sorted(servers):
        auth = servers[name][0].get("auth")
        if auth == "oauth" and not os.path.exists(f"{oauth_dir}/{name}.json"):
            missing["oauth"].append(name)
        elif auth == "token" and not os.path.exists(f"{token_dir}/{name}"):
            missing["token"].append(name)
    for kind, found in missing.items():
        if found:
            print(f"{kind}\t{' '.join(found)}")
    return 0


def tools(servers: dict, wanted: str) -> int:
    """引数なしで全サーバーの制限状況、名前を付ければそのサーバーの許可ツール。"""
    if wanted:
        if wanted not in servers:
            print(f"error: そのような MCP サーバーはありません: {wanted}", file=sys.stderr)
            print(f"       あるのは: {' '.join(sorted(servers))}", file=sys.stderr)
            return 1
        spec, path = servers[wanted]
        allowed = spec.get("tools")
        if allowed is None:
            print(f"{wanted} は tools を書いていないので全ツールを通します（{path}）")
            print("絞るには tools に許可するツール名を列挙します。tools/list の絞り込みと")
            print("tools/call の拒否の両方に効きます。")
        else:
            print("\n".join(allowed))
        return 0

    width = max((len(name) for name in servers), default=0)
    for name in sorted(servers):
        allowed = servers[name][0].get("tools")
        state = f"{len(allowed)} 個に制限" if allowed is not None else "全ツールを通す（tools 未指定）"
        print(f"  {name:{width}}  {state}")
    print()
    print("そのサーバーの許可ツールを見る: ios-dev-sandbox tools <名前>")
    return 0


def main() -> int:
    if len(sys.argv) < 4:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    team, local, action = sys.argv[1:4]
    rest = sys.argv[4:]
    servers = load_servers(team, local)
    if action == "counts":
        return counts(servers)
    if action == "names":
        return names(servers)
    if action == "unauthorized":
        return unauthorized(servers, *rest)
    if action == "tools":
        return tools(servers, rest[0] if rest else "")
    print(f"mcp-servers.py: 知らない指定: {action}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
