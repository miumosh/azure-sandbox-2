# Application Gateway (WAF_v2) の min capacity 変更による通信影響の調査

| 項目 | 変更前 | 変更後 |
|------|--------|--------|
| 自動スケールの最小インスタンス数 (`autoscaleConfiguration.minCapacity`) | `0` | `1` |

対象 SKU は WAF_v2。コード化・デプロイ・実機検証はせず、公開ドキュメント・Issue・ブログをもとに調べた結果をまとめる (調査日: 2026-10-02)。

## 結論

**公開ドキュメントを見る限り、min capacity を 0 → 1 に変えてもアプリの通信は途切れない。**

- 今回の変更は、稼働中のインスタンスはそのままで**予約容量 (1 インスタンス ≒ 10 CU) を足すだけ**の操作。
- ただし、可用性メトリクスが一瞬下がる、反映まで数分かかる、料金が変わる、といった点には注意が必要 (後述)。

## 根拠 (Microsoft Learn)

### 1. スケール操作ではダウンタイムは発生しない

FAQ の「手動でも自動でも、スケールアップ・スケールダウンでダウンタイムは発生しますか?」に対する回答:

> No. Instances are distributed across upgrade domains and fault domains.

### 2. min 0 でもインスタンスが 0 台になるわけではない

- 0 は「予約された容量がない」という意味で、純粋に自動スケールだけで動く状態を指す。
  > Zero signifies no reserved capacity and is purely autoscaling in nature.
- min 0 でも高可用性は保たれている。
  > Even if you configure autoscaling with zero minimum instances the service is still highly available, which is always included with the fixed price.

→ 0 → 1 は「インスタンスが無い状態から立ち上げる」操作ではなく、「最低限確保しておく容量を増やす」操作。

### 3. 設定変更は更新ドメインごとに順番に反映される

- 更新は更新ドメインを 1 つずつ適用し、その間は他の更新ドメインのインスタンスが通信を処理する。
- 更新対象のインスタンスにある接続は、最大 5 分かけて他のインスタンスへ丁寧に切り替えられる。
- MaxSurge が自動で有効になっており、新しいインスタンスを先に作るため、更新中も処理能力が落ちない。

## 注意点

| # | 内容 | 出典 |
|---|------|------|
| 1 | **自動スケール中に可用性メトリクスが一瞬下がることがある。** 「スケールの切り替え中に短時間下がるのは想定どおりの動作で、通常は数秒で戻る」とされている。監視アラートのしきい値によっては通知が飛ぶ可能性がある。 | ドキュメント |
| 2 | **インスタンスの追加には 3〜5 分かかる。** 予約容量は変更直後ではなく、インスタンスの用意ができてから効く。容量を増やす方向の変更なので、通信への悪影響ではない。 | ドキュメント |
| 3 | **サブネットの空き IP が必要。** インスタンスを増やすときも、MaxSurge で一時インスタンスを作るときも、サブネットの IP を使う。足りないと MaxSurge は使われず従来の更新方式に戻り、更新中の最大容量が下がる。 | ドキュメント |
| 4 | **変更中は他の設定変更ができない。** ゲートウェイ全体を更新する操作なので、反映までの数分間はプロビジョニング状態が `Updating` になり、その間は他の設定変更とぶつかると思われる。通信そのものには影響しない。 | 推測 (ドキュメントに記載なし) |
| 5 | **料金が変わる。** 1 インスタンス分 (約 10 CU) の予約容量が、トラフィックの有無に関係なく常に課金されるようになる。 | ドキュメント |

## 調べきれなかったこと

- 「min を 0 → 1 にしたら通信が途切れた」という GitHub Issue、Microsoft Q&A、ブログ記事は見つからなかった。
- 「min 0 でも実際は 2 台以上動いている」という話はよく聞くが、ドキュメントには台数の明記がない。**推測扱い**とする。

確実に確認したい場合は、検証環境で継続的にリクエストを送りながら min capacity を変更し、エラー (5xx・接続リセット) や遅延が出ないかを見る。

## 参考

- [Scaling and Zone-redundant Application Gateway v2 (Microsoft Learn)](https://learn.microsoft.com/en-us/azure/application-gateway/application-gateway-autoscaling-zone-redundant)
- [Application Gateway FAQ (Microsoft Learn)](https://learn.microsoft.com/en-us/azure/application-gateway/application-gateway-faq)
  - 「Does manual or automatic scale up or scale down cause downtime?」
  - 「How does Application Gateway handle routine maintenance?」
- [Application Gateway high traffic support (Microsoft Learn)](https://learn.microsoft.com/en-us/azure/application-gateway/high-traffic-support)
- [Understanding pricing for Application Gateway and WAF (Microsoft Learn)](https://learn.microsoft.com/en-us/azure/application-gateway/understanding-pricing)
