#!/usr/bin/env bash
# =============================================================================
# 10_storage_health.sh — storage & spindle health (read-only). Local: df,
# mount options (noatime audit per barryslone law), smartctl when present.
# Remote (optional, BatchMode): barryslone hdparm spin state + SMART. Restic
# repository status when RESTIC_REPOSITORY/RESTIC_PASSWORD_FILE are set.
# =============================================================================
set -euo pipefail

OUT_DIR="${NEXO_OUT_DIR:-.}"
mkdir -p "${OUT_DIR}"
TMPD="$(mktemp -d)"
trap 'rm -rf "${TMPD}"' EXIT

df -P -x tmpfs -x devtmpfs 2>/dev/null | awk 'NR>1{print $6, $5, $4}' > "${TMPD}/df.txt" || true
findmnt -rno SOURCE,TARGET,OPTIONS 2>/dev/null > "${TMPD}/mounts.txt" || true
if command -v smartctl >/dev/null 2>&1; then
  for dev in /dev/sda /dev/nvme0; do
    [ -e "${dev}" ] && smartctl -H -A "${dev}" 2>/dev/null > "${TMPD}/smart-$(basename "${dev}").txt" || true
  done
fi

NAS_IP="${BARRYSLONE_LAN_IP:-192.168.1.186}"
if command -v ssh >/dev/null 2>&1; then
  timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=6 "${CATALOG_SSH_USER:-adam}@${NAS_IP}" \
    'hdparm -C /dev/sda 2>/dev/null; echo ---; smartctl -H /dev/sda 2>/dev/null | tail -3' \
    > "${TMPD}/nas.txt" 2>/dev/null || echo "unreachable" > "${TMPD}/nas.txt"
fi

if [ -n "${RESTIC_REPOSITORY:-}" ] && [ -n "${RESTIC_PASSWORD_FILE:-}" ] && command -v restic >/dev/null 2>&1; then
  timeout 30 restic snapshots --json 2>/dev/null > "${TMPD}/restic.json" || echo "[]" > "${TMPD}/restic.json"
fi

python3 - "${TMPD}" "${OUT_DIR}" <<'PYEOF'
import datetime, json, os, sys

tmpd, out_dir = sys.argv[1], sys.argv[2]

def read(name):
    p = os.path.join(tmpd, name)
    return open(p, errors="replace").read() if os.path.exists(p) else ""

disks = []
for line in read("df.txt").splitlines():
    parts = line.split()
    if len(parts) >= 3:
        disks.append({"mount": parts[0], "used": parts[1], "avail_kb": int(parts[2]) if parts[2].isdigit() else None})

noatime_missing = []
for line in read("mounts.txt").splitlines():
    parts = line.split()
    if len(parts) >= 3 and parts[0].startswith("/dev/") and "noatime" not in parts[2]:
        noatime_missing.append({"source": parts[0], "target": parts[1]})

smart = {}
for name in os.listdir(tmpd):
    if name.startswith("smart-"):
        text = read(name)
        health = "PASSED" if "PASSED" in text else ("FAILED" if "FAILED" in text else "unknown")
        temp = None
        for line in text.splitlines():
            if "Temperature" in line or "temperature" in line:
                digits = "".join(c for c in line.split(":")[-1] if c.isdigit())
                if digits:
                    temp = int(digits[:3]) if len(digits) > 3 else int(digits)
                break
        smart[name[6:-4]] = {"health": health, "temp_c": temp}

nas = read("nas.txt").strip()
nas_state = {"reachable": bool(nas) and nas != "unreachable",
             "spin_state": "active" if "active/idle" in nas else ("standby" if "standby" in nas else "unknown"),
             "smart_tail": nas.split("---")[-1].strip()[:200] if "---" in nas else None}

restic = {"configured": False}
rj = read("restic.json")
if rj:
    try:
        snaps = json.loads(rj)
        restic = {"configured": True, "snapshots": len(snaps),
                  "latest": snaps[-1].get("time") if snaps else None}
    except Exception:
        restic = {"configured": True, "error": "snapshots query failed"}

payload = {
    "probe": "10_storage_health",
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "node": os.environ.get("NEXO_NODE_NAME", "unknown"),
    "status": "ok",
    "data": {"disks": disks, "noatime_missing": noatime_missing, "smart": smart,
             "nas": nas_state, "restic": restic},
}
path = os.path.join(out_dir, "10_storage_health_result.json")
with open(path, "w") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
print("[10] disks=%d noatime_missing=%d smart=%s -> %s" % (
    len(disks), len(noatime_missing), {k: v["health"] for k, v in smart.items()}, path))
PYEOF
