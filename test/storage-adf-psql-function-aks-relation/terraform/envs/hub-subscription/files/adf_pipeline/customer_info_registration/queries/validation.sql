-- ============================================================================
-- queries/validation.sql (ADF Script Activity 実行用 SQL)
--
-- locals.tf が file() で読み込み、pipeline pl_csv_ingest の parameter
-- validation_sql の default 値として渡す。Script activity は
-- "text": "@{pipeline().parameters.validation_sql}" でこの SQL を取得して実行する。
--
-- ADF パイプラインの [Script Activity] で実行する SQL スクリプト。
-- Copy Activity が CSV を customer_info_landing にロードした後に実行される。
--
-- 処理概要:
--   1. customer_info_landing (生・未検証) の各行をバリデーションする
--   2. 問題ない行を customer_info_staging へ INSERT
--   3. NG な行を customer_info_error へ INSERT (理由付き)
--   4. トランザクション内で customer_info_production を customer_info_staging に同期する (UPSERT + DELETE)
--        - staging の行を policy_no キーで UPSERT (新規=INSERT / 既存=UPDATE で上書き)
--        - staging に無い policy_no の行を DELETE (今回バッチで消えた顧客)
--      production は drop/rename しない永続テーブルのため、SELECT 権限・インデックスは恒久 (再 GRANT 不要)。
--   ※ 参照ビュー (旧 view_prd_table) は廃止。Function/AKS は customer_info_production を直読する。
--
-- バリデーション規則 (landing は VARCHAR(255) のため SQL 側で全チェックする):
--   - 必須   : 4項目が NULL/空でない。空白のみも空扱い (name_kana は全角スペース、他は半角スペース)
--   - 桁数   : policy_no<=10, name_kana<=50, birth_ymd=8
--   - 型/形式: policy_no=半角英数字, name_kana=全角カタカナ（姓＜全角スペース＞名）,
--              birth_ymd=数字8桁(YYYYMMDD) かつ実在する日付, cellular_phone_no=半角数字 3-4-4 (XXX-XXXX-XXXX)
--   - 重複   : landing バッチ内で policy_no が一意 (重複する policy_no を持つ行は全て NG)
-- ============================================================================

-- 前回実行分をクリアしてから再構築する
TRUNCATE TABLE customer_info_staging;
TRUNCATE TABLE customer_info_error;

-- ----------------------------------------------------------------------------
-- 各行の検証結果 (format_error) と policy_no 重複数 (id_count) を 1 度だけ算出し、
-- OK 行を customer_info_staging へ、NG 行を customer_info_error へ同時に振り分ける。
--   - CTE はスコープが「直後の 1 文」のみのため、データ変更 CTE (promote_ok) と本体 INSERT を
--     1 文にまとめる。両者は同一スナップショットの validated を参照する。
--   - format_error: 必須/桁数/型のうち最初に該当した理由。問題なければ NULL。
--   - id_count    : 同一 policy_no の出現数 (window)。>1 なら重複。
-- ----------------------------------------------------------------------------
WITH validated AS (
    SELECT
        policy_no, name_kana, birth_ymd, cellular_phone_no,
        CASE
            -- 必須チェック (NULL / 空 / 空白のみ。name_kana は全角スペース、他は半角スペースを空扱い)
            WHEN policy_no         IS NULL OR policy_no         ~ '^ *$'  THEN 'policy_no required'
            WHEN name_kana         IS NULL OR name_kana         ~ '^　*$' THEN 'name_kana required'
            WHEN birth_ymd         IS NULL OR birth_ymd         ~ '^ *$'  THEN 'birth_ymd required'
            WHEN cellular_phone_no IS NULL OR cellular_phone_no ~ '^ *$'  THEN 'cellular_phone_no required'
            -- 桁数チェック
            WHEN char_length(policy_no) > 10 THEN 'policy_no too long (max 10)'
            WHEN char_length(name_kana) > 50 THEN 'name_kana too long (max 50)'
            WHEN char_length(birth_ymd) <> 8 THEN 'birth_ymd must be 8 digits'
            WHEN char_length(cellular_phone_no) > 15 THEN 'cellular_phone_no too long (max 15)'
            -- 文字種 / 形式 / 文字幅チェック (name_kana 以外は半角、name_kana は全角)
            WHEN policy_no         !~ '^[0-9A-Za-z]+$'                  THEN 'policy_no must be half-width alphanumeric'
            WHEN name_kana         !~ '^[ァ-ヾ]+　[ァ-ヾ]+$'             THEN 'name_kana must be zenkaku katakana in sei<full-width space>mei form'
            WHEN birth_ymd         !~ '^[0-9]{8}$'                      THEN 'birth_ymd must be 8-digit YYYYMMDD'
            WHEN cellular_phone_no !~ '^[0-9]{3}-[0-9]{4}-[0-9]{4}$'    THEN 'cellular_phone_no must be XXX-XXXX-XXXX'
            -- 実在日チェック (8桁数字確定後)。例外を投げる to_date/::date を使わず、月ごとの日数＋閏年を
            -- 「整数比較だけ」で判定する (どんな入力でも throw しない＝Script が落ちない)。
            -- birth_ymd は 'YYYYMMDD' なので substring(,1,4)=年(YYYY) / (,5,2)=月(MM) / (,7,2)=日(DD)。
            WHEN substring(birth_ymd, 5, 2)::int NOT BETWEEN 1 AND 12                       -- 月が 1〜12 の範囲外 → 不正
              OR substring(birth_ymd, 7, 2)::int < 1                                        -- 日が 1 未満 (例 "00") → 不正
              OR substring(birth_ymd, 7, 2)::int >                                          -- 日が「その月の最大日数」を超える → 不正:
                   CASE substring(birth_ymd, 5, 2)::int                                     --   月ごとに最大日数を決める
                     WHEN 2 THEN CASE WHEN (substring(birth_ymd, 1, 4)::int % 4 = 0         --   2月: 閏年なら29日/平年なら28日
                                          AND substring(birth_ymd, 1, 4)::int % 100 <> 0)   --     閏年 = 4で割切れ かつ 100で割切れない…
                                       OR substring(birth_ymd, 1, 4)::int % 400 = 0         --     …または 400 で割切れる (1900=非閏 / 2000=閏)
                                  THEN 29 ELSE 28 END                                       --     → 閏年=29 / 平年=28
                     WHEN 4 THEN 30 WHEN 6 THEN 30 WHEN 9 THEN 30 WHEN 11 THEN 30           --   4/6/9/11月 = 30日
                     ELSE 31                                                                --   その他 (1/3/5/7/8/10/12月) = 31日
                   END
                THEN 'birth_ymd is not a valid calendar date'                              -- 上記いずれか該当 → 実在しない日付
            ELSE NULL
        END AS format_error,
        count(*) OVER (PARTITION BY policy_no) AS id_count
    FROM customer_info_landing
),
-- OK 行 (全チェック合格 かつ policy_no が一意) を昇格用バッファ customer_info_staging へ投入
promote_success AS (
    INSERT INTO customer_info_staging (policy_no, name_kana, birth_ymd, cellular_phone_no)
    SELECT policy_no, name_kana, birth_ymd, cellular_phone_no
    FROM validated
    WHERE format_error IS NULL AND id_count = 1
),
-- NG 行 (形式違反 または policy_no 重複) を customer_info_error へ投入。
-- 理由は形式違反を優先し、形式は正しいが policy_no が重複している行は 'policy_no duplicated'。
-- (NULL/空 policy_no は 'policy_no required' が優先されるため 'policy_no duplicated' にはならない)
promote_error AS (
    INSERT INTO customer_info_error (policy_no, name_kana, birth_ymd, cellular_phone_no, error_message)
    SELECT policy_no, name_kana, birth_ymd, cellular_phone_no,
        COALESCE(format_error, 'policy_no duplicated')
    FROM validated
    WHERE format_error IS NOT NULL OR id_count > 1
    RETURNING 1
)

-- Dummy SELECT で CTE を消化
SELECT
    CASE
        WHEN EXISTS (SELECT 1 FROM promote_error) THEN 'Error is exist.'
        ELSE 'Error is not exist.'
    END AS validation_result;


-- ----------------------------------------------------------------------------
-- 4) トランザクション内で customer_info_production を staging に同期する (UPSERT + DELETE)
--    - production は永続テーブル。drop/rename しないので SELECT 権限・インデックスが恒久 (再 GRANT 不要)。
--    - UPSERT/DELETE は行レベルロックのため、読み手 (Function/AKS) を ACCESS EXCLUSIVE でブロックしない。
--    - 失敗時はロールバックされ、既存の customer_info_production はそのまま残る。
--    - ON CONFLICT (policy_no) は production の PRIMARY KEY(policy_no) を競合キーに使う (create-tables.sql)。
-- ----------------------------------------------------------------------------
BEGIN;

-- staging (検証 OK 行) を policy_no キーで UPSERT。新規 policy_no は INSERT、既存は UPDATE で上書きする。
-- EXCLUDED.* = INSERT しようとした新しい値 (= staging 由来)。テーブル名側 = 既存の古い行。
INSERT INTO customer_info_production (policy_no, name_kana, birth_ymd, cellular_phone_no)
SELECT policy_no, name_kana, birth_ymd, cellular_phone_no FROM customer_info_staging
ON CONFLICT (policy_no) DO UPDATE
    SET name_kana         = EXCLUDED.name_kana,
        birth_ymd         = EXCLUDED.birth_ymd,
        cellular_phone_no = EXCLUDED.cellular_phone_no;

-- 今回バッチ (staging) に無い policy_no = 消えた顧客を削除。
-- staging.policy_no は NOT NULL のため NOT IN で安全 (NULL 混入時の取りこぼしが無い)。
DELETE FROM customer_info_production
WHERE policy_no NOT IN (SELECT policy_no FROM customer_info_staging);

COMMIT;
