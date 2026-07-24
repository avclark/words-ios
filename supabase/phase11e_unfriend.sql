-- Words — Phase 11e: unfriend semantics.
-- Run AFTER phase11d_delete_and_friends.sql (Dashboard → SQL Editor). Idempotent.
--
-- THE RELATIONSHIP LADDER (deliberate, three distinct rungs):
--   UNFRIEND — nothing NEW: no challenges, no rematches; games in flight
--     play out honorably WITH their chat, and chat closes when they end.
--   BLOCK — stop all contact NOW: resigns shared games, seals every
--     surface both ways.
--   ACCOUNT DELETION — everything above plus the seat is anonymized.
-- Unfriending never notifies the other party (that would broadcast
-- rejection); it's discoverable through state — gone from the friends
-- list, 'not_friends' on any new challenge.
--
-- Enforcement here:
--   send_chat: friendship OR an active shared game (was: blocked-check
--     only, so ex-friends could chat forever in finished games).
--   request_rematch: rematch IS a new game — requires friendship (the
--     refusal stays 'rematch_unavailable', indistinguishable from the
--     block case on purpose).

create or replace function public.send_chat(
  p_game_id uuid, p_body text, p_kind text default 'text')
returns bigint
language plpgsql security definer set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_opponent uuid;
  v_status   text;
  v_id       bigint;
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

  -- Unfriended pairs keep chat only while a game is actually in play.
  select status into v_status from games where id = p_game_id;
  if v_status <> 'active' and not exists (
      select 1 from friendships
      where user_a = least(v_uid, v_opponent)
        and user_b = greatest(v_uid, v_opponent)
        and status = 'accepted') then
    raise exception 'chat_closed';
  end if;

  insert into chat_messages (game_id, sender, body, kind)
    values (p_game_id, v_uid, p_body, p_kind)
    returning id into v_id;
  update games set updated_at = now() where id = p_game_id;
  return v_id;
end;
$$;

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
  -- A rematch is a NEW game: blocked pairs AND non-friends both refuse,
  -- indistinguishably (the block stays undisclosed).
  if is_blocked_pair(v_uid, v_opponent) or not exists (
      select 1 from friendships
      where user_a = least(v_uid, v_opponent)
        and user_b = greatest(v_uid, v_opponent)
        and status = 'accepted') then
    raise exception 'rematch_unavailable';
  end if;

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

do $$
begin
  execute 'revoke execute on function public.send_chat(uuid, text, text) from public, anon';
  execute 'grant execute on function public.send_chat(uuid, text, text) to authenticated';
  execute 'revoke execute on function public.request_rematch(uuid) from public, anon';
  execute 'grant execute on function public.request_rematch(uuid) to authenticated';
end $$;
