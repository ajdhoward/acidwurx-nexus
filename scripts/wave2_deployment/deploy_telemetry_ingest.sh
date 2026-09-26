#!/usr/bin/env bash
# =============================================================================
# deploy_telemetry_ingest.sh — provisions the z.ai handoff plane via wrangler:
#   1. ensures D1 database `nexo-telemetry` exists (captures its id),
#   2. applies infra/cloudflare/d1/schema.sql idempotently (IF NOT EXISTS),
#   3. substitutes @@D1_DATABASE_ID@@ into a temp wrangler.toml,
#   4. deploys nexo-telemetry-ingest and binds the HMAC secret from env.
# Skips gracefully without npx/tokens (zero-prompt law). Primary path remains
# Pulumi (Stage 8); this script is the wrangler fallback + schema applier.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SRC_DIR="${REPO_ROOT}/infra/cloudflare/telemetry-ingest"
SCHEMA="${REPO_ROOT}/infra/cloudflare/d1/schema.sql"

if [ -z "${CLOUDFLARE_API_TOKEN:-}" ] || [ -z "${CF_ACCOUNT_ID:-}" ]; then
  echo "[ingest] SKIPPED: CLOUDFLARE_API_TOKEN/CF_ACCOUNT_ID not hydrated"
  exit 0
fi
if ! command -v npx >/dev/null 2>&1; then
  echo "[ingest] SKIPPED: npx (Node) not installed — deploy via CI edge-apply (Pulumi) instead"
  exit 0
fi

export CLOUDFLARE_ACCOUNT_ID="${CF_ACCOUNT_ID}"

echo "[ingest] ensuring D1 database nexo-telemetry"
DB_LIST="$(npx --yes wrangler d1 list --output json 2>/dev/null || echo "[]")"
DB_ID="$(printf '%s' "${DB_LIST}" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
if isinstance(data, dict):
    data = data.get('results', data.get('databases', []))
for db in data:
    if db.get('name') == 'nexo-telemetry':
        print(db.get('uuid') or db.get('id') or '')
        break
" 2>/dev/null || true)"

if [ -z "${DB_ID}" ]; then
  CREATE_OUT="$(npx --yes wrangler d1 create nexo-telemetry 2>&1 || true)"
  DB_ID="$(printf '%s' "${CREATE_OUT}" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1 || true)"
fi

if [ -z "${DB_ID}" ]; then
  echo "[ingest] FAILED: could not resolve/create D1 database id"
  exit 1
fi
echo "[ingest] D1 id resolved (fingerprint: ${DB_ID:0:8}...)"

echo "[ingest] applying schema (idempotent IF NOT EXISTS)"
npx --yes wrangler d1 execute nexo-telemetry --remote --file "${SCHEMA}" >/dev/null

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT
cp -r "${SRC_DIR}/." "${WORKDIR}/"
sed "s/@@D1_DATABASE_ID@@/${DB_ID}/" "${SRC_DIR}/wrangler.toml" > "${WORKDIR}/wrangler.toml"
if grep -q "@@" "${WORKDIR}/wrangler.toml"; then
  echo "[ingest] FAILED: substitution token(s) still present — aborting (honesty law)"
  exit 1
fi

echo "[ingest] deploying worker nexo-telemetry-ingest"
(cd "${WORKDIR}" && npx --yes wrangler deploy)

if [ -n "${NEXO_INGEST_HMAC_KEY:-}" ]; then
  echo "[ingest] binding HMAC secret"
  printf '%s' "${NEXO_INGEST_HMAC_KEY}" | (cd "${WORKDIR}" && npx --yes wrangler secret put NEXO_INGEST_HMAC_KEY)
else
  echo "[ingest] NOTE: NEXO_INGEST_HMAC_KEY empty — worker stays fail-closed until the secret is bound"
fi
echo "[ingest] deploy complete"
