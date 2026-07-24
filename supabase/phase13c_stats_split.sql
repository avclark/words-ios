-- Words — Phase 13c: split practice (AI) stats out of the record.
-- Run AFTER phase13b_stats_endings.sql. Idempotent.
--
-- PRODUCT DECISION: the top-level blended record was meaningless — it
-- mixed "how do I do against my friends" with "how do I do against a
-- difficulty level I chose." Restructure:
--   • HUMAN stats are the headline (record, win rate, avg score) — the
--     competitive identity; already what the leaderboard ranks on.
--   • AI games are PRACTICE: games + average score only. NO win/loss —
--     a W-L against an opponent whose strength you pick isn't a stat.
--   • Opponent-agnostic bests stay combined: best word and best game
--     count whoever you played. A great word is a great word.
-- The overall counters remain in the payload (verify scripts and the
-- practice-games derivation use them); the client simply no longer
-- headlines them.
--
-- Also decided (recorded in FEATURE-LIST): NO reset-stats feature, ever.
-- A resettable leaderboard is a meaningless leaderboard.
--
-- Only stats_for changes; fetch_stats/fetch_leaderboard/fetch_head_to_head
-- pass it through unchanged.

create or replace function public.stats_for(p_user uuid)
returns jsonb
language sql stable set search_path = public
as $$
  with mine as (
    select gp.seat, gp.score, g.winner_seat,
           exists (select 1 from game_players o
                   where o.game_id = g.id and o.seat <> gp.seat
                     and o.engine <> 'local_ai') as vs_human
    from game_players gp
    join games g on g.id = gp.game_id
    where gp.user_id = p_user
      and g.status in ('finished', 'resigned', 'expired')
  ),
  agg as (
    select count(*)::int as games,
           (count(*) filter (where winner_seat = seat))::int as wins,
           (count(*) filter (where winner_seat is not null
                               and winner_seat <> seat))::int as losses,
           (count(*) filter (where winner_seat is null))::int as ties,
           coalesce(round(avg(score))::int, 0) as avg_score,
           coalesce(max(score), 0)::int as best_game,
           (count(*) filter (where vs_human))::int as h_games,
           (count(*) filter (where vs_human and winner_seat = seat))::int as h_wins,
           (count(*) filter (where vs_human and winner_seat is not null
                               and winner_seat <> seat))::int as h_losses,
           (count(*) filter (where vs_human and winner_seat is null))::int as h_ties,
           coalesce(round(avg(score) filter (where vs_human))::int, 0) as h_avg,
           (count(*) filter (where not vs_human))::int as ai_games,
           coalesce(round(avg(score) filter (where not vs_human))::int, 0) as ai_avg
    from mine
  ),
  best_word as (
    select m.word, m.client_score
    from moves m
    join game_players gp on gp.game_id = m.game_id and gp.seat = m.seat
    join games g on g.id = m.game_id
    where gp.user_id = p_user
      and g.status in ('finished', 'resigned', 'expired')
      and m.kind = 'play' and m.word is not null
    order by m.client_score desc nulls last, m.word
    limit 1
  )
  select jsonb_build_object(
    'games', a.games, 'wins', a.wins, 'losses', a.losses, 'ties', a.ties,
    'avg_score', a.avg_score, 'best_game', a.best_game,
    'best_word', (select jsonb_build_object('word', word, 'score', client_score)
                  from best_word),
    'human', jsonb_build_object(
      'games', a.h_games, 'wins', a.h_wins, 'losses', a.h_losses,
      'ties', a.h_ties, 'avg_score', a.h_avg),
    -- Practice: deliberately no wins/losses/ties keys at all — the shape
    -- itself says "this is not a record."
    'ai', jsonb_build_object(
      'games', a.ai_games, 'avg_score', a.ai_avg))
  from agg a;
$$;

do $$
begin
  execute 'revoke execute on function public.stats_for(uuid) from public, anon, authenticated';
end $$;
