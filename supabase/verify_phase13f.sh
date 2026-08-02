#!/bin/bash
# Verifies Phase 13f (avatar profile columns + storage policies) with
# throwaway users. Run AFTER pasting phase13f_avatars.sql. Users (and
# any uploaded test objects) cleaned up on exit.
#
# Asserts: the profile columns exist with correct defaults; a user can
# write/overwrite/delete THEIR OWN avatar slot ({uid}.jpg); a user
# CANNOT write anyone else's slot (or an arbitrary path); anyone —
# including anonymous — can read an uploaded avatar via the public URL.
#
# NOT-PASTED SIGNATURE: step 1 fails fast with
#   "phase13f_avatars.sql NOT PASTED"
# (the profiles.avatar_palette column probe comes back with a
# column-does-not-exist error). That exact red means paste the SQL.
#
# Usage:  SUPABASE_SECRET_KEY=sb_secret_... ./verify_phase13f.sh

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
UPLOADED=()
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
  # Test avatar objects first (service role bypasses RLS), then users.
  for obj in "${UPLOADED[@]:-}"; do
    [ -n "$obj" ] || continue
    local code=""
    code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
      "$URL/storage/v1/object/avatars/$obj" \
      -H "apikey: $KEY" -H "Authorization: Bearer $KEY") || code="000"
    case "$code" in
      200|204|404) ;;
      *) diag "cleanup: avatar object $obj not deleted (HTTP $code) — STRANDED, purge manually" ;;
    esac
  done
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

# Upload bytes to a storage path with a user token; echoes the HTTP code.
put_avatar() {  # $1 token, $2 object name, $3 body text
  [ -n "$1" ] || { diag "put_avatar called with EMPTY token — refusing"; exit 1; }
  curl -s -o /dev/null -w '%{http_code}' -X POST \
    "$URL/storage/v1/object/avatars/$2" \
    -H "apikey: $KEY" -H "Authorization: Bearer $1" \
    -H "Content-Type: image/jpeg" -H "x-upsert: true" \
    --data-binary "$3"
}

step "0. Users A and B"
read -r USER_A TOKEN_A <<< "$(make_user "p13f-a-$TS@example.com")"; CREATED+=("$USER_A")
[ -n "${USER_A:-}" ] && [ -n "${TOKEN_A:-}" ] || fail "USER_A setup incomplete"
read -r USER_B TOKEN_B <<< "$(make_user "p13f-b-$TS@example.com")"; CREATED+=("$USER_B")
[ -n "${USER_B:-}" ] && [ -n "${TOKEN_B:-}" ] || fail "USER_B setup incomplete"
echo "   A=$USER_A B=$USER_B"

step "1. Is phase13f pasted? (probe profiles.avatar_palette)"
PROBE=$(curl -s "$URL/rest/v1/profiles?id=eq.$USER_A&select=avatar_palette,avatar_url" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY")
if printf '%s' "$PROBE" | grep -qi "does not exist\|42703"; then
  fail "phase13f_avatars.sql NOT PASTED — paste it in the Supabase SQL editor (after phase13e), then rerun"
fi
echo "   avatar columns exist ✓"

step "2. Column defaults: palette 'auto', url null"
if ! ROW="$PROBE" python3 <<'PYEOF'
import json, os
rows = json.loads(os.environ["ROW"])
assert len(rows) == 1, rows
row = rows[0]
assert row["avatar_palette"] == "auto", row
assert row["avatar_url"] is None, row
print("   fresh profile: avatar_palette='auto', avatar_url=null ✓")
PYEOF
then fail "profile column defaults wrong"; fi

step "3. A writes A's own slot; overwrite also works"
CODE=$(put_avatar "$TOKEN_A" "$USER_A.jpg" "fake-jpeg-bytes-$TS")
UPLOADED+=("$USER_A.jpg")
[ "$CODE" = 200 ] || fail "A could not upload own avatar (HTTP $CODE)"
CODE=$(put_avatar "$TOKEN_A" "$USER_A.jpg" "fake-jpeg-bytes-v2-$TS")
[ "$CODE" = 200 ] || fail "A could not OVERWRITE own avatar (HTTP $CODE)"
echo "   own-slot insert + upsert overwrite ✓"

step "4. A cannot write B's slot (or an arbitrary path)"
CODE=$(put_avatar "$TOKEN_A" "$USER_B.jpg" "impostor-bytes-$TS")
case "$CODE" in
  200) UPLOADED+=("$USER_B.jpg"); fail "A wrote B's avatar slot — policy hole" ;;
  400|403) ;;
  *) fail "unexpected HTTP $CODE writing B's slot as A" ;;
esac
CODE=$(put_avatar "$TOKEN_A" "not-a-uid.jpg" "stray-bytes-$TS")
case "$CODE" in
  200) UPLOADED+=("not-a-uid.jpg"); fail "A wrote an arbitrary path — policy hole" ;;
  400|403) ;;
  *) fail "unexpected HTTP $CODE writing arbitrary path as A" ;;
esac
echo "   cross-user and stray-path writes refused ✓"

step "5. Anyone can read (public URL, no auth at all)"
CODE=$(curl -s -o /dev/null -w '%{http_code}' \
  "$URL/storage/v1/object/public/avatars/$USER_A.jpg")
[ "$CODE" = 200 ] || fail "public read of A's avatar failed (HTTP $CODE)"
BODY=$(curl -s "$URL/storage/v1/object/public/avatars/$USER_A.jpg")
printf '%s' "$BODY" | grep -q "fake-jpeg-bytes-v2-$TS" \
  || fail "public read returned stale content (overwrite didn't take)"
echo "   anonymous public read returns the LATEST upload ✓"

step "6. Delete: B cannot delete A's slot; A can delete their own"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
  "$URL/storage/v1/object/avatars/$USER_A.jpg" \
  -H "apikey: $KEY" -H "Authorization: Bearer $TOKEN_B")
case "$CODE" in
  200|204) fail "B deleted A's avatar — policy hole" ;;
esac
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
  "$URL/storage/v1/object/avatars/$USER_A.jpg" \
  -H "apikey: $KEY" -H "Authorization: Bearer $TOKEN_A")
case "$CODE" in
  200|204) ;;
  *) fail "A could not delete own avatar (HTTP $CODE)" ;;
esac
echo "   delete: own allowed, cross-user refused ✓"

printf '\nPhase 13f verification PASSED\n'
