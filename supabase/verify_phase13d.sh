#!/bin/bash
# Verifies Phase 13d (personal profile stat aggregations) with throwaway
# users. Run AFTER pasting phase13d_profile_stats.sql. Users cleaned up
# on exit.
#
# Seeds games with KNOWN move scores and endings, then asserts every new
# stat: average word score (lifetime / this-month / monthly series),
# best word, best/average game, wins, both streaks, point-word buckets,
# bingo count + last bingo. The seed includes an AI game the caller WINS
# to prove the count rule: AI games feed skill stats but never wins or
# streaks (a wrongly-included AI win makes current_streak 2, not 1).
#
# NOT-PASTED SIGNATURE: step 1 fails fast with
#   "phase13d_profile_stats.sql NOT PASTED"
# (the RPC probe sees PGRST202 function-not-found). That exact red means
# paste the SQL, nothing else.
#
# Usage:  SUPABASE_SECRET_KEY=sb_secret_... ./verify_phase13d.sh

set -euo pipefail

URL="https://wdbouucicnxeoomazerx.supabase.co"
KEY="${SUPABASE_SECRET_KEY:?Set SUPABASE_SECRET_KEY=sb_secret_...}"
TS=$(date +%s)

step() { printf '\n== %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
py()   { python3 -c "$1"; }

# Robust teardown + loud death (see verify_phase11.sh for the history).
# HARNESS RULE: python sources are LITERALS ONLY — data crosses via
# env/argv/stdin (run check_inline_python.py after any edit).
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
    # Deletes VERIFIED by HTTP code (404 = already gone). A silently
    # failed delete once stranded a profile that polluted a later run —
    # never claim success without checking.
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

friend() {  # $1 inviter token, $2 redeemer token
  local invite
  invite=$(rpc "$1" create_invite '{}' | py 'import json,sys; print(json.load(sys.stdin)["token"])')
  rpc "$2" redeem_invite "{\"p_token\":\"$invite\"}" > /dev/null
}

# Caller's current rack in a game, as one string ("?" = blank).
my_rack() {  # $1 token, $2 game id
  rpc "$1" fetch_game "{\"p_game_id\":\"$2\"}" | python3 -c '
import json, sys
game = json.load(sys.stdin)
for p in game.get("players", []):
    rack = p.get("rack")
    if rack:
        print("".join(rack))
        break
'
}

# Build a submit_move payload placing the given rack letters left-to-right
# on one row. Blanks ("?") become an assigned E with blank=true — exactly
# what leaves the rack server-side. Prints the JSON payload; the played
# word text is payload["p_word"].
play_payload() {  # $1 game, $2 seat, $3 row, $4 letters, $5 score
  python3 - "$1" "$2" "$3" "$4" "$5" <<'PYEOF'
import json, sys
game, seat, row, letters, score = sys.argv[1:6]
placements, word = [], ""
for i, ch in enumerate(letters):
    blank = ch == "?"
    letter = "E" if blank else ch
    placements.append({"row": int(row), "col": i, "letter": letter, "blank": blank})
    word += letter
print(json.dumps({
    "p_game_id": game, "p_seat": int(seat), "p_kind": "play",
    "p_placements": placements, "p_word": word,
    "p_client_score": int(score),
}))
PYEOF
}

play() {  # $1 token, $2 game, $3 seat, $4 row, $5 letters, $6 score; echoes word
  local payload word
  payload=$(play_payload "$2" "$3" "$4" "$5" "$6")
  word=$(printf '%s' "$payload" | py 'import json,sys; print(json.load(sys.stdin)["p_word"])')
  rpc "$1" submit_move "$payload" > /dev/null
  echo "$word"
}

pass_turn() {  # $1 token, $2 game, $3 seat
  rpc "$1" submit_move "{\"p_game_id\":\"$2\",\"p_seat\":$3,\"p_kind\":\"pass\"}" > /dev/null
}

finish() {  # $1 token, $2 game, $3 reason, $4 scores json, $5 winner (or null)
  rpc "$1" finish_game "{\"p_game_id\":\"$2\",\"p_end_reason\":\"$3\",\"p_scores\":$4,\"p_winner_seat\":$5}" > /dev/null
}

step "0. Users A, B (friends), C (fresh — the zero-shape probe)"
read -r USER_A TOKEN_A <<< "$(make_user "p13d-a-$TS@example.com")"; CREATED+=("$USER_A")
[ -n "${USER_A:-}" ] && [ -n "${TOKEN_A:-}" ] || fail "USER_A setup incomplete"
read -r USER_B TOKEN_B <<< "$(make_user "p13d-b-$TS@example.com")"; CREATED+=("$USER_B")
[ -n "${USER_B:-}" ] && [ -n "${TOKEN_B:-}" ] || fail "USER_B setup incomplete"
read -r USER_C TOKEN_C <<< "$(make_user "p13d-c-$TS@example.com")"; CREATED+=("$USER_C")
[ -n "${USER_C:-}" ] && [ -n "${TOKEN_C:-}" ] || fail "USER_C setup incomplete"
friend "$TOKEN_A" "$TOKEN_B"
echo "   A=$USER_A B=$USER_B C=$USER_C"

step "1. Is phase13d pasted? (probe fetch_profile_stats)"
PROBE=$(curl -s -X POST "$URL/rest/v1/rpc/fetch_profile_stats" \
  -H "apikey: $KEY" -H "Authorization: Bearer $TOKEN_A" \
  -H "Content-Type: application/json" -d '{}')
if printf '%s' "$PROBE" | grep -q "PGRST202\|Could not find the function"; then
  fail "phase13d_profile_stats.sql NOT PASTED — paste it in the Supabase SQL editor (after phase13c), then rerun"
fi
echo "   fetch_profile_stats exists ✓"

step "2. Seed A's known history (moves + endings, ordered)"
# G1 (vs B): three plays — 52, 35, then a 7-tile BINGO for 78 — then a
# play-out win 165-0. Rows differ per play so cells never collide.
CREATE=$(rpc "$TOKEN_A" create_game "{\"p_opponent\":\"$USER_B\"}")
G1=$(printf '%s' "$CREATE" | py 'import json,sys; print(json.load(sys.stdin)["game_id"])')
RACK=$(printf '%s' "$CREATE" | py 'import json,sys; print("".join(json.load(sys.stdin)["my_rack"]))')
W52=$(play "$TOKEN_A" "$G1" 0 7 "${RACK:0:2}" 52)
pass_turn "$TOKEN_B" "$G1" 1
RACK=$(my_rack "$TOKEN_A" "$G1")
W35=$(play "$TOKEN_A" "$G1" 0 8 "${RACK:0:2}" 35)
pass_turn "$TOKEN_B" "$G1" 1
RACK=$(my_rack "$TOKEN_A" "$G1")
[ "${#RACK}" -eq 7 ] || fail "expected a full 7-tile rack for the bingo, got '$RACK'"
BINGO=$(play "$TOKEN_A" "$G1" 0 10 "$RACK" 78)
finish "$TOKEN_A" "$G1" emptied '{"0":165,"1":0}' 0
echo "   G1: $W52(+52), $W35(+35), BINGO $BINGO(+78) → A wins 165-0"

# G2 (vs B): one 41-point play, win 41-5.
CREATE=$(rpc "$TOKEN_A" create_game "{\"p_opponent\":\"$USER_B\"}")
G2=$(printf '%s' "$CREATE" | py 'import json,sys; print(json.load(sys.stdin)["game_id"])')
RACK=$(printf '%s' "$CREATE" | py 'import json,sys; print("".join(json.load(sys.stdin)["my_rack"]))')
W41=$(play "$TOKEN_A" "$G2" 0 7 "${RACK:0:2}" 41)
finish "$TOKEN_A" "$G2" emptied '{"0":41,"1":5}' 0
echo "   G2: $W41(+41) → A wins 41-5"

# G3 (vs B): no plays, A LOSES 0-10 — the streak breaker.
CREATE=$(rpc "$TOKEN_A" create_game "{\"p_opponent\":\"$USER_B\"}")
G3=$(printf '%s' "$CREATE" | py 'import json,sys; print(json.load(sys.stdin)["game_id"])')
finish "$TOKEN_A" "$G3" emptied '{"0":0,"1":10}' 1
echo "   G3: A loses 0-10 (breaks the streak)"

# G5 (vs AI, finished BETWEEN the loss and the next human win): a
# 60-point play and an A "win". If AI games wrongly touched win stats,
# current_streak would read 2 below instead of 1, and wins 4 not 3.
CREATE=$(rpc "$TOKEN_A" create_game '{"p_ai_difficulty":"easy"}')
G5=$(printf '%s' "$CREATE" | py 'import json,sys; print(json.load(sys.stdin)["game_id"])')
RACK=$(printf '%s' "$CREATE" | py 'import json,sys; print("".join(json.load(sys.stdin)["my_rack"]))')
W60=$(play "$TOKEN_A" "$G5" 0 7 "${RACK:0:2}" 60)
finish "$TOKEN_A" "$G5" resigned '{"0":60,"1":0}' 0
echo "   G5 (AI): $W60(+60) → A 'wins' 60-0 — skill yes, streaks no"

# G4 (vs B): no plays, A wins 20-6 — the current streak of one.
CREATE=$(rpc "$TOKEN_A" create_game "{\"p_opponent\":\"$USER_B\"}")
G4=$(printf '%s' "$CREATE" | py 'import json,sys; print(json.load(sys.stdin)["game_id"])')
finish "$TOKEN_A" "$G4" emptied '{"0":20,"1":6}' 0
echo "   G4: A wins 20-6 (human sequence W W L W)"

step "3. A's profile stats: every block computes the seeded truth"
# Plays: 52+35+78+41+60 = 266 over 5 → avg 53.2 (this month too).
# Games: 165,41,0,20,60 → best 165, avg round(286/5)=57.
# Human W W L W → wins 3, longest 2, current 1 (AI win excluded).
# Buckets: ≥50: 52,78,60 =3; ≥40: +41 =4; ≥30: +35 =5. Bingos: 1.
if ! STATS="$(rpc "$TOKEN_A" fetch_profile_stats '{}')" BINGO="$BINGO" python3 <<'PYEOF'
import datetime, json, os
s = json.loads(os.environ["STATS"])
aw = s["avg_word"]
assert aw["lifetime"] == 53.2, aw
assert aw["this_month"] == 53.2, aw
this_month = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m")
assert len(aw["monthly"]) == 1, aw["monthly"]
assert aw["monthly"][0]["month"] == this_month, (aw["monthly"], this_month)
assert aw["monthly"][0]["avg"] == 53.2, aw["monthly"]
assert s["best_word"]["word"] == os.environ["BINGO"], s["best_word"]
assert s["best_word"]["score"] == 78, s["best_word"]
assert s["best_game"] == 165, s
assert s["avg_game"] == 57, s
assert s["wins"] == 3, s  # 4 would mean the AI win leaked in
st = s["streaks"]
assert st["longest"] == 2 and st["current"] == 1, \
    (st, "current=2 means the AI game touched the streak")
pw = s["point_words"]
assert pw["w50"] == 3 and pw["w40"] == 4 and pw["w30"] == 5, pw
b = s["bingos"]
assert b["count"] == 1 and b["last_word"] == os.environ["BINGO"], b
print("   avg 53.2 (1-month series), best %s+78, game 165/57, W3 streaks 2/1, buckets 3/4/5, bingo 1 ✓" % os.environ["BINGO"])
PYEOF
then fail "A's profile stats wrong"; fi

step "4. Fresh user C: the zero shape (no games, no crash food)"
if ! STATS="$(rpc "$TOKEN_C" fetch_profile_stats '{}')" python3 <<'PYEOF'
import json, os
s = json.loads(os.environ["STATS"])
aw = s["avg_word"]
assert aw["lifetime"] is None and aw["this_month"] is None, aw
assert aw["monthly"] == [], aw
assert s["best_word"] is None, s
assert s["best_game"] == 0 and s["avg_game"] == 0, s
assert s["wins"] == 0, s
assert s["streaks"] == {"longest": 0, "current": 0}, s["streaks"]
assert s["point_words"] == {"w50": 0, "w40": 0, "w30": 0}, s["point_words"]
assert s["bingos"]["count"] == 0 and s["bingos"]["last_word"] is None, s["bingos"]
print("   nulls/zeros/empty series — nothing for a client to crash on ✓")
PYEOF
then fail "C's zero shape wrong"; fi

step "5. Internal helper sealed from clients"
BODY=$(curl -s -X POST "$URL/rest/v1/rpc/profile_stats_for" \
  -H "apikey: $KEY" -H "Authorization: Bearer $TOKEN_C" \
  -H "Content-Type: application/json" -d "{\"p_user\":\"$USER_A\"}")
printf '%s' "$BODY" | grep -qi "permission denied\|42501\|PGRST" \
  || fail "profile_stats_for callable by clients: $BODY"
echo "   profile_stats_for sealed (definer-internal only) ✓"

printf '\nPhase 13d verification PASSED\n'
