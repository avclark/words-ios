# Game Logic Reference

Knowledge harvested from the old Replit/Node backend, to reimplement in
Swift. This is a spec of *rules and approaches*, not code to copy. The
Replit implementation had real weaknesses (noted below) — reproduce the
correct rules, not its shortcuts.

## Move validation (rules are correct — port these)

A move is legal iff ALL hold:
1. At least one tile placed; no more than 7.
2. Every placed tile is in bounds and on an empty square; no duplicate
   positions.
3. All placed tiles share one row (horizontal) or one column (vertical).
4. The run is contiguous: between the min and max placed position along
   the line, every intermediate cell is filled — by a newly placed tile
   OR a tile already on the board.
5. First move of the game: must cover the center square (7,7).
6. Every later move: at least one placed tile must be orthogonally
   adjacent to an existing board tile (i.e., the new word connects).

Your prototype's live score preview already checks 1–4. When you add real
turn logic, add 5 and 6.

## Words formed by a move

- The "main word" is the full contiguous run along the move's axis
  (extending through existing tiles on both ends).
- Each placed tile may also form a "cross word" on the perpendicular axis.
- A single-tile move can form words on BOTH axes.
- Only runs of length >= 2 count as words.
- Every formed word must be in the dictionary or the whole move is illegal.

## Scoring (correct — port this)

For each word formed:
- Sum letter values. Blank tiles = 0.
- Premium squares apply ONLY to tiles placed THIS turn (existing tiles on
  the board score face value, no premium):
  - DLS: letter × 2, TLS: letter × 3 (added to word score)
  - DWS / center: word × 2 (multiplier), TWS: word × 3 (multiplier)
  - Multiple word multipliers stack (e.g., two DWS = ×4).
- Total move score = sum of all words' scores.
- Bingo bonus: +50 if all 7 tiles were used in one move.

(The prototype's `BoardState.currentScore()` already implements this
correctly, including cross-words and premiums.)

## Tile bag (subtle ordering — preserve it)

- Standard 100-tile distribution.
- Swap: remove chosen letters from rack, return them to the bag, RESHUFFLE,
  THEN draw replacements. Order matters — reshuffling before drawing stops
  a player drawing back their own just-discarded tiles.
- Refill draws up to a 7-tile rack after each move.

## Endgame (correct — non-obvious, keep as reference)

- Game ends when: bag is empty AND some player has emptied their rack; OR
  6 consecutive passes (3 per player in a 2-player game).
- Final scoring: each player loses the sum of their leftover tile values;
  the player who emptied their rack GAINS the total of all opponents'
  leftovers.

## Move generator / AI / hint (keep the SHAPE, rebuild properly)

Move generator + hint to be reworked from scratch; design TBD at step 4.

The Replit `findBestWord` approach — permute rack → keep valid words → try
placements → score → keep best — is the right skeleton for BOTH the AI
opponent and the hint feature.

BUT the Replit implementation is a toy; do NOT reproduce its details:
- It only tried horizontal words (can't build vertical plays at all).
- It permuted at most 5 tiles and capped at 500 permutations "for
  performance," so it misses most strong plays.
- It hardcoded a blank tile as the letter "A".

Do it properly in Swift. For a real move generator, the standard approach
is a precomputed dictionary structure (DAWG or GADDAG) that finds all legal
placements efficiently, rather than brute-forcing permutations. AI
difficulty = pick from the ranked candidate plays (best play = hard;
a weaker/random valid play = easy).

## Dictionary (fix the Replit bug)

- Use an open word list: ENABLE (~173k words) or a SOWPODS-derived list.
  Avoid officially licensed dictionaries (TWL/Collins) for IP reasons.
- Bundle the word list INSIDE the app.
- CRITICAL: fail loudly if the list is missing. The Replit version silently
  accepted EVERY word when its list failed to load — never fall open.
- No definitions in these lists; pair with Wiktionary/WordNet data later if
  tap-for-definition is wanted.

## Discarded from Replit (not applicable to a local Swift app)

HTTP routing, DB schema, auth, websockets, generated Zod types. If online
multiplayer is built later, these become relevant as concepts again, but
none of the code transfers.
