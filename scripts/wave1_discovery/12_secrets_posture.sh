#!/usr/bin/env bash
# =============================================================================
# 12_secrets_posture.sh — secrets HYGIENE posture audit (read-only; NEVER
# prints values — only existence, permissions, counts and sha256:16
# fingerprints). Checks: .env perms, age key perms/location, sops/age/gh/bw
# availability, git remotes with embedded credentials (reports remote NAME
# only), token-shaped hits in shell history (COUNT only), gh hosts file
# plaintext flag, and the archive rotation checklist status via ROTATION_*
# env markers.
# =============================================================================
set -euo pipefail

OUT_DIR="${NEXO_OUT_DIR:-.}"
mkdir -p "${OUT_DIR}"
# Locate repo root by walking up from OUT_DIR until a repo marker appears
REPO_ROOT_GUESS="$(pwd)"
_d="$(cd "${OUT_DIR}" 2>/dev/null && pwd || echo "$(pwd)")"
while [ "${_d}" != "/" ]; do
  if [ -f "${_d}/.env.example" ] || [ -d "${_d}/.git" ]; then REPO_ROOT_GUESS="${_d}"; break; fi
  _d="$(dirname "${_d}")"
done

python3 - "${OUT_DIR}" "${REPO_ROOT_GUESS}" <<'PYEOF'
import datetime, hashlib, json, os, re, subprocess, sys

out_dir, repo = sys.argv[1], sys.argv[2]
checks = []

def add(cid, status, detail=""):
    checks.append({"id": cid, "status": status, "detail": detail})

def perms(path):
    try:
        return oct(os.stat(path).st_mode & 0o777)
    except OSError:
        return None

# .env hygiene — Law 9: this file holds live tokens; anything but 0600 is a FAIL
for env_path in (os.path.join(repo, ".env"),):
    if os.path.exists(env_path):
        p = perms(env_path)
        add("env_file", "pass" if p == "0o600" else "fail", ".env perms %s (want 0600)" % p)
    else:
        add("env_file", "warn", ".env absent — stages will record skipped")

# age key — Law 9: private key material; anything but 0600 is a FAIL
key = os.path.expanduser("~/.config/nexo/age/keys.txt")
if os.path.exists(key):
    p = perms(key)
    add("age_key", "pass" if p == "0o600" else "fail", "keys.txt perms %s" % p)
else:
    add("age_key", "warn", "no age key at ~/.config/nexo/age/keys.txt (engine generates on run)")

# tooling availability
for tool in ("sops", "age", "gh", "bw", "restic", "openssl", "tmux"):
    add("tool_%s" % tool, "pass" if os.system("command -v %s >/dev/null 2>&1" % tool) == 0 else "missing", "")

# git remotes with embedded credentials (report remote name only)
try:
    out = subprocess.run(["git", "-C", repo, "remote", "-v"], capture_output=True, text=True, timeout=10).stdout
    tainted = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 2 and re.search(r"://[^/\s]+:[^@\s]+@", parts[1]):
            tainted.append(parts[0])
    add("git_remotes_token_free", "fail" if tainted else "pass",
        "remotes with embedded creds: %s" % (",".join(sorted(set(tainted))) or "none"))
except Exception:
    add("git_remotes_token_free", "warn", "git not queryable")

# .git/config deep scan — `git push -u <token-url>` parks the token in
# [branch "main"] remote=, which `git remote -v` never shows. Section names
# only; values never leave this function.
gitcfg = os.path.join(repo, ".git", "config")
if os.path.exists(gitcfg):
    tainted_sections = []
    section = "?"
    for line in open(gitcfg, errors="replace"):
        stripped = line.strip()
        if stripped.startswith("["):
            section = stripped
        if re.search(r"://[^/\s]+:[^@\s]+@", stripped) or re.search(r"\b(ghp_|gho_|github_pat_|cfut_|cfat_)[A-Za-z0-9_\-]{10,}", stripped):
            tainted_sections.append(section)
    add("git_config_token_free", "fail" if tainted_sections else "pass",
        "sections with embedded credentials: %s" % ",".join(sorted(set(tainted_sections))) if tainted_sections else "")

# gh plaintext store (existence check only)
gh_hosts = os.path.expanduser("~/.config/gh/hosts.yml")
add("gh_plaintext_store", "info" if os.path.exists(gh_hosts) else "pass",
    "gh hosts.yml present (0600 expected; normal for gh auth login)" if os.path.exists(gh_hosts) else "")
if os.path.exists(gh_hosts):
    p = perms(gh_hosts)
    if p not in ("0o600", "0o644"):
        add("gh_perms", "warn", "hosts.yml perms %s" % p)

# shell history token-shaped hits (COUNT only, never content)
hist_hits = 0
for hist in (os.path.expanduser("~/.bash_history"), os.path.expanduser("~/.zsh_history")):
    if os.path.exists(hist):
        try:
            text = open(hist, errors="replace").read()
            hist_hits += len(re.findall(r"\b(ghp_[A-Za-z0-9]{20,}|cfut_[A-Za-z0-9_\-]{20,}|sk-or-v1-[A-Za-z0-9]{16,}|AGE-SECRET-KEY-1[02-9A-Z]{40,})\b", text))
        except OSError:
            pass
add("history_token_hits", "fail" if hist_hits else "pass",
    "%d token-shaped string(s) in shell history — rotate + scrub" % hist_hits if hist_hits else "")

# Rotation checklist — reference credentials BY NAME ONLY; the compromised
# values are documented in the owner's private rotation runbook, never here.
rotation = [
    ("CF_API_TOKEN (cfut-prefixed token leaked in archive exports)", "ROTATION_CF_TOKEN"),
    ("LITELLM_MASTER_KEY (leaked in archive exports)", "ROTATION_LITELLM_KEY"),
    ("SEARXNG_SECRET_KEY (leaked in archive exports)", "ROTATION_SEARXNG_KEY"),
    ("Bitwarden session/master (leaked in archive exports)", "ROTATION_BITWARDEN"),
    ("wgcf WARP keys (July-era, if reused)", "ROTATION_WARP_KEYS"),
]
for item, marker in rotation:
    state = os.environ.get(marker, "")
    fp = "sha256:" + hashlib.sha256(item.encode()).hexdigest()[:16]
    add(marker.lower(), "pass" if state == "1" else "todo", "%s [%s]" % (item, fp))

failed = [c for c in checks if c["status"] == "fail"]
payload = {
    "probe": "12_secrets_posture",
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "node": os.environ.get("NEXO_NODE_NAME", "unknown"),
    "status": "ok" if not failed else "degraded",
    "data": {"checks": checks, "checks_total": len(checks), "checks_failed": len(failed)},
}
path = os.path.join(out_dir, "12_secrets_posture_result.json")
with open(path, "w") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
print("[12] checks=%d failed=%d -> %s" % (len(checks), len(failed), path))
PYEOF
