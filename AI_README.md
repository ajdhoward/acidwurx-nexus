# AI_README.md — Architectural Guardrail Laws for Autonomous Agents

**ATTENTION FUTURE AI AGENTS & MULTI-AGENT RUNNERS (OpenCode / Hermes / MCP
sub-agents):** this repository drives real bare-metal hardware on a strict
16GB-RAM appliance and an 8GB/5400RPM gateway. Violations brick boot paths or
starve compute. Adhere to every law below when proposing or writing changes.

## Law 1 — Container Runtime
The appliance (jessicafletcher) uses **rootless, daemonless Podman only**.
Never generate docker-compose specs, dockerd units, or systemd container
trackers for the appliance. markslone is the ONLY Docker host (AI Cockpit:
Open WebUI 1G / LiteLLM 512M / SearXNG 256M caps — never raise them; 8GB
ceiling). barryslone is container-FREE (3GB Phenom): native binaries only
(Restic, Samba, hdparm), never Docker/Podman.

## Law 2 — Overlay & Routing
All mesh traffic rides **Cloudflare Zero Trust (Mesh/Tunnels/wgcf WARP)**.
Tailscale, NetBird, WireGuard-mesh daemons, OmniRoute daemons are
DECOMMISSIONED — do not reinstall or reference them. Routing changes must:
(a) keep bypass rules (to 100.64.0.0/10, 192.168.1.0/24, 172.16.0.0/12 ->
main, priorities 50-52) ABOVE the breakout rule (from 192.168.1.0/24 ->
table 100, priority 100); (b) preserve the WAN fallback default in table 100
so a WARP outage can never blackhole the LAN; (c) never add a DNS line to the
wgcf config (AdGuard Home on markslone owns DNS); (d) auto-detect interface
names at runtime (patterns: CloudflareWARP, warp0, wgcf, cfw0) — never
hardcode.

## Law 3 — Thread Pinning & Isolation
Inference is pinned to physical cores **2-5** (`isolcpus=2-5 nohz_full=2-5
rcu_nocbs=2-5`, container cpuset `2,3,4,5`, llama-server `-t 4`). Cores 0-1
belong to the OS and network stacks. Never schedule more than ONE inference
container concurrently on the appliance. Never lower hugepages below 512.

## Law 4 — Spindle Protection (markslone)
markslone runs on a 5400RPM HDD: zero daemon state writes. Use wgcf static
WireGuard configs (NEVER warp-cli — it writes state every 30s), volatile
journald (Storage=volatile, 100M cap), tmpfs for logs/run, BFQ elevator,
zram-zstd 50%, `ionice -c3` for compose operations, and NO logging rules in
nftables. Conntrack max 65536.

## Law 5 — Zero Public Exposure
No inbound port forwarding. No public reverse proxies (nginx/caddy/traefik)
on gateway hosts. Public hostnames resolve ONLY through Cloudflare
(tunnel CNAMEs, proxied) and sit behind CF Access (WebAuthn `swk`). No DNS
A/AAAA record may point at 192.168.x, 100.64/10, 172.16/12, or the ISP CGNAT
IP. Ollama binds loopback/tunnel-only — `OLLAMA_HOST=0.0.0.0` is a
reportable blindspot (probe 03 enforces).

## Law 6 — Budget & Model Policy
£5/month hard cap. LLM traffic flows through the Budget Sentinel worker ->
AI Gateway `acidwurx`. Only allowlisted free models may execute:
`@cf/meta/llama-3.2-1b-instruct`, `@cf/meta/llama-3.2-3b-instruct`,
`@cf/meta/llama-3-8b-instruct`, `@cf/mistral/mistral-7b-instruct-v0.1`,
`@cf/google/gemma-2-2b-it`, `@cf/qwen/qwen1.5-0.5b-chat`. Blocked: gpt-4*,
claude-3-opus/3.5*, o1/o3, gemini-1.5-pro, @cf/meta/llama-3.1-405b,
@cf/meta/llama-3-70b, @cf/mistral/mistral-large. KV spend key `spend:YYYY-MM`
(integer pence, cap 500).

## Law 7 — Validation Before Mutation
Every change passes the staged gate: `python3 scripts/ci/validate_repo.py .`
(lint) -> `pulumi preview` + `ansible-playbook --syntax-check`/`--check`
(simulation) -> wave1 read-only probes (live discovery) -> GitHub environment
`production-bare-metal` approval (human) -> apply. Discovery/dry-run stages
must remain strictly non-mutating.

## Law 8 — Idempotence & No Zip-Merge Drift
Scaffolding is engine-generated and idempotent; never hand-merge archives
(the historical netboot_1_1.yml duplication incident). Re-run
`generate_nexus_engine.py --force` instead. Ansible tasks must be idempotent
and survive reboots (systemd units enabled; NetworkManager dispatcher hook
`99-acidwurx-routing` re-applies policy routing on interface changes).

## Law 9 — Secrets
Env-hydrated only (see .env.example). sops+age for anything committed
(`*.enc.yaml`). Never echo tokens to logs, receipts, or terminal output —
fingerprints (sha256:16) only. NEXO_VAULT_KEY, WARP_PRIVATE_KEY, and
LITELLM_MASTER_KEY values found in historical exports are COMPROMISED —
rotate before first production run.

## Law 10 — Verification Honesty
Validation scripts must exit non-zero on real failure (the historical
"COMPLETE while failed" incident is prohibited): assert real probe output,
never print success unconditionally. Terminal-killing one-liners are banned;
long runs go through tmux or nohup with logged output.
