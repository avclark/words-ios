-- Words — Phase 8 schema: friends, invites, human-vs-human games.
-- Run AFTER phase7_games.sql (Dashboard → SQL Editor). Idempotent.
--
-- DESIGN
-- • Invite links are the PRIMARY friend mechanism (FEATURE-LIST): a
--   multi-use, expiring token tied to its creator. Redeeming one creates
--   an ACCEPTED friendship immediately — sending someone your link is the
--   consent step, so no request/approve dance on top of it.
-- • Usernames are OPTIONAL and claimable any time (no signup friction);
--   username search is the backstop for "I know they play but lost the
--   link". No email search, no phone/contact matching — by design.
-- • Human seats reuse the Phase 7 generic seat model unchanged
--   (engine = 'human'). The Phase 7 rack-privacy exception for AI seats
--   does NOT extend to human seats: fetch_game only reveals a rack when
--   it's the caller's own seat or an AI seat. verify_phase8.sh proves it.

-- ---------------------------------------------------------------------------
-- Usernames: optional, unique, lowercase [a-z0-9_]{3,20}.
-- ---------------------------------------------------------------------------

alter table public.profiles add column if not exists username text;
create unique index if not exists profiles_username_unique
  on public.profiles (username);

create or replace function public.set_username(p_username text)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if p_username is null then
    update profiles set username = null where id = v_uid;
    return 'cleared';
  end if;
  if p_username !~ '^[a-z0-9_]{3,20}$' then
    return 'invalid';
  end if;
  begin
    update profiles set username = p_username where id = v_uid;
  exception when unique_violation then
    return 'taken';
  end;
  return 'ok';
end;
$$;

-- ---------------------------------------------------------------------------
-- Invite links. One live (unexpired) link per creator, reused on repeated
-- asks; 30-day expiry. Cascade: deleting the creator deletes their links.
-- ---------------------------------------------------------------------------

create table if not exists public.invites (
  token      text primary key default encode(gen_random_bytes(8), 'hex'),
  creator    uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '30 days'
);

alter table public.invites enable row level security;

drop policy if exists invites_select_own on public.invites;
create policy invites_select_own on public.invites
  for select to authenticated using (creator = (select auth.uid()));
-- Writes via RPCs only.

create or replace function public.create_invite()
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_token text;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select token into v_token from invites
    where creator = v_uid and expires_at > now()
    order by created_at desc limit 1;
  if v_token is null then
    insert into invites (creator) values (v_uid) returning token into v_token;
  end if;
  return jsonb_build_object('token', v_token);
end;
$$;

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

  select jsonb_build_object('user_id', id, 'display_name', display_name,
                            'avatar', avatar, 'username', username)
    into v_friend from profiles where id = v_invite.creator;

  v_a := least(v_uid, v_invite.creator);
  v_b := greatest(v_uid, v_invite.creator);
  select status into v_status from friendships where user_a = v_a and user_b = v_b;
  if v_status = 'accepted' then
    return jsonb_build_object('status', 'already_friends', 'friend', v_friend);
  elsif v_status = 'pending' then
    -- A pending request in either direction collapses to friendship: both
    -- sides have now expressed intent.
    update friendships set status = 'accepted' where user_a = v_a and user_b = v_b;
  else
    insert into friendships (user_a, user_b, status, requested_by)
      values (v_a, v_b, 'accepted', v_invite.creator);
  end if;
  return jsonb_build_object('status', 'accepted', 'friend', v_friend);
end;
$$;

-- ---------------------------------------------------------------------------
-- Friend requests (the username-search path).
-- ---------------------------------------------------------------------------

create or replace function public.send_friend_request(p_user uuid)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_a      uuid;
  v_b      uuid;
  v_row    friendships%rowtype;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if p_user = v_uid then return 'self'; end if;
  if not exists (select 1 from profiles where id = p_user) then
    return 'no_such_user';
  end if;
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
  -- They asked us first; asking back = mutual consent.
  update friendships set status = 'accepted' where user_a = v_a and user_b = v_b;
  return 'accepted';
end;
$$;

create or replace function public.respond_friend_request(p_user uuid, p_accept boolean)
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
  v_a := least(v_uid, p_user);
  v_b := greatest(v_uid, p_user);
  select * into v_row from friendships where user_a = v_a and user_b = v_b;
  if not found or v_row.status <> 'pending' or v_row.requested_by = v_uid then
    return 'no_request';
  end if;
  if p_accept then
    update friendships set status = 'accepted' where user_a = v_a and user_b = v_b;
    return 'accepted';
  end if;
  delete from friendships where user_a = v_a and user_b = v_b;
  return 'declined';
end;
$$;

-- Removes a friend OR cancels an outgoing pending request.
create or replace function public.remove_friend(p_user uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  delete from friendships
    where user_a = least(auth.uid(), p_user)
      and user_b = greatest(auth.uid(), p_user);
end;
$$;

create or replace function public.list_friends()
returns jsonb
language sql stable security definer set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id', pr.id,
    'display_name', pr.display_name,
    'avatar', pr.avatar,
    'username', pr.username,
    'state', case
      when f.status = 'accepted' then 'friend'
      when f.requested_by = auth.uid() then 'outgoing'
      else 'incoming' end) order by pr.display_name), '[]'::jsonb)
  from friendships f
  join profiles pr on pr.id = case when f.user_a = auth.uid() then f.user_b else f.user_a end
  where auth.uid() in (f.user_a, f.user_b);
$$;

-- ---------------------------------------------------------------------------
-- create_game now takes an optional human opponent (must be a friend).
-- Same generic seats; a human seat 1 instead of the AI seat. The old
-- single-parameter signature is replaced.
-- ---------------------------------------------------------------------------

drop function if exists public.create_game(text);

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
    -- The other seat's rack is returned ONLY for an AI seat (the client
    -- runs the engine). A human opponent's rack never leaves the server.
    'ai_rack', case when p_opponent is null then v_rack1 end,
    'bag_count', jsonb_array_length(v_bag));
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

do $$
declare fn text;
begin
  foreach fn in array array[
    'set_username(text)',
    'create_invite()',
    'redeem_invite(text)',
    'send_friend_request(uuid)',
    'respond_friend_request(uuid, boolean)',
    'remove_friend(uuid)',
    'list_friends()',
    'create_game(text, uuid)']
  loop
    execute format('revoke execute on function public.%s from public, anon', fn);
    execute format('grant execute on function public.%s to authenticated', fn);
  end loop;
end $$;
