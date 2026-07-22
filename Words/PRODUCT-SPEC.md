# Words — Product Spec

The destination is an **invite-only, asynchronous multiplayer word game** played
with friends and family. Single-player vs. AI is a permanent feature, not
scaffolding. This document captures functional decisions; visual design is
deliberately deferred to a later pass.

## Core decisions

**Opponents**
- Invite-only. Friends found by username or invite link.
- No random matchmaking with strangers, no public/global leaderboards.
- AI opponent is a permanent feature — lets a player start a game any time,
  especially useful when human opponents are slow to take their turns.

**Games**
- Multiple simultaneous games (Scrabble GO-style lobby listing all active
  games with "your turn" / "their turn" / "finished" states).
- Games must survive app closes and device restarts (server is the source of
  truth once multiplayer exists; local persistence before that).

**Turns**
- Asynchronous by default: play whenever, no one needs to be online at once.
- Real-time live sync (moves appearing instantly when both players happen to
  be in the app) is a desirable LATER enhancement, layered on top of async.
  Do not build both at once.

**Accounts / auth**
- **v1: Sign in with Apple ONLY.** One tap, no passwords, no reset flow to
  build or maintain. All players are invited personally and on iPhone, so
  this covers everyone. Apple's private email relay addresses privacy
  concerns for users who don't want to share a real address.
- No guest mode: every player needs an account to be identified and routed
  turns. Guest-to-account conversion would be a flow for a user who doesn't
  exist in this app's audience.
- No Facebook login: friend-finding is by invite link/username, not a social
  graph.
- **REQUIREMENT for later extensibility:** model users so a user *has* auth
  credentials rather than a user *being* an Apple identity. The user record
  needs a stable internal ID with the Apple identity as a linked credential.
  Done this way, email/password (or Google) can be added later as a purely
  additive change with no migration. Managed backends do this by default —
  don't fight the platform.
- NOTE if third-party logins are ever added: Apple requires Sign in with
  Apple to be offered alongside other third-party logins (e.g. Google).

**Sessions**
- Sign in once, stay signed in indefinitely. Session token stored in the iOS
  Keychain and silently refreshed.
- No Face ID / biometric gate: there is nothing sensitive to protect in a
  word game, and it would add a tap for no security benefit.

**Notifications**
- Push notifications are essential in v1 of multiplayer: "your turn" and
  "game over" at minimum.

## How this shapes the LOCAL build (before any backend)

The local single-player app should be built as if the opponent is already
remote. The AI is one implementation of an opponent, not a special case.

1. **Player abstraction.** Model players generically (identity, display name,
   avatar, score, turn state). "You" and "the AI" are two instances. A remote
   human becomes a third kind with no changes to the game screen.
2. **Opponent interface.** Moves flow through one path that doesn't know
   whether they came from the local AI generator or a server. "Waiting for
   opponent" is a real modeled state, not "AI is thinking."
3. **Game persistence.** Persist in-progress games locally now. This is
   directly reusable for async multiplayer, where games MUST survive app
   closes.
4. **Lobby-shaped home screen.** Even with only local games, structure the
   home screen as a list of games rather than a single "New Game" button.
5. **Thin local profile.** Avatar + display name + basic stats, stored as a
   user record (not hardcoded as "the local user"). Keep deliberately
   minimal — it gets rebuilt against server data later.

## Build order

- Phase 4: Player/opponent abstraction + game screen chrome (avatars, scores,
  turn indicator, move log). Most architecturally load-bearing phase.
- Phase 5: Home screen as game lobby + game setup (AI difficulty) + local
  game persistence.
- Phase 6: Thin local profile (avatar, display name, basic stats).
- Backend design conversation (managed platform vs. custom server; data model).
- Multiplayer: accounts, server, async games, friends, push notifications.
- Design pass across all screens.
- Later: optional real-time live sync; email/password or Google auth if a
  player actually needs it.

## Known future requirements

- Apple Developer Program ($99/yr) required for TestFlight distribution to
  friends/family, and to escape the 7-day free-provisioning expiry.
- A backend has ongoing hosting cost.
- Deferred from the original feature checklist (revisit post-multiplayer):
  chat + moderation (Apple requires block/report for user-generated content),
  boosts/power-ups, cosmetics, leagues, monetization.
