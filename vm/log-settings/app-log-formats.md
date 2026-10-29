# アプリケーションログの形式と DCR / テーブル定義の関係

AMA でアプリケーションログを Log Analytics に送るとき、ログの形式によって DCR とテーブル定義がどう変わるかの整理。
[README](README.md) のサンプル (テキストログ → `SampleApp_CL`) の補足資料。

出典 (2026-10 時点):

- [Collect text file from virtual machine with Azure Monitor](https://learn.microsoft.com/en-us/azure/azure-monitor/vm/data-collection-log-text)
- [Collect JSON file from virtual machine with Azure Monitor](https://learn.microsoft.com/en-us/azure/azure-monitor/vm/data-collection-log-json)
- [Sample data collection rules (DCRs)](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/data-collection-rule-samples)

「実機確認」と書いたもの以外はドキュメントからの整理。

## 結論

- **形式によって DCR は変わる**。変わるのは主に 3 か所:
  1. `log_file.format` (`text` / `json`)
  2. `stream_declaration` (AMA から入ってくる列の定義)
  3. `transform_kql` (入ってきた列を、テーブルの列に合わせる変換)
- **テーブル定義はキモの 1 つ**だが、それだけでは決まらない。データは次の 3 段で流れ、隣り合う段の列名と型が合っていないと値が入らない。

  ```
  ログファイル ─(AMA)─▶ 入力ストリーム ─(transform_kql)─▶ 出力 ─▶ カスタムテーブル
                       stream_declaration                         テーブルの列定義
  ```

  - テキスト形式なら、入力ストリームは**常に** `TimeGenerated / RawData / Computer / FilePath` の固定 4 列。
    中身をどの列に分けるかは **transform_kql とテーブル定義**で決まる
  - JSON 形式なら AMA が JSON をパースしてくれるので、**stream_declaration とテーブル定義**を JSON のキーに合わせるのがキモ
- テーブルにあって変換の出力に無い列は空のまま。変換の出力にあってテーブルに無い列は捨てられる (エラーにはならない)。
  そのため「取り込めているのに列が空」になりやすい。まず列名と型の一致を疑う

## 形式ごとの実装パターン

| ログの形式 | DCR の `format` | stream_declaration | transform_kql | テーブルの列 |
|-----------|-----------------|--------------------|---------------|--------------|
| 1 行 1 レコードのテキスト (このサンプル) | `text` | 固定 4 列 | 不要 (`source`) または `extract()` / `parse` で分割 | `TimeGenerated` + `RawData` (+ 切り出した列) |
| 区切り文字 (CSV / TSV など) | `text` | 固定 4 列 | `split()` で分割して型変換 | 分割後の列 (`RawData` は不要にできる) |
| 複数行 (スタックトレースなど) | `text` + `record_start_timestamp_format` | 固定 4 列 | 1 行テキストと同じ | 1 行テキストと同じ |
| JSON Lines (1 行 1 JSON) | `json` | **JSON のキーと型を列挙** | 不要 (`source`) または時刻の付け替えなど | **JSON のキーと同名・同型の列** |
| 整形された JSON (複数行) / ネストした JSON | 非対応 | - | - | - |
| syslog に出す (`logger` / journald 経由) | `syslog` データソース | 不要 | 不要 | 組み込みの `Syslog` テーブル (カスタムテーブル不要) |
| アプリから直接 HTTP で送る | DCR `kind = "Direct"` (Logs Ingestion API) | アプリが送る JSON に合わせて定義 | 任意 | カスタムテーブル |

以下、それぞれの詳細。

### 1. 1 行 1 レコードのテキスト (このサンプルの構成)

```
2026-10-29T08:42:14Z ERROR something failed in sampleapp
```

- AMA が送るのは `TimeGenerated` / `RawData` / `Computer` / `FilePath` の 4 列で、stream_declaration もこの 4 列で固定
- `transform_kql = "source"` なら行全体が `RawData` に入るだけ。テーブルは `TimeGenerated` と `RawData` があれば足りる
  (`Computer` / `FilePath` はテーブルに列があれば自動で入る)
- レベルやメッセージで検索・アラートしたいなら、変換で切り出して列を足す (このサンプルの `Level` / `Message`)。**足した列はテーブルにも定義が必要**
- `TimeGenerated` は既定では**取り込み時刻**。ログ行の時刻を使いたいなら変換で上書きする
  - ただしアラートの評価ウィンドウとずれるので注意 ([README のアラートの注意点](README.md#アラートの注意点-実機で引っかかった点))
- 実機確認: AMA はファイル末尾から読み始めるため、DCR が届く前に書かれた行は取り込まれなかった

#### このサンプルで Level / Message 列を足した手順

ログ行の書式を `<ISO 8601 時刻> <LEVEL> <メッセージ>` と決め、そこから 3 つの値を取り出して列にした。

**手順 1. カスタムテーブルに列を足す** (`log_analytics.tf`)

AMA が送る 4 列に加えて、変換で作る列を**先に**テーブルに定義する。テーブルに無い列は、変換で作っても捨てられる。

| 列 | 型 | 入れ方 |
|----|----|--------|
| `TimeGenerated` | dateTime | AMA (変換でログ行の時刻に上書き) |
| `RawData` | string | AMA (行全体。元の行を残すため削らない) |
| `Computer` | string | AMA |
| `FilePath` | string | AMA |
| `Level` | string | **変換で追加** |
| `Message` | string | **変換で追加** |

**手順 2. DCR の入力ストリームは固定 4 列のまま** (`dcr.tf` の `stream_declaration`)

text 形式では入力ストリームの列を増やせない (AMA が送るのは 4 列だけ)。列を増やすのは変換の仕事。

**手順 3. 変換 (`transform_kql`) で RawData から切り出す** (`dcr.tf` の 2 つ目の `data_flow`)

```kql
source
| extend LogTime = todatetime(extract(@"^(\S+)", 1, RawData))
| extend Level = extract(@"^\S+\s+(\w+)", 1, RawData)
| extend Message = extract(@"^\S+\s+\w+\s+(.*)$", 1, RawData)
| extend TimeGenerated = iif(isnull(LogTime), TimeGenerated, LogTime)
| project-away LogTime
```

行ごとのロジック:

| 行 | 処理 | `2026-10-29T08:42:14Z ERROR something failed in sampleapp` の場合 |
|----|------|------|
| 1 | `source` = AMA から入ってきたレコード (4 列) | - |
| 2 | 行頭から空白までの語 (`^(\S+)`) を `todatetime()` で時刻にする。変換できなければ null | `LogTime = 2026-10-29T08:42:14Z` |
| 3 | 1 語目と空白を飛ばした次の英数字の語 (`^\S+\s+(\w+)`) | `Level = "ERROR"` |
| 4 | 1 語目と 2 語目を飛ばした残り全部 (`^\S+\s+\w+\s+(.*)$`) | `Message = "something failed in sampleapp"` |
| 5 | `LogTime` が取れたときだけ `TimeGenerated` を上書きする。取れなければ取り込み時刻のまま | `TimeGenerated = 2026-10-29T08:42:14Z` |
| 6 | 作業用の `LogTime` を出力から消す (テーブルに無い列なので残しても捨てられるが、明示的に消す) | - |

- `extract()` は一致しないと空文字を返す。書式が違う行 (例: 複数行ログの 2 行目以降が `RawData` に連結されたもの) でもレコード自体は落ちず、
  取り出せなかった列が空になるだけ。`RawData` を残しているので元の行は必ず読める
- `parse` 演算子 (`parse RawData with LogTime:datetime " " Level:string " " Message:string`) でも同じことができる。
  ここでは書式が崩れた行でも挙動を読み取りやすい `extract()` にした
- 書式を変えたら (例: レベルを `[ERROR]` のように括弧で囲む)、正規表現を直す。テーブルの列は同じでよい

**手順 4. 列を使って検索・アラートする** (`alert.tf`)

```kql
SampleApp_CL
| where Level == "ERROR"
```

`Level` 列が無いと `RawData has "ERROR"` のような全文検索になり、メッセージ本文に "ERROR" という単語を含む INFO 行にも一致してしまう。
列に分けておくと、条件を正確に書けて、`summarize count() by Level` のような集計もできる。

実機確認: 取り込んだデータで `Level` 列に `INFO` と `ERROR` が分かれて入り、`Level == "ERROR"` のアラートが発報した。

### 2. 区切り文字 (CSV など)

```
2024-06-21 19:17:34,1423,Error,Sales,Unable to connect to pricing service.
```

DCR (`format = "text"`) と stream_declaration は 1. と同じで、変わるのは変換とテーブル。ドキュメントの例:

```kql
source
| project d = split(RawData, ",")
| project TimeGenerated = todatetime(d[0]), Code = toint(d[1]), Severity = tostring(d[2]),
          Module = tostring(d[3]), Message = tostring(d[4])
```

- `split()` は dynamic を返すので、`toint()` / `tostring()` でテーブルの列の型に合わせる
- 分割した列を全部出すなら、テーブルに `RawData` は無くてもよい
- メッセージ部分にカンマが入るログでは `split()` だと崩れる。その場合は `parse` / `extract()` で先頭から決まった数だけ取る

### 3. 複数行のテキスト (スタックトレースなど)

```
2026-10-29T09:00:00Z ERROR request failed
java.lang.NullPointerException
    at com.example.Foo.bar(Foo.java:42)
2026-10-29T09:00:01Z INFO next request
```

- DCR の `record_start_timestamp_format` (Terraform では `settings.text.record_start_timestamp_format`) に一致するタイムスタンプを
  **レコードの開始**とみなし、次のタイムスタンプまでの行をまとめて 1 レコードの `RawData` にする
- タイムスタンプが見つからない場合は改行がレコードの区切りになる。**書式が合っていないと 1 行ずつ別レコードになる**
- 指定できる書式 (これ以外は不可):

  | 書式 | 例 |
  |------|----|
  | `ISO 8601` | `2024-10-29T18:28:34Z` (**小数秒付きは非対応**) |
  | `yyyy-MM-ddTHH:mm:ssk` | `2024-10-29T18:28:34Z` / `2024-10-29T18:28:34+01:11` |
  | `YYYY-MM-DD HH:MM:SS` | `2024-10-29 18:28:34` |
  | `M/D/YYYY HH:MM:SS AM/PM` | `10/29/2024 06:28:34 PM` |
  | `Mon DD, YYYY HH:MM:SS` | `October 29, 2024 18:28:34` |
  | `yyMMdd HH:mm:ss` | `241029 18:28:34` |
  | `ddMMyy HH:mm:ss` | `291024 18:28:34` |
  | `MMM d HH:mm:ss` | `Oct 29 18:28:34` |
  | `dd/MMM/yyyy:HH:mm:ss zzz` | `14/Oct/2024:18:28:34 -00` (Apache / nginx のアクセスログ形式) |

- ログフレームワークの既定がミリ秒付き (`2026-10-29T09:00:00.123Z` や `2026-10-29 09:00:00,123`) のことは多い。
  ISO 8601 の小数秒は非対応と書かれているので、**アプリ側の出力形式を表に合わせるのが前提になる** (`YYYY-MM-DD HH:MM:SS` は後ろにミリ秒が続いても先頭一致で判定されるかは未確認)

### 4. JSON Lines (1 行に 1 つの JSON)

```json
{"Time":"2025-03-07 13:17:34","Code":1423,"Severity":"Error","Module":"Sales","Message":"Unable to connect to pricing service."}
```

テキストとの一番の違いは、**AMA が JSON をパースして列に分けてくれる**こと。変換で分割する必要は無い。その代わり、次の 3 つをそろえる。

1. DCR を `format = "json"` にする (`settings.text` は不要)
2. `stream_declaration` に JSON のキーと型を並べる (`TimeGenerated` は必須。`Computer` / `FilePath` は任意)
3. カスタムテーブルに**同じ名前・同じ型**の列を作る。JSON のキーと同名の列に値が入る

Terraform で書くとこうなる (未検証のスケッチ):

```hcl
resource "azurerm_log_analytics_workspace_table_custom_log" "json" {
  name         = "SampleJson_CL"
  workspace_id = azurerm_log_analytics_workspace.this.id
  column {
    name = "TimeGenerated"
    type = "dateTime"
  }
  column {
    name = "Computer"
    type = "string"
  }
  column {
    name = "FilePath"
    type = "string"
  }
  column {
    name = "Code"
    type = "int"
  }
  column {
    name = "Severity"
    type = "string"
  }
  column {
    name = "Module"
    type = "string"
  }
  column {
    name = "Message"
    type = "string"
  }
}

# azurerm_monitor_data_collection_rule の中
stream_declaration {
  stream_name = "Custom-Json-SampleJson_CL"
  column {
    name = "TimeGenerated"
    type = "datetime"
  }
  column {
    name = "Computer"
    type = "string"
  }
  column {
    name = "FilePath"
    type = "string"
  }
  column {
    name = "Time"
    type = "string"
  }
  column {
    name = "Code"
    type = "int"
  }
  column {
    name = "Severity"
    type = "string"
  }
  column {
    name = "Module"
    type = "string"
  }
  column {
    name = "Message"
    type = "string"
  }
}

data_sources {
  log_file {
    name          = "samplejson"
    streams       = ["Custom-Json-SampleJson_CL"]
    file_patterns = ["/var/log/sampleapp/*.json"]
    format        = "json"
  }
}

data_flow {
  streams       = ["Custom-Json-SampleJson_CL"]
  destinations  = ["law"]
  output_stream = "Custom-SampleJson_CL"
  # JSON の Time をレコードの時刻にする (ドキュメントの例)
  transform_kql = "source | extend TimeGenerated = todatetime(Time) | project-away Time"
}
```

注意点:

- **1 行 1 JSON (JSONL / NDJSON) のみ**。インデントした複数行の JSON や、ネストした JSON 本体は非対応とドキュメントにある
  (ネストを残したい場合は、アプリ側で文字列にして 1 列に入れ、変換で `parse_json()` する方法が考えられる。未検証)
- JSON に `TimeGenerated` キーが無ければ取り込み時刻になる。ログ側の時刻を使うなら上のように変換で付け替える
- ドキュメントには「テーブルの列と同じ型にすること」とある (例: テーブルが `int` なのに JSON が `"1423"` 文字列、のような不一致を避ける)。不一致時の挙動は未確認
- ドキュメントの JSON 用テーブル作成の節には「この PowerShell スクリプト (Tables API への PUT) 以外の方法では作れない」とある。
  Terraform の `azurerm_log_analytics_workspace_table_custom_log` も同じ Tables API を呼ぶので問題ない見込みだが、JSON 形式では未検証

### 5. syslog に出す (カスタムテーブル不要)

アプリが `logger` / syslog ライブラリで syslog に書く、または systemd サービスとして動かして標準出力を journald に出す場合、
rsyslog 経由で AMA の Syslog 収集に乗るので **カスタムテーブルもテキストログ用の DCR も要らない** (このサンプルの `syslog` データソースだけで足りる)。

- 送信先は組み込みの `Syslog` テーブル。列は固定 (`Facility` / `SeverityLevel` / `ProcessName` / `SyslogMessage` など)
- アプリ独自の項目は `SyslogMessage` の中に入るので、検索時に `parse` / `extract()` で取り出す
- アプリ専用のファシリティ (`local0`〜`local7`) を割り当てると、DCR で収集対象を絞りやすい
- systemd サービスの標準出力は、既定では journald から rsyslog に `daemon` ファシリティで渡る (ユニットの `SyslogFacility=` で変更できる)
- 実機確認: AMA 経由の `SeverityLevel` は `error` / `critical` / `warning` という表記になる

### 6. アプリから直接送る (Logs Ingestion API)

エージェントを経由せず、アプリが HTTP でワークスペースに送る方式。

- DCR は `kind = "Direct"` (ログ取り込みのエンドポイントが DCR に自動で作られる)。VM への DCR 関連付けや AMA は不要
- stream_declaration はアプリが送る JSON に合わせて自由に定義し、変換でテーブルに合わせる
- 送信元に DCR への「Monitoring Metrics Publisher」ロールが必要 (VM のマネージド ID など)
- ファイルを介さないので、ローテーションや複数行の問題が無い。代わりにアプリ側に送信処理と再送処理が要る

## どれを選ぶか

| 状況 | おすすめ |
|------|----------|
| ログ形式を変えられない既存アプリ | テキスト (1〜3)。変換で必要な列だけ切り出す |
| ログ形式をこれから決められる | **JSON Lines** (4)。列への分割を変換に書かずに済み、テーブル定義とキーを合わせるだけでよい |
| とにかく簡単に、検索は全文でよい | syslog に出す (5)。カスタムテーブルが要らない |
| 取り込み遅延やファイル管理を避けたい / コンテナー・PaaS でも使いたい | Logs Ingestion API (6) |

## 設計時のチェックリスト

- [ ] テーブル名は `_CL` で終わる。DCR より先に作る (Terraform は `depends_on`)
- [ ] 変換の出力列 (または JSON のキー) と、テーブルの列の**名前と型**が一致している
- [ ] stream_declaration の型 (`string` / `int` / `long` / `real` / `boolean` / `datetime` / `dynamic`) とテーブルの型 (`string` / `int` / `long` / `real` / `boolean` / `dateTime` / `dynamic` / `guid`) は書き方が少し違う (`datetime` と `dateTime`)
- [ ] 複数行ログなら、行頭のタイムスタンプがサポートされている書式に合っている (ISO 8601 の小数秒は不可)
- [ ] ファイルは UTF-8 か ASCII で、追記のみ (上書きしない)。ローテーションで、file_patterns に一致する別の名前に変えていない (重複取り込みになる)
- [ ] 監視するディレクトリは 10 個以下。古いファイルは掃除する (追跡するファイルが多いと AMA の CPU / メモリが増える)
- [ ] AMA (`syslog` ユーザー) がファイルとディレクトリを読める権限になっている
- [ ] `TimeGenerated` をログの時刻に置き換えるなら、アラートの評価ウィンドウと取り込み遅延の関係を考える
- [ ] 送信先のワークスペースは DCR 1 つにつき 1 つ (テキスト / JSON ログ)。複数に送るなら DCR を分ける (データは重複して課金される)
- [ ] テーブルの列の追加は後からできるが、型の変更や列の削除には制約がある。最初に形式を固める
