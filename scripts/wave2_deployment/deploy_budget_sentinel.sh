#!/usr/bin/env bash
# =============================================================================
# deploy_budget_sentinel.sh — deploys the Budget Sentinel worker by REUSING
# the existing worker name acidwurx-cost-monitor (July audit directive: one
# worker = one billable entrypoint). Ensures KV namespace ACIDWURX_SPEND_KV,
# substitutes @@SPEND_KV_ID@@ into a temp copy (the repo file keeps the token),
# then wrangler deploy. Skips gracefully without npx/tokens.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SRC_DIR="${REPO_ROOT}/infra/cloudflare/budget-sentinel"

if [ -z "${CLOUDFLARE_API_TOKEN:-}" ] || [ -z "${CF_ACCOUNT_ID:-}" ]; then
  echo "[sentinel] SKIPPED: CLOUDFLARE_API_TOKEN/CF_ACCOUNT_ID not hydrated"
  exit 0
fi
if ! command -v npx >/dev/null 2>&1; then
  echo "[sentinel] SKIPPED: npx (Node) not installed — deploy via CI edge-apply job instead"
  exit 0
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT
cp -r "${SRC_DIR}/." "${WORKDIR}/"

echo "[sentinel] ensuring KV namespace ACIDWURX_SPEND_KV"
KV_LIST="$(CLOUDFLARE_ACCOUNT_ID="${CF_ACCOUNT_ID}" npx --yes wrangler kv namespace list --output json 2>/dev/null || echo "[]")"
KV_ID="$(printf '%s' "${KV_LIST}" | python3 -c "
import json,sys
try:
    data=json.load(sys.stdin)
except Exception:
    data=[]
for ns in data:
    if ns.get('title')=='ACIDWURX_SPEND_KV':
        print(ns.get('id','')); break
" || true)"

if [ -z "${KV_ID}" ]; then
  KV_CREATE="$(CLOUDFLARE_ACCOUNT_ID="${CF_ACCOUNT_ID}" npx --yes wrangler kv namespace create ACIDWURX_SPEND_KV 2>&1 || true)"
  KV_ID="$(printf '%s' "${KV_CREATE}" | grep -oE '[0-9a-f]{32}' | head -1 || true)"
fi

if [ -z "${KV_ID}" ]; then
  echo "[sentinel] FAILED: could not resolve/create KV namespace id"
  printf '%s\n' "${KV_CREATE:-}" | head -c 400
  exit 1
fi
echo "[sentinel] KV id resolved (fingerprint: ${KV_ID:0:8}...)"

sed "s/@@SPEND_KV_ID@@/${KV_ID}/" "${SRC_DIR}/wrangler.toml" > "${WORKDIR}/wrangler.toml"
sed -i "s/@@CF_ACCOUNT_ID@@/${CF_ACCOUNT_ID}/" "${WORKDIR}/wrangler.toml"
if grep -q "@@" "${WORKDIR}/wrangler.toml"; then
  echo "[sentinel] FAILED: substitution token(s) still present — aborting (honesty law)"
  exit 1
fi

echo "[sentinel] deploying worker acidwurx-cost-monitor"
(cd "${WORKDIR}" && CLOUDFLARE_ACCOUNT_ID="${CF_ACCOUNT_ID}" npx --yes wrangler deploy)
echo "[sentinel] deploy complete"
