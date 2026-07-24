-- Words — Phase 11d: durable game deletion + friend-request notifications.
-- Run AFTER phase11c_search.sql (Dashboard → SQL Editor). Idempotent.
--
-- 1) DELETION SEMANTICS (deliberate): deleting a game removes it from
--    YOUR lobby, never your opponent's — their history is theirs.
--    • Human-vs-human: per-seat hide (hidden_at on your seat); survives
--      sync, relaunch, and reinstall because fetch_lobby excludes it.
--    • Solo games (AI opponent, or a departed seat): hard delete — no
--      one else exists to care.
--    • Active human games refuse ('resign_first'): deleting one would be
--      silent abandonment — the opponent waits on a ghost until expiry.
--    The old client-only delete just dropped the cache; every sync
--    resurrected the rows.
--
-- 2) FRIEND NOTIFICATIONS (spec gap; FEATURE-LIST updated to match):
--    'friend_request' when someone asks; 'friend_accept' to the SENDER
--    when accepted (they initiated; the answer is the event) and to the
--    INVITER when an invite link is redeemed. Declines never notify —
--    no action to take, nothing but sting. Same notify_user gate, same
--    outbox constraint, one 'friend' prefs toggle.

-- ---------------------------------------------------------------------------
-- Deletion
-- ---------------------------------------------------------------------------

alter table public.game_players add column if not exists hidden_at timestamptz;

create or replace function public.delete_game(p_game_id uuid)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_game games%rowtype;
  v_me   game_players%rowtype;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select * into v_game from games where id = p_game_id for update;
  if not found then return 'already_gone'; end if;
  select * into v_me from game_players
   where game_id = p_game_id and user_id = v_uid;
  if not found then raise exception 'not_participant'; end if;

  if not exists (select 1 from game_players
                 where game_id = p_game_id and engine = 'human'
                   and user_id is distinct from v_uid) then
    -- Solo (AI or departed opponent): nobody else's history involved.
    delete from games where id = p_game_id;
    return 'deleted';
  end if;

  if v_game.status = 'active' then
    raise exception 'resign_first';
  end if;
  update game_players set hidden_at = now()
   where game_id = p_game_id and seat = v_me.seat;
  return 'hidden';
end;
$$;

-- Lobby excludes games this user has hidden (fetch_game stays reachable —
-- hidden is a lobby concept, not an access revocation).
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
  where is_game_participant(g.id)
    and not exists (select 1 from game_players hp
                    where hp.game_id = g.id
                      and hp.user_id = (select auth.uid())
                      and hp.hidden_at is not null);
$$;

-- ---------------------------------------------------------------------------
-- Friend notifications: expand the closed type list + prefs + triggers.
-- ---------------------------------------------------------------------------

do $$
declare c record;
begin
  for c in select conname from pg_constraint
           where conrelid = 'public.notification_outbox'::regclass and contype = 'c'
  loop
    execute format('alter table public.notification_outbox drop constraint %I', c.conname);
  end loop;
end $$;

alter table public.notification_outbox
  add constraint notification_outbox_type_valid check
    (type in ('turn','new_game','game_over','chat','expiry_warning','ping',
              'friend_request','friend_accept'));

alter table public.notification_prefs
  add column if not exists friend boolean not null default true;

create or replace function public.notify_user(
  p_recipient uuid, p_type text, p_game uuid, p_title text, p_body text)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_enabled boolean;
begin
  select case p_type
           when 'turn' then turn
           when 'new_game' then new_game
           when 'game_over' then game_over
           when 'chat' then chat
           when 'expiry_warning' then expiry_warning
           when 'ping' then ping
           when 'friend_request' then friend
           when 'friend_accept' then friend
         end
    into v_enabled
    from notification_prefs where user_id = p_recipient;
  if v_enabled is false then return; end if;  -- null (no row) = enabled

  insert into notification_outbox (recipient, type, game_id, title, body, badge)
    values (p_recipient, p_type, p_game, p_title, p_body,
            awaiting_move_count(p_recipient));

  begin
    perform net.http_post(
      url := 'https://wdbouucicnxeoomazerx.supabase.co/functions/v1/send-push',
      body := '{}'::jsonb,
      headers := '{"Content-Type": "application/json"}'::jsonb);
  exception when others then
    null;
  end;
end;
$$;

create or replace function public.notify_friendship_event()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_actor      uuid;
  v_target     uuid;
  v_actor_name text;
begin
  if tg_op = 'INSERT' and new.status = 'pending' then
    v_actor := new.requested_by;
    v_target := case when v_actor = new.user_a then new.user_b else new.user_a end;
    select display_name into v_actor_name from profiles where id = v_actor;
    perform notify_user(v_target, 'friend_request', null,
      'Friend request',
      coalesce(v_actor_name, 'Someone') || ' wants to be friends.');
  elsif tg_op = 'INSERT' and new.status = 'accepted' then
    -- Invite-link redemption: instant friendship; tell the inviter.
    v_actor := auth.uid();
    v_target := case when v_actor = new.user_a then new.user_b else new.user_a end;
    if v_actor is not null and v_target is not null and v_target <> v_actor then
      select display_name into v_actor_name from profiles where id = v_actor;
      perform notify_user(v_target, 'friend_accept', null,
        'New friend',
        coalesce(v_actor_name, 'Someone') || ' accepted your invite — you''re now friends.');
    end if;
  elsif tg_op = 'UPDATE' and old.status = 'pending' and new.status = 'accepted' then
    v_target := new.requested_by;
    v_actor := case when v_target = new.user_a then new.user_b else new.user_a end;
    select display_name into v_actor_name from profiles where id = v_actor;
    perform notify_user(v_target, 'friend_accept', null,
      'New friend',
      coalesce(v_actor_name, 'Someone') || ' accepted your friend request.');
  end if;
  return new;
end;
$$;

drop trigger if exists friendships_notify on public.friendships;
create trigger friendships_notify
  after insert or update on public.friendships
  for each row execute function public.notify_friendship_event();

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

do $$
begin
  execute 'revoke execute on function public.delete_game(uuid) from public, anon';
  execute 'grant execute on function public.delete_game(uuid) to authenticated';
  execute 'revoke execute on function public.fetch_lobby() from public, anon';
  execute 'grant execute on function public.fetch_lobby() to authenticated';
  execute 'revoke execute on function public.notify_user(uuid, text, uuid, text, text) from public, anon, authenticated';
  execute 'revoke execute on function public.notify_friendship_event() from public, anon, authenticated';
end $$;
