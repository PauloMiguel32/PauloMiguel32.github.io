-- =====================================================================
-- CrossFit Cainta - UPDATE v15  (run ONCE, AFTER supabase-update-v14.sql)
-- Create Account now asks "Member or Coach". The choice is saved as a REQUEST
-- (requested_role). Nobody becomes a coach by themselves: the Head Coach still
-- taps Approve, and the app then gives the role they asked for.
-- Safe to run more than once.
-- =====================================================================
alter table public.profiles add column if not exists requested_role text not null default 'member';
alter table public.profiles drop constraint if exists profiles_requested_role_check;
alter table public.profiles add constraint profiles_requested_role_check check (requested_role in ('member', 'coach'));

-- Sign-up reads the choice (anything other than 'coach' counts as member). The real role stays 'member'.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name, bio, board_ok, requested_role)
  values (
    new.id,
    new.email,
    coalesce(nullif(trim(new.raw_user_meta_data->>'full_name'), ''), split_part(new.email, '@', 1)),
    coalesce(new.raw_user_meta_data->>'bio', ''),
    coalesce(new.raw_user_meta_data->>'board_ok', '') = 'true',
    case when new.raw_user_meta_data->>'account_type' = 'coach' then 'coach' else 'member' end
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

-- Only the Head Coach can change the request afterwards
create or replace function public.lock_requested_role()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_head_coach() then
    new.requested_role := old.requested_role;
  end if;
  return new;
end;
$$;
drop trigger if exists profiles_lock_requested_role on public.profiles;
create trigger profiles_lock_requested_role before update on public.profiles
  for each row execute function public.lock_requested_role();
