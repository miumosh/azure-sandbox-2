-- ============================================================================
-- create-database.sql
--
-- Azure Bastion 経由で踏み台 VM に接続し、踏み台から psql で
-- Azure Database for PostgreSQL のプライベートエンドポイントへ接続して実行する。
--
-- 実行例 (踏み台 VM 上):
--   psql "host=<psql-fqdn> port=5432 dbname=postgres user=<admin>@<server> \
--         sslmode=require" -f create-database.sql
--
-- 注意:
--   - 本構成では appdb は Terraform (azurerm_postgresql_flexible_server_database.app) が
--     作成するため、通常このスクリプトは不要（実行すると "database appdb already exists"）。
--     DB を IaC で作らない環境向けの参考として残している。
--   - CREATE DATABASE はトランザクション内で実行できないため独立した
--     スクリプトとして分離している (テーブル作成は create-tables.sql)。
--   - 本スクリプトは管理者 (psqladmin) で 1 度だけ実行する想定。
-- ============================================================================

-- アプリ用データベースを作成 (既に存在する場合は手動でスキップ)
-- PostgreSQL には CREATE DATABASE IF NOT EXISTS が無いため、
-- 二重実行を避けたい場合は事前に \l で存在確認すること。
CREATE DATABASE appdb
    WITH ENCODING = 'UTF8'
         LC_COLLATE = 'en_US.UTF-8'
         LC_CTYPE = 'en_US.UTF-8'
         TEMPLATE = template0;

-- 以降のテーブル作成は appdb に接続し直してから create-tables.sql を実行する:
--   \connect appdb
--   \i create-tables.sql
