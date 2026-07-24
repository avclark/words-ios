-- Words — Phase 12: result acknowledgment, review data, rack history.
-- Run AFTER phase11f_chat_closure.sql (Dashboard → SQL Editor). Idempotent.
--
-- 1) RESULT ACKNOWLEDGMENT: a finished game stays in the lobby until its
--    result has been SEEN (the game-over screen viewed), then moves to
--    Past games. Same pattern as chat read markers: an acknowledgment,
--    not a timer. Per-seat (game_players.result_seen_at), synced so it
--    survives reinstall.
-- 2) RACK HISTORY for post-game review: move_private snapshots the
--    submitting seat's rack BEFORE each move. RLS with ZERO policies —
--    readable only through fetch_review, which requires the game to be
--    FINISHED and returns rack history for the CALLER'S seat only:
--    mid-game rack history is a cheat vector, and the opponent's racks
--    stay private even after the game. Moves earlier than this migration
--    have no rack rows; review skips those turns gracefully.

alter table public.game_players add column if not exists result_seen_at timestamptz;

create or replace function public.mark_result_seen(p_game_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  update game_players gp set result_seen_at = coalesce(gp.result_seen_at, now())
   from games g
   where g.id = p_game_id and gp.game_id = p_game_id
     and gp.user_id = auth.uid()
     and g.status <> 'active';
end;
$$;

-- ---------------------------------------------------------------------------
-- Rack history
-- ---------------------------------------------------------------------------

create table if not exists public.move_private (
  move_id     bigint primary key references public.moves (id) on delete cascade,
  rack_before jsonb not null
);

alter table public.move_private enable row level security;
-- No policies: fetch_review only.

-- submit_move: identical to the Phase 9 version plus the rack snapshot.
drop function if exists public.submit_move(uuid, smallint, text, jsonb, text, int, jsonb, uuid);

create or replace function public.submit_move(
  p_game_id      uuid,
  p_seat         smallint,
  p_kind         text,
  p_placements   jsonb default null,
  p_word         text default null,
  p_client_score int default null,
  p_swap_letters jsonb default null,
  p_op_id        uuid default null
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_uid         uuid := auth.uid();
  v_game        games%rowtype;
  v_player      game_players%rowtype;
  v_priv        game_private%rowtype;
  v_rack        jsonb;
  v_rack_before jsonb;
  v_board       jsonb;
  v_bag         jsonb;
  v_d           jsonb;
  v_drawn       jsonb := '[]'::jsonb;
  v_pl          jsonb;
  v_letters     jsonb;
  v_key         text;
  v_move_id     bigint;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  select * into v_game from games where id = p_game_id for update;
  if not found then raise exception 'game_not_found'; end if;
  if not is_game_participant(p_game_id) then raise exception 'not_participant'; end if;

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
  v_rack_before := v_rack;

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
            p_word, p_client_score, p_op_id)
    returning id into v_move_id;
  -- Rack snapshot for post-game review (finished games only, own seat
  -- only — see fetch_review).
  insert into move_private (move_id, rack_before)
    values (v_move_id, v_rack_before);

  return jsonb_build_object(
    'duplicate', false,
    'drawn', v_drawn,
    'bag_count', (select jsonb_array_length(bag) from game_private
                  where game_id = p_game_id),
    'turn_number', v_game.turn_number + 1);
end;
$$;

-- ---------------------------------------------------------------------------
-- fetch_review: everything needed to replay MY game after it's over.
-- ---------------------------------------------------------------------------

create or replace function public.fetch_review(p_game_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_seat smallint;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select seat into v_seat from game_players
   where game_id = p_game_id and user_id = v_uid;
  if v_seat is null then raise exception 'not_participant'; end if;
  if exists (select 1 from games where id = p_game_id and status = 'active') then
    raise exception 'game_still_active';  -- no mid-game rack history, ever
  end if;

  return jsonb_build_object(
    'my_seat', v_seat,
    'moves', coalesce((
      select jsonb_agg(jsonb_build_object(
        'move_number', m.move_number,
        'seat', m.seat,
        'kind', m.kind,
        'placements', m.placements,
        'word', m.word,
        'client_score', m.client_score,
        'rack_before', case when m.seat = v_seat then mp.rack_before end
      ) order by m.move_number)
      from moves m
      left join move_private mp on mp.move_id = m.id
      where m.game_id = p_game_id), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------
-- Lobby + game payloads carry the acknowledgment flag.
-- ---------------------------------------------------------------------------

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
    'unread_chat', unread_chat_count(g.id),
    'result_seen', (select gp.result_seen_at is not null from game_players gp
                    where gp.game_id = g.id and gp.user_id = (select auth.uid())),
    'players', (
      select jsonb_agg(jsonb_build_object(
        'seat', p.seat, 'user_id', p.user_id, 'engine', p.engine,
        'ai_difficulty', p.ai_difficulty, 'score', p.score,
        'display_name', pr.display_name, 'avatar', pr.avatar) order by p.seat)
      from game_players p
      left join profiles pr on pr.id = p.user_id
      where p.game_id = g.id)) order by g.updated_at desc), '[]'::jsonb)
  from games g
  where is_game_participant(g.id)
    and not exists (select 1 from game_players hp
                    where hp.game_id = g.id
                      and hp.user_id = (select auth.uid())
                      and hp.hidden_at is not null);
$$;

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
    'unread_chat', unread_chat_count(g.id),
    'result_seen', (select gp.result_seen_at is not null from game_players gp
                    where gp.game_id = g.id and gp.user_id = auth.uid()),
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

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

do $$
declare fn text;
begin
  foreach fn in array array[
    'mark_result_seen(uuid)',
    'submit_move(uuid, smallint, text, jsonb, text, int, jsonb, uuid)',
    'fetch_review(uuid)',
    'fetch_lobby()',
    'fetch_game(uuid)']
  loop
    execute format('revoke execute on function public.%s from public, anon', fn);
    execute format('grant execute on function public.%s to authenticated', fn);
  end loop;
end $$;
