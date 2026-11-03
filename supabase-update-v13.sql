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
