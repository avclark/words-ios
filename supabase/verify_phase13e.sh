#!/bin/bash
# Verifies Phase 13e (friends-percentile badges) with throwaway users.
# Run AFTER pasting phase13e_stat_percentiles.sql (which builds on 13d).
# Users cleaned up on exit.
#
# Seeds A + four friends with KNOWN stat values and asserts every ranked
# percentile, the tie rule (ties share the better rank), the count rule
# (an AI-heavy friend's AI game lifts their skill ranking but never the
# wins ranking), the no-data edge (a gameless friend is excluded from
# average/maximum rankings but included in count rankings), suppression
# below the floor (a 2-person population returns NO percentiles), and
# block exclusion (blocking removes someone from the population both
# ways).
#
# NOT-PASTED SIGNATURE: step 1 fails fast with
#   "phase13e_stat_percentiles.sql NOT PASTED"
# (fetch_profile_stats exists from 13d but has no 'percentiles' key).
# If 13d itself is missing it says so instead (PGRST202 probe).
#
# Usage:  SUPABASE_SECRET_KEY=sb_secret_... ./verify_phase13e.sh

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
# on one row. Blanks ("?") become an assigned E with blank=true.
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

play() {  # $1 token, $2 game, $3 seat, $4 row, $5 letters, $6 score
  local payload
  payload=$(play_payload "$2" "$3" "$4" "$5" "$6")
  rpc "$1" submit_move "$payload" > /dev/null
}

pass_turn() {  # $1 token, $2 game, $3 seat
  rpc "$1" submit_move "{\"p_game_id\":\"$2\",\"p_seat\":$3,\"p_kind\":\"pass\"}" > /dev/null
}

finish() {  # $1 token, $2 game, $3 reason, $4 scores json, $5 winner (or null)
  rpc "$1" finish_game "{\"p_game_id\":\"$2\",\"p_end_reason\":\"$3\",\"p_scores\":$4,\"p_winner_seat\":$5}" > /dev/null
}

new_game() {  # $1 creator token, $2 opponent id; echoes "game_id rack"
  rpc "$1" create_game "{\"p_opponent\":\"$2\"}" | python3 -c '
import json, sys
game = json.load(sys.stdin)
print(game["game_id"], "".join(game.get("my_rack") or []))
'
}

step "0. Users: A + friends B,C,D,E (floor population of 5), F (later)"
read -r USER_A TOKEN_A <<< "$(make_user "p13e-a-$TS@example.com")"; CREATED+=("$USER_A")
[ -n "${USER_A:-}" ] && [ -n "${TOKEN_A:-}" ] || fail "USER_A setup incomplete"
read -r USER_B TOKEN_B <<< "$(make_user "p13e-b-$TS@example.com")"; CREATED+=("$USER_B")
[ -n "${USER_B:-}" ] && [ -n "${TOKEN_B:-}" ] || fail "USER_B setup incomplete"
read -r USER_C TOKEN_C <<< "$(make_user "p13e-c-$TS@example.com")"; CREATED+=("$USER_C")
[ -n "${USER_C:-}" ] && [ -n "${TOKEN_C:-}" ] || fail "USER_C setup incomplete"
read -r USER_D TOKEN_D <<< "$(make_user "p13e-d-$TS@example.com")"; CREATED+=("$USER_D")
[ -n "${USER_D:-}" ] && [ -n "${TOKEN_D:-}" ] || fail "USER_D setup incomplete"
read -r USER_E TOKEN_E <<< "$(make_user "p13e-e-$TS@example.com")"; CREATED+=("$USER_E")
[ -n "${USER_E:-}" ] && [ -n "${TOKEN_E:-}" ] || fail "USER_E setup incomplete"
read -r USER_F TOKEN_F <<< "$(make_user "p13e-f-$TS@example.com")"; CREATED+=("$USER_F")
[ -n "${USER_F:-}" ] && [ -n "${TOKEN_F:-}" ] || fail "USER_F setup incomplete"
friend "$TOKEN_A" "$TOKEN_B"
friend "$TOKEN_A" "$TOKEN_C"
friend "$TOKEN_A" "$TOKEN_D"
friend "$TOKEN_A" "$TOKEN_E"
echo "   A=$USER_A + friends B,C,D,E; F waits"

step "1. Is phase13e pasted? (probe for the 'percentiles' key)"
PROBE=$(curl -s -X POST "$URL/rest/v1/rpc/fetch_profile_stats" \
  -H "apikey: $KEY" -H "Authorization: Bearer $TOKEN_A" \
  -H "Content-Type: application/json" -d '{}')
if printf '%s' "$PROBE" | grep -q "PGRST202\|Could not find the function"; then
  fail "fetch_profile_stats missing entirely — paste phase13d_profile_stats.sql FIRST, then phase13e"
fi
if ! printf '%s' "$PROBE" | grep -q '"percentiles"'; then
  fail "phase13e_stat_percentiles.sql NOT PASTED — paste it in the Supabase SQL editor (after phase13d), then rerun"
fi
echo "   percentiles key present ✓"

step "2. Seed known values: A vs each friend, plus B's AI game"
# Per-member targets (skill = all games, wins = human only):
#   avg_word:  A 40 | B 77.5 (60 human + 95 AI) | C 20 | D 25 | E 45
#   best_word: A 40 | B 95 | C 20 | D 25 | E 45
#   best_game: A 50 | B 95 | C 20 | D 25 | E 45
#   wins:      A 1  | B 1 (AI win EXCLUDED) | C 1 | D 1 | E 0
#   bingos:    A 1 (the 7-tile play) | others 0
read -r G1 RACK <<< "$(new_game "$TOKEN_A" "$USER_B")"
[ "${#RACK}" -eq 7 ] || fail "expected a 7-tile rack for A's bingo, got '$RACK'"
play "$TOKEN_A" "$G1" 0 7 "$RACK" 40            # A: 7-tile BINGO, 40
BRACK=$(my_rack "$TOKEN_B" "$G1")
play "$TOKEN_B" "$G1" 1 8 "${BRACK:0:2}" 60     # B: 60
finish "$TOKEN_A" "$G1" emptied '{"0":40,"1":60}' 1
echo "   G1: A bingo(+40), B(+60) → B wins 60-40"

read -r G2 RACK <<< "$(new_game "$TOKEN_A" "$USER_C")"
pass_turn "$TOKEN_A" "$G2" 0
CRACK=$(my_rack "$TOKEN_C" "$G2")
play "$TOKEN_C" "$G2" 1 7 "${CRACK:0:2}" 20     # C: 20
finish "$TOKEN_A" "$G2" emptied '{"0":10,"1":20}' 1
echo "   G2: C(+20) → C wins 20-10"

read -r G3 RACK <<< "$(new_game "$TOKEN_A" "$USER_D")"
pass_turn "$TOKEN_A" "$G3" 0
DRACK=$(my_rack "$TOKEN_D" "$G3")
play "$TOKEN_D" "$G3" 1 7 "${DRACK:0:2}" 25     # D: 25
finish "$TOKEN_A" "$G3" emptied '{"0":5,"1":25}' 1
echo "   G3: D(+25) → D wins 25-5"

read -r G4 RACK <<< "$(new_game "$TOKEN_A" "$USER_E")"
pass_turn "$TOKEN_A" "$G4" 0
ERACK=$(my_rack "$TOKEN_E" "$G4")
play "$TOKEN_E" "$G4" 1 7 "${ERACK:0:2}" 45     # E: 45
finish "$TOKEN_A" "$G4" emptied '{"0":50,"1":45}' 0
echo "   G4: E(+45) → A wins 50-45 (A's only human win)"

AI=$(rpc "$TOKEN_B" create_game '{"p_ai_difficulty":"easy"}')
G5=$(printf '%s' "$AI" | py 'import json,sys; print(json.load(sys.stdin)["game_id"])')
BRACK=$(printf '%s' "$AI" | py 'import json,sys; print("".join(json.load(sys.stdin)["my_rack"]))')
play "$TOKEN_B" "$G5" 0 7 "${BRACK:0:2}" 95     # B (AI game): 95
finish "$TOKEN_B" "$G5" resigned '{"0":95,"1":0}' 0
echo "   G5 (B vs AI): B(+95), B 'wins' — lifts B's skill ranks, never wins"

step "3. A's percentiles: exact ranks over the 5-person population"
# avg_word:  desc B,E,A,D,C → A rank 3/5 → Top 60%
# best_word: desc B,E,A,D,C → A rank 3/5 → Top 60%
#   (B tops both ONLY because the AI 95 counts for skill.)
# best_game: desc B95,A50,E45,D25,C20 → A rank 2/5 → Top 40%
# wins:      A,B,C,D tied at 1 (rank 1 shared — the tie rule), E 0
#            → A Top 20%. If B's AI win leaked in, A would be Top 40%.
# bingos:    A 1, rest 0 → A rank 1/5 → Top 20%.
if ! STATS="$(rpc "$TOKEN_A" fetch_profile_stats '{}')" python3 <<'PYEOF'
import json, os
s = json.loads(os.environ["STATS"])
# Pass A untouched underneath:
assert s["wins"] == 1 and s["bingos"]["count"] == 1, s
assert s["best_word"]["score"] == 40, s["best_word"]
p = s["percentiles"]
assert p["population"] == 5, p
assert p["avg_word"] == 60, (p, "avg_word: expected rank 3/5")
assert p["best_word"] == 60, (p, "best_word: expected rank 3/5")
assert p["best_game"] == 40, (p, "best_game: expected rank 2/5")
assert p["wins"] == 20, (p, "40 here means B's AI win leaked into wins")
assert p["bingos"] == 20, (p, "bingos: expected rank 1/5")
print("   population 5; avg 60, best word 60, best game 40, wins 20 (tie shared, AI excluded), bingos 20 ✓")
PYEOF
then fail "A's percentiles wrong"; fi

step "4. Gameless friend F joins: excluded from averages, counted at 0 in counts"
friend "$TOKEN_A" "$TOKEN_F"
if ! STATS="$(rpc "$TOKEN_A" fetch_profile_stats '{}')" python3 <<'PYEOF'
import json, os
s = json.loads(os.environ["STATS"])
p = s["percentiles"]
assert p["population"] == 6, p
# F has no plays/games: averages & maxima still rank 5 people →
# unchanged; counts now rank 6 with F at 0 → ceil(100*1/6) = 17.
assert p["avg_word"] == 60 and p["best_word"] == 60 and p["best_game"] == 40, \
    (p, "a gameless member must not enter average/maximum rankings")
assert p["wins"] == 17 and p["bingos"] == 17, \
    (p, "a gameless member MUST enter count rankings at 0")
print("   population 6; averages unchanged, counts now Top 17% ✓")
PYEOF
then fail "no-data edge wrong"; fi

step "5. F below the floor: population 2 → NO percentiles at all"
if ! STATS="$(rpc "$TOKEN_F" fetch_profile_stats '{}')" python3 <<'PYEOF'
import json, os
s = json.loads(os.environ["STATS"])
p = s["percentiles"]
assert p["population"] == 2, p
for key in ("avg_word", "best_word", "best_game", "wins", "bingos"):
    assert p[key] is None, (key, p, "suppression below the floor failed")
print("   F (2-person population): every percentile null — no badges ✓")
PYEOF
then fail "suppression below floor wrong"; fi

step "6. Block exclusion: F blocks A → out of each other's population"
rpc "$TOKEN_F" block_user "{\"p_user\":\"$USER_A\"}" > /dev/null
if ! STATS="$(rpc "$TOKEN_A" fetch_profile_stats '{}')" python3 <<'PYEOF'
import json, os
s = json.loads(os.environ["STATS"])
p = s["percentiles"]
assert p["population"] == 5, (p, "blocked F still in A's population")
assert p["wins"] == 20 and p["bingos"] == 20, p
print("   A back to population 5, counts back to Top 20% ✓")
PYEOF
then fail "block exclusion (A side) wrong"; fi
if ! STATS="$(rpc "$TOKEN_F" fetch_profile_stats '{}')" python3 <<'PYEOF'
import json, os
s = json.loads(os.environ["STATS"])
p = s["percentiles"]
assert p["population"] == 1, (p, "blocked A still in F's population")
assert p["wins"] is None, p
print("   F alone (population 1), still no badges ✓")
PYEOF
then fail "block exclusion (F side) wrong"; fi

step "7. Internal helper sealed from clients"
BODY=$(curl -s -X POST "$URL/rest/v1/rpc/profile_percentiles_for" \
  -H "apikey: $KEY" -H "Authorization: Bearer $TOKEN_C" \
  -H "Content-Type: application/json" -d "{\"p_user\":\"$USER_A\"}")
printf '%s' "$BODY" | grep -qi "permission denied\|42501\|PGRST" \
  || fail "profile_percentiles_for callable by clients: $BODY"
echo "   profile_percentiles_for sealed (definer-internal only) ✓"

printf '\nPhase 13e verification PASSED\n'
