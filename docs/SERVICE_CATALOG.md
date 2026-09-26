# SERVICE_CATALOG.md — Launch Anything, Declaratively

The `platform/` directory is the service factory: one JSON profile per
launchable service, one stdlib launcher, hard-law enforcement baked in.
This is the "prepare for the things I don't know I need yet" mechanism —
a new service is a 30-line JSON file, not a bespoke deployment event.

## 60-second launch

```bash
./nexo.sh launch list                 # what exists + per-host budget
./nexo.sh launch render n8n           # compose + notes, NO deploy (inspect first)
./nexo.sh launch deploy n8n           # budget/port/law checks -> compose up -> receipt
./nexo.sh status                      # health of everything catalog-deployed
```

## Adding YOUR service (5 minutes)

1. `cp platform/profiles/_template.json platform/profiles/myservice.json`
2. Fill: image, ports, mem_limit_mb, env_names (**secret NAMES only** — values
   come from `.env` at deploy time, never from the profile), health_path,
   exposure, dns_gui_name, backup_paths, tags.
3. `./nexo.sh validate` (JSON gate) → `./nexo.sh launch render myservice` →
   review `platform/rendered/myservice.notes.md` → deploy.

## The laws the launcher enforces (refusal = exit 2, with reason)

| Law | Enforcement |
|---|---|
| Law 1 (container-free barryslone) | `legacy` group runtime=forbidden → ALL profiles refused |
| Law 1/3 (single inference container) | `compute` group runtime=podman-inference-only → docker profiles refused |
| 8GB ceiling (markslone) | `catalog_budget_mb: 4096` — sum of deployed profiles' mem_limit_mb must fit; cockpit's fixed caps (1792MB) are reserved on top |
| Law 4 (spindle) | every compose invocation wrapped in `ionice -c3` |
| Law 5 (zero exposure) | default exposure=mesh; `tunnel` exposure requires an explicit hostname and renders an Access-gated ingress note (add to infra/pulumi/index.ts + cloudflare/config.yml) |
| Law 9 (secrets) | profiles carry env NAMES; values hydrated from `.env`; compose fails closed with `${VAR:?...}` when a secret is missing |
| Port collisions | pre-deploy collision check against docs/ARCHITECTURE.md §2 allocations (local socket probe or BatchMode ssh `ss`) |

## Shipped profiles (from the operational archive's own service catalog)

| id | port | MB | why it exists |
|---|---|---|---|
| n8n | 5678 | 512 | automation hub (archive catalog) |
| jellyfin | 8096 | 1024 | media (archive tunnel plan) |
| uptime-kuma | 3002 | 256 | monitoring for every fleet service; 3001 is AdGuard's |
| netbox | 8071 | 768+256 | DCIM/IPAM truth store (archive discovery provider); seed from probe 02 |
| semaphore | 3010 | 384 | Ansible web runner with audit (archive catalog); 3000 is Open WebUI's |
| esphome | 6052 | 512 | firmware workbench for probe 02's Espressif OUI targets |

Rendered artifacts live in `platform/rendered/` (gitignored): compose files,
notes (AdGuard rewrite line, tunnel hint, backup paths, required secrets),
and `*.deploy.json` receipts consumed by `status` and the budget ledger.

## Integration touchpoints (automatic)

- **DNS:** notes file prints the exact AdGuard rewrite (`||<name>.gui^$dnsrewrite=<host>`).
- **Backups:** `backup_paths` are consumed by `fleet_backup.sh`/restic planning.
- **Discovery:** probe 02 fingerprints catalog ports (5678/8096/3002/8071/3010/6052) on sweeps.
- **Telemetry:** deployed receipts are plain JSON — Stage-4b pushes them to D1
  (cost_governance_ledger rows via notes, mcp_server_registry unaffected).
