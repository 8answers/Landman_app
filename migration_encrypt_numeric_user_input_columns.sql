-- Encrypt numeric user-entered fields at rest by storing ciphertext in text columns.
-- This migration converts relevant numeric columns to text so encrypted payloads
-- can be persisted. Before conversion, it drops CHECK constraints that still
-- compare these columns as numeric values (e.g. percentage >= 0).

DO $$
DECLARE
  target_refs constant text[] := ARRAY[
    'projects.total_area',
    'projects.selling_area',
    'projects.estimated_development_cost',
    'non_sellable_areas.area',
    'partners.amount',
    'expenses.amount',
    'amenity_areas.area',
    'amenity_areas.all_in_cost',
    'amenity_areas.sale_price',
    'amenity_areas.sale_value',
    'amenity_areas.payment_amount',
    'plots.area',
    'plots.all_in_cost_per_sqft',
    'plots.total_plot_cost',
    'plots.sale_price',
    'project_managers.percentage',
    'project_managers.fixed_fee',
    'project_managers.monthly_fee',
    'project_managers.months',
    'project_managers.fee',
    'agents.percentage',
    'agents.fixed_fee',
    'agents.monthly_fee',
    'agents.months',
    'agents.per_sqft_fee',
    'agents.per_sqm_fee',
    'agents.fee'
  ];
  ref text;
  v_table text;
  v_column text;
  con_row record;
BEGIN
  -- 1) Drop check constraints that reference any target column.
  FOREACH ref IN ARRAY target_refs
  LOOP
    v_table := split_part(ref, '.', 1);
    v_column := split_part(ref, '.', 2);

    FOR con_row IN
      SELECT con.conname
      FROM pg_constraint con
      JOIN pg_class cls
        ON cls.oid = con.conrelid
      JOIN pg_namespace ns
        ON ns.oid = cls.relnamespace
      WHERE con.contype = 'c'
        AND ns.nspname = 'public'
        AND cls.relname = v_table
        AND lower(pg_get_constraintdef(con.oid)) LIKE '%' || lower(v_column) || '%'
    LOOP
      EXECUTE format(
        'ALTER TABLE public.%I DROP CONSTRAINT IF EXISTS %I',
        v_table,
        con_row.conname
      );
    END LOOP;
  END LOOP;

  -- 2) Convert numeric columns to text so encrypted ciphertext can be stored.
  FOREACH ref IN ARRAY target_refs
  LOOP
    v_table := split_part(ref, '.', 1);
    v_column := split_part(ref, '.', 2);

    IF EXISTS (
      SELECT 1
      FROM information_schema.columns c
      WHERE c.table_schema = 'public'
        AND c.table_name = v_table
        AND c.column_name = v_column
        AND c.data_type <> 'text'
    ) THEN
      EXECUTE format(
        'ALTER TABLE public.%I ALTER COLUMN %I TYPE text USING %I::text',
        v_table,
        v_column,
        v_column
      );
    END IF;
  END LOOP;
END $$;
