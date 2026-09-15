-- ============================================================================
-- create-tables.sql
--
-- 顧客情報の取込パイプラインで使うテーブルを appdb に作成する。
-- create-database.sql で appdb を作成した後、appdb へ接続して実行する:
--   \connect appdb
--   \i create-tables.sql
--
-- データ項目 (CSV ヘッダ -> データ項目 のマッピング仕様より):
--   顧客_番号     -> policy_no          VARCHAR(10)
--   顧客_氏名     -> name_kana          VARCHAR(50)   全角カタカナ (業務上限 50 文字)
--   顧客_生年月日 -> birth_ymd          VARCHAR(8)    YYYYMMDD
--   顧客_電話番号 -> cellular_phone_no  VARCHAR(15)   XXX-XXXX-XXXX
--
-- ★補足 (型の考え方):
--   - PostgreSQL の VARCHAR(n) は「n バイト」ではなく「n 文字 (コードポイント)」。全角カナ 1 字 = 1 文字
--     (UTF-8 で 3 バイト) なので、name_kana VARCHAR(50) は「全角カナ 50 文字 (最大 150 バイト)」を格納できる。
--   - production/staging は仕様の厳格上限 (policy_no10/name_kana50/birth_ymd8/cellular_phone_no15) かつ NOT NULL。検証済み行のみ。
--   - landing/error は VARCHAR(255) (寛大な慣習上限) かつ NULL 許容。桁数超過・型違反・空も受け入れて
--     SQL 検証 (validation-...sql) で error に振り分けるため。255 を超える異常値のみ Copy(Sink) で 22001
--     となりロード段階で弾かれる (現実の顧客データでは起きない)。
--
-- テーブル構成 (役割):
--   customer_info_landing    : CSV 生ロード先 (未検証・全行)。VARCHAR(255)/NULL 可。
--   customer_info_staging    : 検証 OK 行の入替バッファ (昇格用・使い捨て)。production と同じ厳格型+NOT NULL。
--   customer_info_production : 本番 (Function/AKS が直読する安定名)。厳格型+NOT NULL (検証済み行のみ)。
--   customer_info_error      : 検証 NG 行 (error_message 付き)。NG 値をそのまま記録するため VARCHAR(255)/NULL 可。
--
-- 注意: 旧スキーマ (stg_table / prd_table / new_prd_table / error_table / view_prd_table、
--       および deleted_reason 列) は廃止した。既存テーブルがある環境では
--       CREATE TABLE IF NOT EXISTS では作り替わらないため、先に旧オブジェクトを
--       DROP してから本ファイルを実行すること (手順は docs/migration-runbook.md)。
-- ============================================================================

-- 取込ランディング (CSV を一旦受ける生ロード先・未検証)
-- VARCHAR(255)/NULL 可。桁数超過・型違反・空もそのまま受け入れ、検証は Script Activity の SQL で行う。
CREATE TABLE IF NOT EXISTS customer_info_landing (
    policy_no           VARCHAR(255),
    name_kana           VARCHAR(255),
    birth_ymd           VARCHAR(255),
    cellular_phone_no   VARCHAR(255)
);

-- 本番テーブル (検証済み行のみ。全列 NOT NULL)。
-- 永続テーブル＝Script Activity が UPSERT/DELETE で同期し drop/rename しない。
-- policy_no を PRIMARY KEY とする (validation.sql の UPSERT が ON CONFLICT (policy_no) で使う競合キー)。
CREATE TABLE IF NOT EXISTS customer_info_production (
    policy_no           VARCHAR(10)  NOT NULL PRIMARY KEY,
    name_kana           VARCHAR(50)  NOT NULL,
    birth_ymd           VARCHAR(8)   NOT NULL,
    cellular_phone_no   VARCHAR(15)  NOT NULL
);

-- ID 取得 API (name_kana + birth_ymd + cellular_phone_no で完全一致検索) 用のインデックス。
-- production は永続テーブル (UPSERT/DELETE で同期し drop/rename しない) ため、このインデックスは恒久。
CREATE INDEX IF NOT EXISTS idx_customer_info_lookup
    ON customer_info_production (name_kana, birth_ymd, cellular_phone_no);

-- 検証 OK 行の入替バッファ (Script Activity が毎回 TRUNCATE して再投入し、production へ UPSERT する。rename はしない)。
-- production と同一スキーマ + インデックスを継承させるため LIKE で作成する (PRIMARY KEY の unique 索引も継承)。
-- LIKE は production の NOT NULL も継承するが、要望により明示的にも NOT NULL を付与する。
CREATE TABLE IF NOT EXISTS customer_info_staging (LIKE customer_info_production INCLUDING ALL);
ALTER TABLE customer_info_staging
    ALTER COLUMN policy_no         SET NOT NULL,
    ALTER COLUMN name_kana         SET NOT NULL,
    ALTER COLUMN birth_ymd         SET NOT NULL,
    ALTER COLUMN cellular_phone_no SET NOT NULL;

-- バリデーション NG 行を退避するテーブル。
-- landing の NG 値 (桁数超過など) をそのまま記録するため、データ列・error_message とも
-- VARCHAR(255)/NULL 可とする (厳格型だと NG 値の INSERT 自体が 22001 で落ちてしまう)。
-- error_message には固定の理由コードのみ入れ、生の値は埋め込まない (生値はデータ列に保持)。
CREATE TABLE IF NOT EXISTS customer_info_error (
    policy_no           VARCHAR(255),
    name_kana           VARCHAR(255),
    birth_ymd           VARCHAR(255),
    cellular_phone_no   VARCHAR(255),
    error_message       VARCHAR(255)
);

-- ============================================================================
-- AAD ロールへの最小権限付与
-- ============================================================================
-- ★ 前提: ADF/Function/踏み台 の AAD ロールは先に create-aad-roles.sql を
--    **postgres データベース**で実行して作成しておくこと
--    (pgaadauth_* 関数は postgres DB にしか無いため)。ロールはクラスタ共有なので
--    本ファイル (appdb で実行) からも参照できる。
--
--    本ファイルは appdb に Entra 管理者で接続して実行する:
--      psql "host=<fqdn> port=5432 dbname=appdb user=<entra-admin-upn> sslmode=require" \
--           -f create-tables.sql
-- ----------------------------------------------------------------------------

-- --- Function: 参照のみ (最小権限) -----------------------------------------
-- production は永続テーブル (drop/rename しない) のため、ここで一度付与すれば SELECT 権限は恒久。
-- validation.sql 側での再 GRANT は不要 (案11)。
GRANT CONNECT ON DATABASE appdb TO "ci00-func";
GRANT USAGE ON SCHEMA public TO "ci00-func";
GRANT SELECT ON customer_info_production TO "ci00-func";

-- --- 踏み台 VM の MI: 日常確認用に参照のみ (最小権限) ----------------------
GRANT CONNECT ON DATABASE appdb TO "ci00-jumpbox";
GRANT USAGE ON SCHEMA public TO "ci00-jumpbox";
GRANT SELECT ON customer_info_production, customer_info_error TO "ci00-jumpbox";

-- --- ADF: 取込・入替に必要な権限 (最後に所有権移譲) ------------------------
-- Script Activity は TRUNCATE(staging) / INSERT / UPSERT / DELETE を行うため対象テーブルの所有権を ADF へ移す
-- (案11 では DROP/RENAME はしない。TRUNCATE は所有権が必要なので OWNER 移譲は引き続き行う)。
-- 所有権移譲には実行ロールが移譲先ロールのメンバである必要があるため自身に付与する。
-- (func/jumpbox への明示 GRANT は OWNER 変更後も保持される)
GRANT "ci00-adf" TO CURRENT_USER;

GRANT CONNECT ON DATABASE appdb TO "ci00-adf";
-- CREATE が必要: 下の ALTER TABLE ... OWNER TO "ci00-adf" は PostgreSQL の仕様で
-- 「新オーナーがスキーマに CREATE 権限を持つこと」を要求する (無いと permission denied for schema public)。
-- ※ パイプライン実行時 (案11 の UPSERT/DELETE/TRUNCATE) には CREATE 不要だが、所有権移譲のため付与する。
GRANT USAGE, CREATE ON SCHEMA public TO "ci00-adf";
ALTER TABLE customer_info_landing OWNER TO "ci00-adf";
ALTER TABLE customer_info_production OWNER TO "ci00-adf";
ALTER TABLE customer_info_staging OWNER TO "ci00-adf";
ALTER TABLE customer_info_error OWNER TO "ci00-adf";
