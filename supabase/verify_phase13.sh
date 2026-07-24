#!/bin/bash
# Verifies Phase 13 (stats, friends-only leaderboard, head-to-head) with
# throwaway users. Run AFTER phase13b_stats_endings.sql. Users cleaned up
# on exit.
#
# The core of this script is the ENDING ZOO (step 1): one game per
# terminal path — normal play-out, six-pass tie, resignation, expiry
# forfeit, departed opponent — so stats can never again silently miss an
# ending category (the phase13 bug: only status='finished' counted).
#
# Usage:  SUPABASE_SECRET_KEY=sb_secret_... ./verify_phase13.sh

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

admin_rpc() {  # service-role RPC (cron-style jobs)
  curl -sf --retry 2 --retry-delay 1 -X POST "$URL/rest/v1/rpc/$1" \
    -H "apikey: $KEY" -H "Authorization: Bearer $KEY" \
    -H "Content-Type: application/json" -d "$2"
}

rpc_expect_error() {
  local body
  body=$(curl -s -X POST "$URL/rest/v1/rpc/$2" \
    -H "apikey: $KEY" -H "Authorization: Bearer $1" \
    -H "Content-Type: application/json" -d "$3")
  echo "$body" | grep -q "$4" || fail "$2 should have failed with '$4', got: $body"
}

friend() {  # $1 inviter token, $2 redeemer token
  local invite
  invite=$(rpc "$1" create_invite '{}' | py 'import json,sys; print(json.load(sys.stdin)["token"])')
  rpc "$2" redeem_invite "{\"p_token\":\"$invite\"}" > /dev/null
}

new_game() {  # $1 creator token, $2 opponent id; echoes game id
  rpc "$1" create_game "{\"p_opponent\":\"$2\"}" \
    | py 'import json,sys; print(json.load(sys.stdin)["game_id"])'
}

step "0. Users A, B, D (friends of A), C (stranger)"
read -r USER_A TOKEN_A <<< "$(make_user "p13a-$TS@example.com")"; CREATED+=("$USER_A")
[ -n "${USER_A:-}" ] && [ -n "${TOKEN_A:-}" ] || fail "USER_A setup incomplete"
read -r USER_B TOKEN_B <<< "$(make_user "p13b-$TS@example.com")"; CREATED+=("$USER_B")
[ -n "${USER_B:-}" ] && [ -n "${TOKEN_B:-}" ] || fail "USER_B setup incomplete"
read -r USER_C TOKEN_C <<< "$(make_user "p13c-$TS@example.com")"; CREATED+=("$USER_C")
[ -n "${USER_C:-}" ] && [ -n "${TOKEN_C:-}" ] || fail "USER_C setup incomplete"
read -r USER_D TOKEN_D <<< "$(make_user "p13d-$TS@example.com")"; CREATED+=("$USER_D")
[ -n "${USER_D:-}" ] && [ -n "${TOKEN_D:-}" ] || fail "USER_D setup incomplete"
friend "$TOKEN_A" "$TOKEN_B"
friend "$TOKEN_A" "$TOKEN_D"
echo "   A=$USER_A B=$USER_B C=$USER_C D=$USER_D"

step "1. The ending zoo: one game per terminal path"
# G1 — resignation: A plays a word (+4), B resigns → A wins ('resigned').
CREATE=$(rpc "$TOKEN_A" create_game "{\"p_opponent\":\"$USER_B\"}")
G1=$(printf '%s' "$CREATE" | py 'import json,sys; print(json.load(sys.stdin)["game_id"])')
RACK_A=$(printf '%s' "$CREATE" | py 'import json,sys; print("".join(json.load(sys.stdin)["my_rack"]))')
L1=${RACK_A:0:1}; L2=${RACK_A:1:1}
PLAY_PAYLOAD=$(python3 - "$G1" "$L1" "$L2" <<'PYEOF'
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
rpc "$TOKEN_B" resign_game "{\"p_game_id\":\"$G1\"}" > /dev/null
echo "   G1 resignation: A played $L1$L2 (+4), B resigned → A wins"

# G2 — normal play-out: finish_game 'emptied', A 30 : B 20, A wins.
G2=$(new_game "$TOKEN_A" "$USER_B")
rpc "$TOKEN_A" finish_game "{\"p_game_id\":\"$G2\",\"p_end_reason\":\"emptied\",\"p_scores\":{\"0\":30,\"1\":20},\"p_winner_seat\":0}" > /dev/null
echo "   G2 play-out: emptied, A 30-20 → A wins"

# G3 — six passes: finish_game 'six_passes', 5:5, no winner → tie.
G3=$(new_game "$TOKEN_A" "$USER_B")
rpc "$TOKEN_A" finish_game "{\"p_game_id\":\"$G3\",\"p_end_reason\":\"six_passes\",\"p_scores\":{\"0\":5,\"1\":5},\"p_winner_seat\":null}" > /dev/null
echo "   G3 six passes: 5-5, tie"

# G4 — expiry forfeit: A (creator, on turn) never plays; warned long ago;
# the job expires it and the on-turn player forfeits → A LOSES.
G4=$(new_game "$TOKEN_A" "$USER_B")
curl -sf -X PATCH "$URL/rest/v1/games?id=eq.$G4" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"expires_at":"2020-01-01T00:00:00Z","expiry_warned_at":"2020-01-01T00:00:00Z"}' > /dev/null
admin_rpc process_game_expiry '{}' > /dev/null
echo "   G4 expiry: A sat on the turn → A forfeits"

# G5 — departed opponent: game vs D, then D deletes their account →
# phase8b forfeits to the surviving human → A wins.
G5=$(new_game "$TOKEN_A" "$USER_D")
rpc "$TOKEN_D" delete_account '{}' > /dev/null
echo "   G5 departed: D deleted their account → A wins by forfeit"

# The zoo must cover all three terminal statuses — assert them outright
# so a future status change can't fake coverage.
GAMES_JSON=$(curl -s "$URL/rest/v1/games?id=in.($G1,$G2,$G3,$G4,$G5)&select=id,status,winner_seat" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY")
if ! GAMES="$GAMES_JSON" G1="$G1" G2="$G2" G3="$G3" G4="$G4" G5="$G5" python3 <<'PYEOF'
import json, os
rows = {g["id"]: g for g in json.loads(os.environ["GAMES"])}
expect = {
    os.environ["G1"]: ("resigned", 0),
    os.environ["G2"]: ("finished", 0),
    os.environ["G3"]: ("finished", None),
    os.environ["G4"]: ("expired", 1),
    os.environ["G5"]: ("resigned", 0),
}
for gid, (status, winner) in expect.items():
    g = rows.get(gid)
    assert g, ("game missing", gid)
    assert g["status"] == status, (gid, g["status"], "wanted", status)
    assert g["winner_seat"] == winner, (gid, g["winner_seat"], "wanted", winner)
print("   statuses: resigned/finished/finished/expired/resigned, winners correct ✓")
PYEOF
then fail "ending zoo statuses wrong"; fi

step "2. A's stats count every ending: 3-1-1 across five games"
if ! WORD="$L1$L2" STATS="$(rpc "$TOKEN_A" fetch_stats '{}')" python3 <<'PYEOF'
import json, os
s = json.loads(os.environ["STATS"])
# G1 win(4) + G2 win(30) + G3 tie(5) + G4 loss(0) + G5 win(0)
assert s["games"] == 5, s
assert s["wins"] == 3 and s["losses"] == 1 and s["ties"] == 1, s
assert s["best_game"] == 30, s
assert s["avg_score"] == 8, s  # round(39/5)
assert s["best_word"] and s["best_word"]["word"] == os.environ["WORD"], s["best_word"]
h = s["human"]
assert h["games"] == 5 and h["wins"] == 3 and h["losses"] == 1 and h["ties"] == 1, h
ai = s["ai"]
assert ai["games"] == 0 and ai["avg_score"] == 0, ai
assert "wins" not in ai and "losses" not in ai, \
    "practice subset must carry NO win-loss keys (13c framing)"
print("   A: 3-1-1, avg 8, best 30, best word from G1; practice empty, no W-L keys ✓")
PYEOF
then fail "A's stats miss an ending category"; fi

step "3. B's stats (read by friend A): 1-2-1"
if ! STATS="$(rpc "$TOKEN_A" fetch_stats "{\"p_user\":\"$USER_B\"}")" python3 <<'PYEOF'
import json, os
s = json.loads(os.environ["STATS"])
# G1 loss(0) + G2 loss(20) + G3 tie(5) + G4 win(0)
assert s["games"] == 4, s
assert s["wins"] == 1 and s["losses"] == 2 and s["ties"] == 1, s
assert s["avg_score"] == 6, s  # round(25/4)
print("   B (viewed by A): 1-2-1, expiry win counted ✓")
PYEOF
then fail "B's stats wrong"; fi

step "4. Head-to-head counts all four shared endings, symmetrically"
if ! H2H="$(rpc "$TOKEN_A" fetch_head_to_head "{\"p_user\":\"$USER_B\"}")" python3 <<'PYEOF'
import json, os
h = json.loads(os.environ["H2H"])
assert h["games"] == 4, h
assert h["my_wins"] == 2 and h["their_wins"] == 1 and h["ties"] == 1, h
assert h["my_avg"] == 10 and h["their_avg"] == 6, h  # round(39/4), round(25/4)
assert h["last_played"], h
print("   A vs B: 2-1-1 over four endings ✓")
PYEOF
then fail "H2H for A wrong"; fi
if ! H2H="$(rpc "$TOKEN_B" fetch_head_to_head "{\"p_user\":\"$USER_A\"}")" python3 <<'PYEOF'
import json, os
h = json.loads(os.environ["H2H"])
assert h["my_wins"] == 1 and h["their_wins"] == 2 and h["ties"] == 1, h
print("   B vs A mirrors it: 1-2-1 ✓")
PYEOF
then fail "H2H for B wrong"; fi
rpc_expect_error "$TOKEN_A" fetch_head_to_head "{\"p_user\":\"$USER_A\"}" "self"
echo "   self-H2H refused ✓"

step "5. Leaderboard: me + friends, nobody else (departed D gone)"
if ! ME="$USER_A" FRIEND="$USER_B" BOARD="$(rpc "$TOKEN_A" fetch_leaderboard '{}')" python3 <<'PYEOF'
import json, os
rows = json.loads(os.environ["BOARD"])
assert len(rows) == 2, rows
by_id = {r["user_id"]: r for r in rows}
me = by_id[os.environ["ME"]]
friend = by_id[os.environ["FRIEND"]]
assert me["me"] is True and friend["me"] is False, rows
assert me["stats"]["human"]["wins"] == 3, me["stats"]
assert friend["stats"]["human"]["wins"] == 1, friend["stats"]
print("   A's board: exactly A + B, resignation/expiry wins included ✓")
PYEOF
then fail "A leaderboard wrong"; fi
if ! ME="$USER_C" BOARD="$(rpc "$TOKEN_C" fetch_leaderboard '{}')" python3 <<'PYEOF'
import json, os
rows = json.loads(os.environ["BOARD"])
assert len(rows) == 1 and rows[0]["user_id"] == os.environ["ME"], rows
assert rows[0]["stats"]["games"] == 0, rows[0]
print("   friendless C: board of one (the empty state's data shape) ✓")
PYEOF
then fail "C leaderboard wrong"; fi

step "6. Privacy: strangers refused, same error as blocked"
rpc_expect_error "$TOKEN_C" fetch_stats "{\"p_user\":\"$USER_A\"}" "not_friends"
rpc_expect_error "$TOKEN_C" fetch_head_to_head "{\"p_user\":\"$USER_A\"}" "not_friends"
echo "   stranger C: stats and H2H both sealed ✓"

step "7. AI games land in PRACTICE (count + avg, no W-L), human record untouched"
AI=$(rpc "$TOKEN_A" create_game '{"p_ai_difficulty":"easy"}')
AI_GAME=$(printf '%s' "$AI" | py 'import json,sys; print(json.load(sys.stdin)["game_id"])')
rpc "$TOKEN_A" submit_move "{\"p_game_id\":\"$AI_GAME\",\"p_seat\":0,\"p_kind\":\"pass\"}" > /dev/null
rpc "$TOKEN_A" finish_game "{\"p_game_id\":\"$AI_GAME\",\"p_end_reason\":\"resigned\",\"p_scores\":{\"0\":12,\"1\":0},\"p_winner_seat\":1}" > /dev/null
if ! STATS="$(rpc "$TOKEN_A" fetch_stats '{}')" python3 <<'PYEOF'
import json, os
s = json.loads(os.environ["STATS"])
assert s["games"] == 6 and s["wins"] == 3 and s["losses"] == 2, s
assert s["avg_score"] == 9, s  # round(51/6)
h = s["human"]
assert h["games"] == 5 and h["losses"] == 1 and h["avg_score"] == 8, h
ai = s["ai"]
assert ai["games"] == 1 and ai["avg_score"] == 12, ai
assert "wins" not in ai, "practice must never grow a W-L"
print("   practice: 1 game avg 12, no W-L keys; human record byte-identical ✓")
PYEOF
then fail "AI-game accounting wrong"; fi

step "8. Hiding a game from the lobby does NOT hide it from stats"
rpc "$TOKEN_A" delete_game "{\"p_game_id\":\"$G1\"}" | grep -q '"hidden"' || fail "hide finished game"
if ! STATS="$(rpc "$TOKEN_A" fetch_stats '{}')" python3 <<'PYEOF'
import json, os
s = json.loads(os.environ["STATS"])
assert s["games"] == 6 and s["wins"] == 3, s
assert s["human"]["games"] == 5 and s["human"]["wins"] == 3, s["human"]
print("   hidden game still counts ✓")
PYEOF
then fail "hidden game dropped from stats"; fi

step "9. Block seals stats both ways and shrinks the leaderboard"
rpc "$TOKEN_B" block_user "{\"p_user\":\"$USER_A\"}" > /dev/null
rpc_expect_error "$TOKEN_A" fetch_stats "{\"p_user\":\"$USER_B\"}" "not_friends"
rpc_expect_error "$TOKEN_B" fetch_stats "{\"p_user\":\"$USER_A\"}" "not_friends"
rpc_expect_error "$TOKEN_A" fetch_head_to_head "{\"p_user\":\"$USER_B\"}" "not_friends"
if ! ME="$USER_A" BOARD="$(rpc "$TOKEN_A" fetch_leaderboard '{}')" python3 <<'PYEOF'
import json, os
rows = json.loads(os.environ["BOARD"])
assert len(rows) == 1 and rows[0]["user_id"] == os.environ["ME"], rows
print("   post-block: B gone from A's board, stats sealed both ways ✓")
PYEOF
then fail "post-block leaderboard wrong"; fi

step "10. Internal helpers are not callable by clients"
BODY=$(curl -s -X POST "$URL/rest/v1/rpc/stats_for" \
  -H "apikey: $KEY" -H "Authorization: Bearer $TOKEN_C" \
  -H "Content-Type: application/json" -d "{\"p_user\":\"$USER_A\"}")
echo "$BODY" | grep -qi "permission denied\|42501\|PGRST" \
  || fail "stats_for callable by clients: $BODY"
echo "   stats_for sealed (definer-internal only) ✓"

printf '\nPhase 13 verification PASSED\n'
