#!/usr/bin/env bash
# =============================================================================
# 06_fleet_ssh_inventory.sh — BULK parallel SSH fact-harvester across the fleet.
# One ssh per node (BatchMode, 6s connect timeout) running a single fact bundle;
# results parsed into per-node JSON + consolidated node inventory. Read-only:
# the remote bundle only runs getters. Unreachable nodes are recorded with a
# route hint (WoL relay / physical) — never silently dropped (Law 10).
# Env: FLEET_NODES="name:ip:user name2:ip2:user2" (default = archive fleet).
# Writes 06_fleet_ssh_inventory_result.json + nodes/<name>.json per node.
# =============================================================================
set -euo pipefail

OUT_DIR="${NEXO_OUT_DIR:-.}"
mkdir -p "${OUT_DIR}/nodes"
DEFAULT_NODES="markslone:192.168.1.179:adam jessicafletcher:192.168.1.138:adam barryslone:192.168.1.186:adam tanyacheex:192.168.1.164:adam"
FLEET_NODES="${FLEET_NODES:-${DEFAULT_NODES}}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new)

echo "[06] bulk SSH inventory: ${FLEET_NODES}"

probe_node() {
  local name="$1" ip="$2" user="$3"
  local raw="${OUT_DIR}/nodes/${name}.raw"
  local rc=0
  ssh "${SSH_OPTS[@]}" "${user}@${ip}" bash -s > "${raw}" 2> "${raw}.err" <<'REMOTE' || rc=$?
echo "OS=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
echo "KERNEL=$(uname -r 2>/dev/null)"
echo "UPTIME_S=$(cut -d. -f1 /proc/uptime 2>/dev/null)"
echo "CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ //')"
echo "CORES=$(nproc 2>/dev/null)"
echo "MEM_TOTAL_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null)"
echo "DISKS=$(df -P -x tmpfs -x devtmpfs 2>/dev/null | awk 'NR>1{printf "%s=%s;", $6, $5}')"
echo "FAILED_UNITS=$(systemctl --failed --no-legend 2>/dev/null | wc -l)"
echo "FAILED_LIST=$(systemctl --failed --no-legend 2>/dev/null | awk '{print $1}' | tr '\n' ',')"
echo "PKG_MANAGER=$(if command -v apt >/dev/null 2>&1; then echo apt; elif command -v pacman >/dev/null 2>&1; then echo pacman; elif command -v dnf >/dev/null 2>&1; then echo dnf; else echo other; fi)"
echo "PKG_COUNT=$( (dpkg -l 2>/dev/null || pacman -Q 2>/dev/null || rpm -qa 2>/dev/null) | wc -l)"
echo "DOCKER_RUNNING=$(docker ps -q 2>/dev/null | wc -l)"
echo "DOCKER_IMAGES=$(docker images -q 2>/dev/null | wc -l)"
echo "PODMAN_RUNNING=$(podman ps -q 2>/dev/null | wc -l)"
echo "ISOLCPUS=$(grep -o 'isolcpus=[^ ]*' /proc/cmdline 2>/dev/null || echo none)"
echo "HUGEPAGES=$(awk '/nr_hugepages/{print $NF; exit}' /proc/meminfo 2>/dev/null || echo unknown)"
echo "WOL_ARMED=$(for i in $(ls /sys/class/net 2>/dev/null | grep -v lo | head -3); do ethtool "$i" 2>/dev/null | grep -q 'Wake-on: g' && printf '%s,' "$i"; done)"
echo "USERS_SHELL=$(awk -F: '$7 ~ /(bash|zsh|sh)$/ {printf "%s,", $1}' /etc/passwd 2>/dev/null)"
echo "AUTH_KEYS=$(for h in /home/* /root; do [ -f "$h/.ssh/authorized_keys" ] && printf '%s:%s;' "$(basename "$h")" "$(grep -c . "$h/.ssh/authorized_keys" 2>/dev/null)"; done)"
echo "CRON_LINES=$( (crontab -l 2>/dev/null; cat /etc/cron.d/* 2>/dev/null) | grep -cv '^#' 2>/dev/null || echo 0)"
echo "LISTENERS=$(ss -tulpnH 2>/dev/null | wc -l)"
echo "THERMAL_MAX_MC=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1)"
echo "HOSTNAME_REAL=$(hostname 2>/dev/null)"
REMOTE
  echo "${name} ${ip} ${rc}" >> "${OUT_DIR}/nodes/_exit_codes.txt"
}

PIDS=()
for entry in ${FLEET_NODES}; do
  IFS=':' read -r name ip user <<< "${entry}"
  probe_node "${name}" "${ip}" "${user}" &
  PIDS+=($!)
done
for pid in "${PIDS[@]}"; do wait "${pid}" || true; done

python3 - "${OUT_DIR}" <<'PYEOF'
import datetime, glob, json, os, sys

out_dir = sys.argv[1]
nodes, unreachable = [], []
ip_map = {}
exit_path = os.path.join(out_dir, "nodes", "_exit_codes.txt")
if os.path.exists(exit_path):
    for line in open(exit_path):
        parts = line.split()
        if len(parts) >= 2:
            ip_map[parts[0]] = parts[1]
for raw_path in sorted(glob.glob(os.path.join(out_dir, "nodes", "*.raw"))):
    name = os.path.basename(raw_path)[:-4]
    facts, rc = {}, None
    err_path = raw_path + ".err"
    err_text = open(err_path).read().strip()[:200] if os.path.exists(err_path) else ""
    for line in open(raw_path, errors="replace"):
        if "=" in line:
            k, v = line.split("=", 1)
            facts[k.strip()] = v.strip()
    exit_path = os.path.join(out_dir, "nodes", "_exit_codes.txt")
    node_entry = {"name": name, "facts": facts, "ssh_error": err_text if not facts else None}
    if facts:
        disks = []
        for chunk in filter(None, facts.get("DISKS", "").split(";")):
            if "=" in chunk:
                mount, pct = chunk.rsplit("=", 1)
                disks.append({"mount": mount, "used": pct})
        node_entry.update({
            "reachable": True,
            "os": facts.get("OS"), "kernel": facts.get("KERNEL"),
            "hostname_real": facts.get("HOSTNAME_REAL"),
            "cores": facts.get("CORES"), "mem_total_kb": facts.get("MEM_TOTAL_KB"),
            "pkg_manager": facts.get("PKG_MANAGER"), "pkg_count": facts.get("PKG_COUNT"),
            "failed_units": int(facts.get("FAILED_UNITS") or 0),
            "failed_list": [u for u in facts.get("FAILED_LIST", "").split(",") if u],
            "docker_running": int(facts.get("DOCKER_RUNNING") or 0),
            "podman_running": int(facts.get("PODMAN_RUNNING") or 0),
            "isolcpus": facts.get("ISOLCPUS"),
            "hugepages": facts.get("HUGEPAGES"),
            "wol_armed": bool(facts.get("WOL_ARMED")),
            "users_shell": [u for u in facts.get("USERS_SHELL", "").split(",") if u],
            "authorized_keys": facts.get("AUTH_KEYS"),
            "listeners": int(facts.get("LISTENERS") or 0),
            "thermal_max_c": (int(facts.get("THERMAL_MAX_MC") or 0) / 1000.0) if facts.get("THERMAL_MAX_MC") else None,
            "disks": disks,
        })
        nodes.append(node_entry)
    else:
        unreachable.append({"name": name, "ip": ip_map.get(name), "error": err_text or "ssh failed",
                            "route_hint": "Wake via WoL relay (POST markslone:9000/wake) or physical check; then re-run wave"})
with open(os.path.join(out_dir, "nodes", "inventory.json"), "w") as fh:
    json.dump({"nodes": nodes, "unreachable": unreachable}, fh, indent=2, sort_keys=True)

payload = {
    "probe": "06_fleet_ssh_inventory",
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "node": os.environ.get("NEXO_NODE_NAME", "unknown"),
    "status": "ok" if nodes else ("degraded" if unreachable else "skipped"),
    "data": {"nodes": nodes, "nodes_reachable": len(nodes), "nodes_unreachable": unreachable},
}
path = os.path.join(out_dir, "06_fleet_ssh_inventory_result.json")
with open(path, "w") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
print("[06] reachable=%d unreachable=%d -> %s" % (len(nodes), len(unreachable), path))
PYEOF
