#!/bin/bash
# Verifies the Phase 6 server setup end to end WITHOUT needing Apple:
# creates a throwaway user via the auth admin API, checks the signup
# trigger created its profile row, signs in as that user, updates the
# profile as the user would, calls the delete_account RPC, and confirms
# both the user and the profile are gone.
#
# Usage:  SUPABASE_SECRET_KEY=sb_secret_... ./verify.sh
# (The SECRET key is required — admin user creation. Never put it in the app.)

set -euo pipefail

URL="https://wdbouucicnxeoomazerx.supabase.co"
KEY="${SUPABASE_SECRET_KEY:?Set SUPABASE_SECRET_KEY=sb_secret_...}"

EMAIL="verify-$(date +%s)@example.com"
PASS="verify-pass-$(date +%s)"

step() { printf '\n== %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

# The throwaway user is deleted on exit — success OR failure — so a failed
# run never strands a test user.
USER_ID=""
cleanup() {
  [ -n "$USER_ID" ] && curl -s -o /dev/null -X DELETE "$URL/auth/v1/admin/users/$USER_ID" \
    -H "apikey: $KEY" -H "Authorization: Bearer $KEY" || true
}
trap cleanup EXIT

step "1. Create throwaway user via admin API"
USER_ID=$(curl -sf -X POST "$URL/auth/v1/admin/users" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\",\"email_confirm\":true}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])') \
  || fail "admin user creation (is the secret key right?)"
echo "   user: $USER_ID"

step "2. Signup trigger created a profile row"
PROFILE=$(curl -sf "$URL/rest/v1/profiles?id=eq.$USER_ID&select=display_name,avatar" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY")
echo "   profile: $PROFILE"
[ "$PROFILE" != "[]" ] || fail "no profile row — was setup.sql applied?"

step "3. Sign in as the user (password grant)"
TOKEN=$(curl -sf -X POST "$URL/auth/v1/token?grant_type=password" \
  -H "apikey: $KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])') \
  || fail "password sign-in"
echo "   got session token"

step "4. Update own profile with the user's own token (RLS check)"
curl -sf -X PATCH "$URL/rest/v1/profiles?id=eq.$USER_ID" \
  -H "apikey: $KEY" -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -H "Prefer: return=representation" \
  -d '{"display_name":"Verify Bot","avatar":"star"}' | grep -q "Verify Bot" \
  || fail "profile update as user"
echo "   updated"

step "5. delete_account RPC as the user"
curl -sf -X POST "$URL/rest/v1/rpc/delete_account" \
  -H "apikey: $KEY" -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{}' || fail "delete_account RPC"
echo "   called"

step "6. User and profile are really gone"
GONE_PROFILE=$(curl -sf "$URL/rest/v1/profiles?id=eq.$USER_ID&select=id" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY")
[ "$GONE_PROFILE" = "[]" ] || fail "profile still exists: $GONE_PROFILE"
GONE_USER=$(curl -s -o /dev/null -w '%{http_code}' "$URL/auth/v1/admin/users/$USER_ID" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY")
[ "$GONE_USER" = "404" ] || fail "auth user still exists (HTTP $GONE_USER)"
echo "   confirmed deleted"

printf '\nALL CHECKS PASSED — server side is ready (Apple provider still separate).\n'
