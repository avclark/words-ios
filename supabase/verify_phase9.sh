#!/bin/bash
# Verifies Phase 9 (idempotent ops, expiry warn-then-expire, resign,
# rematch) with throwaway users. Run AFTER phase9_robustness.sql.
# All users this script creates are deleted on exit, success or failure.
#
# Usage:  SUPABASE_SECRET_KEY=sb_secret_... ./verify_phase9.sh

set -euo pipefail

URL="https://wdbouucicnxeoomazerx.supabase.co"
KEY="${SUPABASE_SECRET_KEY:?Set SUPABASE_SECRET_KEY=sb_secret_...}"
TS=$(date +%s)

step() { printf '\n== %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
py()   { python3 -c "$1"; }

CREATED=()
cleanup() {
  local status=$?
  for id in "${CREATED[@]:-}"; do
    [ -n "$id" ] && curl -s -o /dev/null -X DELETE "$URL/auth/v1/admin/users/$id" \
      -H "apikey: $KEY" -H "Authorization: Bearer $KEY" || true
  done
  printf '\ncleanup: removed %d test user(s)%s\n' "${#CREATED[@]}" \
    "$([ $status -ne 0 ] && echo ' (after failure)')"
}
trap cleanup EXIT

make_user() {
  local id token
  id=$(curl -sf -X POST "$URL/auth/v1/admin/users" \
    -H "apikey: $KEY" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -d "{\"email\":\"$1\",\"password\":\"pw-$TS\",\"email_confirm\":true}" \
    | py 'import json,sys; print(json.load(sys.stdin)["id"])')
  token=$(curl -sf -X POST "$URL/auth/v1/token?grant_type=password" \
    -H "apikey: $KEY" -H "Content-Type: application/json" \
    -d "{\"email\":\"$1\",\"password\":\"pw-$TS\"}" \
    | py 'import json,sys; print(json.load(sys.stdin)["access_token"])')
  echo "$id $token"
}

rpc() {
  curl -sf -X POST "$URL/rest/v1/rpc/$2" \
    -H "apikey: $KEY" -H "Authorization: Bearer $1" \
    -H "Content-Type: application/json" -d "$3"
}

admin_rpc() {  # service-role call (process_game_expiry)
  curl -sf -X POST "$URL/rest/v1/rpc/$1" \
    -H "apikey: $KEY" -H "Authorization: Bearer $KEY" \
    -H "Content-Type: application/json" -d "$2"
}

step "0. Create two throwaway users, friend them, start a human game"
read -r USER_A TOKEN_A <<< "$(make_user "p9a-$TS@example.com")"; CREATED+=("$USER_A")
read -r USER_B TOKEN_B <<< "$(make_user "p9b-$TS@example.com")"; CREATED+=("$USER_B")
INVITE=$(rpc "$TOKEN_A" create_invite '{}' | py 'import json,sys; print(json.load(sys.stdin)["token"])')
rpc "$TOKEN_B" redeem_invite "{\"p_token\":\"$INVITE\"}" > /dev/null
GAME=$(rpc "$TOKEN_A" create_game "{\"p_opponent\":\"$USER_B\"}" \
  | py 'import json,sys; print(json.load(sys.stdin)["game_id"])')
echo "   game=$GAME"

step "1. Idempotent submission: same op id twice applies once"
A_LETTER=$(rpc "$TOKEN_A" fetch_game "{\"p_game_id\":\"$GAME\"}" \
  | py 'import json,sys; r=json.load(sys.stdin)["players"][0]["rack"]; print(next(l for l in r if l!="?"))')
OP_ID=$(py 'import uuid; print(uuid.uuid4())')
R1=$(rpc "$TOKEN_A" submit_move "{\"p_game_id\":\"$GAME\",\"p_seat\":0,\"p_kind\":\"play\",
  \"p_placements\":[{\"row\":7,\"col\":7,\"letter\":\"$A_LETTER\",\"blank\":false}],
  \"p_word\":\"$A_LETTER\",\"p_client_score\":3,\"p_op_id\":\"$OP_ID\"}")
echo "$R1" | py 'import json,sys; d=json.load(sys.stdin); assert d["duplicate"]==False and len(d["drawn"])==1, d' \
  || fail "first submit: $R1"
R2=$(rpc "$TOKEN_A" submit_move "{\"p_game_id\":\"$GAME\",\"p_seat\":0,\"p_kind\":\"play\",
  \"p_placements\":[{\"row\":7,\"col\":7,\"letter\":\"$A_LETTER\",\"blank\":false}],
  \"p_word\":\"$A_LETTER\",\"p_client_score\":3,\"p_op_id\":\"$OP_ID\"}")
echo "$R2" | py 'import json,sys; d=json.load(sys.stdin); assert d["duplicate"]==True and len(d["rack"])==7, d' \
  || fail "replay not deduped: $R2"
rpc "$TOKEN_A" fetch_game "{\"p_game_id\":\"$GAME\"}" | py '
import json,sys
d=json.load(sys.stdin)
assert d["turn_number"]==2 and len(d["moves"])==1, (d["turn_number"], len(d["moves"]))
assert d["players"][0]["score"]==3, "score double-applied"
print("   applied exactly once; replay returned current rack ✓")' || fail "dedupe state"

step "2. Expiry: warn first, never silently"
admin_rpc process_game_expiry '{}' > /dev/null
# Fresh game must be untouched (14-day window).
rpc "$TOKEN_A" fetch_game "{\"p_game_id\":\"$GAME\"}" | py '
import json,sys; d=json.load(sys.stdin)
assert d["status"]=="active" and d["expiry_warned_at"] is None, d["status"]
print("   fresh game untouched ✓")' || fail "fresh game touched by expiry job"
# Simulate near-deadline: job must WARN, not expire.
curl -sf -X PATCH "$URL/rest/v1/games?id=eq.$GAME" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"expires_at":"2020-01-01T00:00:00Z"}' > /dev/null
admin_rpc process_game_expiry '{}' > /dev/null
rpc "$TOKEN_A" fetch_game "{\"p_game_id\":\"$GAME\"}" | py '
import json,sys; d=json.load(sys.stdin)
assert d["status"]=="active" and d["expiry_warned_at"] is not None, (d["status"], d["expiry_warned_at"])
print("   past-deadline game got a WARNING, still active ✓")' || fail "warn step"
# Only after the warning has stood for 24h does it expire.
curl -sf -X PATCH "$URL/rest/v1/games?id=eq.$GAME" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"expiry_warned_at":"2020-01-01T00:00:00Z"}' > /dev/null
admin_rpc process_game_expiry '{}' > /dev/null
rpc "$TOKEN_B" fetch_game "{\"p_game_id\":\"$GAME\"}" | py '
import json,sys; d=json.load(sys.stdin)
assert d["status"]=="expired" and d["end_reason"]=="expired", d["status"]
assert d["winner_seat"]==0, "inactive seat 1 must forfeit; winner should be 0"
print("   expired after 24h-old warning; inactive player forfeits ✓")' || fail "expire step"

step "3. Playing a move resets the expiry clock"
GAME2=$(rpc "$TOKEN_A" create_game "{\"p_opponent\":\"$USER_B\"}" \
  | py 'import json,sys; print(json.load(sys.stdin)["game_id"])')
curl -sf -X PATCH "$URL/rest/v1/games?id=eq.$GAME2" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"expires_at":"2020-01-01T00:00:00Z","expiry_warned_at":"2020-01-01T00:00:00Z"}' > /dev/null
rpc "$TOKEN_A" submit_move "{\"p_game_id\":\"$GAME2\",\"p_seat\":0,\"p_kind\":\"pass\"}" > /dev/null
rpc "$TOKEN_A" fetch_game "{\"p_game_id\":\"$GAME2\"}" | py '
import json,sys, datetime
d=json.load(sys.stdin)
assert d["expiry_warned_at"] is None, "warning must clear on activity"
exp=d["expires_at"]
assert exp > "2026", exp
print("   activity resets deadline + clears warning ✓")' || fail "expiry reset"

step "4. Resign: opponent sees a real game-over"
rpc "$TOKEN_B" resign_game "{\"p_game_id\":\"$GAME2\"}" > /dev/null
rpc "$TOKEN_A" fetch_game "{\"p_game_id\":\"$GAME2\"}" | py '
import json,sys; d=json.load(sys.stdin)
assert d["status"]=="resigned" and d["winner_seat"]==0, (d["status"], d.get("winner_seat"))
assert any(m["kind"]=="resign" for m in d["moves"]), "resign move not recorded"
print("   B resigned; A sees resigned + A wins ✓")' || fail "resign"

step "5. Rematch: both players tap, exactly one game"
RM_A=$(rpc "$TOKEN_A" request_rematch "{\"p_game_id\":\"$GAME2\"}")
RM_B=$(rpc "$TOKEN_B" request_rematch "{\"p_game_id\":\"$GAME2\"}")
NEW_A=$(echo "$RM_A" | py 'import json,sys; d=json.load(sys.stdin); print(d["game_id"])')
NEW_B=$(echo "$RM_B" | py 'import json,sys; d=json.load(sys.stdin); print(d["game_id"])')
[ "$NEW_A" = "$NEW_B" ] || fail "two rematch games created: $NEW_A vs $NEW_B"
echo "$RM_A" | py 'import json,sys; d=json.load(sys.stdin); assert d["created"]==True and d["my_seat"]==0 and len(d["my_rack"])==7, d' \
  || fail "A rematch shape: $RM_A"
echo "$RM_B" | py 'import json,sys; d=json.load(sys.stdin); assert d["created"]==False and d["my_seat"]==1 and len(d["my_rack"])==7 and d["opponent"]["display_name"], d' \
  || fail "B rematch shape: $RM_B"
RM_AGAIN=$(rpc "$TOKEN_A" request_rematch "{\"p_game_id\":\"$GAME2\"}" | py 'import json,sys; print(json.load(sys.stdin)["game_id"])')
[ "$RM_AGAIN" = "$NEW_A" ] || fail "repeat rematch made another game"
echo "   one game ($NEW_A), A seat 0 created, B seat 1 joined ✓"

step "6. AI games are exempt from expiry"
AI_GAME=$(rpc "$TOKEN_A" create_game '{"p_ai_difficulty":"easy"}' \
  | py 'import json,sys; print(json.load(sys.stdin)["game_id"])')
curl -sf -X PATCH "$URL/rest/v1/games?id=eq.$AI_GAME" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"expires_at":"2020-01-01T00:00:00Z"}' > /dev/null
admin_rpc process_game_expiry '{}' > /dev/null
rpc "$TOKEN_A" fetch_game "{\"p_game_id\":\"$AI_GAME\"}" | py '
import json,sys; d=json.load(sys.stdin)
assert d["status"]=="active" and d["expiry_warned_at"] is None, d["status"]
print("   solo AI game never warned/expired ✓")' || fail "AI game expired"

printf '\nALL PHASE 9 CHECKS PASSED\n'
