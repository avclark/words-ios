-- Words — Phase 7 schema: server-backed games.
-- Run AFTER setup.sql (Dashboard → SQL Editor). Idempotent; safe to re-run.
--
-- DESIGN
-- • All reads and writes go through SECURITY DEFINER RPCs. Base tables have
--   read-only RLS for participants; game_private (bag + racks) has RLS
--   enabled with NO policies at all — clients cannot read it, period.
--   A player sees their own rack (and an AI seat's rack — see below) only
--   through fetch_game/create_game responses.
-- • Moves are INTENT: submit_move receives tile placements, never a scored
--   result. The server checks what is cheap and high-value today (turn,
--   tiles really in the rack, cells actually empty, bounds) and records the
--   client's score as UNTRUSTED (client_score). Full server-side validation
--   and scoring can replace the internals later with zero API change.
-- • Seats are generic: game_players.engine says who controls a seat —
--   'human' (user_id) or 'local_ai' (client-driven engine, ai_difficulty).
--   A remote human is just another 'human' seat; nothing else changes.
--   Until a server-side AI exists, the human participant submits moves for
--   an AI seat, and may read that seat's rack (the documented exception to
--   rack privacy — the engine runs on the client and needs its tiles).
-- • Account deletion: profiles → game_players cascade; a trigger then
--   deletes any game left with no human seat (for AI games: all of them).
--   Games, moves, private state, and chat all cascade away.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table if not exists public.games (
  id                  uuid primary key default gen_random_uuid(),
  status              text not null default 'active'
                      check (status in ('active','finished','resigned','expired')),
  -- Committed tiles only, keyed "row-col" → {letter, blank}. For blanks,
  -- letter is the assigned display letter and blank = true.
  board               jsonb not null default '{}'::jsonb,
  turn_seat           smallint not null default 0,
  turn_number         int not null default 1,
  consecutive_passes  int not null default 0,
  end_reason          text check (end_reason in ('emptied','six_passes','resigned','expired')),
  winner_seat         smallint,
  -- One-tap rematch (Phase 9) links the new game back to the old.
  rematch_of          uuid references public.games (id) on delete set null,
  -- Human-readable log carried over from a pre-Phase-7 local game.
  import_log          jsonb,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  finished_at         timestamptz,
  -- Warn-then-expire flow (Phase 9/10): reset on every move; a job will
  -- warn before expires_at and only expire after the warning. Fields only
  -- for now — nothing enforces expiry yet.
  expires_at          timestamptz not null default now() + interval '7 days',
  expiry_warned_at    timestamptz
);

create table if not exists public.game_players (
  game_id       uuid not null references public.games (id) on delete cascade,
  seat          smallint not null check (seat in (0, 1)),
  user_id       uuid references public.profiles (id) on delete cascade,
  engine        text not null default 'human' check (engine in ('human','local_ai')),
  ai_difficulty text check (ai_difficulty in ('easy','medium','hard')),
  score         int not null default 0,
  primary key (game_id, seat),
  check ((engine = 'human') = (user_id is not null)),
  check (engine <> 'local_ai' or ai_difficulty is not null)
);

-- Secrets. RLS on, zero policies: only definer functions can touch this.
create table if not exists public.game_private (
  game_id uuid primary key references public.games (id) on delete cascade,
  bag     jsonb not null,  -- ordered array of letters ("?" = blank)
  racks   jsonb not null   -- {"0": [letters], "1": [letters]}
);

create table if not exists public.moves (
  id           bigint generated always as identity primary key,
  game_id      uuid not null references public.games (id) on delete cascade,
  seat         smallint not null,
  move_number  int not null,
  kind         text not null check (kind in ('play','pass','swap','resign')),
  -- The INTENT: [{row, col, letter, blank}]. letter is the display letter
  -- (for blanks: the assigned letter, blank = true). Authoritative.
  placements   jsonb,
  word         text,
  -- Client-computed score. Recorded for display/history but NOT trusted;
  -- server-side scoring will supersede it without changing this API.
  client_score int,
  created_at   timestamptz not null default now(),
  unique (game_id, move_number)
);

-- Phase 8 (friends & invites) will extend this — minimal shape now so the
-- game schema has something real to reference. Invite links get their own
-- table in Phase 8.
create table if not exists public.friendships (
  user_a       uuid not null references public.profiles (id) on delete cascade,
  user_b       uuid not null references public.profiles (id) on delete cascade,
  status       text not null default 'pending' check (status in ('pending','accepted')),
  requested_by uuid not null,
  created_at   timestamptz not null default now(),
  primary key (user_a, user_b),
  check (user_a < user_b)
);

-- Phase 11 (chat) will extend this — minimal shape now.
create table if not exists public.chat_messages (
  id         bigint generated always as identity primary key,
  game_id    uuid not null references public.games (id) on delete cascade,
  sender     uuid not null references public.profiles (id) on delete cascade,
  body       text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------

alter table public.games         enable row level security;
alter table public.game_players  enable row level security;
alter table public.game_private  enable row level security;  -- no policies: locked
alter table public.moves         enable row level security;
alter table public.friendships   enable row level security;
alter table public.chat_messages enable row level security;

-- Definer so policies on game_players can use it without recursing.
create or replace function public.is_game_participant(p_game_id uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from game_players
    where game_id = p_game_id and user_id = auth.uid()
  );
$$;

drop policy if exists games_select_participant on public.games;
create policy games_select_participant on public.games
  for select to authenticated using (public.is_game_participant(id));

drop policy if exists game_players_select_participant on public.game_players;
create policy game_players_select_participant on public.game_players
  for select to authenticated using (public.is_game_participant(game_id));

drop policy if exists moves_select_participant on public.moves;
create policy moves_select_participant on public.moves
  for select to authenticated using (public.is_game_participant(game_id));

-- No insert/update/delete policies anywhere: writes go through RPCs only.

drop policy if exists friendships_select_own on public.friendships;
create policy friendships_select_own on public.friendships
  for select to authenticated
  using (user_a = (select auth.uid()) or user_b = (select auth.uid()));

drop policy if exists chat_select_participant on public.chat_messages;
create policy chat_select_participant on public.chat_messages
  for select to authenticated using (public.is_game_participant(game_id));

drop policy if exists chat_insert_participant on public.chat_messages;
create policy chat_insert_participant on public.chat_messages
  for insert to authenticated
  with check (sender = (select auth.uid()) and public.is_game_participant(game_id));

-- ---------------------------------------------------------------------------
-- Internal helpers (not callable by clients)
-- ---------------------------------------------------------------------------

-- Standard 100-tile bag, shuffled.
create or replace function public.game_new_bag()
returns jsonb
language sql volatile
as $$
  with dist(letter, n) as (values
    ('A',9),('B',2),('C',2),('D',4),('E',12),('F',2),('G',3),('H',2),('I',9),
    ('J',1),('K',1),('L',4),('M',2),('N',6),('O',8),('P',2),('Q',1),('R',6),
    ('S',4),('T',6),('U',4),('V',2),('W',2),('X',1),('Y',2),('Z',1),('?',2))
  select coalesce(jsonb_agg(to_jsonb(letter) order by random()), '[]'::jsonb)
  from dist cross join lateral generate_series(1, n)
$$;

-- First n tiles off the top: {drawn: [...], rest: [...]}.
create or replace function public.bag_draw(p_bag jsonb, p_n int)
returns jsonb
language sql immutable
as $$
  select jsonb_build_object(
    'drawn', coalesce((select jsonb_agg(value order by i)
                       from jsonb_array_elements(p_bag) with ordinality t(value, i)
                       where i <= p_n), '[]'::jsonb),
    'rest',  coalesce((select jsonb_agg(value order by i)
                       from jsonb_array_elements(p_bag) with ordinality t(value, i)
                       where i > p_n), '[]'::jsonb));
$$;

-- Remove one occurrence of each letter from a rack; raises if any is missing.
-- This is the "tiles claimed were really in their rack" check — the server
-- dealt the rack, so it knows.
create or replace function public.rack_remove(p_rack jsonb, p_letters jsonb)
returns jsonb
language plpgsql immutable
as $$
declare
  r   text[];
  l   text;
  idx int;
begin
  select coalesce(array_agg(value), '{}') into r
  from jsonb_array_elements_text(p_rack) value;
  for l in select value from jsonb_array_elements_text(p_letters) loop
    idx := array_position(r, l);
    if idx is null then
      raise exception 'tiles_not_in_rack';
    end if;
    r := r[1:idx-1] || r[idx+1:];
  end loop;
  return coalesce(to_jsonb(r), '[]'::jsonb);
end;
$$;

-- After a human's game_players row cascades away, remove games that no
-- longer have any human seat (an AI seat alone is not a game).
create or replace function public.cleanup_orphan_games()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  delete from games g
  where g.id = old.game_id
    and not exists (select 1 from game_players p
                    where p.game_id = g.id and p.engine = 'human');
  return old;
end;
$$;

drop trigger if exists game_players_cleanup on public.game_players;
create trigger game_players_cleanup
  after delete on public.game_players
  for each row execute function public.cleanup_orphan_games();

-- ---------------------------------------------------------------------------
-- RPC: create_game — server builds the bag and deals both racks.
-- Phase 7: the opponent is always the AI; Phase 8/9 add a p_opponent
-- parameter for human seats (additive change).
-- ---------------------------------------------------------------------------

create or replace function public.create_game(p_ai_difficulty text default 'hard')
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_game_id uuid;
  v_bag     jsonb;
  v_d       jsonb;
  v_rack0   jsonb;
  v_rack1   jsonb;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if p_ai_difficulty not in ('easy','medium','hard') then
    raise exception 'bad_difficulty';
  end if;

  v_bag := game_new_bag();
  v_d := bag_draw(v_bag, 7);  v_rack0 := v_d->'drawn';  v_bag := v_d->'rest';
  v_d := bag_draw(v_bag, 7);  v_rack1 := v_d->'drawn';  v_bag := v_d->'rest';

  insert into games default values returning id into v_game_id;
  insert into game_players (game_id, seat, user_id, engine, ai_difficulty) values
    (v_game_id, 0, v_uid, 'human', null),
    (v_game_id, 1, null, 'local_ai', p_ai_difficulty);
  insert into game_private (game_id, bag, racks)
    values (v_game_id, v_bag, jsonb_build_object('0', v_rack0, '1', v_rack1));

  return jsonb_build_object(
    'game_id', v_game_id,
    'my_rack', v_rack0,
    'ai_rack', v_rack1,
    'bag_count', jsonb_array_length(v_bag));
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: submit_move — the intent API.
-- ---------------------------------------------------------------------------

create or replace function public.submit_move(
  p_game_id      uuid,
  p_seat         smallint,
  p_kind         text,                  -- 'play' | 'pass' | 'swap'
  p_placements   jsonb default null,    -- for 'play': [{row,col,letter,blank}]
  p_word         text default null,
  p_client_score int default null,
  p_swap_letters jsonb default null     -- for 'swap': rack letters ("?" = blank)
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
  if v_game.status <> 'active' then raise exception 'game_not_active'; end if;
  if v_game.turn_seat <> p_seat then raise exception 'not_your_turn'; end if;

  select * into v_player from game_players
  where game_id = p_game_id and seat = p_seat;
  -- A human seat can only be played by its own user. An AI seat can be
  -- played by any (i.e., the) human participant — the client runs the
  -- engine until a server-side one exists.
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

    -- What leaves the rack: "?" for blanks, the letter itself otherwise.
    select coalesce(jsonb_agg(
             case when coalesce((e->>'blank')::boolean, false)
                  then '?' else e->>'letter' end), '[]'::jsonb)
      into v_letters
      from jsonb_array_elements(p_placements) e;
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
          expires_at = now() + interval '7 days'
      where id = p_game_id;

  elsif p_kind = 'pass' then
    update games
      set turn_seat = 1 - p_seat,
          turn_number = turn_number + 1,
          consecutive_passes = consecutive_passes + 1,
          updated_at = now(),
          expires_at = now() + interval '7 days'
      where id = p_game_id;

  elsif p_kind = 'swap' then
    if p_swap_letters is null or jsonb_array_length(p_swap_letters) = 0 then
      raise exception 'empty_swap';
    end if;
    if jsonb_array_length(p_swap_letters) > jsonb_array_length(v_priv.bag) then
      raise exception 'bag_too_small';
    end if;
    v_rack := rack_remove(v_rack, p_swap_letters);
    -- Return to bag, RESHUFFLE, then draw (GAME-LOGIC-REFERENCE ordering).
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
          expires_at = now() + interval '7 days'
      where id = p_game_id;

  else
    raise exception 'bad_kind';
  end if;

  insert into moves (game_id, seat, move_number, kind, placements, word, client_score)
    values (p_game_id, p_seat, v_game.turn_number, p_kind, p_placements, p_word, p_client_score);

  return jsonb_build_object(
    'drawn', v_drawn,
    'bag_count', (select jsonb_array_length(bag) from game_private
                  where game_id = p_game_id),
    'turn_number', v_game.turn_number + 1);
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: finish_game — endgame is client-detected for now (same trust level
-- as scoring); server-side endgame detection can replace the internals
-- later without changing the API.
-- ---------------------------------------------------------------------------

create or replace function public.finish_game(
  p_game_id     uuid,
  p_end_reason  text,
  p_scores      jsonb,          -- {"0": final, "1": final} after leftover math
  p_winner_seat smallint default null
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_game games%rowtype;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  select * into v_game from games where id = p_game_id for update;
  if not found then raise exception 'game_not_found'; end if;
  if not is_game_participant(p_game_id) then raise exception 'not_participant'; end if;
  if v_game.status <> 'active' then return; end if;  -- idempotent
  if p_end_reason not in ('emptied','six_passes','resigned') then
    raise exception 'bad_end_reason';
  end if;

  update games set status = 'finished', end_reason = p_end_reason,
    winner_seat = p_winner_seat, finished_at = now(), updated_at = now()
    where id = p_game_id;
  update game_players gp set score = (p_scores ->> gp.seat::text)::int
    where gp.game_id = p_game_id and p_scores ? gp.seat::text;
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: resign_game — schema/API ready now; client UI arrives in Phase 9.
-- ---------------------------------------------------------------------------

create or replace function public.resign_game(p_game_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_game games%rowtype;
  v_seat smallint;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  select * into v_game from games where id = p_game_id for update;
  if not found then raise exception 'game_not_found'; end if;
  if v_game.status <> 'active' then raise exception 'game_not_active'; end if;
  select seat into v_seat from game_players
    where game_id = p_game_id and user_id = auth.uid();
  if v_seat is null then raise exception 'not_participant'; end if;

  update games set status = 'resigned', end_reason = 'resigned',
    winner_seat = 1 - v_seat, finished_at = now(), updated_at = now()
    where id = p_game_id;
  insert into moves (game_id, seat, move_number, kind)
    values (p_game_id, v_seat, v_game.turn_number, 'resign');
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: fetch_game — everything the caller may see about one game:
-- their own rack, AI racks (client-driven engine), never a human
-- opponent's rack, never the bag (count only).
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
-- RPC: fetch_lobby — summaries of every game the caller is in.
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
-- RPC: import_local_game — one-time migration of a pre-Phase-7 local game.
-- The client authored every part of that game anyway, so the payload is
-- trusted the same way its historical moves are. Idempotent by game id.
-- ---------------------------------------------------------------------------

create or replace function public.import_local_game(p jsonb)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_id  uuid := (p->>'id')::uuid;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if exists (select 1 from games where id = v_id) then return 'exists'; end if;

  insert into games (id, status, board, turn_seat, turn_number,
                     consecutive_passes, end_reason, winner_seat, import_log,
                     created_at, finished_at)
  values (
    v_id,
    coalesce(p->>'status', 'active'),
    coalesce(p->'board', '{}'::jsonb),
    coalesce((p->>'turn_seat')::smallint, 0),
    coalesce((p->>'turn_number')::int, 1),
    coalesce((p->>'consecutive_passes')::int, 0),
    p->>'end_reason',
    (p->>'winner_seat')::smallint,
    p->'log',
    coalesce((p->>'created_at')::timestamptz, now()),
    case when p->>'status' = 'finished' then now() end);

  insert into game_players (game_id, seat, user_id, engine, ai_difficulty, score) values
    (v_id, 0, v_uid, 'human', null, coalesce((p->'scores'->>'0')::int, 0)),
    (v_id, 1, null, 'local_ai',
     coalesce(p->>'ai_difficulty', 'hard'), coalesce((p->'scores'->>'1')::int, 0));

  insert into game_private (game_id, bag, racks)
    values (v_id, coalesce(p->'bag', '[]'::jsonb),
            coalesce(p->'racks', '{"0":[],"1":[]}'::jsonb));
  return 'imported';
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants: RPCs for signed-in clients; helpers locked down entirely.
-- ---------------------------------------------------------------------------

revoke execute on function public.game_new_bag() from public, anon, authenticated;
revoke execute on function public.bag_draw(jsonb, int) from public, anon, authenticated;
revoke execute on function public.rack_remove(jsonb, jsonb) from public, anon, authenticated;
revoke execute on function public.cleanup_orphan_games() from public, anon, authenticated;

do $$
declare fn text;
begin
  foreach fn in array array[
    'is_game_participant(uuid)',
    'create_game(text)',
    'submit_move(uuid, smallint, text, jsonb, text, int, jsonb)',
    'finish_game(uuid, text, jsonb, smallint)',
    'resign_game(uuid)',
    'fetch_game(uuid)',
    'fetch_lobby()',
    'import_local_game(jsonb)']
  loop
    execute format('revoke execute on function public.%s from public, anon', fn);
    execute format('grant execute on function public.%s to authenticated', fn);
  end loop;
end $$;
