-- =====================================================
-- Landman Website Database Schema
-- =====================================================
-- This schema stores all project data entered in the website
-- =====================================================

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- =====================================================
-- 1. PROJECTS TABLE
-- =====================================================
CREATE TABLE IF NOT EXISTS projects (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    project_name VARCHAR(255) NOT NULL,
    project_address TEXT DEFAULT '',
    google_maps_link TEXT DEFAULT '',
    total_area DECIMAL(15, 2) DEFAULT 0.00,
    selling_area DECIMAL(15, 2) DEFAULT 0.00,
    estimated_development_cost DECIMAL(15, 2) DEFAULT 0.00,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(user_id, project_name)
);

-- =====================================================
-- 2. NON-SELLABLE AREAS TABLE
-- =====================================================
CREATE TABLE IF NOT EXISTS non_sellable_areas (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    area DECIMAL(15, 2) DEFAULT 0.00,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- =====================================================
-- 3. PARTNERS TABLE
-- =====================================================
CREATE TABLE IF NOT EXISTS partners (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    amount DECIMAL(15, 2) DEFAULT 0.00,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(project_id, name)
);

-- =====================================================
-- 4. EXPENSES TABLE
-- =====================================================
CREATE TABLE IF NOT EXISTS expenses (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    item VARCHAR(255) NOT NULL,
    amount DECIMAL(15, 2) DEFAULT 0.00,
    category VARCHAR(100) NOT NULL CHECK (category IN (
        'Land Purchase Cost',
        'Statutory & Registration',
        'Legal & Professional Fees',
        'Survey, Approvals & Conversion',
        'Construction & Development',
        'Amenities & Infrastructure',
        'Others'
    )),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- =====================================================
-- 5. LAYOUTS TABLE
-- =====================================================
CREATE TABLE IF NOT EXISTS layouts (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(project_id, name)
);

-- =====================================================
-- 6. PLOTS TABLE
-- =====================================================
CREATE TABLE IF NOT EXISTS plots (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    layout_id UUID NOT NULL REFERENCES layouts(id) ON DELETE CASCADE,
    plot_number VARCHAR(100) NOT NULL,
    area DECIMAL(15, 2) DEFAULT 0.00,
    all_in_cost_per_sqft DECIMAL(15, 2) DEFAULT 0.00,
    total_plot_cost DECIMAL(15, 2) DEFAULT 0.00,
    status VARCHAR(20) DEFAULT 'available' CHECK (status IN ('available', 'sold', 'reserved', 'blocked')),
    sale_price DECIMAL(15, 2) DEFAULT NULL,
    buyer_name VARCHAR(255) DEFAULT NULL,
    sale_date DATE DEFAULT NULL,
    agent_name VARCHAR(255) DEFAULT NULL,
    payments JSONB DEFAULT '[]'::jsonb,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(layout_id, plot_number)
);

-- =====================================================
-- 7. PLOT PARTNERS TABLE (Many-to-Many)
-- =====================================================
CREATE TABLE IF NOT EXISTS plot_partners (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    plot_id UUID NOT NULL REFERENCES plots(id) ON DELETE CASCADE,
    partner_name VARCHAR(255) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(plot_id, partner_name)
);

-- =====================================================
-- 8. PROJECT MANAGERS TABLE
-- =====================================================
CREATE TABLE IF NOT EXISTS project_managers (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    compensation_type VARCHAR(50) CHECK (compensation_type IN ('Percentage Bonus', 'Fixed Fee', 'Monthly Fee', 'None')),
    earning_type VARCHAR(50) CHECK (earning_type IN ('Per Plot', 'Per Square Foot', 'Lump Sum')),
    percentage DECIMAL(5, 2) DEFAULT NULL,
    fixed_fee DECIMAL(15, 2) DEFAULT NULL,
    monthly_fee DECIMAL(15, 2) DEFAULT NULL,
    months INTEGER DEFAULT NULL CHECK (months >= 1 AND months <= 12),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- =====================================================
-- 9. PROJECT MANAGER SELECTED BLOCKS TABLE (Many-to-Many)
-- =====================================================
CREATE TABLE IF NOT EXISTS project_manager_blocks (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    project_manager_id UUID NOT NULL REFERENCES project_managers(id) ON DELETE CASCADE,
    plot_id UUID NOT NULL REFERENCES plots(id) ON DELETE CASCADE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(project_manager_id, plot_id)
);

-- =====================================================
-- 10. AGENTS TABLE
-- =====================================================
CREATE TABLE IF NOT EXISTS agents (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    compensation_type VARCHAR(50) CHECK (compensation_type IN ('Percentage Bonus', 'Fixed Fee', 'Monthly Fee', 'Per Sqft Fee', 'None')),
    earning_type VARCHAR(50) CHECK (earning_type IN ('Per Plot', 'Per Square Foot', 'Lump Sum')),
    percentage DECIMAL(5, 2) DEFAULT NULL,
    fixed_fee DECIMAL(15, 2) DEFAULT NULL,
    monthly_fee DECIMAL(15, 2) DEFAULT NULL,
    months INTEGER DEFAULT NULL CHECK (months >= 1 AND months <= 12),
    per_sqft_fee DECIMAL(15, 2) DEFAULT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- =====================================================
-- 11. AGENT SELECTED BLOCKS TABLE (Many-to-Many)
-- =====================================================
CREATE TABLE IF NOT EXISTS agent_blocks (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    agent_id UUID NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    plot_id UUID NOT NULL REFERENCES plots(id) ON DELETE CASCADE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(agent_id, plot_id)
);

-- =====================================================
-- INDEXES FOR PERFORMANCE
-- =====================================================
CREATE INDEX IF NOT EXISTS idx_projects_user_id ON projects(user_id);
CREATE INDEX IF NOT EXISTS idx_projects_name ON projects(project_name);
CREATE INDEX IF NOT EXISTS idx_non_sellable_areas_project_id ON non_sellable_areas(project_id);
CREATE INDEX IF NOT EXISTS idx_partners_project_id ON partners(project_id);
CREATE INDEX IF NOT EXISTS idx_expenses_project_id ON expenses(project_id);
CREATE INDEX IF NOT EXISTS idx_expenses_category ON expenses(category);
CREATE INDEX IF NOT EXISTS idx_layouts_project_id ON layouts(project_id);
CREATE INDEX IF NOT EXISTS idx_plots_layout_id ON plots(layout_id);
CREATE INDEX IF NOT EXISTS idx_plots_status ON plots(status);
CREATE INDEX IF NOT EXISTS idx_plot_partners_plot_id ON plot_partners(plot_id);
CREATE INDEX IF NOT EXISTS idx_project_managers_project_id ON project_managers(project_id);
CREATE INDEX IF NOT EXISTS idx_project_manager_blocks_manager_id ON project_manager_blocks(project_manager_id);
CREATE INDEX IF NOT EXISTS idx_project_manager_blocks_plot_id ON project_manager_blocks(plot_id);
CREATE INDEX IF NOT EXISTS idx_agents_project_id ON agents(project_id);
CREATE INDEX IF NOT EXISTS idx_agent_blocks_agent_id ON agent_blocks(agent_id);
CREATE INDEX IF NOT EXISTS idx_agent_blocks_plot_id ON agent_blocks(plot_id);

-- =====================================================
-- ROW LEVEL SECURITY (RLS) POLICIES
-- =====================================================

-- Enable RLS on all tables
ALTER TABLE projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE non_sellable_areas ENABLE ROW LEVEL SECURITY;
ALTER TABLE partners ENABLE ROW LEVEL SECURITY;
ALTER TABLE expenses ENABLE ROW LEVEL SECURITY;
ALTER TABLE layouts ENABLE ROW LEVEL SECURITY;
ALTER TABLE plots ENABLE ROW LEVEL SECURITY;
ALTER TABLE plot_partners ENABLE ROW LEVEL SECURITY;
ALTER TABLE project_managers ENABLE ROW LEVEL SECURITY;
ALTER TABLE project_manager_blocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE agents ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_blocks ENABLE ROW LEVEL SECURITY;

-- Drop existing policies so this bootstrap script can be re-run safely.
DROP POLICY IF EXISTS "Users can view their own projects" ON projects;
DROP POLICY IF EXISTS "Users can insert their own projects" ON projects;
DROP POLICY IF EXISTS "Users can update their own projects" ON projects;
DROP POLICY IF EXISTS "Users can delete their own projects" ON projects;
DROP POLICY IF EXISTS "Users can manage non-sellable areas for their projects" ON non_sellable_areas;
DROP POLICY IF EXISTS "Users can manage partners for their projects" ON partners;
DROP POLICY IF EXISTS "Users can manage expenses for their projects" ON expenses;
DROP POLICY IF EXISTS "Users can manage layouts for their projects" ON layouts;
DROP POLICY IF EXISTS "Users can manage plots for their layouts" ON plots;
DROP POLICY IF EXISTS "Users can manage plot partners" ON plot_partners;
DROP POLICY IF EXISTS "Users can manage project managers for their projects" ON project_managers;
DROP POLICY IF EXISTS "Users can manage project manager blocks" ON project_manager_blocks;
DROP POLICY IF EXISTS "Users can manage agents for their projects" ON agents;
DROP POLICY IF EXISTS "Users can manage agent blocks" ON agent_blocks;

-- Policies for projects table
CREATE POLICY "Users can view their own projects"
    ON projects FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "Users can insert their own projects"
    ON projects FOR INSERT
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own projects"
    ON projects FOR UPDATE
    USING (auth.uid() = user_id);

CREATE POLICY "Users can delete their own projects"
    ON projects FOR DELETE
    USING (auth.uid() = user_id);

-- Policies for non_sellable_areas table
CREATE POLICY "Users can manage non-sellable areas for their projects"
    ON non_sellable_areas
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = non_sellable_areas.project_id
            AND projects.user_id = auth.uid()
        )
    );

-- Policies for partners table
CREATE POLICY "Users can manage partners for their projects"
    ON partners
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = partners.project_id
            AND projects.user_id = auth.uid()
        )
    );

-- Policies for expenses table
CREATE POLICY "Users can manage expenses for their projects"
    ON expenses
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = expenses.project_id
            AND projects.user_id = auth.uid()
        )
    );

-- Policies for layouts table
CREATE POLICY "Users can manage layouts for their projects"
    ON layouts
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = layouts.project_id
            AND projects.user_id = auth.uid()
        )
    );

-- Policies for plots table
CREATE POLICY "Users can manage plots for their layouts"
    ON plots
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM layouts
            JOIN projects ON projects.id = layouts.project_id
            WHERE layouts.id = plots.layout_id
            AND projects.user_id = auth.uid()
        )
    );

-- Policies for plot_partners table
CREATE POLICY "Users can manage plot partners"
    ON plot_partners
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM plots
            JOIN layouts ON layouts.id = plots.layout_id
            JOIN projects ON projects.id = layouts.project_id
            WHERE plots.id = plot_partners.plot_id
            AND projects.user_id = auth.uid()
        )
    );

-- Policies for project_managers table
CREATE POLICY "Users can manage project managers for their projects"
    ON project_managers
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = project_managers.project_id
            AND projects.user_id = auth.uid()
        )
    );

-- Policies for project_manager_blocks table
CREATE POLICY "Users can manage project manager blocks"
    ON project_manager_blocks
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM project_managers
            JOIN projects ON projects.id = project_managers.project_id
            WHERE project_managers.id = project_manager_blocks.project_manager_id
            AND projects.user_id = auth.uid()
        )
    );

-- Policies for agents table
CREATE POLICY "Users can manage agents for their projects"
    ON agents
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = agents.project_id
            AND projects.user_id = auth.uid()
        )
    );

-- Policies for agent_blocks table
CREATE POLICY "Users can manage agent blocks"
    ON agent_blocks
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM agents
            JOIN projects ON projects.id = agents.project_id
            WHERE agents.id = agent_blocks.agent_id
            AND projects.user_id = auth.uid()
        )
    );

-- =====================================================
-- TRIGGERS FOR UPDATED_AT TIMESTAMP
-- =====================================================

-- Function to update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply trigger to all tables with updated_at
DROP TRIGGER IF EXISTS update_projects_updated_at ON projects;
CREATE TRIGGER update_projects_updated_at
    BEFORE UPDATE ON projects
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_non_sellable_areas_updated_at ON non_sellable_areas;
CREATE TRIGGER update_non_sellable_areas_updated_at
    BEFORE UPDATE ON non_sellable_areas
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_partners_updated_at ON partners;
CREATE TRIGGER update_partners_updated_at
    BEFORE UPDATE ON partners
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_expenses_updated_at ON expenses;
CREATE TRIGGER update_expenses_updated_at
    BEFORE UPDATE ON expenses
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_layouts_updated_at ON layouts;
CREATE TRIGGER update_layouts_updated_at
    BEFORE UPDATE ON layouts
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_plots_updated_at ON plots;
CREATE TRIGGER update_plots_updated_at
    BEFORE UPDATE ON plots
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_project_managers_updated_at ON project_managers;
CREATE TRIGGER update_project_managers_updated_at
    BEFORE UPDATE ON project_managers
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_agents_updated_at ON agents;
CREATE TRIGGER update_agents_updated_at
    BEFORE UPDATE ON agents
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- =====================================================
-- SAMPLE QUERIES FOR REFERENCE
-- =====================================================

-- Get all projects for a user
-- SELECT * FROM projects WHERE user_id = auth.uid() ORDER BY created_at DESC;

-- Get complete project data with all related information
-- SELECT 
--     p.*,
--     json_agg(DISTINCT jsonb_build_object('id', nsa.id, 'name', nsa.name, 'area', nsa.area)) as non_sellable_areas,
--     json_agg(DISTINCT jsonb_build_object('id', pt.id, 'name', pt.name, 'amount', pt.amount)) as partners,
--     json_agg(DISTINCT jsonb_build_object('id', e.id, 'item', e.item, 'amount', e.amount, 'category', e.category)) as expenses
-- FROM projects p
-- LEFT JOIN non_sellable_areas nsa ON nsa.project_id = p.id
-- LEFT JOIN partners pt ON pt.project_id = p.id
-- LEFT JOIN expenses e ON e.project_id = p.id
-- WHERE p.user_id = auth.uid()
-- GROUP BY p.id;

-- Get all plots with their layout and project info
-- SELECT 
--     pl.id,
--     pl.plot_number,
--     pl.area,
--     pl.all_in_cost_per_sqft,
--     pl.total_plot_cost,
--     pl.status,
--     l.name as layout_name,
--     p.project_name
-- FROM plots pl
-- JOIN layouts l ON l.id = pl.layout_id
-- JOIN projects p ON p.id = l.project_id
-- WHERE p.user_id = auth.uid()
-- ORDER BY l.name, pl.plot_number;
