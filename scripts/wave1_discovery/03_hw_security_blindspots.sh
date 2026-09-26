#!/usr/bin/env bash
# =============================================================================
# 03_hw_security_blindspots.sh — read-only telemetry probe: CPU topology, RAM
# layout, Vulkan device indices, thermal zone maxima, public-IP leak canary
# (vs ISP_CGNAT_IP 88.97.176.163 + warp= trace), open listening sockets with
# blindspot rule flags (archive incidents T-002 Ollama 0.0.0.0:11434,
# T-003 xrdp/3389 + rpcbind/111), and Stage-5 mesh route verification
# (policy-routing priority order 50<51<52<100, no-blackhole fallback).
# Writes 03_hw_security_blindspots_result.json.
# =============================================================================
set -euo pipefail

OUT_DIR="${NEXO_OUT_DIR:-.}"
mkdir -p "${OUT_DIR}"
TMPD="$(mktemp -d)"
trap 'rm -rf "${TMPD}"' EXIT

echo "[03] collecting hardware + security telemetry (read-only)"

# --- CPU ------------------------------------------------------------------------
{
  if command -v lscpu >/dev/null 2>&1; then
    lscpu 2>/dev/null | grep -E "^(Model name|CPU\(s\)|Thread|Core|Socket|CPU max MHz|CPU min MHz|Vendor ID)" || true
  else
    grep -m1 "model name" /proc/cpuinfo || true
    echo "CPU(s): $(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)"
  fi
} > "${TMPD}/cpu.txt"

# --- RAM --------------------------------------------------------------------------
grep -E "^(MemTotal|MemAvailable|SwapTotal)" /proc/meminfo > "${TMPD}/ram.txt" || true
if [ "$(id -u)" -eq 0 ] && command -v dmidecode >/dev/null 2>&1; then
  dmidecode -t memory 2>/dev/null | grep -E "Size:|Part Number:|Speed:|Type:" | grep -v "No Module" > "${TMPD}/dimm.txt" || true
fi

# --- Vulkan -----------------------------------------------------------------------
if command -v vulkaninfo >/dev/null 2>&1; then
  vulkaninfo --summary 2>/dev/null | grep -E "deviceName|deviceType|driverName|apiVersion|GPU id" > "${TMPD}/vulkan.txt" || true
fi
ls /dev/dri 2>/dev/null > "${TMPD}/dri.txt" || true

# --- Thermals -----------------------------------------------------------------------
for z in /sys/class/thermal/thermal_zone*; do
  [ -f "${z}/temp" ] || continue
  type="$(cat "${z}/type" 2>/dev/null || echo unknown)"
  temp="$(cat "${z}/temp" 2>/dev/null || echo 0)"
  echo "${type} ${temp}"
done > "${TMPD}/thermal.txt"

# --- Public IP leak canary -----------------------------------------------------------
curl -4 -s --max-time 6 "https://1.1.1.1/cdn-cgi/trace" 2>/dev/null | grep -E "^(ip|warp|loc|colo)=" > "${TMPD}/cftrace.txt" || echo "cf_trace_unreachable" > "${TMPD}/cftrace.txt"
curl -4 -s --max-time 6 "https://ifconfig.me/ip" 2>/dev/null > "${TMPD}/publicip.txt" || echo "unreachable" > "${TMPD}/publicip.txt"

# --- Listening sockets -----------------------------------------------------------------
if command -v ss >/dev/null 2>&1; then
  ss -tulpnH 2>/dev/null > "${TMPD}/sockets.txt" || true
else
  netstat -tulpen 2>/dev/null > "${TMPD}/sockets.txt" || true
fi

# --- Stage-5 mesh route verification ----------------------------------------------------
ip rule show 2>/dev/null > "${TMPD}/iprule.txt" || true
ip route show table 100 2>/dev/null > "${TMPD}/rt100.txt" || true
ip route show default 2>/dev/null > "${TMPD}/rtdefault.txt" || true
if command -v wg >/dev/null 2>&1; then
  wg show 2>/dev/null > "${TMPD}/wg.txt" || true
fi

# --- JSON assembly ------------------------------------------------------------------------
python3 - "${TMPD}" "${OUT_DIR}" <<'PYEOF'
import datetime, json, os, re, sys

tmpd, out_dir = sys.argv[1], sys.argv[2]

def read(name):
    path = os.path.join(tmpd, name)
    if not os.path.exists(path):
        return ""
    with open(path) as fh:
        return fh.read()

cpu = {}
for line in read("cpu.txt").splitlines():
    if ":" in line:
        k, v = line.split(":", 1)
        cpu[k.strip()] = v.strip()

ram = {}
for line in read("ram.txt").splitlines():
    parts = line.split()
    if len(parts) >= 2:
        ram[parts[0].rstrip(":")] = parts[1]

dimms = [line.strip() for line in read("dimm.txt").splitlines() if line.strip()]

vulkan_devices = []
current = {}
for line in read("vulkan.txt").splitlines():
    line = line.strip()
    if line.startswith("GPU id"):
        if current:
            vulkan_devices.append(current)
        current = {"index": line.split("GPU id")[1].strip().strip(":(").split(")")[0].strip()}
    elif "=" in line:
        k, v = line.split("=", 1)
        current[k.strip()] = v.strip()
if current:
    vulkan_devices.append(current)

thermals = []
for line in read("thermal.txt").splitlines():
    parts = line.split()
    if len(parts) == 2:
        try:
            thermals.append({"zone": parts[0], "millidegrees_c": int(parts[1]),
                             "celsius": round(int(parts[1]) / 1000.0, 2)})
        except ValueError:
            pass
max_thermal = max((t["celsius"] for t in thermals), default=None)

cftrace = {}
for line in read("cftrace.txt").splitlines():
    if "=" in line:
        k, v = line.split("=", 1)
        cftrace[k.strip()] = v.strip()
public_ip = read("publicip.txt").strip()
isp_cgnat = os.environ.get("ISP_CGNAT_IP", "").strip()
leak = bool(isp_cgnat and public_ip == isp_cgnat)

sockets = []
blindspots = []
BLINDSPOT_RULES = {
    "11434": "T-002 Ollama exposed (bind 127.0.0.1 — AI_README Law 5)",
    "3389": "T-003 xrdp exposed on LAN (restrict to mesh or disable)",
    "3240": "Plex exposed (tunnel-gate or disable DLNA/remote)",
    "111": "rpcbind exposed (mask rpcbind unless NFS required)",
    "9090": "cockpit/prometheus-class port on all interfaces",
}
for line in read("sockets.txt").splitlines():
    fields = line.split()
    if len(fields) < 5:
        continue
    proto, local = fields[0], fields[4] if len(fields) > 4 else ""
    m = re.match(r"^(.*):(\d+)$", local)
    if not m:
        continue
    addr, port = m.group(1), m.group(2)
    entry = {"proto": proto, "address": addr, "port": int(port)}
    sockets.append(entry)
    if addr in ("0.0.0.0", "*", "[::]", "::") and port in BLINDSPOT_RULES:
        blindspots.append({"port": int(port), "address": addr, "rule": BLINDSPOT_RULES[port]})

# Stage-5 routing verification
rules_txt = read("iprule.txt")
prio = {}
for m in re.finditer(r"(\d+):\s+from ([\d./]+|all) (?:to ([\d./]+) )?lookup (\w+)", rules_txt):
    prio.setdefault(m.group(4), []).append(int(m.group(1)))
routing = {
    "table_100_routes": [line.strip() for line in read("rt100.txt").splitlines() if line.strip()],
    "ip_rules_present": bool(rules_txt.strip()),
    "bypass_prios_ok": all(
        any(p < 100 for p in prio.get(tbl, [999])) for tbl in ("main",)
    ) if prio else None,
    "no_blackhole_check": "default" in read("rt100.txt") or not read("rt100.txt").strip(),
    "wg_interfaces": [line.split(":")[0].strip() for line in read("wg.txt").splitlines()
                      if line.strip().endswith(":") and "interface" not in line][:4],
}

payload = {
    "probe": "03_hw_security_blindspots",
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "node": os.environ.get("NEXO_NODE_NAME", "unknown"),
    "status": "ok",
    "data": {
        "cpu": cpu,
        "ram": ram,
        "dimm_layout": dimms,
        "vulkan_devices": vulkan_devices,
        "dri_nodes": [n.strip() for n in read("dri.txt").splitlines() if n.strip()],
        "thermals": thermals,
        "max_thermal_c": max_thermal,
        "public_ip": public_ip,
        "cf_trace": cftrace,
        "isp_cgnat_leak": leak,
        "warp_on": cftrace.get("warp") == "on",
        "listening_sockets": sockets,
        "blindspots": blindspots,
        "routing_verification": routing,
    },
}
path = os.path.join(out_dir, "03_hw_security_blindspots_result.json")
with open(path, "w") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
print("[03] blindspots=%d leak=%s warp=%s -> %s" % (
    len(blindspots), leak, cftrace.get("warp"), path))
PYEOF
