#!/usr/bin/env bash
# =============================================================================
# telemetry_push.sh — push the latest (or given) wave run to the secure
# telemetry area on GitHub. Zero prompts (BatchMode/gh credential helper).
#
#   ./nexo.sh push [--dry-run] [--run-dir <dir>] [--flag <label>] [--no-issue]
#
# Env:
#   NEXO_TELEMETRY_REPO   git URL (default: https://github.com/ajdhoward/acidwurx-nexus-telemetry.git)
#   NEXO_TELEMETRY_DIR    local clone path (default: ~/acidwurx-telemetry)
#   NEXO_AGE_RECIPIENT    override encryption recipient (else repo .sops.yaml)
#   NEXO_TELEMETRY_PASSPHRASE  openssl fallback passphrase
# Flow: pack.py stages classified bundle -> clone/pull telemetry repo ->
# copy runs/<node>/<run_id>/ -> git commit -> push -> gh issue with labels
# (base: telemetry,wave1 + conditional flags from INDEX.json). The ISSUE is
# the GitHub-native flag of exactly what was pushed, every time.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TELEMETRY_REPO="${NEXO_TELEMETRY_REPO:-https://github.com/ajdhoward/acidwurx-nexus-telemetry.git}"
TELEMETRY_DIR="${NEXO_TELEMETRY_DIR:-${HOME}/acidwurx-telemetry}"
DRY_RUN=0
MAKE_ISSUE=1
RUN_DIR=""
EXTRA_FLAGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --no-issue) MAKE_ISSUE=0; shift ;;
    --run-dir) RUN_DIR="$2"; shift 2 ;;
    --flag) EXTRA_FLAGS+=("$2"); shift 2 ;;
    *) echo "[push] unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "${RUN_DIR}" ]; then
  RUN_DIR="$(ls -1dt "${REPO_ROOT}"/docs/discovery/wave1/run-* 2>/dev/null | head -1 || true)"
fi
if [ -z "${RUN_DIR}" ] || [ ! -f "${RUN_DIR}/results.json" ]; then
  echo "[push] FATAL: no wave run found (run ./nexo.sh wave1 first)"; exit 1
fi
echo "[push] run-dir: ${RUN_DIR} (dry-run=${DRY_RUN})"

STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
python3 "${REPO_ROOT}/tools/telemetry/pack.py" --run-dir "${RUN_DIR}" --out "${STAGE}"
STAGED_RUN="$(dirname "$(find "${STAGE}" -name INDEX.json -type f | head -1)")"
if [ -z "${STAGED_RUN}" ] || [ "${STAGED_RUN}" = "." ] || [ ! -d "${STAGED_RUN}" ]; then
  echo "[push] FATAL: pack.py produced no bundle (looked for INDEX.json under ${STAGE})"; exit 1
fi
NODE="$(basename "$(dirname "${STAGED_RUN}")")"
RUN_ID="$(basename "${STAGED_RUN}")"

FLAGS_JSON="$(python3 -c "import json,sys; idx=json.load(open(sys.argv[1])); print(' '.join(idx.get('flags',[])))" "${STAGED_RUN}/INDEX.json")"
ALL_FLAGS="${FLAGS_JSON} ${EXTRA_FLAGS[*]+${EXTRA_FLAGS[*]}}"

if [ "${DRY_RUN}" -eq 1 ]; then
  echo "[push] DRY-RUN plan:"
  echo "  repo   : ${TELEMETRY_REPO}"
  echo "  path   : runs/${NODE}/${RUN_ID}/"
  echo "  files  :"; (cd "${STAGED_RUN}" && find . -type f -exec ls -la {} \; | sed 's/^/    /')
  echo "  flags  : ${ALL_FLAGS:-none}"
  echo "  issue  : $([ "${MAKE_ISSUE}" -eq 1 ] && echo "yes (labels: telemetry,wave1 + flags)" || echo no)"
  exit 0
fi

# --- clone or refresh the telemetry repo (credentials via gh helper / cached) ---
if [ ! -d "${TELEMETRY_DIR}/.git" ]; then
  if command -v gh >/dev/null 2>&1; then gh auth setup-git >/dev/null 2>&1 || true; fi
  GIT_TERMINAL_PROMPT=0 git clone "${TELEMETRY_REPO}" "${TELEMETRY_DIR}" || {
    echo "[push] FATAL: clone failed — create the repo first:"; \
    echo "  gh repo create acidwurx-nexus-telemetry --public"; exit 1; }
fi
(cd "${TELEMETRY_DIR}" && GIT_TERMINAL_PROMPT=0 git pull --ff-only >/dev/null 2>&1 || true)

mkdir -p "${TELEMETRY_DIR}/runs/${NODE}/${RUN_ID}"
cp -r "${STAGED_RUN}/." "${TELEMETRY_DIR}/runs/${NODE}/${RUN_ID}/"

cd "${TELEMETRY_DIR}"
git add "runs/${NODE}/${RUN_ID}"
if git diff --staged --quiet; then
  echo "[push] nothing new to commit (identical run already pushed)"
else
  git commit -m "telemetry(${NODE}): ${RUN_ID} [${ALL_FLAGS// /,}]" >/dev/null
  GIT_TERMINAL_PROMPT=0 git push || { echo "[push] FATAL: git push failed (gh auth login / credentials)"; exit 1; }
  echo "[push] pushed runs/${NODE}/${RUN_ID}"
fi

# --- GitHub-native flag: one issue per push, labeled by classification flags ---
if [ "${MAKE_ISSUE}" -eq 1 ] && command -v gh >/dev/null 2>&1; then
  LABELS="telemetry,wave1"
  for flag in ${FLAGS_JSON}; do
    case "${flag}" in
      blindspots-found) LABELS="${LABELS},telemetry-blindspots" ;;
      drift-detected)   LABELS="${LABELS},telemetry-drift" ;;
      degraded-probe)   LABELS="${LABELS},telemetry-degraded" ;;
      dns-violation)    LABELS="${LABELS},telemetry-dns-violation" ;;
    esac
  done
  for extra in ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}; do
    if [ -n "${extra}" ]; then LABELS="${LABELS},${extra}"; fi
  done
  gh issue create --repo "${TELEMETRY_REPO#https://github.com/}" \
    --title "telemetry: ${NODE} ${RUN_ID} [${ALL_FLAGS// /,}]" \
    --body-file "${STAGED_RUN}/BRIEFING.md" \
    --label "${LABELS}" 2>/dev/null \
    && echo "[push] issue flagged with labels: ${LABELS}" \
    || echo "[push] NOTE: issue creation skipped (labels may not exist yet — create them once in repo settings, or pass --no-issue)"
fi
if [ -x "${SCRIPT_DIR}/notify.sh" ]; then
  bash "${SCRIPT_DIR}/notify.sh" "nexo telemetry" "pushed ${NODE}/${RUN_ID} flags:[${ALL_FLAGS// /,}]" 3 "satellite" || true
fi
echo "[push] done — secure area: ${TELEMETRY_REPO} -> runs/${NODE}/${RUN_ID}/"
