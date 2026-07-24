-- Words — Phase 11c: search by display name OR username.
-- Run AFTER phase11b_block_rematch.sql (Dashboard → SQL Editor). Idempotent.
--
-- Friends-and-family reality: people search for "Jessica", not for
-- whichever @handle she picked (usernames are optional; most players
-- won't have one). Search now matches display name OR username,
-- case-insensitive substring. Privacy posture (deliberate): being
-- findable by name is acceptable because the only consequence is a
-- consent-gated friend request; mitigations are a 2-character minimum,
-- a 10-result cap, and blocked pairs never appearing in each other's
-- results. Results carry the relationship state so identical names are
-- distinguishable by context ("the Adam you're already friends with").

create or replace function public.search_players(p_query text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_q   text;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  v_q := trim(coalesce(p_query, ''));
  if char_length(v_q) < 2 then return '[]'::jsonb; end if;
  -- User input is data, not pattern: escape ilike wildcards.
  v_q := replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_');

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'user_id', p.id,
      'display_name', p.display_name,
      'avatar', p.avatar,
      'username', p.username,
      'state', coalesce((
        select case
          when f.status = 'accepted' then 'friend'
          when f.requested_by = v_uid then 'outgoing'
          else 'incoming' end
        from friendships f
        where f.user_a = least(v_uid, p.id)
          and f.user_b = greatest(v_uid, p.id)), 'none'))
      order by (p.username is not null and p.username ilike v_q || '%') desc,
               p.display_name)
    from (
      select pr.* from profiles pr
      where pr.id <> v_uid
        and not is_blocked_pair(v_uid, pr.id)
        and (pr.display_name ilike '%' || v_q || '%'
             or pr.username ilike '%' || v_q || '%')
      order by pr.display_name
      limit 10
    ) p), '[]'::jsonb);
end;
$$;

do $$
begin
  execute 'revoke execute on function public.search_players(text) from public, anon';
  execute 'grant execute on function public.search_players(text) to authenticated';
end $$;
