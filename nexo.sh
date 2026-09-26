#!/usr/bin/env bash
# =============================================================================
# nexo.sh — single entry point for the AcidWurx Nexus repo (zero prompts).
#   ./nexo.sh wave1               read-only telemetry wave (probes 00-05)
#   ./nexo.sh validate            structural validation harness (CI gate)
#   ./nexo.sh launch <args...>    service catalog factory (list/render/deploy/status/budget)
#   ./nexo.sh status              catalog deployment health
#   ./nexo.sh backup [--dry-run]  fleet configuration backups (+ optional restic)
#   ./nexo.sh tasks               print the Stage-10 task board
#   ./nexo.sh mcp                 run the MCP task server on stdio (for agent clients)
#   ./nexo.sh trace               mesh routing + edge validation trace
#   ./nexo.sh report [--run-dir D]  print the secret-scrubbed AI briefing
#   ./nexo.sh push [--dry-run] [--flag L] [--no-issue]  push run to the secure
#                                 telemetry area (classify -> encrypt -> flag)
#   ./nexo.sh remediate             facts -> routed plan + auto-safe executor + tasks
#   ./nexo.sh facts | matrix | coverage   fact stream / service matrix / routing coverage
#   ./nexo.sh fleet-apply [--syntax-only]  bulk ansible (check mode; APPLY=1 canary+fleet)
#   ./nexo.sh public-audit          GO/NO-GO gate before making the repo public
#   ./nexo.sh access-request ...    AI-agent decryption-access application (keygen+issue)
#   ./nexo.sh cron [--dry-run|--remove]    auto-progression timer (wave+remediate+push+notify)
#   ./nexo.sh notify "title" "msg"  one-shot ntfy push (NEXO_NTFY_TOPIC)
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${REPO_ROOT}"

# Guarded env loading: .env FILLS UNSET variables; caller-exported values
# always win (so `GITHUB_TOKEN=x ./nexo.sh ...` is never clobbered by an
# empty .env line).
load_env_guarded() {
  local envfile="$1" line key
  [ -f "${envfile}" ] || return 0
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in ''|'#'*) continue ;; esac
    line="${line#export }"
    key="${line%%=*}"
    case "${key}" in *[!A-Za-z0-9_]*|'') continue ;; esac
    if [ -z "${!key+set}" ]; then
      eval "export ${line}" 2>/dev/null || echo "[env] WARN: unparseable ${envfile} line for ${key}"
    fi
  done < "${envfile}"
}
load_env_guarded "${REPO_ROOT}/.env"

CMD="${1:-help}"
shift || true

case "${CMD}" in
  wave1)    exec bash scripts/wave1_discovery/00_master_orchestrator.sh "$@" ;;
  validate) exec python3 scripts/ci/validate_repo.py "${1:-.}" ;;
  launch)   exec python3 platform/launch.py "$@" ;;
  status)   exec python3 platform/launch.py status ;;
  backup)   exec bash scripts/wave2_deployment/fleet_backup.sh "$@" ;;
  tasks)    exec python3 tools/mcp/nexo_tasks_server.py --cli list ;;
  mcp)      exec python3 tools/mcp/nexo_tasks_server.py ;;
  trace)    exec bash scripts/wave2_deployment/validation_trace.sh "$@" ;;
  push)     exec bash scripts/wave2_deployment/telemetry_push.sh "$@" ;;
  notify)   exec bash scripts/wave2_deployment/notify.sh "$@" ;;
  cron)     exec bash scripts/wave2_deployment/install_cron.sh "$@" ;;
  public-audit) exec python3 scripts/ci/public_audit.py "${1:-.}" ;;
  access-request) exec python3 tools/access/request_access.py "$@" ;;
  remediate) exec python3 tools/remediation/engine.py "$@" ;;
  facts)    exec python3 tools/remediation/engine.py --facts-only "$@" ;;
  matrix)   exec python3 tools/remediation/engine.py --matrix "$@" ;;
  coverage) exec python3 tools/remediation/engine.py --coverage "$@" ;;
  fleet-apply) exec bash scripts/wave3_bulk/fleet_apply.sh "$@" ;;
  report)
    RUN_DIR=""
    if [ "${1:-}" = "--run-dir" ]; then RUN_DIR="$2"; else
      RUN_DIR="$(ls -1dt "${REPO_ROOT}"/docs/discovery/wave1/run-* 2>/dev/null | head -1 || true)"
    fi
    if [ -z "${RUN_DIR}" ]; then echo "no wave run found — run ./nexo.sh wave1 first"; exit 1; fi
    exec python3 tools/telemetry/pack.py --run-dir "${RUN_DIR}" --out /tmp/nexo-report-$ --brief-only
    ;;
  help|*)
    sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    ;;
esac
