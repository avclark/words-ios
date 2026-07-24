-- Words — Phase 13b: stats must count EVERY terminal state, not just
-- status = 'finished'. Run AFTER phase13_stats.sql. Idempotent.
--
-- BUG (caught by verify_phase13 step 1): a game A won by B's resignation
-- counted for nothing — stats_for and fetch_head_to_head filtered on
-- status = 'finished', but games reach the end down four paths and only
-- one of them lands there. The games.status CHECK constraint is the
-- authority: ('active','finished','resigned','expired'). Terminal set,
-- enumerated explicitly (a hypothetical future status must be CLASSIFIED,
-- not silently swept in by a '<> active' filter):
--
--   'finished'  — finish_game: normal play-out (end_reason 'emptied')
--                 and six-pass endings ('six_passes'); winner_seat from
--                 the endgame math, null = tie.
--   'resigned'  — resign_game, block-resign (phase11), and the
--                 departed-opponent forfeit (phase8b account deletion);
--                 winner_seat = the non-resigning / surviving seat.
--   'expired'   — phase9 expiry job; winner_seat = the seat NOT on turn
--                 (the inactive player forfeits).
--
-- Attribution was never the bug — every terminal path already sets
-- winner_seat correctly — inclusion was. fetch_leaderboard shares
-- stats_for, so recreating these two functions fixes all three surfaces.
-- (Phase 12's fetch_review gates on status <> 'active' and was correct.)

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
           coalesce(round(avg(score) filter (where vs_human))::int, 0) as h_avg
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
      'ties', a.h_ties, 'avg_score', a.h_avg))
  from agg a;
$$;

create or replace function public.fetch_head_to_head(p_user uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if p_user = v_uid then raise exception 'self'; end if;
  perform assert_stats_visible(v_uid, p_user);
  return (
    with shared as (
      select g.winner_seat, me.seat as my_seat,
             me.score as my_score, them.score as their_score,
             g.updated_at
      from games g
      join game_players me on me.game_id = g.id and me.user_id = v_uid
      join game_players them on them.game_id = g.id and them.user_id = p_user
      where g.status in ('finished', 'resigned', 'expired')
    )
    select jsonb_build_object(
      'games', count(*)::int,
      'my_wins', (count(*) filter (where winner_seat = my_seat))::int,
      'their_wins', (count(*) filter (where winner_seat is not null
                                        and winner_seat <> my_seat))::int,
      'ties', (count(*) filter (where winner_seat is null))::int,
      'my_avg', coalesce(round(avg(my_score))::int, 0),
      'their_avg', coalesce(round(avg(their_score))::int, 0),
      'last_played', max(updated_at))
    from shared);
end;
$$;

-- Re-assert grants (create or replace preserves them, but explicit
-- beats implicit after a recreate).
do $$
declare fn text;
begin
  execute 'revoke execute on function public.fetch_head_to_head(uuid) from public, anon';
  execute 'grant execute on function public.fetch_head_to_head(uuid) to authenticated';
  execute 'revoke execute on function public.stats_for(uuid) from public, anon, authenticated';
end $$;
