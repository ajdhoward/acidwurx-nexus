#!/usr/bin/env bash
# =============================================================================
# fleet_apply.sh — BULK configuration deploy with canary discipline.
#   ./fleet_apply.sh                 # check mode: --check --diff across fleet
#   APPLY=1 ./fleet_apply.sh         # canary host first, verify, then fleet
#   CANARY_HOST=markslone ./fleet_apply.sh
#   ./fleet_apply.sh --syntax-only   # fastest gate (no connections)
# Zero prompts; per-phase receipts; honest non-zero exits (Law 10).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ANSIBLE_DIR="${REPO_ROOT}/infra/ansible"
CANARY_HOST="${CANARY_HOST:-jessicafletcher}"
APPLY="${APPLY:-0}"
TS="$(date +%Y%m%d-%H%M%S)"
RECEIPT_DIR="${REPO_ROOT}/docs/discovery/wave1"
mkdir -p "${RECEIPT_DIR}"

cd "${ANSIBLE_DIR}"
command -v ansible-playbook >/dev/null 2>&1 || { echo "FATAL: ansible-playbook not installed (pip install ansible-core)"; exit 1; }

if [ "${1:-}" = "--syntax-only" ]; then
  ansible-playbook -i inventory.ini playbook.yml --syntax-check
  echo "[fleet-apply] syntax OK"
  exit 0
fi

run_phase() {
  local name="$1"; shift
  echo ""
  echo "================ PHASE: ${name} ================"
  local log="${RECEIPT_DIR}/fleet-apply-${name}-${TS}.log"
  local rc=0
  ansible-playbook -i inventory.ini playbook.yml "$@" 2>&1 | tee "${log}" || rc=${PIPESTATUS[0]}
  echo "[fleet-apply] phase ${name} rc=${rc} log=${log}"
  return "${rc}"
}

if [ "${APPLY}" != "1" ]; then
  echo "[fleet-apply] CHECK MODE (set APPLY=1 to mutate). Canary will be: ${CANARY_HOST}"
  run_phase "check-canary" --check --diff --limit "${CANARY_HOST}" || true
  run_phase "check-fleet" --check --diff || true
  echo ""
  echo "[fleet-apply] check complete — review diffs above; re-run with APPLY=1 to execute"
  exit 0
fi

echo "[fleet-apply] APPLY MODE — canary first (${CANARY_HOST}), then fleet"
if ! run_phase "apply-canary" --limit "${CANARY_HOST}"; then
  echo "[fleet-apply] CANARY FAILED — fleet apply aborted (nothing further touched)"
  exit 1
fi
echo "[fleet-apply] canary OK — proceeding to fleet (excluding canary)"
if ! run_phase "apply-fleet" --limit "fleet:!${CANARY_HOST}"; then
  echo "[fleet-apply] FLEET PHASE reported failures — inspect log; re-run is safe (idempotent)"
  exit 1
fi
echo "[fleet-apply] fleet apply complete"
if [ -x "${REPO_ROOT}/scripts/wave2_deployment/notify.sh" ]; then
  bash "${REPO_ROOT}/scripts/wave2_deployment/notify.sh" "nexo fleet-apply" "APPLY complete: canary ${CANARY_HOST} + fleet" 4 "heavy_check_mark" || true
fi
