-- Add project base area unit persistence for Settings page dropdown
alter table if exists public.projects
add column if not exists area_unit text not null default 'Square Meter (sqm)';

alter table if exists public.projects
alter column area_unit set default 'Square Meter (sqm)';

update public.projects
set area_unit = 'Square Meter (sqm)'
where coalesce(trim(area_unit), '') = ''
   or lower(trim(area_unit)) = 'square feet (sqft)';