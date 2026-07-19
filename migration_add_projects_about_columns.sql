-- Persist project About details used by Data Entry and reports.
-- Safe/idempotent for existing Supabase projects.

ALTER TABLE public.projects
ADD COLUMN IF NOT EXISTS project_address TEXT DEFAULT '',
ADD COLUMN IF NOT EXISTS google_maps_link TEXT DEFAULT '';

NOTIFY pgrst, 'reload schema';
