-- Words — Phase 13f: avatar system (profile columns + storage policies).
-- Run AFTER phase13e_stat_percentiles.sql. Idempotent.
--
-- The client now renders ONE avatar component everywhere: an uploaded
-- PHOTO when one exists, else a client-side duotone initials MONOGRAM.
-- Server side that needs two things:
--
--  1. PROFILE COLUMNS:
--     • avatar_url      — public URL of the uploaded photo (null = none;
--       the client shows the monogram).
--     • avatar_palette  — the monogram's duotone choice; 'auto' (the
--       default) = derived deterministically from the display name.
--     Both flow through the existing profile fetch/update path (own-row
--     RLS unchanged). The legacy `avatar` icon column stays for old
--     clients; nothing new reads it.
--
--  2. STORAGE POLICIES for the PUBLIC `avatars` bucket (bucket already
--     created by hand in the dashboard — this file does NOT create it):
--     • PUBLIC READ: anyone can read any avatar. The bucket is public;
--       this makes the object-level policy explicit and correct.
--     • WRITE OWN SLOT ONLY: each user owns exactly ONE object,
--       `{auth.uid()}.jpg` (lowercase uuid — matching auth.uid()::text).
--       Insert/update/delete are allowed only on that exact name, so a
--       new upload overwrites in place (no orphans) and nobody can ever
--       touch someone else's avatar.

alter table public.profiles
  add column if not exists avatar_url text;
alter table public.profiles
  add column if not exists avatar_palette text not null default 'auto';

-- Storage object policies (storage.objects already has RLS enabled by
-- Supabase). Names are namespaced to avoid colliding with any dashboard-
-- created policies; drop-then-create keeps the file idempotent.

drop policy if exists "avatars_public_read" on storage.objects;
create policy "avatars_public_read"
  on storage.objects for select
  using (bucket_id = 'avatars');

drop policy if exists "avatars_insert_own" on storage.objects;
create policy "avatars_insert_own"
  on storage.objects for insert
  with check (
    bucket_id = 'avatars'
    and auth.uid() is not null
    and name = auth.uid()::text || '.jpg'
  );

drop policy if exists "avatars_update_own" on storage.objects;
create policy "avatars_update_own"
  on storage.objects for update
  using (
    bucket_id = 'avatars'
    and auth.uid() is not null
    and name = auth.uid()::text || '.jpg'
  )
  with check (
    bucket_id = 'avatars'
    and auth.uid() is not null
    and name = auth.uid()::text || '.jpg'
  );

drop policy if exists "avatars_delete_own" on storage.objects;
create policy "avatars_delete_own"
  on storage.objects for delete
  using (
    bucket_id = 'avatars'
    and auth.uid() is not null
    and name = auth.uid()::text || '.jpg'
  );
