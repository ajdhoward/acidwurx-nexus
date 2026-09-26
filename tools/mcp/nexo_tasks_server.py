#!/usr/bin/env python3
"""tools/mcp/nexo_tasks_server.py — Stage-10 task-assignment MCP server.
PURE STDLIB JSON-RPC 2.0 over stdio (newline-delimited), implementing the
Model Context Protocol surface the fleet's agent runners (OpenCode, Hermes,
Claude-class desktops) connect to. Contract: docs/tasks/mcp_task_contract.md.

Tools:
  dispatch_task(title, target, priority?) -> task_id     [state=backlog]
  claim_task(task_id, agent) -> bool        (atomic CAS backlog->claimed)
  start_task(task_id, agent) -> bool        (claimed->in_progress)
  complete_task(task_id, agent, evidence) -> bool  (->verified)
  merge_task(task_id, agent) -> bool        (verified->merged; human/CI gate)
  list_tasks(state?) -> rows

Concurrency: fcntl exclusive lock + atomic os.replace; single JSON source of
truth (docs/tasks/tasks.json); TASK_BOARD.md markdown chart regenerated from
JSON on every mutation. Parallelism caps from the contract are advisory and
enforced by the orchestrating agents, not the file store.

CLI mode (no MCP client needed):
  nexo_tasks_server.py --cli list   # print the board as a table
Run mode:  nexo_tasks_server.py     # stdio server (used by nexo.sh mcp)
Env: NEXO_TASKS_FILE (default <repo>/docs/tasks/tasks.json).
"""
import datetime
import json
import os
import sys
import tempfile

try:
    import fcntl
except ImportError:  # non-POSIX fallback: proceed without advisory locks
    fcntl = None

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
TASKS_FILE = os.environ.get("NEXO_TASKS_FILE") or os.path.join(REPO, "docs", "tasks", "tasks.json")
BOARD_FILE = os.path.join(os.path.dirname(TASKS_FILE), "TASK_BOARD.md")
STATES = ["backlog", "claimed", "in_progress", "verified", "merged"]
SERVER_INFO = {"name": "nexo-tasks", "version": "1.0.0"}
DEFAULT_PROTOCOL = "2024-11-05"

TOOL_SPECS = [
    {"name": "dispatch_task",
     "description": "Append a new task row (state=backlog). Returns the assigned task_id.",
     "inputSchema": {"type": "object",
                     "properties": {"title": {"type": "string"},
                                    "target": {"type": "string", "description": "node or domain, e.g. jessicafletcher, cloudflare"},
                                    "priority": {"type": "string", "enum": ["low", "normal", "high"]}},
                     "required": ["title", "target"]}},
    {"name": "claim_task",
     "description": "Atomic compare-and-set backlog->claimed for one agent. Refuses double claims.",
     "inputSchema": {"type": "object",
                     "properties": {"task_id": {"type": "string"}, "agent": {"type": "string"}},
                     "required": ["task_id", "agent"]}},
    {"name": "start_task",
     "description": "claimed->in_progress by the claiming agent.",
     "inputSchema": {"type": "object",
                     "properties": {"task_id": {"type": "string"}, "agent": {"type": "string"}},
                     "required": ["task_id", "agent"]}},
    {"name": "complete_task",
     "description": "in_progress/claimed->verified with evidence string (command output path, probe artifact id).",
     "inputSchema": {"type": "object",
                     "properties": {"task_id": {"type": "string"}, "agent": {"type": "string"},
                                    "evidence": {"type": "string"}},
                     "required": ["task_id", "agent", "evidence"]}},
    {"name": "merge_task",
     "description": "verified->merged. Reserved for the human Stage-7 gate or CI success.",
     "inputSchema": {"type": "object",
                     "properties": {"task_id": {"type": "string"}, "agent": {"type": "string"}},
                     "required": ["task_id", "agent"]}},
    {"name": "list_tasks",
     "description": "List tasks, optionally filtered by state.",
     "inputSchema": {"type": "object",
                     "properties": {"state": {"type": "string", "enum": STATES}}}},
]


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


def load_tasks():
    if not os.path.exists(TASKS_FILE):
        return []
    with open(TASKS_FILE) as fh:
        return json.load(fh).get("tasks", [])


def save_tasks(tasks):
    os.makedirs(os.path.dirname(TASKS_FILE), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(TASKS_FILE), prefix=".tasks-", suffix=".json")
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump({"tasks": tasks, "updated": now_iso()}, fh, indent=2)
        os.replace(tmp, TASKS_FILE)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    render_board(tasks)


def render_board(tasks):
    lines = ["# TASK_BOARD.md — Parallel Sub-Agent Task Chart (Stage 10)", "",
             "_Auto-rendered from tasks.json by nexo_tasks_server — edit via MCP tools, not by hand._", "",
             "| id | task | target | agent | state | evidence |", "|---|---|---|---|---|---|"]
    for t in tasks:
        lines.append("| %s | %s | %s | %s | %s | %s |" % (
            t.get("id", "?"), (t.get("title") or "").replace("|", "\\|"),
            t.get("target", ""), t.get("agent") or "—", t.get("state", "?"),
            (t.get("evidence") or "—").replace("|", "\\|")))
    lines.append("")
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(BOARD_FILE), prefix=".board-", suffix=".md")
    with os.fdopen(fd, "w") as fh:
        fh.write("\n".join(lines))
    os.replace(tmp, BOARD_FILE)


class TaskLock:
    def __enter__(self):
        os.makedirs(os.path.dirname(TASKS_FILE), exist_ok=True)
        self._lock_fh = open(TASKS_FILE + ".lock", "w")
        if fcntl is not None:
            fcntl.flock(self._lock_fh, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        if fcntl is not None:
            fcntl.flock(self._lock_fh, fcntl.LOCK_UN)
        self._lock_fh.close()
        return False


def next_id(tasks):
    highest = 0
    for t in tasks:
        raw = str(t.get("id", "")).replace("T-", "")
        if raw.isdigit():
            highest = max(highest, int(raw))
    return "T-%03d" % (highest + 1)


def tool_dispatch(args):
    title = str(args.get("title", "")).strip()
    target = str(args.get("target", "")).strip()
    if not title or not target:
        return {"ok": False, "error": "title and target are required"}
    with TaskLock():
        tasks = load_tasks()
        task_id = next_id(tasks)
        tasks.append({"id": task_id, "title": title, "target": target,
                      "priority": args.get("priority", "normal"), "agent": None,
                      "state": "backlog", "evidence": None,
                      "created": now_iso(), "updated": now_iso()})
        save_tasks(tasks)
    return {"ok": True, "task_id": task_id}


def tool_transition(args, allowed_from, to_state, needs_evidence=False):
    task_id = str(args.get("task_id", ""))
    agent = str(args.get("agent", ""))
    evidence = args.get("evidence")
    if needs_evidence and not str(evidence or "").strip():
        return {"ok": False, "error": "evidence is required (Law 10)"}
    with TaskLock():
        tasks = load_tasks()
        for t in tasks:
            if t.get("id") != task_id:
                continue
            if t.get("state") not in allowed_from:
                return {"ok": False, "error": "task %s in state %r, expected one of %r" % (task_id, t.get("state"), allowed_from)}
            if to_state != "merged" and t.get("agent") not in (None, agent):
                return {"ok": False, "error": "task %s already owned by %r" % (task_id, t.get("agent"))}
            t["agent"] = agent
            t["state"] = to_state
            if evidence is not None:
                t["evidence"] = str(evidence)[:500]
            t["updated"] = now_iso()
            save_tasks(tasks)
            return {"ok": True, "task_id": task_id, "state": to_state}
        return {"ok": False, "error": "unknown task_id %r" % task_id}


def tool_list(args):
    tasks = load_tasks()
    state = args.get("state")
    if state:
        tasks = [t for t in tasks if t.get("state") == state]
    return {"ok": True, "count": len(tasks), "tasks": tasks}


TOOLS = {
    "dispatch_task": tool_dispatch,
    "claim_task": lambda a: tool_transition(a, ["backlog"], "claimed"),
    "start_task": lambda a: tool_transition(a, ["claimed"], "in_progress"),
    "complete_task": lambda a: tool_transition(a, ["claimed", "in_progress"], "verified", needs_evidence=True),
    "merge_task": lambda a: tool_transition(a, ["verified"], "merged"),
    "list_tasks": tool_list,
}


def rpc_result(req_id, result):
    return {"jsonrpc": "2.0", "id": req_id, "result": result}


def rpc_error(req_id, code, message):
    return {"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}}


def handle(msg):
    method = msg.get("method")
    req_id = msg.get("id")
    params = msg.get("params") or {}
    if method == "initialize":
        client_proto = params.get("protocolVersion") or DEFAULT_PROTOCOL
        return rpc_result(req_id, {"protocolVersion": client_proto,
                                   "capabilities": {"tools": {"listChanged": False}},
                                   "serverInfo": SERVER_INFO})
    if method in ("notifications/initialized", "initialized"):
        return None
    if method == "ping":
        return rpc_result(req_id, {})
    if method == "tools/list":
        return rpc_result(req_id, {"tools": TOOL_SPECS})
    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        if name not in TOOLS:
            return rpc_error(req_id, -32602, "unknown tool %r" % name)
        try:
            outcome = TOOLS[name](args)
        except Exception as exc:
            outcome = {"ok": False, "error": repr(exc)}
        return rpc_result(req_id, {
            "content": [{"type": "text", "text": json.dumps(outcome, indent=2)}],
            "isError": not outcome.get("ok", False),
        })
    if req_id is not None:
        return rpc_error(req_id, -32601, "method not found: %r" % method)
    return None


def serve_stdio():
    sys.stderr.write("[nexo-tasks] MCP stdio server up (tasks: %s)\n" % TASKS_FILE)
    sys.stderr.flush()
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception as exc:
            sys.stdout.write(json.dumps(rpc_error(None, -32700, "parse error: %r" % (exc,))) + "\n")
            sys.stdout.flush()
            continue
        try:
            response = handle(msg)
        except Exception as exc:
            response = rpc_error(msg.get("id"), -32603, "internal error: %r" % (exc,))
        if response is not None:
            sys.stdout.write(json.dumps(response) + "\n")
            sys.stdout.flush()


def cli_list():
    tasks = load_tasks()
    if not tasks:
        print("(board empty — dispatch via MCP tools or bootstrap Stage 10)")
        return
    print("%-7s %-9s %-16s %-52s %s" % ("ID", "STATE", "TARGET", "TITLE", "AGENT"))
    for t in tasks:
        print("%-7s %-9s %-16s %-52s %s" % (
            t.get("id"), t.get("state"), str(t.get("target"))[:16],
            str(t.get("title"))[:52], t.get("agent") or "—"))


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "--cli" and sys.argv[2] == "list":
        cli_list()
        return 0
    if len(sys.argv) >= 2 and sys.argv[1] == "--cli":
        sys.stderr.write("usage: --cli list\n")
        return 2
    serve_stdio()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
