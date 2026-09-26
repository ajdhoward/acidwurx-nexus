-- =============================================================================
-- infra/cloudflare/d1/schema.sql — Cloudflare D1 `nexo-telemetry`
-- z.ai hand-off tables (contract: docs/interop/ZAI_HANDOFF_SCHEMA.md).
-- Applied idempotently: wrangler d1 execute nexo-telemetry --remote --file schema.sql
-- or Pulumi-provisioned database + CI apply step. IF NOT EXISTS everywhere.
-- =============================================================================

CREATE TABLE IF NOT EXISTS mcp_server_registry (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  node            TEXT    NOT NULL,
  server_name     TEXT    NOT NULL,
  transport       TEXT    NOT NULL DEFAULT 'stdio',
  listen_path     TEXT    NOT NULL DEFAULT '',
  pid             INTEGER,
  status          TEXT    NOT NULL DEFAULT 'unknown',
  context_bounds  INTEGER,
  capabilities    TEXT    NOT NULL DEFAULT '[]',
  first_seen      TEXT    NOT NULL,
  last_seen       TEXT    NOT NULL,
  UNIQUE (node, server_name, listen_path)
);

CREATE TABLE IF NOT EXISTS partial_code_fragments (
  fragment_id     TEXT PRIMARY KEY,
  repo            TEXT NOT NULL DEFAULT 'acidwurx-nexus',
  target_file     TEXT NOT NULL,
  language        TEXT NOT NULL,
  purpose         TEXT,
  content         TEXT NOT NULL,
  content_sha256  TEXT NOT NULL,
  status          TEXT NOT NULL DEFAULT 'proposed',
  source_agent    TEXT NOT NULL,
  peer_review     TEXT,
  created_at      TEXT NOT NULL,
  updated_at      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS cost_governance_ledger (
  entry_id          INTEGER PRIMARY KEY AUTOINCREMENT,
  period            TEXT    NOT NULL,
  scope             TEXT    NOT NULL,
  model_or_service  TEXT    NOT NULL DEFAULT '',
  requests          INTEGER NOT NULL DEFAULT 0,
  cost_pence        INTEGER NOT NULL DEFAULT 0,
  cap_pence         INTEGER,
  notes             TEXT,
  recorded_at       TEXT    NOT NULL,
  UNIQUE (period, scope, model_or_service)
);

CREATE INDEX IF NOT EXISTS idx_mcp_node        ON mcp_server_registry (node);
CREATE INDEX IF NOT EXISTS idx_mcp_last_seen   ON mcp_server_registry (last_seen);
CREATE INDEX IF NOT EXISTS idx_frag_status     ON partial_code_fragments (status);
CREATE INDEX IF NOT EXISTS idx_frag_target     ON partial_code_fragments (target_file);
CREATE INDEX IF NOT EXISTS idx_frag_sha        ON partial_code_fragments (content_sha256);
CREATE INDEX IF NOT EXISTS idx_ledger_period   ON cost_governance_ledger (period);
CREATE INDEX IF NOT EXISTS idx_ledger_scope    ON cost_governance_ledger (scope);
