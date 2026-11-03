-- =====================================================================
-- Run this ONCE, right after the Head Coach has created their account
-- in the app (Create Account). Replace the email below with theirs, then Run.
-- The result should say "Success. 1 row affected" (or UPDATE 1).
-- Do the sign-up yourself first so nobody else can take that email.
-- Run supabase-setup.sql AND supabase-update-v2.sql before this.
-- =====================================================================
update public.profiles
set role = 'head_coach',
    status = 'approved',
    pinned = true,
    board_ok = true,
    photo_url = 'jason-truman.jpg'
where lower(email) = lower('PUT-HEAD-COACH-EMAIL-HERE');
