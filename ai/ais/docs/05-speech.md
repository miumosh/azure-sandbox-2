# Speech の閉域化 — 影響が一番大きい

**Speech は他の kind と性質が違う。閉域化するとアプリのコードを変えないと動かない。
しかもこの変更は取り消せない。**

---

## 1. 何が変わるのか

| 項目 | 内容 |
|---|---|
| カスタムサブドメイン | PE を使うには**必須**。そして **Azure 側でも取り消せない**。戻すにはリソース再作成 |
| エンドポイント | `<region>.stt.speech.microsoft.com` → `<custom>.cognitiveservices.azure.com` |
| SDK 初期化 | `SpeechConfig.FromSubscription(key, region)` は **401 で失敗**。`FromEndpoint` が必要 |
| エンドポイント形式 | `wss://<custom>.cognitiveservices.azure.com` (WebSocket) |
| 認証 | `Authorization` ヘッダのトークンは **All networks のときしか使えない**。`Ocp-Apim-Subscription-Key` を使う |
| **Speech Studio** | public 無効では **使用不可**。VNet 内からでも不可 |
| リージョン依存ロジック | カスタムドメイン名にリージョン情報が含まれないため、DNS 名からリージョンを取る実装は破綻する |

> 出典: [How to use private endpoints with Speech service](https://learn.microsoft.com/azure/ai-services/speech-service/speech-services-private-link)
>
> "When you turn on a custom domain name, the operation is **not reversible**.
> The only way to go back to the regional name is to **create a new Speech resource**."

---

## 2. コードの変更

### 変更前 (リージョンエンドポイント)

```python
import azure.cognitiveservices.speech as speechsdk
config = speechsdk.SpeechConfig(subscription=speech_key, region="japaneast")
```

### 変更後 (閉域化・カスタムサブドメイン)

```python
import azure.cognitiveservices.speech as speechsdk
config = speechsdk.SpeechConfig(
    endpoint="wss://spch-aissbx-xxxxx.cognitiveservices.azure.com",
    subscription=speech_key,
)
```

他言語:

```csharp
var config = SpeechConfig.FromEndpoint(endPoint, speechKey);   // C#
```
```java
SpeechConfig config = SpeechConfig.fromEndpoint(endPoint, speechKey);   // Java
```
```javascript
const config = sdk.SpeechConfig.fromEndpoint(new URL(endPoint), speechKey);  // JS
```

**変更しないと 401 になる。** これは「キーが違う」ではなく
「カスタムドメイン有効化により初期化方法が変わった」ことのサイン。

---

## 3. REST API の URL 変換

ホスト名だけを差し替え、パスはそのまま。

### Speech to text REST API (バッチ / カスタム音声認識)

```
変更前: https://japaneast.api.cognitive.microsoft.com/speechtotext/v3.1/transcriptions
変更後: https://spch-aissbx-xxxxx.cognitiveservices.azure.com/speechtotext/v3.1/transcriptions
```

### Text to speech REST API

**こちらはパスも変わる** (サービス種別がパスに移る)。

```
変更前: https://japaneast.tts.speech.microsoft.com/cognitiveservices/voices/list
変更後: https://spch-aissbx-xxxxx.cognitiveservices.azure.com/tts/cognitiveservices/voices/list
                                                             ^^^^
```

サービス種別とパス接頭辞の対応:

| 種別 | 変更前ホストの要素 | 変更後のパス接頭辞 |
|---|---|---|
| Speech to text (short audio) | `stt` | `/stt` |
| Text to speech | `tts` | `/tts` |
| Speech Translation | `s2s` | `/s2s` |
| Custom voice | `voice` | `/voice` |

---

## 4. Speech Studio は VNet 内でも使えない

**これが一番の制約。** 他のサービスと違い、VNet 内に踏み台を置いても解決しない。

> "If you allow only private endpoints through the Networking > Private endpoint
> connections tab, **you can't use Speech Studio** with the Speech resource."
>
> "Access to Speech Studio **through private or VNet service endpoints is not supported**."

| Speech リソースのネットワーク設定 | Speech Studio |
|---|---|
| All networks | 制限なし |
| Selected Networks and Private Endpoints | **許可した公開 IP からのみ** |
| **Disabled (本構成)** | **使用不可** |

### 回避策 (MS Docs 記載)

**カスタム音声認識 (custom speech):**

- 開発用に public な Speech リソースを別途用意し、Studio でモデルを作って
  [`Models_CopyTo`](https://learn.microsoft.com/rest/api/speechtotext/models/copy-to) REST で本番リソースへコピーする
- Studio を使わず [Speech to text REST API](https://learn.microsoft.com/azure/ai-services/speech-service/rest-speech-to-text) で全操作を行う

**カスタム音声 (custom voice):**

- 開発用 public リソースで作成し、**Azure サポートチケット**でコピーを依頼する
- [Custom voice REST API](https://learn.microsoft.com/rest/api/aiservices/speechapi/operation-groups) を直接使う

---

## 5. 認証トークンの制約

`Authorization` ヘッダ + 発行トークン方式は **All networks のときしか使えない。**

> "Using an authorization token and passing it to the special endpoint through the
> `Authorization` header works **only if you turned on the All networks access option**.
> In other cases you get either a `Forbidden` or `BadRequest` error."

閉域構成では `Ocp-Apim-Subscription-Key` ヘッダにリソースキーを渡す。

---

## 6. 実測結果

本構成 (`kind = SpeechServices` / `publicNetworkAccess = Disabled` / PE + `cognitiveservices` ゾーン):

| | VNet 内 (probe VM) | VNet 外 |
|---|---|---|
| 名前解決 `spch-aissbx-xxxxx.cognitiveservices.azure.com` | **10.60.10.7** | 公開 IP |
| `GET /speechtotext/v3.1/transcriptions` | **200** (`{"values": []}`) | **403** `Public access is disabled` |

Entra ID (VM のマネージド ID) 認証でも VNet 内から 200。

---

## 7. 導入前チェックリスト

Speech を閉域化する前に確認すること。**カスタムサブドメインは取り消せない。**

- [ ] 既存アプリの `SpeechConfig` 初期化を `FromEndpoint` に変えられるか
- [ ] DNS 名からリージョンを判定している実装がないか
- [ ] TTS の REST を使っている場合、パス接頭辞 (`/tts` 等) の変更に追随できるか
- [ ] Speech Studio を運用に使っていないか。使っているなら回避策 (§4) を受け入れられるか
- [ ] 認証トークン方式を使っていないか (`Ocp-Apim-Subscription-Key` に変えられるか)
- [ ] **本番リソースでいきなり試さず、テスト用リソースで先に確認したか**

> "If your Speech resource has a lot of associated custom models and projects
> created via Speech Studio, we strongly recommend **trying the configuration with
> a test resource** before you modify the resource used in production."
