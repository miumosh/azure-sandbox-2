# gpt-realtime-1.5 × East US 2 — 提供状況・クォータ・申請要否の調査

調査日: 2026-09-04 / 調査対象サブスクリプション: `<SUBSCRIPTION_ID>`（従量課金 / テナント `<TENANT_DOMAIN>`）

---

## 1. 結論(TL;DR)

- **East US 2 で `gpt-realtime-1.5` は利用可能。** バージョン `2026-02-23`、ライフサイクルは **GenerallyAvailable**（Preview ではない）。
- **利用開始に申請は一切不要。** 本サブスクリプションには既定でクォータ `limit=10`（未使用 0）が付与済みで、そのままデプロイできる。
- 申請が要るのは **(a) クォータ上限の引き上げ**（既定 10 → 最大 30000）と、**(b) Guardrails（旧コンテンツフィルター）を OFF にする／不正監視を除外する**場合のみ。(b) は Microsoft アカウントチーム管理下の顧客限定。
- **「昔は申請が必要だった」は正しい。** 2023/01 GA 〜 2024 年央までは Azure OpenAI 自体がサブスクリプション単位のゲート対象だった。ただし realtime API の初出（`gpt-4o-realtime-preview` / 2024-10）はゲート撤廃後なので、**realtime に申請が必要だった時期は存在しない**（当時の障壁はリージョンとクォータ）。

---

## 2. モデル提供状況（eastus2）

```bash
az cognitiveservices model list -l eastus2 -o json \
  | jq -r '.[] | select(.model.name|test("realtime";"i"))
           | "\(.kind)\t\(.model.name)\t\(.model.version)\t\(.model.lifecycleStatus)\t\(.model.skus|map(.name)|join(","))"' \
  | sort -u
```

eastus2 では realtime 系が 9 モデル提供されている（`kind` は `OpenAI` / `AIServices` 双方で同一の結果）:

| モデル | バージョン | ライフサイクル | デプロイタイプ |
| --- | --- | --- | --- |
| **gpt-realtime-1.5** | **2026-02-23** | **GA** | **GlobalStandard, DataZoneStandard** |
| gpt-realtime | 2025-08-28 | GA | GlobalStandard |
| gpt-realtime-mini | 2025-10-06 / 2025-12-15 | GA | GlobalStandard |
| gpt-realtime-translate | 2026-05-06 | GA | GlobalStandard |
| gpt-realtime-whisper | 2026-05-06 | GA | GlobalStandard |
| gpt-realtime-2 | 2026-05-06 | Preview | GlobalStandard, DataZoneStandard |
| gpt-realtime-2.1 | 2026-07-07 | Preview | GlobalStandard, DataZoneStandard |
| gpt-realtime-2.1-mini | 2026-07-07 | Preview | GlobalStandard |

> `-2` / `-2.1` 系は現時点で Preview 扱い。**GA 前提の要件なら 1.5 が妥当**。

### 2.1 gpt-realtime-1.5 の SKU 詳細

```json
{
  "name": "gpt-realtime-1.5",
  "version": "2026-02-23",
  "status": "GenerallyAvailable",
  "deprecation": { "inference": "2027-08-24T00:00:00Z" },
  "skus": [
    { "name": "GlobalStandard",   "capacity": { "default": 10, "maximum": 30000 },
      "deprecationDate": "2027-08-24T00:00:00+00:00" },
    { "name": "DataZoneStandard", "capacity": { "default": 10, "maximum": 30000 },
      "deprecationDate": "2027-08-24T00:00:00+00:00" }
  ]
}
```

- **推論の廃止予定は 2027-08-24。** 約 1 年弱の猶予があるため、長期運用ならモデル更新の運用フローを前提に置くこと。
- `DataZoneStandard` が選べるので、**データ所在をデータゾーン内に限定したい要件にも対応可能**（GlobalStandard は全世界ルーティング）。

---

## 3. クォータ（申請不要であることの根拠）

```bash
az cognitiveservices usage list -l eastus2 -o json \
  | jq -r '.[] | select(.name.value|test("realtime";"i"))
           | "\(.name.value)\tcurrent=\(.currentValue)\tlimit=\(.limit)"' | sort
```

```
OpenAI.DataZoneStandard.gpt-realtime-1.5      current=0  limit=10
OpenAI.DataZoneStandard.gpt-realtime-2.1      current=0  limit=10
OpenAI.DataZoneStandard.gpt-realtime-2        current=0  limit=10
OpenAI.GlobalStandard.gpt-4o-mini-realtime-preview  current=0  limit=6
OpenAI.GlobalStandard.gpt-4o-realtime-preview       current=0  limit=6
OpenAI.GlobalStandard.gpt-realtime-1.5        current=0  limit=10
OpenAI.GlobalStandard.gpt-realtime-2.1        current=0  limit=10
OpenAI.GlobalStandard.gpt-realtime-2.1-mini   current=0  limit=10
OpenAI.GlobalStandard.gpt-realtime-2          current=0  limit=10
OpenAI.GlobalStandard.gpt-realtime            current=0  limit=10
OpenAI.GlobalStandard.gpt-realtime-mini       current=0  limit=20
OpenAI.GlobalStandard.gpt-realtime-translate  current=0  limit=10
OpenAI.GlobalStandard.gpt-realtime-whisper    current=0  limit=10
```

ポイント:

- **`limit` が 0 ではなく 10 → 申請なしで即デプロイ可能**。ゲート対象モデルであれば、ここが 0 になるか、そもそも usage エントリが出ない。
- 単位は capacity 1 = **1K TPM 相当**。realtime では実質「同時セッション数の上限」に効く。
- **PoC・単一セッションの検証なら既定 10 で十分。** 本番で同時接続を増やす段階になって初めて、サポートリクエストでの引き上げ（上限 30000）を検討する。
- `gpt-4o-realtime-preview` / `gpt-4o-mini-realtime-preview` の `limit=6` は、realtime 黎明期（2024-10）の絞られたクォータの名残。

---

## 4. デプロイ手順

```bash
RG=<rg>
NAME=<account-name>

az cognitiveservices account create -n "$NAME" -g "$RG" -l eastus2 \
  --kind AIServices --sku S0 --custom-domain "$NAME"

az cognitiveservices account deployment create -n "$NAME" -g "$RG" \
  --deployment-name gpt-realtime-1.5 \
  --model-name gpt-realtime-1.5 \
  --model-version 2026-02-23 \
  --model-format OpenAI \
  --sku-name GlobalStandard \
  --sku-capacity 10
```

- `--custom-domain` は Entra ID 認証 / Private Endpoint を使う場合に必須。
- `--sku-capacity` は既定 10。クォータが 10 なので 10 を超える指定は `InsufficientQuota` になる。
- AOAI は**デプロイ自体は無課金・トークン（realtime は音声/テキストの入出力）従量**。検証後に `deployment delete` すればコストは実利用分のみ。

---

## 5. 「昔は申請が必要だったのか」— 経緯

| 時期 | 状態 |
| --- | --- |
| 2023-01 GA 〜 2024 年前半 | **サブスクリプション単位の申請が必須。** `aka.ms/oai/access` のフォームで用途を申告 → 審査（5〜10 営業日）。原則「Microsoft 管理顧客（アカウントチームが付いている企業）」向けで、**個人メールアドレスでの申請は却下**された。承認前は OpenAI kind のリソース自体が作成できない |
| 2023 春〜夏 | さらに **GPT-4 は別枠の waitlist**。AOAI アクセス済みでも GPT-4 は別途待ち |
| 2024 年央（概ね 5〜7 月） | **一般アクセスのゲート撤廃。** ドキュメントが "all Azure customers are eligible" に書き換わり、旧フォームは順次クローズ。2024-07-20 の Microsoft Q&A に「フォームのリンクが切れている / The form was closed」の報告があり、これが切り替わり時期の痕跡。**「◯月◯日に廃止」という明示的なアナウンスは MS から出ておらず、静かにドキュメント改訂された** |
| 2024-10 | `gpt-4o-realtime-preview` 登場。**ゲート撤廃後のリリースなので申請は一度も要求されていない。** 当時の障壁は「eastus2 / swedencentral の 2 リージョンのみ」「クォータが極小」 |
| 現在（2026-09） | 公式ドキュメントに明記 → *"Standard Azure OpenAI usage does not require Limited Access registration."* |

### 5.1 現在も申請が残っているもの

Limited Access の一覧に Azure OpenAI は残っているが、対象は**機能単位**:

- **Guardrails（旧コンテンツフィルター）を OFF にする** — 閾値の調整だけなら誰でも可。部分/全体を切るには申請
- **不正監視（abuse monitoring）の除外** — 申請
- いずれも **Microsoft アカウントチーム管理下の顧客／対象プログラム参加者に限定**
- 加えて、**新規モデルのローンチ直後に一時的なモデル単位ゲートが付くことがある**（o3 が launch 時に registration 必須だった例）。`gpt-realtime-1.5` は GA かつ既定クォータ付与済みのため該当しない

---

## 6. 未検証事項

- **実 PUT によるデプロイ検証は未実施。** モデル一覧・クォータともに問題ないため通る見込みだが、Azure Firewall のゾーン容量の件（[../../firewall/sku_zone_relation/research.md](../../firewall/sku_zone_relation/research.md)）のように「一覧や validate では検出できない実デプロイ時の制限」が稀にある。本番設計に入る前に一度実デプロイして確認するのが安全。
- realtime の同時セッション数と capacity（TPM）の正確な換算比は未確認。負荷設計時に実測が必要。

---

## 参考

- [Limited access to Azure OpenAI in Microsoft Foundry Models](https://learn.microsoft.com/en-us/azure/foundry/responsible-ai/openai/limited-access)
- [Limited Access features for Foundry Tools](https://learn.microsoft.com/en-us/azure/ai-services/cognitive-services-limited-access)
- [Azure OpenAI registration forms are closed or not working (Microsoft Q&A, 2024-07-20)](https://learn.microsoft.com/en-us/answers/questions/1826693/azure-openai-registration-forms-are-closed-or-not)
