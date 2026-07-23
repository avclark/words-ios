-- Words — Phase 10: push notifications.
-- Run AFTER phase9_robustness.sql (Dashboard → SQL Editor). Idempotent.
--
-- DESIGN: outbox pattern. Game events insert typed rows into
-- notification_outbox via ONE function (notify_user) that (a) enforces the
-- closed list of allowed types and (b) honors the recipient's per-type
-- prefs SERVER-side — a disabled type is never inserted, let alone sent.
-- The send-push edge function drains the outbox to APNs.
--
-- NOTIFICATION DISCIPLINE (product requirement, FEATURE-LIST): the type
-- CHECK below is the complete list, matching FEATURE-LIST exactly. Every
-- insert flows from a trigger on a real game event or the rate-limited
-- ping RPC. There is deliberately NO generic "send a push" API — adding a
-- re-engagement nag would require a schema change to this file's
-- constraint, which is the point.
--
-- Decisions:
-- • "Your turn" pushes fire only in human-vs-human games (a solo AI game
--   flips turns while you're holding the phone — pushing that is noise).
-- • Badge = number of human-vs-human games awaiting your move, computed
--   at send time; the client recomputes on foreground.
-- • Ping rate limit: one ping per game per 6 hours, and only while it's
--   actually the opponent's turn.

-- ---------------------------------------------------------------------------
-- Device tokens: a user may have several devices; a token belongs to at
-- most one user (re-registering reassigns it). APNs 410 deletes it.
-- ---------------------------------------------------------------------------

create table if not exists public.device_tokens (
  token      text primary key,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  platform   text not null default 'ios' check (platform in ('ios')),
  updated_at timestamptz not null default now()
);

alter table public.device_tokens enable row level security;
-- No policies: register/unregister RPCs only; the edge function reads with
-- the service role.

create or replace function public.register_device_token(
  p_token text, p_platform text default 'ios')
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  insert into device_tokens (token, user_id, platform)
    values (p_token, auth.uid(), p_platform)
  on conflict (token) do update
    set user_id = excluded.user_id, updated_at = now();
end;
$$;

create or replace function public.unregister_device_token(p_token text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  delete from device_tokens
   where token = p_token and user_id = auth.uid();
end;
$$;

-- ---------------------------------------------------------------------------
-- Per-type preferences, honored at INSERT time (server-side).
-- Missing row = everything on. Clients read/write their own row directly.
-- ---------------------------------------------------------------------------

create table if not exists public.notification_prefs (
  user_id        uuid primary key references public.profiles (id) on delete cascade,
  turn           boolean not null default true,
  new_game       boolean not null default true,
  game_over      boolean not null default true,
  chat           boolean not null default true,
  expiry_warning boolean not null default true,
  ping           boolean not null default true,
  updated_at     timestamptz not null default now()
);

alter table public.notification_prefs enable row level security;

drop policy if exists notification_prefs_select_own on public.notification_prefs;
create policy notification_prefs_select_own on public.notification_prefs
  for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists notification_prefs_insert_own on public.notification_prefs;
create policy notification_prefs_insert_own on public.notification_prefs
  for insert to authenticated with check (user_id = (select auth.uid()));

drop policy if exists notification_prefs_update_own on public.notification_prefs;
create policy notification_prefs_update_own on public.notification_prefs
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- Outbox
-- ---------------------------------------------------------------------------

create table if not exists public.notification_outbox (
  id         bigint generated always as identity primary key,
  recipient  uuid not null references public.profiles (id) on delete cascade,
  -- THE closed list. FEATURE-LIST's exact events; nothing else, ever.
  type       text not null check
             (type in ('turn','new_game','game_over','chat','expiry_warning','ping')),
  game_id    uuid references public.games (id) on delete cascade,
  title      text not null,
  body       text not null,
  badge      int,
  created_at timestamptz not null default now(),
  sent_at    timestamptz,
  error      text
);

alter table public.notification_outbox enable row level security;
-- No policies: written by triggers/RPCs, drained by the edge function.

-- Human-vs-human games awaiting this user's move (the badge number).
create or replace function public.awaiting_move_count(p_user uuid)
returns int
language sql stable security definer set search_path = public
as $$
  select count(*)::int from games g
  join game_players me on me.game_id = g.id and me.user_id = p_user
  where g.status = 'active'
    and g.turn_seat = me.seat
    and exists (select 1 from game_players o
                where o.game_id = g.id and o.engine = 'human'
                  and o.user_id is distinct from p_user);
$$;

-- The single gate every notification passes through: closed type list
-- (table constraint) + server-side prefs check + immediate drain poke.
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
         end
    into v_enabled
    from notification_prefs where user_id = p_recipient;
  if v_enabled is false then return; end if;  -- null (no row) = enabled

  insert into notification_outbox (recipient, type, game_id, title, body, badge)
    values (p_recipient, p_type, p_game, p_title, p_body,
            awaiting_move_count(p_recipient));

  -- Poke the drain immediately; the cron sweep below is the safety net.
  begin
    perform net.http_post(
      url := 'https://wdbouucicnxeoomazerx.supabase.co/functions/v1/send-push',
      body := '{}'::jsonb,
      headers := '{"Content-Type": "application/json"}'::jsonb);
  exception when others then
    null;  -- pg_net missing/unreachable: the cron sweep delivers
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- Event sources (the only writers)
-- ---------------------------------------------------------------------------

-- Turn passed to a human (their opponent moved) — human-vs-human only.
-- auth.uid() inside the trigger is the mover, so the mover never
-- self-notifies (covers AI games too: the human submits the AI's move).
create or replace function public.notify_turn_change()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_recipient game_players%rowtype;
  v_mover_name text;
begin
  if new.status <> 'active' or new.turn_seat = old.turn_seat then return new; end if;
  select * into v_recipient from game_players
   where game_id = new.id and seat = new.turn_seat;
  if v_recipient.engine <> 'human'
     or v_recipient.user_id is not distinct from auth.uid() then
    return new;
  end if;
  if not exists (select 1 from game_players o
                 where o.game_id = new.id and o.seat <> new.turn_seat
                   and o.engine = 'human') then
    return new;  -- solo AI game: no push
  end if;
  select coalesce(pr.display_name, 'Your opponent') into v_mover_name
    from game_players gp left join profiles pr on pr.id = gp.user_id
   where gp.game_id = new.id and gp.seat <> new.turn_seat;
  perform notify_user(v_recipient.user_id, 'turn', new.id,
                      'Your turn', v_mover_name || ' played — your move.');
  return new;
end;
$$;

drop trigger if exists games_notify_turn on public.games;
create trigger games_notify_turn
  after update on public.games
  for each row execute function public.notify_turn_change();

-- Game ended (finished / resigned / expired). Everyone human except the
-- actor; expiry has no actor (cron), so both players hear about it.
create or replace function public.notify_game_over()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_seat game_players%rowtype;
  v_body text;
begin
  if old.status <> 'active' or new.status = 'active' then return new; end if;
  for v_seat in
    select * from game_players
     where game_id = new.id and engine = 'human'
       and user_id is distinct from auth.uid()
  loop
    v_body := case new.end_reason
      when 'resigned' then case when new.winner_seat = v_seat.seat
        then 'Your opponent resigned — you win!'
        else 'The game ended by resignation.' end
      when 'expired' then case when new.winner_seat = v_seat.seat
        then 'The game expired — you win by forfeit.'
        else 'The game expired after 14 days of inactivity.' end
      else case when new.winner_seat = v_seat.seat
        then 'You won!'
        when new.winner_seat is null then 'The game ended in a tie.'
        else 'Your opponent won this one.' end
    end;
    perform notify_user(v_seat.user_id, 'game_over', new.id, 'Game over', v_body);
  end loop;
  return new;
end;
$$;

drop trigger if exists games_notify_over on public.games;
create trigger games_notify_over
  after update on public.games
  for each row execute function public.notify_game_over();

-- Expiry warning: fires when the Phase 9 job stamps expiry_warned_at.
create or replace function public.notify_expiry_warning()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_on_turn game_players%rowtype;
begin
  if old.expiry_warned_at is not null or new.expiry_warned_at is null
     or new.status <> 'active' then
    return new;
  end if;
  select * into v_on_turn from game_players
   where game_id = new.id and seat = new.turn_seat;
  if v_on_turn.engine = 'human' then
    perform notify_user(v_on_turn.user_id, 'expiry_warning', new.id,
                        'Game expiring',
                        'Your game expires today unless you play.');
  end if;
  return new;
end;
$$;

drop trigger if exists games_notify_expiry_warning on public.games;
create trigger games_notify_expiry_warning
  after update on public.games
  for each row execute function public.notify_expiry_warning();

-- New game: the invited/challenged human seat hears about it.
create or replace function public.notify_new_game()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_creator_name text;
begin
  if new.engine <> 'human' or new.user_id is not distinct from auth.uid() then
    return new;
  end if;
  select coalesce(pr.display_name, 'A friend') into v_creator_name
    from game_players gp left join profiles pr on pr.id = gp.user_id
   where gp.game_id = new.game_id and gp.seat <> new.seat;
  perform notify_user(new.user_id, 'new_game', new.game_id,
                      'New game',
                      v_creator_name || ' challenged you to a game.');
  return new;
end;
$$;

drop trigger if exists game_players_notify_new_game on public.game_players;
create trigger game_players_notify_new_game
  after insert on public.game_players
  for each row execute function public.notify_new_game();

-- Chat (plumbing for Phase 11 — the table exists, the app doesn't send yet).
create or replace function public.notify_chat_message()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_seat game_players%rowtype;
  v_sender_name text;
begin
  select display_name into v_sender_name from profiles where id = new.sender;
  for v_seat in
    select * from game_players
     where game_id = new.game_id and engine = 'human'
       and user_id is distinct from new.sender
  loop
    perform notify_user(v_seat.user_id, 'chat', new.game_id,
                        coalesce(v_sender_name, 'New message'),
                        left(new.body, 120));
  end loop;
  return new;
end;
$$;

drop trigger if exists chat_notify_message on public.chat_messages;
create trigger chat_notify_message
  after insert on public.chat_messages
  for each row execute function public.notify_chat_message();

-- ---------------------------------------------------------------------------
-- Ping / nudge: 1 per game per 6 hours, only while it's the opponent's
-- turn. The one client-invokable notification, and it's rate-limited.
-- ---------------------------------------------------------------------------

alter table public.game_players add column if not exists last_ping_at timestamptz;

create or replace function public.ping_opponent(p_game_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_game games%rowtype;
  v_me game_players%rowtype;
  v_opp game_players%rowtype;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select * into v_game from games where id = p_game_id for update;
  if not found then raise exception 'game_not_found'; end if;
  if v_game.status <> 'active' then raise exception 'game_not_active'; end if;
  select * into v_me from game_players
   where game_id = p_game_id and user_id = v_uid;
  if not found then raise exception 'not_participant'; end if;
  select * into v_opp from game_players
   where game_id = p_game_id and seat = 1 - v_me.seat;
  if v_opp.engine <> 'human' then raise exception 'no_human_opponent'; end if;
  if v_game.turn_seat <> v_opp.seat then
    return jsonb_build_object('status', 'not_their_turn');
  end if;
  if v_me.last_ping_at is not null
     and v_me.last_ping_at > now() - interval '6 hours' then
    return jsonb_build_object(
      'status', 'cooldown',
      'retry_after_minutes',
      ceil(extract(epoch from (v_me.last_ping_at + interval '6 hours' - now())) / 60)::int);
  end if;

  update game_players set last_ping_at = now()
   where game_id = p_game_id and seat = v_me.seat;
  perform notify_user(v_opp.user_id, 'ping', p_game_id,
                      'Still your turn',
                      (select display_name from profiles where id = v_uid)
                        || ' is waiting for you to play.');
  return jsonb_build_object('status', 'sent');
end;
$$;

-- ---------------------------------------------------------------------------
-- Safety-net drain every 5 minutes (pg_net poke is the fast path).
-- ---------------------------------------------------------------------------

create or replace function public.drain_notification_outbox()
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if exists (select 1 from notification_outbox
             where sent_at is null and error is null) then
    begin
      perform net.http_post(
        url := 'https://wdbouucicnxeoomazerx.supabase.co/functions/v1/send-push',
        body := '{}'::jsonb,
        headers := '{"Content-Type": "application/json"}'::jsonb);
    exception when others then null;
    end;
  end if;
end;
$$;

do $$
begin
  create extension if not exists pg_net;
  begin
    perform cron.unschedule('words-push-drain');
  exception when others then null;
  end;
  perform cron.schedule('words-push-drain', '*/5 * * * *',
                        'select public.drain_notification_outbox()');
exception when others then
  raise notice 'pg_net/pg_cron unavailable (%) — outbox drains only on direct pokes', sqlerrm;
end $$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

do $$
declare fn text;
begin
  foreach fn in array array[
    'register_device_token(text, text)',
    'unregister_device_token(text)',
    'ping_opponent(uuid)']
  loop
    execute format('revoke execute on function public.%s from public, anon', fn);
    execute format('grant execute on function public.%s to authenticated', fn);
  end loop;
  execute 'revoke execute on function public.notify_user(uuid, text, uuid, text, text) from public, anon, authenticated';
  execute 'revoke execute on function public.awaiting_move_count(uuid) from public, anon, authenticated';
  execute 'revoke execute on function public.drain_notification_outbox() from public, anon, authenticated';
end $$;
