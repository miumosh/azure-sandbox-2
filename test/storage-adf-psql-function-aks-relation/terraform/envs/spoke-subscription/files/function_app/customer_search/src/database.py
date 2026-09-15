from __future__ import annotations

import os

from azure.identity import DefaultAzureCredential

# Azure Database for PostgreSQL の AAD トークン取得用スコープ
_PSQL_AAD_SCOPE = "https://ossrdbms-aad.database.windows.net/.default"

# マネージドID を自動検出するクレデンシャル (トークンは SDK 側でキャッシュ・更新)
_credential = DefaultAzureCredential()


def connection_string() -> str:
    """環境変数 + AAD トークンから psycopg 用の接続文字列を組み立て"""

    host = os.environ["PSQL_HOST"]
    database = os.environ["PSQL_DATABASE"]
    user = os.environ["PSQL_USER"]
    port = os.environ.get("PSQL_PORT", "5432")
    sslmode = os.environ.get("PSQL_SSLMODE", "require")
    token = _credential.get_token(_PSQL_AAD_SCOPE).token
    return (
        f"host={host} port={port} dbname={database} "
        f"user={user} password={token} sslmode={sslmode}"
    )
