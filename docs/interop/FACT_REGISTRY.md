# FACT_REGISTRY.md — the canonical interface contract (facts_schema_version 1)

Every probe emits the SAME envelope; every consumer (remediation engine, D1
push, task board, briefing, launch budgets) reads ONLY these keys. Names are
append-only: a fact key, once published, is never renamed or retyped — new
facts get new keys. That is what makes the interfaces predictable.

## Envelope (all probes)

```json
{
  "probe": "NN_name",
  "ts": "ISO-8601",
  "node": "hostname",
  "status": "ok | degraded | skipped | error",
  "data": { },
  "errors": [ ]
}
```

`status=skipped` = missing credentials (zero-prompt law); `degraded` = ran but
partial (e.g., empty LAN); `error` = probe bug (rc!=0, orchestrator counts it).

## Fact types (remediation engine's input vocabulary)

| fact type | source | value | context keys |
|---|---|---|---|
| token_missing | 01/04 skipped | env var name | — |
| tool_missing | 12 | tool name | — |
| secret_hygiene_fail | 12 fail checks | check id | ctx_id, detail |
| rotation_todo | 12 rotate_* todo | checklist item | item, marker |
| blindspot_port | 03/05 | port int | rule |
| isp_leak | 03 | public ip | — |
| warp_off_gateway / warp_off_client | 03 | public ip | — |
| routing_missing | 03 (gateway) | true | — |
| thermal_high | 03 | max °C | — |
| dhcp_drift | 02 | note | ip |
| esp_target | 02 | ip | ip, mac |
| host_unreachable | 06 | node name | name, error |
| failed_units | 06 | count | count, list |
| isolcpus_inactive / hugepages_low | 06 (compute) | true / pages | — |
| dns_violation | 08 | count | count |
| gateway_dupes | 08 | csv ids | value |
| worker_burn | 08 | count | count |
| tunnel_route_missing | 08 | true | — |
| gov_gap | 09 | gap text | gap |
| disk_pressure | 10 | used% | mount, value |
| noatime_missing | 10 | count | count |
| smart_fail | 10 | device | device |
| nas_unreachable / restic_unconfigured | 10 | true | — |
| ollama_ctx_low / mcp_server_missing | 05 | true | — |

Unrouted facts fall to `R-UNKNOWN` (task dispatch) and are COUNTED — coverage
is reported as `routed/(routed+unrouted)`, target ≥95%, measured per wave by
`./nexo.sh remediate --coverage`. Never assumed.

## Per-probe data keys (stable surface)

- 01: zones[], tunnels[], workers[], worker_count, gateways[], kv_namespaces[], r2_buckets[], dns_violations[], token_valid
- 02: subnet, hosts_up[{ip,mac,vendor,fleet_role,services[]}], esp_firmware_staging_targets[], drift_alerts[]
- 03: cpu{}, ram{}, dimm_layout[], vulkan_devices[], thermals[], max_thermal_c, public_ip, cf_trace{}, isp_cgnat_leak, warp_on, listening_sockets[], blindspots[{port,address,rule}], routing_verification{}
- 04: repos_total, stale_repos, staleness_counts{}, consolidation_groups[], readmes_mapped, inventory[]
- 05: ollama_models[{name,num_ctx,...}], ollama_bind_exposed, context_bounds_ok, llama_server_health, fastmcp, mcp_sdk, mcp_configs[], mcp_processes[], task_board{}
- 06: nodes[{name,reachable,os,kernel,hostname_real,cores,mem_total_kb,pkg_manager,pkg_count,failed_units,failed_list[],docker_running,podman_running,isolcpus,hugepages,wol_armed,users_shell[],authorized_keys,listeners,thermal_max_c,disks[]}], nodes_reachable, nodes_unreachable[{name,error,route_hint}]
- 07: routers[{name,reachable,release,kernel,model,pkg_count,leases_count,option3_redirect,pxe_options_present,uci_files[]}], leases[{expires_epoch,mac,ip,hostname,router}]
- 08: zones_full[{zone,records[],record_count}], access_apps[{domain,policies[{swk_required}]}], zt_devices[], tunnels_full[{routes[],vnets[]}], gateways_full[], workers_detail[], kv[], r2[], pages[], records_total, dns_violations[], account_flags{worker_count,worker_burn_risk,gateway_duplicates,gateway_primary_present,dns_violation_count,sentinel_overlap,tunnel_private_routes}
- 09: owner, repos[{repo,exists,private,branch_protection{},environments[],approval_gate_present,secret_names[],missing_secrets[],recent_runs[],webhooks,labels[]}], governance_gaps[], governance_gaps_count
- 10: disks[{mount,used,avail_kb}], noatime_missing[], smart{dev:{health,temp_c}}, nas{reachable,spin_state}, restic{configured,snapshots,latest}
- 11: hosts_probed, services_probed, probes_total, matrix[{host,ip,service,port,state,http_status?}], findings[{rule,detail}]
- 12: checks[{id,status,detail}], checks_total, checks_failed

## Consumers

| consumer | reads |
|---|---|
| tools/remediation/engine.py | fact stream (above) → plan/executor/tasks |
| orchestrator Stage-4b push | 05 → mcp_server_registry; 01/08 → cost_governance_ledger |
| pack.py briefing | REPORT.md + selected keys per probe |
| platform/launch.py budget | 11 matrix (port collisions) |
| probe 07 leases | R-DHCP-DRIFT MAC substitution source |
