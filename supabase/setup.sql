-- Words — Phase 6 schema: users, profiles, account deletion.
-- Run this in the Supabase Dashboard → SQL Editor (paste + Run).
-- Safe to re-run: statements are idempotent.
--
-- IDENTITY MODEL (PRODUCT-SPEC requirement)
-- The stable internal user ID is auth.users.id. A Sign in with Apple login
-- is one row in auth.identities LINKED to that user — the user HAS an Apple
-- credential; the user IS NOT the Apple identity. Supabase models this out
-- of the box: adding Google or email/password later just adds another
-- auth.identities row against the same user ID. No migration, purely
-- additive — don't fight the platform.

-- ---------------------------------------------------------------------------
-- Profiles: presentation data for a user (display name + avatar).
-- Everything else about a user stays in auth.*; game data arrives in Phase 7.
-- ---------------------------------------------------------------------------

create table if not exists public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  display_name text not null default 'Player'
               check (char_length(display_name) between 1 and 40),
  avatar       text not null default 'bolt',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

alter table public.profiles enable row level security;

-- Any signed-in user may read any profile (needed later for opponents'
-- names/avatars and username search). Writes: own row only. No insert
-- policy — rows are created exclusively by the signup trigger below.
drop policy if exists "profiles_select_authenticated" on public.profiles;
create policy "profiles_select_authenticated"
  on public.profiles for select to authenticated using (true);

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own"
  on public.profiles for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- Keep updated_at honest.
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists profiles_touch_updated_at on public.profiles;
create trigger profiles_touch_updated_at
  before update on public.profiles
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Signup trigger: every new auth user gets a profile row immediately,
-- whatever provider created them. The client then personalizes it
-- (Apple full name arrives only on the first authorization, client-side).
-- ---------------------------------------------------------------------------

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''), 'Player')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Account deletion (App Store requirement): really deletes the user
-- server-side. Deleting the auth.users row cascades to auth.identities
-- (the Apple credential) and public.profiles. Runs as definer because
-- clients have no privileges on auth.users; the WHERE clause pins it to
-- the caller's own account.
-- ---------------------------------------------------------------------------

create or replace function public.delete_account()
returns void
language sql
security definer
set search_path = ''
as $$
  delete from auth.users where id = (select auth.uid());
$$;

revoke execute on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;
