# TASK_BOARD.md — Parallel Sub-Agent Task Chart (Stage 10)

State machine: `backlog -> claimed -> in_progress -> verified -> merged`
Claim protocol: see docs/tasks/mcp_task_contract.md (FastMCP tools).
Chart below is the seed board; rows are appended by wave1 findings.

| id | task | target | agent | state | evidence |
|---|---|---|---|---|---|
| T-001 | Reserve static DHCP lease jessicafletcher=.138 on sharon | openwrt-primary | human | backlog | uci show dhcp |
| T-002 | Rebind Ollama to 127.0.0.1 (systemd override) | jessicafletcher | sub-agent-1 | backlog | ss -tulpn grep 11434 |
| T-003 | Close xrdp/3389 + rpcbind/111 exposure | jessicafletcher | sub-agent-1 | backlog | probe 03 delta |
| T-004 | Rotate compromised CF API token (export leak) | cloudflare | human | backlog | wrangler whoami |
| T-005 | Consolidate AI gateways acidwurx2/master -> acidwurx | cloudflare | sub-agent-2 | backlog | probe 01 diff |
| T-006 | Inventory ~110 workers; flag dead/duplicate | cloudflare | sub-agent-2 | backlog | probe 01 + 04 report |
| T-007 | Explain/resolve blocked ACL nodes (columbo, amandabentley, ironside) | mesh | sub-agent-3 | backlog | probe 02 ARP+ping |
| T-008 | ESPHome/OpenWrt staging list from OUI sweep | lan | sub-agent-3 | backlog | probe 02 oui table |
| T-009 | WoL BIOS enablement check + wol_listener.py deploy | markslone+jessicafletcher | sub-agent-1 | backlog | ethtool wol g |
| T-010 | BarrySlone Restic USB repo init + spin-down verify | barryslone | sub-agent-4 | backlog | restic snapshots; hdparm -C |
