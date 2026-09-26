#!/usr/bin/env python3
"""tools/telemetry/pack.py — classifier / redactor / encryptor for the secure
telemetry area. Turns a wave-run directory into a pushable, classified bundle:

  <out>/<node>/<run_id>/
    INDEX.json        (plaintext metadata: statuses, sha256s, flags)
    BRIEFING.md       (plaintext, secret-scrubbed, AI-ingestible)
    enc/raw.tar.gz.*  (encrypted full artifacts; backend chain:
                       age -> sops -> openssl aes-256-cbc-pbkdf2 -> REFUSE)

Usage:
  pack.py --run-dir <dir> --out <staging> [--manifest <path>] [--brief-only]
Env:
  NEXO_AGE_RECIPIENT     age1... public key (preferred backend; else parsed
                         from the repo .sops.yaml)
  NEXO_TELEMETRY_PASSPHRASE  openssl fallback passphrase
  NEXO_NODE_NAME         node label override
Exit codes: 0 ok · 2 refused (no encryption backend for class raw).
"""
import argparse
import datetime
import fnmatch
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

SECRET_SHAPES = [
    re.compile(r"\bghp_[A-Za-z0-9]{20,}\b"),
    re.compile(r"\bgho_[A-Za-z0-9]{20,}\b"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b"),
    re.compile(r"\bcfut_[A-Za-z0-9_\-]{20,}\b"),
    re.compile(r"\bcfat_[A-Za-z0-9_\-]{20,}\b"),
    re.compile(r"\bsk-[A-Za-z0-9_\-]{16,}\b"),
    re.compile(r"\bsk-or-v1-[A-Za-z0-9]{16,}\b"),
    re.compile(r"AGE-SECRET-KEY-1[02-9A-Z]{50,}"),
    re.compile(r"\beyJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b"),
    re.compile(r"\b[A-Fa-f0-9]{64,}\b"),
    re.compile(r"\b[A-Za-z0-9+/]{40,}={0,2}\b"),
]


def fingerprint(value):
    return "sha256:" + hashlib.sha256(value.encode("utf-8")).hexdigest()[:16]


def redact(text):
    out = text
    for shape in SECRET_SHAPES:
        out = shape.sub(lambda m: "[REDACTED-%s]" % fingerprint(m.group(0)), out)
    return out


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def classify(name, manifest):
    for cls, spec in manifest["classes"].items():
        for pattern in spec["patterns"]:
            if fnmatch.fnmatch(name, pattern):
                return cls, spec["treatment"]
    return None, "local-only"  # default-deny: unclassified never leaves


def find_recipient(repo_root):
    env_rec = os.environ.get("NEXO_AGE_RECIPIENT", "").strip()
    if env_rec.startswith("age1"):
        return env_rec
    sops_path = os.path.join(repo_root, ".sops.yaml")
    if os.path.exists(sops_path):
        m = re.search(r"age:\s*\"?(age1[a-z0-9]{58})\"?", open(sops_path).read())
        if m:
            return m.group(1)
    return None


def have(cmd):
    return shutil.which(cmd) is not None


def encrypt_raw(tar_path, dest_dir, repo_root, receipt):
    recipient = find_recipient(repo_root)
    if have("age") and recipient:
        out = tar_path + ".age"
        proc = subprocess.run(["age", "-r", recipient, "-o", out, tar_path],
                              capture_output=True, text=True)
        if proc.returncode == 0:
            receipt.update(backend="age", recipient=recipient)
            return out
        receipt.update(backend_attempt="age failed: " + proc.stderr[-150:])
    if have("sops") and recipient:
        out = tar_path + ".sops"
        env = dict(os.environ)
        keyfile = os.path.expanduser("~/.config/nexo/age/keys.txt")
        if os.path.exists(keyfile):
            env["SOPS_AGE_KEY_FILE"] = keyfile
        proc = subprocess.run(
            ["sops", "--encrypt", "--age", recipient, "--input-type", "binary",
             "--output-type", "binary", tar_path],
            capture_output=True, env=env)
        if proc.returncode == 0:
            with open(out, "wb") as fh:
                fh.write(proc.stdout)
            receipt.update(backend="sops", recipient=recipient)
            return out
        receipt.update(backend_attempt="sops failed rc=%d" % proc.returncode)
    passphrase = os.environ.get("NEXO_TELEMETRY_PASSPHRASE", "").strip()
    if have("openssl") and passphrase:
        out = tar_path + ".openssl-aes256"
        with open(out, "wb") as fh:
            proc = subprocess.run(
                ["openssl", "enc", "-aes-256-cbc", "-pbkdf2", "-iter", "200000",
                 "-salt", "-in", tar_path, "-pass", "env:NEXO_TELEMETRY_PASSPHRASE"],
                stdout=fh, env=dict(os.environ, NEXO_TELEMETRY_PASSPHRASE=passphrase))
        if proc.returncode == 0:
            receipt.update(backend="openssl-aes-256-cbc-pbkdf2")
            return out
        receipt.update(backend_attempt="openssl failed rc=%d" % proc.returncode)
    return None


def compute_flags(results, exit_codes):
    flags = set()
    for probe in results.get("probes", []):
        data = probe.get("data") or {}
        if data.get("blindspots"):
            flags.add("blindspots-found")
        if data.get("drift_alerts"):
            flags.add("drift-detected")
        if data.get("dns_violations"):
            flags.add("dns-violation")
    if any(str(v) not in ("0", "missing") for v in (exit_codes or {}).values()):
        flags.add("degraded-probe")
    return sorted(flags)


def render_briefing(results, run_dir, flags):
    lines = ["# AI BRIEFING — %s @ %s" % (results.get("node", "?"), results.get("run_id", "?")),
             "", "_Auto-generated by tools/telemetry/pack.py — secret-scrubbed, safe for the public telemetry area._", ""]
    report = os.path.join(run_dir, "REPORT.md")
    if os.path.exists(report):
        lines.append(open(report).read().strip())
        lines.append("")
    lines.append("## Flags")
    lines.append(", ".join("`%s`" % f for f in flags) if flags else "none")
    lines.append("")
    for probe in results.get("probes", []):
        name = probe.get("probe", "?")
        data = probe.get("data") or {}
        lines.append("## %s — %s" % (name, probe.get("status", "?")))
        if name.startswith("03"):
            lines.append("- blindspots: %s" % json.dumps(data.get("blindspots", []), sort_keys=True))
            lines.append("- public_ip: %s | warp_on: %s | isp_leak: %s" % (
                data.get("public_ip"), data.get("warp_on"), data.get("isp_cgnat_leak")))
            lines.append("- max_thermal_c: %s | mem: %s" % (data.get("max_thermal_c"), (data.get("ram") or {}).get("MemTotal")))
            lines.append("- routing: %s" % json.dumps(data.get("routing_verification", {}), sort_keys=True)[:400])
        elif name.startswith("02"):
            hosts = data.get("hosts_up", [])
            lines.append("- hosts_up: %d" % len(hosts))
            for host in hosts[:20]:
                lines.append("  - %s %s %s %s" % (host.get("ip"), host.get("mac") or "-",
                                                 host.get("vendor"), ",".join(host.get("services") or [])[:60]))
            lines.append("- esp staging targets: %d | drift alerts: %s" % (
                len(data.get("esp_firmware_staging_targets", [])),
                json.dumps(data.get("drift_alerts", []))))
        elif name.startswith("01"):
            lines.append("- zones: %d | tunnels: %d | workers: %s | gateways: %d | dns violations: %d" % (
                len(data.get("zones", [])), len(data.get("tunnels", [])), data.get("worker_count", "-"),
                len(data.get("gateways", [])), len(data.get("dns_violations", []))))
        elif name.startswith("04"):
            lines.append("- repos: %s | stale: %s | consolidation groups: %d" % (
                data.get("repos_total", "-"), data.get("stale_repos", "-"),
                len(data.get("consolidation_groups", []))))
            for group in data.get("consolidation_groups", [])[:8]:
                lines.append("  - %s <- %s" % (group.get("seed"), ", ".join(group.get("members", [])[1:])))
        elif name.startswith("05"):
            lines.append("- ollama models: %s | exposed: %s | fastmcp: %s | mcp configs: %d" % (
                json.dumps([m.get("name") for m in data.get("ollama_models", []) if isinstance(m, dict)]),
                data.get("ollama_bind_exposed"), data.get("fastmcp"), len(data.get("mcp_configs", []))))
        lines.append("")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--run-dir", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--manifest", default=None)
    ap.add_argument("--brief-only", action="store_true", help="print redacted briefing to stdout and exit")
    args = ap.parse_args()

    run_dir = os.path.abspath(args.run_dir)
    results_path = os.path.join(run_dir, "results.json")
    if not os.path.exists(results_path):
        sys.stderr.write("[pack] FATAL: %s has no results.json (run wave1 first)\n" % run_dir)
        return 1
    with open(results_path) as fh:
        results = json.load(fh)

    repo_root = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    manifest_path = args.manifest or os.path.join(repo_root, "telemetry", "PUSH_MANIFEST.json")
    if not os.path.exists(manifest_path):
        manifest_path = os.path.join(repo_root, "tools", "telemetry", "PUSH_MANIFEST.json")
    with open(manifest_path) as fh:
        manifest = json.load(fh)

    exit_codes = results.get("exit_codes", {})
    flags = compute_flags(results, exit_codes)

    if args.brief_only:
        sys.stdout.write(redact(render_briefing(results, run_dir, flags)) + "\n")
        return 0

    node_raw = os.environ.get("NEXO_NODE_NAME") or results.get("node") or "unknown"
    node = re.sub(r"[^A-Za-z0-9._-]", "_", str(node_raw)).strip("._-") or "unknown"
    run_id = results.get("run_id") or os.path.basename(run_dir)
    dest = os.path.join(args.out, node, run_id)
    os.makedirs(dest, exist_ok=True)

    # INDEX.json — plaintext metadata with per-file sha256 + classification
    index = {"schema_version": 1, "node": node, "run_id": run_id,
             "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
             "flags": flags, "probes": [], "files": [], "exit_codes": exit_codes}
    for probe in results.get("probes", []):
        index["probes"].append({"probe": probe.get("probe"), "status": probe.get("status")})
    enc_payload = []
    for path in sorted(glob.glob(os.path.join(run_dir, "**", "*"), recursive=True)):
        if not os.path.isfile(path):
            continue
        rel = os.path.relpath(path, run_dir)
        cls, treatment = classify(rel, manifest)
        entry = {"name": rel, "class": cls or "unclassified", "treatment": treatment,
                 "bytes": os.path.getsize(path), "sha256": sha256_file(path)}
        index["files"].append(entry)
        if treatment == "encrypted":
            enc_payload.append(path)

    receipt = {"encrypted": [], "skipped": [], "plaintext": []}
    if enc_payload:
        tar_path = os.path.join(dest, "raw.tar.gz")
        import tarfile
        with tarfile.open(tar_path, "w:gz") as tar:
            for p in enc_payload:
                tar.add(p, arcname=os.path.basename(p))
        encrypted = encrypt_raw(tar_path, dest, repo_root, receipt)
        os.unlink(tar_path)
        if encrypted is None:
            receipt["skipped"].append({"class": "raw", "reason": "no encryption backend (need age, sops, or NEXO_TELEMETRY_PASSPHRASE+openssl) — FAIL CLOSED, raw not pushed"})
            index["raw_encrypted"] = False
        else:
            enc_dir = os.path.join(dest, "enc")
            os.makedirs(enc_dir, exist_ok=True)
            final = os.path.join(enc_dir, os.path.basename(encrypted))
            os.replace(encrypted, final)
            receipt["encrypted"].append({"file": os.path.relpath(final, dest), "sha256": sha256_file(final)})
            index["raw_encrypted"] = True
    else:
        index["raw_encrypted"] = None

    briefing = redact(render_briefing(results, run_dir, flags))
    with open(os.path.join(dest, "BRIEFING.md"), "w") as fh:
        fh.write(briefing + "\n")
    receipt["plaintext"].extend(["INDEX.json", "BRIEFING.md"])
    with open(os.path.join(dest, "INDEX.json"), "w") as fh:
        json.dump(index, fh, indent=2, sort_keys=True)
    with open(os.path.join(dest, "PACK_RECEIPT.json"), "w") as fh:
        json.dump({"packed": index["generated"], "node": node, "run_id": run_id,
                   "flags": flags, "encryption": receipt}, fh, indent=2, sort_keys=True)
    print("[pack] staged %s (flags: %s; raw encrypted: %s)" % (dest, ",".join(flags) or "none", index["raw_encrypted"]))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        sys.stderr.write("[pack] FATAL: %r\n" % (exc,))
        raise SystemExit(1)
