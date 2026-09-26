# MCP_TASKS.md — Stage-10 task server wiring

`tools/mcp/nexo_tasks_server.py` is a **pure-stdlib MCP server** (JSON-RPC 2.0
over stdio, newline-delimited) implementing `docs/tasks/mcp_task_contract.md`:
`dispatch_task`, `claim_task`, `start_task`, `complete_task`, `merge_task`,
`list_tasks` — with fcntl locking, atomic replaces, CAS state transitions,
evidence-required completion (Law 10), and TASK_BOARD.md auto-rendered from
tasks.json on every mutation.

## Connect an agent client

OpenCode / generic MCP client config:

```json
{
  "mcpServers": {
    "nexo-tasks": {
      "command": "python3",
      "args": ["/ABS/PATH/TO/platform-2-homelab/acidwurx-nexus/tools/mcp/nexo_tasks_server.py"],
      "env": { "NEXO_TASKS_FILE": "/ABS/PATH/TO/platform-2-homelab/acidwurx-nexus/docs/tasks/tasks.json" }
    }
  }
}
```

Claude-class desktop clients: same `mcpServers` block in
`~/.config/claude/claude_desktop_config.json` (paths absolute; the server has
zero dependencies, so any python3 >= 3.8 host works — including barryslone).

## Human/CLI usage (no client needed)

```bash
./nexo.sh tasks                      # board table
./nexo.sh mcp                        # foreground stdio server (debug)
```

## Lifecycle & gates

backlog → claimed → in_progress → verified → **merged**
(`merge_task` is the human Stage-7 / CI-success boundary; agents stop at
`verified` with evidence.) Parallelism caps from the contract: 4 concurrent
on jessicafletcher (cores 2–5), 2 on markslone (I/O budget), sequential on
barryslone. Bootstrap Stage 10 seeds the board automatically from wave1
findings (blindspots, DNS violations, DHCP drift, consolidation groups).

## Probe 05 verification

`05_local_ai_mcp_audit.sh` checks this server's presence, the tasks.json /
TASK_BOARD.md pair, FastMCP/mcp SDK availability for richer clients, Ollama
context bounds (num_ctx ≥ 8192), and running MCP daemons — so the loop is
self-auditing every wave.
