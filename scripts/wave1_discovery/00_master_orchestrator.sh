#!/usr/bin/env bash
# =============================================================================
# 00_master_orchestrator.sh — Wave 1 parallel telemetry runner.
# STRICTLY READ-ONLY: every sub-probe performs only GET/connect/listen ops.
# Launches probes 01-05 as background jobs with per-probe timeouts, captures
# logs + JSON artifacts under docs/discovery/wave1/run-<ts>/, aggregates into
# results.json + REPORT.md. Individual probe failure NEVER aborts the wave;
# the orchestrator exits non-zero ONLY if it could not run at all or every
# probe failed (verification honesty, AI_README Law 10).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${NEXO_OUT_DIR:-${REPO_ROOT}/docs/discovery/wave1/run-${RUN_ID}}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-300}"
export NEXO_OUT_DIR="${OUT_DIR}"
export NEXO_NODE_NAME="${NEXO_NODE_NAME:-$(hostname -s 2>/dev/null || hostname)}"

mkdir -p "${OUT_DIR}"
echo "[orchestrator] run ${RUN_ID} node ${NEXO_NODE_NAME} out ${OUT_DIR}"

# --- Stage 1 hydration: load .env if present (zero prompts) -------------------
if [ -f "${REPO_ROOT}/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/.env"
  set +a
  echo "[orchestrator] hydrated environment from .env"
else
  echo "[orchestrator] NOTE: no .env at repo root — probes requiring tokens will report status=skipped"
fi

command -v python3 >/dev/null 2>&1 || { echo "[orchestrator] FATAL: python3 not found"; exit 1; }

HAVE_TIMEOUT=1
command -v timeout >/dev/null 2>&1 || HAVE_TIMEOUT=0

run_probe() {
  local probe="$1"
  local log="${OUT_DIR}/${probe%.sh}.log"
  local rc=0
  if [ "${HAVE_TIMEOUT}" -eq 1 ]; then
    if [[ "${probe}" == *.py ]]; then
      timeout "${PROBE_TIMEOUT}" python3 "${SCRIPT_DIR}/${probe}" >"${log}" 2>&1 || rc=$?
    else
      timeout "${PROBE_TIMEOUT}" bash "${SCRIPT_DIR}/${probe}" >"${log}" 2>&1 || rc=$?
    fi
  else
    if [[ "${probe}" == *.py ]]; then
      python3 "${SCRIPT_DIR}/${probe}" >"${log}" 2>&1 || rc=$?
    else
      bash "${SCRIPT_DIR}/${probe}" >"${log}" 2>&1 || rc=$?
    fi
  fi
  echo "${probe} ${rc}" >> "${OUT_DIR}/probe_exit_codes.txt"
  echo "[orchestrator] probe ${probe} finished rc=${rc}"
  return "${rc}"
}

# --- Launch all probes in parallel (background jobs) ---------------------------
PROBES=(
  "01_cf_edge_ai_audit.py"
  "02_lan_iot_firmware_sweep.sh"
  "03_hw_security_blindspots.sh"
  "04_github_ai_consolidation.py"
  "05_local_ai_mcp_audit.sh"
)
PIDS=()
for probe in "${PROBES[@]}"; do
  if [ -f "${SCRIPT_DIR}/${probe}" ]; then
    run_probe "${probe}" &
    PIDS+=($!)
  else
    echo "[orchestrator] WARNING: missing probe ${probe}"
    echo "${probe} missing" >> "${OUT_DIR}/probe_exit_codes.txt"
  fi
done

FAILURES=0
for pid in "${PIDS[@]}"; do
  wait "${pid}" || FAILURES=$((FAILURES + 1))
done

# --- Aggregate artifacts into results.json + REPORT.md -------------------------
AGGREGATE="${OUT_DIR}/aggregate.py"
cat > "${AGGREGATE}" <<'PYAGG'
import datetime, glob, json, os, sys
out_dir = sys.argv[1]
results = []
for path in sorted(glob.glob(os.path.join(out_dir, "*_result.json"))):
    try:
        with open(path) as fh:
            results.append(json.load(fh))
    except Exception as exc:
        results.append({"probe": os.path.basename(path), "status": "corrupt", "error": repr(exc)})
exit_codes = {}
ec_path = os.path.join(out_dir, "probe_exit_codes.txt")
if os.path.exists(ec_path):
    for line in open(ec_path):
        parts = line.split()
        if len(parts) == 2:
            exit_codes[parts[0]] = parts[1]
summary = {
    "run_id": os.path.basename(out_dir),
    "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "node": os.environ.get("NEXO_NODE_NAME", "unknown"),
    "probe_count": len(results),
    "exit_codes": exit_codes,
    "probes": results,
}
with open(os.path.join(out_dir, "results.json"), "w") as fh:
    json.dump(summary, fh, indent=2, sort_keys=True)
lines = ["# Wave 1 Discovery Report — %s" % summary["generated"], ""]
lines.append("| probe | status | highlights |")
lines.append("|---|---|---|")
for probe in results:
    name = probe.get("probe", "?")
    status = probe.get("status", "?")
    data = probe.get("data", {}) or {}
    highlights = []
    for key in ("zones", "tunnels", "workers", "gateways", "hosts_up", "blindspots", "repos_total", "stale_repos", "ollama_models", "mcp_configs"):
        value = data.get(key)
        if isinstance(value, list):
            highlights.append("%s=%d" % (key, len(value)))
        elif isinstance(value, (int, str)) and key in data:
            highlights.append("%s=%s" % (key, value))
    lines.append("| %s | %s | %s |" % (name, status, ", ".join(highlights) or "-"))
lines.append("")
with open(os.path.join(out_dir, "REPORT.md"), "w") as fh:
    fh.write("\n".join(lines) + "\n")
print("[aggregate] wrote results.json + REPORT.md (%d probes)" % len(results))
PYAGG
python3 "${AGGREGATE}" "${OUT_DIR}"

# --- Stage 4b: optional signed push to CF edge D1 (z.ai handoff plane) --------
if [ -n "${NEXO_INGEST_URL:-}" ] && [ -n "${NEXO_INGEST_HMAC_KEY:-}" ]; then
  python3 - "${OUT_DIR}/results.json" <<'PYPUSH'
import datetime, hashlib, hmac, json, os, sys, time, urllib.error, urllib.request

results_path = sys.argv[1]
out_dir = os.path.dirname(results_path)
receipt_path = os.path.join(out_dir, "push_receipt.json")
url = os.environ["NEXO_INGEST_URL"]
key = os.environ["NEXO_INGEST_HMAC_KEY"].encode()
now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
receipt = {"status": "failed", "ts": now}

def write_receipt(extra=None):
    if extra:
        receipt.update(extra)
    with open(receipt_path, "w") as fh:
        json.dump(receipt, fh, indent=2, sort_keys=True)
    print("[push] status=%s (%s)" % (receipt.get("status"), receipt_path))

try:
    with open(results_path) as fh:
        results = json.load(fh)
except Exception as exc:
    write_receipt({"status": "failed", "error": "cannot read results.json: %r" % (exc,)})
    sys.exit(0)

records = []
node = results.get("node", "unknown")
for probe in results.get("probes", []):
    name = str(probe.get("probe", ""))
    data = probe.get("data") or {}
    if name.startswith("05"):
        base = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")
        for model in data.get("ollama_models", []) or []:
            if not isinstance(model, dict):
                continue
            records.append({"table": "mcp_server_registry", "op": "upsert", "row": {
                "node": node,
                "server_name": "ollama:%s" % model.get("name", "unknown"),
                "transport": "http",
                "listen_path": base,
                "status": "ok",
                "context_bounds": model.get("num_ctx"),
                "capabilities": json.dumps(["chat"]),
                "first_seen": now, "last_seen": now}})
        for cfg in data.get("mcp_configs", []) or []:
            records.append({"table": "mcp_server_registry", "op": "upsert", "row": {
                "node": node,
                "server_name": "config:%s" % os.path.basename(str(cfg)),
                "transport": "stdio",
                "listen_path": str(cfg)[:400],
                "status": "detected",
                "capabilities": json.dumps([]),
                "first_seen": now, "last_seen": now}})
        for proc in (data.get("mcp_processes", []) or [])[:20]:
            parts = str(proc).split(None, 1)
            if not parts:
                continue
            pid = int(parts[0]) if parts[0].isdigit() else None
            cmdline = parts[1][:200] if len(parts) > 1 else ""
            pname = os.path.basename(cmdline.split()[0]) if cmdline else "mcp"
            records.append({"table": "mcp_server_registry", "op": "upsert", "row": {
                "node": node,
                "server_name": "proc:%s" % pname,
                "transport": "stdio",
                "listen_path": cmdline,
                "pid": pid,
                "status": "detected",
                "capabilities": json.dumps([]),
                "first_seen": now, "last_seen": now}})
    if name.startswith("01"):
        try:
            cap = int(os.environ.get("DAILY_SPEND_CAP_PENCE", "500") or 500)
        except ValueError:
            cap = 500
        for gw in data.get("gateways", []) or []:
            if not isinstance(gw, dict):
                continue
            notes = {k: gw.get(k) for k in ("cache", "cache_ttl", "rate_limit", "auth") if k in gw}
            records.append({"table": "cost_governance_ledger", "op": "upsert", "row": {
                "period": now[:10], "scope": "ai-gateway",
                "model_or_service": str(gw.get("id", "")),
                "requests": 0, "cost_pence": 0, "cap_pence": cap,
                "notes": json.dumps(notes, sort_keys=True), "recorded_at": now}})
        if data.get("worker_count"):
            records.append({"table": "cost_governance_ledger", "op": "upsert", "row": {
                "period": now[:7], "scope": "workers-platform",
                "model_or_service": "scripts-total",
                "requests": 0, "cost_pence": 0, "cap_pence": cap,
                "notes": json.dumps({"workers": data.get("worker_count"),
                                     "burn_risk": bool(data.get("worker_burn_risk"))}),
                "recorded_at": now}})

records = records[:500]
if not records:
    write_receipt({"status": "empty", "records": 0})
    sys.exit(0)

envelope = {"schema_version": 1, "node": node,
            "run_id": results.get("run_id", ""), "generated": now, "records": records}
raw = json.dumps(envelope, separators=(",", ":")).encode("utf-8")
t = str(int(time.time()))
sig = hmac.new(key, t.encode("ascii") + b"." + raw, hashlib.sha256).hexdigest()
req = urllib.request.Request(url, data=raw, method="POST", headers={
    "Content-Type": "application/json",
    "X-Nexo-Signature": "t=%s,v1=%s" % (t, sig),
    "User-Agent": "nexo-orchestrator/2.0"})
try:
    with urllib.request.urlopen(req, timeout=20) as resp:
        body = resp.read().decode("utf-8", "replace")
        try:
            parsed = json.loads(body)
        except Exception:
            parsed = {"raw": body[:200]}
        write_receipt({"status": "ok", "http": resp.status,
                       "records_sent": len(records), "response": parsed})
except urllib.error.HTTPError as exc:
    detail = ""
    try:
        detail = exc.read().decode("utf-8", "replace")[:300]
    except Exception:
        pass
    write_receipt({"status": "rejected", "http": exc.code, "detail": detail})
except Exception as exc:
    write_receipt({"status": "failed", "error": repr(exc)})
sys.exit(0)
PYPUSH
else
  echo "[orchestrator] ingest push skipped (NEXO_INGEST_URL/NEXO_INGEST_HMAC_KEY not hydrated)"
fi

TOTAL="${#PROBES[@]}"
if [ "${FAILURES}" -ge "${TOTAL}" ]; then
  echo "[orchestrator] FATAL: all ${TOTAL} probes failed — inspect ${OUT_DIR}/*.log"
  exit 1
fi
echo "[orchestrator] wave complete: ${FAILURES}/${TOTAL} probe(s) degraded — artifacts in ${OUT_DIR}"
exit 0
