-- Words — Phase 13: profile stats, friends-only leaderboard, head-to-head.
-- Run AFTER phase12_review.sql (Dashboard → SQL Editor). Idempotent.
--
-- DESIGN: stats are COMPUTED ON DEMAND — no stats table, no incremental
-- maintenance. At this app's scale the aggregate is trivial, and on-demand
-- means: no drift, no backfill for already-finished games, and no
-- "every game-end writer must also update stats" sweep (the bug class
-- that let request_rematch bypass blocks). Archived (result_seen) and
-- per-seat hidden (hidden_at) games count naturally: the aggregation
-- never looks at either column.
--
-- PRIVACY: there is no new table, so there are no new rows for policies
-- to guard — the underlying tables keep their existing participant-only
-- RLS, and these SECURITY DEFINER RPCs are the ONLY cross-user read
-- path. The gate: self always; otherwise accepted friendship required,
-- with an explicit both-directions block check on top (blocking already
-- severs friendship — this is defense in depth). Stranger and blocked
-- get the SAME 'not_friends' error, so a refusal never leaks block
-- state. stats_for() itself is internal: EXECUTE is revoked from
-- clients; only the definer RPCs call it.
--
-- SEMANTICS:
--   finished games only (status = 'finished'); active games count nowhere.
--   win  = winner_seat = my seat;  loss = winner_seat = other seat;
--   tie  = winner_seat null.  Resign/expiry already set winner_seat.
--   'human' subset = games whose OTHER seat is not local_ai ('departed'
--   counts as human — it was a human game when it was played).
--   best word = my highest-scoring play across finished games
--   (client_score — client-computed, same number game history shows).

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
    where gp.user_id = p_user and g.status = 'finished'
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
    where gp.user_id = p_user and g.status = 'finished'
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

-- Shared relationship gate: self always passes; otherwise accepted
-- friendship AND no block in either direction. One error for both
-- stranger and blocked — no block-state leak.
create or replace function public.assert_stats_visible(p_viewer uuid, p_target uuid)
returns void
language plpgsql stable set search_path = public
as $$
begin
  if p_viewer is null then raise exception 'not_authenticated'; end if;
  if p_viewer = p_target then return; end if;
  if exists (select 1 from blocks
             where (blocker = p_viewer and blocked = p_target)
                or (blocker = p_target and blocked = p_viewer)) then
    raise exception 'not_friends';
  end if;
  if not exists (select 1 from friendships
                 where user_a = least(p_viewer, p_target)
                   and user_b = greatest(p_viewer, p_target)
                   and status = 'accepted') then
    raise exception 'not_friends';
  end if;
end;
$$;

-- Own stats (p_user null/omitted) or a friend's.
create or replace function public.fetch_stats(p_user uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_target uuid := coalesce(p_user, auth.uid());
begin
  perform assert_stats_visible(v_uid, v_target);
  return stats_for(v_target);
end;
$$;

-- Me + my accepted friends, one row each, with per-user stats. Ranking
-- (win rate over human games with a minimum-games floor) happens
-- client-side — the metric is presentation, the data is not.
create or replace function public.fetch_leaderboard()
returns jsonb
language sql stable security definer set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id', u.id,
    'display_name', pr.display_name,
    'avatar', pr.avatar,
    'username', pr.username,
    'me', u.id = (select auth.uid()),
    'stats', stats_for(u.id))), '[]'::jsonb)
  from (
    select (select auth.uid()) as id
    union
    select case when f.user_a = (select auth.uid()) then f.user_b
                else f.user_a end
    from friendships f
    where f.status = 'accepted'
      and (select auth.uid()) in (f.user_a, f.user_b)
  ) u
  join profiles pr on pr.id = u.id;
$$;

-- Our record against each other: finished games where BOTH of us hold
-- seats. Friends only (same gate as fetch_stats).
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
      where g.status = 'finished'
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

-- ---------------------------------------------------------------------------
-- Grants: the three RPCs for signed-in clients; the internals for no one.
-- ---------------------------------------------------------------------------

do $$
declare fn text;
begin
  foreach fn in array array[
    'fetch_stats(uuid)',
    'fetch_leaderboard()',
    'fetch_head_to_head(uuid)']
  loop
    execute format('revoke execute on function public.%s from public, anon', fn);
    execute format('grant execute on function public.%s to authenticated', fn);
  end loop;
  -- Internal helpers: callable only from the definer RPCs above.
  foreach fn in array array[
    'stats_for(uuid)',
    'assert_stats_visible(uuid, uuid)']
  loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', fn);
  end loop;
end $$;
