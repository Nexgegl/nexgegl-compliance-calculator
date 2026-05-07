-- ============================================================
-- Migration: create_ai_action_governance_tables
-- Project:   NEXGEGL AI Action Governance — Collections Prototype
-- Date:      2026-05-07
-- ============================================================

-- Ensure UUID generation is available (Supabase has this by default)
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================
-- TABLE: ai_action_requests
-- Every AI-generated collection recommendation becomes a row
-- here with status=PENDING before any governance evaluation.
-- No execution is permitted without decision_id + decision_code.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.ai_action_requests (
  id                  uuid          PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Tenant scoping (text for prototype; migrate to uuid in production)
  tenant_id           text          NOT NULL,

  -- Origin of the request
  source_type         text          NOT NULL
    CHECK (source_type IN ('AI', 'HUMAN', 'SYSTEM')),

  -- Customer identifiers (only PII stored)
  customer_id         text,
  customer_name       text,

  -- Debt details
  amount              numeric,
  aging_bucket        text,
  risk_level          text,

  -- AI recommendation output
  recommended_action  text,
  ai_reason           text,

  -- Governance inputs
  policy_context      jsonb,

  -- KFSA decision fields
  decision_id         uuid,
  decision_code       text,
  verdict             text
    CHECK (verdict IN ('KILL', 'FIX', 'ALERT', 'SCALE')),

  -- Lifecycle status
  status              text          NOT NULL DEFAULT 'PENDING'
    CHECK (status IN ('PENDING', 'APPROVED', 'NEEDS_FIX', 'ESCALATED', 'BLOCKED', 'EXECUTED')),

  -- Metadata evidence (no additional PII)
  evidence            jsonb,

  -- Timestamps
  created_at          timestamptz   NOT NULL DEFAULT now(),
  updated_at          timestamptz   NOT NULL DEFAULT now()
);

-- ============================================================
-- TABLE: ai_action_audit_logs
-- Immutable append-only event log. Every governance event
-- for every action_request is recorded here.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.ai_action_audit_logs (
  id                  uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           text          NOT NULL,
  action_request_id   uuid
    REFERENCES public.ai_action_requests(id)
    ON DELETE SET NULL,
  event_type          text          NOT NULL,
  payload             jsonb,
  created_at          timestamptz   NOT NULL DEFAULT now()
);

-- ============================================================
-- FUNCTION + TRIGGER: auto-update updated_at on ai_action_requests
-- ============================================================
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_ai_action_requests_updated_at
  ON public.ai_action_requests;

CREATE TRIGGER trg_ai_action_requests_updated_at
  BEFORE UPDATE ON public.ai_action_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- ============================================================
-- INDEXES: ai_action_requests
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_aar_tenant_id
  ON public.ai_action_requests (tenant_id);

CREATE INDEX IF NOT EXISTS idx_aar_status
  ON public.ai_action_requests (status);

CREATE INDEX IF NOT EXISTS idx_aar_verdict
  ON public.ai_action_requests (verdict);

CREATE INDEX IF NOT EXISTS idx_aar_tenant_status
  ON public.ai_action_requests (tenant_id, status);

CREATE INDEX IF NOT EXISTS idx_aar_created_at
  ON public.ai_action_requests (created_at DESC);

-- ============================================================
-- INDEXES: ai_action_audit_logs
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_aaal_action_request_id
  ON public.ai_action_audit_logs (action_request_id);

CREATE INDEX IF NOT EXISTS idx_aaal_tenant_id
  ON public.ai_action_audit_logs (tenant_id);

CREATE INDEX IF NOT EXISTS idx_aaal_event_type
  ON public.ai_action_audit_logs (event_type);

CREATE INDEX IF NOT EXISTS idx_aaal_created_at
  ON public.ai_action_audit_logs (created_at DESC);

-- ============================================================
-- ROW LEVEL SECURITY
-- Enable RLS; grant full access to service_role (used by n8n)
-- ============================================================
ALTER TABLE public.ai_action_requests    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_action_audit_logs  ENABLE ROW LEVEL SECURITY;

-- Service role (n8n uses service role key) — full access
CREATE POLICY "service_role_all_action_requests"
  ON public.ai_action_requests
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

CREATE POLICY "service_role_all_audit_logs"
  ON public.ai_action_audit_logs
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- ============================================================
-- COMMENTS
-- ============================================================
COMMENT ON TABLE public.ai_action_requests IS
  'AI-generated action requests awaiting governance evaluation. No execution without decision_id and decision_code.';

COMMENT ON TABLE public.ai_action_audit_logs IS
  'Immutable audit trail of all governance decisions per action_request.';

COMMENT ON COLUMN public.ai_action_requests.tenant_id IS
  'Tenant identifier. Uses text for prototype; migrate to uuid FK in production.';

COMMENT ON COLUMN public.ai_action_requests.source_type IS
  'Origin: AI (model-generated), HUMAN (user-initiated), SYSTEM (rule-triggered).';

COMMENT ON COLUMN public.ai_action_requests.verdict IS
  'KFSA policy verdict. KILL=blocked, FIX=data issue, ALERT=escalate, SCALE=approve.';

COMMENT ON COLUMN public.ai_action_requests.decision_code IS
  'Unique policy decision reference. Format: KFSA-MOCK-{timestamp} in prototype.';

COMMENT ON COLUMN public.ai_action_requests.status IS
  'Lifecycle: PENDING -> APPROVED|BLOCKED|ESCALATED|NEEDS_FIX -> EXECUTED.';
