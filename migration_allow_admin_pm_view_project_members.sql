-- Allow active admin / project_manager members to read project_members rows
-- for their project. This is needed to keep Access Control in sync across admins.

begin;

create or replace function public.is_active_project_admin_or_pm(target_project_id uuid)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.project_members pm
    where pm.project_id = target_project_id
      and pm.user_id = auth.uid()
      and pm.status = 'active'
      and pm.role in ('admin', 'project_manager')
  );
$$;

revoke all on function public.is_active_project_admin_or_pm(uuid) from public;
grant execute on function public.is_active_project_admin_or_pm(uuid) to authenticated;

drop policy if exists "Admins and project managers can view project members"
on public.project_members;
create policy "Admins and project managers can view project members"
  on public.project_members
  for select
  using (
    public.is_active_project_admin_or_pm(project_id)
    or user_id = auth.uid()
  );

commit;
