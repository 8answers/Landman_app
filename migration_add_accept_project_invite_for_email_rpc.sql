-- Accept a project invite for an invited email when that email already has an auth account.
-- Used by the browser invite landing page to confirm access before the desktop app is opened.

CREATE OR REPLACE FUNCTION public.accept_project_invite_for_email(
  p_project_id UUID,
  p_invited_email TEXT,
  p_role TEXT DEFAULT NULL
)
RETURNS TABLE (
  outcome TEXT,
  user_id UUID,
  role TEXT,
  project_id UUID
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  normalized_email TEXT := lower(trim(coalesce(p_invited_email, '')));
  normalized_role TEXT := lower(trim(coalesce(p_role, '')));
  resolved_user_id UUID;
  invite_row public.project_access_invites%ROWTYPE;
  resolved_role TEXT := '';
  now_ts TIMESTAMPTZ := now();
BEGIN
  IF p_project_id IS NULL OR normalized_email = '' THEN
    RETURN;
  END IF;

  SELECT u.id
  INTO resolved_user_id
  FROM auth.users u
  WHERE lower(coalesce(u.email, '')) = normalized_email
  ORDER BY u.created_at ASC
  LIMIT 1;

  IF resolved_user_id IS NULL THEN
    RETURN QUERY
    SELECT 'missing_account'::TEXT, NULL::UUID, ''::TEXT, p_project_id;
    RETURN;
  END IF;

  IF normalized_role <> '' THEN
    SELECT *
    INTO invite_row
    FROM public.project_access_invites i
    WHERE i.project_id = p_project_id
      AND lower(coalesce(i.invited_email, '')) = normalized_email
      AND lower(coalesce(i.role, '')) = normalized_role
    ORDER BY i.requested_at DESC NULLS LAST, i.updated_at DESC NULLS LAST
    LIMIT 1;
  END IF;

  IF invite_row.id IS NULL THEN
    SELECT *
    INTO invite_row
    FROM public.project_access_invites i
    WHERE i.project_id = p_project_id
      AND lower(coalesce(i.invited_email, '')) = normalized_email
    ORDER BY i.requested_at DESC NULLS LAST, i.updated_at DESC NULLS LAST
    LIMIT 1;
  END IF;

  IF invite_row.id IS NULL THEN
    RETURN QUERY
    SELECT 'invite_not_found'::TEXT, resolved_user_id, ''::TEXT, p_project_id;
    RETURN;
  END IF;

  resolved_role := lower(trim(coalesce(invite_row.role, normalized_role, 'partner')));

  IF lower(coalesce(invite_row.status, '')) IN ('revoked', 'paused', 'expired') THEN
    RETURN QUERY
    SELECT 'invite_unavailable'::TEXT, resolved_user_id, resolved_role, p_project_id;
    RETURN;
  END IF;

  UPDATE public.project_access_invites
  SET
    status = 'accepted',
    accepted_at = COALESCE(accepted_at, now_ts),
    accepted_user_id = resolved_user_id,
    updated_at = now_ts
  WHERE id = invite_row.id;

  INSERT INTO public.project_members (
    project_id,
    user_id,
    invited_email,
    role,
    status,
    accepted_at,
    updated_at
  )
  VALUES (
    p_project_id,
    resolved_user_id,
    normalized_email,
    resolved_role,
    'active',
    now_ts,
    now_ts
  )
  ON CONFLICT ON CONSTRAINT project_members_project_id_user_id_key
  DO UPDATE SET
    invited_email = EXCLUDED.invited_email,
    role = EXCLUDED.role,
    status = 'active',
    accepted_at = COALESCE(project_members.accepted_at, EXCLUDED.accepted_at),
    updated_at = EXCLUDED.updated_at;

  RETURN QUERY
  SELECT 'accepted'::TEXT, resolved_user_id, resolved_role, p_project_id;
END;
$$;

REVOKE ALL ON FUNCTION public.accept_project_invite_for_email(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.accept_project_invite_for_email(UUID, TEXT, TEXT) TO service_role;
