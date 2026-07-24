#!/bin/bash
# Verifies Phase 12 (result acknowledgment, rack history, fetch_review)
# with throwaway users. Run AFTER phase12_review.sql. Users cleaned up on
# exit.
#
# Usage:  SUPABASE_SECRET_KEY=sb_secret_... ./verify_phase12.sh

set -euo pipefail

URL="https://wdbouucicnxeoomazerx.supabase.co"
KEY="${SUPABASE_SECRET_KEY:?Set SUPABASE_SECRET_KEY=sb_secret_...}"
TS=$(date +%s)

step() { printf '\n== %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
py()   { python3 -c "$1"; }

# Robust teardown + loud death (see verify_phase11.sh for the history:
# SIGPIPE skips the EXIT trap, silent aborts strand users).
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
  local failed=0
  for id in "${CREATED[@]:-}"; do
    [ -n "$id" ] || continue
    # Deletes VERIFIED by HTTP code (404 = already gone, e.g. via
    # delete_account). A silently failed delete once stranded a profile
    # that polluted a later run's search assertions — never claim
    # success without checking.
    local code="" attempt
    for attempt in 1 2 3; do
      code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$URL/auth/v1/admin/users/$id" \
        -H "apikey: $KEY" -H "Authorization: Bearer $KEY") || code="000"
      case "$code" in 200|204|404) break ;; esac
      sleep "$attempt"
    done
    case "$code" in
      200|204|404) ;;
      *) failed=$((failed+1))
         diag "cleanup: FAILED to delete $id (HTTP $code) — STRANDED, purge manually" ;;
    esac
  done
  diag "cleanup: removed $(( ${#CREATED[@]} - failed )) of ${#CREATED[@]} test user(s)$([ "$failed" -gt 0 ] && echo " — $failed STRANDED")$([ $status -ne 0 ] && echo ' (after abnormal exit)')"
}
trap 'diag "ERR at line $LINENO: [$BASH_COMMAND] exited $? (fatal unless a retry recovers — real aborts end with a FAIL/abort line)"' ERR
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

rpc_expect_error() {
  local body
  body=$(curl -s -X POST "$URL/rest/v1/rpc/$2" \
    -H "apikey: $KEY" -H "Authorization: Bearer $1" \
    -H "Content-Type: application/json" -d "$3")
  echo "$body" | grep -q "$4" || fail "$2 should have failed with '$4', got: $body"
}

step "0. Users A, B (friends), C (stranger); human game A vs B"
read -r USER_A TOKEN_A <<< "$(make_user "p12a-$TS@example.com")"; CREATED+=("$USER_A")
[ -n "${USER_A:-}" ] && [ -n "${TOKEN_A:-}" ] || fail "USER_A setup incomplete"
read -r USER_B TOKEN_B <<< "$(make_user "p12b-$TS@example.com")"; CREATED+=("$USER_B")
[ -n "${USER_B:-}" ] && [ -n "${TOKEN_B:-}" ] || fail "USER_B setup incomplete"
read -r USER_C TOKEN_C <<< "$(make_user "p12c-$TS@example.com")"; CREATED+=("$USER_C")
[ -n "${USER_C:-}" ] && [ -n "${TOKEN_C:-}" ] || fail "USER_C setup incomplete"
INVITE=$(rpc "$TOKEN_A" create_invite '{}' | py 'import json,sys; print(json.load(sys.stdin)["token"])')
rpc "$TOKEN_B" redeem_invite "{\"p_token\":\"$INVITE\"}" > /dev/null
CREATE=$(rpc "$TOKEN_A" create_game "{\"p_opponent\":\"$USER_B\"}")
GAME=$(printf '%s' "$CREATE" | py 'import json,sys; print(json.load(sys.stdin)["game_id"])')
RACK_A=$(printf '%s' "$CREATE" | py 'import json,sys; print("".join(json.load(sys.stdin)["my_rack"]))')
echo "   game=$GAME rack_A=$RACK_A"

step "1. mark_result_seen is a no-op on ACTIVE games"
rpc "$TOKEN_A" mark_result_seen "{\"p_game_id\":\"$GAME\"}" > /dev/null
SEEN=$(curl -s "$URL/rest/v1/game_players?game_id=eq.$GAME&user_id=eq.$USER_A&select=result_seen_at" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY")
printf '%s' "$SEEN" | py '
import json,sys
rows=json.load(sys.stdin)
assert rows and rows[0]["result_seen_at"] is None, rows
print("   active game not acknowledgeable ✓")' || fail "ack on active game took effect"

step "2. fetch_review refuses while the game is active"
rpc_expect_error "$TOKEN_A" fetch_review "{\"p_game_id\":\"$GAME\"}" "game_still_active"
echo "   mid-game rack history sealed ✓"

step "3. Moves record rack_before in move_private"
# Payload built by a FIXED python program; values cross only via argv.
# (The old inline-interpolation version died on bash 3.2's nested-quote
# parsing — shell variables never appear inside python source now.)
L1=${RACK_A:0:1}; L2=${RACK_A:1:1}
PLAY_PAYLOAD=$(python3 - "$GAME" "$L1" "$L2" <<'PYEOF'
import json, sys
game, l1, l2 = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({
    "p_game_id": game, "p_seat": 0, "p_kind": "play",
    "p_placements": [
        {"row": 7, "col": 7, "letter": l1, "blank": False},
        {"row": 7, "col": 8, "letter": l2, "blank": False},
    ],
    "p_word": l1 + l2, "p_client_score": 4,
}))
PYEOF
)
rpc "$TOKEN_A" submit_move "$PLAY_PAYLOAD" > /dev/null
rpc "$TOKEN_B" submit_move "{\"p_game_id\":\"$GAME\",\"p_seat\":1,\"p_kind\":\"pass\"}" > /dev/null
PRIV=$(curl -s "$URL/rest/v1/move_private?select=move_id,rack_before&order=move_id" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY")
MOVES=$(curl -s "$URL/rest/v1/moves?game_id=eq.$GAME&select=id,seat,kind&order=move_number" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY")
if ! MOVES="$MOVES" PRIV="$PRIV" RACK_A="$RACK_A" python3 <<'PYEOF'
import json, os
moves = json.loads(os.environ["MOVES"])
priv = {p["move_id"]: p["rack_before"] for p in json.loads(os.environ["PRIV"])}
assert len(moves) == 2, moves
for m in moves:
    assert m["id"] in priv, ("missing rack snapshot for move", m)
first = priv[moves[0]["id"]]
assert len(first) == 7, first
assert "".join(first) == os.environ["RACK_A"], (first, os.environ["RACK_A"])
print("   both moves snapshotted; play rack matches dealt rack ✓")
PYEOF
then fail "move_private rows wrong"; fi

step "4. move_private is unreadable by participants directly (RLS, zero policies)"
DIRECT=$(curl -s "$URL/rest/v1/move_private?select=rack_before" \
  -H "apikey: $KEY" -H "Authorization: Bearer $TOKEN_A")
[ "$DIRECT" = "[]" ] || fail "participant reads move_private directly: $DIRECT"
echo "   direct reads sealed ✓"

step "5. Finish the game (B resigns) → fetch_review opens up"
rpc "$TOKEN_B" resign_game "{\"p_game_id\":\"$GAME\"}" > /dev/null
REVIEW_A=$(rpc "$TOKEN_A" fetch_review "{\"p_game_id\":\"$GAME\"}")
if ! REVIEW="$REVIEW_A" python3 <<'PYEOF'
import json, os
d = json.loads(os.environ["REVIEW"])
assert d["my_seat"] == 0, d["my_seat"]
moves = d["moves"]
assert len(moves) >= 2, moves
play = [m for m in moves if m["kind"] == "play"][0]
assert play["seat"] == 0 and len(play["rack_before"] or []) == 7, play
assert play["placements"] and len(play["placements"]) == 2, play
others = [m for m in moves if m["seat"] == 1]
assert others and all(m["rack_before"] is None for m in others), others
print("   A: own rack history present, opponent racks null ✓")
PYEOF
then fail "fetch_review for A wrong"; fi
REVIEW_B=$(rpc "$TOKEN_B" fetch_review "{\"p_game_id\":\"$GAME\"}")
if ! REVIEW="$REVIEW_B" python3 <<'PYEOF'
import json, os
d = json.loads(os.environ["REVIEW"])
assert d["my_seat"] == 1, d
mine = [m for m in d["moves"] if m["seat"] == 1]
theirs = [m for m in d["moves"] if m["seat"] == 0]
assert all(m["rack_before"] is not None for m in mine
           if m["kind"] in ("play", "pass", "swap")), mine
assert all(m["rack_before"] is None for m in theirs), theirs
print("   B: mirror-image privacy holds ✓")
PYEOF
then fail "fetch_review for B wrong"; fi

step "6. Stranger C gets nothing from fetch_review"
rpc_expect_error "$TOKEN_C" fetch_review "{\"p_game_id\":\"$GAME\"}" "not_participant"
echo "   stranger refused ✓"

step "7. Acknowledgment flow: unseen → seen, idempotent, per-seat"
rpc "$TOKEN_A" fetch_lobby '{}' | GAME="$GAME" python3 -c '
import json, sys, os
rows = json.load(sys.stdin)
g = [r for r in rows if r["game_id"] == os.environ["GAME"]][0]
assert g["status"] != "active", g["status"]
assert g["result_seen"] is False, g["result_seen"]
print("   finished + unseen -> still in the lobby ✓")' || fail "lobby result_seen pre-ack"
rpc "$TOKEN_A" mark_result_seen "{\"p_game_id\":\"$GAME\"}" > /dev/null
rpc "$TOKEN_A" mark_result_seen "{\"p_game_id\":\"$GAME\"}" > /dev/null
rpc "$TOKEN_A" fetch_lobby '{}' | GAME="$GAME" python3 -c '
import json, sys, os
g = [r for r in json.load(sys.stdin) if r["game_id"] == os.environ["GAME"]][0]
assert g["result_seen"] is True, g
print("   acknowledged (idempotent) ✓")' || fail "lobby result_seen post-ack"
rpc "$TOKEN_B" fetch_lobby '{}' | GAME="$GAME" python3 -c '
import json, sys, os
g = [r for r in json.load(sys.stdin) if r["game_id"] == os.environ["GAME"]][0]
assert g["result_seen"] is False, g
print("   B unaffected — acknowledgment is per-seat ✓")' || fail "B result_seen leaked"

step "8. fetch_game carries result_seen too"
rpc "$TOKEN_A" fetch_game "{\"p_game_id\":\"$GAME\"}" | py '
import json,sys
d=json.load(sys.stdin)
assert d["result_seen"] is True, d.get("result_seen")
print("   fetch_game result_seen ✓")' || fail "fetch_game result_seen"
rpc "$TOKEN_B" fetch_game "{\"p_game_id\":\"$GAME\"}" | py '
import json,sys
assert json.load(sys.stdin)["result_seen"] is False
print("   per-seat in fetch_game too ✓")' || fail "fetch_game result_seen for B"

step "9. AI games work the same (submit → snapshot; review after finish)"
AI=$(rpc "$TOKEN_C" create_game '{"p_ai_difficulty":"easy"}')
AI_GAME=$(printf '%s' "$AI" | py 'import json,sys; print(json.load(sys.stdin)["game_id"])')
rpc "$TOKEN_C" submit_move "{\"p_game_id\":\"$AI_GAME\",\"p_seat\":0,\"p_kind\":\"pass\"}" > /dev/null
rpc "$TOKEN_C" finish_game "{\"p_game_id\":\"$AI_GAME\",\"p_end_reason\":\"resigned\",\"p_scores\":{\"0\":0,\"1\":0},\"p_winner_seat\":1}" > /dev/null
rpc "$TOKEN_C" fetch_review "{\"p_game_id\":\"$AI_GAME\"}" | py '
import json,sys
d=json.load(sys.stdin)
mine=[m for m in d["moves"] if m["seat"]==0]
assert mine and mine[0]["rack_before"] is not None, mine
print("   AI-game review has rack history ✓")' || fail "AI game review"

printf '\nPhase 12 verification PASSED\n'
