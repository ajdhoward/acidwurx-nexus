# PIPELINE.md — The 10-Stage Execution Lifecycle

| Stage | Owner | Mechanism | Gate |
|---|---|---|---|
| 1. Pre-flight variable hydration | bootstrap.sh | set -a; source .env; strict env checks; zero prompts; missing optional vars recorded as `skipped` | bootstrap aborts ONLY if .env unreadable |
| 2. age keygen + sops integration | generate_nexus_engine.py | pure-stdlib X25519+bech32 (RFC 7748 self-test) or NEXO_VAULT_KEY import; keys at ~/.config/nexo/age/keys.txt (0600, outside repo); .sops.yaml recipient pinned | crypto self-test must pass (NEXO-E-5001) |
| 3. Read-only parallel telemetry wave | scripts/wave1_discovery/00_master_orchestrator.sh | background probes 01-05 with per-probe timeouts + logs; aggregation to results.json | every probe read-only by construction (GET/connect/listen) |
| 4. Telemetry normalization | 00_master_orchestrator.sh + probes | unified JSON schema {node,probe,ts,status,data[]}; markdown mirrors for AI ingestion | json.load must parse every artifact |
| 5. Mesh route verification | probe 03 + validation_trace.sh | WARP iface detection, policy-routing order check (bypass 50-52 above breakout 100), outbound IP != ISP CGNAT, `warp=on`, tunnel route presence via CF API | non-zero exit on any failed assertion |
| 6. Dry-run IaC simulation | .github/workflows/iac-cd.yml job `pulumi-preview` + `ansible-dry` | `pulumi preview` (file-backend, no cloud), `ansible-playbook --syntax-check` + `--check --diff` | preview/plan diff attached to PR; failure blocks |
| 7. Manual authorization lock | GitHub environment `production-bare-metal` | required reviewers = repo owner; apply jobs `needs:` the environment | human approval click (the repo button) |
| 8. Live edge orchestration | iac-cd.yml job `edge-apply` | `pulumi up` (tunnel, vnet, route 192.168.1.0/24, Access app+swk policy, CNAMEs), create_ai_gateway.sh (REST, idempotent GET-before-POST), deploy_budget_sentinel.sh (KV create + wrangler) | post-apply validation_trace.sh TTFT probe |
| 9. Bare-metal configuration | iac-cd.yml job `ansible-apply` (webfactory/ssh-agent) | playbook.yml: debloat, isolcpus via GRUB/extlinux per-distro, nftables containment, rootless podman, Mesa-Vulkan (mesa-vulkan-drivers/libvulkan1/vulkan-tools), hugepages 512, sysctls, model seeding, container start, healthcheck | `ansible-playbook` rc=0 + podman health=healthy + :8080 /v1/models 200 |
| 10. Continuous integration mapping | docs/tasks/TASK_BOARD.md + mcp_task_contract.md | FastMCP tools (dispatch_task/claim_task/complete_task) read/write the markdown chart + tasks.json; sub-agents (OpenCode/Hermes) claim rows; orchestrator probe 05 verifies MCP paths | board state machine: backlog->claimed->verified->merged |

## Failure-mode preemptions encoded (from witnessed incidents)

1. Verification honesty: every validator exits non-zero on real failure.
2. Terminal-killer one-liners banned; long jobs run under tmux/nohup.
3. WARP handshake: endpoint rotation list + MTU 1280 + UDP-2408-blocked hint.
4. Key paste corruption: env injection only; wgcf conf generated, never pasted.
5. HDD death: Law 4 controls on markslone; ionice -c3 in bootstrap.
6. Zip-merge drift: engine scaffolding is the only writer; --force replaces.
7. DHCP drift (.138/.139): inventory pins ansible_host; probe 02 detects drift.
8. CF 120s timeout on long generations: SSE streaming + keepalive headers.
9. IPv6 timeouts masking results: probes pin `-4` where semantic.
10. Rate limits: probe 04 caps README fetches (GITHUB_CONSOLIDATION_MAX_READMES).
