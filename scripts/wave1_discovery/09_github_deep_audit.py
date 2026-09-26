#!/usr/bin/env python3
"""09_github_deep_audit.py — GitHub GOVERNANCE audit (read-only) for the repos
that run this mesh. Complements probe 04 (consolidation) with the CI/CD control
plane picture: branch protection, environments + protection rules, Actions
secret NAMES (never values), recent workflow runs + conclusions, webhooks,
labels, open issues. Emits governance_gaps consumed by the remediation engine
(missing production-bare-metal environment, unprotected main, missing secrets
from the 8-item checklist). Env: GITHUB_TOKEN; NEXO_GH_AUDIT_REPOS
(comma list, default acidwurx-nexus,acidwurx-nexus-telemetry).
"""
import datetime
import json
import os
import sys
import urllib.error
import urllib.request

OUT_DIR = os.environ.get("NEXO_OUT_DIR", ".")
RESULT = os.path.join(OUT_DIR, "09_github_deep_audit_result.json")
API = "https://api.github.com"
TIMEOUT = 20
REQUIRED_SECRETS = ["CLOUDFLARE_API_TOKEN", "CF_ACCOUNT_ID", "CF_ZONE_ID", "ADMIN_EMAIL",
                    "CLOUDFLARE_TUNNEL_SECRET", "LOCAL_APPLIANCE_SSH_KEY",
                    "PULUMI_CONFIG_PASSPHRASE", "NEXO_INGEST_HMAC_KEY"]
REQUIRED_ENVIRONMENTS = ["production-bare-metal"]


def emit(status, data, errors=None):
    payload = {"probe": "09_github_deep_audit",
               "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
               "node": os.environ.get("NEXO_NODE_NAME", "unknown"),
               "status": status, "data": data, "errors": errors or []}
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(RESULT, "w") as fh:
        json.dump(payload, fh, indent=2, sort_keys=True)
    print("[09] status=%s -> %s" % (status, RESULT))


def gh(path, token, errors):
    req = urllib.request.Request(API + path, headers={
        "Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "acidwurx-nexo-engine/2.3"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            remaining = resp.headers.get("X-RateLimit-Remaining")
            if remaining is not None and remaining.isdigit() and int(remaining) < 10:
                errors.append({"note": "rate-limit guard: %s remaining" % remaining})
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        errors.append({"path": path, "http": exc.code})
        return None
    except Exception as exc:
        errors.append({"path": path, "error": repr(exc)[:150]})
        return None


def main():
    token = os.environ.get("GITHUB_TOKEN", "").strip()
    if not token:
        emit("skipped", {"reason": "GITHUB_TOKEN not set"})
        return 0
    errors = []
    me = gh("/user", token, errors)
    if not me or not me.get("login"):
        emit("degraded", {"reason": "token rejected or /user failed"}, errors)
        return 0
    owner = os.environ.get("GITHUB_OWNER", "").strip() or me["login"]
    repo_list = [r.strip() for r in os.environ.get(
        "NEXO_GH_AUDIT_REPOS", "acidwurx-nexus,acidwurx-nexus-telemetry").split(",") if r.strip()]

    repos = []
    for name in repo_list:
        full = "%s/%s" % (owner, name)
        entry = {"repo": full}
        info = gh("/repos/%s" % full, token, errors)
        if not info:
            entry["exists"] = False
            repos.append(entry)
            continue
        entry["exists"] = True
        entry["private"] = info.get("private")
        entry["default_branch"] = info.get("default_branch")
        entry["open_issues"] = info.get("open_issues_count")

        protection = gh("/repos/%s/branches/%s/protection" % (full, info.get("default_branch", "main")), token, errors)
        entry["branch_protection"] = {
            "present": protection is not None,
            "required_pr": bool(protection and protection.get("required_pull_request_reviews")),
            "status_checks": bool(protection and protection.get("required_status_checks")),
        }
        envs = gh("/repos/%s/environments" % full, token, errors) or {}
        env_names = [e.get("name") for e in (envs.get("environments") or [])]
        entry["environments"] = env_names
        entry["approval_gate_present"] = all(e in env_names for e in REQUIRED_ENVIRONMENTS)
        secrets = gh("/repos/%s/actions/secrets" % full, token, errors) or {}
        secret_names = [s.get("name") for s in (secrets.get("secrets") or [])]
        entry["secret_names"] = secret_names
        entry["missing_secrets"] = [s for s in REQUIRED_SECRETS if s not in secret_names]
        runs = gh("/repos/%s/actions/runs?per_page=15" % full, token, errors) or {}
        entry["recent_runs"] = [{"name": r.get("name"), "status": r.get("status"),
                                 "conclusion": r.get("conclusion"), "created": r.get("created_at")}
                                for r in (runs.get("workflow_runs") or [])]
        hooks = gh("/repos/%s/hooks" % full, token, errors)
        entry["webhooks"] = len(hooks) if isinstance(hooks, list) else None
        labels = gh("/repos/%s/labels?per_page=100" % full, token, errors)
        entry["labels"] = [l.get("name") for l in labels] if isinstance(labels, list) else None
        repos.append(entry)

    nexus = next((r for r in repos if r["repo"].endswith("/acidwurx-nexus")), None)
    gaps = []
    if nexus and nexus.get("exists"):
        if not nexus.get("approval_gate_present"):
            gaps.append("environment 'production-bare-metal' missing (Stage-7 gate absent — apply jobs would run ungated if secrets existed)")
        if not (nexus.get("branch_protection") or {}).get("present"):
            gaps.append("main branch unprotected (enable after first green run: PR + status checks + signed commits)")
        for secret in nexus.get("missing_secrets", []):
            gaps.append("actions secret missing: %s" % secret)
        red_runs = [r for r in nexus.get("recent_runs", []) if r.get("conclusion") == "failure"]
        if red_runs:
            gaps.append("%d recent failed workflow run(s): %s" % (len(red_runs), ", ".join(r["name"] for r in red_runs[:3])))
    tele = next((r for r in repos if r["repo"].endswith("/acidwurx-nexus-telemetry")), None)
    if tele and tele.get("exists") and tele.get("labels") is not None:
        needed = {"telemetry", "wave1", "telemetry-blindspots", "telemetry-drift", "telemetry-degraded", "telemetry-dns-violation"}
        missing_labels = sorted(needed - set(tele["labels"]))
        if missing_labels:
            gaps.append("telemetry repo missing labels: %s" % ", ".join(missing_labels))

    emit("ok", {"owner": owner, "repos": repos, "governance_gaps": gaps,
                "governance_gaps_count": len(gaps)}, errors)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        emit("error", {"fatal": repr(exc)})
        sys.exit(1)
