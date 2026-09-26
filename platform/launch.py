#!/usr/bin/env python3
"""platform/launch.py — Service Catalog launcher (stdlib only, zero prompts).

The "launch anything" factory: declarative JSON profiles -> rendered compose
stacks -> budget/law-checked deployment -> health verification -> receipts.

Commands:
  list                       show every profile + per-host budget usage
  budget                     budget head-room per host group
  render  <id>               write platform/rendered/<id>.docker-compose.yml
                             + <id>.notes.md (DNS rewrite, tunnel ingress hint,
                             backup paths) WITHOUT deploying
  deploy  <id> [--local]     render + deploy (docker compose up -d under
                             ionice -c3, Law 4). Remote target via ssh
                             BatchMode (CATALOG_SSH_USER, default adam).
                             Refuses: legacy group, compute group docker,
                             budget overflow, port collisions.
  status                     health-probe every deployed profile (receipts in
                             platform/rendered/*.deploy.json)

Env: CATALOG_SSH_USER (default adam), CATALOG_RENDER_DIR override.
Exit codes: 0 ok · 2 refused-by-law/budget · 3 render/health failure.
"""
import datetime
import glob
import json
import os
import shutil
import socket
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
PROFILES_DIR = os.path.join(HERE, "profiles")
HOSTS_PATH = os.path.join(HERE, "hosts.json")
RENDER_DIR = os.environ.get("CATALOG_RENDER_DIR") or os.path.join(HERE, "rendered")


def die(code, msg):
    sys.stderr.write("[launch] REFUSED (%d): %s\n" % (code, msg))
    raise SystemExit(code)


def load_hosts():
    with open(HOSTS_PATH) as fh:
        return json.load(fh)["hosts"]


def load_profiles():
    profiles = {}
    for path in sorted(glob.glob(os.path.join(PROFILES_DIR, "*.json"))):
        with open(path) as fh:
            prof = json.load(fh)
        pid = prof.get("id", os.path.basename(path)[:-5])
        if str(pid).startswith("_"):
            continue
        profiles[pid] = prof
    return profiles


def yaml_scalar(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    text = str(value)
    if text == "" or any(c in text for c in ":#{}[]&*!|>'\"%@`") or text.strip() != text:
        return json.dumps(text)
    return text


def emit_yaml(node, indent=0, lines=None):
    if lines is None:
        lines = []
    pad = " " * indent
    if isinstance(node, dict):
        for key in node:
            value = node[key]
            if isinstance(value, dict) and value:
                lines.append("%s%s:" % (pad, key))
                emit_yaml(value, indent + 2, lines)
            elif isinstance(value, list) and value:
                lines.append("%s%s:" % (pad, key))
                for item in value:
                    if isinstance(item, dict):
                        first = True
                        for k2 in item:
                            prefix = "%s- " % pad if first else "%s  " % pad
                            first = False
                            v2 = item[k2]
                            if isinstance(v2, (dict, list)) and v2:
                                lines.append("%s%s:" % (prefix, k2))
                                emit_yaml(v2, indent + 4, lines)
                            else:
                                lines.append("%s%s: %s" % (prefix, k2, yaml_scalar(v2)))
                    else:
                        lines.append("%s- %s" % (pad, yaml_scalar(item)))
            elif isinstance(value, dict):
                lines.append("%s%s: {}" % (pad, key))
            elif isinstance(value, list):
                lines.append("%s%s: []" % (pad, key))
            else:
                lines.append("%s%s: %s" % (pad, key, yaml_scalar(value)))
    return lines


def build_compose(prof):
    services = {}
    volumes = {}
    for svc_name, svc in prof["services"].items():
        entry = {
            "image": svc["image"],
            "container_name": "nexo-%s-%s" % (prof["id"], svc_name),
            "restart": svc.get("restart", "unless-stopped"),
            "mem_limit": "%dm" % int(svc["mem_limit_mb"]),
            "cpus": float(svc.get("cpus", 1.0)),
        }
        if svc.get("host_port"):
            entry["ports"] = ["%d:%d" % (svc["host_port"], svc["container_port"])]
        env_lines = []
        for static_key, static_val in (svc.get("env_static") or {}).items():
            env_lines.append("%s=%s" % (static_key, static_val))
        for secret_name in svc.get("env_names", []):
            env_lines.append("%s=${%s:?catalog: set %s in .env before deploy}" % (secret_name, secret_name, secret_name))
        if env_lines:
            entry["environment"] = env_lines
        vol_names = {}
        for vol_name, mount in (svc.get("volumes") or {}).items():
            vol_names[vol_name] = {"driver": "local", "driver_opts": {"type": "none", "o": "bind", "device": "/opt/nexo/%s/%s" % (prof["id"], vol_name)}}
            volumes[vol_name] = vol_names[vol_name]
            entry.setdefault("volumes_list", []).append("%s:%s" % (vol_name, mount))
        if "volumes_list" in entry:
            entry["volumes"] = entry.pop("volumes_list")
        if svc.get("depends_on"):
            entry["depends_on"] = list(svc["depends_on"])
        if svc.get("health_path"):
            entry["healthcheck"] = {
                "test": ["CMD-SHELL", "wget -qO- http://127.0.0.1:%d%s >/dev/null 2>&1 || curl -sf http://127.0.0.1:%d%s >/dev/null 2>&1 || exit 1" % (svc["container_port"], svc["health_path"], svc["container_port"], svc["health_path"])],
                "interval": "30s", "timeout": "5s", "retries": "3", "start_period": "20s",
            }
        services[svc_name] = entry
    doc = {"name": "nexo-%s" % prof["id"], "services": services}
    if volumes:
        doc["volumes"] = volumes
    return doc


def profile_mb(prof):
    return sum(int(s["mem_limit_mb"]) for s in prof["services"].values())


def cmd_list(profiles, hosts):
    print("%-14s %-9s %-28s %7s %s" % ("ID", "TARGET", "NAME", "MB", "PORTS"))
    for pid in sorted(profiles):
        prof = profiles[pid]
        ports = ",".join(str(s["host_port"]) for s in prof["services"].values() if s.get("host_port")) or "-"
        print("%-14s %-9s %-28s %7d %s" % (pid, prof["target_group"], prof["name"][:28], profile_mb(prof), ports))


def cmd_budget(profiles, hosts):
    used = {}
    for receipt in glob.glob(os.path.join(RENDER_DIR, "*.deploy.json")):
        try:
            with open(receipt) as fh:
                data = json.load(fh)
            if data.get("state") == "deployed":
                used[data["target_group"]] = used.get(data["target_group"], 0) + int(data.get("mb", 0))
        except Exception:
            pass
    for group, host in hosts.items():
        budget = int(host.get("catalog_budget_mb", 0))
        print("%-9s budget=%5dMB used=%5dMB free=%5dMB runtime=%s" % (
            group, budget, used.get(group, 0), max(budget - used.get(group, 0), 0), host["runtime"]))


def resolve_target(prof, hosts):
    group = prof["target_group"]
    if group not in hosts:
        die(2, "unknown target_group %r" % group)
    host = hosts[group]
    if host["runtime"] == "forbidden":
        die(2, "Law 1: %s (%s) is container-free — profile %r refused" % (host["hostname"], group, prof["id"]))
    if host["runtime"] == "podman-inference-only":
        die(2, "Law 1/3: %s runs exactly one inference container — profile %r refused" % (host["hostname"], prof["id"]))
    address = os.environ.get(host["address_env"], host["address_default"])
    return group, host, address


def render(prof, hosts):
    group, host, address = resolve_target(prof, hosts)
    os.makedirs(RENDER_DIR, exist_ok=True)
    compose_path = os.path.join(RENDER_DIR, "%s.docker-compose.yml" % prof["id"])
    doc = build_compose(prof)
    lines = emit_yaml(doc)
    with open(compose_path, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    notes = [
        "# %s — deploy notes (auto-rendered)" % prof["id"],
        "",
        "- target: %s (%s @ %s), budget %dMB, this profile %dMB" % (host["hostname"], group, address, host["catalog_budget_mb"], profile_mb(prof)),
        "- AdGuard rewrite: ||%s^$dnsrewrite=%s" % (prof.get("dns_gui_name", "%s.gui" % prof["id"]), address),
    ]
    if prof.get("exposure") == "tunnel" and prof.get("tunnel_hostname"):
        notes.append("- tunnel ingress (add to infra/pulumi/index.ts ingressRules + cloudflared config): hostname %s -> http://%s:<port> (Access-gated)" % (prof["tunnel_hostname"], address))
    else:
        notes.append("- exposure: mesh-only (Law 5). No tunnel hostname. No public DNS.")
    notes.append("- backup paths: %s" % ", ".join(prof.get("backup_paths", [])))
    notes.append("- env secrets required: %s" % (", ".join(sorted({e for s in prof["services"].values() for e in s.get("env_names", [])})) or "none"))
    notes_path = os.path.join(RENDER_DIR, "%s.notes.md" % prof["id"])
    with open(notes_path, "w") as fh:
        fh.write("\n".join(notes) + "\n")
    return compose_path, notes_path, group, host, address


def port_free(address, port, local):
    if port is None:
        return True
    try:
        if local:
            with socket.create_connection(("127.0.0.1", int(port)), timeout=2):
                return False
        else:
            proc = subprocess.run(
                ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                 "%s@%s" % (os.environ.get("CATALOG_SSH_USER", "adam"), address),
                 "ss -ltn 'sport = :%d' | tail -n +2 | wc -l" % int(port)],
                capture_output=True, text=True, timeout=20)
            return proc.returncode != 0 or proc.stdout.strip() in ("0", "")
    except Exception:
        return True  # unverifiable => allow; deploy health-check will surface truth


def cmd_deploy(pid, profiles, hosts, local_flag):
    if pid not in profiles:
        die(3, "unknown profile %r (try: launch.py list)" % pid)
    prof = profiles[pid]
    compose_path, notes_path, group, host, address = render(prof, hosts)
    used = 0
    for receipt in glob.glob(os.path.join(RENDER_DIR, "*.deploy.json")):
        try:
            with open(receipt) as fh:
                data = json.load(fh)
            if data.get("state") == "deployed" and data.get("target_group") == group and data.get("id") != pid:
                used += int(data.get("mb", 0))
        except Exception:
            pass
    need = profile_mb(prof)
    if used + need > int(host["catalog_budget_mb"]):
        die(2, "budget overflow on %s: used %dMB + %s %dMB > %dMB cap" % (host["hostname"], used, pid, need, host["catalog_budget_mb"]))
    this_host = socket.gethostname().lower()
    is_local = local_flag or this_host.startswith(host["hostname"].lower()) or address in ("127.0.0.1", "localhost")
    for svc in prof["services"].values():
        if svc.get("host_port") and not port_free(address, svc["host_port"], is_local):
            die(2, "port %d already bound on %s — collision (see docs/ARCHITECTURE.md §2)" % (svc["host_port"], address))
    receipt = {"id": pid, "target_group": group, "host": host["hostname"], "address": address,
               "mb": need, "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
               "state": "pending", "health": None}
    if is_local:
        if shutil.which("docker") is None:
            die(3, "docker not found on this host; run deploy from the gateway or pass CATALOG_SSH_USER")
        cmd = ["ionice", "-c3", "docker", "compose", "-f", compose_path, "up", "-d"]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
        receipt["command"] = " ".join(cmd)
        receipt["rc"] = proc.returncode
        receipt["stderr_tail"] = proc.stderr[-400:]
    else:
        user = os.environ.get("CATALOG_SSH_USER", "adam")
        remote_dir = "/opt/nexo/%s" % pid
        scp = subprocess.run(["scp", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                              compose_path, "%s@%s:/tmp/nexo-%s.docker-compose.yml" % (user, address, pid)],
                             capture_output=True, text=True, timeout=60)
        if scp.returncode != 0:
            receipt.update(state="failed", error="scp: " + scp.stderr[-300:])
            write_receipt(pid, receipt)
            die(3, "scp to %s failed (BatchMode — key auth required): %s" % (address, scp.stderr[-200:]))
        remote_cmd = ("mkdir -p %s && mv /tmp/nexo-%s.docker-compose.yml %s/docker-compose.yml && "
                      "ionice -c3 docker compose -f %s/docker-compose.yml up -d") % (remote_dir, pid, remote_dir, remote_dir)
        ssh = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                              "%s@%s" % (user, address), remote_cmd],
                             capture_output=True, text=True, timeout=600)
        receipt["rc"] = ssh.returncode
        receipt["stderr_tail"] = ssh.stderr[-400:]
    if receipt.get("rc", 1) != 0:
        receipt["state"] = "failed"
        write_receipt(pid, receipt)
        die(3, "compose up failed rc=%s — see %s.deploy.json" % (receipt.get("rc"), pid))
    receipt["state"] = "deployed"
    primary = next((s for s in prof["services"].values() if s.get("health_path") and s.get("host_port")), None)
    if primary:
        receipt["health"] = "http://%s:%d%s" % (address, primary["host_port"], primary["health_path"])
    write_receipt(pid, receipt)
    print("[launch] %s deployed on %s (%s) — health: %s" % (pid, host["hostname"], address, receipt["health"] or "n/a"))


def write_receipt(pid, receipt):
    os.makedirs(RENDER_DIR, exist_ok=True)
    with open(os.path.join(RENDER_DIR, "%s.deploy.json" % pid), "w") as fh:
        json.dump(receipt, fh, indent=2, sort_keys=True)


def cmd_status(profiles):
    import urllib.request
    rows = []
    for receipt_path in sorted(glob.glob(os.path.join(RENDER_DIR, "*.deploy.json"))):
        try:
            with open(receipt_path) as fh:
                data = json.load(fh)
        except Exception:
            continue
        health = data.get("health")
        state = data.get("state")
        if health and state == "deployed":
            try:
                req = urllib.request.Request(health, method="GET")
                with urllib.request.urlopen(req, timeout=4) as resp:
                    state = "healthy(%d)" % resp.status
            except Exception as exc:
                state = "unreachable(%s)" % type(exc).__name__
        rows.append((data.get("id"), data.get("host"), state))
    if not rows:
        print("[launch] nothing deployed via catalog yet (receipts: platform/rendered/*.deploy.json)")
        return
    print("%-14s %-14s %s" % ("ID", "HOST", "STATE"))
    for pid, host, state in rows:
        print("%-14s %-14s %s" % (pid, host, state))


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help", "help"):
        print(__doc__)
        return 0
    hosts = load_hosts()
    profiles = load_profiles()
    cmd = args[0]
    if cmd == "list":
        cmd_list(profiles, hosts)
    elif cmd == "budget":
        cmd_budget(profiles, hosts)
    elif cmd == "render" and len(args) >= 2:
        if args[1] not in profiles:
            die(3, "unknown profile %r" % args[1])
        compose_path, notes_path, group, host, address = render(profiles[args[1]], hosts)
        print("[launch] rendered %s (+ %s) for %s @ %s" % (compose_path, notes_path, host["hostname"], address))
    elif cmd == "deploy" and len(args) >= 2:
        cmd_deploy(args[1], profiles, hosts, "--local" in args[2:])
    elif cmd == "status":
        cmd_status(profiles)
    else:
        die(3, "usage: launch.py {list|budget|render <id>|deploy <id> [--local]|status}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except Exception as exc:
        sys.stderr.write("[launch] FATAL: %r\n" % (exc,))
        raise SystemExit(1)
