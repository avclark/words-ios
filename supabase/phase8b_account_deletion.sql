-- Words — Phase 8b: account deletion in human-vs-human games.
-- Run AFTER phase8_friends.sql (Dashboard → SQL Editor). Idempotent.
--
-- PROBLEM: deleting an account cascaded the user's game_players rows away,
-- leaving any human opponent a one-seated zombie game — unopenable and
-- unexplained. FEATURE-LIST bans exactly that kind of silent breakage.
--
-- DESIGN
-- • Active human-vs-human game: the remaining player wins by forfeit,
--   VISIBLY — status 'resigned', winner = their seat. No silent vanishing.
-- • The departing seat is anonymized, not deleted: engine = 'departed',
--   user_id = NULL. The other player keeps the game (and its history);
--   the deleted user's identity — profile, name, auth identities — is
--   fully removed, which is what App Store deletion requires.
-- • Finished human-vs-human games: seat anonymized, record kept.
-- • When the LAST real human leaves (AI games, or the other seat already
--   departed), the existing orphan-cleanup trigger deletes the whole game:
--   'departed' does not count as a human seat.

-- ---------------------------------------------------------------------------
-- Allow the 'departed' engine. The original check constraints were
-- unnamed; drop every check on game_players and re-add named ones.
-- ---------------------------------------------------------------------------

do $$
declare c record;
begin
  for c in select conname from pg_constraint
           where conrelid = 'public.game_players'::regclass and contype = 'c'
  loop
    execute format('alter table public.game_players drop constraint %I', c.conname);
  end loop;
end $$;

alter table public.game_players
  add constraint game_players_seat_valid check (seat in (0, 1)),
  add constraint game_players_engine_valid
    check (engine in ('human', 'local_ai', 'departed')),
  add constraint game_players_human_has_user
    check (engine <> 'human' or user_id is not null),
  add constraint game_players_nonhuman_has_no_user
    check (engine = 'human' or user_id is null),
  add constraint game_players_ai_has_difficulty
    check (engine <> 'local_ai' or ai_difficulty is not null);

-- ---------------------------------------------------------------------------
-- BEFORE DELETE on profiles: runs ahead of the FK cascade, so seats that
-- must survive are detached (user_id NULL) before the cascade can take
-- them. Fires both for direct deletes and for the auth.users cascade.
-- ---------------------------------------------------------------------------

create or replace function public.handle_profile_deletion()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  -- Forfeit every ACTIVE game where a human opponent remains.
  update games g
     set status = 'resigned',
         end_reason = 'resigned',
         winner_seat = 1 - gp.seat,
         finished_at = now(),
         updated_at = now()
    from game_players gp
   where gp.game_id = g.id
     and gp.user_id = old.id
     and g.status = 'active'
     and exists (select 1 from game_players o
                 where o.game_id = g.id
                   and o.engine = 'human'
                   and o.user_id <> old.id);

  -- Anonymize the departing seat wherever another human keeps the game.
  update game_players gp
     set user_id = null,
         engine = 'departed',
         ai_difficulty = null
   where gp.user_id = old.id
     and exists (select 1 from game_players o
                 where o.game_id = gp.game_id
                   and o.engine = 'human'
                   and o.user_id <> old.id);

  return old;
end;
$$;

drop trigger if exists on_profile_deleted on public.profiles;
create trigger on_profile_deleted
  before delete on public.profiles
  for each row execute function public.handle_profile_deletion();

revoke execute on function public.handle_profile_deletion() from public, anon, authenticated;
