#!/bin/bash
# Verifies Phase 10 (notification outbox, prefs, ping rate limit, event
# triggers) with throwaway users — everything provable without a device.
# Run AFTER phase10_notifications.sql. Users are cleaned up on exit.
#
# Usage:  SUPABASE_SECRET_KEY=sb_secret_... ./verify_phase10.sh

set -euo pipefail

URL="https://wdbouucicnxeoomazerx.supabase.co"
KEY="${SUPABASE_SECRET_KEY:?Set SUPABASE_SECRET_KEY=sb_secret_...}"
TS=$(date +%s)

step() { printf '\n== %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
py()   { python3 -c "$1"; }

# Robust teardown + loud death. History: a piped invocation once SIGPIPEd
# a script mid-run — bash dies on untrapped fatal signals WITHOUT running
# the EXIT trap, so it aborted silently AND stranded its test users. Now:
# every abort reports the failing line/command to stderr and to
# /tmp/words-verify.log (stdout may be the thing that died), cleanup runs
# on signals too, and ERR reporting reaches inside functions (set -E).
set -E
CREATED=()
CLEANED=0
diag() {
  printf '%s\n' "$*" >&2 || true
  printf '%s %s: %s\n' "$(date '+%H:%M:%S')" "$(basename "$0")" "$*" \
    >> /tmp/words-verify.log 2>/dev/null || true
}
cleanup() {
  local status=$?
  [ "$CLEANED" = 1 ] && return 0
  CLEANED=1
  for id in "${CREATED[@]:-}"; do
    [ -n "$id" ] || continue
    # Deletes retry: a transient 403/reset here is how users get stranded.
    curl -sf -o /dev/null -X DELETE "$URL/auth/v1/admin/users/$id" \
      -H "apikey: $KEY" -H "Authorization: Bearer $KEY" \
      || { sleep 1; curl -s -o /dev/null -X DELETE "$URL/auth/v1/admin/users/$id" \
           -H "apikey: $KEY" -H "Authorization: Bearer $KEY" || true; }
  done
  diag "cleanup: removed ${#CREATED[@]} test user(s)$([ $status -ne 0 ] && echo ' (after abnormal exit)')"
}
trap 'diag "ABORT at line $LINENO: [$BASH_COMMAND] exited $?"' ERR
trap 'diag "killed by signal (INT/TERM/PIPE)"; cleanup; exit 130' INT TERM PIPE
trap cleanup EXIT

jwt_sub() {  # user id from a JWT access token (never tracebacks)
  python3 -c '
import base64, json, sys
try:
    p = sys.argv[1].split(".")[1]
    p += "=" * (-len(p) % 4)
    print(json.loads(base64.urlsafe_b64decode(p)).get("sub", ""))
except Exception:
    pass
' "$1"
}

make_user() {  # $1 = email; echoes "user_id access_token"
  # Retries transient failures with per-attempt diagnostics (curl exit
  # codes visible — suppressed stderr once hid the real cause). A create
  # whose response is lost cannot strand a user: the id is recovered
  # from the sign-in JWT, so cleanup always knows about it.
  local id="" token="" attempt rc out
  for attempt in 1 2 3; do
    rc=0
    out=$(curl -sf -X POST "$URL/auth/v1/admin/users" \
      -H "apikey: $KEY" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
      -d "{\"email\":\"$1\",\"password\":\"pw-$TS\",\"email_confirm\":true}") || rc=$?
    id=$(printf '%s' "$out" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("id", ""))
except Exception:
    pass
')
    [ -n "$id" ] && break
    diag "make_user: create attempt $attempt for $1 failed (curl exit $rc)"
    sleep "$attempt"
  done
  for attempt in 1 2 3; do
    rc=0
    out=$(curl -sf -X POST "$URL/auth/v1/token?grant_type=password" \
      -H "apikey: $KEY" -H "Content-Type: application/json" \
      -d "{\"email\":\"$1\",\"password\":\"pw-$TS\"}") || rc=$?
    token=$(printf '%s' "$out" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("access_token", ""))
except Exception:
    pass
')
    [ -n "$token" ] && break
    diag "make_user: sign-in attempt $attempt for $1 failed (curl exit $rc)"
    sleep "$attempt"
  done
  [ -n "$token" ] || { diag "make_user: could not sign in $1 — aborting"; exit 1; }
  [ -n "$id" ] || id=$(jwt_sub "$token")
  [ -n "$id" ] || { diag "make_user: no user id for $1 — aborting"; exit 1; }
  echo "$id $token"
}

rpc() {
  [ -n "$1" ] || { diag "rpc called with EMPTY token — refusing (would escalate to service_role)"; exit 1; }
  curl -sf --retry 2 --retry-delay 1 -X POST "$URL/rest/v1/rpc/$2" \
    -H "apikey: $KEY" -H "Authorization: Bearer $1" \
    -H "Content-Type: application/json" -d "$3"
}

outbox() {  # $1 = query string; service-role read of the outbox
  curl -s "$URL/rest/v1/notification_outbox?$1" \
    -H "apikey: $KEY" -H "Authorization: Bearer $KEY"
}

play_letter() {  # $1 token, $2 game, $3 seat — plays first non-blank rack letter
  local L
  L=$(rpc "$1" fetch_game "{\"p_game_id\":\"$2\"}" \
    | python3 -c '
import json, sys
seat = int(sys.argv[1])
rack = json.load(sys.stdin)["players"][seat]["rack"]
print(next(l for l in rack if l != "?"))
' "$3")
  ROW=$((7 + $3)); COL=$((3 + RANDOM % 9))
  rpc "$1" submit_move "{\"p_game_id\":\"$2\",\"p_seat\":$3,\"p_kind\":\"play\",
    \"p_placements\":[{\"row\":$ROW,\"col\":$COL,\"letter\":\"$L\",\"blank\":false}],
    \"p_word\":\"$L\",\"p_client_score\":2}" > /dev/null
}

step "0. Users, friendship, game, device token"
read -r USER_A TOKEN_A <<< "$(make_user "p10a-$TS@example.com")"; CREATED+=("$USER_A")
[ -n "${USER_A:-}" ] && [ -n "${TOKEN_A:-}" ] || fail "USER_A setup incomplete"
read -r USER_B TOKEN_B <<< "$(make_user "p10b-$TS@example.com")"; CREATED+=("$USER_B")
[ -n "${USER_B:-}" ] && [ -n "${TOKEN_B:-}" ] || fail "USER_B setup incomplete"
INVITE=$(rpc "$TOKEN_A" create_invite '{}' | py 'import json,sys; print(json.load(sys.stdin)["token"])')
rpc "$TOKEN_B" redeem_invite "{\"p_token\":\"$INVITE\"}" > /dev/null
rpc "$TOKEN_B" register_device_token "{\"p_token\":\"fake-token-$TS\"}" > /dev/null
GAME=$(rpc "$TOKEN_A" create_game "{\"p_opponent\":\"$USER_B\"}" \
  | py 'import json,sys; print(json.load(sys.stdin)["game_id"])')
echo "   game=$GAME, B has a (fake) device token"

step "1. Challenge produced a new_game notification for B (not A)"
outbox "game_id=eq.$GAME&type=eq.new_game&select=recipient,title,body" | py "
import json,sys
rows=json.load(sys.stdin)
assert len(rows)==1 and rows[0]['recipient']=='$USER_B', rows
assert 'challenged' in rows[0]['body'], rows[0]
print('   new_game → B only ✓')" || fail "new_game notification"

step "2. A plays → turn notification for B with badge"
play_letter "$TOKEN_A" "$GAME" 0
outbox "game_id=eq.$GAME&type=eq.turn&select=recipient,badge,body" | py "
import json,sys
rows=json.load(sys.stdin)
assert len(rows)==1 and rows[0]['recipient']=='$USER_B', rows
assert rows[0]['badge']==1, ('badge', rows[0]['badge'])
print('   turn → B, badge=1 ✓')" || fail "turn notification"

step "3. Server-side prefs: B disables 'turn', plays continue, no new row"
curl -sf -X POST "$URL/rest/v1/notification_prefs" \
  -H "apikey: $KEY" -H "Authorization: Bearer $TOKEN_B" \
  -H "Content-Type: application/json" -H "Prefer: resolution=merge-duplicates" \
  -d "{\"user_id\":\"$USER_B\",\"turn\":false}" > /dev/null
rpc "$TOKEN_B" submit_move "{\"p_game_id\":\"$GAME\",\"p_seat\":1,\"p_kind\":\"pass\"}" > /dev/null
play_letter "$TOKEN_A" "$GAME" 0
COUNT=$(outbox "game_id=eq.$GAME&type=eq.turn&recipient=eq.$USER_B&select=id" | py 'import json,sys; print(len(json.load(sys.stdin)))')
[ "$COUNT" = "1" ] || fail "turn row inserted despite disabled pref (count=$COUNT)"
# A (prefs untouched) DID get one for B's pass.
COUNT_A=$(outbox "game_id=eq.$GAME&type=eq.turn&recipient=eq.$USER_A&select=id" | py 'import json,sys; print(len(json.load(sys.stdin)))')
[ "$COUNT_A" = "1" ] || fail "A should have exactly one turn row (got $COUNT_A)"
echo "   disabled type never enters the outbox; other user unaffected ✓"

step "4. Ping: works on opponent's turn, rate-limited, direction-checked"
rpc "$TOKEN_A" ping_opponent "{\"p_game_id\":\"$GAME\"}" | grep -q '"sent"' || fail "ping should send (B on turn)"
rpc "$TOKEN_A" ping_opponent "{\"p_game_id\":\"$GAME\"}" | py '
import json,sys
d=json.load(sys.stdin)
assert d["status"]=="cooldown" and d["retry_after_minutes"]>300, d
print("   second ping → cooldown (~6h) ✓")' || fail "ping rate limit"
rpc "$TOKEN_B" ping_opponent "{\"p_game_id\":\"$GAME\"}" | grep -q "not_their_turn" || fail "B pinging on own turn should refuse"
outbox "game_id=eq.$GAME&type=eq.ping&select=recipient" | py "
import json,sys
rows=json.load(sys.stdin)
assert len(rows)==1 and rows[0]['recipient']=='$USER_B', rows
print('   exactly one ping row → B ✓')" || fail "ping outbox"

step "5. Resign → game_over for the opponent only"
rpc "$TOKEN_A" resign_game "{\"p_game_id\":\"$GAME\"}" > /dev/null
outbox "game_id=eq.$GAME&type=eq.game_over&select=recipient,body" | py "
import json,sys
rows=json.load(sys.stdin)
assert len(rows)==1 and rows[0]['recipient']=='$USER_B', rows
assert 'resigned' in rows[0]['body'] and 'win' in rows[0]['body'], rows[0]
print('   game_over → B only, correct copy ✓')" || fail "game_over notification"

step "6. Expiry warning rides the Phase 9 job"
GAME2=$(rpc "$TOKEN_A" create_game "{\"p_opponent\":\"$USER_B\"}" \
  | py 'import json,sys; print(json.load(sys.stdin)["game_id"])')
curl -sf -X PATCH "$URL/rest/v1/games?id=eq.$GAME2" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"expires_at":"2020-01-01T00:00:00Z"}' > /dev/null
curl -sf -X POST "$URL/rest/v1/rpc/process_game_expiry" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" -d '{}' > /dev/null
outbox "game_id=eq.$GAME2&type=eq.expiry_warning&select=recipient,body" | py "
import json,sys
rows=json.load(sys.stdin)
assert len(rows)==1 and rows[0]['recipient']=='$USER_A', rows
assert 'expires today' in rows[0]['body'], rows[0]
print('   expiry_warning → player on turn ✓')" || fail "expiry warning"

step "7. Solo AI games never notify"
AI_GAME=$(rpc "$TOKEN_A" create_game '{"p_ai_difficulty":"easy"}' \
  | py 'import json,sys; print(json.load(sys.stdin)["game_id"])')
play_letter "$TOKEN_A" "$AI_GAME" 0
rpc "$TOKEN_A" submit_move "{\"p_game_id\":\"$AI_GAME\",\"p_seat\":1,\"p_kind\":\"pass\"}" > /dev/null
COUNT=$(outbox "game_id=eq.$AI_GAME&select=id" | py 'import json,sys; print(len(json.load(sys.stdin)))')
[ "$COUNT" = "0" ] || fail "AI game produced $COUNT notification(s)"
echo "   zero rows for solo play ✓"

step "8. Chat plumbing ready (Phase 11)"
# Phase 11 closed direct inserts; chat goes through send_chat.
rpc "$TOKEN_B" send_chat "{\"p_game_id\":\"$GAME2\",\"p_body\":\"good game!\"}" > /dev/null
outbox "game_id=eq.$GAME2&type=eq.chat&select=recipient,body" | py "
import json,sys
rows=json.load(sys.stdin)
assert len(rows)==1 and rows[0]['recipient']=='$USER_A', rows
assert rows[0]['body']=='good game!', rows[0]
print('   chat message → other participant ✓')" || fail "chat notification"

step "9. Edge function (skipped unless deployed)"
FN=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL/functions/v1/send-push" \
  -H "Content-Type: application/json" -d '{}')
if [ "$FN" = "404" ] || [ "$FN" = "503" ]; then
  echo "   send-push not deployed yet — deploy it, then re-run (HTTP $FN)"
else
  sleep 3
  outbox "game_id=eq.$GAME&type=eq.ping&select=sent_at,error" | py '
import json,sys
rows=json.load(sys.stdin)
r=rows[0]
assert r["sent_at"] is not None, "row not drained"
err = r["error"]
print("   drained: sent_at set, error=%r (fake token -> APNs error is EXPECTED)" % err)' \
    || fail "outbox not drained by edge function"
fi

printf '\nALL PHASE 10 CHECKS PASSED\n'
