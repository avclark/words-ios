# Words — iOS Board Prototype

A SwiftUI prototype of a Scrabble GO-style board and tile interaction layer.
Currently a single-screen, local-state app. The goal: make the board UX feel
exactly like Scrabble GO before building the rest of the app around it.

## Current state

Working: drag from rack (translucent tile under finger), drop-cell highlight,
haptics, drag/tap placed tiles to move or return them, rack reorder with gap
animation, blank-tile letter picker, live score chip (cross-words + premiums),
two-state zoom (1.0 / 1.7x) with pinch toggle, pan-while-zoomed, auto-zoom on
tile drop, spring-back on invalid drops.

## Architecture invariants — do not break these

1. **One coordinate path.** All pixel↔cell math lives in `BoardMetrics`
   (GameModels.swift). The board transform is `visual = layout × zoom +
   panOffset` (scaled about top-leading), and `BoardMetrics.cell(at:)`
   inverts that exact formula. Never add a second conversion path; never
   hit-test a point that isn't `DragController.visualCenter`. Every past
   version of this app died from visuals and hit-testing disagreeing.
2. **Never remove a view mid-gesture.** A dragged board tile stays in
   `state.placed` and is hidden via opacity; the move commits on gesture
   end. Removing the view kills its gesture and hangs the drag (v1 bug).
3. **Exactly two zoom states** (1.0 and `DragController.placementZoom`).
   No intermediate zoom levels.
4. All drag state flows through `DragController`; views stay presentation-only.
5. **Async work never touches UI state carelessly** (three shipped bugs
   came from this class: the notification-delegate thread crash, the
   invite decode misread as a network error, the blank chat sheet).
   Rules, in order of importance:
   - Every completion path (network, realtime, delegate, timer) hops to
     the MainActor BEFORE touching @Observable/@State — mark the owning
     types @MainActor so the compiler enforces it.
   - Never synchronously mutate state a PARENT view observes from a
     presentation-lifecycle callback (onAppear/onChange during a sheet's
     presentation) — the parent invalidation can collide with the
     presentation transaction and drop the presented view's first frame
     (blank until a system-forced commit). Use `.task` + `await
     Task.yield()` so the mutation lands after the commit.
   - Async views need explicit loading/error/empty states — cached
     content immediately, spinner only while a fetch is genuinely in
     flight, retry on failure. A conditional whose nil branch renders
     EmptyView inside a sheet is a blank screen waiting to happen.
   - Classify errors by kind, not by catch-all: a DecodingError surfaced
     as "network failure" (invite bug) misleads both user and debugger.
6. **Notification callbacks hop to main explicitly.** UNUserNotificationCenter
   delegate callbacks arrive on a background queue and their completion
   handlers feed straight back into UIKit — implement the
   completion-handler variants and run BOTH the body and the
   completionHandler inside DispatchQueue.main.async. The async delegate
   variants resume the framework thunk off-main and crash with "Call must
   be made on main thread". Deep-link IDs from taps must stay parked in
   NotificationsController.pendingGameID until RootView's session objects
   exist — cold-launch taps arrive before the store does — and are
   consumed by whichever comes last (tap or session-ready).

## Tuning knobs (the usual iteration targets)

- `DragController.liftOffset` — tile offset from finger (currently -12pt)
- `DragController.floatingSize` — dragged tile size (54pt)
- `DragController.placementZoom` — zoomed-in scale (1.7)
- `DragController.panGlide` — pan momentum, glide pt per pt/s of flick (0.15);
  glide settle spring is in `panEnded(velocity:)`
- Haptic intensities — `Haptics` enum in DragController.swift
- Spring constants — search `.spring(` across views
- Pan activation threshold — `minimumDistance: 12` in GameView's boardPanGesture
- Pinch snap thresholds — 1.15 / 0.87 in GameView's pinchGesture

## Known rough edges

- Rack reorder insertion index is approximate near rack edges
- Score chip can clip at the board's top edge
- No auto-pan when dragging a tile near the zoomed board's edge
  (Scrabble GO pans automatically; we require manual pan)
- Grabbing the board mid-glide reads the settled target offset, not the
  in-flight presentation value, so the board can jump slightly
- OPEN INTERMITTENT (unreproduced since instrumentation): chat sheet can
  present as a frozen first frame — UIKit shows it but the SwiftUI graph
  inside never ticks (no body eval / onAppear / .task) until a
  system-forced commit (app-switcher swipe, lock). Reproduced through
  three fix attempts, vanished after logging-only changes → Heisenbug or
  environmental (Low Power Mode / cold start / fast-tap suspected).
  Diagnostics armed: category "chat" breadcrumbs log every body eval,
  sheet-closure eval, store INIT (with ObjectIdentifier), tap, and
  onAppear — one log capture of a recurrence classifies the mechanism
  (see the discrimination matrix in the session around 2026-07-23).

## Build & deploy

Deployment target iOS 17. Test on a REAL device — simulator can't judge
drag feel or haptics. The user holds the phone and reports how interactions
feel; treat that feedback as the spec.

Bundle ID: com.kittyrobotics.Words.Words

### Deploy to Adam's iPhone 14 Pro (verified working)

Run from `Words/` (the directory containing `Words.xcodeproj`):

```sh
# 1. Build (note: xcodebuild wants the physical UDID, not the devicectl UUID)
xcodebuild -project Words.xcodeproj -scheme Words -configuration Debug \
  -destination 'id=00008120-0006796E0138C01E' \
  -allowProvisioningUpdates -derivedDataPath build build

# 2. Install over network (devicectl uses the CoreDevice UUID)
xcrun devicectl device install app --device 82327A4A-AE93-497C-9733-3EBBFAB14323 \
  build/Build/Products/Debug-iphoneos/Words.app

# 3. Launch
xcrun devicectl device process launch --device 82327A4A-AE93-497C-9733-3EBBFAB14323 \
  --terminate-existing com.kittyrobotics.Words.Words
```

Gotchas:
- The two device IDs are different on purpose: `xcodebuild -destination` needs the
  physical UDID (`00008120-...`); `devicectl` needs the CoreDevice UUID
  (from `xcrun devicectl list devices`). The CoreDevice UUID can CHANGE after
  re-pairing/OS updates — if devicectl says "device not found", re-run
  `xcrun devicectl list devices` and use the fresh UUID.
- The first `devicectl` install after a while can fail with
  `Network.NWError error 60 - Operation timed out` while the tunnel warms up.
  Just retry once — the second attempt succeeds.
- STALE-DEPLOY TRAP: if the device is offline, `xcodebuild -destination
  'id=…'` fails BEFORE building, leaving the previous binary in
  build/Build/Products/. A later "just install it" then ships stale code
  while the source looks fixed (this shipped a pre-fix build once and
  cost a debugging round trip). Before any install after a failed build,
  verify freshness: `stat -f "%Sm" build/Build/Products/Debug-iphoneos/
  Words.app/Words` must postdate the last source change; when the device
  is offline, build with `-destination 'generic/platform=iOS'` so the
  binary is current when the device returns.

## Out of scope for now

Dictionary validation, networking, accounts, sounds, final visual design.
An existing API server (auth, scoring, hint engine, sockets) exists from a
previous React Native version and may be reconnected later.

## Git

Never create commits. The user commits manually. You may edit files and stage changes, but do not run git commit.
## Current status (end of session, 2026-07-21)

**Completed: Phases 0–5** of the local single-player build (per PRODUCT-SPEC.md
build order). The game is playable end to end on device; Phase 5 changes are
uncommitted in the working tree pending Adam's device testing.

- Phase 0: home screen shell, new-game/exit flow (RootView swaps HomeView ↔
  GameView; fresh UUID identity per game).
- Phase 1: real game — 100-tile bag, bundled ENABLE dictionary (Lexicon.swift,
  fails loudly if missing), full move validation + scoring via playMove().
  This supersedes "dictionary validation" in Out of scope above.
- Phase 2: AI opponent — Appel–Jacobson generator (AIPlayer.swift: anchors,
  trie, cross-checks, transpose for vertical, real blank handling). Scoring
  shared via MoveScorer.swift (one path for preview/player/AI). 7 unit tests
  in WordsTests verify generator legality with rigged boards.
- Phase 3: pass, swap (remove→return→reshuffle→draw), endgame detection
  (bag+rack empty, or 6 passes), final-score math, game-over overlay.
- Phase 4: player/opponent abstraction — Player/PlayerProfile (stable UUID
  identity), OpponentEngine seam (Opponent.swift; LocalAIOpponent wraps the
  generator; actions carry no score — BoardState re-scores everything),
  TurnState .local/.opponent ("waiting" is a real state), GameHeaderView
  (avatars/scores/turn/bag/pass/move log), thin profile editor on Home
  (LocalProfile in UserDefaults).

- Phase 5: persistence + lobby + game setup. SavedGame (GameStore.swift) is
  the complete serializable game state (board, both racks, scores, bag order,
  turn, passes, log, pending placement) — the record that later syncs for
  async multiplayer. GameStore = file-per-game JSON under Application
  Support/Games. BoardState gained gameID/createdAt/difficulty, init(from:),
  snapshot(), and an onAutosave hook fired after every turn-completing
  action; RootView also saves on scenePhase change and exit. If a save has
  turnState .opponent, restore re-kicks the engine (the pre-quit computation
  died with the process). HomeView is now the lobby (rows sorted your-turn →
  waiting → finished, swipe-to-delete, profile sheet, new-game sheet with
  the "invite a friend" seam). AI difficulty: AIPlayer.move(difficulty:)
  picks best / top-quartile / median from the ranked candidates;
  bestMove == .hard (tests unchanged). 3 persistence round-trip tests added.

**Fixed since Phase 4 device testing:** full-rack drag freeze (rack slots
now never remove the dragged tile's view — its slot IS the gap, invariant 2)
and the pass chip now always visible (dimmed at 0/6).

- Phase 6 (per FEATURE-LIST.md; supersedes the old "Phase 6 = stats" note):
  Supabase foundation + auth. supabase-swift 2.49.0 via SPM (pinned by
  toolchain: Xcode 16.2/Swift 6.0.3 can't build ≥2.50). Config in gitignored
  Words/Words/SupabaseConfig.plist (bundled via synchronized group; example
  at Words/SupabaseConfig.example.plist; fails loudly if missing —
  SupabaseService.swift). AuthController.swift: state machine
  loading/signedOut/signedIn(uid)/offline, native Apple sign-in
  (signInWithIdToken + SHA256 nonce), sign-out, delete-account RPC, server
  profile fetch/merge/push (fresh row seeded from Apple name or local
  profile; established server row wins). SignInView gates the app in
  RootView — Apple sign-in verified working; the temporary offline bypass
  from the pre-verification window has been removed (its stale UserDefaults
  flag is cleaned up in AuthController.start()).
  Sign in with Apple entitlement wired (Words/Words.entitlements,
  CODE_SIGN_ENTITLEMENTS) — provisioning accepted it already. Server side:
  supabase/setup.sql (profiles + signup trigger + delete_account RPC —
  MUST be pasted into the SQL editor once), supabase/verify.sh (end-to-end
  server check via admin API, no Apple needed), supabase/README.md (key
  swap + Apple provider steps). Identity model: stable ID = auth.users.id,
  Apple = linked row in auth.identities (additive providers later).

- Phase 7: server-backed games. supabase/phase7_games.sql (MUST be pasted
  into the SQL editor after setup.sql): games/game_players/moves + RLS,
  game_private (bag + racks, RLS with ZERO policies — definer RPCs only),
  minimal friendships/chat stubs. Seats are generic controllers
  (engine = 'human'|'local_ai'); the client drives AI turns (submits for
  the AI seat, may read AI racks — the documented rack-privacy exception).
  Moves are INTENT via submit_move (placements only; server checks turn +
  rack ownership + cell occupancy; client_score recorded but untrusted —
  server scoring can land later with no API change). Server deals ALL
  tiles: remote BoardState never draws locally (isRemote/bagRemaining;
  refills arrive via applyServerDraw), so playing needs connectivity;
  board commit + score stay instant (optimistic), refill animates in on
  the server ack. Client: RemoteGames.swift (DTOs/RPCs), GameSync.swift
  (@MainActor; per-game FIFO op chains, rejection → rollback to server
  truth + alert, migrateLocalGames via idempotent import_local_game,
  refreshLobby reconcile), GameStore per-user dir (Games/<uid>/, adopts
  legacy root files), SavedGame.bagCount (nil = pre-P7 local game).
  BoardState re-kick moved from init(from:) to resumeOpponentTurnIfNeeded()
  so callbacks wire first — callers MUST call it after open.
  Account deletion: server cascade (cleanup_orphan_games trigger deletes
  games with no human seat) + local cache wipe via auth.onAccountDeleted.
  verify_phase7.sh exercises the whole RPC surface with curl.
  4 remote-mode unit tests added (14 total).

- Phase 8: friends & invites. supabase/phase8_friends.sql (paste AFTER
  phase7_games.sql): optional unique usernames on profiles
  (set_username RPC: ok/taken/invalid), invites table (one live token per
  creator, 30-day expiry, redeem = instant accepted friendship;
  own_link/already_friends/invalid handled), friend-request RPCs
  (send/respond/remove/list_friends; mutual request auto-accepts),
  create_game(text, uuid) replaces the old signature — optional human
  opponent (must be accepted friend; ai_rack null for human games).
  HUMAN RACK PRIVACY: the AI-seat rack exception does NOT extend to human
  seats (fetch_game reveals own seat + AI seats only) — verify_phase8.sh
  proves it. Client: invite links via custom scheme words://invite/<token>
  (Words-Info.plist merged via INFOPLIST_FILE; universal links deferred to
  ship time — need a domain + AASA). BoardState: localSeat (challenge
  recipient = server seat 1; class stays local-perspective, GameSync
  translates on the wire), opponentIsHuman (beginOpponentTurn waits
  instead of running an engine — no auto-pass on the empty local mirror
  of a human rack), applyServerRefresh(from:) folds pulled server state
  into the LIVE board (no view teardown — invariant 2). RootView polls
  fetch_game every 10s while waiting on a human. FriendsView/FriendsStore
  (invite ShareLink, username search, requests, challenge), new-game
  sheet lists Robo + friends. All verify scripts now trap EXIT and clean
  up their users on failure; verify_phase7.sh also purges stale test
  users from earlier runs. AIPlayer.move got an alphabetical tie-break —
  candidate emission order is hash-order-dependent and QUICK/QUIRK tie at
  17 made blankCompletesHighValueWord flaky (test comment documents it).
  18 unit tests.

- Phase 8b: account deletion in human games
  (supabase/phase8b_account_deletion.sql — paste AFTER phase8_friends.sql).
  The "step 11 regression" was a false positive: verify_phase7's old
  assertion checked the WHOLE games table was empty, which broke the
  moment Adam had real production games — now scoped to the run's own
  game ids. The real gap it surfaced: deleting an account cascaded the
  seat row away, zombifying the human opponent's game. Fix: BEFORE DELETE
  trigger on profiles — active human-vs-human games flip to resigned with
  the remaining seat as winner (visible forfeit, no dark patterns);
  departing seat is anonymized (engine 'departed', user_id null, named
  constraints re-added to allow it); last-real-human deletion still
  removes the game entirely (orphan cleanup treats departed as
  non-human). Client maps departed → "Departed player". verify_phase8
  step 8 proves forfeit + anonymize + final cleanup.
  NOTE: SUPABASE_SECRET_KEY lives in ~/.zshrc — `source ~/.zshrc` before
  running verify scripts (non-interactive shells don't load it).

- Phase 9: multiplayer robustness (supabase/phase9_robustness.sql — paste
  AFTER phase8b). Persisted op queue: GameSync journals every op
  (submit/resign/finish) to Games/<uid>/pending-ops.json BEFORE first
  attempt, removes on success/terminal rejection; flushPending() on
  launch + foreground (ALWAYS before any pull — order prevents rollback
  of unpushed optimistic state). Idempotency: submit_move p_op_id +
  moves.client_op_id unique — a replayed already-applied op returns
  duplicate:true + the seat's CURRENT rack; client reconciles via
  applyAuthoritativeRack (folds tentative placements back in). Rejection
  → drop the game's queued ops + rollback + alert naming the opponent.
  Expiry: 14-day inactivity window (friends-and-family pace — expiry is
  garbage collection, not churn pressure), warn at <24h, expire only
  after the warning has stood 24h; human-vs-human only (solo AI games
  never expire); inactive player forfeits (winner = other seat);
  process_game_expiry() hourly via pg_cron (guarded — if pg_cron missing,
  schedule externally); Phase 10 push hooks on expiry_warned_at
  transitions. Deadline visible: lobby row ("expires in Nd") + header
  clock chip when <3 days. Resign: flag button in game header (human
  games), confirmation dialog, explicit loss regardless of score
  (GameOverSummary.localWon overrides score comparison — also used for
  expiry). Rematch: request_rematch RPC — unique index on rematch_of +
  row lock = both-players-tap yields ONE game; creator seat 0, joiner
  seat 1 (BoardState localSeat init param). Sync: kept polling over
  Supabase realtime (async game, battery, simplicity; revisit when
  Phase 11 chat needs realtime anyway) — 10s waiting / 30s own turn,
  poll dies with the screen. 25 unit tests.

- Phase 10: push notifications (supabase/phase10_notifications.sql — paste
  AFTER phase9; edge function supabase/functions/send-push/ — deploy with
  `supabase functions deploy send-push --no-verify-jwt` after `supabase
  link --project-ref wdbouucicnxeoomazerx`; secrets: APNS_KEY_ID,
  APNS_TEAM_ID (67DBW6837G), APNS_PRIVATE_KEY (p8 contents), APNS_TOPIC
  (bundle id), APNS_ENV sandbox|production). OUTBOX PATTERN: every event
  → notify_user() (closed type CHECK matching FEATURE-LIST exactly:
  turn/new_game/game_over/chat/expiry_warning/ping; prefs checked
  server-side BEFORE insert) → notification_outbox → edge function drains
  to APNs (pg_net poke + 5-min cron sweep; claim-first, 410 deletes
  token). NO generic send API exists — nags require changing the schema
  constraint, by design. Turn pushes: human-vs-human only (trigger skips
  when recipient == auth.uid(), which also covers solo AI). Ping: 1 per
  game per 6h, only on opponent's turn (game_players.last_ping_at).
  Badge = human games awaiting your move (server at send, client
  recomputes on foreground). Client: PushController.swift
  (NotificationsController.shared + AppDelegate adaptor; permission asked
  at FIRST HUMAN GAME, never launch; tap routes via payload game_id →
  RootView.openFromNotification; in-game banners for the visible game
  suppressed; sign-out/delete unregisters the token via
  auth.onWillSignOut). Prefs toggles in profile sheet (direct table RLS).
  aps-environment=development in entitlements (provisioning accepted it).
  verify_phase10.sh proves the whole server pipeline headlessly; simctl
  push tests client UX without APNs; real delivery needs the p8 key +
  device. 28 unit tests.

- Phase 11: chat + emoji takeovers + block/report + realtime
  (supabase/phase11_chat.sql — paste AFTER phase10; NOTE verify_phase10
  step 8 now needs it too). Emoji reactions ARE chat messages
  (kind='emoji') — one table/stream/notification path. Chat writes via
  send_chat ONLY (direct-insert policy dropped; enforces participant +
  human-opponent + not-blocked, bumps games.updated_at so lobbies
  refresh). TWO read markers by design: server chat_reads drives unread
  badges (moves when the chat sheet is read); a device-local takeover
  mark (UserDefaults) records which emoji animated — takeover fires
  exactly once, and a reinstall can't replay server-read history
  (candidates = emoji > max(both marks)). EmojiTakeover.swift: 7 distinct
  styles (confetti/tumble/zoomQuiver/flames/clapWave/heartbeat/
  slamShake), all pure functions of elapsed time over TimelineView +
  Canvas, hit-test-disabled overlay ABOVE the board — a live drag is
  never disturbed (invariant 2); the slam SHAKES THE OVERLAY, never the
  board. Realtime: GameChannel (Chat.swift) per open game — chat inserts
  + games-row updates (RLS applies); Phase 9 polling stays as fallback;
  disconnect on background, reconnect on foreground fires onReconnect →
  full re-sync. Block (block_user): auto-resigns shared active games AS
  BLOCKER, deletes friendship, seals chat/requests/invites/games both
  ways (checks added to create_game/send_friend_request/redeem_invite;
  blocked invite redemption reads as 'invalid' on purpose). Reports →
  service-only reports table (dashboard review). Blocked-players +
  unblock in profile sheet. 33 unit tests.

- Phase 11b: rematch block-bypass fix + readable reports
  (supabase/phase11b_block_rematch.sql — paste AFTER phase11).
  request_rematch (Phase 9 vintage) was the ONE game-creation path the
  Phase 11 block sweep missed — blocked players could rematch a resigned
  game into a fresh playable one. Now raises 'rematch_unavailable'
  (client shows "A rematch isn't available for this game." — clear
  outcome, block not disclosed, same stance as invites→'invalid').
  Full audit recorded in the SQL header: every other creation path was
  already sealed; submit_move/ping are transitively safe (blocks resign
  all shared active games). LESSON: when adding a cross-cutting check,
  grep EVERY function that inserts into the guarded table — the sweep
  updated the functions being replaced that phase and missed one from an
  earlier phase. reports_readable view: reports joined to names +
  message text, service_role only, for at-a-glance Table Editor review.
  verify_phase11 now covers rematch-under-block (both directions),
  post-unblock rematch restoration, and view access control.
  PRODUCT DECISION — unblock does NOT restore friendship: blocking ends
  the relationship (games resigned, friendship deleted); unblocking only
  permits a new one — reconnection is a fresh request/invite, so it's
  always a deliberate, visible act on both sides (auto-restore would pop
  the pair back into each other's lists with no action taken, leaking
  the block-then-unblock). Stated in the UI at the point of action:
  caption under Blocked Players + post-unblock alert. verify_phase11
  step 7 asserts not-friends-after-unblock both sides + deliberate
  re-friend works.

- Phase 11c: search by display name OR username
  (supabase/phase11c_search.sql — paste AFTER phase11b). Friends search
  for "Jessica", not @handles — search_players RPC matches either,
  case-insensitive substring, ilike wildcards escaped, 2-char minimum +
  10-result cap (enumeration guards), blocked pairs excluded from each
  other's results, relationship state included so identical names are
  distinguishable (Friends ✓ / Requested / Accept / Add). PRIVACY
  DECISION: everyone is findable by name — acceptable because the only
  consequence is a consent-gated friend request in an invite-only app;
  NO hide-from-search setting (decline + block cover the harm; revisit
  only if the app stops being invite-only). Username reframed as an
  optional exact handle on top (profile sheet + Friends copy updated);
  usernames claimable/clearable in profile sheet with inline
  taken/invalid feedback (set_username RPC, no schema change).
  verify_phase11 step 5b covers name/username/no-match/min-length/
  wildcard-escape; step 6 covers search block-exclusion.

- Phase 11d: durable deletion + friend notifications
  (supabase/phase11d_delete_and_friends.sql — paste AFTER phase11c).
  DELETION SEMANTICS: delete = remove from MY lobby only — human games
  get per-seat hide (game_players.hidden_at; fetch_lobby excludes;
  opponent untouched); solo games (AI/departed) hard-delete; ACTIVE
  human games refuse 'resign_first' (UI hides the swipe too). The old
  swipe-delete was cache-only and every sync resurrected the rows.
  Client deletes server-FIRST, cache after; failure alerts.
  FRIEND NOTIFICATIONS (spec gap closed; FEATURE-LIST updated):
  'friend_request' on request; 'friend_accept' to the SENDER on
  acceptance and to the INVITER on invite redemption; declines never
  notify. Same notify_user gate + outbox constraint (expanded), one
  'friend' prefs toggle, tap opens the friends sheet (payload type
  friend_* → NotificationsController.pendingFriendsOpen → RootView
  showFriendsSheet binding into HomeView). verify_phase11 steps 9/10
  cover hide-durability/opponent-copy/resign_first/AI-hard-delete and
  request/accept/invite-accept/toggle.

- Phase 11e: unfriend semantics (supabase/phase11e_unfriend.sql — paste
  AFTER phase11d). THE LADDER: unfriend = nothing NEW (create_game
  not_friends; rematch counts as new → rematch_unavailable,
  indistinguishable from block on purpose) but in-flight games play out
  WITH chat; chat closes when they end (send_chat: friendship OR active
  game, else 'chat_closed'); block = stop-now; deletion = +anonymize.
  No unfriend notification — discoverable through state, not broadcast.
  FriendsView remove now confirms with the semantics stated; ChatStore
  surfaces send failures (chat_closed/blocked/network) inline instead of
  silently dropping messages. ALSO FIXED: notification toggles blanked
  on devices WITH a prefs row — fetchNotificationPrefs' select list
  lagged the struct when 11d added `friend`, and synthesized Decodable
  requires keys even with property defaults → decode threw → try? → nil
  → empty section (simulator worked only because its account had NO
  row). Now select("*") + hand-written tolerant decodeIfPresent init +
  the section always shows toggles/error+retry/spinner, never blank.
  verify_phase11 step 10b covers the ladder end to end.

- Phase 11f: chat lives and dies with the game
  (supabase/phase11f_chat_closure.sql — paste AFTER phase11e; BOTH 11e
  and 11f were unpasted as of this session's end). PRODUCT DECISION:
  a game ending closes its chat for EVERYONE, friendship irrelevant —
  finished games are history; rematch to keep talking. (11e briefly
  tied finished-game chat to friendship; the client's game-over overlay
  made that clause unreachable, so the rule became the simple one.)
  Unfriend therefore means exactly one thing: no new games/rematches.
  Client: chat button hidden on finished games (explicit, was
  overlay-accident); opening a finished game auto-clears unread so a
  pre-finish message can't stick a badge forever (KNOWN TRADE-OFF: a
  "gg" sent right before resign is only ever seen as its push banner);
  chat_closed send error reworded for its one reachable case (game ends
  while sheet open). verify_phase11 10b now asserts closure is a GAME
  rule (still closed after re-friending).

**Next:** paste phase11e_unfriend.sql THEN phase11f_chat_closure.sql,
re-run verify_phase11.sh (10b must fully pass), device-retest unfriend +
finished-game chat. Then Phase 12 — hints, post-game review, definitions.

Session learnings not captured elsewhere:
- FALSE-ALARM TRAP (cost a security scare): a Supabase request with an
  empty/absent Bearer token authenticates as the `apikey` HEADER — in the
  verify scripts that's the SECRET key = service_role = RLS bypassed. A
  transient make_user failure left an empty token, and the "stranger"
  read everything, mimicking an RLS hole that did not exist. Guards now
  structural: make_user emits only complete credentials (internal
  retries, aborts otherwise), every call site asserts non-empty, and
  rpc() refuses empty tokens outright. Corollary: when a security test
  fails, verify the test's own auth identity before believing the leak.
- ENABLE list surprises: "john", "jow", "jus" ARE words; "za", "ki", "non",
  "nos"… check assumptions. When writing generator tests with rigged boards,
  grep enable1.txt for EVERY word/non-word assumption first — two test rigs
  failed because the generator legally outplayed the hand analysis.
- `xcodebuild test` console doesn't show #expect failure details or print()
  from Swift Testing. Use `-resultBundlePath` + `xcrun xcresulttool get
  test-results summary` and read `testFailures[].failureText` (Issue.record
  strings land there).
- Unit tests run on the iPhone 16 Pro simulator; trie build + all 7 tests
  finish in ~1s, so run them before every device deploy.
- New .swift files are picked up automatically (synchronized project groups) —
  no pbxproj editing needed.
