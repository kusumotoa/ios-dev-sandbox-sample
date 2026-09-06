#!/usr/bin/env python3
"""claude-config kit の Python 側。YAML に一行文で埋めると読めず、検査もできない。

サブコマンド:
    merge-settings <team settings.json> <dest settings.json>
        チーム標準に書いたキーだけを上書きする。
"""
import json
import os
import sys
import tempfile


def write_json(path: str, data: dict) -> None:
    """書き損じで設定を失わないよう、別ファイルに書いてから差し替える。open(path, "w")
    は先に truncate するので、途中で落ちると空のまま残る。"""
    directory = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=directory)
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(data, handle, ensure_ascii=False, indent=2)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def deep_merge(current: dict, team: dict) -> dict:
    """入れ子の中まで、チーム標準に書いたキーだけを上書きする。最上位だけ置き換えると、
    env に 1 つ足しただけで sbx が入れた ANTHROPIC_BASE_URL ごと消える。"""
    merged = dict(current)
    for key, value in team.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


def merge_settings(team_path: str, dest_path: str) -> int:
    team = json.load(open(team_path))
    current = json.load(open(dest_path)) if os.path.exists(dest_path) else {}
    write_json(dest_path, deep_merge(current, team))
    print(f"[claude-config] settings.json に {' '.join(team)} を入れました")
    return 0


def main() -> int:
    match sys.argv[1:]:
        case ["merge-settings", host_path, dest_path]:
            return merge_settings(host_path, dest_path)
        case _:
            print(__doc__.strip(), file=sys.stderr)
            return 2


if __name__ == "__main__":
    sys.exit(main())
