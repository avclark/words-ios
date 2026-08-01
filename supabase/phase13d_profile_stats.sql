-- Words — Phase 13d: personal profile stat aggregations (Pass A).
-- Run AFTER phase13c_stats_split.sql. Idempotent.
--
-- The Profile hub (client Round 1) laid out stat blocks that had no
-- server source: average word score (+ monthly chart), win streaks,
-- point-word buckets, bingos. This adds ONE new self-only RPC that
-- computes them on demand — same design as Phase 13: no stats table,
-- SECURITY DEFINER aggregation over games/game_players/moves at query
-- time (trivial scale, zero drift, zero backfill). fetch_stats /
-- fetch_leaderboard / fetch_head_to_head are UNTOUCHED, as are all
-- their visibility gates — this RPC serves only the caller's own
-- numbers (auth.uid()); there is no p_user parameter to gate.
--
-- THE COUNT RULE (mirrors Phase 13c's framing):
--   • SKILL stats count ALL terminal games, human AND AI: average word
--     score, best word, best game, average game, bingos, point-word
--     buckets. A great word is a great word, whoever sat across.
--   • WIN stats count HUMAN games only: wins, longest win streak,
--     current win streak. A win against a difficulty you chose isn't a
--     win — AI games must never touch streaks.
--
-- WHAT COUNTS AS A "WORD": one 'play' move. Its recorded client_score
-- is the move's TOTAL as the game actually scored it — main word +
-- cross-words + premiums + the bingo bonus. Cross-words never get move
-- rows of their own, so nothing is double-counted; this is the same
-- number the in-game history and review show. (client_score is the
-- client-computed history number, matching Phase 13's best_word.)
--
-- Universe: TERMINAL games only ('finished','resigned','expired') —
-- the same universe every existing stat uses. In-flight games don't
-- move stats.
--
-- BINGO: a play using all seven tiles (jsonb_array_length(placements)
-- = 7) — the move the +50 bonus marks.
--
-- POINT-WORD BUCKETS: independent tiers (Scrabble GO-style): count of
-- plays scoring ≥50, ≥40, ≥30 — a 55-point word counts in all three.
--
-- STREAK ORDER: human terminal games by finished_at (set on every
-- terminal path: finish_game, resign_game, expiry, departed-account,
-- block-resign), coalesced to updated_at for safety on legacy rows.
-- Ties (winner_seat null) break streaks and never count as wins.
--
-- MONTHLY SERIES: last 4 calendar months including the current one,
-- keyed 'YYYY-MM'; only months with at least one play appear. Averages
-- round to 1 decimal. 'lifetime'/'this_month' are null when there are
-- no qualifying plays (the client renders "—").

create or replace function public.profile_stats_for(p_user uuid)
returns jsonb
language sql stable set search_path = public
as $$
  with plays as (
    -- Every scoring word I played in a terminal game (AI games included
    -- — skill stats count all games).
    select m.word, m.client_score, m.created_at,
           jsonb_array_length(coalesce(m.placements, '[]'::jsonb)) as tiles
    from moves m
    join game_players gp on gp.game_id = m.game_id and gp.seat = m.seat
    join games g on g.id = m.game_id
    where gp.user_id = p_user
      and g.status in ('finished','resigned','expired')
      and m.kind = 'play'
      and m.client_score is not null
  ),
  word_agg as (
    select round(avg(client_score)::numeric, 1) as lifetime_avg,
           round((avg(client_score) filter (
             where date_trunc('month', created_at) = date_trunc('month', now())
           ))::numeric, 1) as month_avg,
           (count(*) filter (where client_score >= 50))::int as w50,
           (count(*) filter (where client_score >= 40))::int as w40,
           (count(*) filter (where client_score >= 30))::int as w30,
           (count(*) filter (where tiles = 7))::int as bingos
    from plays
  ),
  monthly as (
    select coalesce(jsonb_agg(jsonb_build_object('month', mo, 'avg', mavg)
                              order by mo), '[]'::jsonb) as series
    from (
      select to_char(date_trunc('month', created_at), 'YYYY-MM') as mo,
             round(avg(client_score)::numeric, 1) as mavg
      from plays
      where created_at >= date_trunc('month', now()) - interval '3 months'
      group by 1
    ) months
  ),
  best_word as (
    -- Same tie-break as Phase 13's stats_for: score desc, then word.
    select word, client_score
    from plays
    where word is not null
    order by client_score desc nulls last, word
    limit 1
  ),
  last_bingo as (
    select word from plays
    where tiles = 7 and word is not null
    order by created_at desc
    limit 1
  ),
  games_agg as (
    -- Skill: best/average GAME over all terminal games (AI included) —
    -- pairs with best_word's opponent-agnostic framing. The human-only
    -- average remains fetch_stats' record number; this one feeds the
    -- profile's skill blocks.
    select coalesce(max(gp.score), 0)::int as best_game,
           coalesce(round(avg(gp.score))::int, 0) as avg_game
    from game_players gp
    join games g on g.id = gp.game_id
    where gp.user_id = p_user
      and g.status in ('finished','resigned','expired')
  ),
  human_results as (
    -- Win stats: HUMAN terminal games only, in end-time order. A
    -- 'departed' seat still counts as human (it was a human game) —
    -- same rule as Phase 13c's vs_human. Ties are not wins.
    select coalesce(g.winner_seat = gp.seat, false) as won,
           coalesce(g.finished_at, g.updated_at) as ended_at
    from game_players gp
    join games g on g.id = gp.game_id
    where gp.user_id = p_user
      and g.status in ('finished','resigned','expired')
      and exists (select 1 from game_players o
                  where o.game_id = g.id and o.seat <> gp.seat
                    and o.engine <> 'local_ai')
  ),
  runs as (
    -- Gaps-and-islands: consecutive same-result games share a group.
    select won,
           row_number() over (order by ended_at)
         - row_number() over (partition by won order by ended_at) as grp
    from human_results
  ),
  longest as (
    select coalesce(max(len), 0)::int as longest
    from (select count(*) as len from runs where won group by grp) s
  ),
  current_streak as (
    -- Wins since the last non-win; 0 if the latest human game wasn't a
    -- win. (max(ended_at) of non-wins; -infinity when unbeaten.)
    select count(*)::int as current
    from human_results
    where won
      and ended_at > coalesce((select max(ended_at)
                               from human_results where not won),
                              '-infinity'::timestamptz)
  ),
  wins_agg as (
    select (count(*) filter (where won))::int as wins
    from human_results
  )
  select jsonb_build_object(
    'avg_word', jsonb_build_object(
      'lifetime',   w.lifetime_avg,
      'this_month', w.month_avg,
      'monthly',    mo.series),
    'best_word', (select jsonb_build_object('word', word, 'score', client_score)
                  from best_word),
    'best_game', ga.best_game,
    'avg_game',  ga.avg_game,
    'wins',      wi.wins,
    'streaks', jsonb_build_object('longest', lo.longest, 'current', cu.current),
    'point_words', jsonb_build_object('w50', w.w50, 'w40', w.w40, 'w30', w.w30),
    'bingos', jsonb_build_object(
      'count', w.bingos,
      'last_word', (select word from last_bingo)))
  from word_agg w, monthly mo, games_agg ga, longest lo, current_streak cu, wins_agg wi;
$$;

-- The self-only RPC. No p_user parameter on purpose: this pass serves
-- the caller's own numbers, so there is nothing to gate. (Reading
-- OTHERS' stats stays behind fetch_stats + assert_stats_visible,
-- unchanged.) The friends-percentile pass is separate and later.
create or replace function public.fetch_profile_stats()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  return profile_stats_for(v_uid);
end;
$$;

-- Internal helper sealed from clients (same stance as stats_for);
-- fetch_profile_stats keeps default execute for signed-in users.
do $$
begin
  execute 'revoke execute on function public.profile_stats_for(uuid) from public, anon, authenticated';
end $$;
