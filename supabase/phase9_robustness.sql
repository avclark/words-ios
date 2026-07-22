-- Words — Phase 9: multiplayer robustness.
-- Run AFTER phase8b_account_deletion.sql (Dashboard → SQL Editor). Idempotent.
--
-- CONTENTS
-- • Idempotent move submission: moves.client_op_id + dedupe in submit_move,
--   so a client replaying a persisted op queue after force-quit can never
--   double-apply a move; a duplicate returns the seat's current rack so the
--   client can reconcile a refill it never received.
-- • Game expiry, warn-then-expire (FEATURE-LIST: never silent):
--   INACTIVITY WINDOW = 14 days, WARNING = 24h before the end. Rationale:
--   this is a friends-and-family game — expiry exists to garbage-collect
--   genuinely abandoned games, not to pressure play (Scrabble GO's 7 days
--   is churn pressure). Human-vs-human games only; a solo game against the
--   AI never expires. Phase 10's push notification hooks into
--   expiry_warned_at being set by process_game_expiry — no rework needed.
-- • Rematch: request_rematch creates (or joins) THE one rematch game —
--   a unique index on rematch_of plus row locking makes the both-players-
--   tap-at-once race produce a single game.

-- ---------------------------------------------------------------------------
-- Idempotent submissions
-- ---------------------------------------------------------------------------

alter table public.moves add column if not exists client_op_id uuid;
create unique index if not exists moves_client_op_unique
  on public.moves (game_id, client_op_id) where client_op_id is not null;

-- 14-day inactivity window for new games.
alter table public.games alter column expires_at
  set default now() + interval '14 days';

drop function if exists public.submit_move(uuid, smallint, text, jsonb, text, int, jsonb);

create or replace function public.submit_move(
  p_game_id      uuid,
  p_seat         smallint,
  p_kind         text,
  p_placements   jsonb default null,
  p_word         text default null,
  p_client_score int default null,
  p_swap_letters jsonb default null,
  p_op_id        uuid default null      -- client-generated idempotency key
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_game    games%rowtype;
  v_player  game_players%rowtype;
  v_priv    game_private%rowtype;
  v_rack    jsonb;
  v_board   jsonb;
  v_bag     jsonb;
  v_d       jsonb;
  v_drawn   jsonb := '[]'::jsonb;
  v_pl      jsonb;
  v_letters jsonb;
  v_key     text;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  select * into v_game from games where id = p_game_id for update;
  if not found then raise exception 'game_not_found'; end if;
  if not is_game_participant(p_game_id) then raise exception 'not_participant'; end if;

  -- Replay of an op the server already applied (client force-quit before
  -- learning the result): report success again, with the seat's CURRENT
  -- rack so the client can reconcile the refill it never received.
  if p_op_id is not null and exists (
      select 1 from moves
      where game_id = p_game_id and client_op_id = p_op_id) then
    return jsonb_build_object(
      'duplicate', true,
      'drawn', '[]'::jsonb,
      'rack', (select racks -> p_seat::text from game_private
               where game_id = p_game_id),
      'bag_count', (select jsonb_array_length(bag) from game_private
                    where game_id = p_game_id),
      'turn_number', v_game.turn_number);
  end if;

  if v_game.status <> 'active' then raise exception 'game_not_active'; end if;
  if v_game.turn_seat <> p_seat then raise exception 'not_your_turn'; end if;

  select * into v_player from game_players
  where game_id = p_game_id and seat = p_seat;
  if v_player.engine = 'human' and v_player.user_id <> v_uid then
    raise exception 'not_your_seat';
  end if;

  select * into v_priv from game_private where game_id = p_game_id;
  v_rack := v_priv.racks -> p_seat::text;

  if p_kind = 'play' then
    if p_placements is null or jsonb_array_length(p_placements) = 0 then
      raise exception 'empty_move';
    end if;
    if jsonb_array_length(p_placements) > 7 then
      raise exception 'too_many_tiles';
    end if;

    v_board := v_game.board;
    for v_pl in select value from jsonb_array_elements(p_placements) loop
      if (v_pl->>'row')::int not between 0 and 14
         or (v_pl->>'col')::int not between 0 and 14 then
        raise exception 'out_of_bounds';
      end if;
      v_key := (v_pl->>'row') || '-' || (v_pl->>'col');
      if v_board ? v_key then raise exception 'cell_occupied'; end if;
      v_board := v_board || jsonb_build_object(v_key, jsonb_build_object(
        'letter', v_pl->>'letter',
        'blank',  coalesce((v_pl->>'blank')::boolean, false)));
    end loop;

    select coalesce(jsonb_agg(
             case when coalesce((e->>'blank')::boolean, false)
                  then '?' else e->>'letter' end), '[]'::jsonb)
      into v_letters from jsonb_array_elements(p_placements) e;
    v_rack := rack_remove(v_rack, v_letters);

    v_d := bag_draw(v_priv.bag,
                    least(jsonb_array_length(p_placements),
                          jsonb_array_length(v_priv.bag)));
    v_drawn := v_d->'drawn';

    update game_private
      set bag = v_d->'rest',
          racks = jsonb_set(racks, array[p_seat::text], v_rack || v_drawn)
      where game_id = p_game_id;
    update game_players set score = score + coalesce(p_client_score, 0)
      where game_id = p_game_id and seat = p_seat;
    update games
      set board = v_board,
          turn_seat = 1 - p_seat,
          turn_number = turn_number + 1,
          consecutive_passes = 0,
          updated_at = now(),
          expires_at = now() + interval '14 days',
          expiry_warned_at = null
      where id = p_game_id;

  elsif p_kind = 'pass' then
    update games
      set turn_seat = 1 - p_seat,
          turn_number = turn_number + 1,
          consecutive_passes = consecutive_passes + 1,
          updated_at = now(),
          expires_at = now() + interval '14 days',
          expiry_warned_at = null
      where id = p_game_id;

  elsif p_kind = 'swap' then
    if p_swap_letters is null or jsonb_array_length(p_swap_letters) = 0 then
      raise exception 'empty_swap';
    end if;
    if jsonb_array_length(p_swap_letters) > jsonb_array_length(v_priv.bag) then
      raise exception 'bag_too_small';
    end if;
    v_rack := rack_remove(v_rack, p_swap_letters);
    select coalesce(jsonb_agg(value order by random()), '[]'::jsonb) into v_bag
      from jsonb_array_elements(v_priv.bag || p_swap_letters);
    v_d := bag_draw(v_bag, jsonb_array_length(p_swap_letters));
    v_drawn := v_d->'drawn';
    update game_private
      set bag = v_d->'rest',
          racks = jsonb_set(racks, array[p_seat::text], v_rack || v_drawn)
      where game_id = p_game_id;
    update games
      set turn_seat = 1 - p_seat,
          turn_number = turn_number + 1,
          consecutive_passes = 0,
          updated_at = now(),
          expires_at = now() + interval '14 days',
          expiry_warned_at = null
      where id = p_game_id;

  else
    raise exception 'bad_kind';
  end if;

  insert into moves (game_id, seat, move_number, kind, placements, word,
                     client_score, client_op_id)
    values (p_game_id, p_seat, v_game.turn_number, p_kind, p_placements,
            p_word, p_client_score, p_op_id);

  return jsonb_build_object(
    'duplicate', false,
    'drawn', v_drawn,
    'bag_count', (select jsonb_array_length(bag) from game_private
                  where game_id = p_game_id),
    'turn_number', v_game.turn_number + 1);
end;
$$;

-- ---------------------------------------------------------------------------
-- Expiry: warn, then — and only then — expire. Runs hourly via pg_cron.
-- Phase 10 hook: expiry_warned_at transitioning from null is the "send the
-- warning push" signal; status flipping to 'expired' is the "game over"
-- signal. Human-vs-human games only.
-- ---------------------------------------------------------------------------

create or replace function public.process_game_expiry()
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_warned  int;
  v_expired int;
begin
  -- Warn the game when less than 24h remains (once).
  with warned as (
    update games g
       set expiry_warned_at = now(), updated_at = now()
     where g.status = 'active'
       and g.expiry_warned_at is null
       and g.expires_at < now() + interval '24 hours'
       and 2 = (select count(*) from game_players p
                where p.game_id = g.id and p.engine = 'human')
    returning g.id)
  select count(*) into v_warned from warned;

  -- Expire only games that were warned a full day ago — even a game found
  -- already past its deadline gets its 24h warning window first.
  with expired as (
    update games g
       set status = 'expired',
           end_reason = 'expired',
           winner_seat = 1 - g.turn_seat,   -- the inactive player forfeits
           finished_at = now(),
           updated_at = now()
     where g.status = 'active'
       and g.expires_at < now()
       and g.expiry_warned_at is not null
       and g.expiry_warned_at < now() - interval '24 hours'
       and 2 = (select count(*) from game_players p
                where p.game_id = g.id and p.engine = 'human')
    returning g.id)
  select count(*) into v_expired from expired;

  return jsonb_build_object('warned', v_warned, 'expired', v_expired);
end;
$$;

-- Schedule hourly. Guarded so the file still applies where pg_cron is
-- unavailable — then run process_game_expiry from an external scheduler.
do $$
begin
  create extension if not exists pg_cron;
  begin
    perform cron.unschedule('words-game-expiry');
  exception when others then null;
  end;
  perform cron.schedule('words-game-expiry', '23 * * * *',
                        'select public.process_game_expiry()');
exception when others then
  raise notice 'pg_cron unavailable (%) — schedule process_game_expiry externally', sqlerrm;
end $$;

-- ---------------------------------------------------------------------------
-- Rematch: one tap from game over; both players tapping yields ONE game.
-- ---------------------------------------------------------------------------

create unique index if not exists games_rematch_unique
  on public.games (rematch_of) where rematch_of is not null;

create or replace function public.request_rematch(p_game_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_game     games%rowtype;
  v_opponent uuid;
  v_new_id   uuid;
  v_my_seat  smallint;
  v_bag      jsonb;
  v_d        jsonb;
  v_rack0    jsonb;
  v_rack1    jsonb;
  v_created  boolean := false;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  -- Lock the finished game row: concurrent rematch taps serialize here.
  select * into v_game from games where id = p_game_id for update;
  if not found then raise exception 'game_not_found'; end if;
  if v_game.status = 'active' then raise exception 'game_still_active'; end if;
  if not exists (select 1 from game_players
                 where game_id = p_game_id and user_id = v_uid) then
    raise exception 'not_participant';
  end if;
  select user_id into v_opponent from game_players
   where game_id = p_game_id and engine = 'human' and user_id <> v_uid;
  if v_opponent is null then raise exception 'no_human_opponent'; end if;

  select id into v_new_id from games where rematch_of = p_game_id;
  if v_new_id is null then
    v_created := true;
    v_bag := game_new_bag();
    v_d := bag_draw(v_bag, 7);  v_rack0 := v_d->'drawn';  v_bag := v_d->'rest';
    v_d := bag_draw(v_bag, 7);  v_rack1 := v_d->'drawn';  v_bag := v_d->'rest';
    insert into games (rematch_of) values (p_game_id) returning id into v_new_id;
    insert into game_players (game_id, seat, user_id, engine) values
      (v_new_id, 0, v_uid, 'human'),
      (v_new_id, 1, v_opponent, 'human');
    insert into game_private (game_id, bag, racks)
      values (v_new_id, v_bag, jsonb_build_object('0', v_rack0, '1', v_rack1));
  end if;

  select seat into v_my_seat from game_players
   where game_id = v_new_id and user_id = v_uid;

  return jsonb_build_object(
    'game_id', v_new_id,
    'created', v_created,
    'my_seat', v_my_seat,
    'my_rack', (select racks -> v_my_seat::text from game_private
                where game_id = v_new_id),
    'bag_count', (select jsonb_array_length(bag) from game_private
                  where game_id = v_new_id),
    'opponent', (select jsonb_build_object(
                   'user_id', pr.id,
                   'display_name', pr.display_name,
                   'avatar', pr.avatar)
                 from profiles pr where pr.id = v_opponent));
end;
$$;

-- ---------------------------------------------------------------------------
-- fetch_game / fetch_lobby now expose the expiry deadline.
-- ---------------------------------------------------------------------------

create or replace function public.fetch_game(p_game_id uuid)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'game_id', g.id,
    'status', g.status,
    'board', g.board,
    'turn_seat', g.turn_seat,
    'turn_number', g.turn_number,
    'consecutive_passes', g.consecutive_passes,
    'end_reason', g.end_reason,
    'winner_seat', g.winner_seat,
    'created_at', g.created_at,
    'updated_at', g.updated_at,
    'expires_at', g.expires_at,
    'expiry_warned_at', g.expiry_warned_at,
    'bag_count', (select jsonb_array_length(bag) from game_private
                  where game_id = g.id),
    'import_log', g.import_log,
    'players', (
      select jsonb_agg(jsonb_build_object(
        'seat', p.seat,
        'user_id', p.user_id,
        'engine', p.engine,
        'ai_difficulty', p.ai_difficulty,
        'score', p.score,
        'display_name', pr.display_name,
        'avatar', pr.avatar,
        'rack', case when p.user_id = auth.uid() or p.engine = 'local_ai'
                     then (select racks -> p.seat::text from game_private
                           where game_id = g.id) end
      ) order by p.seat)
      from game_players p
      left join profiles pr on pr.id = p.user_id
      where p.game_id = g.id),
    'moves', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'seat', m.seat, 'move_number', m.move_number, 'kind', m.kind,
        'word', m.word, 'client_score', m.client_score) order by m.move_number),
        '[]'::jsonb)
      from moves m where m.game_id = g.id))
  from games g
  where g.id = p_game_id and is_game_participant(g.id);
$$;

create or replace function public.fetch_lobby()
returns jsonb
language sql stable security definer set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'game_id', g.id,
    'status', g.status,
    'turn_seat', g.turn_seat,
    'end_reason', g.end_reason,
    'winner_seat', g.winner_seat,
    'updated_at', g.updated_at,
    'expires_at', g.expires_at,
    'players', (
      select jsonb_agg(jsonb_build_object(
        'seat', p.seat, 'user_id', p.user_id, 'engine', p.engine,
        'ai_difficulty', p.ai_difficulty, 'score', p.score,
        'display_name', pr.display_name, 'avatar', pr.avatar) order by p.seat)
      from game_players p
      left join profiles pr on pr.id = p.user_id
      where p.game_id = g.id)) order by g.updated_at desc), '[]'::jsonb)
  from games g
  where is_game_participant(g.id);
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

do $$
declare fn text;
begin
  foreach fn in array array[
    'submit_move(uuid, smallint, text, jsonb, text, int, jsonb, uuid)',
    'request_rematch(uuid)',
    'fetch_game(uuid)',
    'fetch_lobby()']
  loop
    execute format('revoke execute on function public.%s from public, anon', fn);
    execute format('grant execute on function public.%s to authenticated', fn);
  end loop;
  -- The expiry job runs under cron (superuser) or an external scheduler
  -- with the secret key; clients can't invoke it.
  execute 'revoke execute on function public.process_game_expiry() from public, anon, authenticated';
  execute 'grant execute on function public.process_game_expiry() to service_role';
end $$;
