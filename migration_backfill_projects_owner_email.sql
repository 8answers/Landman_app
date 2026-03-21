-- Backfill projects.owner_email for existing projects where it is empty.
-- This helps partner viewers reliably see the admin email in Settings.

ALTER TABLE public.projects
ADD COLUMN IF NOT EXISTS owner_email TEXT;

UPDATE public.projects p
SET owner_email = lower(u.email)
FROM auth.users u
WHERE u.id = p.user_id
  AND coalesce(trim(p.owner_email), '') = ''
  AND coalesce(trim(u.email), '') <> '';
