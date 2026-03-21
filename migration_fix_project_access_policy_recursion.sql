-- Fix infinite recursion in RLS policies introduced by member-access policy on projects.
-- Run this migration after migration_add_project_access_control.sql.

-- Helper function: evaluate project ownership without triggering policy recursion.
CREATE OR REPLACE FUNCTION public.is_project_owner(target_project_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.projects p
    WHERE p.id = target_project_id
      AND p.user_id = auth.uid()
  );
$$;

REVOKE ALL ON FUNCTION public.is_project_owner(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_project_owner(uuid) TO authenticated;

-- Rebuild invite policies
DROP POLICY IF EXISTS "Owners can manage invites for their projects" ON public.project_access_invites;
DROP POLICY IF EXISTS "Invitees can view their own invites" ON public.project_access_invites;
DROP POLICY IF EXISTS "Invitees can accept their own invites" ON public.project_access_invites;
DROP POLICY IF EXISTS "Owners can select invites for their projects" ON public.project_access_invites;
DROP POLICY IF EXISTS "Owners can insert invites for their projects" ON public.project_access_invites;
DROP POLICY IF EXISTS "Owners can update invites for their projects" ON public.project_access_invites;
DROP POLICY IF EXISTS "Owners can delete invites for their projects" ON public.project_access_invites;

CREATE POLICY "Owners can select invites for their projects"
  ON public.project_access_invites
  FOR SELECT
  USING (
    public.is_project_owner(project_id)
    OR lower(invited_email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );

CREATE POLICY "Owners can insert invites for their projects"
  ON public.project_access_invites
  FOR INSERT
  WITH CHECK (public.is_project_owner(project_id));

CREATE POLICY "Owners can update invites for their projects"
  ON public.project_access_invites
  FOR UPDATE
  USING (
    public.is_project_owner(project_id)
    OR lower(invited_email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  )
  WITH CHECK (
    public.is_project_owner(project_id)
    OR (
      lower(invited_email) = lower(coalesce(auth.jwt() ->> 'email', ''))
      AND accepted_user_id = auth.uid()
    )
  );

CREATE POLICY "Owners can delete invites for their projects"
  ON public.project_access_invites
  FOR DELETE
  USING (public.is_project_owner(project_id));

-- Rebuild project member policies
DROP POLICY IF EXISTS "Owners can manage project members" ON public.project_members;
DROP POLICY IF EXISTS "Users can read own project membership" ON public.project_members;
DROP POLICY IF EXISTS "Invitees can upsert own membership" ON public.project_members;
DROP POLICY IF EXISTS "Invitees can update own membership" ON public.project_members;
DROP POLICY IF EXISTS "Owners and members can view project_members" ON public.project_members;
DROP POLICY IF EXISTS "Owners and accepted invitees can insert project_members" ON public.project_members;
DROP POLICY IF EXISTS "Owners and self can update project_members" ON public.project_members;
DROP POLICY IF EXISTS "Owners can delete project_members" ON public.project_members;

-- IMPORTANT:
-- Keep SELECT on project_members free of any projects-table reference.
-- projects SELECT policy queries project_members; if project_members SELECT also
-- queries projects (directly or via helper), recursion happens.
CREATE POLICY "Users can read own project membership"
  ON public.project_members
  FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY "Owners and accepted invitees can insert project_members"
  ON public.project_members
  FOR INSERT
  WITH CHECK (
    public.is_project_owner(project_id)
    OR (
      user_id = auth.uid()
      AND EXISTS (
        SELECT 1
        FROM public.project_access_invites i
        WHERE i.project_id = project_members.project_id
          AND lower(i.invited_email) = lower(coalesce(auth.jwt() ->> 'email', ''))
          AND i.status = 'accepted'
      )
    )
  );

CREATE POLICY "Owners can update project_members"
  ON public.project_members
  FOR UPDATE
  USING (public.is_project_owner(project_id))
  WITH CHECK (public.is_project_owner(project_id));

CREATE POLICY "Owners can delete project_members"
  ON public.project_members
  FOR DELETE
  USING (public.is_project_owner(project_id));

CREATE POLICY "Users can update own project_members row"
  ON public.project_members
  FOR UPDATE
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- Recreate projects member-read policy after member-policy fixes.
DROP POLICY IF EXISTS "Members can view projects they belong to" ON public.projects;
CREATE POLICY "Members can view projects they belong to"
  ON public.projects
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.project_members pm
      WHERE pm.project_id = projects.id
        AND pm.user_id = auth.uid()
        AND pm.status = 'active'
    )
  );
