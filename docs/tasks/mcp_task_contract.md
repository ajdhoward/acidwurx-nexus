# mcp_task_contract.md — FastMCP Task Assignment Contract (Stage 10)

Local MCP server (FastMCP, stdio transport) exposing three tools that operate
on `docs/tasks/TASK_BOARD.md` + `docs/tasks/tasks.json` (JSON mirror). All
tools are file-transaction based (read-modify-write with atomic replace) so
parallel sub-agents (OpenCode/Hermes runners, local AI continuations) never
corrupt the board.

## Tools

1. `dispatch_task(title, target, priority) -> task_id`
   Appends a row (state=backlog) to board+mirror. Used by the orchestrator
   after wave1 findings are normalized (Stage 4 JSON -> rows).
2. `claim_task(task_id, agent) -> bool`
   Atomic compare-and-set backlog->claimed. Refuses double claims.
3. `complete_task(task_id, agent, evidence) -> bool`
   claimed/in_progress->verified with evidence string (command output path,
   probe artifact id). verified->merged is reserved for the human approval
   gate (Law 7) or CI status success.

## Chart contract

- tasks.json schema:
  `{"tasks":[{"id":"T-###","title":str,"target":str,"agent":str|null,
    "state":"backlog|claimed|in_progress|verified|merged",
    "evidence":str|null,"created":iso8601,"updated":iso8601}]}`
- The markdown table in TASK_BOARD.md is regenerated from tasks.json on every
  mutation (single source of truth = JSON; markdown = AI-ingestible view).
- Probe `05_local_ai_mcp_audit.sh` verifies: FastMCP importable, tool
  registration manifest present, Ollama profile context bounds
  (num_ctx >= 8192 for qwen2.5-coder:7b), MCP daemon paths (~/.config/mcp,
  opencode config, claude_desktop_config.json) and reports drift.

## Parallelism rules

- One agent per task (claim exclusivity).
- Max 4 concurrent local tasks on jessicafletcher (cores 2-5 = 4 pins).
- Max 2 concurrent tasks on markslone (Law 4 I/O budget).
- barryslone: sequential only, never during spin-down windows.
