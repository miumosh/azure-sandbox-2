import azure.functions as func

from api import bp as customer_search_bp

# 既定の HTTP 認証レベルを Function キーにする (各 route でも明示)
app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)

# 用途別 Blueprint を登録
app.register_functions(customer_search_bp)
