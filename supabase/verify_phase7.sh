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

make_user() {  # $1 = email; echoes "user_id access_token"
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

rpc() {  # $1 token, $2 fn, $3 json args; echoes body, fails on HTTP error
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
read -r USER_B TOKEN_B <<< "$(make_user "p7b-$TS@example.com")"
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
rpc "$TOKEN_A" delete_account '{}' > /dev/null
LEFT=$(curl -s "$URL/rest/v1/games?select=id" -H "apikey: $KEY" -H "Authorization: Bearer $KEY")
[ "$LEFT" = "[]" ] || fail "games survived account deletion: $LEFT"
echo "   cascade ✓"

step "12. Cleanup user B"
curl -sf -o /dev/null -X DELETE "$URL/auth/v1/admin/users/$USER_B" -H "apikey: $KEY" -H "Authorization: Bearer $KEY"
echo "   done"

printf '\nALL PHASE 7 CHECKS PASSED\n'
