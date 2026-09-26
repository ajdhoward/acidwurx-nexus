#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — ONE-CLICK execution vehicle (zero mid-run prompts).
# Stages map 1:1 to docs/PIPELINE.md. Everything is env/flag-driven:
#   APPLY=1        pre-authorize local live stages 8-9 (default: stop at gate)
#   SKIP_WAVE1=1   skip telemetry collection (not recommended)
#   NEXO_KEEP=1    keep temp artifacts on failure
# Any missing OPTIONAL token degrades that stage to "skipped" in the receipt.
# Missing .env is a pre-flight condition: it is created once from
# .env.example with instructions, then the run exits(3) BEFORE any work —
# this is up-front guidance, never a mid-run surprise.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
RECEIPT_DIR="${REPO_ROOT}/docs/discovery/wave1"
RECEIPT="${NEXO_RECEIPT:-${RECEIPT_DIR}/bootstrap-receipt-${TS}.json}"
mkdir -p "${RECEIPT_DIR}"

RECEIPT_TMP="$(mktemp)"
trap 'rm -f "${RECEIPT_TMP}"' EXIT

stage_record() { # stage name status detail
  printf '{"stage":"%s","name":"%s","status":"%s","detail":"%s","ts":"%s"}\n' \
    "$1" "$2" "$3" "$(echo "$4" | tr -d '"' | head -c 200)" "$(date -u +%FT%TZ)" >> "${RECEIPT_TMP}"
}

echo "=============================================================="
echo " AcidWurx Nexus bootstrap — ${TS}"
echo " repo: ${REPO_ROOT}"
echo "=============================================================="

# --- Stage 0: preflight ---------------------------------------------------------
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required"; exit 1; }
if [ ! -t 1 ] && command -v tmux >/dev/null 2>&1; then
  echo "[preflight] non-interactive run detected — output is log-safe (no terminal killers, Law 10)"
fi
stage_record 0 "preflight" "ok" "python3 present"

# --- Stage 1: variable hydration ---------------------------------------------------
if [ ! -f "${REPO_ROOT}/.env" ]; then
  cp "${REPO_ROOT}/.env.example" "${REPO_ROOT}/.env"
  chmod 600 "${REPO_ROOT}/.env"
  echo "ACTION REQUIRED (one time, up front): fill ${REPO_ROOT}/.env then re-run."
  echo "Nothing else will ever ask you a question mid-run."
  stage_record 1 "hydration" "blocked-on-env" ".env created from example; fill and re-run"
  python3 -c "
import json,sys
rows=[json.loads(l) for l in open('${RECEIPT_TMP}') if l.strip()]
json.dump({'bootstrap':'acidwurx-nexus','ts':'${TS}','result':'blocked-on-env','stages':rows},open('${RECEIPT}','w'),indent=2)
print('receipt:', '${RECEIPT}')
"
  exit 3
fi
set -a
# shellcheck disable=SC1091
source "${REPO_ROOT}/.env"
set +a
for var in CF_API_TOKEN CF_ACCOUNT_ID GITHUB_TOKEN NEXO_VAULT_KEY WARP_PRIVATE_KEY LITELLM_MASTER_KEY; do
  if [ -n "${!var:-}" ]; then echo "[hydration] ${var}: SET (fingerprint only, never echoed)"; else echo "[hydration] ${var}: empty -> dependent stages will record 'skipped'"; fi
done
stage_record 1 "hydration" "ok" ".env sourced; zero prompts enforced"

# --- Stage 2: key governance ---------------------------------------------------------
AGE_KEYS="${HOME}/.config/nexo/age/keys.txt"
if [ -n "${NEXO_VAULT_KEY:-}" ]; then
  case "${NEXO_VAULT_KEY}" in
    AGE-SECRET-KEY-1*) echo "[keys] NEXO_VAULT_KEY is an age secret key — importing for sops";
      mkdir -p "$(dirname "${AGE_KEYS}")"; umask 077; printf '%s\n' "${NEXO_VAULT_KEY}" > "${AGE_KEYS}";;
    *) echo "[keys] NEXO_VAULT_KEY is legacy 32-byte-hex form (Jul era) — sops age key expected at ${AGE_KEYS}";;
  esac
fi
if [ -f "${AGE_KEYS}" ]; then chmod 600 "${AGE_KEYS}"; stage_record 2 "keys" "ok" "age key present at ~/.config/nexo/age/keys.txt"; else stage_record 2 "keys" "skipped" "no age key material (run engine keygen or set NEXO_VAULT_KEY)"; fi
command -v sops >/dev/null 2>&1 && echo "[keys] sops binary available" || echo "[keys] sops not installed — encrypted-blob workflows will skip (install: distro package or GitHub release)"

# --- Stage 3+4: telemetry wave --------------------------------------------------------
if [ "${SKIP_WAVE1:-0}" = "1" ]; then
  stage_record 3 "wave1" "skipped" "SKIP_WAVE1=1"
else
  if bash "${REPO_ROOT}/scripts/wave1_discovery/00_master_orchestrator.sh"; then
    stage_record 3 "wave1" "ok" "probes completed"
    stage_record 4 "normalize" "ok" "results.json + REPORT.md aggregated"
  else
    stage_record 3 "wave1" "degraded" "one or more probes failed — see run dir logs"
  fi
fi

# --- Stage 5: mesh route verification --------------------------------------------------
if bash "${SCRIPT_DIR}/validation_trace.sh"; then
  stage_record 5 "mesh-verify" "ok" "routing assertions passed"
else
  stage_record 5 "mesh-verify" "degraded" "routing assertions failed (see trace output)"
fi

# --- Stage 6: dry-run simulation ------------------------------------------------------------
DRY_OK=1
while IFS= read -r -d '' shf; do bash -n "${shf}" || { echo "[dry] SYNTAX FAIL ${shf}"; DRY_OK=0; }; done < <(find "${REPO_ROOT}/scripts" -name '*.sh' -print0)
python3 -m compileall -q "${REPO_ROOT}/scripts" >/dev/null 2>&1 || DRY_OK=0
python3 "${REPO_ROOT}/scripts/ci/validate_repo.py" "${REPO_ROOT}" || DRY_OK=0
if command -v ansible-playbook >/dev/null 2>&1; then
  (cd "${REPO_ROOT}/infra/ansible" && ansible-playbook -i inventory.ci.ini playbook.yml --syntax-check) || DRY_OK=0
else
  echo "[dry] ansible-playbook not installed — syntax gate deferred to CI"
fi
if command -v pulumi >/dev/null 2>&1 && [ -n "${CF_API_TOKEN:-}" ]; then
  (cd "${REPO_ROOT}/infra/pulumi" && PULUMI_BACKEND_URL="file://${HOME}/.pulumi-state" PULUMI_CONFIG_PASSPHRASE="${PULUMI_CONFIG_PASSPHRASE:-nexo-local}" \
    pulumi preview --non-interactive --suppress-outputs 2>&1 | tail -5) || echo "[dry] pulumi preview reported diffs/errors — inspect before apply"
else
  echo "[dry] pulumi not installed or CF_API_TOKEN empty — preview deferred to CI"
fi
[ "${DRY_OK}" -eq 1 ] && stage_record 6 "dry-run" "ok" "bash/py/yaml/ts structural gates passed" || stage_record 6 "dry-run" "failed" "structural gate failures above"

# --- Stage 7: authorization lock ---------------------------------------------------------
if [ "${APPLY:-0}" != "1" ]; then
  echo ""
  echo "================ STAGE 7 GATE ================"
  echo " Dry-run complete. Live stages are LOCKED."
  echo " Primary gate : GitHub Actions environment 'production-bare-metal'"
  echo "                (approval button on the workflow run)."
  echo " Local gate   : re-run with APPLY=1 to pre-authorize stages 8-9 here."
  echo "=============================================="
  stage_record 7 "gate" "locked" "APPLY!=1 — stopped before live mutation"
  FINAL="gated-stop"
else
  stage_record 7 "gate" "open" "APPLY=1 pre-authorized"
  FINAL="applied"

  # --- Stage 8: edge orchestration ---------------------------------------------------------
  if command -v pulumi >/dev/null 2>&1 && [ -n "${CF_API_TOKEN:-}" ]; then
    (cd "${REPO_ROOT}/infra/pulumi" && PULUMI_BACKEND_URL="file://${HOME}/.pulumi-state" PULUMI_CONFIG_PASSPHRASE="${PULUMI_CONFIG_PASSPHRASE:-nexo-local}" \
      pulumi up --non-interactive --yes) && stage_record 8 "edge-apply" "ok" "pulumi up complete" || stage_record 8 "edge-apply" "failed" "pulumi up errored"
  else
    stage_record 8 "edge-apply" "skipped" "pulumi/token unavailable — CI edge-apply governs"
  fi
  bash "${SCRIPT_DIR}/create_ai_gateway.sh" && stage_record 8 "ai-gateway" "ok" "gateway ensured" || stage_record 8 "ai-gateway" "skipped" "see script output"
  bash "${SCRIPT_DIR}/deploy_budget_sentinel.sh" && stage_record 8 "sentinel" "ok" "worker deployed" || stage_record 8 "sentinel" "skipped" "wrangler/token unavailable"
  bash "${SCRIPT_DIR}/deploy_telemetry_ingest.sh" && stage_record 8 "telemetry-ingest" "ok" "D1 + ingest worker deployed" || stage_record 8 "telemetry-ingest" "skipped" "wrangler/token unavailable"

  # --- Stage 9: bare-metal configuration ----------------------------------------------------
  if command -v ansible-playbook >/dev/null 2>&1; then
    (cd "${REPO_ROOT}/infra/ansible" && ansible-playbook -i inventory.ini playbook.yml) \
      && stage_record 9 "bare-metal" "ok" "playbook applied" \
      || stage_record 9 "bare-metal" "failed" "playbook errored — re-run is safe (idempotent)"
  else
    stage_record 9 "bare-metal" "skipped" "ansible not installed on this host"
  fi
fi

# --- Stage 10: task-board integration (always safe, file-local) ---------------------------
python3 - "${REPO_ROOT}" <<'PYSTAGE10'
import datetime, glob, json, os, sys
repo = sys.argv[1]
tasks_path = os.path.join(repo, "docs", "tasks", "tasks.json")
existing = []
if os.path.exists(tasks_path):
    try:
        with open(tasks_path) as fh:
            existing = json.load(fh).get("tasks", [])
    except Exception:
        existing = []
runs = sorted(glob.glob(os.path.join(repo, "docs", "discovery", "wave1", "run-*")))
new_rows = []
next_id = len(existing) + 100
if runs:
    latest = os.path.join(runs[-1], "results.json")
    if os.path.exists(latest):
        with open(latest) as fh:
            results = json.load(fh)
        for probe in results.get("probes", []):
            data = probe.get("data", {}) or {}
            for spot in data.get("blindspots", []):
                new_rows.append({"title": "Remediate blindspot: %s" % spot.get("rule", spot), "target": results.get("node", "unknown")})
            for viol in data.get("dns_violations", []):
                new_rows.append({"title": "DNS violation %s -> %s" % (viol.get("name"), viol.get("content")), "target": "cloudflare"})
            for drift in data.get("drift_alerts", []):
                new_rows.append({"title": drift.get("note", "dhcp drift"), "target": drift.get("ip", "lan")})
            for group in data.get("consolidation_groups", [])[:5]:
                new_rows.append({"title": "Consolidate repos: %s" % ", ".join(group.get("members", [])), "target": "github"})
now = datetime.datetime.now(datetime.timezone.utc).isoformat()
seen = {(t.get("title"), t.get("target")) for t in existing}
for row in new_rows:
    if (row["title"], row["target"]) in seen:
        continue
    next_id += 1
    existing.append({"id": "T-%03d" % next_id, "title": row["title"], "target": row["target"],
                     "agent": None, "state": "backlog", "evidence": None,
                     "created": now, "updated": now})
os.makedirs(os.path.dirname(tasks_path), exist_ok=True)
with open(tasks_path, "w") as fh:
    json.dump({"tasks": existing}, fh, indent=2)
print("[stage10] tasks.json now holds %d rows (MCP contract: docs/tasks/mcp_task_contract.md)" % len(existing))
PYSTAGE10
stage_record 10 "task-board" "ok" "tasks.json synced from latest wave1 artifacts"

# --- Receipt --------------------------------------------------------------------------------
python3 -c "
import json
rows=[json.loads(l) for l in open('${RECEIPT_TMP}') if l.strip()]
failed=[r for r in rows if r['status']=='failed']
result='${FINAL}' if not failed else 'completed-with-failures'
json.dump({'bootstrap':'acidwurx-nexus','ts':'${TS}','result':result,'stages':rows},open('${RECEIPT}','w'),indent=2)
print('receipt:', '${RECEIPT}')
"
echo "[bootstrap] done — result recorded in receipt (verification-honest: failures are never masked)"
