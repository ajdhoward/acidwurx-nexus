#!/usr/bin/env python3
"""tools/remediation/engine.py — the decision engine: wave facts -> routed plans.

Reads the latest (or --run-dir) wave results.json, extracts the canonical fact
stream (docs/interop/FACT_REGISTRY.md), matches tools/remediation/rules.json,
and emits THREE artifacts into the run directory:

  remediation_plan.md   human-readable, grouped AUTO-SAFE / GATED / HUMAN,
                        with an unrouted-findings appendix (coverage is
                        measured, never assumed)
  remediate.sh          executor for AUTO-SAFE routes only. DRY by default:
                        prints actions; APPLY=1 executes. set -euo pipefail,
                        idempotent steps, per-action verify commands.
  tasks (appended)      high/critical + all human-route findings become
                        docs/tasks/tasks.json rows (Stage-10 board; the MCP
                        server renders TASK_BOARD.md on next mutation)

Modes:
  engine.py [--run-dir D]            full evaluation + artifacts
  engine.py --facts-only [--run-dir D]   dump the extracted fact stream (JSON)
  engine.py --matrix [--run-dir D]   render the probe-11 service matrix table
  engine.py --coverage               print routed/unrouted coverage percentage
Exit codes: 0 ok · 1 no results.json · 2 rules.json unreadable.
"""
import argparse
import datetime
import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
RULES_PATH = os.path.join(HERE, "rules.json")


def latest_run_dir():
    candidates = sorted(glob.glob(os.path.join(REPO, "docs", "discovery", "wave1", "run-*")))
    return candidates[-1] if candidates else None


def load_results(run_dir):
    path = os.path.join(run_dir, "results.json")
    if not os.path.exists(path):
        sys.stderr.write("[remediate] FATAL: no results.json in %s — run ./nexo.sh wave1\n" % run_dir)
        raise SystemExit(1)
    with open(path) as fh:
        return json.load(fh)


def fact(f_type, value=None, node=None, **ctx):
    entry = {"type": f_type, "value": value, "node": node}
    entry.update(ctx)
    return entry


def extract_facts(results):
    facts = []
    run_node = results.get("node", "unknown")
    probes = {p.get("probe", ""): p for p in results.get("probes", [])}

    def data(prefix):
        for name, probe in probes.items():
            if name.startswith(prefix):
                return probe.get("data") or {}, probe.get("status")
        return {}, None

    d01, s01 = data("01")
    if s01 == "skipped":
        facts.append(fact("token_missing", "CF_API_TOKEN", run_node))
    d02, _ = data("02")
    for drift in d02.get("drift_alerts", []):
        facts.append(fact("dhcp_drift", drift.get("note"), run_node, ip=drift.get("ip")))
    for esp in d02.get("esp_firmware_staging_targets", []):
        facts.append(fact("esp_target", esp.get("ip"), run_node, ip=esp.get("ip"), mac=esp.get("mac")))
    d03, _ = data("03")
    for spot in d03.get("blindspots", []):
        facts.append(fact("blindspot_port", spot.get("port"), run_node, rule=spot.get("rule")))
    if d03.get("isp_cgnat_leak"):
        facts.append(fact("isp_leak", d03.get("public_ip"), run_node))
    if d03.get("warp_on") is False:
        kind = "warp_off_gateway" if "markslone" in str(run_node).lower() else "warp_off_client"
        facts.append(fact(kind, d03.get("public_ip"), run_node))
    routing = d03.get("routing_verification") or {}
    if routing.get("ip_rules_present") is False and "markslone" in str(run_node).lower():
        facts.append(fact("routing_missing", True, run_node))
    thermal = d03.get("max_thermal_c")
    if isinstance(thermal, (int, float)) and thermal > 80:
        facts.append(fact("thermal_high", thermal, run_node))
    d04, s04 = data("04")
    if s04 == "skipped":
        facts.append(fact("token_missing", "GITHUB_TOKEN", run_node))
    d05, _ = data("05")
    if d05.get("ollama_bind_exposed"):
        facts.append(fact("blindspot_port", 11434, run_node, rule="T-002 via probe 05"))
    if d05.get("context_bounds_ok") is False:
        facts.append(fact("ollama_ctx_low", True, run_node))
    if d05.get("fastmcp") in ("absent", None) and d05.get("mcp_processes") == []:
        facts.append(fact("mcp_server_missing", True, run_node))
    d06, _ = data("06")
    for unreach in d06.get("nodes_unreachable", []):
        facts.append(fact("host_unreachable", unreach.get("name"), run_node,
                          name=unreach.get("name"), ip=unreach.get("ip") or "192.168.1.x"))
    for node_entry in d06.get("nodes", []):
        nname = node_entry.get("name", "?")
        if node_entry.get("failed_units"):
            facts.append(fact("failed_units", node_entry["failed_units"], nname,
                              count=node_entry["failed_units"], list=",".join(node_entry.get("failed_list", [])[:4])))
        if nname.startswith("jessica"):
            if str(node_entry.get("isolcpus", "none")) in ("none", "", "None"):
                facts.append(fact("isolcpus_inactive", True, nname))
            hp = str(node_entry.get("hugepages", ""))
            if hp.isdigit() and int(hp) < 512:
                facts.append(fact("hugepages_low", int(hp), nname))
    d08, _ = data("08")
    flags08 = d08.get("account_flags") or {}
    if flags08.get("dns_violation_count"):
        facts.append(fact("dns_violation", flags08["dns_violation_count"], "cloudflare",
                          count=flags08["dns_violation_count"]))
    if flags08.get("gateway_duplicates"):
        facts.append(fact("gateway_dupes", ",".join(flags08["gateway_duplicates"]), "cloudflare"))
    if flags08.get("worker_burn_risk"):
        facts.append(fact("worker_burn", flags08.get("worker_count"), "cloudflare",
                          count=flags08.get("worker_count")))
    if d08 and "192.168.1.0/24" not in (flags08.get("tunnel_private_routes") or []):
        facts.append(fact("tunnel_route_missing", True, "cloudflare"))
    d09, _ = data("09")
    for gap in d09.get("governance_gaps", []):
        facts.append(fact("gov_gap", gap, "github", gap=gap))
    d10, _ = data("10")
    for disk in d10.get("disks", []):
        used = str(disk.get("used", "")).rstrip("%")
        if used.isdigit() and int(used) >= 85:
            facts.append(fact("disk_pressure", disk.get("used"), run_node, mount=disk.get("mount")))
    if d10.get("noatime_missing"):
        facts.append(fact("noatime_missing", len(d10["noatime_missing"]), run_node, count=len(d10["noatime_missing"])))
    for device, smart in (d10.get("smart") or {}).items():
        if smart.get("health") == "FAILED":
            facts.append(fact("smart_fail", device, run_node, device=device))
    nas = d10.get("nas") or {}
    if nas and nas.get("reachable") is False:
        facts.append(fact("nas_unreachable", True, "barryslone"))
    restic = d10.get("restic") or {}
    if restic and restic.get("configured") is False:
        facts.append(fact("restic_unconfigured", True, run_node))
    d12, _ = data("12")
    for check in d12.get("checks", []):
        if check.get("status") == "fail":
            facts.append(fact("secret_hygiene_fail", check.get("id"), run_node, ctx_id=check.get("id"), detail=check.get("detail")))
        if check.get("status") == "todo" and str(check.get("id", "")).startswith("rotation_"):
            facts.append(fact("rotation_todo", check.get("detail"), run_node,
                              item=check.get("detail", "").split(" [")[0], marker=str(check.get("id", "")).upper()))
        if check.get("status") == "missing" and str(check.get("id", "")).startswith("tool_"):
            facts.append(fact("tool_missing", str(check.get("id"))[5:], run_node))
    return facts


def rule_matches(rule, f):
    when = rule.get("when", {})
    if when.get("type") == "always":
        return True
    if when.get("type") != f.get("type"):
        return False
    if "value" in when and str(when["value"]) != str(f.get("value")):
        return False
    if "ctx_id" in when and when["ctx_id"] != f.get("ctx_id"):
        return False
    if "contains" in when and when["contains"] not in str(f.get("value", "")) + str(f.get("gap", "")):
        return False
    return True


def interpolate(text, f):
    out = str(text)
    for key in ("node", "value", "count", "name", "ip", "mac", "mount", "device", "item", "marker", "gap", "list", "detail"):
        out = out.replace("{%s}" % key, str(f.get(key, f.get("node", "")) if key == "node" else f.get(key, "{%s}" % key)))
    return out


def evaluate(facts, rules_doc):
    routed, unrouted = [], []
    once_seen = set()
    for f in facts:
        matched = None
        for rule in rules_doc.get("rules", []):
            if rule.get("when", {}).get("once") and rule["id"] in once_seen:
                continue
            if rule_matches(rule, f):
                matched = rule
                if rule.get("when", {}).get("once"):
                    once_seen.add(rule["id"])
                break
        if matched:
            routed.append({"rule": matched, "fact": f})
        else:
            unrouted.append(f)
    # 'always' rules fire once even with zero matching facts
    for rule in rules_doc.get("rules", []):
        if rule.get("when", {}).get("type") == "always" and rule["id"] not in once_seen:
            once_seen.add(rule["id"])
            routed.append({"rule": rule, "fact": fact("always", True, "local")})
    return routed, unrouted


def dedupe(routed):
    seen, out = set(), []
    for item in routed:
        key = (item["rule"]["id"], json.dumps(item["fact"], sort_keys=True, default=str))
        if key in seen:
            continue
        seen.add(key)
        out.append(item)
    return out


def write_plan(run_dir, routed, unrouted, facts):
    groups = {"auto-safe": [], "gated": [], "human": []}
    for item in routed:
        groups.setdefault(item["rule"].get("risk", "human"), []).append(item)
    lines = ["# Remediation Plan — %s" % datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
             "", "Facts extracted: %d | routed entries: %d | unrouted: %d | coverage: %.0f%%" % (
                 len(facts), len(routed), len(unrouted),
                 (100.0 * (len(facts) - len(unrouted)) / len(facts)) if facts else 100.0), ""]
    for risk in ("auto-safe", "gated", "human"):
        lines.append("## %s (%d)" % (risk.upper(), len(groups[risk])))
        for item in groups[risk]:
            rule, f = item["rule"], item["fact"]
            lines.append("")
            lines.append("### [%s] %s" % (rule["id"], interpolate(rule["title"], f)))
            lines.append("- severity: %s | target: %s" % (rule.get("severity", "?"), interpolate(rule.get("target", "?"), f)))
            if rule.get("notes"):
                lines.append("- notes: %s" % interpolate(rule["notes"], f))
            lines.append("- steps:")
            for step in rule.get("steps", []):
                lines.append("  ```bash")
                lines.append("  %s" % interpolate(step, f))
                lines.append("  ```")
            if rule.get("verify"):
                lines.append("- verify: `%s`" % interpolate(rule["verify"], f))
        lines.append("")
    if unrouted:
        lines.append("## UNROUTED FINDINGS (extend rules.json to cover these)")
        for f in unrouted:
            lines.append("- %s=%s (node %s)" % (f.get("type"), f.get("value"), f.get("node")))
    path = os.path.join(run_dir, "remediation_plan.md")
    with open(path, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    return path


def write_executor(run_dir, routed):
    auto = [item for item in routed if item["rule"].get("risk") == "auto-safe"]
    seen_rules = set()
    lines = ["#!/usr/bin/env bash",
             "# AUTO-GENERATED by tools/remediation/engine.py — AUTO-SAFE routes only.",
             "# Dry by default: prints actions. APPLY=1 executes. Idempotent by construction.",
             "set -euo pipefail",
             'REPO="%s"' % REPO,
             'APPLY="${APPLY:-0}"',
             'echo "AUTO-SAFE remediation: %d action(s), APPLY=${APPLY}"' % len(auto)]
    calls = []
    for item in auto:
        rule, f = item["rule"], item["fact"]
        if rule["id"] in seen_rules:
            continue
        seen_rules.add(rule["id"])
        fname = "action_%s" % re.sub(r"[^A-Za-z0-9]", "_", rule["id"])
        title = interpolate(rule["title"], f).replace('"', "'").replace("`", "'")
        lines.append("")
        lines.append("%s() {" % fname)
        lines.append('  echo "[remediate:%s] %s"' % (rule["id"], title))
        lines.append('  if [ "${APPLY}" != "1" ]; then echo "  (dry - set APPLY=1 to execute)"; return 0; fi')
        for step in rule.get("steps", []):
            lines.append("  %s" % interpolate(step, f))
        if rule.get("verify"):
            lines.append('  if %s >/dev/null 2>&1; then echo "  verify: PASS"; else echo "  verify: CHECK MANUALLY"; fi' % interpolate(rule["verify"], f))
        lines.append("}")
        calls.append(fname)
    if not calls:
        lines.append("")
        lines.append('echo "nothing auto-safe routed this wave"')
    lines.append("")
    for fname in calls:
        lines.append("%s" % fname)
    lines.append('echo "[remediate] done (APPLY=${APPLY})"')
    lines.append('if [ "${APPLY}" = "1" ] && [ -x "$REPO/scripts/wave2_deployment/notify.sh" ]; then')
    lines.append('  bash "$REPO/scripts/wave2_deployment/notify.sh" "nexo remediate" "auto-safe actions executed on $(uname -n)" 3 "wrench" || true')
    lines.append('fi')
    path = os.path.join(run_dir, "remediate.sh")
    with open(path, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    os.chmod(path, 0o755)
    return path


def seed_tasks(routed, unrouted, facts):
    tasks_path = os.path.join(REPO, "docs", "tasks", "tasks.json")
    tasks = []
    if os.path.exists(tasks_path):
        try:
            with open(tasks_path) as fh:
                tasks = json.load(fh).get("tasks", [])
        except Exception:
            tasks = []
    existing = {(t.get("title"), t.get("target")) for t in tasks}
    now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    next_id = max([int(str(t.get("id", "T-0")).replace("T-", "") or 0) for t in tasks] + [200])
    added = 0
    candidates = [item for item in routed
                  if item["rule"].get("severity") in ("high", "critical") or item["rule"].get("risk") == "human"]
    for f in unrouted:
        candidates.append({"rule": {"id": "R-UNKNOWN", "risk": "human", "severity": "medium",
                                    "title": "Unrouted finding: {type}={value} — triage + extend rules.json",
                                    "steps": []}, "fact": f})
    for item in candidates:
        rule, f = item["rule"], item["fact"]
        title = "[%s] %s" % (rule["id"], interpolate(rule["title"], f))[:160]
        target = interpolate(rule.get("target", "?"), f)
        if (title, target) in existing:
            continue
        next_id += 1
        added += 1
        tasks.append({"id": "T-%03d" % next_id, "title": title, "target": target,
                      "agent": None, "state": "backlog", "evidence": rule["id"],
                      "created": now, "updated": now})
    if added:
        os.makedirs(os.path.dirname(tasks_path), exist_ok=True)
        with open(tasks_path, "w") as fh:
            json.dump({"tasks": tasks, "updated": now}, fh, indent=2)
    return added


def render_matrix(run_dir):
    path = os.path.join(run_dir, "11_services_matrix_result.json")
    if not os.path.exists(path):
        print("no probe-11 results in %s" % run_dir)
        return
    with open(path) as fh:
        d = json.load(fh).get("data", {})
    rows = d.get("matrix", [])
    hosts = sorted({r["host"] for r in rows})
    services = sorted({r["service"] for r in rows})
    print("%-16s %s" % ("service", " ".join("%-15s" % h for h in hosts)))
    for svc in services:
        cells = []
        for h in hosts:
            hit = next((r for r in rows if r["service"] == svc and r["host"] == h), None)
            cells.append("%-15s" % ((":%d" % hit.get("http_status")) if hit and hit.get("http_status") else ("open" if hit else ".")))
        print("%-16s %s" % (svc, " ".join(cells)))
    for f in d.get("findings", []):
        print("FINDING [%s] %s" % (f.get("rule"), f.get("detail")))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-dir", default=None)
    ap.add_argument("--facts-only", action="store_true")
    ap.add_argument("--matrix", action="store_true")
    ap.add_argument("--coverage", action="store_true")
    args = ap.parse_args()

    run_dir = args.run_dir or latest_run_dir()
    if not run_dir:
        sys.stderr.write("[remediate] no wave run found — ./nexo.sh wave1 first\n")
        return 1
    if args.matrix:
        render_matrix(run_dir)
        return 0
    results = load_results(run_dir)
    facts = extract_facts(results)
    if args.facts_only:
        json.dump(facts, sys.stdout, indent=2, default=str)
        print()
        return 0
    try:
        with open(RULES_PATH) as fh:
            rules_doc = json.load(fh)
    except Exception as exc:
        sys.stderr.write("[remediate] FATAL: rules.json unreadable: %r\n" % (exc,))
        return 2
    routed, unrouted = evaluate(facts, rules_doc)
    routed = dedupe(routed)
    if args.coverage:
        routed_facts = len(facts) - len(unrouted)
        total = len(facts) or 1
        print("facts=%d routed=%d unrouted=%d coverage=%.1f%%" % (
            len(facts), routed_facts, len(unrouted), 100.0 * routed_facts / total))
        return 0
    plan = write_plan(run_dir, routed, unrouted, facts)
    executor = write_executor(run_dir, routed)
    added = seed_tasks(routed, unrouted, facts)
    routed_facts = len(facts) - len(unrouted)
    coverage = (100.0 * routed_facts / len(facts)) if facts else 100.0
    print("[remediate] facts=%d routed=%d unrouted=%d coverage=%.0f%%" % (len(facts), routed_facts, len(unrouted), coverage))
    print("[remediate] plan: %s" % plan)
    print("[remediate] executor: %s (dry by default; APPLY=1 to execute auto-safe routes)" % executor)
    print("[remediate] task board: +%d row(s)" % added)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except Exception as exc:
        sys.stderr.write("[remediate] FATAL: %r\n" % (exc,))
        raise SystemExit(1)
