#!/usr/bin/env bash
# =============================================================================
# create_ai_gateway.sh — idempotent AI Gateway ensure (REST; the Terraform/
# Pulumi provider cannot manage AI Gateways — archive-verified limitation).
# GET-before-POST; never mutates an existing gateway. Skips gracefully when
# tokens or curl are absent (zero-prompt law).
# =============================================================================
set -euo pipefail

GW_ID="${AI_GATEWAY_ID:-acidwurx}"
API="https://api.cloudflare.com/client/v4"

if [ -z "${CF_API_TOKEN:-}" ] || [ -z "${CF_ACCOUNT_ID:-}" ]; then
  echo "[ai-gateway] SKIPPED: CF_API_TOKEN/CF_ACCOUNT_ID not hydrated"
  exit 0
fi
command -v curl >/dev/null 2>&1 || { echo "[ai-gateway] SKIPPED: curl not installed"; exit 0; }

echo "[ai-gateway] checking for existing gateway '${GW_ID}'"
LIST="$(curl -s --max-time 15 -H "Authorization: Bearer ${CF_API_TOKEN}" \
  "${API}/accounts/${CF_ACCOUNT_ID}/ai_gateway/universal_gateways" || true)"

if printf '%s' "${LIST}" | python3 -c "
import json,sys
try:
    body=json.load(sys.stdin)
except Exception:
    sys.exit(1)
result=body.get('result') or []
if isinstance(result,dict): result=result.get('gateways',[])
ids=[str(g.get('id') or g.get('name') or '') for g in result]
sys.exit(0 if '${GW_ID}' in ids else 1)
"; then
  echo "[ai-gateway] '${GW_ID}' already exists — no mutation performed"
  exit 0
fi

echo "[ai-gateway] creating '${GW_ID}' (cache 30d, 60 req/min, auth on)"
CREATE="$(curl -s --max-time 15 -X POST \
  -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
  --data '{"id":"'"${GW_ID}"'","auth_header":true,"cache":true,"cache_ttl":2592000,"rate_limit":60,"rate_limit_period":"m","collect_detailed_logs":false}' \
  "${API}/accounts/${CF_ACCOUNT_ID}/ai_gateway/universal_gateways" || true)"

if printf '%s' "${CREATE}" | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin).get('success') else 1)"; then
  echo "[ai-gateway] created OK"
  exit 0
else
  echo "[ai-gateway] create did not confirm success — response recorded below (endpoint shape may differ on this account; verify in dashboard)"
  printf '%s\n' "${CREATE}" | head -c 600
  exit 1
fi
