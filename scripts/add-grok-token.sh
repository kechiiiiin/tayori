#!/bin/bash
# Grok Bot が音沙汰（tayori）へ投稿を送るためのサービストークンを足す一回きりの設定。秘密の値は画面に出さず、キーチェーンにだけ置く。
# アプリ用のトークン tayori-app には触らない（回し直さない）。何度流しても同じ結果になる（ただし Grok 用の秘密は毎回回し直す）。
#
#   1. サービストークン tayori-grok-bot を作る（あれば回し直す）→ キーチェーン tayori-grok-token
#   2. Access アプリ「tayori」のポリシーに、tayori-app と並べてこのトークンを足す
#   3. Worker secret ACCESS_SERVICE_CLIENT_IDS を「アプリ用,Grok 用」の2本にする
#
# 要るもの: キーチェーン cloudflare-admin-token（Access 編集）・cloudflare-deploy-token（Workers 編集）・tayori-token（アプリ用の client-id）
set -euo pipefail

TOKEN_NAME=tayori-grok-bot
KC=tayori-grok-token
APP_TOKEN_NAME=tayori-app
APP_NAME=tayori

cd "$(dirname "$0")/../worker"
ADMIN=$(security find-generic-password -s cloudflare-admin-token -w)
api() { curl -sS -H "Authorization: Bearer $ADMIN" -H "Content-Type: application/json" "$@"; }
ok() { python3 -c 'import sys,json;d=json.load(sys.stdin);sys.exit(0 if d.get("success") else (print(d.get("errors"),file=sys.stderr) or 1))'; }
field() { python3 -c "import sys,json;print(json.load(sys.stdin)['result']['$1'])"; }
token_id() { api "$B/service_tokens" | python3 -c "import sys,json;print(next((t['id'] for t in json.load(sys.stdin)['result'] if t['name']=='$1'),''))"; }

ACC=$(api "https://api.cloudflare.com/client/v4/zones?name=kechiiiiin.com" | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"][0]["account"]["id"])')
B=https://api.cloudflare.com/client/v4/accounts/$ACC/access

# 1. Grok 用トークン
APP_TID=$(token_id "$APP_TOKEN_NAME")
[ -n "$APP_TID" ] || { echo "アプリ用トークン $APP_TOKEN_NAME が見つかりません" >&2; exit 1; }
TID=$(token_id "$TOKEN_NAME")
if [ -z "$TID" ]; then
  R=$(api -X POST "$B/service_tokens" -d "{\"name\":\"$TOKEN_NAME\",\"duration\":\"forever\"}")
else
  R=$(api -X POST "$B/service_tokens/$TID/rotate")
fi
echo "$R" | ok
TID=$(echo "$R" | field id)
CID=$(echo "$R" | field client_id)
security add-generic-password -U -s "$KC" -a client-id -w "$CID"
security add-generic-password -U -s "$KC" -a client-secret -w "$(echo "$R" | field client_secret)"
unset R
echo "1. トークン $TOKEN_NAME をキーチェーン $KC に保存"

# 2. ポリシー（アプリ用と Grok 用の2本を通す）
APP=$(api "$B/apps" | python3 -c "import sys,json;print(next((a['id'] for a in json.load(sys.stdin)['result'] if a.get('name')=='$APP_NAME'),''))")
[ -n "$APP" ] || { echo "Access アプリ $APP_NAME が見つかりません" >&2; exit 1; }
P="{\"name\":\"family service token\",\"decision\":\"non_identity\",\"precedence\":1,\"include\":[{\"service_token\":{\"token_id\":\"$APP_TID\"}},{\"service_token\":{\"token_id\":\"$TID\"}}]}"
PID=$(api "$B/apps/$APP/policies" | python3 -c "import sys,json;r=json.load(sys.stdin).get('result') or [];print(r[0]['id'] if r else '')")
if [ -z "$PID" ]; then
  api -X POST "$B/apps/$APP/policies" -d "$P" | ok
else
  api -X PUT "$B/apps/$APP/policies/$PID" -d "$P" | ok
fi
echo "2. ポリシー: Service Auth（$APP_TOKEN_NAME と $TOKEN_NAME）"

# 3. Worker secret
APP_CID=$(security find-generic-password -s tayori-token -a client-id -w)
export CLOUDFLARE_API_TOKEN=$(security find-generic-password -s cloudflare-deploy-token -w)
printf '%s' "$APP_CID,$CID" | npx wrangler secret put ACCESS_SERVICE_CLIENT_IDS >/dev/null
echo "3. Worker secret ACCESS_SERVICE_CLIENT_IDS をアプリ用と Grok 用の2本に"
echo "完了"
