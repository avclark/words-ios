-- Words — Phase 11: chat, emoji reactions, block & report, realtime.
-- Run AFTER phase10_notifications.sql (Dashboard → SQL Editor). Idempotent.
--
-- DESIGN
-- • Emoji reactions ARE chat messages (kind = 'emoji'): one table, one
--   realtime stream, one notification path, one read-marker. The takeover
--   animation is client-side, driven by "emoji messages newer than my
--   read marker" — which is also what makes it fire exactly once.
-- • chat_reads carries each player's last-read message id per game:
--   unread badges and takeover fire-once both derive from it.
-- • Chat writes go through send_chat ONLY (the Phase 7 direct-insert
--   policy is dropped): it enforces participant + human-opponent +
--   not-blocked, and bumps games.updated_at so lobbies refresh.
-- • Blocking (App Store requirement): auto-resigns shared active games AS
--   THE BLOCKER (walking away; the blocked player sees a normal
--   resignation and learns nothing), deletes the friendship, and blocks
--   new games / requests / invites / chat in both directions. Because
--   every shared surface is severed, no notification path from a blocked
--   user survives — no notify filtering needed.
-- • Reports land in a service-only table, reviewed via the dashboard.

-- ---------------------------------------------------------------------------
-- Chat: kinds + read markers
-- ---------------------------------------------------------------------------

alter table public.chat_messages
  add column if not exists kind text not null default 'text';

do $$ begin
  alter table public.chat_messages
    add constraint chat_messages_kind_valid check (kind in ('text','emoji'));
exception when duplicate_object then null; end $$;

create table if not exists public.chat_reads (
  game_id              uuid not null references public.games (id) on delete cascade,
  user_id              uuid not null references public.profiles (id) on delete cascade,
  last_read_message_id bigint not null default 0,
  updated_at           timestamptz not null default now(),
  primary key (game_id, user_id)
);

alter table public.chat_reads enable row level security;
-- RPC-only writes; reads folded into fetch_chat/fetch_game/fetch_lobby.

-- Replace direct chat inserts with the RPC path.
drop policy if exists chat_insert_participant on public.chat_messages;

-- ---------------------------------------------------------------------------
-- Blocks & reports
-- ---------------------------------------------------------------------------

create table if not exists public.blocks (
  blocker    uuid not null references public.profiles (id) on delete cascade,
  blocked    uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker, blocked)
);

alter table public.blocks enable row level security;

drop policy if exists blocks_select_own on public.blocks;
create policy blocks_select_own on public.blocks
  for select to authenticated using (blocker = (select auth.uid()));

create table if not exists public.reports (
  id         bigint generated always as identity primary key,
  reporter   uuid not null references public.profiles (id) on delete cascade,
  reported   uuid not null,   -- survives the reported account's deletion
  game_id    uuid references public.games (id) on delete set null,
  message_id bigint,
  reason     text not null check (char_length(reason) between 1 and 2000),
  created_at timestamptz not null default now()
);

alter table public.reports enable row level security;
-- No policies: written via report_user, read only from the dashboard.

create or replace function public.is_blocked_pair(p_a uuid, p_b uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from blocks
                 where (blocker = p_a and blocked = p_b)
                    or (blocker = p_b and blocked = p_a));
$$;

create or replace function public.block_user(p_user uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_game record;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if p_user = v_uid then raise exception 'cannot_block_self'; end if;
  insert into blocks (blocker, blocked) values (v_uid, p_user)
    on conflict do nothing;
  delete from friendships
    where user_a = least(v_uid, p_user) and user_b = greatest(v_uid, p_user);
  -- Walk away from shared active games: the BLOCKER resigns them. The
  -- blocked player sees an ordinary resignation, nothing more.
  for v_game in
    select g.id,
           (select seat from game_players where game_id = g.id and user_id = p_user) as their_seat,
           (select seat from game_players where game_id = g.id and user_id = v_uid) as my_seat,
           g.turn_number
      from games g
     where g.status = 'active'
       and exists (select 1 from game_players where game_id = g.id and user_id = v_uid)
       and exists (select 1 from game_players where game_id = g.id and user_id = p_user)
  loop
    update games set status = 'resigned', end_reason = 'resigned',
      winner_seat = v_game.their_seat, finished_at = now(), updated_at = now()
      where id = v_game.id;
    insert into moves (game_id, seat, move_number, kind)
      values (v_game.id, v_game.my_seat, v_game.turn_number, 'resign');
  end loop;
end;
$$;

create or replace function public.unblock_user(p_user uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  delete from blocks where blocker = auth.uid() and blocked = p_user;
end;
$$;

create or replace function public.list_blocked()
returns jsonb
language sql stable security definer set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id', b.blocked,
    'display_name', coalesce(pr.display_name, 'Deleted player'),
    'avatar', pr.avatar) order by b.created_at desc), '[]'::jsonb)
  from blocks b
  left join profiles pr on pr.id = b.blocked
  where b.blocker = auth.uid();
$$;

create or replace function public.report_user(
  p_user uuid, p_reason text,
  p_game_id uuid default null, p_message_id bigint default null)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  insert into reports (reporter, reported, game_id, message_id, reason)
    values (auth.uid(), p_user, p_game_id, p_message_id, p_reason);
end;
$$;

-- ---------------------------------------------------------------------------
-- Block enforcement in existing entry points
-- ---------------------------------------------------------------------------

-- create_game: refuse blocked pairs (recreate with the check added).
create or replace function public.create_game(
  p_ai_difficulty text default 'hard',
  p_opponent      uuid default null
) returns jsonb
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

  if p_opponent is not null then
    if p_opponent = v_uid then raise exception 'self_game'; end if;
    if is_blocked_pair(v_uid, p_opponent) then raise exception 'blocked'; end if;
    if not exists (select 1 from friendships
                   where user_a = least(v_uid, p_opponent)
                     and user_b = greatest(v_uid, p_opponent)
                     and status = 'accepted') then
      raise exception 'not_friends';
    end if;
  elsif p_ai_difficulty not in ('easy','medium','hard') then
    raise exception 'bad_difficulty';
  end if;

  v_bag := game_new_bag();
  v_d := bag_draw(v_bag, 7);  v_rack0 := v_d->'drawn';  v_bag := v_d->'rest';
  v_d := bag_draw(v_bag, 7);  v_rack1 := v_d->'drawn';  v_bag := v_d->'rest';

  insert into games default values returning id into v_game_id;
  if p_opponent is null then
    insert into game_players (game_id, seat, user_id, engine, ai_difficulty) values
      (v_game_id, 0, v_uid, 'human', null),
      (v_game_id, 1, null, 'local_ai', p_ai_difficulty);
  else
    insert into game_players (game_id, seat, user_id, engine) values
      (v_game_id, 0, v_uid, 'human'),
      (v_game_id, 1, p_opponent, 'human');
  end if;
  insert into game_private (game_id, bag, racks)
    values (v_game_id, v_bag, jsonb_build_object('0', v_rack0, '1', v_rack1));

  return jsonb_build_object(
    'game_id', v_game_id,
    'my_rack', v_rack0,
    'ai_rack', case when p_opponent is null then v_rack1 end,
    'bag_count', jsonb_array_length(v_bag));
end;
$$;

-- send_friend_request: blocked pairs get a terminal status.
create or replace function public.send_friend_request(p_user uuid)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_a   uuid;
  v_b   uuid;
  v_row friendships%rowtype;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if p_user = v_uid then return 'self'; end if;
  if not exists (select 1 from profiles where id = p_user) then
    return 'no_such_user';
  end if;
  if is_blocked_pair(v_uid, p_user) then return 'blocked'; end if;
  v_a := least(v_uid, p_user);
  v_b := greatest(v_uid, p_user);
  select * into v_row from friendships where user_a = v_a and user_b = v_b;
  if not found then
    insert into friendships (user_a, user_b, status, requested_by)
      values (v_a, v_b, 'pending', v_uid);
    return 'sent';
  end if;
  if v_row.status = 'accepted' then return 'already_friends'; end if;
  if v_row.requested_by = v_uid then return 'already_pending'; end if;
  update friendships set status = 'accepted' where user_a = v_a and user_b = v_b;
  return 'accepted';
end;
$$;

-- redeem_invite: blocked pairs can't sneak back in via a link.
create or replace function public.redeem_invite(p_token text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_invite  invites%rowtype;
  v_a       uuid;
  v_b       uuid;
  v_status  text;
  v_friend  jsonb;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select * into v_invite from invites
    where token = p_token and expires_at > now();
  if not found then
    return jsonb_build_object('status', 'invalid');
  end if;
  if v_invite.creator = v_uid then
    return jsonb_build_object('status', 'own_link');
  end if;
  if is_blocked_pair(v_uid, v_invite.creator) then
    return jsonb_build_object('status', 'invalid');  -- indistinguishable on purpose
  end if;

  select jsonb_build_object('user_id', id, 'display_name', display_name,
                            'avatar', avatar, 'username', username)
    into v_friend from profiles where id = v_invite.creator;

  v_a := least(v_uid, v_invite.creator);
  v_b := greatest(v_uid, v_invite.creator);
  select status into v_status from friendships where user_a = v_a and user_b = v_b;
  if v_status = 'accepted' then
    return jsonb_build_object('status', 'already_friends', 'friend', v_friend);
  elsif v_status = 'pending' then
    update friendships set status = 'accepted' where user_a = v_a and user_b = v_b;
  else
    insert into friendships (user_a, user_b, status, requested_by)
      values (v_a, v_b, 'accepted', v_invite.creator);
  end if;
  return jsonb_build_object('status', 'accepted', 'friend', v_friend);
end;
$$;

-- ---------------------------------------------------------------------------
-- Chat RPCs
-- ---------------------------------------------------------------------------

create or replace function public.send_chat(
  p_game_id uuid, p_body text, p_kind text default 'text')
returns bigint
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_opponent uuid;
  v_id bigint;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if p_kind not in ('text','emoji') then raise exception 'bad_kind'; end if;
  if p_body is null or char_length(p_body) < 1 or char_length(p_body) > 1000 then
    raise exception 'bad_body';
  end if;
  if not exists (select 1 from game_players
                 where game_id = p_game_id and user_id = v_uid) then
    raise exception 'not_participant';
  end if;
  select user_id into v_opponent from game_players
   where game_id = p_game_id and engine = 'human' and user_id <> v_uid;
  if v_opponent is null then raise exception 'no_human_opponent'; end if;
  if is_blocked_pair(v_uid, v_opponent) then raise exception 'blocked'; end if;

  insert into chat_messages (game_id, sender, body, kind)
    values (p_game_id, v_uid, p_body, p_kind)
    returning id into v_id;
  -- Chat is activity: lobbies re-sort and refresh on it.
  update games set updated_at = now() where id = p_game_id;
  return v_id;
end;
$$;

create or replace function public.fetch_chat(p_game_id uuid)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'my_last_read', coalesce((select last_read_message_id from chat_reads
                              where game_id = p_game_id and user_id = auth.uid()), 0),
    'messages', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', m.id, 'sender', m.sender, 'kind', m.kind,
        'body', m.body, 'created_at', m.created_at) order by m.id)
      from chat_messages m where m.game_id = p_game_id), '[]'::jsonb))
  where is_game_participant(p_game_id);
$$;

create or replace function public.mark_chat_read(p_game_id uuid, p_message_id bigint)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if not is_game_participant(p_game_id) then raise exception 'not_participant'; end if;
  insert into chat_reads (game_id, user_id, last_read_message_id)
    values (p_game_id, auth.uid(), p_message_id)
  on conflict (game_id, user_id) do update
    set last_read_message_id = greatest(chat_reads.last_read_message_id, excluded.last_read_message_id),
        updated_at = now();
end;
$$;

-- Unread chat count for one game and caller.
create or replace function public.unread_chat_count(p_game_id uuid)
returns int
language sql stable security definer set search_path = public
as $$
  select count(*)::int from chat_messages m
  where m.game_id = p_game_id
    and m.sender <> auth.uid()
    and m.id > coalesce((select last_read_message_id from chat_reads
                         where game_id = p_game_id and user_id = auth.uid()), 0);
$$;

-- fetch_game / fetch_lobby gain unread_chat.
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
    'unread_chat', unread_chat_count(g.id),
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
-- Realtime: chat inserts + game updates stream to subscribed clients
-- (RLS still applies). Guarded — if the publication is unavailable the
-- app degrades to its existing polling.
-- ---------------------------------------------------------------------------

do $$ begin
  alter publication supabase_realtime add table public.chat_messages;
exception when duplicate_object then null;
          when others then raise notice 'realtime chat_messages: %', sqlerrm; end $$;

do $$ begin
  alter publication supabase_realtime add table public.games;
exception when duplicate_object then null;
          when others then raise notice 'realtime games: %', sqlerrm; end $$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

do $$
declare fn text;
begin
  foreach fn in array array[
    'block_user(uuid)',
    'unblock_user(uuid)',
    'list_blocked()',
    'report_user(uuid, text, uuid, bigint)',
    'send_chat(uuid, text, text)',
    'fetch_chat(uuid)',
    'mark_chat_read(uuid, bigint)',
    'create_game(text, uuid)',
    'send_friend_request(uuid)',
    'redeem_invite(text)',
    'fetch_game(uuid)',
    'fetch_lobby()']
  loop
    execute format('revoke execute on function public.%s from public, anon', fn);
    execute format('grant execute on function public.%s to authenticated', fn);
  end loop;
  execute 'revoke execute on function public.is_blocked_pair(uuid, uuid) from public, anon, authenticated';
  execute 'revoke execute on function public.unread_chat_count(uuid) from public, anon, authenticated';
end $$;
