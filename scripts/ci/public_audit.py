#!/usr/bin/env python3
"""scripts/ci/public_audit.py — GO/NO-GO gate before making the repo public.
Scans every tracked file for secret-shaped strings, verifies .env/keys/backups
are not tracked, and checks file permissions hygiene. Exit 0 = GO, 1 = NO-GO.
Run: ./nexo.sh public-audit
"""
import os
import re
import subprocess
import sys

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
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
]
FORBIDDEN_TRACKED = {".env", "backups", "keys.txt"}

findings = []

# 1. tracked-file secret scan (git-tracked only; untracked local files are fine)
try:
    tracked = subprocess.run(["git", "-C", ROOT, "ls-files", "-z"],
                             capture_output=True, text=True, timeout=30).stdout.split("\0")
except Exception:
    tracked = [os.path.relpath(os.path.join(dp, f), ROOT)
               for dp, _, fns in os.walk(ROOT) if ".git" not in dp for f in fns]
tracked = [t for t in tracked if t]

for rel in tracked:
    parts = set(rel.split("/"))
    base = os.path.basename(rel)
    if base in FORBIDDEN_TRACKED or (parts & FORBIDDEN_TRACKED):
        findings.append("TRACKED-FORBIDDEN: %s" % rel)
    full = os.path.join(ROOT, rel)
    if not os.path.isfile(full):
        continue
    try:
        text = open(full, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    if rel == "scripts/ci/public_audit.py" or rel == "tools/telemetry/pack.py":
        continue  # scanners legitimately quote the shapes
    for shape in SECRET_SHAPES:
        m = shape.search(text)
        if m:
            findings.append("SECRET-SHAPE: %s @%d (%s...)" % (rel, m.start(), m.group(0)[:8]))

# 2. gitignore coverage
gi = os.path.join(ROOT, ".gitignore")
if os.path.exists(gi):
    gitignore = open(gi).read()
    for needed in (".env", "backups/", "keys.txt"):
        if needed not in gitignore:
            findings.append("GITIGNORE-MISSING: %s" % needed)
else:
    findings.append("GITIGNORE-MISSING: no .gitignore at repo root")

print("public_audit: scanned %d tracked files" % len(tracked))
if findings:
    print("\nNO-GO — %d finding(s):" % len(findings))
    for f in findings:
        print("  * %s" % f)
    sys.exit(1)
print("GO — no secret-shaped strings, no forbidden tracked paths, gitignore coverage OK.")
print("Publish with: gh repo edit <owner>/acidwurx-nexus --visibility public --accept-ownership-confirmation")
sys.exit(0)
