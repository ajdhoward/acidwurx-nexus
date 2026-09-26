#!/usr/bin/env python3
"""04_github_ai_consolidation.py — read-only GitHub v3 repository auditor.
Inventories owner repos (paginated), classifies staleness (dead >730d,
stale >365d, aging >180d), extracts concept keywords from names/descriptions/
topics, clusters duplicate project concepts (>=2 shared keywords) for the
archive consolidation mandate, and fetches structural README maps (heading
trees only, capped by GITHUB_CONSOLIDATION_MAX_READMES, default 20) saved as
markdown under the run directory for AI concept-merge ingestion.
Writes 04_github_ai_consolidation_result.json + consolidation_report.md.
Env: GITHUB_TOKEN (missing => status=skipped), GITHUB_CONSOLIDATION_MAX_READMES.
"""
import datetime
import json
import os
import re
import sys
import urllib.error
import urllib.request

OUT_DIR = os.environ.get("NEXO_OUT_DIR", ".")
RESULT_PATH = os.path.join(OUT_DIR, "04_github_ai_consolidation_result.json")
REPORT_PATH = os.path.join(OUT_DIR, "consolidation_report.md")
API = "https://api.github.com"
TIMEOUT = 20
MAX_READMES = int(os.environ.get("GITHUB_CONSOLIDATION_MAX_READMES", "20"))
STOPWORDS = {
    "the", "and", "for", "with", "api", "app", "new", "old", "test", "tests",
    "my", "repo", "project", "code", "git", "github", "config", "configs",
    "script", "scripts", "tool", "tools", "util", "utils", "dev", "setup",
}


def emit(status, data, errors=None):
    payload = {
        "probe": "04_github_ai_consolidation",
        "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "node": os.environ.get("NEXO_NODE_NAME", "unknown"),
        "status": status,
        "data": data,
        "errors": errors or [],
    }
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(RESULT_PATH, "w") as fh:
        json.dump(payload, fh, indent=2, sort_keys=True)
    print("[04] status=%s -> %s" % (status, RESULT_PATH))


def gh(path, token, errors, accept="application/vnd.github+json"):
    req = urllib.request.Request(
        API + path,
        headers={
            "Authorization": "Bearer " + token,
            "Accept": accept,
            "User-Agent": "acidwurx-nexo-engine/1.0",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            remaining = resp.headers.get("X-RateLimit-Remaining")
            body = resp.read()
            if accept.endswith("raw+json") or "raw" in accept:
                return body.decode("utf-8", "replace"), remaining
            return json.loads(body.decode("utf-8")), remaining
    except urllib.error.HTTPError as exc:
        errors.append({"path": path, "http": exc.code})
        return None, None
    except Exception as exc:
        errors.append({"path": path, "error": repr(exc)})
        return None, None


def days_since(iso_ts):
    try:
        dt = datetime.datetime.fromisoformat(iso_ts.replace("Z", "+00:00"))
        return (datetime.datetime.now(datetime.timezone.utc) - dt).days
    except Exception:
        return 99999


def staleness(days):
    if days > 730:
        return "dead"
    if days > 365:
        return "stale"
    if days > 180:
        return "aging"
    return "active"


def keywords(repo):
    words = set()
    text = " ".join(filter(None, [repo.get("name", ""), repo.get("description") or ""]))
    words.update(w for w in re.split(r"[^a-z0-9]+", text.lower()) if len(w) > 3 and w not in STOPWORDS)
    words.update(t.lower() for t in (repo.get("topics") or []) if len(t) > 2)
    return words


def heading_tree(markdown_text, limit=40):
    heads = []
    for line in markdown_text.splitlines():
        m = re.match(r"^(#{1,4})\s+(.*)$", line)
        if m:
            heads.append("%s %s" % (m.group(1), m.group(2).strip()[:80]))
        if len(heads) >= limit:
            break
    return heads


def main():
    token = os.environ.get("GITHUB_TOKEN", "").strip()
    if not token:
        emit("skipped", {"reason": "GITHUB_TOKEN not set — repo consolidation audit disabled"})
        return 0

    errors = []
    repos = []
    page = 1
    remaining = "999"
    while page <= 5:
        batch, remaining = gh(
            "/user/repos?per_page=100&sort=pushed&direction=desc&affiliation=owner&page=%d" % page,
            token, errors)
        if not batch:
            break
        repos.extend(batch)
        if len(batch) < 100:
            break
        if remaining is not None and remaining.isdigit() and int(remaining) < 40:
            errors.append({"note": "rate limit guard tripped at page %d (remaining=%s)" % (page, remaining)})
            break
        page += 1

    if not repos:
        emit("degraded", {"repos_total": 0, "note": "no repos returned (check token scope)"}, errors)
        return 0

    inventory = []
    for repo in repos:
        days = days_since(repo.get("pushed_at") or repo.get("updated_at") or "")
        inventory.append({
            "full_name": repo.get("full_name"),
            "pushed_at": repo.get("pushed_at"),
            "days_since_push": days,
            "staleness": staleness(days),
            "archived": bool(repo.get("archived")),
            "fork": bool(repo.get("fork")),
            "language": repo.get("language"),
            "size_kb": repo.get("size"),
            "description": repo.get("description"),
            "topics": repo.get("topics") or [],
            "keywords": sorted(keywords(repo)),
        })

    # Concept clustering: >=2 shared keywords => consolidation candidate group
    groups = []
    used = set()
    for i, a in enumerate(inventory):
        if i in used or not a["keywords"]:
            continue
        cluster = [a["full_name"]]
        used.add(i)
        for j, b in enumerate(inventory):
            if j <= i or j in used or not b["keywords"]:
                continue
            shared = set(a["keywords"]) & set(b["keywords"])
            if len(shared) >= 2:
                cluster.append(b["full_name"])
                used.add(j)
        if len(cluster) > 1:
            groups.append({"seed": a["full_name"], "members": cluster,
                           "shared": sorted(set(a["keywords"]))[:6]})

    # README structural maps (capped, newest first — repos arrive sorted by push)
    readmes_dir = os.path.join(OUT_DIR, "readmes")
    os.makedirs(readmes_dir, exist_ok=True)
    fetched = 0
    readme_maps = []
    for entry in inventory:
        if fetched >= MAX_READMES:
            break
        if entry["fork"] or entry["archived"]:
            continue
        raw, _ = gh("/repos/%s/readme" % entry["full_name"], token, errors,
                    accept="application/vnd.github.raw+json")
        if raw is None:
            continue
        fetched += 1
        safe = entry["full_name"].replace("/", "__") + ".md"
        with open(os.path.join(readmes_dir, safe), "w") as fh:
            fh.write(raw if isinstance(raw, str) else str(raw))
        readme_maps.append({"repo": entry["full_name"], "headings": heading_tree(raw)})

    stale_counts = {}
    for entry in inventory:
        stale_counts[entry["staleness"]] = stale_counts.get(entry["staleness"], 0) + 1

    report = ["# GitHub Consolidation Report — %s" % datetime.date.today().isoformat(), ""]
    report.append("Total owner repos: %d | dead: %d | stale: %d | aging: %d | active: %d" % (
        len(inventory), stale_counts.get("dead", 0), stale_counts.get("stale", 0),
        stale_counts.get("aging", 0), stale_counts.get("active", 0)))
    report.append("")
    report.append("## Consolidation candidate groups (>=2 shared concept keywords)")
    for group in groups:
        report.append("- **%s** <- %s (shared: %s)" % (
            group["seed"], ", ".join(group["members"][1:]), ", ".join(group["shared"])))
    if not groups:
        report.append("- none detected")
    report.append("")
    report.append("## Stale/dead inventory")
    report.append("| repo | days since push | class |")
    report.append("|---|---|---|")
    for entry in sorted(inventory, key=lambda e: -e["days_since_push"]):
        if entry["staleness"] in ("dead", "stale"):
            report.append("| %s | %d | %s |" % (entry["full_name"], entry["days_since_push"], entry["staleness"]))
    report.append("")
    report.append("_README heading maps for %d repos saved under readmes/ for concept-merge ingestion._" % fetched)
    with open(REPORT_PATH, "w") as fh:
        fh.write("\n".join(report) + "\n")

    emit("ok", {
        "repos_total": len(inventory),
        "stale_repos": stale_counts.get("dead", 0) + stale_counts.get("stale", 0),
        "staleness_counts": stale_counts,
        "consolidation_groups": groups,
        "readmes_mapped": fetched,
        "inventory": inventory,
    }, errors)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        emit("error", {"fatal": repr(exc)})
        sys.exit(1)
