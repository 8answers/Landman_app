-- Ensure non-owner Admin / Project Manager members can view project access
-- invite rows for their project, so Access Control stays in sync for all admins.

begin;

drop policy if exists "Active admins and project managers can view invites for their projects"
on public.project_access_invites;

create policy "Active admins and project managers can view invites for their projects"
  on public.project_access_invites
  for select
  using (
    exists (
      select 1
      from public.project_members pm
      where pm.project_id = project_access_invites.project_id
        and pm.user_id = auth.uid()
        and pm.status = 'active'
        and pm.role in ('admin', 'project_manager')
    )
  );

commit;
