-- Allow active admin / project_manager members to update project and plot-status
-- related rows so cross-user sync can trigger for non-owner editors too.

begin;

drop policy if exists "Active admins and project managers can update projects"
on public.projects;
create policy "Active admins and project managers can update projects"
  on public.projects
  for update
  using (
    exists (
      select 1
      from public.project_members pm
      where pm.project_id = projects.id
        and pm.user_id = auth.uid()
        and pm.status = 'active'
        and pm.role in ('admin', 'project_manager')
    )
  )
  with check (
    exists (
      select 1
      from public.project_members pm
      where pm.project_id = projects.id
        and pm.user_id = auth.uid()
        and pm.status = 'active'
        and pm.role in ('admin', 'project_manager')
    )
  );

drop policy if exists "Active admins and project managers can update layouts"
on public.layouts;
create policy "Active admins and project managers can update layouts"
  on public.layouts
  for update
  using (
    exists (
      select 1
      from public.project_members pm
      where pm.project_id = layouts.project_id
        and pm.user_id = auth.uid()
        and pm.status = 'active'
        and pm.role in ('admin', 'project_manager')
    )
  )
  with check (
    exists (
      select 1
      from public.project_members pm
      where pm.project_id = layouts.project_id
        and pm.user_id = auth.uid()
        and pm.status = 'active'
        and pm.role in ('admin', 'project_manager')
    )
  );

drop policy if exists "Active admins and project managers can insert layouts"
on public.layouts;
create policy "Active admins and project managers can insert layouts"
  on public.layouts
  for insert
  with check (
    exists (
      select 1
      from public.project_members pm
      where pm.project_id = layouts.project_id
        and pm.user_id = auth.uid()
        and pm.status = 'active'
        and pm.role in ('admin', 'project_manager')
    )
  );

drop policy if exists "Active admins and project managers can delete layouts"
on public.layouts;
create policy "Active admins and project managers can delete layouts"
  on public.layouts
  for delete
  using (
    exists (
      select 1
      from public.project_members pm
      where pm.project_id = layouts.project_id
        and pm.user_id = auth.uid()
        and pm.status = 'active'
        and pm.role in ('admin', 'project_manager')
    )
  );

drop policy if exists "Active admins and project managers can update amenity areas"
on public.amenity_areas;
create policy "Active admins and project managers can update amenity areas"
  on public.amenity_areas
  for update
  using (
    exists (
      select 1
      from public.project_members pm
      where pm.project_id = amenity_areas.project_id
        and pm.user_id = auth.uid()
        and pm.status = 'active'
        and pm.role in ('admin', 'project_manager')
    )
  )
  with check (
    exists (
      select 1
      from public.project_members pm
      where pm.project_id = amenity_areas.project_id
        and pm.user_id = auth.uid()
        and pm.status = 'active'
        and pm.role in ('admin', 'project_manager')
    )
  );

drop policy if exists "Active admins and project managers can insert amenity areas"
on public.amenity_areas;
create policy "Active admins and project managers can insert amenity areas"
  on public.amenity_areas
  for insert
  with check (
    exists (
      select 1
      from public.project_members pm
      where pm.project_id = amenity_areas.project_id
        and pm.user_id = auth.uid()
        and pm.status = 'active'
        and pm.role in ('admin', 'project_manager')
    )
  );

drop policy if exists "Active admins and project managers can delete amenity areas"
on public.amenity_areas;
create policy "Active admins and project managers can delete amenity areas"
  on public.amenity_areas
  for delete
  using (
    exists (
      select 1
      from public.project_members pm
      where pm.project_id = amenity_areas.project_id
        and pm.user_id = auth.uid()
        and pm.status = 'active'
        and pm.role in ('admin', 'project_manager')
    )
  );

drop policy if exists "Active admins and project managers can update plots"
on public.plots;
create policy "Active admins and project managers can update plots"
  on public.plots
  for update
  using (
    exists (
      select 1
      from public.layouts l
      join public.project_members pm on pm.project_id = l.project_id
      where l.id = plots.layout_id
        and pm.user_id = auth.uid()
        and pm.status = 'active'
        and pm.role in ('admin', 'project_manager')
    )
  )
  with check (
    exists (
      select 1
      from public.layouts l
      join public.project_members pm on pm.project_id = l.project_id
      where l.id = plots.layout_id
        and pm.user_id = auth.uid()
        and pm.status = 'active'
        and pm.role in ('admin', 'project_manager')
    )
  );

drop policy if exists "Active admins and project managers can insert plots"
on public.plots;
create policy "Active admins and project managers can insert plots"
  on public.plots
  for insert
  with check (
    exists (
      select 1
      from public.layouts l
      join public.project_members pm on pm.project_id = l.project_id
      where l.id = plots.layout_id
        and pm.user_id = auth.uid()
        and pm.status = 'active'
        and pm.role in ('admin', 'project_manager')
    )
  );

drop policy if exists "Active admins and project managers can delete plots"
on public.plots;
create policy "Active admins and project managers can delete plots"
  on public.plots
  for delete
  using (
    exists (
      select 1
      from public.layouts l
      join public.project_members pm on pm.project_id = l.project_id
      where l.id = plots.layout_id
        and pm.user_id = auth.uid()
        and pm.status = 'active'
        and pm.role in ('admin', 'project_manager')
    )
  );

commit;
