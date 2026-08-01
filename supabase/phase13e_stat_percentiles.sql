-- Words — Phase 13e: friends-percentile badges (stats Pass B).
-- Run AFTER phase13d_profile_stats.sql. Idempotent.
--
-- Layers "Top N%" percentiles on top of Pass A's personal stats: how
-- the caller ranks AMONG THEIR FRIENDS for each stat with a meaningful
-- ordering. Pass A's computations (profile_stats_for) are UNTOUCHED —
-- fetch_profile_stats is recreated to merge in a 'percentiles' object
-- computed by the new helper.
--
-- POPULATION: the caller + their ACCEPTED friends — the exact set the
-- leaderboard uses (same friendships query). Block exclusion is
-- structural, same as everywhere else: blocking DELETES the friendship
-- (Phase 11), so a blocked pair can never appear in each other's
-- population. No new visibility rules invented.
--
-- RANKED STATS and their bases (the Pass A count rule, applied to every
-- member of the population identically):
--   • avg_word  — skill, ALL terminal games (AI included)
--   • best_word — skill, ALL terminal games
--   • best_game — skill, ALL terminal games
--   • bingos    — skill, ALL terminal games
--   • wins      — HUMAN terminal games only (AI wins never rank)
-- POINT-WORD BUCKETS ARE DELIBERATELY NOT RANKED: three more badges on
-- one card would be clutter, and the buckets are volume-correlated
-- shadows of avg_word/best_word — a percentile there is noise, not
-- signal. (Revisit if the design pass wants it.)
--
-- PERCENTILE DEFINITION: competition rank, ties share the BETTER rank.
--   N = ceil(100 * rank / population_ranked)   → "Top N%"
-- where rank = 1-based rank by value DESCENDING (rank(), so equal
-- values all take the minimum rank). Lower N is better; the sole best
-- of 5 people is Top 20%; four people tied for best of 5 are ALL
-- Top 20%.
--
-- NO-DATA EDGE (per stat):
--   • Averages/maxima (avg_word, best_word, best_game) EXCLUDE members
--     with no qualifying data — a person with zero plays has no
--     average, and inventing a 0 would fake a floor.
--   • Counts (wins, bingos) INCLUDE every member — 0 is a real count
--     (you genuinely out-win a friend who never finished a game).
--
-- LOW-FRIEND-COUNT SUPPRESSION: a percentile is returned ONLY when the
-- stat's ranked set has at least stat_percentile_floor() members (and
-- the caller is in that set). Below the floor the field is NULL and the
-- client shows the plain stat with no badge — never "Top 100%" noise.
-- The floor lives in ONE tunable function below (spirit of
-- Leaderboard.rankingFloor): 5 = you + ~4 friends.

-- THE tunable threshold — change the number here, nowhere else.
create or replace function public.stat_percentile_floor()
returns int
language sql immutable
as $$ select 5 $$;

create or replace function public.profile_percentiles_for(p_user uuid)
returns jsonb
language sql stable set search_path = public
as $$
  with population as (
    select p_user as id
    union
    select case when f.user_a = p_user then f.user_b else f.user_a end
    from friendships f
    where f.status = 'accepted' and p_user in (f.user_a, f.user_b)
  ),
  member_stats as (
    -- Each member's comparable values, computed with the same universe
    -- and count rule as Pass A (terminal games; skill = all games,
    -- wins = human games only). NULL avg/max = no qualifying data.
    select pop.id,
      (select avg(m.client_score)
         from moves m
         join game_players gp on gp.game_id = m.game_id and gp.seat = m.seat
         join games g on g.id = m.game_id
        where gp.user_id = pop.id
          and g.status in ('finished','resigned','expired')
          and m.kind = 'play' and m.client_score is not null) as avg_word,
      (select max(m.client_score)
         from moves m
         join game_players gp on gp.game_id = m.game_id and gp.seat = m.seat
         join games g on g.id = m.game_id
        where gp.user_id = pop.id
          and g.status in ('finished','resigned','expired')
          and m.kind = 'play' and m.client_score is not null) as best_word,
      (select max(gp.score)
         from game_players gp
         join games g on g.id = gp.game_id
        where gp.user_id = pop.id
          and g.status in ('finished','resigned','expired')) as best_game,
      (select count(*)::int
         from moves m
         join game_players gp on gp.game_id = m.game_id and gp.seat = m.seat
         join games g on g.id = m.game_id
        where gp.user_id = pop.id
          and g.status in ('finished','resigned','expired')
          and m.kind = 'play' and m.client_score is not null
          and jsonb_array_length(coalesce(m.placements, '[]'::jsonb)) = 7) as bingos,
      (select count(*)::int
         from game_players gp
         join games g on g.id = gp.game_id
        where gp.user_id = pop.id
          and g.status in ('finished','resigned','expired')
          and g.winner_seat = gp.seat
          and exists (select 1 from game_players o
                      where o.game_id = g.id and o.seat <> gp.seat
                        and o.engine <> 'local_ai')) as wins
    from population pop
  )
  select jsonb_build_object(
    'population', (select count(*) from member_stats),
    'avg_word',
      (select ceil(100.0 * r.rk / r.n)::int
         from (select id, rank() over (order by avg_word desc) as rk,
                      count(*) over () as n
                 from member_stats where avg_word is not null) r
        where r.id = p_user and r.n >= stat_percentile_floor()),
    'best_word',
      (select ceil(100.0 * r.rk / r.n)::int
         from (select id, rank() over (order by best_word desc) as rk,
                      count(*) over () as n
                 from member_stats where best_word is not null) r
        where r.id = p_user and r.n >= stat_percentile_floor()),
    'best_game',
      (select ceil(100.0 * r.rk / r.n)::int
         from (select id, rank() over (order by best_game desc) as rk,
                      count(*) over () as n
                 from member_stats where best_game is not null) r
        where r.id = p_user and r.n >= stat_percentile_floor()),
    'wins',
      (select ceil(100.0 * r.rk / r.n)::int
         from (select id, rank() over (order by wins desc) as rk,
                      count(*) over () as n
                 from member_stats) r
        where r.id = p_user and r.n >= stat_percentile_floor()),
    'bingos',
      (select ceil(100.0 * r.rk / r.n)::int
         from (select id, rank() over (order by bingos desc) as rk,
                      count(*) over () as n
                 from member_stats) r
        where r.id = p_user and r.n >= stat_percentile_floor()));
$$;

-- Recreate the Pass A RPC to carry the comparison layer. Still
-- self-only; Pass A's payload is byte-identical, plus 'percentiles'.
create or replace function public.fetch_profile_stats()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  return profile_stats_for(v_uid)
      || jsonb_build_object('percentiles', profile_percentiles_for(v_uid));
end;
$$;

-- Internal helper sealed from clients (same stance as stats_for /
-- profile_stats_for).
do $$
begin
  execute 'revoke execute on function public.profile_percentiles_for(uuid) from public, anon, authenticated';
end $$;
