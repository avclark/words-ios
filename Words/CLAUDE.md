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
xcrun devicectl device install app --device C3AC3F89-00F5-4B58-A306-A871F4FA067C \
  build/Build/Products/Debug-iphoneos/Words.app

# 3. Launch
xcrun devicectl device process launch --device C3AC3F89-00F5-4B58-A306-A871F4FA067C \
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