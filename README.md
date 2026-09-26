# acidwurx-nexus — AcidWurx Sovereign Personal AI Mesh

Single-command GitOps deployment vehicle for the AcidWurx hybrid edge/local AI
mesh. Generated and continuously validated by `generate_nexus_engine.py`
(Python standard library only — zero environment dependency risk).

## One-Click Bootstrap

```bash
# From a clean machine with python3 + git:
git clone https://github.com/<owner>/acidwurx-nexus.git platform-2-homelab/acidwurx-nexus
cd platform-2-homelab/acidwurx-nexus
cp .env.example .env && chmod 600 .env   # fill tokens ONCE, up front
./scripts/wave2_deployment/bootstrap.sh  # zero prompts from here on
```

Every variable is hydrated from the environment at t=0 (`CF_API_TOKEN`,
`CF_ACCOUNT_ID`, `GITHUB_TOKEN`, `NEXO_VAULT_KEY`, `WARP_PRIVATE_KEY`,
`WARP_ADDRESS`, `LITELLM_MASTER_KEY`, `SEARXNG_SECRET_KEY`,
`OPENROUTER_API_KEY`, `CF_TUNNEL_TOKEN`). The pipeline never asks a question
mid-run; missing optional tokens degrade the affected stage to a recorded
`skipped` state in the run receipt.

## Fleet (source-of-truth, extracted from operational archive)

| Node | LAN IP | Mesh role | Hardware / OS baseline |
|---|---|---|---|
| markslone | 192.168.1.179 | Unified gateway: WARP breakout (wgcf Path-B), AdGuard Home DNS, NetBoot.xyz PXE engine, AI Cockpit Docker host, WoL relay (:9000), Salt master | i5-3210M, 8GB DDR3, 700GB 5400RPM HDD — spindle-protected (BFQ, zram-zstd, volatile journal 100M) — Arch-based (autodetected) |
| jessicafletcher | 192.168.1.138/.139 (reserve static) | LLM GPU compute appliance + Ansible control node | HP EliteDesk 800 G4 SFF, i7-8700 6C/12T, 16152MB (2x8GB DDR4-2666), Intel UHD 630 (Vulkan 1.4.305 / Mesa ANV), SanDisk WDC PC SN720 256GB NVMe, BIOS Q01 v02.31.00 |
| barryslone | 192.168.1.186 | Container-free NAS / backup target | AMD Phenom, 3GB RAM ceiling, 2.7TB XFS noatime, hdparm 15-min spin-down, WoL hooks, native Samba + Restic — **no Docker, ever** |
| tanyacheex | 192.168.1.164 | Pop!_OS cockpit workstation (PXE-provisioned, autorandr eDP-1/HDMI-1) | daily driver / thin client |
| michaelknight | OCI free ARM | Edge automation: LiteLLM proxy pool | ~1GB-class ARM |
| sharon (openwrt-primary) | 192.168.1.1 | LAN router: dumb WAP + DHCP relay, Cake SQM, DHCP opt 3/6 -> markslone, opt 66/67 -> netboot.xyz.efi, 30-min leases | OpenWrt (apk-era, dropbear root) |
| openwrt-secondary | 192.168.1.250 | Secondary router | OpenWrt |

Blocked/ephemeral registry nodes (columbo, amandabentley, ironside) and
ai-server / vps-master (Hetzner 1vCPU/2GB) are catalogued in
`docs/ARCHITECTURE.md` and re-verified read-only by wave1 probes.

## Inference Plane

- Appliance engine: rootless Podman `ghcr.io/ggerganov/llama.cpp:server-vulkan`
  on `/dev/dri` (UHD 630, Mesa ANV), model `qwen2.5-coder-7b-instruct-q4_k_m.gguf`,
  `-ngl 99 -t 4 --ctx-size 8192`, `--host 0.0.0.0 --port 8080`, pinned to
  isolated cores 2-5 (`isolcpus=2-5 nohz_full=2-5 rcu_nocbs=2-5`), caps
  `IPC_LOCK`+`SYS_NICE` only, 512 hugepages, `/var/lib/models:/models:ro`.
- Edge: Cloudflare AI Gateway `acidwurx` (caching 30d, 60 req/min, auth on)
  fronted by the Budget Sentinel worker (£5/month cap, KV spend ledger
  `spend:YYYY-MM` in pence, free-model allowlist, blocked-model denylist).
- Dual-gateway routing (OmniRouter pattern): LiteLLM (markslone :4000,
  michaelknight HA pool) routes OpenRouter-free chain -> Workers AI free
  (`@cf/meta/llama-3.2-1b-instruct`, fallback `@cf/qwen/qwen1.5-0.5b-chat`)
  -> local Ollama (`qwen2.5-coder:7b`) -> appliance llama-server.
- UI: Open WebUI (markslone :3000) via tunnel hostname `cockpit.acidwurx.org`;
  SearXNG (:8081, 256M cap) as no-telemetry doc search plugin.
- Power lifecycle: appliance idles in S5 (0W); edge worker health-probes
  `HEAD https://acidwurx.org` (1500ms) and triggers Wake-on-Lan via
  `POST http://<subnet-router>:9000/wake` (wol_listener.py), failing over to
  Workers AI while the node PXE-boots into RAM.

## Networking & Zero Trust

- Outbound CGNAT bypass: LAN 192.168.1.0/24 -> markslone policy routing
  (rt tables: bypass prio 50/51/52 for 100.64.0.0/10, 192.168.1.0/24,
  172.16.0.0/12; breakout table 100 `from 192.168.1.0/24`) -> wgcf WARP
  (MTU 1280, endpoints 162.159.193.1:2408 / 162.159.192.1) -> clean CF IP.
  WAN fallback in the breakout table means **no blackhole** if WARP drops.
- Cloudflare Mesh / WARP Connector (free tier, <=50 nodes) advertises
  192.168.1.0/24 as the private route via tunnel `acidwurx-bare-metal`
  (Pulumi `ZeroTrustTunnelRoute`). NetBird and Tailscale are DECOMMISSIONED.
- Inbound: only CF Access-gated hostnames (api.acidwurx.org /v1/* -> :8080,
  /mcp/* -> :8000, cockpit.acidwurx.org -> :3000), WebAuthn/YubiKey (`swk`)
  required, session 24h. Zero public origin IPs; DNS violation policy
  enforced by probe 01.
- nftables containment (`infra/nftables/mesh-containment.nft`): drop
  UDP 5353 (mDNS) + 1900 (SSDP) in/out on mesh interfaces, no logging
  (HDD-safe), atomic flush+reload, interface names auto-detected
  (CloudflareWARP|warp0|wgcf|cfw0 pattern).

## Repository Layout

```text
.github/workflows/    iac-cd.yml (lint -> pulumi preview -> ansible --check -> gated apply)
                      repo-doc-generator.yml (REPO_MAP.md), dependabot.yml
docs/                 ARCHITECTURE.md, PIPELINE.md, discovery/wave1/, tasks/
infra/pulumi/         index.ts + Pulumi.yaml + package.json (Cloudflare v5 provider
                      + @pulumi/command): tunnel, vnet, 192.168.1.0/24 route,
                      Access swk profiles, D1 database, ingest WorkerScript,
                      AI Gateway caching upsert
infra/ansible/        inventory.ini, playbook.yml, group_vars/all.yml, ansible.cfg
infra/nftables/       mesh-containment.nft
infra/cloudflare/     config.yml (cloudflared ingress), worker.js (edge router + WoL),
                      budget-sentinel/ (wrangler.toml + src/index.ts),
                      telemetry-ingest/ (D1 sink worker + wrangler.toml),
                      d1/schema.sql (z.ai handoff tables)
infra/netbootxyz/     docker-compose.yml, custom-menu.ipxe, openwrt-uci.md
docs/interop/         ZAI_HANDOFF_SCHEMA.md (webhook/HMAC/D1 contract for z.ai peer)
scripts/wave1_discovery/  00_master_orchestrator.sh + probes 01-12 (read-only,
                      parallel: edge, LAN/IoT, hardware, GitHub, AI/MCP, fleet SSH
                      inventory, router capture, cloud imaging, GH governance,
                      storage, service matrix, secrets posture)
scripts/wave2_deployment/ bootstrap.sh, validation_trace.sh, wol_listener.py,
                      deploy_budget_sentinel.sh, create_ai_gateway.sh,
                      deploy_telemetry_ingest.sh, fleet_backup.sh
scripts/wave3_bulk/   fleet_apply.sh (canary-disciplined bulk ansible)
scripts/ci/           validate_repo.py (standalone re-run of the engine harness)
platform/             SERVICE FACTORY: launch.py + hosts.json + profiles/*.json
                      (n8n, jellyfin, uptime-kuma, netbox, semaphore, esphome,
                      _template) -> rendered compose + budget/law-gated deploy
tools/mcp/            nexo_tasks_server.py — pure-stdlib MCP task server (Stage 10)
tools/telemetry/      pack.py — classify/redact/encrypt wave runs for the secure
                      telemetry area (telemetry/PUSH_MANIFEST.json is the law)
tools/access/         request_access.py — AI-agent keygen + access-request issue
tools/remediation/    rules.json (36 routes, risk-classified) + engine.py —
                      facts -> plan -> auto-safe executor -> task board rows
.github/workflows/    + access-approval.yml (label-driven grant/deny -> .sops.yaml)
docs/                 + ACCESS_APPLICATION.md (agent application procedure)
nexo.sh               unified CLI: wave1 | validate | launch | status | backup |
                      tasks | mcp | trace | report | push | remediate | facts |
                      matrix | coverage | fleet-apply | public-audit | cron |
                      notify | access-request
```

## Governance

- Secrets: sops + age (`NEXO_VAULT_KEY`). `.sops.yaml` pins the repo
  recipient; encrypted blobs may live in-repo; plaintext never does.
  Legacy Bitwarden CLI hydration (`bw get password acidwurx/...`) is
  documented in `.env.example` comments for migration.
- Promotion gate: GitHub environment `production-bare-metal` requires manual
  approval; branch `main` requires PR + status checks + signed commits.
- All wave1 tooling is strictly read-only (GET/listen/connect-probe only).

## Verification

Run the internal harness any time without regenerating:

```bash
python3 scripts/ci/validate_repo.py .
```

It re-executes the exact checks the engine applied before committing:
bash -n syntax, Python AST compile, JSON parse, YAML structural lint,
TypeScript brace/paren balance, placeholder ban, and crypto self-tests.
