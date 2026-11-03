-- =====================================================================
-- CrossFit Cainta - ALL UPDATES IN ONE FILE  (v2 to v17)
-- Run this ONCE in Supabase > SQL Editor > New query. It is safe to run
-- even if you already ran some of the updates before: every step checks
-- first. Run it AFTER supabase-setup.sql.
-- If Supabase shows a "destructive operation" warning, that is normal
-- (the file replaces old rules and views with newer ones). Press Run.
-- =====================================================================


-- ############################################################
-- ## supabase-update-v2.sql
-- ############################################################
-- =====================================================================
-- CrossFit Cainta - UPDATE v2  (run ONCE, AFTER supabase-setup.sql)
-- Paste the WHOLE file into Supabase > SQL Editor > New query > Run.
-- Safe to run more than once. Adds: board consent + private board,
-- real class bookings (max 15), and names that cannot be faked.
-- =====================================================================

-- 1. Board consent column
alter table public.profiles add column if not exists board_ok boolean not null default false;

-- 2. New sign-ups can tick "allow board" (still never choose their own role)
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name, bio, board_ok)
  values (
    new.id,
    new.email,
    coalesce(nullif(trim(new.raw_user_meta_data->>'full_name'), ''), split_part(new.email, '@', 1)),
    coalesce(new.raw_user_meta_data->>'bio', ''),
    coalesce(new.raw_user_meta_data->>'board_ok', '') = 'true'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

-- 3. Public board: only approved + pinned + consenting, and only id, name, role, photo
drop view if exists public.public_board;
create view public.public_board as
  select id, full_name, role, photo_url
  from public.profiles
  where status = 'approved' and pinned = true and board_ok = true;
grant select on public.public_board to anon, authenticated;

-- The Head Coach keeps their place on the board
update public.profiles set board_ok = true where role = 'head_coach';

-- 4. Names on videos and notes always come from the account
create or replace function public.fill_form_check_name()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.member_name := coalesce((select full_name from public.profiles where id = new.owner), '');
  return new;
end;
$$;
drop trigger if exists form_checks_fill_name on public.form_checks;
create trigger form_checks_fill_name before insert on public.form_checks
  for each row execute function public.fill_form_check_name();

create or replace function public.fill_form_note_author()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  select full_name, role into new.author_name, new.author_role from public.profiles where id = new.author;
  return new;
end;
$$;
drop trigger if exists form_notes_fill_author on public.form_notes;
create trigger form_notes_fill_author before insert on public.form_notes
  for each row execute function public.fill_form_note_author();

-- 5. Class bookings (max 15 per class)
create table if not exists public.class_bookings (
  id          uuid primary key default gen_random_uuid(),
  owner       uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  member_name text not null default '',
  class_date  date not null,
  slot        text not null,
  created_at  timestamptz not null default now(),
  unique (owner, class_date, slot)
);
create index if not exists class_bookings_class_idx on public.class_bookings (class_date, slot);
alter table public.class_bookings enable row level security;

create or replace function public.check_booking()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  today date := (now() at time zone 'Asia/Manila')::date;
  dow   int  := extract(dow from new.class_date);
  taken int;
begin
  new.member_name := coalesce((select full_name from public.profiles where id = new.owner), '');
  if not ((new.slot in ('evening1', 'evening2') and dow in (1, 2, 3, 5))
       or (new.slot = 'hybrid'   and dow = 4)
       or (new.slot = 'saturday' and dow = 6)) then
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
drop trigger if exists class_bookings_check on public.class_bookings;
create trigger class_bookings_check before insert on public.class_bookings
  for each row execute function public.check_booking();

drop policy if exists "bookings: read own or coach" on public.class_bookings;
create policy "bookings: read own or coach" on public.class_bookings
  for select to authenticated using (owner = auth.uid() or public.is_coach());

drop policy if exists "bookings: approved members add own" on public.class_bookings;
create policy "bookings: approved members add own" on public.class_bookings
  for insert to authenticated with check (owner = auth.uid() and public.is_approved());

drop policy if exists "bookings: delete own or coach" on public.class_bookings;
create policy "bookings: delete own or coach" on public.class_bookings
  for delete to authenticated using (owner = auth.uid() or public.is_coach());

-- Everyone can see how many spots are taken (counts only, never names)
create or replace function public.class_counts(p_from date, p_to date)
returns table (class_date date, slot text, taken integer)
language sql stable security definer set search_path = public as $$
  select b.class_date, b.slot, count(*)::int
  from public.class_bookings b
  where b.class_date between p_from and p_to
  group by b.class_date, b.slot;
$$;
revoke all on function public.class_counts(date, date) from public;
grant execute on function public.class_counts(date, date) to anon, authenticated;


-- ############################################################
-- ## supabase-update-v3.sql
-- ############################################################
-- =====================================================================
-- CrossFit Cainta - UPDATE v3  (run ONCE, AFTER supabase-update-v2.sql)
-- Adds: Workout of the Day, Announcements, PR tracker + opt-in leaderboard.
-- Safe to run more than once.
-- =====================================================================
alter table public.profiles add column if not exists lb_ok boolean not null default false;

-- WOD: everyone can read, coaches write
create table if not exists public.wods (
  id uuid primary key default gen_random_uuid(),
  wod_date date not null unique,
  title text not null default '', warmup text not null default '', strength text not null default '',
  wod text not null default '', scaling text not null default '',
  created_by uuid default auth.uid(), created_at timestamptz not null default now()
);
alter table public.wods enable row level security;
drop policy if exists "wods: anyone reads" on public.wods;
create policy "wods: anyone reads" on public.wods for select to anon, authenticated using (true);
drop policy if exists "wods: coaches add" on public.wods;
create policy "wods: coaches add" on public.wods for insert to authenticated with check (public.is_coach());
drop policy if exists "wods: coaches edit" on public.wods;
create policy "wods: coaches edit" on public.wods for update to authenticated using (public.is_coach()) with check (public.is_coach());
drop policy if exists "wods: coaches delete" on public.wods;
create policy "wods: coaches delete" on public.wods for delete to authenticated using (public.is_coach());

-- Announcements: everyone can read, only the Head Coach writes
create table if not exists public.announcements (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) <= 80),
  body text not null check (char_length(body) <= 600),
  created_by uuid default auth.uid(), created_at timestamptz not null default now()
);
alter table public.announcements enable row level security;
drop policy if exists "announcements: anyone reads" on public.announcements;
create policy "announcements: anyone reads" on public.announcements for select to anon, authenticated using (true);
drop policy if exists "announcements: head coach adds" on public.announcements;
create policy "announcements: head coach adds" on public.announcements for insert to authenticated with check (public.is_head_coach());
drop policy if exists "announcements: head coach deletes" on public.announcements;
create policy "announcements: head coach deletes" on public.announcements for delete to authenticated using (public.is_head_coach());

-- PRs: private to each member (weights stored in kg, times in seconds)
create table if not exists public.prs (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  movement text not null, kind text not null check (kind in ('weight', 'time', 'reps')),
  value numeric not null check (value > 0),
  achieved_on date not null default current_date,
  note text not null default '' check (char_length(note) <= 80),
  created_at timestamptz not null default now()
);
create index if not exists prs_owner_idx on public.prs (owner, movement);
alter table public.prs enable row level security;
drop policy if exists "prs: read own" on public.prs;
create policy "prs: read own" on public.prs for select to authenticated using (owner = auth.uid());
drop policy if exists "prs: add own" on public.prs;
create policy "prs: add own" on public.prs for insert to authenticated with check (owner = auth.uid() and public.is_approved());
drop policy if exists "prs: delete own" on public.prs;
create policy "prs: delete own" on public.prs for delete to authenticated using (owner = auth.uid());

-- Leaderboard: best result per member, ONLY for approved members who opted in
create or replace function public.leaderboard(p_movement text)
returns table (member_name text, value numeric)
language sql stable security definer set search_path = public as $$
  select p.full_name,
         case when x.kind = 'time' then min(x.value) else max(x.value) end
  from public.prs x join public.profiles p on p.id = x.owner
  where x.movement = p_movement and p.status = 'approved' and p.lb_ok = true and public.is_approved()
  group by p.id, p.full_name, x.kind
  order by case when x.kind = 'time' then min(x.value) else -max(x.value) end
  limit 20;
$$;
revoke all on function public.leaderboard(text) from public;
grant execute on function public.leaderboard(text) to authenticated;


-- ############################################################
-- ## supabase-update-v4.sql
-- ############################################################
-- =====================================================================
-- CrossFit Cainta - UPDATE v4  (run ONCE, AFTER supabase-update-v3.sql)
-- Adds: membership dates, online waiver, coach profiles, photo gallery.
-- Safe to run more than once.
-- =====================================================================

-- Membership dates (only the Head Coach can change them)
alter table public.profiles add column if not exists membership_plan text not null default '';
alter table public.profiles add column if not exists membership_ends date;

create or replace function public.protect_profile()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_head_coach() then
    new.id := old.id; new.email := old.email; new.role := old.role;
    new.status := old.status; new.pinned := old.pinned;
    new.membership_plan := old.membership_plan; new.membership_ends := old.membership_ends;
  end if;
  return new;
end;
$$;

-- Waiver: members sign once, nobody can edit or delete a signature
create table if not exists public.waivers (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  signed_name text not null check (char_length(trim(signed_name)) >= 3),
  version text not null,
  signed_at timestamptz not null default now(),
  unique (owner, version)
);
alter table public.waivers enable row level security;
drop policy if exists "waivers: read own or head coach" on public.waivers;
create policy "waivers: read own or head coach" on public.waivers for select to authenticated using (owner = auth.uid() or public.is_head_coach());
drop policy if exists "waivers: sign own" on public.waivers;
create policy "waivers: sign own" on public.waivers for insert to authenticated with check (owner = auth.uid() and public.is_approved());

-- Reserving a class now needs a signed waiver
create or replace function public.check_booking()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  today date := (now() at time zone 'Asia/Manila')::date;
  dow   int  := extract(dow from new.class_date);
  taken int;
begin
  new.member_name := coalesce((select full_name from public.profiles where id = new.owner), '');
  if not exists (select 1 from public.waivers where owner = new.owner) then
    raise exception 'Please sign the waiver first (More > Waiver)';
  end if;
  if not ((new.slot in ('evening1', 'evening2') and dow in (1, 2, 3, 5))
       or (new.slot = 'hybrid' and dow = 4) or (new.slot = 'saturday' and dow = 6)) then
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

-- Coach profiles (public page shows coaches who allowed it in My Profile)
create table if not exists public.coach_bios (
  id uuid primary key references public.profiles(id) on delete cascade,
  bio text not null default '' check (char_length(bio) <= 600),
  certs text not null default '' check (char_length(certs) <= 300)
);
alter table public.coach_bios enable row level security;
drop policy if exists "coach_bios: coach reads own" on public.coach_bios;
create policy "coach_bios: coach reads own" on public.coach_bios for select to authenticated using (id = auth.uid() and public.is_coach());
drop policy if exists "coach_bios: coach adds own" on public.coach_bios;
create policy "coach_bios: coach adds own" on public.coach_bios for insert to authenticated with check (id = auth.uid() and public.is_coach());
drop policy if exists "coach_bios: coach edits own" on public.coach_bios;
create policy "coach_bios: coach edits own" on public.coach_bios for update to authenticated using (id = auth.uid() and public.is_coach()) with check (id = auth.uid() and public.is_coach());

drop view if exists public.public_coaches;
create view public.public_coaches as
  select p.id, p.full_name, p.role, p.photo_url, coalesce(b.bio, '') as bio, coalesce(b.certs, '') as certs
  from public.profiles p left join public.coach_bios b on b.id = p.id
  where p.status = 'approved' and p.role in ('coach', 'head_coach') and p.board_ok = true;
grant select on public.public_coaches to anon, authenticated;

-- Events & photos gallery: everyone can see, coaches add and delete
create table if not exists public.gallery (
  id uuid primary key default gen_random_uuid(),
  title text not null default '' check (char_length(title) <= 80),
  photo_path text not null,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
alter table public.gallery enable row level security;
drop policy if exists "gallery: anyone reads" on public.gallery;
create policy "gallery: anyone reads" on public.gallery for select to anon, authenticated using (true);
drop policy if exists "gallery: coaches add" on public.gallery;
create policy "gallery: coaches add" on public.gallery for insert to authenticated with check (public.is_coach());
drop policy if exists "gallery: coaches delete" on public.gallery;
create policy "gallery: coaches delete" on public.gallery for delete to authenticated using (public.is_coach());

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('gallery', 'gallery', true, 3145728, array['image/*'])
on conflict (id) do update set public = true, file_size_limit = 3145728, allowed_mime_types = array['image/*'];

drop policy if exists "gallery files: coaches upload" on storage.objects;
create policy "gallery files: coaches upload" on storage.objects for insert to authenticated with check (bucket_id = 'gallery' and public.is_coach());
drop policy if exists "gallery files: coaches delete" on storage.objects;
create policy "gallery files: coaches delete" on storage.objects for delete to authenticated using (bucket_id = 'gallery' and public.is_coach());


-- ############################################################
-- ## supabase-update-v5.sql
-- ############################################################
-- =====================================================================
-- CrossFit Cainta - UPDATE v5  (run ONCE, AFTER supabase-update-v4.sql)
-- Lets coaches attach a whiteboard photo to the Workout of the Day.
-- Safe to run more than once.
-- =====================================================================
alter table public.wods add column if not exists photo_path text not null default '';


-- ############################################################
-- ## supabase-update-v6.sql
-- ############################################################
-- =====================================================================
-- CrossFit Cainta - UPDATE v6  (run ONCE, AFTER supabase-update-v5.sql)
-- Members who allowed the Members Board appear on it automatically.
-- Safe to run more than once.
-- =====================================================================
create or replace function public.protect_profile()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_head_coach() then
    new.id := old.id; new.email := old.email; new.role := old.role;
    new.status := old.status; new.pinned := old.pinned;
    new.membership_plan := old.membership_plan; new.membership_ends := old.membership_ends;
    -- an approved member who turns the board on is pinned automatically
    if new.board_ok and not old.board_ok and old.status = 'approved' then new.pinned := true; end if;
  end if;
  return new;
end;
$$;

-- Pin everyone who already approved + allowed the board
update public.profiles set pinned = true where status = 'approved' and board_ok = true and pinned = false;


-- ############################################################
-- ## supabase-update-v7.sql
-- ############################################################
-- =====================================================================
-- CrossFit Cainta - UPDATE v7  (run ONCE, AFTER supabase-update-v6.sql)
-- Membership: plan, start date, months, Comp Camp add-on, next payment date.
-- Safe to run more than once.
-- =====================================================================
alter table public.profiles add column if not exists membership_start date;
alter table public.profiles add column if not exists membership_months integer not null default 1 check (membership_months between 1 and 24);
alter table public.profiles add column if not exists membership_addon boolean not null default false;
alter table public.profiles add column if not exists membership_next_payment date;

-- Only the Head Coach can change membership details (members cannot edit their own)
create or replace function public.protect_profile()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_head_coach() then
    new.id := old.id; new.email := old.email; new.role := old.role;
    new.status := old.status; new.pinned := old.pinned;
    new.membership_plan := old.membership_plan; new.membership_ends := old.membership_ends;
    new.membership_start := old.membership_start; new.membership_months := old.membership_months;
    new.membership_addon := old.membership_addon; new.membership_next_payment := old.membership_next_payment;
    -- an approved member who turns the board on is pinned automatically
    if new.board_ok and not old.board_ok and old.status = 'approved' then new.pinned := true; end if;
  end if;
  return new;
end;
$$;


-- ############################################################
-- ## supabase-update-v8.sql
-- ############################################################
-- =====================================================================
-- CrossFit Cainta - UPDATE v8  (run ONCE, AFTER supabase-update-v7.sql)
-- Events / Comps / Albums: the Head Coach adds them, everyone can see them.
-- They show on the Home carousel, the Events page and the calendar.
-- Photos use the "gallery" storage bucket created in update v4.
-- Safe to run more than once.
-- =====================================================================
create table if not exists public.events (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(trim(title)) between 1 and 80),
  kind text not null default 'comp' check (kind in ('comp', 'event', 'album')),
  event_date date,
  end_date date,
  location text not null default '' check (char_length(location) <= 120),
  details text not null default '' check (char_length(details) <= 800),
  photo_path text not null default '',
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  check (end_date is null or event_date is null or end_date >= event_date)
);
alter table public.events enable row level security;
drop policy if exists "events: anyone reads" on public.events;
create policy "events: anyone reads" on public.events for select to anon, authenticated using (true);
drop policy if exists "events: head coach adds" on public.events;
create policy "events: head coach adds" on public.events for insert to authenticated with check (public.is_head_coach());
drop policy if exists "events: head coach edits" on public.events;
create policy "events: head coach edits" on public.events for update to authenticated using (public.is_head_coach()) with check (public.is_head_coach());
drop policy if exists "events: head coach deletes" on public.events;
create policy "events: head coach deletes" on public.events for delete to authenticated using (public.is_head_coach());

create table if not exists public.event_photos (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  photo_path text not null,
  created_at timestamptz not null default now()
);
create index if not exists event_photos_event_idx on public.event_photos (event_id);
alter table public.event_photos enable row level security;
drop policy if exists "event_photos: anyone reads" on public.event_photos;
create policy "event_photos: anyone reads" on public.event_photos for select to anon, authenticated using (true);
drop policy if exists "event_photos: head coach adds" on public.event_photos;
create policy "event_photos: head coach adds" on public.event_photos for insert to authenticated with check (public.is_head_coach());
drop policy if exists "event_photos: head coach deletes" on public.event_photos;
create policy "event_photos: head coach deletes" on public.event_photos for delete to authenticated using (public.is_head_coach());


-- ############################################################
-- ## supabase-update-v9.sql
-- ############################################################
-- =====================================================================
-- CrossFit Cainta - UPDATE v9  (run ONCE, AFTER supabase-update-v8.sql)
-- Profile: birthday. Members Board: each member designs their own card
-- (paper colour + up to 6 emoji stickers). Safe to run more than once.
-- =====================================================================
alter table public.profiles add column if not exists birthday date;
alter table public.profiles add column if not exists board_design jsonb not null default '{}'::jsonb;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_board_design_size') then
    alter table public.profiles add constraint profiles_board_design_size check (octet_length(board_design::text) <= 1500);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'profiles_birthday_range') then
    alter table public.profiles add constraint profiles_birthday_range check (birthday is null or birthday between date '1900-01-01' and date '2100-01-01');
  end if;
end $$;

-- Public board now also returns the card design (still no email, birthday or phone)
drop view if exists public.public_board;
create view public.public_board as
  select id, full_name, role, photo_url, board_design
  from public.profiles
  where status = 'approved' and pinned = true and board_ok = true;
grant select on public.public_board to anon, authenticated;


-- ############################################################
-- ## supabase-update-v10.sql
-- ############################################################
-- =====================================================================
-- CrossFit Cainta - UPDATE v10  (run ONCE, AFTER supabase-update-v9.sql)
-- Albums with photos AND videos (like Facebook), unlimited stickers on
-- board cards, and personal cork board decorations.
-- Safe to run more than once.
-- =====================================================================
alter table public.profiles add column if not exists board_decor jsonb not null default '{}'::jsonb;
alter table public.profiles drop constraint if exists profiles_board_design_size;
alter table public.profiles add constraint profiles_board_design_size check (octet_length(board_design::text) <= 8000);
alter table public.profiles drop constraint if exists profiles_board_decor_size;
alter table public.profiles add constraint profiles_board_decor_size check (octet_length(board_decor::text) <= 12000);

create table if not exists public.albums (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(trim(title)) between 1 and 80),
  description text not null default '' check (char_length(description) <= 300),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
alter table public.albums enable row level security;
drop policy if exists "albums: anyone reads" on public.albums;
create policy "albums: anyone reads" on public.albums for select to anon, authenticated using (true);
drop policy if exists "albums: coaches add" on public.albums;
create policy "albums: coaches add" on public.albums for insert to authenticated with check (public.is_coach());
drop policy if exists "albums: coaches edit" on public.albums;
create policy "albums: coaches edit" on public.albums for update to authenticated using (public.is_coach()) with check (public.is_coach());
drop policy if exists "albums: coaches delete" on public.albums;
create policy "albums: coaches delete" on public.albums for delete to authenticated using (public.is_coach());

create table if not exists public.album_media (
  id uuid primary key default gen_random_uuid(),
  album_id uuid not null references public.albums(id) on delete cascade,
  path text not null,
  kind text not null check (kind in ('image', 'video')),
  created_at timestamptz not null default now()
);
create index if not exists album_media_album_idx on public.album_media (album_id);
alter table public.album_media enable row level security;
drop policy if exists "album_media: anyone reads" on public.album_media;
create policy "album_media: anyone reads" on public.album_media for select to anon, authenticated using (true);
drop policy if exists "album_media: coaches add" on public.album_media;
create policy "album_media: coaches add" on public.album_media for insert to authenticated with check (public.is_coach());
drop policy if exists "album_media: coaches delete" on public.album_media;
create policy "album_media: coaches delete" on public.album_media for delete to authenticated using (public.is_coach());

-- Public bucket for album photos and videos (50 MB per file)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('albums', 'albums', true, 52428800, array['image/*', 'video/*'])
on conflict (id) do update set public = true, file_size_limit = 52428800, allowed_mime_types = array['image/*', 'video/*'];

drop policy if exists "album files: coaches upload" on storage.objects;
create policy "album files: coaches upload" on storage.objects for insert to authenticated with check (bucket_id = 'albums' and public.is_coach());
drop policy if exists "album files: coaches delete" on storage.objects;
create policy "album files: coaches delete" on storage.objects for delete to authenticated using (bucket_id = 'albums' and public.is_coach());


-- ############################################################
-- ## supabase-update-v11.sql
-- ############################################################
-- =====================================================================
-- CrossFit Cainta - UPDATE v11  (run ONCE, AFTER supabase-update-v10.sql)
-- Allows bigger, sharper event / WOD pictures (10 MB per picture).
-- Album photos and videos keep their 50 MB limit (the free plan maximum).
-- Safe to run more than once.
-- =====================================================================
update storage.buckets set file_size_limit = 10485760 where id = 'gallery';


-- ############################################################
-- ## supabase-update-v12.sql
-- ############################################################
-- =====================================================================
-- CrossFit Cainta - UPDATE v12  (run ONCE, AFTER supabase-update-v11.sql)
-- Approved members can create albums and add photos / videos to any album.
-- Members can rename / delete only their OWN albums and uploads;
-- coaches can still manage everything. Safe to run more than once.
-- =====================================================================
alter table public.album_media add column if not exists owner uuid default auth.uid() references public.profiles(id) on delete set null;

-- Albums
drop policy if exists "albums: coaches add" on public.albums;
drop policy if exists "albums: members add" on public.albums;
create policy "albums: members add" on public.albums for insert to authenticated
  with check (public.is_approved() and created_by = auth.uid());
drop policy if exists "albums: coaches edit" on public.albums;
drop policy if exists "albums: owner or coach edit" on public.albums;
create policy "albums: owner or coach edit" on public.albums for update to authenticated
  using (created_by = auth.uid() or public.is_coach()) with check (created_by = auth.uid() or public.is_coach());
drop policy if exists "albums: coaches delete" on public.albums;
drop policy if exists "albums: owner or coach delete" on public.albums;
create policy "albums: owner or coach delete" on public.albums for delete to authenticated
  using (created_by = auth.uid() or public.is_coach());

-- Photos and videos inside albums
drop policy if exists "album_media: coaches add" on public.album_media;
drop policy if exists "album_media: members add" on public.album_media;
create policy "album_media: members add" on public.album_media for insert to authenticated
  with check (public.is_approved() and owner = auth.uid());
drop policy if exists "album_media: coaches delete" on public.album_media;
drop policy if exists "album_media: owner or coach delete" on public.album_media;
create policy "album_media: owner or coach delete" on public.album_media for delete to authenticated
  using (owner = auth.uid() or public.is_coach()
         or exists (select 1 from public.albums a where a.id = album_id and a.created_by = auth.uid()));

-- Storage: each member can only write inside their own folder of the albums bucket
drop policy if exists "album files: coaches upload" on storage.objects;
drop policy if exists "album files: members upload" on storage.objects;
create policy "album files: members upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'albums' and public.is_approved() and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "album files: coaches delete" on storage.objects;
drop policy if exists "album files: owner or coach delete" on storage.objects;
create policy "album files: owner or coach delete" on storage.objects for delete to authenticated
  using (bucket_id = 'albums' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_coach()));


-- ## supabase-update-v13.sql
-- =====================================================================
-- CrossFit Cainta - UPDATE v13  (run ONCE, AFTER supabase-update-v12.sql)
-- Any approved member or coach can rename / delete ANY album and
-- remove ANY photo or video. Safe to run more than once.
-- =====================================================================
drop policy if exists "albums: owner or coach edit" on public.albums;
drop policy if exists "albums: approved edit" on public.albums;
create policy "albums: approved edit" on public.albums for update to authenticated
  using (public.is_approved()) with check (public.is_approved());
drop policy if exists "albums: owner or coach delete" on public.albums;
drop policy if exists "albums: approved delete" on public.albums;
create policy "albums: approved delete" on public.albums for delete to authenticated
  using (public.is_approved());

drop policy if exists "album_media: owner or coach delete" on public.album_media;
drop policy if exists "album_media: approved delete" on public.album_media;
create policy "album_media: approved delete" on public.album_media for delete to authenticated
  using (public.is_approved());

drop policy if exists "album files: owner or coach delete" on storage.objects;
drop policy if exists "album files: approved delete" on storage.objects;
create policy "album files: approved delete" on storage.objects for delete to authenticated
  using (bucket_id = 'albums' and public.is_approved());


-- ## supabase-update-v14.sql
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


-- ## supabase-update-v15.sql
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


-- ## supabase-update-v16.sql
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


-- ## supabase-update-v17.sql
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
