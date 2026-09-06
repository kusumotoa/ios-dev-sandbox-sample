# ブランチ保護を掛ける

`share/` と `kits/` に置くファイルは**サンドボックスの境界そのもの**です。どのコマンドをホストで実行してよいか、どこへ通信してよいかを決めています。レビューなしに変わってはいけません。

org に置いてメンバーへ配るなら、`main` へ直接 push できないようにしておきます。

## コマンドで設定する

```bash
gh api -X PUT repos/<owner>/<repo>/branches/main/protection --input - <<'JSON'
{
  "required_pull_request_reviews": { "required_approving_review_count": 1 },
  "enforce_admins": true,
  "required_status_checks": null,
  "restrictions": null
}
JSON
```

4 つのキーはすべて必須で、使わないものは `null` を明示します（[API 仕様](https://docs.github.com/en/rest/branches/branch-protection#update-branch-protection)）。

## Web から設定する

Settings → Branches → Add branch ruleset で、`main` に対して次を有効にします。

- Require a pull request before merging（承認 1 以上）
- Do not allow bypassing the above settings

2 つ目は**管理者にも適用する**という意味です。これが無いと、境界を書き換えられる立場の人がレビューを通さずに変更でき、形だけの保護になります。

## private リポジトリに掛ける場合

org が GitHub Team 以上のプランである必要があります。個人の無料プランでは API が `403 Upgrade to GitHub Pro` を返します。
