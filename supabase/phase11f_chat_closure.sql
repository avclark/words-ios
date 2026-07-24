-- Words — Phase 11f: chat lives and dies with the game.
-- Run AFTER phase11e_unfriend.sql (Dashboard → SQL Editor). Idempotent.
--
-- DECISION: a game ending closes its chat, full stop, regardless of
-- friendship — a finished game is history; rematch to keep talking.
-- (11e briefly tied finished-game chat to friendship; the client's
-- game-over overlay made that clause unreachable in practice, so the
-- rule is now the simple one the UI already implied.) The unfriend rung
-- of the ladder therefore means exactly one thing: no NEW games or
-- rematches.

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

  -- Chat is scoped to the live game — nothing else.
  select status into v_status from games where id = p_game_id;
  if v_status <> 'active' then raise exception 'chat_closed'; end if;

  insert into chat_messages (game_id, sender, body, kind)
    values (p_game_id, v_uid, p_body, p_kind)
    returning id into v_id;
  update games set updated_at = now() where id = p_game_id;
  return v_id;
end;
$$;

do $$
begin
  execute 'revoke execute on function public.send_chat(uuid, text, text) from public, anon';
  execute 'grant execute on function public.send_chat(uuid, text, text) to authenticated';
end $$;
