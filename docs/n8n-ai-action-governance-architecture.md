# AI Action Governance — Architecture
## NEXGEGL Collections Prototype

---

## Core Principle

> **AI Recommendation ≠ Decision ≠ Execution**

Every AI output must become an `action_request` record **before** any evaluation. No execution occurs without a `decision_id` and `decision_code`.

---

## Pipeline Diagram

```
Webhook Client (POST)
       │
       ▼
┌──────────────────────┐
│  n8n Webhook Trigger │  POST /webhook/ai-governance-collections
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│  Validate Payload    │  Check: tenant_id, source_type required
└──────────┬───────────┘
           │
    valid? ├── NO ──► 400 JSON { errors: [...] }
           │
           ▼
┌──────────────────────┐
│  Generate UUID       │  Create action_request_id + decision_id
│  Prepare Insert      │  Build insertPayload with status=PENDING
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│  Supabase INSERT     │  POST /rest/v1/ai_action_requests
│  status = PENDING    │  Row locked until governance decision
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│  OpenAI API          │  gpt-4o-mini chat completions
│  AI Recommendation   │  Returns: recommended_action + reason
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│  Parse AI Response   │  Extract action + reason from JSON
│  (with fallback)     │  Merge with original request context
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│  KFSA Policy         │  Apply 4 governance rules (mock)
│  Evaluator           │  Output: verdict + policy_rule + notes
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│  Map Verdict         │  SCALE→APPROVED, FIX→NEEDS_FIX
│  to Status           │  ALERT→ESCALATED, KILL→BLOCKED
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│  Supabase PATCH      │  Update: verdict, status, decision_code
│  action_request      │  evidence: { policy_rule, ai_confidence }
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│  Supabase INSERT     │  Append to ai_action_audit_logs
│  Audit Log           │  event_type: GOVERNANCE_DECISION
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│  Final Response      │  200 JSON with full governance decision
└──────────────────────┘
```

---

## Components

### n8n (Orchestration Layer)
- Runs the governance pipeline end-to-end
- Does **not** make decisions — only routes and persists
- No AI action executes directly from n8n

### Supabase (Source of Truth)
- All `action_requests` and `audit_logs` stored here
- Every governance event is traceable and immutable (audit log)
- No record is deleted in the prototype

### AI Model (Recommender Only)
- Role: suggest a collection action from an approved list
- Output: `recommended_action` + `ai_reason` + `confidence`
- **Cannot trigger execution** — recommendation only

### KFSA Policy Evaluator (Governance Gate)
- Role: mandatory policy gate before any status change
- Mock implementation built into the workflow
- Real endpoint injectable via `KFSA_EVALUATION_ENDPOINT` env var

---

## KFSA Mock Evaluator Rules

Rules are evaluated in priority order:

| Priority | Condition | Verdict | Status | Policy Rule Code |
|----------|-----------|---------|--------|------------------|
| 1 | `customer_id` OR `customer_name` is missing | **FIX** | NEEDS_FIX | `MISSING_CUSTOMER_DATA` |
| 2 | `aging_bucket = "+180"` AND `policy_context.legal_ready = false` | **KILL** | BLOCKED | `LEGAL_NOT_READY_AGED_180` |
| 3 | `amount > 500,000` AND `risk_level = "HIGH"` | **ALERT** | ESCALATED | `HIGH_VALUE_HIGH_RISK` |
| 4 | `amount ≤ 500,000` AND `risk_level ∈ {LOW, MEDIUM}` | **SCALE** | APPROVED | `WITHIN_AUTO_THRESHOLD` |
| 5 | (default) | **ALERT** | ESCALATED | `DEFAULT_ALERT` |

---

## Verdict → Status → Execution Matrix

| Verdict | Status | Execution Allowed | Meaning |
|---------|--------|-------------------|---------|
| SCALE | APPROVED | ✅ Yes | Within thresholds — safe to proceed |
| FIX | NEEDS_FIX | ❌ No | Incomplete data — fix and resubmit |
| ALERT | ESCALATED | ❌ No | Requires human review before action |
| KILL | BLOCKED | ❌ No | Action forbidden by KFSA policy |

---

## Response Schema

```json
{
  "action_request_id": "uuid",
  "recommended_action": "PAYMENT_PLAN",
  "verdict": "SCALE",
  "status": "APPROVED",
  "decision_required": true,
  "decision_code": "KFSA-MOCK-1746619200000",
  "execution_allowed": true,
  "evidence_logged": true,
  "ai_reason": "Customer has manageable debt with low risk profile",
  "timestamp": "2026-05-07T12:00:00.000Z"
}
```

---

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `SUPABASE_URL` | ✅ Yes | Supabase project URL (e.g. `https://xxx.supabase.co`) |
| `SUPABASE_SERVICE_ROLE_KEY` | ✅ Yes | Service role key — used server-side in n8n only |
| `OPENAI_API_KEY` | ✅ Yes | OpenAI API key for `gpt-4o-mini` |
| `KFSA_EVALUATION_ENDPOINT` | ❌ Optional | Real KFSA endpoint; mock rules apply if not set |

---

## Security Boundaries

- **PII stored**: `customer_name` and `customer_id` only
- **No external execution**: no email, WhatsApp, payment, or SMS nodes
- **Execution is simulated**: `execution_allowed` flag is returned but no real action fires
- **No UI-created decisions**: decisions come from KFSA evaluation only
- **No destructive DB operations**: INSERT + PATCH only
- **Service role key**: never exposed to client; stays inside n8n environment

---

## n8n Workflow Node Inventory

| # | Node Name | Type | Purpose |
|---|-----------|------|---------|
| 1 | Webhook — Receive Debt Payload | webhook | Entry point |
| 2 | Validate Payload | code | Required field checks |
| 3 | Is Payload Valid? | if | Route valid vs invalid |
| 4 | Respond 400 — Invalid Payload | respondToWebhook | Error response |
| 5 | Generate action_request_id | code | UUID generation + insert prep |
| 6 | POST action_request — PENDING | httpRequest | Supabase INSERT |
| 7 | Call OpenAI — Collection Recommendation | httpRequest | AI inference |
| 8 | Parse AI Response | code | Extract recommendation |
| 9 | KFSA Policy Evaluator | code | Apply governance rules |
| 10 | Map Verdict to Status | code | SCALE→APPROVED etc. |
| 11 | PATCH action_request — Verdict + Status | httpRequest | Supabase PATCH |
| 12 | POST Audit Log Entry | httpRequest | Supabase INSERT audit |
| 13 | Build Final Response | code | Assemble response JSON |
| 14 | Respond 200 — Governance Decision | respondToWebhook | Success response |

---

## Extension Points

1. **Real KFSA endpoint**: replace Code node 9 with an HTTP Request to `$env.KFSA_EVALUATION_ENDPOINT`
2. **Human approval loop**: add a Wait node for ESCALATED/NEEDS_FIX statuses
3. **Notifications**: add Slack/Teams node after KILL verdict for compliance alerts
4. **Anthropic model**: swap OpenAI node for Anthropic API call using `ANTHROPIC_API_KEY`
5. **Retry logic**: add error workflow in n8n Settings for OpenAI/Supabase failures
