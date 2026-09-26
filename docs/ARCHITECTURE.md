# ARCHITECTURE.md — Unified Source-of-Truth Matrix (frozen at scaffold time)

## 1. Fleet & addressing

| Node | LAN | Mesh/TS-era | Role | Constraints |
|---|---|---|---|---|
| markslone | 192.168.1.179 | 100.67.45.88 | gateway: wgcf WARP breakout, AdGuard Home, netboot.xyz PXE (69/udp,8080/tcp host-mode), AI Cockpit Docker, WoL relay :9000, Salt master | i5-3210M/8GB/700GB 5400RPM — Law 4 spindle protection; OS autodetect (pacman observed) |
| jessicafletcher | 192.168.1.138 (was .139 — reserve DHCP) | 100.64.77.115 | LLM appliance + control node | i7-8700/16152MB/UHD630/SN720-256G; isolcpus 2-5; S5 idle + WoL |
| barryslone | 192.168.1.186 | 100.86.147.118 | NAS/backup | Phenom/3GB; no containers; Restic+XFS noatime+hdparm -S 15min |
| tanyacheex | 192.168.1.164 | 100.96.74.72 | cockpit workstation | Pop!_OS via PXE; autorandr eDP-1+HDMI-1 |
| michaelknight | (OCI) | 100.84.81.62 | LiteLLM HA pool | free ARM tier |
| sharon/openwrt-primary | 192.168.1.1 | — | router | Cake SQM; DHCP opt 3/6->markslone, 66/67->netboot.xyz.efi; 30m leases; MAC 28:ee:52:62:62:08 |
| openwrt-secondary | 192.168.1.250 | — | router | — |
| columbo | — | 100.119.198.77 | blocked/ephemeral | ACL state unexplained — wave1 probe target |
| amandabentley | — | 100.89.165.68 | blocked/static | wave1 probe target |
| ironside | — | — | blocked/ephemeral | wave1 probe target |
| ai-server | — | 100.101.0.1 | static worker | wave1 probe target |
| vps-master | — | 100.64.0.1 | Hetzner 1vCPU/2GB nexo dashboard | Docker: nexo-app(:3000, 2G/2CPU)+cloudflared(256M/0.5CPU); SQLite custom.db 35 tables |

## 2. Service & port map

| Service | Host | Port | Access path |
|---|---|---|---|
| llama.cpp server (Vulkan) | jessicafletcher | 8080 | api.acidwurx.org /v1/* via tunnel |
| MCP tool server | jessicafletcher | 8000 | api.acidwurx.org /mcp/* via tunnel |
| Open WebUI | markslone | 3000 | cockpit.acidwurx.org via tunnel |
| LiteLLM | markslone | 4000 | mesh-internal only (master key env) |
| SearXNG | markslone | 8081 | mesh-internal |
| AdGuard Home | markslone | 53/3001 | LAN DNS; rewrite `||*.gui^$dnsrewrite=192.168.1.179` |
| WoL listener | markslone | 9000 | mesh-internal POST /wake |
| netboot.xyz | markslone | 69/udp, 8080/tcp | LAN PXE |
| Home Assistant | (IoT host) | 8123 | mesh-internal |
| n8n | (services host) | 5678 | mesh-internal |
| Ollama | jessicafletcher | 11434 | **loopback/tunnel-only** (exposure = blindspot) |
| Paperless-ngx | (nas) | 8100 | mesh-internal |
| Plane | (vps) | 8081 | mesh-internal (host-distinct from SearXNG) |
| Jellyfin / Portainer | media/vps | 8096 / 9000 | tunnel-optional (Portainer 9000 must not bind WAN) |
| SSH | all linux nodes | 22 | mesh/LAN only |

## 3. Domains & edge assets

- Zone: acidwurx.org (free plan, zone id in .env — CF_ZONE_ID).
- Hostnames: api.acidwurx.org (inference, Access-gated), acidwurx.org
  (appliance health/portal), cockpit.acidwurx.org (Open WebUI),
  nexo.acidwurx.com (legacy NEXO dashboard, Hetzner), *.gui (internal
  wildcard via AdGuard rewrite).
- AI Gateway: `acidwurx` — https://gateway.ai.cloudflare.com/v1/$CF_ACCOUNT_ID/acidwurx/compat
  (cache 30d, 60 req/min, auth ON). Gateways acidwurx2/master: consolidate.
- Worker: acidwurx-cost-monitor = Budget Sentinel (KV ACIDWURX_SPEND_KV).
  ~110 legacy workers exist — probe 01 inventories; consolidation report via
  probe 04 pattern.
- Tunnels: acidwurx-bare-metal (appliance ingress + private route
  192.168.1.0/24 through vnet acidwurx-mesh).
- z.ai handoff plane: D1 database `nexo-telemetry` (tables mcp_server_registry,
  partial_code_fragments, cost_governance_ledger) behind edge worker
  nexo-telemetry-ingest on ingest.acidwurx.org (HMAC-SHA256 signed envelopes,
  outbound-only push through the tunnel/WARP path — zero inbound exposure).
  Contract: docs/interop/ZAI_HANDOFF_SCHEMA.md; schema: infra/cloudflare/d1/schema.sql.
- DNS violation policy: no record may point to private/CGNAT/ISP space.

## 4. Security posture baseline (from observed telemetry)

- ISP CGNAT IP 88.97.176.163 — outbound leak canary for probe 03.
- Known-good WARP check: `curl --interface <warp> https://1.1.1.1/cdn-cgi/trace`
  contains `warp=on`; outbound IP != ISP CGNAT IP.
- Historical blindspots (must re-verify + remediate): Ollama 0.0.0.0:11434,
  xrdp :3389, Plex :3240, :9090, rpcbind :111 on jessicafletcher.
- Host hardening baseline: ASLR full, dmesg restricted, AppArmor available,
  mitigations active (meltdown PTI, spectre IBRS/IBPB, MDS clear+SMT-vuln
  noted), entropy medium (256 bits at fresh boot).

## 5. Evolution ledger (newest wins)

Tailscale -> NetBird (4-phase migration, incomplete) -> **Cloudflare Mesh**
(decommissioned overlays). Terraform -> OpenTofu -> **Pulumi TS (v5 provider)**.
Packer ISO -> Packer netboot -> **netboot.xyz PXE**. Alpine appliance -> DietPi
pivot -> **Debian-family appliance, engine-autodetected**. Caddy/LiteLLM on
appliance -> stripped (0MB proxy overhead) -> LiteLLM lives on markslone/
michaelknight only. orchestrator-3b+1b -> llama3-8b -> **qwen2.5-coder-7b
q4_k_m** (appliance) with @cf/meta/llama-3-8b-instruct edge failover.
Bitwarden CLI -> **sops+age (NEXO_VAULT_KEY)**. LibreChat/LobeChat rejected ->
**Open WebUI**.
