# MCP サーバーを追加する

Xcode を含む MCP サーバーはすべて macOS ホスト側で動きます。この手順書のファイルに書いたものだけがサンドボックスへ渡されます。サンドボックスの中で MCP サーバーを起動する必要はありません。

## どこに書くか

| | 置き場所 | 配布 |
|---|---|---|
| チーム標準 | このリポジトリの `share/host-mcp.json`（PR レビュー） | git pull && mise run setup で全員に |
| マシン固有 | `local/host-mcp.json`（チーム標準と同名は定義不可） | このマシンだけ |

```json
{
  "servers": {
    "figma-desktop": { "url": "http://127.0.0.1:3845/mcp" },
    "mytool":        { "command": ["npx", "@example/mcp"], "tools": ["render"] },
    "atlassian":     { "url": "https://mcp.atlassian.com/v1/mcp", "auth": "oauth" },
    "myapi":         { "url": "https://api.example.com/mcp", "auth": "token" }
  }
}
```

- `url`：ホストの localhost で待つアプリや、リモートの streamable HTTP へ中継します
- `command`：ホストで stdio MCP を子プロセスとして起動して中継します
- `tools`：許可するツール名の列挙。**省略するとそのサーバーの全ツールを通します。** tools/list の絞り込みと tools/call の拒否の両方に効きます
- `auth: oauth`：認可が要るリモート用。`ios-dev-sandbox mcp-auth <名前>` をホストで 1 回実行してブラウザで認可します。トークンはホストに置かれ（0600）、サンドボックスには入りません
- `auth: token`：発行済みトークンを渡す場合。`ios-dev-sandbox mcp-token <名前>` で登録します。**認可サーバーが動的クライアント登録に対応していない相手**（GitHub など）はこちらを使います。置き場所と扱いは oauth と同じで、コンテナには入りません

MCP サーバーの登録・通信の許可・トークンの受け渡しは、サンドボックスを作るときに全部自動で行われます。**エージェント側の設定ファイル（`~/.claude.json` など）を自分で書く必要はありません。**

サーバーの実体（Figma Desktop など）が起動していなくても、サンドボックスは作れます。使おうとしたときに接続失敗と出るだけです。

## どのサーバーが絞られているか

```bash
ios-dev-sandbox tools              # サーバーごとの制限状況
ios-dev-sandbox tools xcode        # そのサーバーの許可ツールを列挙
```

`ios-dev-sandbox status` の `mcp servers:` 行にも出ます。

```
mcp servers:     atlassian(全許可) figma-desktop(全許可) xcode(38)
```

**書き込み系のツールを持つサーバーは、絞るかどうかをサーバーごとに判断します。** `tools` 無しで載せると、そのサーバーにできること全部がエージェントに開きます（トークンはホストに置かれエージェントからは見えませんが、ブリッジが注入して実行します）。読むだけにしたいなら、読み取り系のツール名だけを列挙します。

チーム標準の `atlassian` は絞っていません。削除の手段が無く、更新されても Confluence 側で前の版に戻せるためです。

`xcode` は 38 個に絞ってありますが、その中の `BuildProject` / `RunAllTests` はホスト側でビルドとテストを走らせます。これは意図した機能で、境界の考え方は [decisions.md](../decisions.md) に書いてあります。

## 反映

| 変えたもの | 反映のしかた |
|---|---|
| 既存サーバーの url・command・tools | `ios-dev-sandbox restart-bridge` |
| サーバーの追加・削除 | `restart-bridge` に加えて `ios-dev-sandbox apply`（コンテナへの登録は作成時固定のため） |

## 制約と境界

- `url:` の外向き接続はホスト側の足で行われ、サンドボックスのネットワークポリシーの対象外です（[図](network-policy.md)）。**host-mcp.json に何を載せるかがそのまま境界の設定**なので、チーム標準は PR レビューを通します
- ツールの応答が SSE で返る場合は最後の応答だけを取り出します。長時間の購読ストリームには対応しません


## OAuth の認証が切れたとき

アクセストークンの期限切れは**ブリッジが自動でリフレッシュ**します。何もしなくてよいです。

リフレッシュトークン自体が失効したときだけ、ホストで認可し直す必要があります。**ブラウザでの認可はサンドボックスの中からはできません。**

```bash
ios-dev-sandbox mcp-auth atlassian
```

動いているサンドボックスにも即座に効きます（作り直しは不要）。コンテナ内のエージェントには、この操作を促すエラーが返ります。

## 発行済みトークンを使うサーバー（`auth: token`）

`auth: oauth` は RFC 9728/8414 の discovery のあと、動的クライアント登録で client_id を取ります。これに対応していない認可サーバーでは使えません。その場合は自分でトークンを発行して登録します。

```bash
ios-dev-sandbox mcp-token <名前>
```

標準入力から読むので、端末にもシェル履歴にも `ps` の引数にも残りません。`~/.config/ios-dev-sandbox/secrets/mcp-tokens/<名前>` に 0600 で置かれます。

**入れ替えても再起動は要りません。** ブリッジは 401 を受けたときにファイルを読み直します。

登録漏れは `ios-dev-sandbox status` の `未登録:` に出ます。

