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
