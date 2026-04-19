-- Allow everyone (anon + authenticated) to read the default sample project.
-- This keeps sample data DB-backed for both debug and packaged release apps.
--
-- Sample project id:
--   46060996-8f5c-4d60-9bcd-a081a14fce2e

CREATE OR REPLACE FUNCTION public.is_default_sample_project(project_id uuid)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT project_id = '46060996-8f5c-4d60-9bcd-a081a14fce2e'::uuid;
$$;

DROP POLICY IF EXISTS "Public can read default sample project row" ON public.projects;
CREATE POLICY "Public can read default sample project row"
ON public.projects
FOR SELECT
TO anon, authenticated
USING (public.is_default_sample_project(id));

DROP POLICY IF EXISTS "Public can read default sample non-sellable areas" ON public.non_sellable_areas;
CREATE POLICY "Public can read default sample non-sellable areas"
ON public.non_sellable_areas
FOR SELECT
TO anon, authenticated
USING (public.is_default_sample_project(project_id));

DROP POLICY IF EXISTS "Public can read default sample amenity areas" ON public.amenity_areas;
CREATE POLICY "Public can read default sample amenity areas"
ON public.amenity_areas
FOR SELECT
TO anon, authenticated
USING (public.is_default_sample_project(project_id));

DROP POLICY IF EXISTS "Public can read default sample partners" ON public.partners;
CREATE POLICY "Public can read default sample partners"
ON public.partners
FOR SELECT
TO anon, authenticated
USING (public.is_default_sample_project(project_id));

DROP POLICY IF EXISTS "Public can read default sample expenses" ON public.expenses;
CREATE POLICY "Public can read default sample expenses"
ON public.expenses
FOR SELECT
TO anon, authenticated
USING (public.is_default_sample_project(project_id));

DROP POLICY IF EXISTS "Public can read default sample layouts" ON public.layouts;
CREATE POLICY "Public can read default sample layouts"
ON public.layouts
FOR SELECT
TO anon, authenticated
USING (public.is_default_sample_project(project_id));

DROP POLICY IF EXISTS "Public can read default sample plots" ON public.plots;
CREATE POLICY "Public can read default sample plots"
ON public.plots
FOR SELECT
TO anon, authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.layouts l
    WHERE l.id = plots.layout_id
      AND public.is_default_sample_project(l.project_id)
  )
);

DROP POLICY IF EXISTS "Public can read default sample plot partners" ON public.plot_partners;
CREATE POLICY "Public can read default sample plot partners"
ON public.plot_partners
FOR SELECT
TO anon, authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.plots p
    JOIN public.layouts l ON l.id = p.layout_id
    WHERE p.id = plot_partners.plot_id
      AND public.is_default_sample_project(l.project_id)
  )
);

DROP POLICY IF EXISTS "Public can read default sample project managers" ON public.project_managers;
CREATE POLICY "Public can read default sample project managers"
ON public.project_managers
FOR SELECT
TO anon, authenticated
USING (public.is_default_sample_project(project_id));

DROP POLICY IF EXISTS "Public can read default sample agents" ON public.agents;
CREATE POLICY "Public can read default sample agents"
ON public.agents
FOR SELECT
TO anon, authenticated
USING (public.is_default_sample_project(project_id));
