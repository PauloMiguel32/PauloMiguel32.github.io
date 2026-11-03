-- =====================================================================
-- CrossFit Cainta - UPDATE v14  (run ONCE, AFTER supabase-update-v13.sql)
-- Coach of the day on the Schedule + notifications for the assigned coach.
--  * Any coach can pick which coach runs each date.
--  * When a member reserves (or cancels) a class on that date, the assigned
--    coach gets a notification with the list of members attending.
--  * When a coach is assigned to a date, they get the current attendee list.
-- Safe to run more than once.
-- =====================================================================

-- 1. Who is the coach for each day
create table if not exists public.day_coaches (
  class_date date primary key,
  coach_id   uuid references public.profiles(id) on delete set null,
  coach_name text not null default '',
  set_by     uuid default auth.uid() references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);
alter table public.day_coaches enable row level security;

drop policy if exists "day_coaches: everyone reads" on public.day_coaches;
create policy "day_coaches: everyone reads" on public.day_coaches for select to anon, authenticated using (true);
drop policy if exists "day_coaches: coaches add" on public.day_coaches;
create policy "day_coaches: coaches add" on public.day_coaches for insert to authenticated with check (public.is_coach());
drop policy if exists "day_coaches: coaches edit" on public.day_coaches;
create policy "day_coaches: coaches edit" on public.day_coaches for update to authenticated using (public.is_coach()) with check (public.is_coach());
drop policy if exists "day_coaches: coaches delete" on public.day_coaches;
create policy "day_coaches: coaches delete" on public.day_coaches for delete to authenticated using (public.is_coach());
grant select on public.day_coaches to anon, authenticated;

create or replace function public.check_day_coach()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.coach_id is not null then
    select full_name into new.coach_name from public.profiles
      where id = new.coach_id and status = 'approved' and role in ('coach', 'head_coach');
    if not found then raise exception 'That person is not an approved coach'; end if;
  else
    new.coach_name := '';
  end if;
  new.set_by := auth.uid();
  new.updated_at := now();
  return new;
end;
$$;
drop trigger if exists day_coaches_check on public.day_coaches;
create trigger day_coaches_check before insert or update on public.day_coaches
  for each row execute function public.check_day_coach();

-- List of coaches a coach can pick from (names only)
create or replace function public.assignable_coaches()
returns table (id uuid, full_name text, role text)
language sql stable security definer set search_path = public as $$
  select p.id, p.full_name, p.role::text
  from public.profiles p
  where p.status = 'approved' and p.role in ('coach', 'head_coach')
  order by (p.role = 'head_coach') desc, p.full_name;
$$;
revoke all on function public.assignable_coaches() from public, anon;
grant execute on function public.assignable_coaches() to authenticated;

-- 2. Notifications
create table if not exists public.notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  title      text not null,
  body       text not null default '',
  kind       text not null default 'info',
  class_date date,
  created_at timestamptz not null default now(),
  read_at    timestamptz
);
create index if not exists notifications_user_idx on public.notifications (user_id, created_at desc);
alter table public.notifications enable row level security;

drop policy if exists "notifications: read own" on public.notifications;
create policy "notifications: read own" on public.notifications for select to authenticated using (user_id = auth.uid());
drop policy if exists "notifications: mark own read" on public.notifications;
create policy "notifications: mark own read" on public.notifications for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists "notifications: delete own" on public.notifications;
create policy "notifications: delete own" on public.notifications for delete to authenticated using (user_id = auth.uid());

-- 3. Helpers for the message text
create or replace function public.slot_label(p_slot text)
returns text language sql immutable as $$
  select case p_slot
    when 'evening1' then '5:30 PM class'
    when 'evening2' then '7:00 PM class'
    when 'hybrid'   then '6:00 PM Hybrid class'
    when 'saturday' then '10:30 AM Saturday class'
    else p_slot end;
$$;

create or replace function public.attendee_text(p_date date, p_slot text)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(string_agg(t.rn || '. ' || t.member_name, E'\n' order by t.rn), 'No one yet')
  from (select member_name, row_number() over (order by created_at) as rn
        from public.class_bookings where class_date = p_date and slot = p_slot) t;
$$;
revoke all on function public.attendee_text(date, text) from public, anon, authenticated;

-- 4. Notify the day's coach when someone reserves or cancels
create or replace function public.notify_booking()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  r public.class_bookings;
  c uuid;
  n int;
  d text;
  verb text;
begin
  if tg_op = 'INSERT' then r := new; verb := 'reserved'; else r := old; verb := 'cancelled'; end if;
  select coach_id into c from public.day_coaches where class_date = r.class_date;
  if c is null or c = r.owner then return null; end if;
  select count(*) into n from public.class_bookings where class_date = r.class_date and slot = r.slot;
  d := to_char(r.class_date, 'FMDy, Mon FMDD');
  insert into public.notifications (user_id, title, body, kind, class_date)
  values (
    c,
    case when verb = 'reserved' then 'New reservation - ' else 'Cancelled - ' end || public.slot_label(r.slot),
    r.member_name || ' ' || verb || ' the ' || public.slot_label(r.slot) || ' on ' || d || E'.\n\n'
      || 'Attending (' || n || ' of 15):' || E'\n' || public.attendee_text(r.class_date, r.slot),
    'booking',
    r.class_date
  );
  return null;
end;
$$;
drop trigger if exists class_bookings_notify_ins on public.class_bookings;
create trigger class_bookings_notify_ins after insert on public.class_bookings
  for each row execute function public.notify_booking();
drop trigger if exists class_bookings_notify_del on public.class_bookings;
create trigger class_bookings_notify_del after delete on public.class_bookings
  for each row execute function public.notify_booking();

-- 5. Notify a coach when they are assigned to a day (with who is booked so far)
create or replace function public.notify_day_coach()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  rec record;
  msg text := '';
  total int := 0;
begin
  if new.coach_id is null or new.coach_id = auth.uid() then return null; end if;
  if tg_op = 'UPDATE' and old.coach_id is not distinct from new.coach_id then return null; end if;
  for rec in select slot, count(*)::int as c from public.class_bookings
             where class_date = new.class_date group by slot order by slot loop
    msg := msg || public.slot_label(rec.slot) || ' (' || rec.c || ' of 15):' || E'\n'
               || public.attendee_text(new.class_date, rec.slot) || E'\n\n';
    total := total + rec.c;
  end loop;
  if total = 0 then msg := 'No one has reserved yet. You will be notified when members reserve.'; end if;
  insert into public.notifications (user_id, title, body, kind, class_date)
  values (new.coach_id, 'You are the coach on ' || to_char(new.class_date, 'FMDy, Mon FMDD'), trim(trailing E'\n' from msg), 'assigned', new.class_date);
  return null;
end;
$$;
drop trigger if exists day_coaches_notify on public.day_coaches;
create trigger day_coaches_notify after insert or update on public.day_coaches
  for each row execute function public.notify_day_coach();

-- 6. Live updates for the bell (ignore if already added)
do $$ begin
  alter publication supabase_realtime add table public.notifications;
exception when duplicate_object then null; when undefined_object then null; end $$;
