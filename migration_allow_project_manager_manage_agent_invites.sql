-- Allow active project managers to manage AGENT invites for their project.
-- Admin/owner permissions remain unchanged.
-- This makes agent invite flow functional for both admin and project manager.

DROP POLICY IF EXISTS "Project managers can insert agent invites for their projects"
ON public.project_access_invites;

CREATE POLICY "Project managers can insert agent invites for their projects"
  ON public.project_access_invites
  FOR INSERT
  WITH CHECK (
    role = 'agent'
    AND EXISTS (
      SELECT 1
      FROM public.project_members pm
      WHERE pm.project_id = project_access_invites.project_id
        AND pm.user_id = auth.uid()
        AND pm.status = 'active'
        AND pm.role = 'project_manager'
    )
  );

DROP POLICY IF EXISTS "Project managers can update agent invites for their projects"
ON public.project_access_invites;

CREATE POLICY "Project managers can update agent invites for their projects"
  ON public.project_access_invites
  FOR UPDATE
  USING (
    role = 'agent'
    AND EXISTS (
      SELECT 1
      FROM public.project_members pm
      WHERE pm.project_id = project_access_invites.project_id
        AND pm.user_id = auth.uid()
        AND pm.status = 'active'
        AND pm.role = 'project_manager'
    )
  )
  WITH CHECK (
    role = 'agent'
    AND EXISTS (
      SELECT 1
      FROM public.project_members pm
      WHERE pm.project_id = project_access_invites.project_id
        AND pm.user_id = auth.uid()
        AND pm.status = 'active'
        AND pm.role = 'project_manager'
    )
  );

