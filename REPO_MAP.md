# AcidWurx Nexus Repository Map

_Auto-generated on 2026-09-26T15:49:35Z from commit c15398c7fe188ebae2eb0da70b05eaab8ecfa541._

```text
.
├── AI_README.md
├── LICENSE
├── README.md
├── REPO_MAP.md
├── docs
│   ├── ARCHITECTURE.md
│   ├── PIPELINE.md
│   ├── discovery
│   │   └── wave1
│   ├── interop
│   │   └── ZAI_HANDOFF_SCHEMA.md
│   └── tasks
│       ├── TASK_BOARD.md
│       └── mcp_task_contract.md
├── infra
│   ├── ansible
│   │   ├── ansible.cfg
│   │   ├── files
│   │   │   ├── acidwurx-interfaces.nft
│   │   │   ├── acidwurx-setup-routing.sh
│   │   │   ├── cockpit-compose.yml
│   │   │   ├── custom-menu.ipxe
│   │   │   ├── litellm-config.yaml
│   │   │   ├── mesh-containment.nft
│   │   │   ├── netboot-compose.yml
│   │   │   ├── searxng-settings.yml
│   │   │   ├── wgcf-down.sh
│   │   │   ├── wgcf-up.sh
│   │   │   └── wol_listener.py
│   │   ├── group_vars
│   │   │   └── all.yml
│   │   ├── inventory.ci.ini
│   │   ├── inventory.ini
│   │   └── playbook.yml
│   ├── cloudflare
│   │   ├── budget-sentinel
│   │   │   ├── src
│   │   │   └── wrangler.toml
│   │   ├── config.yml
│   │   ├── d1
│   │   │   └── schema.sql
│   │   ├── telemetry-ingest
│   │   │   ├── worker.js
│   │   │   └── wrangler.toml
│   │   ├── worker.js
│   │   └── wrangler.toml
│   ├── netbootxyz
│   │   ├── assets
│   │   │   └── preseed.cfg
│   │   ├── custom-menu.ipxe
│   │   ├── docker-compose.yml
│   │   └── openwrt-uci.md
│   ├── nftables
│   │   ├── acidwurx-interfaces.nft
│   │   └── mesh-containment.nft
│   └── pulumi
│       ├── Pulumi.yaml
│       ├── index.ts
│       ├── package.json
│       └── tsconfig.json
├── scripts
│   ├── ci
│   │   └── validate_repo.py
│   ├── wave1_discovery
│   │   ├── 00_master_orchestrator.sh
│   │   ├── 01_cf_edge_ai_audit.py
│   │   ├── 02_lan_iot_firmware_sweep.sh
│   │   ├── 03_hw_security_blindspots.sh
│   │   ├── 04_github_ai_consolidation.py
│   │   └── 05_local_ai_mcp_audit.sh
│   └── wave2_deployment
│       ├── bootstrap.sh
│       ├── create_ai_gateway.sh
│       ├── deploy_budget_sentinel.sh
│       ├── deploy_telemetry_ingest.sh
│       └── validation_trace.sh
└── secrets
```
