-- =====================================================================
-- CrossFit Cainta - UPDATE v17  (run ONCE, AFTER supabase-update-v16.sql)
-- Holiday schedule: on a holiday the classes are
--      10:30 AM  CrossFit      and      4:00 PM  Hybrid
-- Holidays live in a table. Philippine 2026-2027 holidays are pre-filled;
-- the Head Coach can add or remove any date from the Schedule page.
-- Safe to run more than once.
-- =====================================================================
create table if not exists public.holidays (
  holiday_date date primary key,
  name         text not null check (char_length(name) between 1 and 80)
);
alter table public.holidays enable row level security;
drop policy if exists "holidays: everyone reads" on public.holidays;
create policy "holidays: everyone reads" on public.holidays for select to anon, authenticated using (true);
drop policy if exists "holidays: head coach adds" on public.holidays;
create policy "holidays: head coach adds" on public.holidays for insert to authenticated with check (public.is_head_coach());
drop policy if exists "holidays: head coach edits" on public.holidays;
create policy "holidays: head coach edits" on public.holidays for update to authenticated using (public.is_head_coach()) with check (public.is_head_coach());
drop policy if exists "holidays: head coach deletes" on public.holidays;
create policy "holidays: head coach deletes" on public.holidays for delete to authenticated using (public.is_head_coach());
grant select on public.holidays to anon, authenticated;

insert into public.holidays (holiday_date, name) values
  ('2026-11-02', 'All Souls'' Day'),
  ('2026-11-30', 'Bonifacio Day'),
  ('2026-12-08', 'Feast of the Immaculate Conception'),
  ('2026-12-24', 'Christmas Eve'),
  ('2026-12-25', 'Christmas Day'),
  ('2026-12-30', 'Rizal Day'),
  ('2026-12-31', 'Last Day of the Year'),
  ('2027-01-01', 'New Year''s Day'),
  ('2027-02-06', 'Chinese New Year'),
  ('2027-03-25', 'Maundy Thursday'),
  ('2027-03-26', 'Good Friday'),
  ('2027-03-27', 'Black Saturday'),
  ('2027-04-09', 'Araw ng Kagitingan'),
  ('2027-05-01', 'Labor Day'),
  ('2027-06-12', 'Independence Day'),
  ('2027-08-21', 'Ninoy Aquino Day'),
  ('2027-08-30', 'National Heroes Day'),
  ('2027-11-01', 'All Saints'' Day'),
  ('2027-11-02', 'All Souls'' Day'),
  ('2027-11-30', 'Bonifacio Day'),
  ('2027-12-08', 'Feast of the Immaculate Conception'),
  ('2027-12-24', 'Christmas Eve'),
  ('2027-12-25', 'Christmas Day'),
  ('2027-12-30', 'Rizal Day'),
  ('2027-12-31', 'Last Day of the Year')
on conflict (holiday_date) do nothing;

create or replace function public.is_holiday(d date)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.holidays where holiday_date = d);
$$;
grant execute on function public.is_holiday(date) to anon, authenticated;

-- Which classes can be booked: holiday classes on holidays, the normal week otherwise
create or replace function public.slot_runs(d date, s text)
returns boolean language sql stable security definer set search_path = public as $$
  select case
    when public.is_holiday(d) then s in ('holiday_cf', 'holiday_hybrid')
    else (s in ('evening1', 'evening2') and extract(dow from d) in (1, 2, 3, 5))
      or (s = 'hybrid'   and extract(dow from d) = 4)
      or (s = 'saturday' and extract(dow from d) = 6)
  end;
$$;

create or replace function public.check_booking()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  today date := (now() at time zone 'Asia/Manila')::date;
  taken int;
begin
  new.member_name := coalesce((select full_name from public.profiles where id = new.owner), '');
  if not exists (select 1 from public.waivers where owner = new.owner) then
    raise exception 'Please sign the waiver first (More > Waiver)';
  end if;
  if not public.slot_runs(new.class_date, new.slot) then
    raise exception 'That class does not run on this day';
  end if;
  if new.class_date < today then raise exception 'That class date has already passed'; end if;
  if new.class_date > today + 60 then raise exception 'You can only book up to 60 days ahead'; end if;
  perform pg_advisory_xact_lock(hashtext(new.class_date::text || new.slot));
  select count(*) into taken from public.class_bookings where class_date = new.class_date and slot = new.slot;
  if taken >= 15 then raise exception 'This class is full'; end if;
  return new;
end;
$$;

create or replace function public.check_slot_coach()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not public.slot_runs(new.class_date, new.slot) then
    raise exception 'That class does not run on this day';
  end if;
  select full_name into new.coach_name from public.profiles
    where id = new.coach_id and status = 'approved' and role in ('coach', 'head_coach');
  if not found then raise exception 'Only approved coaches can be the coach'; end if;
  return new;
end;
$$;

create or replace function public.slot_label(p_slot text)
returns text language sql immutable as $$
  select case p_slot
    when 'evening1'       then '5:30 PM class'
    when 'evening2'       then '7:00 PM class'
    when 'hybrid'         then '6:00 PM Hybrid class'
    when 'saturday'       then '10:30 AM Saturday class'
    when 'holiday_cf'     then '10:30 AM Holiday CrossFit class'
    when 'holiday_hybrid' then '4:00 PM Holiday Hybrid class'
    else p_slot end;
$$;
