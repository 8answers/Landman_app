ALTER TABLE public.projects
ADD COLUMN IF NOT EXISTS owner_email TEXT;

CREATE INDEX IF NOT EXISTS idx_projects_owner_email
  ON public.projects(owner_email);
