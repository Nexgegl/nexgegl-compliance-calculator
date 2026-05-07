# n8n AI Action Governance Prototype — Implementation Report

**Project:** NEXGEGL Compliance Calculator 
**Date:** 2026-05-07 
**Version:** 1.0.0 — Prototype 
**Branch:** `claude/add-sales-forecast-nexxgegl-RBj7o`

---

## Executive Summary

This prototype demonstrates that an AI model (OpenAI) can recommend a collections action, a governance layer (KFSA mock evaluator) can evaluate that recommendation against policy rules, and no execution is permitted unless the KFSA evaluator returns a `SCALE` verdict — enforcing the principle that **AI Recommendation ≠ Decision ≠ Execution**. Every action request is written to Supabase before AI inference runs, every governance decision produces a `decision_code`, and every event is logged to an immutable audit table.

---

## 1. Files Delivered

| File | Purpose |
|------|---------|
| `docs/n8n-ai-action-governance-architecture.md` | Full architecture spec, pipeline diagram, KFSA rules table, security boundaries |
| `supabase/migrations/create_ai_action_governance_tables.sql` | Supabase SQL migration: tables, indexes, RLS policies, updated_at trigger |
| `n8n/workflows/ai-action-governance-collections-prototype.json` | Importable n8n workflow with 14 nodes |
| `docs/test-payloads/ai-action-governance-sample.json` | 5 test scenarios covering all 4 verdict paths + 400 error |
| `reports/n8n-ai-action-governance-prototype-report.md` | This report |

---

## 2. How to Import the Workflow into n8n

### Step-by-step

1. Open your n8n instance
2. Go to **Workflows** in the left sidebar
3. Click **+ New** → **Import from file**
4. Select `n8n/workflows/ai-action-governance-collections-prototype.json`
5. The workflow opens with 14 nodes pre-wired
6. Set environment variables (see Section 4)
7. Click **Activate** (toggle top-right)
8. Copy the generated webhook URL from node 1 (`Webhook — Receive Debt Payload`)

### Verify import was successful
- 14 nodes should appear on the canvas
- Node 1 (Webhook) shows path `ai-governance-collections`
- Node 3 (IF) has two output branches wired
- Node 9 (KFSA Policy Evaluator) is a Code node with 5 rules

---

## 3. How to Run the SQL Migration in Supabase

1. Open your Supabase project dashboard
2. Go to **SQL Editor** → **New query**
3. Paste the contents of `supabase/migrations/create_ai_action_governance_tables.sql`
4. Click **Run**
5. Verify in **Table Editor**: `ai_action_requests` and `ai_action_audit_logs` tables appear
6. Verify RLS is enabled on both tables (shield icon visible)

### Verify tables created
```sql
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN ('ai_action_requests', 'ai_action_audit_logs');
```

---

## 4. Required Environment Variables

Set these in n8n under **Settings → Environment Variables**:

| Variable | Value | Notes |
|----------|-------|-------|
| `SUPABASE_URL` | `https://your-project.supabase.co` | From Supabase project Settings → API |
| `SUPABASE_SERVICE_ROLE_KEY` | `eyJ...` | **Service role** key only — never anon key |
| `OPENAI_API_KEY` | `sk-...` | Requires access to `gpt-4o-mini` |
| `KFSA_EVALUATION_ENDPOINT` | *(optional)* | Not used in prototype; mock evaluator active |

> **Security note:** `SUPABASE_SERVICE_ROLE_KEY` bypasses Row Level Security. It must never be exposed to clients. Keep it inside n8n environment variables only.

---

## 5. Supabase Tables Created

### `public.ai_action_requests`
Stores every governance request from intake to decision.

| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid PK | Auto-generated |
| `tenant_id` | text | Prototype uses text; migrate to uuid in production |
| `source_type` | text | `AI` / `HUMAN` / `SYSTEM` |
| `customer_id` | text | PII — customer reference |
| `customer_name` | text | PII — display name |
| `amount` | numeric | Debt amount |
| `aging_bucket` | text | e.g. `+30`, `90-180`, `+180` |
| `risk_level` | text | `LOW` / `MEDIUM` / `HIGH` |
| `recommended_action` | text | From AI model |
| `ai_reason` | text | AI reasoning text |
| `policy_context` | jsonb | Passed-through policy metadata |
| `decision_id` | uuid | Governance decision UUID |
| `decision_code` | text | e.g. `KFSA-MOCK-1746619200000` |
| `verdict` | text | `KILL` / `FIX` / `ALERT` / `SCALE` |
| `status` | text | `PENDING` → `APPROVED` / `BLOCKED` / etc. |
| `evidence` | jsonb | Metadata only (policy_rule, ai_confidence) |
| `created_at` | timestamptz | Auto-set |
| `updated_at` | timestamptz | Auto-updated via trigger |

### `public.ai_action_audit_logs`
Immutable append-only log. Never updated or deleted.

| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid PK | Auto-generated |
| `tenant_id` | text | Scoping |
| `action_request_id` | uuid FK | References `ai_action_requests(id)` |
| `event_type` | text | e.g. `GOVERNANCE_DECISION` |
| `payload` | jsonb | Verdict, status, decision_code, policy_rule |
| `created_at` | timestamptz | Auto-set |

---

## 6. KFSA Mock Evaluator Rules

Implemented in node 9 (`KFSA Policy Evaluator`). Rules evaluated in priority order:

| Priority | Condition | Verdict | Status | `policy_rule` Code |
|----------|-----------|---------|--------|--------------------|
| 1 | `customer_id` OR `customer_name` is null/empty | FIX | NEEDS_FIX | `MISSING_CUSTOMER_DATA` |
| 2 | `aging_bucket = "+180"` AND `policy_context.legal_ready = false` | KILL | BLOCKED | `LEGAL_NOT_READY_AGED_180` |
| 3 | `amount > 500,000` AND `risk_level = "HIGH"` | ALERT | ESCALATED | `HIGH_VALUE_HIGH_RISK` |
| 4 | `amount ≤ 500,000` AND `risk_level ∈ {LOW, MEDIUM}` | SCALE | APPROVED | `WITHIN_AUTO_THRESHOLD` |
| 5 | (default) | ALERT | ESCALATED | `DEFAULT_ALERT` |

**`execution_allowed`** is `true` only when `verdict = SCALE` (status = `APPROVED`).

---

## 7. How to Test the Webhook

After activating the workflow in n8n, copy the webhook URL from node 1. Then:

### Quick test (SCALE verdict — should APPROVE)
```bash
curl -X POST https://your-n8n-instance.com/webhook/ai-governance-collections \
  -H "Content-Type: application/json" \
  -d '{
    "tenant_id": "demo-tenant",
    "source_type": "AI",
    "customer_id": "CUST-1001",
    "customer_name": "شركة الاختبار للتجارة",
    "amount": 275000,
    "aging_bucket": "90-180",
    "risk_level": "MEDIUM",
    "policy_context": {
      "legal_ready": true,
      "previous_contact_attempts": 3,
      "has_dispute": false
    }
  }'
```

### Expected response (SCALE path)
```json
{
  "action_request_id": "<uuid>",
  "recommended_action": "PAYMENT_PLAN",
  "verdict": "SCALE",
  "status": "APPROVED",
  "decision_required": true,
  "decision_code": "KFSA-MOCK-1746619200000",
  "execution_allowed": true,
  "evidence_logged": true,
  "ai_reason": "Customer has manageable debt with medium risk profile",
  "timestamp": "2026-05-07T12:00:00.000Z"
}
```

All 5 test scenarios are in `docs/test-payloads/ai-action-governance-sample.json`.

---

## 8. n8n Workflow Node Summary

| # | Node | Type | Key Behaviour |
|---|------|------|---------------|
| 1 | Webhook — Receive Debt Payload | webhook | POST trigger; holds connection until respondToWebhook fires |
| 2 | Validate Payload | code | Checks tenant_id, source_type; flags errors |
| 3 | Is Payload Valid? | if | Routes to error path or happy path |
| 4 | Respond 400 — Invalid Payload | respondToWebhook | Returns 400 with validation error list |
| 5 | Generate action_request_id | code | UUID v4 for request + decision; builds insertPayload |
| 6 | POST action_request — PENDING | httpRequest | Supabase REST INSERT; row enters lifecycle as PENDING |
| 7 | Call OpenAI — Collection Recommendation | httpRequest | gpt-4o-mini; structured JSON response |
| 8 | Parse AI Response | code | Extracts action + reason; merges original context |
| 9 | KFSA Policy Evaluator | code | 4 rules → verdict + policy_rule + policy_notes |
| 10 | Map Verdict to Status | code | SCALE→APPROVED etc.; sets execution_allowed flag |
| 11 | PATCH action_request — Verdict + Status | httpRequest | Supabase REST PATCH; filters by id=eq.{uuid} |
| 12 | POST Audit Log Entry | httpRequest | Supabase INSERT into audit_logs; metadata only |
| 13 | Build Final Response | code | Assembles clean governance response JSON |
| 14 | Respond 200 — Governance Decision | respondToWebhook | Returns 200 with full governance decision |

---

## 9. Known Limitations

| Limitation | Impact | Mitigation Path |
|-----------|--------|-----------------|
| KFSA mock evaluator | Decisions not legally binding | Replace node 9 with HTTP call to `KFSA_EVALUATION_ENDPOINT` |
| `tenant_id` stored as `text` | No FK integrity to tenants table | Change to `uuid` FK in production migration |
| OpenAI timeout not handled | Workflow fails if OpenAI >30s | Add n8n error workflow + retry logic |
| No human approval loop | ESCALATED/NEEDS_FIX not actionable | Add n8n Wait node + approval webhook |
| Prototype has no auth on webhook | Endpoint is open | Add n8n webhook header auth or IP allowlist |
| Single-tenant demo | No tenant isolation in queries | Add `tenant_id=eq.` filter to all Supabase reads |

---

## 10. Next Production Steps

1. **Replace KFSA mock**: Swap Code node 9 with an HTTP Request to the real KFSA evaluation endpoint
2. **Webhook authentication**: Add `Authorization` header validation at node 1 (n8n supports header auth)
3. **Error workflow**: Create a global n8n error workflow to catch and log unhandled exceptions
4. **Human approval loop**: Add Wait + approval webhook for `ESCALATED` and `NEEDS_FIX` statuses
5. **Notifications**: Add Slack/Teams node after node 11 for `BLOCKED` verdicts
6. **Tenant validation**: Add Supabase query to validate `tenant_id` exists before processing
7. **Production DB migration**: Change `tenant_id` to `uuid` with FK reference to tenants table
8. **Rate limiting**: Add n8n rate limiting or API gateway in front of the webhook
9. **Monitoring**: Enable n8n execution history and set up alerts on execution failures
10. **Anthropic fallback**: Add a fallback Code node if OpenAI is unavailable, using `ANTHROPIC_API_KEY`

---

## Appendix A — Governance Response Schema

```json
{
  "action_request_id": "string (uuid)",
  "recommended_action": "string (CALL_CUSTOMER|SEND_NOTICE|LEGAL_REFERRAL|PAYMENT_PLAN|WRITE_OFF|ESCALATE_MANAGER)",
  "verdict": "string (KILL|FIX|ALERT|SCALE)",
  "status": "string (APPROVED|NEEDS_FIX|ESCALATED|BLOCKED)",
  "decision_required": true,
  "decision_code": "string (KFSA-MOCK-{timestamp})",
  "execution_allowed": "boolean",
  "evidence_logged": true,
  "ai_reason": "string",
  "timestamp": "string (ISO 8601)"
}
```

## Appendix B — Supabase REST API Patterns Used

| Operation | Method | URL Pattern | Header |
|-----------|--------|-------------|--------|
| Insert row | POST | `/rest/v1/{table}` | `Prefer: return=representation` |
| Update row | PATCH | `/rest/v1/{table}?id=eq.{uuid}` | `Prefer: return=representation` |
| Auth | Both | All requests | `apikey: {key}` + `Authorization: Bearer {key}` |
