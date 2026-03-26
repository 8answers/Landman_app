-- Add buyer contact number support for amenity area sale details.

begin;

alter table if exists public.amenity_areas
  add column if not exists buyer_contact_number text;

do $$
begin
  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'amenity_areas'
      and column_name = 'buyer_mobile_number'
  ) then
    execute $sql$
      update public.amenity_areas
      set buyer_contact_number = coalesce(
            nullif(trim(buyer_contact_number), ''),
            buyer_mobile_number
          )
      where coalesce(nullif(trim(buyer_contact_number), ''), '') = ''
    $sql$;
  end if;
end
$$;

commit;