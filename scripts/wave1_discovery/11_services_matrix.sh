#!/usr/bin/env bash
# =============================================================================
# 11_services_matrix.sh — builds the authoritative service x node matrix:
# every catalog service probed at every known fleet host (parallel), with TCP
# state and (for HTTP services) status code. This is THE predictable interface
# for "what runs where" — consumed by the remediation engine, launch budgets,
# and the D1 registry. Read-only connect/GET only.
# Env: MATRIX_HOSTS="name=ip,..." override; SERVICE_CATALOG extended in-file.
# =============================================================================
set -euo pipefail

OUT_DIR="${NEXO_OUT_DIR:-.}"
mkdir -p "${OUT_DIR}"
TMPD="$(mktemp -d)"
trap 'rm -rf "${TMPD}"' EXIT

HOSTS="${MATRIX_HOSTS:-markslone=192.168.1.179,jessicafletcher=192.168.1.138,barryslone=192.168.1.186,tanyacheex=192.168.1.164,sharon=192.168.1.1,openwrt-secondary=192.168.1.250,localhost=127.0.0.1}"

# service:port pairs (archive service catalog + launch profiles)
SERVICES="ssh:22 dns:53 tftp:69 http:80 https:443 rtsp:554 mqtt:1883 openwebui:3000 adguard-admin:3001 litellm:4000 kuma:3002 n8n:5678 esphome:6052 jellyfin:8096 paperless:8100 homeassistant:8123 searxng:8081 netbox:8071 semaphore:3010 plex:3240 wol:9000 ollama:11434 llama-server:8080 mcp:8000"

echo "[11] matrix: $(echo "${HOSTS}" | tr ',' '\n' | wc -l) hosts x $(echo "${SERVICES}" | wc -w) services"

python3 - "${OUT_DIR}" "${HOSTS}" "${SERVICES}" <<'PYEOF'
import datetime, json, os, socket, sys, urllib.request
from concurrent.futures import ThreadPoolExecutor

out_dir, hosts_arg, services_arg = sys.argv[1], sys.argv[2], sys.argv[3]
hosts = [tuple(h.split("=", 1)) for h in hosts_arg.split(",") if "=" in h]
services = [tuple(s.split(":", 1)) for s in services_arg.split() if ":" in s]
httpish = {"http", "https", "openwebui", "adguard-admin", "litellm", "kuma", "n8n",
           "esphome", "jellyfin", "paperless", "homeassistant", "searxng", "netbox",
           "semaphore", "plex", "llama-server", "ollama"}

def check(args):
    hname, hip, sname, sport = args
    port = int(sport)
    row = {"host": hname, "ip": hip, "service": sname, "port": port, "state": "closed"}
    try:
        with socket.create_connection((hip, port), timeout=2):
            row["state"] = "open"
    except Exception:
        return row
    if sname in httpish:
        for scheme in ("http",):
            url = "%s://%s:%d/" % (scheme, hip, port)
            try:
                req = urllib.request.Request(url, method="GET")
                with urllib.request.urlopen(req, timeout=3) as resp:
                    row["http_status"] = resp.status
            except urllib.error.HTTPError as exc:
                row["http_status"] = exc.code
            except Exception:
                pass
    return row

jobs = [(hn, hi, sn, sp) for hn, hi in hosts for sn, sp in services]
matrix = []
with ThreadPoolExecutor(max_workers=48) as pool:
    for row in pool.map(check, jobs):
        if row["state"] == "open":
            matrix.append(row)

# law checks derived from the matrix
findings = []
for row in matrix:
    if row["service"] == "ollama" and row["ip"] not in ("127.0.0.1",):
        findings.append({"rule": "T-002", "detail": "Ollama reachable off-loopback at %s:%d" % (row["ip"], row["port"])})
    if row["service"] in ("litellm",) and row["ip"] not in ("127.0.0.1", "192.168.1.179"):
        findings.append({"rule": "mesh-only", "detail": "LiteLLM outside gateway: %s" % row["ip"]})
    if row["service"] == "wol" and row["ip"] != "192.168.1.179":
        findings.append({"rule": "wol-location", "detail": "WoL listener on unexpected host %s" % row["ip"]})

payload = {
    "probe": "11_services_matrix",
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "node": os.environ.get("NEXO_NODE_NAME", "unknown"),
    "status": "ok" if matrix else "degraded",
    "data": {"hosts_probed": len(hosts), "services_probed": len(services),
             "probes_total": len(jobs), "matrix": matrix, "findings": findings},
}
path = os.path.join(out_dir, "11_services_matrix_result.json")
with open(path, "w") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
print("[11] open services=%d/%d findings=%d -> %s" % (len(matrix), len(jobs), len(findings), path))
PYEOF
