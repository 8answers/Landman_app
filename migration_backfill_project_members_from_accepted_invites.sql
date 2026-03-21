-- Backfill project_members rows from accepted invites.
-- Fixes cases where invite is accepted but membership row was not created,
-- which blocks RLS reads (e.g. empty Dashboard for invited users).

INSERT INTO public.project_members (
  project_id,
  user_id,
  invited_email,
  role,
  status,
  invited_at,
  accepted_at,
  created_at,
  updated_at
)
SELECT
  i.project_id,
  i.accepted_user_id,
  lower(trim(i.invited_email)),
  i.role,
  'active',
  coalesce(i.requested_at, now()),
  coalesce(i.accepted_at, i.updated_at, now()),
  now(),
  now()
FROM public.project_access_invites i
WHERE i.status = 'accepted'
  AND i.accepted_user_id IS NOT NULL
  AND coalesce(trim(i.invited_email), '') <> ''
ON CONFLICT (project_id, user_id)
DO UPDATE SET
  invited_email = coalesce(nullif(trim(project_members.invited_email), ''), excluded.invited_email),
  role = excluded.role,
  status = 'active',
  accepted_at = coalesce(project_members.accepted_at, excluded.accepted_at),
  updated_at = now();
