# AcidWurx Nexus Repository Map

_Auto-generated on 2026-09-26T19:45:06Z from commit 6135788794afad5f1787170f69efb0d67dcfcb2a._

```text
.
├── AI_README.md
├── LICENSE
├── README.md
├── REPO_MAP.md
├── docs
│   ├── ACCESS_APPLICATION.md
│   ├── ARCHITECTURE.md
│   ├── MCP_TASKS.md
│   ├── PIPELINE.md
│   ├── SERVICE_CATALOG.md
│   ├── TELEMETRY_SECURE_AREA.md
│   ├── discovery
│   │   └── wave1
│   ├── interop
│   │   ├── FACT_REGISTRY.md
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
├── nexo.sh
├── platform
│   ├── hosts.json
│   ├── launch.py
│   └── profiles
│       ├── _template.json
│       ├── esphome.json
│       ├── home-assistant.json
│       ├── jellyfin.json
│       ├── mosquitto.json
│       ├── n8n.json
│       ├── netbox.json
│       ├── semaphore.json
│       └── uptime-kuma.json
├── scripts
│   ├── ci
│   │   ├── public_audit.py
│   │   └── validate_repo.py
│   ├── wave1_discovery
│   │   ├── 00_master_orchestrator.sh
│   │   ├── 01_cf_edge_ai_audit.py
│   │   ├── 02_lan_iot_firmware_sweep.sh
│   │   ├── 03_hw_security_blindspots.sh
│   │   ├── 04_github_ai_consolidation.py
│   │   ├── 05_local_ai_mcp_audit.sh
│   │   ├── 06_fleet_ssh_inventory.sh
│   │   ├── 07_router_config_capture.sh
│   │   ├── 08_cloud_deep_audit.py
│   │   ├── 09_github_deep_audit.py
│   │   ├── 10_storage_health.sh
│   │   ├── 11_services_matrix.sh
│   │   └── 12_secrets_posture.sh
│   ├── wave2_deployment
│   │   ├── bootstrap.sh
│   │   ├── create_ai_gateway.sh
│   │   ├── deploy_budget_sentinel.sh
│   │   ├── deploy_telemetry_ingest.sh
│   │   ├── fleet_backup.sh
│   │   ├── install_cron.sh
│   │   ├── notify.sh
│   │   ├── telemetry_push.sh
│   │   └── validation_trace.sh
│   └── wave3_bulk
│       └── fleet_apply.sh
├── secrets
├── telemetry
│   └── PUSH_MANIFEST.json
└── tools
    ├── access
    │   └── request_access.py
    ├── mcp
    │   └── nexo_tasks_server.py
    ├── remediation
    │   ├── engine.py
    │   └── rules.json
    └── telemetry
        ├── PUSH_MANIFEST.json
        └── pack.py
```
