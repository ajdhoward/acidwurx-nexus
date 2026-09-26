#!/usr/bin/env bash
# =============================================================================
# fleet_backup.sh — configuration backup orchestrator (read-only at source).
# Captures: OpenWrt routers (sysupgrade -b), markslone gateway config
# (nftables, wireguard/wgcf, cloudflared env, /opt/nexo compose+rendered,
# AdGuard via docker cp when present), jessicafletcher appliance config
# (nftables.d, sysctl drops, GRUB, podman unit inspect). Writes into
# backups/run-<ts>/ (GITIGNORED — these contain secrets) with a SHA256SUMS
# manifest + summary.json. Optional restic push when RESTIC_REPOSITORY and
# RESTIC_PASSWORD_FILE are set (native binary on barryslone per Law 1).
# SSH is strictly BatchMode (key auth; never prompts). --dry-run prints the
# plan and touches nothing remote.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_ROOT="${NEXO_BACKUP_DIR:-${REPO_ROOT}/backups}/run-${TS}"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

OPENWRT_PRIMARY_IP="${OPENWRT_PRIMARY_IP:-192.168.1.1}"
OPENWRT_SECONDARY_IP="${OPENWRT_SECONDARY_IP:-192.168.1.250}"
MARKSLONE_LAN_IP="${MARKSLONE_LAN_IP:-192.168.1.179}"
JESSICAFLETCHER_LAN_IP="${JESSICAFLETCHER_LAN_IP:-192.168.1.138}"
SSH_USER="${CATALOG_SSH_USER:-adam}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
FAILURES=0

say() { echo "[backup] $*"; }

plan() {
  say "run ${TS} -> ${BACKUP_ROOT} (dry-run=${DRY_RUN})"
  say "targets: openwrt ${OPENWRT_PRIMARY_IP}/${OPENWRT_SECONDARY_IP}, markslone ${MARKSLONE_LAN_IP}, jessicafletcher ${JESSICAFLETCHER_LAN_IP}"
}

capture_openwrt() {
  local ip="$1" name="$2"
  say "${name} (${ip}): sysupgrade config bundle"
  if [ "${DRY_RUN}" -eq 1 ]; then say "  DRY: ssh root@${ip} sysupgrade -b /tmp/nexo-${name}.tar.gz && scp"; return 0; fi
  mkdir -p "${BACKUP_ROOT}/${name}"
  if ssh "${SSH_OPTS[@]}" "root@${ip}" "sysupgrade -b /tmp/nexo-${name}.tar.gz 2>/dev/null" \
     && scp "${SSH_OPTS[@]}" "root@${ip}:/tmp/nexo-${name}.tar.gz" "${BACKUP_ROOT}/${name}/" >/dev/null 2>&1 \
     && ssh "${SSH_OPTS[@]}" "root@${ip}" "rm -f /tmp/nexo-${name}.tar.gz"; then
    say "  OK ${name}"
  else
    say "  FAIL ${name} (unreachable or auth) — recorded, continuing"; FAILURES=$((FAILURES+1))
  fi
}

capture_markslone() {
  say "markslone (${MARKSLONE_LAN_IP}): gateway config tree"
  if [ "${DRY_RUN}" -eq 1 ]; then say "  DRY: tar /etc/nftables* /etc/nftables.d /etc/wireguard /etc/nexo /etc/cloudflared /opt/nexo (compose+rendered) + adguard docker cp"; return 0; fi
  mkdir -p "${BACKUP_ROOT}/markslone"
  if ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MARKSLONE_LAN_IP}" \
      "tar czf - /etc/nftables.conf /etc/nftables /etc/nftables.d /etc/wireguard /etc/nexo /etc/cloudflared /opt/nexo 2>/dev/null; docker cp \$(docker ps -qf name=adguard) /opt/adguardhome/conf 2>/dev/null | tar czf - 2>/dev/null || true" \
      > "${BACKUP_ROOT}/markslone/gateway-config.tar.gz"; then
    if [ -s "${BACKUP_ROOT}/markslone/gateway-config.tar.gz" ]; then say "  OK markslone"; else say "  FAIL markslone (empty archive)"; FAILURES=$((FAILURES+1)); fi
  else
    say "  FAIL markslone (ssh/auth)"; FAILURES=$((FAILURES+1))
  fi
}

capture_appliance() {
  say "jessicafletcher (${JESSICAFLETCHER_LAN_IP}): appliance config"
  if [ "${DRY_RUN}" -eq 1 ]; then say "  DRY: tar /etc/nftables.d /etc/sysctl.d/99-nexo* /etc/default/grub + podman inspect acidwurx-llama"; return 0; fi
  mkdir -p "${BACKUP_ROOT}/jessicafletcher"
  if ssh "${SSH_OPTS[@]}" "${SSH_USER}@${JESSICAFLETCHER_LAN_IP}" \
      "tar czf - /etc/nftables.d /etc/sysctl.d/99-nexo-performance.conf /etc/default/grub 2>/dev/null" \
      > "${BACKUP_ROOT}/jessicafletcher/appliance-config.tar.gz"; then
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${JESSICAFLETCHER_LAN_IP}" \
      "podman inspect acidwurx-llama 2>/dev/null || true" \
      > "${BACKUP_ROOT}/jessicafletcher/acidwurx-llama.inspect.json" || true
    if [ -s "${BACKUP_ROOT}/jessicafletcher/appliance-config.tar.gz" ]; then say "  OK jessicafletcher"; else say "  FAIL jessicafletcher (empty archive)"; FAILURES=$((FAILURES+1)); fi
  else
    say "  FAIL jessicafletcher (ssh/auth)"; FAILURES=$((FAILURES+1))
  fi
}

manifest() {
  [ "${DRY_RUN}" -eq 1 ] && return 0
  ( cd "${BACKUP_ROOT}" && find . -type f ! -name SHA256SUMS ! -name summary.json -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS )
  python3 - "${BACKUP_ROOT}" "${TS}" "${FAILURES}" <<'PYSUM'
import json, os, sys
root, ts, failures = sys.argv[1], sys.argv[2], int(sys.argv[3])
files = []
for dirpath, _, filenames in os.walk(root):
    for name in filenames:
        path = os.path.join(dirpath, name)
        files.append({"path": os.path.relpath(path, root), "bytes": os.path.getsize(path)})
summary = {"run": ts, "failures": failures, "files": len(files), "entries": files,
           "contains_secrets": True,
           "handling": "gitignored; chmod -R go-rwx; restic-encrypt for offsite"}
with open(os.path.join(root, "summary.json"), "w") as fh:
    json.dump(summary, fh, indent=2)
print("[backup] manifest: %d files, %d capture failure(s)" % (len(files), failures))
PYSUM
  chmod -R go-rwx "${BACKUP_ROOT}" 2>/dev/null || true
}

restic_push() {
  if [ -n "${RESTIC_REPOSITORY:-}" ] && [ -n "${RESTIC_PASSWORD_FILE:-}" ] && command -v restic >/dev/null 2>&1; then
    if [ "${DRY_RUN}" -eq 1 ]; then say "restic: DRY push ${BACKUP_ROOT}"; return 0; fi
    say "restic: pushing to ${RESTIC_REPOSITORY}"
    if restic backup "${BACKUP_ROOT}" --tag nexo-config --tag "run-${TS}"; then say "restic: OK"; else say "restic: FAIL"; FAILURES=$((FAILURES+1)); fi
  else
    say "restic: skipped (RESTIC_REPOSITORY/RESTIC_PASSWORD_FILE unset or binary absent)"
  fi
}

plan
capture_openwrt "${OPENWRT_PRIMARY_IP}" "sharon"
capture_openwrt "${OPENWRT_SECONDARY_IP}" "openwrt-secondary"
capture_markslone
capture_appliance
manifest
restic_push

if [ "${DRY_RUN}" -eq 1 ]; then say "dry-run complete (nothing touched)"; exit 0; fi
if [ "${FAILURES}" -gt 0 ]; then
  say "COMPLETE WITH ${FAILURES} FAILURE(S) — see summary.json (honesty law: partial success is never reported as full)"
  exit 1
fi
say "all captures OK -> ${BACKUP_ROOT}"
