#!/usr/bin/env bash
# =============================================================================
# 05_local_ai_mcp_audit.sh — read-only verification of the local AI plane:
# Ollama profiles + raw context bounds (num_ctx), bind-safety check, llama.cpp
# appliance health (:8080/health, /v1/models), FastMCP importability, MCP
# config/daemon discovery (opencode/claude/nexo paths, systemd user units,
# process table), and Stage-10 task board artifacts (tasks.json/TASK_BOARD.md).
# Writes 05_local_ai_mcp_audit_result.json.
# =============================================================================
set -euo pipefail

OUT_DIR="${NEXO_OUT_DIR:-.}"
mkdir -p "${OUT_DIR}"
TMPD="$(mktemp -d)"
trap 'rm -rf "${TMPD}"' EXIT

echo "[05] auditing local AI + MCP plane (read-only)"

OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
APPLIANCE_URL="${APPLIANCE_URL:-http://127.0.0.1:8080}"

# --- Ollama --------------------------------------------------------------------
if curl -s --max-time 4 "${OLLAMA_URL}/api/tags" > "${TMPD}/ollama_tags.json" 2>/dev/null; then
  python3 - "${TMPD}/ollama_tags.json" "${OLLAMA_URL}" "${TMPD}" <<'PYEOF'
import json, subprocess, sys
tags_path, base, tmpd = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(tags_path) as fh:
        tags = json.load(fh)
except Exception:
    tags = {"models": []}
models = []
for model in tags.get("models", [])[:10]:
    name = model.get("name", "")
    entry = {"name": name, "size_bytes": model.get("size"), "digest": (model.get("digest") or "")[:12]}
    try:
        import urllib.request
        req = urllib.request.Request(base + "/api/show",
                                     data=json.dumps({"name": name}).encode(),
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=6) as resp:
            show = json.loads(resp.read().decode())
        params = show.get("parameters") or ""
        entry["num_ctx"] = None
        for line in params.splitlines():
            if line.strip().startswith("num_ctx"):
                parts = line.split()
                if len(parts) >= 2 and parts[1].isdigit():
                    entry["num_ctx"] = int(parts[1])
        entry["family"] = (show.get("details") or {}).get("family")
    except Exception:
        entry["show_error"] = True
    models.append(entry)
with open(tmpd + "/ollama_models.json", "w") as fh:
    json.dump(models, fh)
PYEOF
else
  echo '{"unreachable": true}' > "${TMPD}/ollama_models.json"
fi

# --- Ollama bind-safety (Law 5) --------------------------------------------------
if command -v ss >/dev/null 2>&1; then
  ss -tulpnH 2>/dev/null | awk '$5 ~ /:11434$/ {print $5}' > "${TMPD}/ollama_bind.txt" || true
fi

# --- Appliance llama-server --------------------------------------------------------
curl -s --max-time 4 "${APPLIANCE_URL}/health" > "${TMPD}/llama_health.txt" 2>/dev/null || echo "unreachable" > "${TMPD}/llama_health.txt"
curl -s --max-time 4 "${APPLIANCE_URL}/v1/models" > "${TMPD}/llama_models.json" 2>/dev/null || echo "{}" > "${TMPD}/llama_models.json"

# --- FastMCP / python MCP plane ------------------------------------------------------
python3 -c "import fastmcp; print(fastmcp.__version__ if hasattr(fastmcp,'__version__') else 'present')" > "${TMPD}/fastmcp.txt" 2>/dev/null || echo "absent" > "${TMPD}/fastmcp.txt"
python3 -c "import mcp; print('present')" > "${TMPD}/mcp_sdk.txt" 2>/dev/null || echo "absent" > "${TMPD}/mcp_sdk.txt"

# --- MCP config/daemon discovery -------------------------------------------------------
{
  for candidate in \
    "${HOME}/.config/mcp" \
    "${HOME}/.config/opencode" \
    "${HOME}/.config/nexo" \
    "${HOME}/.claude" \
    "${HOME}/.config/claude" \
    "/opt/mcp" ; do
    [ -e "${candidate}" ] && echo "${candidate}" || true
  done
  find "${HOME}/.config" -maxdepth 3 -name "*mcp*.json" -type f 2>/dev/null | head -20 || true
  ls "${HOME}/.claude/claude_desktop_config.json" 2>/dev/null || true
} > "${TMPD}/mcp_paths.txt"

{
  systemctl --user list-units --all 2>/dev/null | grep -iE "mcp|opencode|hermes" || true
  pgrep -af "mcp|fastmcp|opencode|hermes" 2>/dev/null | grep -v pgrep | head -20 || true
} > "${TMPD}/mcp_procs.txt"

# --- Stage-10 task board artifacts --------------------------------------------------------
REPO_ROOT_GUESS="$(cd "${OUT_DIR}/../../.." 2>/dev/null && pwd || echo "")"
{
  for base in "${REPO_ROOT_GUESS}" "$(pwd)" "$(pwd)/../.."; do
    [ -n "${base}" ] || continue
    if [ -f "${base}/docs/tasks/TASK_BOARD.md" ]; then echo "TASK_BOARD:${base}/docs/tasks/TASK_BOARD.md"; fi
    if [ -f "${base}/docs/tasks/tasks.json" ]; then echo "TASKS_JSON:${base}/docs/tasks/tasks.json"; fi
    if [ -f "${base}/docs/tasks/mcp_task_contract.md" ]; then echo "CONTRACT:${base}/docs/tasks/mcp_task_contract.md"; fi
  done
} | sort -u > "${TMPD}/board.txt"

# --- JSON assembly ------------------------------------------------------------------------
python3 - "${TMPD}" "${OUT_DIR}" <<'PYEOF'
import datetime, json, os, sys

tmpd, out_dir = sys.argv[1], sys.argv[2]

def read(name):
    path = os.path.join(tmpd, name)
    if not os.path.exists(path):
        return ""
    with open(path) as fh:
        return fh.read()

def read_json(name, default):
    try:
        return json.loads(read(name) or "null") or default
    except Exception:
        return default

ollama_models = read_json("ollama_models.json", [])
llama_models = read_json("llama_models.json", {})
binds = [b.strip() for b in read("ollama_bind.txt").splitlines() if b.strip()]
exposed = any(b.startswith(("0.0.0.0", "[::]", "*:")) for b in binds)

board = {}
for line in read("board.txt").splitlines():
    if ":" in line:
        key, path = line.split(":", 1)
        board[key.lower()] = path

payload = {
    "probe": "05_local_ai_mcp_audit",
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "node": os.environ.get("NEXO_NODE_NAME", "unknown"),
    "status": "ok" if (ollama_models or llama_models) else "degraded",
    "data": {
        "ollama_models": ollama_models,
        "ollama_bind_exposed": exposed,
        "ollama_binds": binds,
        "context_bounds_ok": all(
            (m.get("num_ctx") or 0) >= 8192 or m.get("num_ctx") is None
            for m in ollama_models if isinstance(m, dict)
        ),
        "llama_server_health": read("llama_health.txt").strip()[:200],
        "llama_server_models": llama_models.get("data", []) if isinstance(llama_models, dict) else [],
        "fastmcp": read("fastmcp.txt").strip(),
        "mcp_sdk": read("mcp_sdk.txt").strip(),
        "mcp_configs": [p.strip() for p in read("mcp_paths.txt").splitlines() if p.strip()],
        "mcp_processes": [p.strip() for p in read("mcp_procs.txt").splitlines() if p.strip()],
        "task_board": board,
    },
}
path = os.path.join(out_dir, "05_local_ai_mcp_audit_result.json")
with open(path, "w") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
print("[05] ollama_models=%d exposed=%s fastmcp=%s -> %s" % (
    len(ollama_models), exposed, payload["data"]["fastmcp"], path))
PYEOF
