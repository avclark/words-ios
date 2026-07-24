-- Words — Phase 11b: close the rematch block-bypass; readable reports.
-- Run AFTER phase11_chat.sql (Dashboard → SQL Editor). Idempotent.
--
-- BUG FIXED: request_rematch (written in Phase 9, before blocks existed)
-- was the one game-creation path the Phase 11 block sweep missed — a
-- blocked player could rematch a resigned game into a fresh playable one,
-- defeating the block entirely. Audit of all creation paths:
--   create_game ✓ (phase11)   redeem_invite ✓ (phase11)
--   send_friend_request ✓ (phase11)   send_chat ✓ (phase11)
--   request_rematch ✗ → fixed here
--   import_local_game: solo-AI only, no pair to check
--   submit_move / ping_opponent: require an ACTIVE game; blocking resigns
--   all shared active games and creation is sealed, so none can exist.
-- The refusal reads as 'rematch_unavailable' — a clear, final outcome
-- that does not disclose the block (same stance as invites → 'invalid').

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
  -- The check Phase 11 missed: no new games across a block, ever.
  if is_blocked_pair(v_uid, v_opponent) then
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
  execute 'revoke execute on function public.request_rematch(uuid) from public, anon';
  execute 'grant execute on function public.request_rematch(uuid) to authenticated';
end $$;

-- ---------------------------------------------------------------------------
-- reports_readable: the reports table joined into something a human can
-- read at a glance in the Table Editor. Service-role only, like the table.
-- ---------------------------------------------------------------------------

create or replace view public.reports_readable as
select r.id,
       r.created_at,
       reporter.display_name                       as reporter_name,
       coalesce(target.display_name, '(deleted account)') as reported_name,
       r.reason,
       message.body                                as reported_message,
       message.kind                                as message_kind,
       r.game_id,
       r.reporter                                  as reporter_id,
       r.reported                                  as reported_id
from public.reports r
left join public.profiles reporter on reporter.id = r.reporter
left join public.profiles target   on target.id  = r.reported
left join public.chat_messages message on message.id = r.message_id
order by r.created_at desc;

revoke all on public.reports_readable from public, anon, authenticated;
grant select on public.reports_readable to service_role;
