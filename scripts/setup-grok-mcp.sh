#!/bin/bash
# Grok Bot（裏側は Cursor）が音沙汰の MCP へつなげるようにする一回きりの設定。秘密の値は画面に出さず、キーチェーンにだけ置く。
# Cursor はヘッダを付ける前に OAuth の確認を投げ、Access の 403 HTML で「network blocked」になる。そこで MCP の入口だけを
# Access の外に出し、Worker 自身が Bearer トークン（MCP_TOKENS）で守る。/api/* は今まで通り Access の内側。
# 何度流しても同じ結果になる（ただしトークンは毎回作り直すので、Grok Bot のヘッダも貼り直す）。
#
#   1. Access アプリ「tayori-mcp」（Bypass）で /mcp と OAuth の確認のパスだけを素通しにする
#   2. トークンを作ってキーチェーン tayori-grok-mcp へ
#   3. Worker secret MCP_TOKENS に入れる
#   4. 本番の /mcp に、トークン無しで 401・トークン付きで 200 が返るのを確かめる
#
# 要るもの: キーチェーン cloudflare-admin-token（Access 編集）・cloudflare-deploy-token（Workers 編集）
set -euo pipefail

HOST=tayori.kechiiiiin.com
APP_NAME=tayori-mcp
KC=tayori-grok-mcp

cd "$(dirname "$0")/../worker"
ADMIN=$(security find-generic-password -s cloudflare-admin-token -w)
api() { curl -sS -H "Authorization: Bearer $ADMIN" -H "Content-Type: application/json" "$@"; }
ok() { python3 -c 'import sys,json;d=json.load(sys.stdin);sys.exit(0 if d.get("success") else (print(d.get("errors"),file=sys.stderr) or 1))'; }
field() { python3 -c "import sys,json;print(json.load(sys.stdin)['result']['$1'])"; }

ACC=$(api "https://api.cloudflare.com/client/v4/zones?name=kechiiiiin.com" | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"][0]["account"]["id"])')
B=https://api.cloudflare.com/client/v4/accounts/$ACC/access

# 1. Access アプリ（パスが具体的な方が tayori 本体より優先される）
DESTS=""
for p in /mcp /.well-known/oauth-protected-resource /.well-known/oauth-authorization-server /.well-known/openid-configuration; do
  DESTS="$DESTS{\"type\":\"public\",\"uri\":\"$HOST$p\"},"
done
DESTS="[${DESTS%,}]"
APP=$(api "$B/apps" | python3 -c "import sys,json;print(next((a['id'] for a in json.load(sys.stdin)['result'] if a.get('name')=='$APP_NAME'),''))")
BODY="{\"name\":\"$APP_NAME\",\"type\":\"self_hosted\",\"domain\":\"$HOST/mcp\",\"destinations\":$DESTS,\"session_duration\":\"24h\",\"app_launcher_visible\":false}"
if [ -z "$APP" ]; then
  R=$(api -X POST "$B/apps" -d "$BODY")
else
  R=$(api -X PUT "$B/apps/$APP" -d "$BODY")
fi
echo "$R" | ok
APP=$(echo "$R" | field id)
P='{"name":"bypass (Worker checks MCP_TOKENS)","decision":"bypass","precedence":1,"include":[{"everyone":{}}]}'
PID=$(api "$B/apps/$APP/policies" | python3 -c "import sys,json;r=json.load(sys.stdin).get('result') or [];print(r[0]['id'] if r else '')")
if [ -z "$PID" ]; then
  api -X POST "$B/apps/$APP/policies" -d "$P" | ok
else
  api -X PUT "$B/apps/$APP/policies/$PID" -d "$P" | ok
fi
echo "1. Access アプリ $APP_NAME（/mcp と OAuth の確認だけ素通し）"

# 2. トークン（英数字 48 文字）
TOKEN=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 48)
security add-generic-password -U -s "$KC" -a token -w "$TOKEN"
echo "2. トークンをキーチェーン $KC に保存"

# 3. Worker secret（失敗はそのまま画面に出す）
export CLOUDFLARE_API_TOKEN=$(security find-generic-password -s cloudflare-deploy-token -w)
printf '%s' "$TOKEN" | npx wrangler secret put MCP_TOKENS
npx wrangler secret list | grep -q '"MCP_TOKENS"' || { echo "MCP_TOKENS が Worker に見当たりません" >&2; exit 1; }
echo "3. Worker secret MCP_TOKENS を設定"

# 4. 本番で確かめる（反映を少し待つ）
sleep 5
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"setup","version":"0"}}}'
NO=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "$INIT" "https://$HOST/mcp")
YES=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" -d "$INIT" "https://$HOST/mcp")
WK=$(curl -s -o /dev/null -w '%{http_code}' "https://$HOST/.well-known/oauth-protected-resource")
unset TOKEN
echo "4. トークン無し $NO（401 なら正しい）・トークン付き $YES（200 なら正しい）・OAuth の確認 $WK（404 なら正しい）"
[ "$NO" = 401 ] && [ "$YES" = 200 ] && [ "$WK" = 404 ] && echo "完了" || { echo "期待と違う応答があります" >&2; exit 1; }
