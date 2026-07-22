#!/bin/bash
# Verifies Phase 8 (friends, invites, human-vs-human games) with throwaway
# users. Run AFTER phase8_friends.sql. Every user this script creates is
# deleted on exit — success or failure — via the EXIT trap.
#
# Usage:  SUPABASE_SECRET_KEY=sb_secret_... ./verify_phase8.sh

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

rpc_expect_error() {
  local body
  body=$(curl -s -X POST "$URL/rest/v1/rpc/$2" \
    -H "apikey: $KEY" -H "Authorization: Bearer $1" \
    -H "Content-Type: application/json" -d "$3")
  echo "$body" | grep -q "$4" || fail "$2 should have failed with '$4', got: $body"
}

step "0. Create three throwaway users"
read -r USER_A TOKEN_A <<< "$(make_user "p8a-$TS@example.com")"; CREATED+=("$USER_A")
read -r USER_B TOKEN_B <<< "$(make_user "p8b-$TS@example.com")"; CREATED+=("$USER_B")
read -r USER_C TOKEN_C <<< "$(make_user "p8c-$TS@example.com")"; CREATED+=("$USER_C")
echo "   A=$USER_A B=$USER_B C=$USER_C"

step "1. Invite link: create, redeem, edge cases"
TOKEN=$(rpc "$TOKEN_A" create_invite '{}' | py 'import json,sys; print(json.load(sys.stdin)["token"])')
TOKEN2=$(rpc "$TOKEN_A" create_invite '{}' | py 'import json,sys; print(json.load(sys.stdin)["token"])')
[ "$TOKEN" = "$TOKEN2" ] || fail "repeated create_invite should reuse the live link"
rpc "$TOKEN_A" redeem_invite "{\"p_token\":\"$TOKEN\"}" | grep -q "own_link" || fail "own link not detected"
rpc "$TOKEN_B" redeem_invite "{\"p_token\":\"$TOKEN\"}" | grep -q '"status": *"accepted"' || fail "redeem failed"
rpc "$TOKEN_B" redeem_invite "{\"p_token\":\"$TOKEN\"}" | grep -q "already_friends" || fail "double redeem not detected"
rpc "$TOKEN_C" redeem_invite '{"p_token":"nope"}' | grep -q "invalid" || fail "bad token not rejected"
echo "   invite flow ✓ (reuse, own_link, accepted, already_friends, invalid)"

step "2. Usernames: claim, uniqueness, validation, search"
rpc "$TOKEN_A" set_username '{"p_username":"adam_test"}' | grep -q '"ok"' || fail "set_username"
rpc "$TOKEN_C" set_username '{"p_username":"adam_test"}' | grep -q '"taken"' || fail "duplicate username allowed"
rpc "$TOKEN_C" set_username '{"p_username":"Bad Name!"}' | grep -q '"invalid"' || fail "invalid username allowed"
FOUND=$(curl -sf "$URL/rest/v1/profiles?username=ilike.adam*&select=username" \
  -H "apikey: $KEY" -H "Authorization: Bearer $TOKEN_C")
echo "$FOUND" | grep -q "adam_test" || fail "username search: $FOUND"
echo "   usernames ✓"

step "3. Friend requests: send, decline, re-send, accept, mutual"
rpc "$TOKEN_C" send_friend_request "{\"p_user\":\"$USER_A\"}" | grep -q '"sent"' || fail "send"
rpc "$TOKEN_C" send_friend_request "{\"p_user\":\"$USER_A\"}" | grep -q '"already_pending"' || fail "dup send"
rpc "$TOKEN_A" list_friends '{}' | py "
import json,sys
d=json.load(sys.stdin)
states={e['user_id']:e['state'] for e in d}
assert states.get('$USER_B')=='friend' and states.get('$USER_C')=='incoming', states
print('   A sees: B friend, C incoming ✓')" || fail "A's list wrong"
rpc "$TOKEN_A" respond_friend_request "{\"p_user\":\"$USER_C\",\"p_accept\":false}" | grep -q '"declined"' || fail "decline"
rpc "$TOKEN_C" send_friend_request "{\"p_user\":\"$USER_A\"}" | grep -q '"sent"' || fail "re-send after decline"
rpc "$TOKEN_A" send_friend_request "{\"p_user\":\"$USER_C\"}" | grep -q '"accepted"' || fail "mutual request should auto-accept"
rpc "$TOKEN_A" remove_friend "{\"p_user\":\"$USER_C\"}" > /dev/null
rpc "$TOKEN_C" list_friends '{}' | py '
import json,sys; assert json.load(sys.stdin)==[], "C should have no friends left"
print("   request lifecycle ✓")' || fail "remove failed"

step "4. Challenge: A starts a human game with friend B"
rpc_expect_error "$TOKEN_A" create_game "{\"p_opponent\":\"$USER_C\"}" "not_friends"
GAME=$(rpc "$TOKEN_A" create_game "{\"p_opponent\":\"$USER_B\"}" | py '
import json,sys
d=json.load(sys.stdin)
assert len(d["my_rack"])==7 and d["ai_rack"] is None and d["bag_count"]==86, d
print(d["game_id"])') || fail "human create_game"
echo "   game=$GAME (ai_rack correctly null)"

step "5. CRITICAL privacy: human racks never cross the net"
rpc "$TOKEN_B" fetch_game "{\"p_game_id\":\"$GAME\"}" | py '
import json,sys
d=json.load(sys.stdin)
racks={p["seat"]: p.get("rack") for p in d["players"]}
assert racks[0] is None, "B can see A rack!"
assert isinstance(racks[1], list) and len(racks[1])==7, "B cannot see own rack"
print("   B: own rack visible, A rack null ✓")' || fail "rack privacy (B)"
rpc "$TOKEN_A" fetch_game "{\"p_game_id\":\"$GAME\"}" | py '
import json,sys
d=json.load(sys.stdin)
racks={p["seat"]: p.get("rack") for p in d["players"]}
assert racks[1] is None, "A can see B rack!"
assert isinstance(racks[0], list) and len(racks[0])==7
print("   A: own rack visible, B rack null ✓")' || fail "rack privacy (A)"
PRIV=$(curl -s "$URL/rest/v1/game_private?select=*" -H "apikey: $KEY" -H "Authorization: Bearer $TOKEN_B")
[ "$PRIV" = "[]" ] || echo "$PRIV" | grep -q "permission denied" || fail "game_private readable: $PRIV"
echo "   game_private locked ✓"

step "6. Human seats enforce ownership (no AI-style delegation)"
A_LETTER=$(rpc "$TOKEN_A" fetch_game "{\"p_game_id\":\"$GAME\"}" \
  | py 'import json,sys; r=json.load(sys.stdin)["players"][0]["rack"]; print(next(l for l in r if l!="?"))')
rpc_expect_error "$TOKEN_B" submit_move "{\"p_game_id\":\"$GAME\",\"p_seat\":0,\"p_kind\":\"pass\"}" "not_your_seat"
RES=$(rpc "$TOKEN_A" submit_move "{\"p_game_id\":\"$GAME\",\"p_seat\":0,\"p_kind\":\"play\",
  \"p_placements\":[{\"row\":7,\"col\":7,\"letter\":\"$A_LETTER\",\"blank\":false}],\"p_word\":\"$A_LETTER\",\"p_client_score\":4}")
echo "$RES" | py 'import json,sys; d=json.load(sys.stdin); assert len(d["drawn"])==1, d' || fail "A play: $RES"
rpc "$TOKEN_B" submit_move "{\"p_game_id\":\"$GAME\",\"p_seat\":1,\"p_kind\":\"pass\"}" > /dev/null || fail "B cannot pass own turn"
rpc "$TOKEN_B" fetch_lobby '{}' | py "
import json,sys
d=json.load(sys.stdin)
assert len(d)==1 and d[0]['game_id']=='$GAME'
names={p['seat']: p['display_name'] for p in d[0]['players']}
assert names[0] and names[1], names
print('   B lobby shows the game with both names ✓')" || fail "B lobby"

step "7. AI exception still intact: AI rack visible in AI games"
rpc "$TOKEN_A" create_game '{"p_ai_difficulty":"easy"}' | py '
import json,sys
d=json.load(sys.stdin)
assert isinstance(d["ai_rack"], list) and len(d["ai_rack"])==7
print("   AI rack returned for AI games ✓")' || fail "AI game create"

step "8. Account deletion mid-game: forfeit + anonymize, then full cleanup (phase8b)"
# A and B still have their active human game from steps 4–6.
rpc "$TOKEN_A" delete_account '{}' > /dev/null
rpc "$TOKEN_B" fetch_game "{\"p_game_id\":\"$GAME\"}" | py '
import json,sys
d=json.load(sys.stdin)
assert d, "B lost the game entirely"
assert d["status"]=="resigned" and d["winner_seat"]==1, (d["status"], d.get("winner_seat"))
seat0=[p for p in d["players"] if p["seat"]==0][0]
assert seat0["engine"]=="departed" and seat0["user_id"] is None, seat0
assert seat0.get("display_name") is None, "departed seat still shows a name"
print("   B sees: resigned, B wins by forfeit, seat 0 anonymized ✓")' \
  || fail "deletion forfeit — is phase8b_account_deletion.sql applied?"
# B deletes too: the last real human is gone, so the game itself must go.
rpc "$TOKEN_B" delete_account '{}' > /dev/null
LEFT=$(curl -s "$URL/rest/v1/games?id=eq.$GAME&select=id" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY")
[ "$LEFT" = "[]" ] || fail "game survived after last human deleted: $LEFT"
echo "   last-human deletion removes the game entirely ✓"

printf '\nALL PHASE 8 CHECKS PASSED\n'
