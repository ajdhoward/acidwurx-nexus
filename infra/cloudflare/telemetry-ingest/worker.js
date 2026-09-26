// =============================================================================
// nexo-telemetry-ingest — Cloudflare Worker (edge sink for the z.ai handoff).
// Contract: docs/interop/ZAI_HANDOFF_SCHEMA.md (schema_version 1).
//   * POST /v1/telemetry  — HMAC-SHA256 signed envelope -> D1 batch upserts.
//   * GET  /v1/registry | /v1/fragments | /v1/ledger — signed read-backs.
//   * GET  /health        — unsigned liveness.
// Bindings: DB (D1, nexo-telemetry). Vars: SCHEMA_VERSION, RATE_LIMIT_PER_MIN.
// Secret: NEXO_INGEST_HMAC_KEY — when empty the worker FAILS CLOSED (401 on
// every signed route): an unkeyed sink must never accept writes.
// Signature scheme (Stripe-style, replay-safe):
//   X-Nexo-Signature: t=<unix>,v1=<hex hmac-sha256(secret, payloadString)>
//   POST payloadString = "<t>.<rawBody>"
//   GET  payloadString = "<t>.GET <pathWithQuery>"
// =============================================================================

const REPLAY_WINDOW_SECONDS = 300;
const MAX_BODY_BYTES = 1048576;
const MAX_FRAGMENT_BYTES = 262144;
const MAX_RECORDS = 500;
const SELECT_LIMIT = 200;

const TABLES = {
  mcp_server_registry: {
    columns: ["node", "server_name", "transport", "listen_path", "pid", "status",
              "context_bounds", "capabilities", "first_seen", "last_seen"],
    required: ["node", "server_name", "first_seen", "last_seen"],
    defaults: { transport: "stdio", listen_path: "", status: "unknown", capabilities: "[]" },
    conflict: "(node, server_name, listen_path)",
    updates: "transport=excluded.transport, pid=excluded.pid, status=excluded.status, " +
             "context_bounds=excluded.context_bounds, capabilities=excluded.capabilities, " +
             "first_seen=COALESCE(mcp_server_registry.first_seen, excluded.first_seen), " +
             "last_seen=excluded.last_seen",
  },
  partial_code_fragments: {
    columns: ["fragment_id", "repo", "target_file", "language", "purpose", "content",
              "content_sha256", "status", "source_agent", "peer_review", "created_at", "updated_at"],
    required: ["fragment_id", "target_file", "language", "content", "content_sha256",
               "source_agent", "created_at", "updated_at"],
    defaults: { repo: "acidwurx-nexus", status: "proposed" },
    conflict: "(fragment_id)",
    updates: "repo=excluded.repo, target_file=excluded.target_file, language=excluded.language, " +
             "purpose=excluded.purpose, content=excluded.content, content_sha256=excluded.content_sha256, " +
             "peer_review=excluded.peer_review, updated_at=excluded.updated_at, " +
             "status=CASE WHEN partial_code_fragments.status='merged' " +
             "THEN partial_code_fragments.status ELSE excluded.status END",
  },
  cost_governance_ledger: {
    columns: ["period", "scope", "model_or_service", "requests", "cost_pence", "cap_pence",
              "notes", "recorded_at"],
    required: ["period", "scope", "recorded_at"],
    defaults: { model_or_service: "", requests: 0, cost_pence: 0 },
    conflict: "(period, scope, model_or_service)",
    updates: "requests=MAX(cost_governance_ledger.requests, excluded.requests), " +
             "cost_pence=excluded.cost_pence, cap_pence=excluded.cap_pence, " +
             "notes=excluded.notes, recorded_at=excluded.recorded_at",
  },
};

// Best-effort per-isolate sliding-window rate limiter (edge instances are
// ephemeral; this damps bursts, CF's platform limits backstop the rest).
const hitLog = [];

function json(body, status, extraHeaders) {
  const headers = Object.assign(
    { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
    extraHeaders || {},
  );
  return new Response(JSON.stringify(body), { status: status, headers: headers });
}

function err(code, message, status) {
  return json({ error: code, detail: message }, status);
}

function rateLimited(limitPerMin) {
  const now = Date.now();
  while (hitLog.length && now - hitLog[0] > 60000) {
    hitLog.shift();
  }
  if (hitLog.length >= limitPerMin) {
    return true;
  }
  hitLog.push(now);
  return false;
}

async function hmacHex(secret, message) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  let out = "";
  const bytes = new Uint8Array(mac);
  for (let i = 0; i < bytes.length; i++) {
    out += bytes[i].toString(16).padStart(2, "0");
  }
  return out;
}

function timingSafeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) {
    return false;
  }
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

async function verifySignature(request, secret, payloadString) {
  const header = request.headers.get("X-Nexo-Signature") || "";
  const parts = {};
  header.split(",").forEach((kv) => {
    const eq = kv.indexOf("=");
    if (eq > 0) {
      parts[kv.slice(0, eq).trim()] = kv.slice(eq + 1).trim();
    }
  });
  if (!parts.t || !parts.v1) {
    return { ok: false, reason: "missing t= or v1= component" };
  }
  const ts = parseInt(parts.t, 10);
  if (!Number.isFinite(ts)) {
    return { ok: false, reason: "non-numeric timestamp" };
  }
  const now = Math.floor(Date.now() / 1000);
  if (Math.abs(now - ts) > REPLAY_WINDOW_SECONDS) {
    return { ok: false, reason: "timestamp outside 300s replay window" };
  }
  const expected = await hmacHex(secret, ts + "." + payloadString);
  if (!timingSafeEqual(expected, parts.v1.toLowerCase())) {
    return { ok: false, reason: "signature mismatch" };
  }
  return { ok: true };
}

function sanitizeRow(table, row, problems, index) {
  const spec = TABLES[table];
  const clean = {};
  for (const col of spec.columns) {
    if (row[col] === undefined || row[col] === null) {
      if (spec.defaults && col in spec.defaults) {
        clean[col] = spec.defaults[col];
      } else {
        clean[col] = null;
      }
    } else {
      const v = row[col];
      clean[col] = typeof v === "object" ? JSON.stringify(v) : v;
    }
  }
  for (const req of spec.required) {
    if (clean[req] === null || clean[req] === "") {
      problems.push({ index: index, reason: "missing column: " + req });
      return null;
    }
  }
  if (table === "partial_code_fragments") {
    if (String(clean.content).length > MAX_FRAGMENT_BYTES) {
      problems.push({ index: index, reason: "content exceeds 256KiB" });
      return null;
    }
  }
  return clean;
}

function insertStatement(table, row, op) {
  const spec = TABLES[table];
  const cols = spec.columns;
  const placeholders = cols.map(() => "?").join(", ");
  let sql = "INSERT INTO " + table + " (" + cols.join(", ") + ") VALUES (" + placeholders + ")";
  if (op === "upsert") {
    sql += " ON CONFLICT " + spec.conflict + " DO UPDATE SET " + spec.updates;
  }
  return { sql: sql, values: cols.map((c) => row[c]) };
}

async function handleTelemetryPost(request, env) {
  const raw = await request.text();
  if (raw.length > MAX_BODY_BYTES) {
    return err("body_too_large", "envelope exceeds 1MiB", 413);
  }
  const check = await verifySignature(request, env.NEXO_INGEST_HMAC_KEY, raw);
  if (!check.ok) {
    return err("signature_invalid", check.reason, 401);
  }
  let envelope;
  try {
    envelope = JSON.parse(raw);
  } catch (e) {
    return err("invalid_json", String(e), 400);
  }
  if (!envelope || envelope.schema_version !== parseInt(env.SCHEMA_VERSION || "1", 10)) {
    return err("schema_version", "unsupported schema_version (worker accepts " + (env.SCHEMA_VERSION || "1") + ")", 400);
  }
  const records = Array.isArray(envelope.records) ? envelope.records : null;
  if (!records || records.length === 0 || records.length > MAX_RECORDS) {
    return err("records", "records must be an array of 1.." + MAX_RECORDS, 400);
  }
  const statements = [];
  const rejected = [];
  for (let i = 0; i < records.length; i++) {
    const rec = records[i] || {};
    const table = rec.table;
    const op = rec.op === "insert" ? "insert" : "upsert";
    if (!(table in TABLES)) {
      rejected.push({ index: i, reason: "table not whitelisted: " + String(table) });
      continue;
    }
    const row = sanitizeRow(table, rec.row || {}, rejected, i);
    if (!row) {
      continue;
    }
    statements.push(insertStatement(table, row, op));
  }
  if (statements.length > 0) {
    await env.DB.batch(statements.slice(0, MAX_RECORDS));
  }
  return json({
    accepted: statements.length,
    rejected: rejected,
    node: envelope.node || null,
    run_id: envelope.run_id || null,
  }, 200);
}

async function handleRead(request, env, route) {
  const url = new URL(request.url);
  const payloadString = "GET " + url.pathname + url.search;
  const check = await verifySignature(request, env.NEXO_INGEST_HMAC_KEY, payloadString);
  if (!check.ok) {
    return err("signature_invalid", check.reason, 401);
  }
  let sql;
  const bindings = [];
  if (route === "registry") {
    sql = "SELECT * FROM mcp_server_registry";
    const node = url.searchParams.get("node");
    if (node) {
      sql += " WHERE node = ?";
      bindings.push(node);
    }
    sql += " ORDER BY last_seen DESC LIMIT " + SELECT_LIMIT;
  } else if (route === "fragments") {
    sql = "SELECT fragment_id, repo, target_file, language, purpose, content_sha256, status, source_agent, peer_review, created_at, updated_at FROM partial_code_fragments";
    const conds = [];
    const status = url.searchParams.get("status");
    const target = url.searchParams.get("target_file");
    if (status) {
      conds.push("status = ?");
      bindings.push(status);
    }
    if (target) {
      conds.push("target_file = ?");
      bindings.push(target);
    }
    if (conds.length) {
      sql += " WHERE " + conds.join(" AND ");
    }
    sql += " ORDER BY updated_at DESC LIMIT " + SELECT_LIMIT;
  } else {
    sql = "SELECT * FROM cost_governance_ledger";
    const period = url.searchParams.get("period");
    if (period) {
      sql += " WHERE period = ?";
      bindings.push(period);
    }
    sql += " ORDER BY recorded_at DESC LIMIT " + SELECT_LIMIT;
  }
  const result = await env.DB.prepare(sql).bind(...bindings).all();
  return json({ route: route, count: (result.results || []).length, rows: result.results || [] }, 200);
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const limit = parseInt(env.RATE_LIMIT_PER_MIN || "30", 10);

    if (request.method === "GET" && url.pathname === "/health") {
      return json({ status: "ok", worker: "nexo-telemetry-ingest", schema_version: parseInt(env.SCHEMA_VERSION || "1", 10) }, 200);
    }
    if (request.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
          "Access-Control-Allow-Headers": "Content-Type, X-Nexo-Signature",
        },
      });
    }

    if (!env.NEXO_INGEST_HMAC_KEY || env.NEXO_INGEST_HMAC_KEY.length === 0) {
      // FAIL CLOSED: an unkeyed sink never accepts traffic (Law 5 + Law 9).
      return err("unkeyed", "NEXO_INGEST_HMAC_KEY not bound — ingest disabled (fail-closed)", 401);
    }
    if (rateLimited(limit)) {
      return err("rate_limited", "exceeds " + limit + " requests/min", 429);
    }

    if (request.method === "POST" && url.pathname === "/v1/telemetry") {
      try {
        return await handleTelemetryPost(request, env);
      } catch (e) {
        return err("internal", String(e), 500);
      }
    }
    if (request.method === "GET") {
      const routes = { "/v1/registry": "registry", "/v1/fragments": "fragments", "/v1/ledger": "ledger" };
      const route = routes[url.pathname];
      if (route) {
        try {
          return await handleRead(request, env, route);
        } catch (e) {
          return err("internal", String(e), 500);
        }
      }
    }
    return err("not_found", "unknown route: " + request.method + " " + url.pathname, 404);
  },
};
