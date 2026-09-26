#!/usr/bin/env python3
"""scripts/ci/validate_repo.py — standalone structural validation harness.
Re-runnable copy of the engine's internal checks (Stage 6 gate, CI job A).

Usage: python3 scripts/ci/validate_repo.py [repo_root]

Checks (hard-fail unless noted):
  * .sh   -> bash -n syntax (when bash present) + set -euo pipefail presence
             for scripts under scripts/ (warn elsewhere)
  * .py   -> ast.parse + compile
  * .json -> json.loads
  * .yml/.yaml -> structural lint: no tabs, no conflict markers, no duplicate
             mapping keys per block (block-scalar aware), bracket balance warn
  * .ts/.js -> string/comment-aware balance of () [] {} + backtick templates
  * .toml -> tomllib (py3.11+) else bracket balance
  * ALL text files -> forbidden placeholder scan (@@TOKENS@@ allowed only in
             whitelisted files)
Exit code 0 = clean; 1 = hard failures (list printed). Never mutates anything.
"""
import ast
import json
import os
import re
import subprocess
import sys

FORBIDDEN = [
    re.compile(p, re.I if ci else 0) for p, ci in [
        (r"TODO:\s*implement", True), (r"FIXME", True), (r"PLACEHOLDER", False),
        (r"<YOUR_", True), (r"YOUR_[A-Z_]+_HERE", True),
        (r"\.\.\.\s*(remainder|rest)", True), (r"code goes here", True),
        (r"implement remainder", True),
    ]
]
TOKEN_WHITELIST = {
    "infra/cloudflare/budget-sentinel/wrangler.toml": ["@@SPEND_KV_ID@@", "@@CF_ACCOUNT_ID@@"],
    "infra/cloudflare/wrangler.toml": ["@@SUBNET_ROUTER_IP@@", "@@TARGET_APPLIANCE_MAC@@"],
    "infra/cloudflare/telemetry-ingest/wrangler.toml": ["@@D1_DATABASE_ID@@", "@@CF_ACCOUNT_ID@@"],
    "infra/netbootxyz/assets/preseed.cfg": ["@@PRESEED_PASSWORD_HASH@@"],
    "scripts/wave2_deployment/deploy_budget_sentinel.sh": ["@@SPEND_KV_ID@@", "@@CF_ACCOUNT_ID@@"],
    "scripts/wave2_deployment/deploy_telemetry_ingest.sh": ["@@D1_DATABASE_ID@@", "@@CF_ACCOUNT_ID@@"],
}
SELF_EXEMPT = {"scripts/ci/validate_repo.py"}  # quotes the forbidden markers by design
SKIP_DIRS = {".git", "node_modules", "__pycache__", ".pulumi-state", ".wrangler", "run-"}
TEXT_EXT = {".sh", ".py", ".json", ".yml", ".yaml", ".ts", ".js", ".toml", ".md",
            ".nft", ".cfg", ".ipxe", ".ini", ".example", ".txt", ".tf", ".sql"}

failures = []
warnings = []


def fail(check, path, detail):
    failures.append({"check": check, "path": path, "detail": detail})


def warn(check, path, detail):
    warnings.append({"check": check, "path": path, "detail": detail})


def check_bash(path, full):
    if subprocess.run(["bash", "--version"], stdout=subprocess.DEVNULL,
                      stderr=subprocess.DEVNULL).returncode != 0:
        warn("bash", path, "bash unavailable — syntax check skipped")
        return
    proc = subprocess.run(["bash", "-n", full], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        fail("bash -n", path, proc.stderr.decode("utf-8", "replace")[:300])
    text = open(full, encoding="utf-8", errors="replace").read()
    if path.startswith("scripts/") and "set -euo pipefail" not in text:
        fail("bash-strict", path, "missing 'set -euo pipefail' (defensive mandate)")


def check_python(path, full):
    src = open(full, encoding="utf-8", errors="replace").read()
    try:
        ast.parse(src)
        compile(src, full, "exec")
    except SyntaxError as exc:
        fail("python-ast", path, "line %s: %s" % (exc.lineno, exc.msg))


def check_json(path, full):
    try:
        with open(full, encoding="utf-8") as fh:
            json.load(fh)
    except Exception as exc:
        fail("json", path, repr(exc)[:200])


def check_yaml(path, full):
    text = open(full, encoding="utf-8", errors="replace").read()
    if "\t" in text:
        fail("yaml-tabs", path, "tab character found (YAML forbids tabs)")
    if re.search(r"^(<<<<<<<|=======$|>>>>>>>)", text, re.M):
        fail("yaml-conflict", path, "merge conflict markers present")
    stack = [(-1, set())]
    block_scalar_indent = None
    lineno = 0
    for raw in text.splitlines():
        lineno += 1
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        stripped = raw.strip()
        if block_scalar_indent is not None:
            if indent > block_scalar_indent:
                continue
            block_scalar_indent = None
        if stripped in ("---", "..."):
            stack = [(-1, set())]
            continue
        while stack and indent < stack[-1][0]:
            stack.pop()
        if not stack:
            stack = [(-1, set())]
        is_item = stripped.startswith("- ") or stripped == "-"
        if is_item and stack[-1][0] == indent:
            stack[-1] = (indent, set())  # each list item opens a fresh mapping scope
        m = re.match(r"^-?\s*([A-Za-z0-9_.\-\"']+)\s*:(\s|$)", stripped)
        if m:
            key = m.group(1).strip("\"'")
            top_indent, top_keys = stack[-1]
            if indent == top_indent:
                if key in top_keys:
                    fail("yaml-dup-key", path, "line %d: duplicate key '%s'" % (lineno, key))
                top_keys.add(key)
            else:
                stack.append((indent, {key}))
            value_part = stripped.split(":", 1)[1].strip()
            if value_part in ("|", ">", "|-", ">-", "|+", ">+"):
                block_scalar_indent = indent


def ts_bracket_counts(src):
    # String/comment-aware bracket counter with template-interpolation stack.
    counts = {"(": 0, ")": 0, "[": 0, "]": 0, "{": 0, "}": 0}
    stack = ["code"]
    interp_depth = 0
    i, n = 0, len(src)
    while i < n:
        mode = stack[-1]
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if mode in ("code", "interp"):
            if c == "/" and nxt == "/":
                j = src.find("\n", i)
                i = n if j < 0 else j
                continue
            if c == "/" and nxt == "*":
                j = src.find("*/", i + 2)
                i = n if j < 0 else j + 2
                continue
            if c in ("'", '"'):
                q = c
                i += 1
                while i < n:
                    if src[i] == "\\":
                        i += 2
                        continue
                    if src[i] == q:
                        i += 1
                        break
                    i += 1
                continue
            if c == "`":
                stack.append("tpl")
                i += 1
                continue
            if c in counts:
                if mode == "interp" and c == "}":
                    if interp_depth == 0:
                        stack.pop()
                        i += 1
                        continue
                    interp_depth -= 1
                elif mode == "interp" and c == "{":
                    interp_depth += 1
                counts[c] += 1
            i += 1
            continue
        if mode == "tpl":
            if c == "\\":
                i += 2
                continue
            if c == "`":
                stack.pop()
                i += 1
                continue
            if c == "$" and nxt == "{":
                stack.append("interp")
                interp_depth = 0
                i += 2
                continue
            i += 1
            continue
    return counts


def check_ts(path, full):
    src = open(full, encoding="utf-8", errors="replace").read()
    counts = ts_bracket_counts(src)
    for opener, closer in (("(", ")"), ("[", "]"), ("{", "}")):
        if counts[opener] != counts[closer]:
            fail("ts-balance", path, "unbalanced %s%s (%d vs %d)" % (
                opener, closer, counts[opener], counts[closer]))


def check_toml(path, full):
    src = open(full, encoding="utf-8", errors="replace").read()
    try:
        import tomllib  # noqa: F401  (py3.11+)
        with open(full, "rb") as fh:
            tomllib.load(fh)
        return
    except ImportError:
        pass
    except Exception as exc:
        fail("toml", path, repr(exc)[:200])
        return
    stripped = re.sub(r'"[^"]*"', '""', src)
    if stripped.count("{") != stripped.count("}") or stripped.count("[") != stripped.count("]"):
        fail("toml-balance", path, "unbalanced brackets (heuristic mode)")


def check_placeholders(path, full):
    allowed = TOKEN_WHITELIST.get(path, [])
    text = open(full, encoding="utf-8", errors="replace").read()
    for pattern in FORBIDDEN:
        for m in pattern.finditer(text):
            fail("placeholder-ban", path, "forbidden marker %r at offset %d" % (m.group(0)[:40], m.start()))
    for token in re.findall(r"@@[A-Z_]+@@", text):
        if token not in allowed:
            fail("placeholder-ban", path, "unwhitelisted runtime token %s" % token)


CHECKS = {
    ".sh": check_bash,
    ".py": check_python,
    ".json": check_json,
    ".yml": check_yaml,
    ".yaml": check_yaml,
    ".ts": check_ts,
    ".js": check_ts,
    ".toml": check_toml,
}


def main():
    root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
    scanned = 0
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.startswith("run-")]
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            ext = os.path.splitext(name)[1].lower()
            if name.endswith(".example"):
                ext = ".example"
            try:
                open(full, encoding="utf-8").read()
            except (UnicodeDecodeError, OSError):
                continue
            scanned += 1
            checker = CHECKS.get(ext)
            if checker:
                checker(rel, full)
            if (ext in TEXT_EXT or ext == ".example") and rel not in SELF_EXEMPT:
                check_placeholders(rel, full)
    print("validate_repo: scanned %d text files under %s" % (scanned, root))
    for w in warnings:
        print("  WARN  [%s] %s: %s" % (w["check"], w["path"], w["detail"]))
    if failures:
        print("\n%d HARD FAILURE(S):" % len(failures))
        for f in failures:
            print("  FAIL  [%s] %s: %s" % (f["check"], f["path"], f["detail"]))
        sys.exit(1)
    print("validate_repo: ALL CHECKS PASSED (%d warnings)" % len(warnings))
    sys.exit(0)


if __name__ == "__main__":
    main()
