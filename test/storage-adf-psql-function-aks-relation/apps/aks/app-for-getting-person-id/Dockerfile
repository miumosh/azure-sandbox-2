# 本人特定 (id 取得) クライアントアプリ用イメージ
FROM python:3.11-slim

WORKDIR /app

# 依存関係を先にインストールしてレイヤキャッシュを効かせる
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# アプリ本体をコピー
COPY main.py .

EXPOSE 8000

# uvicorn で FastAPI アプリを起動する
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
