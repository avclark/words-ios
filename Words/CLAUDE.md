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

**Next:** finish Phase 6 verification (run setup.sql, swap publishable key,
rotate secret key, then Apple flow once the membership is active). Then
Phase 7 — data model + game sync (see FEATURE-LIST.md).

Session learnings not captured elsewhere:
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
