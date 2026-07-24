#!/bin/bash
# Verifies the Phase 7 game schema end to end with throwaway users:
# dealing, intent submission, turn/rack enforcement, privacy (bag + racks),
# lobby, finish, and account-deletion cleanup. Run AFTER phase7_games.sql.
#
# Usage:  SUPABASE_SECRET_KEY=sb_secret_... ./verify_phase7.sh

set -euo pipefail

URL="https://wdbouucicnxeoomazerx.supabase.co"
KEY="${SUPABASE_SECRET_KEY:?Set SUPABASE_SECRET_KEY=sb_secret_...}"
TS=$(date +%s)

step() { printf '\n== %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
py()   { python3 -c "$1"; }

# Every user this run creates is deleted on exit — success OR failure —
# so a failed run never strands test users (deleting a user cascades away
# its games via the cleanup trigger).
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

# Sweep test users stranded by PREVIOUS failed runs (recognizable emails).
purge_stale_test_users() {
  curl -s "$URL/auth/v1/admin/users?per_page=1000" \
    -H "apikey: $KEY" -H "Authorization: Bearer $KEY" \
    | py '
import json, sys, re
users = json.load(sys.stdin).get("users") or []
pat = re.compile(r"^(p7[ab]|p8[abc]|p9[ab]|p10[ab]|p11[abc]|dbg-[ab]|verify|smoke-test)-.*@example\.com$")
for u in users:
    if pat.match(u.get("email") or ""): print(u["id"])' \
    | while read -r id; do
        curl -s -o /dev/null -X DELETE "$URL/auth/v1/admin/users/$id" \
          -H "apikey: $KEY" -H "Authorization: Bearer $KEY"
        echo "   purged stale test user $id"
      done
}
step "Purging test users stranded by earlier runs"
purge_stale_test_users

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

rpc() {  # $1 token, $2 fn, $3 json args; echoes body, fails on HTTP error
  [ -n "$1" ] || { diag "rpc called with EMPTY token — refusing (would escalate to service_role)"; exit 1; }
  curl -sf -X POST "$URL/rest/v1/rpc/$2" \
    -H "apikey: $KEY" -H "Authorization: Bearer $1" \
    -H "Content-Type: application/json" -d "$3"
}

rpc_expect_error() {  # $1 token, $2 fn, $3 args, $4 expected message fragment
  local body
  body=$(curl -s -X POST "$URL/rest/v1/rpc/$2" \
    -H "apikey: $KEY" -H "Authorization: Bearer $1" \
    -H "Content-Type: application/json" -d "$3")
  echo "$body" | grep -q "$4" || fail "$2 should have failed with '$4', got: $body"
}

step "0. Create two throwaway users"
read -r USER_A TOKEN_A <<< "$(make_user "p7a-$TS@example.com")"
[ -n "${USER_A:-}" ] && [ -n "${TOKEN_A:-}" ] || fail "USER_A setup incomplete"
CREATED+=("$USER_A")
read -r USER_B TOKEN_B <<< "$(make_user "p7b-$TS@example.com")"
[ -n "${USER_B:-}" ] && [ -n "${TOKEN_B:-}" ] || fail "USER_B setup incomplete"
CREATED+=("$USER_B")
echo "   A=$USER_A"
echo "   B=$USER_B"

step "1. create_game deals 7+7 and keeps 86 in the bag"
CREATE=$(rpc "$TOKEN_A" create_game '{"p_ai_difficulty":"medium"}')
GAME=$(echo "$CREATE" | py 'import json,sys; print(json.load(sys.stdin)["game_id"])')
RACK_LETTER=$(echo "$CREATE" | py 'import json,sys; r=json.load(sys.stdin)["my_rack"]; print(next(l for l in r if l != "?"))')
echo "$CREATE" | py 'import json,sys; d=json.load(sys.stdin); assert len(d["my_rack"])==7 and len(d["ai_rack"])==7 and d["bag_count"]==86, d' \
  || fail "bad deal"
echo "   game=$GAME, playing letter $RACK_LETTER"

step "2. Privacy: game_private unreadable, stranger sees nothing"
PRIV=$(curl -s "$URL/rest/v1/game_private?select=*" -H "apikey: $KEY" -H "Authorization: Bearer $TOKEN_A")
[ "$PRIV" = "[]" ] || echo "$PRIV" | grep -q "permission denied" || fail "game_private readable: $PRIV"
STRANGER=$(rpc "$TOKEN_B" fetch_game "{\"p_game_id\":\"$GAME\"}")
[ "$STRANGER" = "null" ] || [ -z "$STRANGER" ] || fail "stranger can fetch game: $STRANGER"
STRANGER_LOBBY=$(rpc "$TOKEN_B" fetch_lobby '{}')
[ "$STRANGER_LOBBY" = "[]" ] || fail "stranger lobby not empty: $STRANGER_LOBBY"
echo "   locked down"

step "3. submit_move play: intent accepted, one tile drawn"
RES=$(rpc "$TOKEN_A" submit_move "{\"p_game_id\":\"$GAME\",\"p_seat\":0,\"p_kind\":\"play\",
  \"p_placements\":[{\"row\":7,\"col\":7,\"letter\":\"$RACK_LETTER\",\"blank\":false}],
  \"p_word\":\"$RACK_LETTER\",\"p_client_score\":5}")
echo "$RES" | py 'import json,sys; d=json.load(sys.stdin); assert len(d["drawn"])==1 and d["bag_count"]==85, d' \
  || fail "bad play result: $RES"
echo "   ok: $RES"

step "4. Turn enforcement: seat 0 cannot move again"
rpc_expect_error "$TOKEN_A" submit_move "{\"p_game_id\":\"$GAME\",\"p_seat\":0,\"p_kind\":\"pass\"}" "not_your_turn"
echo "   not_your_turn ✓"

step "5. Rack enforcement: AI seat cannot play a tile it doesn't hold 8 of"
rpc_expect_error "$TOKEN_A" submit_move "{\"p_game_id\":\"$GAME\",\"p_seat\":1,\"p_kind\":\"play\",
  \"p_placements\":[{\"row\":8,\"col\":7,\"letter\":\"Q\",\"blank\":false},{\"row\":9,\"col\":7,\"letter\":\"Q\",\"blank\":false},{\"row\":10,\"col\":7,\"letter\":\"Q\",\"blank\":false}],
  \"p_word\":\"QQQ\"}" "tiles_not_in_rack"
echo "   tiles_not_in_rack ✓"

step "6. Occupied-cell enforcement"
AI_LETTER=$(rpc "$TOKEN_A" fetch_game "{\"p_game_id\":\"$GAME\"}" \
  | py 'import json,sys; d=json.load(sys.stdin); r=d["players"][1]["rack"]; print(next(l for l in r if l != "?"))')
rpc_expect_error "$TOKEN_A" submit_move "{\"p_game_id\":\"$GAME\",\"p_seat\":1,\"p_kind\":\"play\",
  \"p_placements\":[{\"row\":7,\"col\":7,\"letter\":\"$AI_LETTER\",\"blank\":false}],\"p_word\":\"X\"}" "cell_occupied"
echo "   cell_occupied ✓"

step "7. AI seat pass (client drives the AI), then swap for seat 0"
rpc "$TOKEN_A" submit_move "{\"p_game_id\":\"$GAME\",\"p_seat\":1,\"p_kind\":\"pass\"}" > /dev/null
SWAP_LETTER=$(rpc "$TOKEN_A" fetch_game "{\"p_game_id\":\"$GAME\"}" \
  | py 'import json,sys; d=json.load(sys.stdin); r=d["players"][0]["rack"]; print(r[0])')
SWAP=$(rpc "$TOKEN_A" submit_move "{\"p_game_id\":\"$GAME\",\"p_seat\":0,\"p_kind\":\"swap\",\"p_swap_letters\":[\"$SWAP_LETTER\"]}")
echo "$SWAP" | py 'import json,sys; d=json.load(sys.stdin); assert len(d["drawn"])==1 and d["bag_count"]==85, d' \
  || fail "bad swap: $SWAP"
echo "   pass + swap ✓"

step "8. fetch_game state + rack privacy shape"
rpc "$TOKEN_A" fetch_game "{\"p_game_id\":\"$GAME\"}" | py '
import json,sys
d=json.load(sys.stdin)
assert d["turn_number"]==4 and d["turn_seat"]==1, d["turn_number"]
assert d["consecutive_passes"]==0, "swap must reset passes"
assert len(d["players"][0]["rack"])==7 and len(d["players"][1]["rack"])==7
assert len(d["moves"])==3
assert "7-7" in d["board"]
assert d["players"][0]["score"]==5
print("   state ✓")' || fail "fetch_game state wrong"

step "9. finish_game records finals; lobby shows it"
rpc "$TOKEN_A" finish_game "{\"p_game_id\":\"$GAME\",\"p_end_reason\":\"six_passes\",\"p_scores\":{\"0\":42,\"1\":37},\"p_winner_seat\":0}" > /dev/null
rpc "$TOKEN_A" fetch_lobby '{}' | py '
import json,sys
d=json.load(sys.stdin)
assert len(d)==1 and d[0]["status"]=="finished" and d[0]["winner_seat"]==0
assert d[0]["players"][0]["score"]==42 and d[0]["players"][1]["score"]==37
print("   lobby ✓")' || fail "lobby wrong after finish"

step "10. import_local_game is idempotent"
IMPORT_ID=$(py 'import uuid; print(uuid.uuid4())')
R1=$(rpc "$TOKEN_A" import_local_game "{\"p\":{\"id\":\"$IMPORT_ID\",\"status\":\"active\",\"turn_seat\":0,\"turn_number\":3,\"scores\":{\"0\":12,\"1\":9},\"ai_difficulty\":\"easy\",\"board\":{\"7-7\":{\"letter\":\"A\",\"blank\":false}},\"racks\":{\"0\":[\"A\",\"B\"],\"1\":[\"C\"]},\"bag\":[\"D\",\"E\"],\"log\":[\"imported\"]}}")
R2=$(rpc "$TOKEN_A" import_local_game "{\"p\":{\"id\":\"$IMPORT_ID\",\"status\":\"active\"}}")
[ "$R1" = '"imported"' ] && [ "$R2" = '"exists"' ] || fail "import not idempotent: $R1 / $R2"
echo "   import ✓ ($R1 then $R2)"

step "11. delete_account removes user AND all their games"
# Scoped to THIS run's games — the table may legitimately hold other
# users' real games (the original whole-table-empty assertion false-failed
# the moment the database had production data in it).
rpc "$TOKEN_A" delete_account '{}' > /dev/null
for id in "$GAME" "$IMPORT_ID"; do
  LEFT=$(curl -s "$URL/rest/v1/games?id=eq.$id&select=id" \
    -H "apikey: $KEY" -H "Authorization: Bearer $KEY")
  [ "$LEFT" = "[]" ] || fail "game $id survived account deletion: $LEFT"
done
echo "   cascade ✓ (both of A's games gone)"

printf '\nALL PHASE 7 CHECKS PASSED\n'
