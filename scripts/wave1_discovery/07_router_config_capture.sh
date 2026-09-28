#!/usr/bin/env bash
# =============================================================================
# 07_router_config_capture.sh — OpenWrt config-as-code capture (READ-ONLY).
# For each router: uci export (network/firewall/dhcp/wireless/sqm), OpenWrt
# release, installed package count, DHCP lease table (authoritative IP/MAC/
# hostname map — feeds drift detection), neighbour table. Captures land in
# <run>/routers/<name>/ and are classified ENCRYPTED by the push manifest
# (uci exports can contain wireless PSKs — they never leave in plaintext).
# Env: OPENWRT_NODES="name:ip" (default sharon + secondary), OPENWRT_SSH_USER.
# =============================================================================
set -euo pipefail

OUT_DIR="${NEXO_OUT_DIR:-.}"
mkdir -p "${OUT_DIR}/routers"
OPENWRT_NODES="${OPENWRT_NODES:-sharon:192.168.1.1 openwrt-secondary:192.168.1.250}"
OPENWRT_SSH_USER="${OPENWRT_SSH_USER:-root}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new)

echo "[07] router capture: ${OPENWRT_NODES}"

capture_router() {
  local name="$1" ip="$2"
  local dir="${OUT_DIR}/routers/${name}"
  mkdir -p "${dir}"
  local rc=0
  # NOTE: OpenWrt ships ash (busybox) — 'bash -s' does not exist there.
  # The remote bundle is strictly POSIX so 'sh -s' works everywhere.
  ssh "${SSH_OPTS[@]}" "${OPENWRT_SSH_USER}@${ip}" sh -s > "${dir}/facts.txt" 2> "${dir}/ssh.err" <<'REMOTE' || rc=$?
echo "RELEASE=$(cat /etc/openwrt_release 2>/dev/null | grep DISTRIB_DESCRIPTION | cut -d"'" -f2)"
echo "KERNEL=$(uname -r)"
echo "UPTIME_S=$(cut -d. -f1 /proc/uptime)"
echo "PKG_COUNT=$( (apk list -I 2>/dev/null || opkg list-installed 2>/dev/null) | wc -l)"
echo "MODEL=$(cat /tmp/sysinfo/model 2>/dev/null || echo unknown)"
echo "---LEASES---"
cat /tmp/dhcp.leases 2>/dev/null
echo "---NEIGH---"
ip neigh show 2>/dev/null
echo "---UCI-NETWORK---"
uci export network 2>/dev/null
echo "---UCI-FIREWALL---"
uci export firewall 2>/dev/null
echo "---UCI-DHCP---"
uci export dhcp 2>/dev/null
echo "---UCI-WIRELESS---"
uci export wireless 2>/dev/null
echo "---UCI-SQM---"
uci export sqm 2>/dev/null
REMOTE
  echo "${name} ${ip} ${rc}" >> "${OUT_DIR}/routers/_exit_codes.txt"
}

PIDS=()
for entry in ${OPENWRT_NODES}; do
  IFS=':' read -r name ip <<< "${entry}"
  capture_router "${name}" "${ip}" &
  PIDS+=($!)
done
for pid in "${PIDS[@]}"; do wait "${pid}" || true; done

python3 - "${OUT_DIR}" <<'PYEOF'
import datetime, glob, json, os, sys

out_dir = sys.argv[1]
routers, leases_all = [], []
for facts_path in sorted(glob.glob(os.path.join(out_dir, "routers", "*", "facts.txt"))):
    rdir = os.path.dirname(facts_path)
    name = os.path.basename(rdir)
    text = open(facts_path, errors="replace").read()
    if not text.strip():
        err = open(os.path.join(rdir, "ssh.err"), errors="replace").read().strip()[:200] if os.path.exists(os.path.join(rdir, "ssh.err")) else ""
        routers.append({"name": name, "reachable": False, "error": err or "ssh failed"})
        continue
    sections, current = {}, "FACTS"
    for line in text.splitlines():
        if line.startswith("---") and line.endswith("---"):
            current = line.strip("-")
            sections[current] = []
        else:
            sections.setdefault(current, []).append(line)
    facts = {}
    for kv in sections.get("FACTS", []):
        if "=" in kv:
            k, v = kv.split("=", 1)
            facts[k.strip()] = v.strip()
    # split uci sections into individual encrypted-class files
    for sec in ("UCI-NETWORK", "UCI-FIREWALL", "UCI-DHCP", "UCI-WIRELESS", "UCI-SQM"):
        body = "\n".join(sections.get(sec, [])).strip()
        if body:
            with open(os.path.join(rdir, sec.lower().replace("uci-", "") + ".uci"), "w") as fh:
                fh.write(body + "\n")
    leases = []
    for row in sections.get("LEASES", []):
        parts = row.split()
        if len(parts) >= 3:
            lease = {"expires_epoch": parts[0], "mac": parts[1].upper(), "ip": parts[2],
                     "hostname": parts[3] if len(parts) > 3 else None}
            leases.append(lease)
            leases_all.append(dict(lease, router=name))
    dhcp_opts = "\n".join(sections.get("UCI-DHCP", []))
    routers.append({
        "name": name, "reachable": True,
        "release": facts.get("RELEASE"), "kernel": facts.get("KERNEL"),
        "model": facts.get("MODEL"), "pkg_count": facts.get("PKG_COUNT"),
        "leases_count": len(leleases),
        "option3_redirect": ("192.168.1.179" in dhcp_opts) or None,
        "pxe_options_present": ("66" in dhcp_opts and "67" in dhcp_opts) or None,
        "uci_files": sorted(f for f in os.listdir(rdir) if f.endswith(".uci")),
    })

payload = {
    "probe": "07_router_config_capture",
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "node": os.environ.get("NEXO_NODE_NAME", "unknown"),
    "status": "ok" if any(r.get("reachable") for r in routers) else "degraded",
    "data": {"routers": routers, "leases": leases_all},
}
path = os.path.join(out_dir, "07_router_config_capture_result.json")
with open(path, "w") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
print("[07] routers=%d reachable=%d leases=%d -> %s" % (
    len(routers), sum(1 for r in routers if r.get("reachable")), len(leases_all), path))
PYEOF
