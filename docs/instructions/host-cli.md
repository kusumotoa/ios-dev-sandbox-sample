# ホスト専用 CLI を増やす

サンドボックスは Linux なので、macOS でしか動かない CLI はそのままでは使えません。

この手順書のファイルにコマンド名を書いておくと、サンドボックスの中に同じ名前のコマンドが用意されます。それを実行すると macOS ホスト側で本物が動き、出力がサンドボックスへ返ります。ここに書いていないコマンドは、サンドボックスからは呼べません。

## どちらに書くか

| | 置き場所 | 配布 |
|---|---|---|
| **チーム標準**：全員のマシンに同じ形で存在し、設定がこのリポジトリだけで完結するもの | このリポジトリの `share/host-cli.json` | git pull && mise run setup で全員に |
| **マシン固有**：それ以外 | `<clone>/local/host-cli.json` | このマシンだけ |

## チーム標準に足す

```json
{
  "schemaVersion": 1,
  "commands": [
    { "name": "ios-dev-sandbox-gpg-sign", "path": "@@BIN@@/ios-dev-sandbox-gpg-sign",
      "allowedSubcommands": ["sign", "keyid"] }
  ]
}
```

`@@BIN@@` はこのリポジトリが同梱するコマンド専用のプレースホルダで、起動時に
`scripts/` の絶対パスへ置き換わります。**チーム標準（`share/host-cli.json`）でしか
展開されません。** マシン固有の `local/host-cli.json` にはそのまま渡るので、
そちらでは絶対パスを書いてください（相対パスや `@@BIN@@` は無視され、起動ログに
警告が出るだけです）。ホストに入れた他のツール（brew の swiftlint など）も同じく
絶対パスです。

`schemaVersion` は省略できます。

## マシン固有に足す・上書きする

このファイルは無くても構いません。

```json
{
  "paths": { "some-team-tool": "/Users/me/src/some-team-tool/.build/release/some-team-tool" },
  "extra": [
    { "name": "my-tool", "path": "/usr/local/bin/my-tool", "allowedSubcommands": ["run"] }
  ]
}
```

- `paths`：チーム標準コマンドのバイナリパスを差し替えます。手元でビルドした版を試す、別の場所に入れた、といった場合です。差し替えても `allowedSubcommands` はチーム標準のものが効きます
- `extra`：このマシンだけのコマンドを追加します。チーム標準と同名のエントリは**無視され、警告が出ます**。ローカル設定からチーム標準の `allowedSubcommands` を緩めることはできません

## allowedSubcommands の書き方

省略すると全サブコマンドを許可します。値は 2 通りです。

| 形式 | 意味 |
|---|---|
| 配列 `["status", "logs"]` | 第 1 階層の語だけを見ます。空配列は全拒否 |
| オブジェクト `{"files": ["list", "read"]}` | 第 1 階層の語ごとに、許可する第 2 階層の語を指定します。キーに無い語は拒否、値が空配列ならその語の下は全許可 |

オブジェクト形式は、読み取りと書き込みが同じ語の下に混在するコマンド（`files list` と `files rm`）向けです。

どちらの形式でも、書いていないものは全部拒否です。許可の判定は `Sources/HostBridge/BridgeConfiguration.swift` の `SubcommandPolicy` が行います。何を許すかの基準は Xcode MCP のツール選定と揃えていて、ファイルやデータを書き換える操作と、任意のコードを実行できる操作は載せません。

サブコマンドは**引数の先頭**に置いてください。`mytool ui --device X` は通り、`mytool --json ui` のようにフラグが先頭に来る呼び出しは拒否されます。

## 反映されるまで

**マシン固有**（`local/host-cli.json`）は、編集して `ios-dev-sandbox restart-bridge` を実行すれば効きます。コマンドを増やした場合だけ、中継コマンドがサンドボックス作成時に置かれるものなので `ios-dev-sandbox apply` で作り直します。

**チーム標準**（`share/host-cli.json`）は PR で変えます。手元の clone を直接書き換えると自分のマシンでは効きますが、他のメンバーには配られません。マージ後、各自が `git pull && mise run setup` します。

そのコマンドを使うスキルは、チームで揃えるなら `share/skills/<name>/`、自分だけなら `local/skills/<name>/` に置いてください。読み取り専用でマウントされるので、編集は即座にサンドボックスへ届きます。
