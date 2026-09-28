#!/usr/bin/env bash
# =============================================================================
# install_cron.sh — automatic progression loop (systemd USER units, no sudo).
# Installs nexo-wave.timer: on schedule runs wave1 -> remediate -> push (and,
# when NEXO_AUTOREMEDIATE=1, executes AUTO-SAFE remediations), then notifies.
# Every artifact of a run lands in GitHub telemetry + a labeled flag issue =
# the phone/PC notification. Idempotent; --remove uninstalls; --dry-run prints.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
UNIT_DIR="${HOME}/.config/systemd/user"
SCHEDULE="${NEXO_WAVE_SCHEDULE:-*-*-* 04:30:00}"
MODE="install"
case "${1:-}" in
  --remove) MODE="remove" ;;
  --dry-run) MODE="dry" ;;
esac

SERVICE="[Unit]
Description=AcidWurx Nexus automatic wave (discover -> remediate -> push -> notify)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
WorkingDirectory=${REPO_ROOT}
EnvironmentFile=${REPO_ROOT}/.env
ExecStart=/bin/bash -c 'set -euo pipefail; ./nexo.sh wave1; ./nexo.sh remediate; RUN=\$(ls -1dt docs/discovery/wave1/run-* | head -1); if [ \"\${NEXO_AUTOREMEDIATE:-0}\" = \"1\" ] && [ -f \"\$RUN/remediate.sh\" ]; then APPLY=1 bash \"\$RUN/remediate.sh\"; fi; ./nexo.sh push --flag scheduled; bash scripts/wave2_deployment/notify.sh \"nexo wave\" \"scheduled wave complete on '\$(uname -n)'\" 3 floppy_disk'
TimeoutStartSec=3600

[Install]
WantedBy=timers.target"

TIMER="[Unit]
Description=AcidWurx Nexus wave timer

[Timer]
OnCalendar=${SCHEDULE}
Persistent=true
RandomizedDelaySec=900

[Install]
WantedBy=timers.target"

if [ "${MODE}" = "remove" ]; then
  systemctl --user disable --now nexo-wave.timer nexo-wave.service 2>/dev/null || true
  rm -f "${UNIT_DIR}/nexo-wave.timer" "${UNIT_DIR}/nexo-wave.service"
  systemctl --user daemon-reload 2>/dev/null || true
  echo "[cron] removed nexo-wave units"
  exit 0
fi

if [ "${MODE}" = "dry" ]; then
  echo "----- nexo-wave.service -----"; printf '%s\n' "${SERVICE}"
  echo "----- nexo-wave.timer -----"; printf '%s\n' "${TIMER}"
  echo "[cron] dry-run: units would be written to ${UNIT_DIR} (schedule: ${SCHEDULE})"
  exit 0
fi

mkdir -p "${UNIT_DIR}"
printf '%s\n' "${SERVICE}" > "${UNIT_DIR}/nexo-wave.service"
printf '%s\n' "${TIMER}" > "${UNIT_DIR}/nexo-wave.timer"
systemctl --user daemon-reload
systemctl --user enable --now nexo-wave.timer
echo "[cron] installed. schedule: ${SCHEDULE} (override with NEXO_WAVE_SCHEDULE)"
systemctl --user list-timers nexo-wave.timer --no-pager 2>/dev/null || true
echo "[cron] NOTE: requires user linger for headless operation: sudo loginctl enable-linger ${USER}"
