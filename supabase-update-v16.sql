-- =====================================================================
-- CrossFit Cainta - UPDATE v16  (run ONCE, AFTER supabase-update-v15.sql)
-- Coaches tap a class time on the Schedule to say "I'm the coach", and tap
-- again to cancel if they can't make it. Everyone sees the coach name.
-- Coaches who claim a class get notified (with the member list) when members
-- reserve or cancel. Safe to run more than once.
-- =====================================================================
create table if not exists public.slot_coaches (
  class_date date not null,
  slot       text not null,
  coach_id   uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  coach_name text not null default '',
  created_at timestamptz not null default now(),
  primary key (class_date, slot, coach_id)
);
alter table public.slot_coaches enable row level security;

drop policy if exists "slot_coaches: everyone reads" on public.slot_coaches;
create policy "slot_coaches: everyone reads" on public.slot_coaches for select to anon, authenticated using (true);
drop policy if exists "slot_coaches: coach claims for self" on public.slot_coaches;
create policy "slot_coaches: coach claims for self" on public.slot_coaches for insert to authenticated
  with check (coach_id = auth.uid() and public.is_coach());
drop policy if exists "slot_coaches: coach cancels own" on public.slot_coaches;
create policy "slot_coaches: coach cancels own" on public.slot_coaches for delete to authenticated
  using ((coach_id = auth.uid() and public.is_coach()) or public.is_head_coach());
grant select on public.slot_coaches to anon, authenticated;

create or replace function public.check_slot_coach()
returns trigger language plpgsql security definer set search_path = public as $$
declare dow int := extract(dow from new.class_date);
begin
  if not ((new.slot in ('evening1', 'evening2') and dow in (1, 2, 3, 5))
       or (new.slot = 'hybrid'   and dow = 4)
       or (new.slot = 'saturday' and dow = 6)) then
    raise exception 'That class does not run on this day';
  end if;
  select full_name into new.coach_name from public.profiles
    where id = new.coach_id and status = 'approved' and role in ('coach', 'head_coach');
  if not found then raise exception 'Only approved coaches can be the coach'; end if;
  return new;
end;
$$;
drop trigger if exists slot_coaches_check on public.slot_coaches;
create trigger slot_coaches_check before insert on public.slot_coaches
  for each row execute function public.check_slot_coach();

-- Notify every coach who claimed that class when a member reserves / cancels
create or replace function public.notify_booking()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  r public.class_bookings;
  c record;
  n int;
  d text;
  verb text;
  lst text;
begin
  if tg_op = 'INSERT' then r := new; verb := 'reserved'; else r := old; verb := 'cancelled'; end if;
  select count(*) into n from public.class_bookings where class_date = r.class_date and slot = r.slot;
  d := to_char(r.class_date, 'FMDy, Mon FMDD');
  lst := public.attendee_text(r.class_date, r.slot);
  for c in select coach_id from public.slot_coaches
           where class_date = r.class_date and slot = r.slot and coach_id <> r.owner loop
    insert into public.notifications (user_id, title, body, kind, class_date)
    values (
      c.coach_id,
      case when verb = 'reserved' then 'New reservation - ' else 'Cancelled - ' end || public.slot_label(r.slot),
      r.member_name || ' ' || verb || ' the ' || public.slot_label(r.slot) || ' on ' || d || E'.\n\n'
        || 'Attending (' || n || ' of 15):' || E'\n' || lst,
      'booking',
      r.class_date
    );
  end loop;
  return null;
end;
$$;

-- The old "coach of the day" assignment is replaced by the tap-to-claim above
drop trigger if exists day_coaches_notify on public.day_coaches;
