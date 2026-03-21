-- Project access control for invited users (partner / project_manager / agent / admin)
-- This migration adds:
-- 1) Invite + membership tables
-- 2) Member read access across project data
-- 3) Storage read access for shared documents bucket paths

CREATE TABLE IF NOT EXISTS public.project_access_invites (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    project_id UUID NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
    invited_email TEXT NOT NULL,
    role VARCHAR(32) NOT NULL CHECK (role IN ('partner', 'project_manager', 'agent', 'admin')),
    status VARCHAR(32) NOT NULL DEFAULT 'requested' CHECK (status IN ('requested', 'accepted', 'revoked', 'expired')),
    requested_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    requested_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    accepted_at TIMESTAMP WITH TIME ZONE,
    accepted_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    UNIQUE (project_id, invited_email, role)
);

CREATE TABLE IF NOT EXISTS public.project_members (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    project_id UUID NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    invited_email TEXT,
    role VARCHAR(32) NOT NULL DEFAULT 'partner' CHECK (role IN ('partner', 'project_manager', 'agent', 'admin')),
    status VARCHAR(32) NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'revoked')),
    invited_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    invited_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    accepted_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    UNIQUE (project_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_project_access_invites_project_email
    ON public.project_access_invites(project_id, invited_email);
CREATE INDEX IF NOT EXISTS idx_project_access_invites_email
    ON public.project_access_invites(invited_email);
CREATE INDEX IF NOT EXISTS idx_project_members_user_project
    ON public.project_members(user_id, project_id);
CREATE INDEX IF NOT EXISTS idx_project_members_project_role
    ON public.project_members(project_id, role);

CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS update_project_access_invites_updated_at ON public.project_access_invites;
CREATE TRIGGER update_project_access_invites_updated_at
    BEFORE UPDATE ON public.project_access_invites
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS update_project_members_updated_at ON public.project_members;
CREATE TRIGGER update_project_members_updated_at
    BEFORE UPDATE ON public.project_members
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();

ALTER TABLE public.project_access_invites ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.project_members ENABLE ROW LEVEL SECURITY;

-- Owners can manage invites for their own projects.
DROP POLICY IF EXISTS "Owners can manage invites for their projects" ON public.project_access_invites;
CREATE POLICY "Owners can manage invites for their projects"
    ON public.project_access_invites
    FOR ALL
    USING (
        EXISTS (
            SELECT 1
            FROM public.projects p
            WHERE p.id = project_access_invites.project_id
              AND p.user_id = auth.uid()
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1
            FROM public.projects p
            WHERE p.id = project_access_invites.project_id
              AND p.user_id = auth.uid()
        )
    );

-- Invitees can view their own invites.
DROP POLICY IF EXISTS "Invitees can view their own invites" ON public.project_access_invites;
CREATE POLICY "Invitees can view their own invites"
    ON public.project_access_invites
    FOR SELECT
    USING (
        lower(project_access_invites.invited_email) =
        lower(coalesce(auth.jwt() ->> 'email', ''))
    );

-- Invitees can mark their own invites as accepted.
DROP POLICY IF EXISTS "Invitees can accept their own invites" ON public.project_access_invites;
CREATE POLICY "Invitees can accept their own invites"
    ON public.project_access_invites
    FOR UPDATE
    USING (
        lower(project_access_invites.invited_email) =
        lower(coalesce(auth.jwt() ->> 'email', ''))
    )
    WITH CHECK (
        lower(project_access_invites.invited_email) =
        lower(coalesce(auth.jwt() ->> 'email', ''))
        AND project_access_invites.accepted_user_id = auth.uid()
    );

-- Owners can manage members for their own projects.
DROP POLICY IF EXISTS "Owners can manage project members" ON public.project_members;
CREATE POLICY "Owners can manage project members"
    ON public.project_members
    FOR ALL
    USING (
        EXISTS (
            SELECT 1
            FROM public.projects p
            WHERE p.id = project_members.project_id
              AND p.user_id = auth.uid()
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1
            FROM public.projects p
            WHERE p.id = project_members.project_id
              AND p.user_id = auth.uid()
        )
    );

-- Members can read their own membership rows.
DROP POLICY IF EXISTS "Users can read own project membership" ON public.project_members;
CREATE POLICY "Users can read own project membership"
    ON public.project_members
    FOR SELECT
    USING (project_members.user_id = auth.uid());

-- Invitees can create/update their own membership after accepting an invite.
DROP POLICY IF EXISTS "Invitees can upsert own membership" ON public.project_members;
CREATE POLICY "Invitees can upsert own membership"
    ON public.project_members
    FOR INSERT
    WITH CHECK (
        project_members.user_id = auth.uid()
        AND EXISTS (
            SELECT 1
            FROM public.project_access_invites i
            WHERE i.project_id = project_members.project_id
              AND lower(i.invited_email) = lower(coalesce(auth.jwt() ->> 'email', ''))
              AND i.status = 'accepted'
        )
    );

DROP POLICY IF EXISTS "Invitees can update own membership" ON public.project_members;
CREATE POLICY "Invitees can update own membership"
    ON public.project_members
    FOR UPDATE
    USING (
        project_members.user_id = auth.uid()
    )
    WITH CHECK (
        project_members.user_id = auth.uid()
    );

-- Members can view project rows.
DROP POLICY IF EXISTS "Members can view projects they belong to" ON public.projects;
CREATE POLICY "Members can view projects they belong to"
    ON public.projects
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1
            FROM public.project_members pm
            WHERE pm.project_id = projects.id
              AND pm.user_id = auth.uid()
              AND pm.status = 'active'
        )
    );

-- Members can view project-related table rows.
DROP POLICY IF EXISTS "Members can view non-sellable areas" ON public.non_sellable_areas;
CREATE POLICY "Members can view non-sellable areas"
    ON public.non_sellable_areas
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1
            FROM public.project_members pm
            WHERE pm.project_id = non_sellable_areas.project_id
              AND pm.user_id = auth.uid()
              AND pm.status = 'active'
        )
    );

DROP POLICY IF EXISTS "Members can view partners" ON public.partners;
CREATE POLICY "Members can view partners"
    ON public.partners
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1
            FROM public.project_members pm
            WHERE pm.project_id = partners.project_id
              AND pm.user_id = auth.uid()
              AND pm.status = 'active'
        )
    );

DROP POLICY IF EXISTS "Members can view expenses" ON public.expenses;
CREATE POLICY "Members can view expenses"
    ON public.expenses
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1
            FROM public.project_members pm
            WHERE pm.project_id = expenses.project_id
              AND pm.user_id = auth.uid()
              AND pm.status = 'active'
        )
    );

DROP POLICY IF EXISTS "Members can view layouts" ON public.layouts;
CREATE POLICY "Members can view layouts"
    ON public.layouts
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1
            FROM public.project_members pm
            WHERE pm.project_id = layouts.project_id
              AND pm.user_id = auth.uid()
              AND pm.status = 'active'
        )
    );

DROP POLICY IF EXISTS "Members can view plots" ON public.plots;
CREATE POLICY "Members can view plots"
    ON public.plots
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1
            FROM public.layouts l
            JOIN public.project_members pm ON pm.project_id = l.project_id
            WHERE l.id = plots.layout_id
              AND pm.user_id = auth.uid()
              AND pm.status = 'active'
        )
    );

DROP POLICY IF EXISTS "Members can view plot partners" ON public.plot_partners;
CREATE POLICY "Members can view plot partners"
    ON public.plot_partners
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1
            FROM public.plots pl
            JOIN public.layouts l ON l.id = pl.layout_id
            JOIN public.project_members pm ON pm.project_id = l.project_id
            WHERE pl.id = plot_partners.plot_id
              AND pm.user_id = auth.uid()
              AND pm.status = 'active'
        )
    );

DROP POLICY IF EXISTS "Members can view project managers" ON public.project_managers;
CREATE POLICY "Members can view project managers"
    ON public.project_managers
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1
            FROM public.project_members pm
            WHERE pm.project_id = project_managers.project_id
              AND pm.user_id = auth.uid()
              AND pm.status = 'active'
        )
    );

DROP POLICY IF EXISTS "Members can view project manager blocks" ON public.project_manager_blocks;
CREATE POLICY "Members can view project manager blocks"
    ON public.project_manager_blocks
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1
            FROM public.project_managers mgr
            JOIN public.project_members pm ON pm.project_id = mgr.project_id
            WHERE mgr.id = project_manager_blocks.project_manager_id
              AND pm.user_id = auth.uid()
              AND pm.status = 'active'
        )
    );

DROP POLICY IF EXISTS "Members can view agents" ON public.agents;
CREATE POLICY "Members can view agents"
    ON public.agents
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1
            FROM public.project_members pm
            WHERE pm.project_id = agents.project_id
              AND pm.user_id = auth.uid()
              AND pm.status = 'active'
        )
    );

DROP POLICY IF EXISTS "Members can view agent blocks" ON public.agent_blocks;
CREATE POLICY "Members can view agent blocks"
    ON public.agent_blocks
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1
            FROM public.agents a
            JOIN public.project_members pm ON pm.project_id = a.project_id
            WHERE a.id = agent_blocks.agent_id
              AND pm.user_id = auth.uid()
              AND pm.status = 'active'
        )
    );

DO $$
BEGIN
    IF to_regclass('public.amenity_areas') IS NOT NULL THEN
        EXECUTE 'DROP POLICY IF EXISTS "Members can view amenity areas" ON public.amenity_areas';
        EXECUTE '
            CREATE POLICY "Members can view amenity areas"
                ON public.amenity_areas
                FOR SELECT
                USING (
                    EXISTS (
                        SELECT 1
                        FROM public.project_members pm
                        WHERE pm.project_id = amenity_areas.project_id
                          AND pm.user_id = auth.uid()
                          AND pm.status = ''active''
                    )
                )';
    END IF;
END
$$;

DO $$
BEGIN
    IF to_regclass('public.documents') IS NOT NULL THEN
        EXECUTE 'DROP POLICY IF EXISTS "Members can view documents" ON public.documents';
        EXECUTE '
            CREATE POLICY "Members can view documents"
                ON public.documents
                FOR SELECT
                USING (
                    EXISTS (
                        SELECT 1
                        FROM public.project_members pm
                        WHERE pm.project_id = documents.project_id
                          AND pm.user_id = auth.uid()
                          AND pm.status = ''active''
                    )
                )';
    END IF;
END
$$;

-- Storage access for invited members: allow read of files under /documents/{project_id}/...
DROP POLICY IF EXISTS "Project members can read shared documents" ON storage.objects;
CREATE POLICY "Project members can read shared documents"
    ON storage.objects
    FOR SELECT
    TO authenticated
    USING (
        bucket_id = 'documents'
        AND EXISTS (
            SELECT 1
            FROM public.project_members pm
            WHERE pm.project_id::text = (storage.foldername(name))[1]
              AND pm.user_id = auth.uid()
              AND pm.status = 'active'
        )
    );
