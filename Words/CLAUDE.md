# Words

An invite-only, asynchronous multiplayer Scrabble-style iOS game
(SwiftUI + Supabase, Sign in with Apple only), played with friends and
family, with a permanent AI opponent. Feature-complete for v1 through
Phase 13; remaining work is cleanup → design pass (14) → ship (15).
See PRODUCT-SPEC.md / FEATURE-LIST.md for scope, and **"Current status"
below — start at the COLD-START TL;DR** for where things stand and what
to verify before doing anything.

## Current state (board UX layer)

The original interaction goal — board UX that feels like Scrabble GO —
is met and stable: drag from rack (translucent tile under finger),
drop-cell highlight, haptics, drag/tap placed tiles to move or return
them, rack reorder with gap animation, blank-tile letter picker, live
score chip (cross-words + premiums), two-state zoom (1.0 / 1.7x) with
pinch toggle, pan-while-zoomed, auto-zoom on tile drop, spring-back on
invalid drops. Everything above it (multiplayer, chat, hints, review,
stats) is layered per the phase history in Current status.

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
- OPEN — BLANK SHEET ON PRESENT, now REPRODUCIBLE (2026-07-24): the
  REVIEW sheet shows the exact chat-sheet signature on demand: tap
  Review → blank sheet → lock the phone → content flashes in → unlock →
  content stays. Two sheets with one signature = a general presentation
  problem, not a ChatSheet bug. Shared pattern: content gated on an
  optional @State object, presented by a bool flip, on GameView's
  modifier chain; one difference the logs exploit — chat's store exists
  long before the tap, review's engine is created IN the tap handler.
  Diagnostics armed in BOTH categories ("chat", "review"): GameView
  BODY eval, tap, sheet-CLOSURE eval (with nil-branch fallback+log),
  inner BODY eval with values read, onAppear, .task START, store/engine
  INIT + every phase transition (all with ObjectIdentifiers).
  Discrimination matrix (capture one repro, read in order):
    tap logged, NO closure eval, NO body/onAppear → (a) presentation
      layer stuck before the SwiftUI graph (UIKit commit never happened);
    closure eval logged with engineNil=true / NIL-BRANCH visible → (d)
      nil-gated content — blank is the EmptyView/fallback branch;
    closure eval ok, NO inner BODY eval until the lock → (b) inner view
      graph never ticked (the chat capture looked like this);
    BODY evals logged with correct values but screen blank → (c) render/
      CA commit stuck — SwiftUI fine, pixels not committed.
  DO NOT ship a fix before a capture names the row (three chat fixes
  shipped against wrong theories). Chat + review must be fixed by the
  same mechanism-level change.

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
## Current status (end of session, 2026-07-24)

**COLD-START TL;DR — read this first in a fresh session.**

**Built: Phases 0–13 (with sub-phases through 13c). The app is
FEATURE-COMPLETE for v1**: local game + AI, Supabase async multiplayer,
friends/invites/usernames, push notifications, chat + emoji takeovers +
block/report, hints + post-game review + tap-to-define, stats +
friends-only leaderboard + head-to-head. Remaining: a cleanup pass,
Phase 14 (design pass — every screen deliberately plain until then),
Phase 15 (ship: TestFlight, App Store assets, privacy policy, swap
custom-scheme invite links for universal links).

State a fresh session must verify, not assume:
- **SQL paste ledger** (Adam pastes in the Dashboard; the server is the
  truth): everything through phase13b_stats_endings.sql is pasted and
  verified. phase13c_stats_split.sql was written this session and NOT
  yet confirmed pasted — verify_phase13.sh answers this: red at exactly
  one assertion (KeyError 'ai' in step 2) = not pasted; fully green =
  pasted. Never edit an applied SQL file; new versioned files only.
- **Phone**: has the current client (Phase 13c build, 2026-07-24
  ~14:25, includes optional-'ai' tolerance so it works either way).
  Adam's DEVICE CHECKLISTS for Phases 12 and 13 are both outstanding.
- **Verify harness**: run supabase/check_inline_python.py before AND
  after touching any verify script (python-in-shell is LITERALS ONLY —
  data via env/argv/stdin; see HARNESS RULE below). All 8 scripts +
  checker were green at session end except the expected phase13 'ai'
  red. SUPABASE_SECRET_KEY needs `source ~/.zshrc` (non-interactive
  shells don't load it).
- **Environment weather**: the Supabase auth gateway has been
  intermittently failing on the SERVICE key (curl exit 56 resets and
  bad_jwt/"unrecognized JWT kid" 403s — their side, not ours). Every
  script retries and cleanup now verifies deletes by HTTP code and
  reports STRANDED users loudly. Treat a single 56/403-that-recovers
  as weather; repeated failures as real.
- **OPEN BUG (do not fix without a log capture)**: blank-sheet-on-
  present — see Known rough edges. Reproducible on demand on the
  review sheet; breadcrumbs armed in categories "review" and "chat";
  the discrimination matrix is written down. Three chat-sheet fixes
  already shipped against wrong theories — the next step is READING A
  CAPTURE, not another theory.
- Never commit — Adam commits. Deploys: verify binary freshness (stat
  the binary, `find Words -name "*.swift" -newer …`) before claiming
  anything is on the phone.

Full phase-by-phase history follows.

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

- Phase 12: past games, game-over rework, review, hints, definitions
  (supabase/phase12_review.sql — paste AFTER phase11f).
  - PAST GAMES: acknowledgment-based archival — the game-over screen
    APPEARING marks the result seen (BoardState.markResultSeen once-only
    → autosave + mark_result_seen RPC; game_players.result_seen_at,
    per-seat, synced). Finished+seen = SavedGame.isArchived → out of the
    lobby into the Past games sheet (HomeView; same GameRow, same
    swipe-delete, tap reopens with the result overlay). Presentation
    only; stats (Phase 13) will draw on all finished games.
  - GAME-OVER REWORK: GameOverView gained "Review game" (onReview) which
    dismisses the overlay (resultDismissed, per-game state) into the
    live finished board; the action bar swaps to finishedBar
    (Result / Review-analysis / Rematch). Board stays fully alive —
    invariant 2 untouched, overlay only.
  - REVIEW: move_private table (RLS zero policies) snapshots rack_before
    on EVERY submit_move; fetch_review(game) returns all moves +
    rack_before ONLY for the caller's seat and ONLY on finished games
    ('game_still_active' otherwise) — mid-game rack history is a cheat
    vector, opponent racks stay private forever. ReviewEngine
    (@MainActor @Observable) replays moves to rebuild per-turn boards,
    runs AIPlayer.bestMove per MY turn via Task.detached (progressive:
    turns append live behind a progress bar; first call may pay the trie
    build), caches JSON at App Support/Reviews/<gameID>.json (versioned;
    finished games never change → cache never expires). Moves predating
    the migration have no rack row → shown as un-analyzable, excluded
    from summary math. ReviewView: summary cards (best play, biggest
    miss, points left, avg/turn) + expandable turn rows with a Canvas
    MiniBoardView (board-before muted, played gold, best green outline).
  - HINTS: HintBudget.{placements,bestWord} = 5 each (BoardState.swift,
    the named-constant requirement), HintBudget.placementSpots = 12 —
    CHOICE MADE: top 12 DISTINCT positions (start cell + orientation,
    best word per position; AIPlayer.topMoves), red = best, green =
    rest. Type 2 stages via applyBestWordHint (recall → match rack
    tiles by letter, blanks pre-assigned → placed; never commits; bails
    WITHOUT spending if the board/rack shifted under the async compute).
    Highlights clear on turn boundaries (play/pass/swap/opponent/
    refresh). Compute runs Task.detached with a spinner in the hint
    button (first hint in a HUMAN game pays the trie build). Counters
    persist in SavedGame; GameSync.carryLocalOnly keeps them (and a
    locally-set resultSeen) from being clobbered by server rebuilds.
  - DEFINITIONS: bundled WordNet 3.1 ∩ ENABLE extract
    (Words/Words/definitions.tsv, ~58k entries / 4.2MB; built by
    scratchpad script from wordnetcode.princeton.edu — WORD\tpos. gloss
    | pos. gloss, first sense per POS, irregulars baked in from *.exc).
    Definitions.swift: lazy load + warmUp() at game open, suffix-strip
    stems() for regular inflections, attribution string shown in
    DefinitionSheet. Tap a COMMITTED tile (cell-level onTapGesture;
    TapGesture fails on movement so pans still work; fresh-tile taps
    still return to rack) → committedWords(through:) → sheet. Offline
    by construction; missing entries say "valid word, no definition".
    Amenity, not authority: Lexicon remains the only validity judge.
  - verify_phase12.sh: ack no-op on active, review sealed while active +
    for strangers, move_private RLS-sealed + populated (play rack ==
    dealt rack), per-seat rack privacy both directions, lobby/fetch_game
    result_seen flags, idempotent ack, AI-game review parity.
  - Tests: Phase12Tests.swift (topMoves dedup/sort/cap, hint budget
    spend/stale-bail, staged hint scores == promised, ack once-only,
    snapshot round trip, carryLocalOnly, definitions direct/inflected/
    stems, committedWords).

- Phase 13: stats + friends-only leaderboard + head-to-head — LAST
  feature phase; app is feature-complete for v1 after this
  (supabase/phase13_stats.sql — paste AFTER phase12_review.sql).
  - DESIGN DECISION — ON DEMAND, not incremental: no stats table; three
    SECURITY DEFINER RPCs (fetch_stats(p_user default null=self),
    fetch_leaderboard, fetch_head_to_head) aggregate games/game_players/
    moves at query time via internal stats_for() (EXECUTE revoked from
    clients; verify step 9 proves it). Rationale: trivial scale, zero
    drift, zero backfill, and no "every game-end writer must also
    update stats" sweep (the request_rematch-bypass bug class).
    Archived (result_seen) and hidden (hidden_at) games count — the
    aggregation never reads those columns (verify step 7).
  - SEMANTICS: every TERMINAL status counts, enumerated explicitly —
    'finished' (play-out + six-pass via finish_game), 'resigned'
    (resign_game, block-resign, departed-opponent forfeit), 'expired'
    (phase9 job). Phase13b fix: the first cut filtered status='finished'
    only, so resignations/expiry/departed counted NOTHING (caught by
    verify step 1; phase13b_stats_endings.sql recreates stats_for +
    fetch_head_to_head — leaderboard shares stats_for). winner_seat is
    set on every terminal path, so attribution needed no fix; null =
    tie (ties excluded from win rate); 'human' subset = other seat not
    local_ai ('departed' counts — it was a human game); best word = my
    top client_score play (client-computed, same number history shows).
    verify_phase13 step 1 is now an ENDING ZOO: one game per terminal
    path (play-out, six-pass tie, resignation, expiry forfeit, departed
    opponent) with statuses and winners asserted outright, then the
    stats/H2H/leaderboard ledgers checked against all five.
  - PRIVACY: no new table → no new row policies; existing table RLS
    unchanged; the gate lives in assert_stats_visible (self, else
    accepted friendship AND both-direction block check — defense in
    depth). Stranger and blocked get the SAME 'not_friends' (no
    block-state leak).
  - LEADERBOARD METRIC (decision): rank on win rate over HUMAN games,
    floor of 5 (Leaderboard.rankingFloor in StatsViews.swift, named
    constant); tie-breaks wins → avg score → name (fully ordered, board
    never shuffles). Below floor: unranked, "N more games to rank",
    sorted by progress. AI games excluded from the board (Robo-farming
    must not move it) but included in personal stats (with vs-human
    breakout shown). No metric switcher on purpose.
  - CLIENT: StatsViews.swift (Leaderboard policy enum + StatsSheet +
    HeadToHeadSheet); profile sheet grew ONE row ("Your stats" →
    StatsSheet) instead of a section; FriendsView got a LEADERBOARD
    section (rows tap → H2H sheet; empty state points at the invite
    link; loading/error/empty per invariant 5) with data cached in
    FriendsStore (leaderboard kept on refresh failure — never a silent
    blank). Restrained styling; design pass is next.
  - Tests: Phase13Tests.swift (ranking floor, ordering + tie-breaks,
    unranked-by-progress, win-rate-ignores-ties, DTO decodes incl.
    null best_word). verify_phase13.sh: own/friend stats correctness,
    H2H symmetry + self refusal, board = me+friends exactly, stranger
    sealed, AI-vs-human accounting, hidden-game-still-counts, block
    seals both ways + shrinks board, internal helper sealed.

  - Phase 13c (restructure): human stats are THE record (headline:
    record/win rate/avg vs people — unqualified, matches the
    leaderboard); AI games are PRACTICE, framed explicitly in the UI
    and in the payload shape — stats_for's 'ai' subset carries games +
    avg_score and deliberately NO win/loss keys (a W-L against a
    difficulty you chose isn't a stat; verify asserts the keys are
    absent). Bests stay opponent-agnostic (best word/best game
    combined). Practice score-trend deferred to the design pass (needs
    time-ordered windows + chart). PlayerStats.ai is Optional for
    pre-paste tolerance (client derives the count, shows — for avg).
    DECIDED, recorded in FEATURE-LIST: NO reset-stats feature ever
    (resettable leaderboard = meaningless leaderboard; account
    deletion is the reset). supabase/phase13c_stats_split.sql.

**Next (in order):**
1. Paste phase13c_stats_split.sql if verify_phase13.sh still shows the
   'ai' red; re-run it for the green record.
2. Adam's device passes: Phase 12 checklist (past games, game-over
   rework, review, hints, tap-to-define) and Phase 13 checklist (stats
   split, leaderboard, H2H) — both in session notes, both outstanding.
3. Blank-sheet bug: waiting on Adam's Console capture (categories
   "review"/"chat"); classify via the matrix, THEN fix chat+review
   together with one mechanism-level change.
4. Cleanup pass (Adam's call on scope), then Phase 14 design pass,
   then Phase 15 ship (TestFlight, App Store assets, privacy policy,
   universal links to replace words:// custom scheme).

Session learnings not captured elsewhere:
- HARNESS RULE (fourth harness failure — this must be the last): shell
  variables are NEVER interpolated into Python source in verify scripts.
  The killer was `"$(python3 -c "…{…}")"` — macOS bash 3.2 mangles braces
  in nested double quotes inside command substitution, so the Python
  that RUNS differs from the Python WRITTEN; a static validator can only
  parse the latter, which is why "all 105 blocks verified" still
  shipped a broken block. The class is now BANNED, not linted: every
  python source is a literal (single-quoted -c string or <<'PYEOF'
  heredoc), data crosses only via env/argv/stdin, and JSON payloads
  with variable data are built by fixed python programs taking argv
  (see verify_phase12 step 3, verify_phase10 play_letter).
  supabase/check_inline_python.py enforces this mechanically (bans
  double-quoted sources + unquoted heredocs, ast-parses every literal —
  exact, because literals ARE what python receives; self-tested against
  all three historical failure shapes). RUN IT after any verify-script
  edit, before running the script. Beware `this is not python` — valid
  Python; don't use it as checker bait.
- verify.sh's user creation now retries like make_user (curl exit 56 =
  transient auth-gateway reset; it reproduced twice in one session and
  succeeds on retry). Related cosmetic wart: the ERR trap prints "ERR
  at line N" diags for curl failures that are HANDLED by retry loops
  (`|| rc=$?` still triggers the trap under set -E before the handler
  runs). If a script prints ERR but keeps going and passes, that was
  a survived retry, not a failure.
- AUTH-GATEWAY WEATHER, diagnosed: the flake family (curl exit 56,
  sporadic 403s on admin calls) is the gateway intermittently failing
  to verify the SERVICE key's JWT — the 403 body says bad_jwt /
  "unrecognized JWT kid". Same request succeeds seconds later. Rule:
  retry-with-verification everywhere (done); when a security-ish check
  fails once, confirm the failure is repeatable before believing it
  (a "user still exists" 403 was a deleted user + gateway lie).
- PER-RUN-UNIQUE TEST DATA is a hard rule, learned twice now: a
  cleanup delete silently failed (gateway 403), stranding a "Jessica
  Testclark" profile; the NEXT run's blocked-pair search assertion
  found the stranger and failed as if block-exclusion had regressed.
  Fixes: (1) any searchable fixture data embeds $TS (name AND query);
  (2) assertions must never depend on the ABSENCE of strangers;
  (3) cleanup now verifies every delete by HTTP code (404 = already
  gone counts as success — delete_account'd users) and prints
  "STRANDED, purge manually" instead of claiming success. When a
  previously-green verify step fails right after unrelated changes,
  suspect test-data pollution before product regression.
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
  no pbxproj editing needed. Non-source files dropped into Words/Words/
  (definitions.tsv) become bundle resources the same way.
- definitions.tsv is REGENERABLE: tools/build_definitions.py (run from a
  dir containing an extracted WordNet 3.1 `dict/` from
  wordnetcode.princeton.edu/wn3.1.dict.tar.gz) rebuilds it from ENABLE ∩
  WordNet. Change the sense-count/format there, not by hand-editing 58k
  lines.
