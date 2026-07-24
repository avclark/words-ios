# Words — v1 Feature List & Phase Plan

Companion to PRODUCT-SPEC.md (which holds the multiplayer/architecture
decisions). This is the definitive feature scope for v1 and the build order.

## Product thesis

Scrabble GO is slow, glitchy, ad-saturated, and badly designed. Words is the
opposite: fast, clean, no ads, no dark patterns, and genuinely delightful to
use. **The differentiator is quality, not feature count.** Every feature must
earn its place against that thesis — anything that adds friction between the
player and the game is suspect by default.

Platform: iPhone only. Backend: Supabase. Auth: Sign in with Apple only.

---

## ALREADY BUILT (Phases 0–5, local)

- 15x15 board, standard premium squares, standard 100-tile bag
- Drag-and-drop tile placement with two-state zoom + pan, haptics, rack
  reorder, tap-to-place, recall, spring-back on invalid drops
- Blank tiles with letter picker
- Live score preview (cross-words, premiums, bingo bonus)
- Full move validation (line, contiguity, center opening, connection,
  dictionary check on all formed words) against bundled ENABLE word list
- Pass, swap/exchange (correct bag ordering), endgame detection, final
  scoring with leftover-tile math, game-over screen
- AI opponent ("Robo") with proper move generator (vertical + horizontal,
  correct blank handling, cross-word validation) and 3 difficulty levels
- Player/opponent abstraction (multiplayer-shaped), game header with
  avatars/scores/turn state/move log
- Local game persistence (force-quit safe), lobby with multiple games,
  new-game setup with difficulty

---

## v1 FEATURE LIST

### Accounts & identity
- Sign in with Apple only (no email/password, no guest mode, no Facebook)
- Persistent session (Keychain, silent refresh) — sign in once, stay in
- Display name + avatar (photo upload or built-in set)
- Sign out
- Account deletion (App Store requirement for apps with accounts)

### Friends
- **Invite link is the primary mechanism**: shareable link the user sends via
  iMessage/anything. Tap to accept, you're friends. This covers the realistic
  case (texting your wife a link).
- Username search as a backstop, for "I know they play but don't have a link."
  Usernames are user-chosen and shareable.
- NO email search — privacy exposure (lets anyone probe whether an address
  plays the game) isn't worth it for a friends-only app, and Apple's private
  relay means many users don't know their own address.
- NO contact/phone matching — Sign in with Apple provides no phone number, so
  there is nothing to match against. (Also avoids SMS cost entirely.)
- Friend requests: send, accept, decline, remove
- Friends list with "challenge" action
- Relationship-ending ladder (three distinct rungs, Phase 11e/f): UNFRIEND
  is gentle and means exactly one thing — no new games or rematches;
  games in flight play out honorably, chat included. BLOCK stops all
  contact now (resigns shared games, seals everything); ACCOUNT DELETION
  additionally anonymizes the seat. Unfriending never notifies the other
  party — it's discoverable through state, not broadcast.
  (Chat closure is a GAME rule, not a friendship rule: chat lives and
  dies with its game, for everyone — see Chat & delight.)

### Games & multiplayer
- Asynchronous 1v1 games with friends (server is source of truth)
- Multiple simultaneous games
- Lobby grouped/sorted: Your Turn → Their Turn → Finished
- Start game from friends list or lobby
- Rematch (one tap, from game-over)
- Resign
- **Game expiry with warning, never silent**: if a game goes inactive, notify
  the player whose turn it is that the game expires today unless they play.
  Only if no action is taken does the game then expire. No silent
  auto-forfeits — that's the kind of dark pattern this app exists to avoid.
  (Scrabble GO uses a 7-day window; pick a value, warn before it lands.)
- AI opponent remains permanently available (play solo any time, especially
  while waiting on human opponents)
- Optimistic UI: moves commit instantly on-device and sync; never wait on
  the network for the feel of placing a word

### Hints & learning
Two distinct hint types, both powered by the existing move generator (which
already produces every legal candidate, ranked by score). No currency, no XP,
no purchases.

- **Hint type 1 — Show playable locations.** Outlines every place a word can
  be played from the current rack: green outlines for valid placements, red
  outline for the best/highest-scoring option. Does NOT place tiles.
  *Design note:* an open board with a full rack can yield hundreds of legal
  placements — outlining all of them is visual soup. Show the top N (start
  ~10–15) or filter to distinct anchor positions. Tuning decision at build.
- **Hint type 2 — Show best word.** Actually stages the tiles on the board
  forming the highest-scoring play. Does NOT commit it — the player can then
  play it, recall it, or do something else.
- **Budget: 5 of EACH type per game.** Both values must be single named
  config constants, trivially adjustable — not magic numbers scattered
  through the code.
- **Post-game review**: after a game ends, show best missed plays per turn
  ("your best play on turn 7 was QUARTZ for 68"). Free — this is the feature
  Scrabble GO puts behind a subscription.
- **Tap-to-define**: tap any played word on the board for its definition.
  Requires a definitions data source (ENABLE has none) — Wiktionary/WordNet
  extract bundled locally, or an API.

### Chat & delight (the signature feature)
- In-game chat, iMessage-style bubbles, per game. Chat lives and dies
  with its game: when the game ends, its chat closes for everyone,
  friendship or not — a finished game is history; rematch to keep
  talking. (Phase 11f)
- Emoji reactions from a quick panel
- **Screen-takeover animations**: when you open a game, a waiting emoji from
  your opponent animates dramatically — confetti, screen-filling effects,
  iMessage-style. This is the differentiator; make it excellent.
- Block and report (REQUIRED by Apple for user-generated content)
- Chat notification toggle

### Notifications
Sent when the user has them enabled, for these events:
- It's your turn
- A new game has started (someone challenged you)
- A game has ended
- A new chat message arrives
- **Expiry warning** — "this game expires today if you don't play"
- **Ping / nudge**: a player can prompt their opponent that they're waiting
  ("Adam is waiting for you to play"). Rate-limit this so it can't be spammed.
- A friend request arrives, or your request/invite is accepted. Declines
  never notify — there's no action to take, and silence there is kindness,
  not a dark pattern. (Added Phase 11d; one "Friend requests" toggle
  covers both.)

**Notification discipline (a deliberate differentiator):** NEVER send
re-engagement nags, "your friend misses you," promotional pushes, or anything
not in the list above. Every notification this app sends is a real event the
player asked to know about.

- Per-type toggles in settings

### Stats & leaderboard
- Profile stats: games played, won, lost, win rate, average score, best word,
  best game score
- **Friends-only leaderboard** (no global rankings, no strangers)
- Head-to-head record when viewing a friend

### Settings
- Notification toggles
- Sound/haptics toggles
- Privacy policy (App Store requirement)
- Account deletion

---

## EXPLICITLY EXCLUDED FROM v1

- Ads of any kind, ever (core to the thesis)
- In-app purchases / premium currency / diamonds
- Boosts, power-ups, chests, loot boxes
- Global leaderboards, random matchmaking with strangers
- Themed/constrained game modes, daily puzzles
- Mini-games and any XP/economy system (see roadmap below)
- Word strength meter (redundant with live score preview)
- Cosmetics/collectible tile sets
- More than 2 players per game
- Android, web client

## ROADMAP (post-v1, standalone — not gated to anything)

- Word-training mini-game, designed on its own terms as a fun way to learn
  words. NOT wired to an XP economy that unlocks hints.
- Optional real-time live sync when both players are in the app
- Additional auth methods if a player actually needs them

---

## REMAINING PHASE PLAN

**Phase 6 — Supabase foundation + auth**
Set up the Supabase project. Sign in with Apple. User records modeled with a
stable internal ID and Apple identity as a linked credential (per
PRODUCT-SPEC, so other auth methods stay additive). Profile: display name,
avatar. Sign out, account deletion. Local games keep working throughout.

**Phase 7 — Data model + game sync**
Schema for users, friendships, games, moves, chat. Migrate the local
SavedGame shape to server-backed games. Moves submitted as *intent* (not
results-with-score) so full server validation can be added later without an
API redesign. Server-side turn and rack-ownership checks. Optimistic UI.

**Phase 8 — Friends & invites**
Username search, invite links, friend requests, friends list, challenge to
game. Optional contact matching.

**Phase 9 — Async multiplayer end to end**
Real games against real people. Lobby driven by server state. Rematch,
resign, game expiry/auto-forfeit.

**Phase 10 — Push notifications**
Your turn, new game started, game ended, chat message, expiry warning, and
opponent ping (rate-limited). Supabase edge function calling APNs. Per-type
toggles. Strict discipline: no re-engagement pushes, ever.

**Phase 11 — Chat + emoji delight**
Chat per game, emoji reactions, screen-takeover animations on open. Block and
report.

**Phase 12 — Hints, post-game review, definitions**
Both hint types (show playable locations; stage best word), 5 of each per
game as adjustable config constants. Post-game best-missed-play review.
Tap-to-define with a bundled definitions source.

**Phase 13 — Stats & friends leaderboard**
Profile stats, friends-only leaderboard, head-to-head records.

**Phase 14 — Design pass**
The full visual redesign across every screen, now that the app is complete
and its shape is known.

**Phase 15 — Ship**
Apple Developer Program, App Store assets, privacy policy, TestFlight to
wife/friends, then App Store submission.

Note: the game is playable with friends at the end of Phase 9. Phases 10–13
make it good; Phase 14 makes it beautiful.
