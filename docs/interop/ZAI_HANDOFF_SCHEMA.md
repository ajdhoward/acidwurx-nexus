# ZAI_HANDOFF_SCHEMA.md — Master Hand-off Interoperability Contract (schema_version 1)

Audience: the z.ai cloud-edge peer (GLM-class reasoning agent) and any future
edge collaborator. This document is the single normative contract for telemetry
hand-off between the local Sovereign Personal AI Mesh and Cloudflare-edge
storage/compute. Everything flows OUTBOUND through the WARP/tunnel path —
zero public inbound exposure (AI_README Law 5).

## 1. Transport & topology

```text
wave1 probes (LAN nodes)
  -> 00_master_orchestrator.sh  (normalizes to results.json, Stage 4)
  -> HTTPS POST (outbound via wgcf WARP / CF tunnel, never inbound)
  -> https://ingest.acidwurx.org/v1/telemetry
  -> Worker `nexo-telemetry-ingest` (edge, HMAC-verified, table-whitelisted)
  -> Cloudflare D1 database `nexo-telemetry`
       ├── mcp_server_registry        (live MCP/Ollama server inventory)
       ├── partial_code_fragments     (cross-agent code hand-off ledger)
       └── cost_governance_ledger     (£5 cap accounting mirror)
```

z.ai reads back through the same worker (GET endpoints, §5) or via the
Cloudflare REST API against D1 — never by direct node access.

## 2. Authentication: HMAC-SHA256 signed envelopes

- Shared secret: `NEXO_INGEST_HMAC_KEY` (>=32 random bytes, sops-managed;
  bound into the worker as a secret; hydrated locally via `.env`).
- Signature header (Stripe-style, replay-safe):

```text
X-Nexo-Signature: t=1789000000,v1=9a1c...e5f3
```

- Signed payload string for POST: `"<t>.<rawBody>"` (raw bytes, exact).
- Signed payload string for GET:  `"<t>.<METHOD> <pathWithQuery>"`
  e.g. `"1789000000.GET /v1/fragments?status=proposed"`.
- `v1` = lowercase hex HMAC-SHA256(secret, payloadString).
- Replay window: |now - t| <= 300 seconds. Constant-time comparison at the edge.
- Rejections: 401 (bad/missing/expired signature), 400 (schema violation),
  413 (body > 1 MiB), 429 (> 30 requests/min per IP). All rejections return
  JSON `{"error": ..., "code": ...}` — no HTML, machine-readable always.

## 3. POST /v1/telemetry — envelope schema (normative)

```json
{
  "schema_version": 1,
  "node": "jessicafletcher",
  "run_id": "20260925-043012",
  "generated": "2026-09-25T04:31:44+00:00",
  "records": [
    { "table": "mcp_server_registry", "op": "upsert", "row": { } },
    { "table": "cost_governance_ledger", "op": "upsert", "row": { } },
    { "table": "partial_code_fragments", "op": "upsert", "row": { } }
  ]
}
```

Rules: `schema_version` MUST be 1; `records` length 1..500; `table` MUST be one
of the three whitelisted tables; `op` is `insert` or `upsert` (upsert = ON
CONFLICT DO UPDATE per §4); unknown columns are dropped server-side; missing
required columns reject the individual record (others still commit). Response:

```json
{ "accepted": 12, "rejected": [ { "index": 7, "reason": "missing column: server_name" } ] }
```

## 4. D1 tables — columns, producers, and conflict semantics

### 4.1 mcp_server_registry  (producer: probe 05 via orchestrator push)
| column | type | notes |
|---|---|---|
| id | INTEGER PK AUTOINCREMENT | |
| node | TEXT NOT NULL | fleet hostname (e.g. jessicafletcher) |
| server_name | TEXT NOT NULL | e.g. `ollama:qwen2.5-coder:7b`, `fastmcp:nexo-tasks`, path basename for config hits |
| transport | TEXT NOT NULL DEFAULT 'stdio' | stdio / http / sse |
| listen_path | TEXT NOT NULL DEFAULT '' | URL or filesystem path ('' when unknown — NOT NULL keeps the UNIQUE index effective) |
| pid | INTEGER | null when not process-backed |
| status | TEXT NOT NULL DEFAULT 'unknown' | detected / ok / degraded / absent |
| context_bounds | INTEGER | num_ctx for Ollama profiles (probe 05 raw context bound) |
| capabilities | TEXT | JSON array string, e.g. ["chat","tools"] |
| first_seen | TEXT NOT NULL | ISO-8601 |
| last_seen | TEXT NOT NULL | ISO-8601 |

UNIQUE(node, server_name, listen_path); upsert updates status/context_bounds/
capabilities/last_seen, preserves first_seen via COALESCE.

### 4.2 partial_code_fragments  (producer: AI sub-agents / z.ai peer; Stage 10)
| column | type | notes |
|---|---|---|
| fragment_id | TEXT PK | agent-assigned ULID or sha256(content)[:16] |
| repo | TEXT NOT NULL DEFAULT 'acidwurx-nexus' | |
| target_file | TEXT NOT NULL | repo-relative path the fragment belongs to |
| language | TEXT NOT NULL | typescript / python / bash / yaml / hcl / sql |
| purpose | TEXT | one-line intent (feeds consolidation clustering) |
| content | TEXT NOT NULL | the fragment body — never truncated markers (Law: engine validator rejects on re-import) |
| content_sha256 | TEXT NOT NULL | dedupe key across agents |
| status | TEXT NOT NULL DEFAULT 'proposed' | proposed -> validated -> merged / rejected (validated requires scripts/ci/validate_repo.py pass; merged requires Stage-7 human gate) |
| source_agent | TEXT NOT NULL | e.g. `z.ai/glm-5-turbo`, `opencode-local`, `hermes-runner-2` |
| peer_review | TEXT | JSON verdict blob from reviewing agent |
| created_at / updated_at | TEXT NOT NULL | ISO-8601 |

Upsert on fragment_id: content/status/peer_review/updated_at refresh, but a
row already `merged` NEVER leaves `merged` via upsert (CASE guard in SQL).

### 4.3 cost_governance_ledger  (producers: probe 01 mirror, budget sentinel, LiteLLM)
| column | type | notes |
|---|---|---|
| entry_id | INTEGER PK AUTOINCREMENT | |
| period | TEXT NOT NULL | `YYYY-MM` (sentinel cap) or `YYYY-MM-DD` (daily detail) |
| scope | TEXT NOT NULL | ai-gateway / workers-ai / openrouter / workers-platform / infra |
| model_or_service | TEXT NOT NULL DEFAULT '' | e.g. `@cf/meta/llama-3.2-1b-instruct`, gateway id `acidwurx` |
| requests | INTEGER DEFAULT 0 | monotonic MAX() on upsert (counters never regress) |
| cost_pence | INTEGER DEFAULT 0 | integer pence; free-tier rows are 0 by definition |
| cap_pence | INTEGER | 500 = £5 monthly hard cap (Law 6) |
| notes | TEXT | JSON: cache/rate-limit config, burn-risk flags, worker counts |
| recorded_at | TEXT NOT NULL | ISO-8601 |

UNIQUE(period, scope, model_or_service).

## 5. Read-back endpoints for z.ai (same worker, GET + HMAC per §2)

| endpoint | returns |
|---|---|
| GET /health | liveness JSON (unsigned) |
| GET /v1/registry?node=<n> | mcp_server_registry rows (LIMIT 200, last_seen DESC) |
| GET /v1/fragments?status=proposed&target_file=<p> | fragments for review/merge triage |
| GET /v1/ledger?period=YYYY-MM | ledger rows for the period |

z.ai workflow loop: read `status=proposed` fragments -> review against
AI_README laws -> POST an upsert record flipping status to `validated` or
`rejected` with a `peer_review` JSON verdict -> human Stage-7 gate merges.

## 6. Webhook formatting (edge -> local, optional Wave-2 extension point)

When z.ai completes a review pass it may POST a completion webhook to the
local orchestrator through the private tunnel (service `http://192.168.1.179:9000`
class listener, mesh-only). Normative body:

```json
{
  "event": "fragment.review.completed",
  "run_id": "20260925-043012",
  "fragment_ids": ["01J8ZK..."],
  "verdicts": { "01J8ZK...": "validated" },
  "reviewer": "z.ai/glm-5-turbo",
  "signed_at": "2026-09-25T05:02:11+00:00"
}
```

Signed with the same X-Nexo-Signature scheme (secret shared via sops). The
local listener maps verdicts onto docs/tasks/tasks.json rows (Stage 10 chart).

## 7. Operational guarantees

- Push is best-effort and NEVER fails the wave: orchestrator retries once,
  writes `push_receipt.json` (status, http code, accepted/rejected counts)
  into the run directory, and continues. Law 10 honesty: a failed push is
  recorded, never masked.
- Idempotence: re-pushing the same run_id is safe — UNIQUE constraints +
  content_sha256 dedupe + MAX()/COALESCE merge semantics.
- Size guards: body <= 1 MiB; fragment content <= 256 KiB per row.
- Schema evolution: bump `schema_version` only with a worker that accepts
  N and N-1; the worker rejects unknown versions with 400 (never guesses).
