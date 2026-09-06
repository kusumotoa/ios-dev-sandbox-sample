"""公開から一定期間経った最新の gh リリースを 1 つ選ぶ。

標準入力は GitHub の releases API の JSON。引数は寝かせる日数。
条件を満たすものが無ければ何も出力しない（呼び手が既存版のままにする）。
npm/pnpm の minimumReleaseAge と同じ考え方で、公開直後に差し替えられた版を
掴まないようにする。

**何があっても異常終了しない。** 呼び手はこれをパイプの最後段に置くので、
ここで例外が飛ぶと `set -e` がサンドボックスの作成ごと止めてしまう。gh が
古いままなのは困らないが、作成できないのは困る。選べなければ黙って何も
出さず、終了コードは常に 0。
"""

import datetime
import json
import sys


def main() -> int:
    try:
        days = int(sys.argv[1])
        releases = json.load(sys.stdin)
    except Exception:
        return 0
    if not isinstance(releases, list):
        return 0
    cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)

    best = None
    for release in releases:
        try:
            if release.get("draft") or release.get("prerelease"):
                continue
            tag = release.get("tag_name")
            stamp = release.get("published_at")
            if not tag or not stamp:
                continue
            published = datetime.datetime.fromisoformat(str(stamp).replace("Z", "+00:00"))
            # GitHub は常に Z 付きだが、素の日時でも比較できるようにしておく
            # （naive と aware を比べると TypeError で落ちる）。
            if published.tzinfo is None:
                published = published.replace(tzinfo=datetime.timezone.utc)
        except Exception:
            # 壊れた 1 件で全体を落とさない。
            continue
        # 一覧の並び順に頼らない。API が並べるのは created_at で、ここで見て
        # いるのは published_at なので、最大値を自分で選ぶ。
        if published <= cutoff and (best is None or published > best[0]):
            best = (published, tag)

    if best:
        tag = best[1]
        # lstrip は文字集合を剥がすので使わない。先頭の "v" だけ落とす。
        print(tag[1:] if tag.startswith("v") else tag)
    return 0


if __name__ == "__main__":
    sys.exit(main())
