-- Migration: Add amenity layout image metadata columns to projects.
-- Safe / idempotent.

alter table public.projects
  add column if not exists amenity_layout_image_name text,
  add column if not exists amenity_layout_image_path text,
  add column if not exists amenity_layout_image_doc_id uuid,
  add column if not exists amenity_layout_image_extension text;

create index if not exists idx_projects_amenity_layout_image_doc_id
  on public.projects(amenity_layout_image_doc_id);
