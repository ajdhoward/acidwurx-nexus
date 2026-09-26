#!/usr/bin/env python3
"""tools/access/request_access.py — AI-agent access application (pure stdlib).

Implements the application side of docs/ACCESS_APPLICATION.md:
  1. Generates an age X25519 keypair LOCALLY (embedded implementation,
     RFC 7748 vectors self-tested; or --pubkey to import an existing one,
     or uses `age-keygen` when installed).
  2. Stores the SECRET key at ~/.config/nexo/agent-keys/<agent>.txt (0600) —
     it never leaves this machine, never enters the issue.
  3. Prints/submits the access-request issue containing ONLY the public key.

Submission paths (first available wins; zero prompts):
  --print-body        just print the issue markdown (manual submission)
  gh CLI present      gh issue create --label access-request
  GITHUB_TOKEN set    REST API issue creation via urllib
  else                print body + manual instructions

Usage:
  request_access.py --agent "z.ai/glm-5-turbo" --purpose "code review of encrypted telemetry" [--print-body]
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import secrets as _secrets
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

# --- compact age keygen (same math as generate_nexus_engine.py, self-tested) --
_P = 2 ** 255 - 19
_A24 = 121665
_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
_GEN = [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]


def _x25519(scalar_bytes, u_bytes):
    k = bytearray(scalar_bytes)
    k[0] &= 248
    k[31] &= 127
    k[31] |= 64
    k_int = int.from_bytes(k, "little")
    u = int.from_bytes(u_bytes, "little") % _P
    x1, x2, z2, x3, z3 = u, 1, 0, u, 1
    swap = 0

    def cswap(sw, a, b):
        d = (sw * ((a - b) % _P)) % _P
        return ((a - d) % _P, (b + d) % _P)

    for t in range(254, -1, -1):
        kt = (k_int >> t) & 1
        swap ^= kt
        x2, x3 = cswap(swap, x2, x3)
        z2, z3 = cswap(swap, z2, z3)
        swap = kt
        a = (x2 + z2) % _P
        aa = a * a % _P
        b = (x2 - z2) % _P
        bb = b * b % _P
        e = (aa - bb) % _P
        c = (x3 + z3) % _P
        d = (x3 - z3) % _P
        da = d * a % _P
        cb = c * b % _P
        x3 = (da + cb) ** 2 % _P
        z3 = x1 * ((da - cb) ** 2 % _P) % _P
        x2 = aa * bb % _P
        z2 = e * ((aa + _A24 * e) % _P) % _P
    x2, x3 = cswap(swap, x2, x3)
    z2, z3 = cswap(swap, z2, z3)
    return (x2 * pow(z2, _P - 2, _P) % _P).to_bytes(32, "little")


def _polymod(values):
    chk = 1
    for v in values:
        top = chk >> 25
        chk = ((chk & 0x1FFFFFF) << 5) ^ v
        for i in range(5):
            chk ^= _GEN[i] if ((top >> i) & 1) else 0
    return chk


def _hrp_expand(hrp):
    return [ord(x) >> 5 for x in hrp] + [0] + [ord(x) & 31 for x in hrp]


def _convertbits(data, frombits, tobits, pad=True):
    acc = bits = 0
    ret = []
    maxv = (1 << tobits) - 1
    for value in data:
        acc = (acc << frombits) | value
        bits += frombits
        while bits >= tobits:
            bits -= tobits
            ret.append((acc >> bits) & maxv)
    if pad and bits:
        ret.append((acc << (tobits - bits)) & maxv)
    return ret


def _bech32_encode(hrp, data_bytes):
    data5 = _convertbits(data_bytes, 8, 5)
    hrp_l = hrp.lower()
    values = _hrp_expand(hrp_l) + data5
    polymod = _polymod(values + [0, 0, 0, 0, 0, 0]) ^ 1
    checksum = [(polymod >> 5 * (5 - i)) & 31 for i in range(6)]
    out = hrp_l + "1" + "".join(_CHARSET[d] for d in data5 + checksum)
    return out.upper() if hrp != hrp_l else out


def _selftest():
    got = _x25519(
        bytes.fromhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"),
        b"\x09" + b"\x00" * 31)
    want = bytes.fromhex("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
    if got != want:
        sys.stderr.write("[access] FATAL: X25519 self-test failed\n")
        raise SystemExit(1)


def generate_keypair():
    _selftest()
    secret32 = _secrets.token_bytes(32)
    public32 = _x25519(secret32, b"\x09" + b"\x00" * 31)
    secret_str = _bech32_encode("AGE-SECRET-KEY-", secret32)
    public_str = _bech32_encode("age", public32)
    return secret_str, public_str


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--agent", required=True, help="agent identity, e.g. 'z.ai/glm-5-turbo'")
    ap.add_argument("--purpose", default="(unspecified)", help="what the agent needs access for")
    ap.add_argument("--pubkey", default=None, help="import an existing age1... public key instead of generating")
    ap.add_argument("--repo", default=os.environ.get("NEXO_ACCESS_REPO", "ajdhoward/acidwurx-nexus"))
    ap.add_argument("--print-body", action="store_true")
    args = ap.parse_args()

    if not re.match(r"^[A-Za-z0-9._/@ -]{3,80}$", args.agent):
        sys.stderr.write("[access] invalid --agent charset\n")
        return 2

    key_dir = os.path.join(os.path.expanduser("~"), ".config", "nexo", "agent-keys")
    key_path = os.path.join(key_dir, "%s.txt" % re.sub(r"[^A-Za-z0-9._-]", "_", args.agent))
    if args.pubkey:
        public = args.pubkey.strip()
        if not re.match(r"^age1[02-9ac-z]{58}$", public):
            sys.stderr.write("[access] --pubkey is not a valid age public key\n")
            return 2
        secret = None
    elif os.path.exists(key_path):
        text = open(key_path).read()
        m = re.search(r"(AGE-SECRET-KEY-1[02-9A-Z]{58})", text)
        p = re.search(r"# public key: (age1[02-9ac-z]{58})", text)
        if m and p:
            secret, public = m.group(1), p.group(1)
        else:
            sys.stderr.write("[access] existing key file unreadable: %s\n" % key_path)
            return 1
    elif shutil.which("age-keygen"):
        proc = subprocess.run(["age-keygen"], capture_output=True, text=True)
        secret = re.search(r"(AGE-SECRET-KEY-1[02-9A-Z]{58})", proc.stdout + proc.stderr)
        public = re.search(r"(age1[02-9ac-z]{58})", proc.stdout + proc.stderr)
        if not (secret and public):
            sys.stderr.write("[access] age-keygen output unparseable\n")
            return 1
        secret, public = secret.group(1), public.group(1)
    else:
        secret, public = generate_keypair()

    if secret:
        os.makedirs(key_dir, exist_ok=True)
        old = os.umask(0o077)
        try:
            if not os.path.exists(key_path):
                with open(key_path, "w") as fh:
                    fh.write("# created: %s\n# public key: %s\n%s\n" % (
                        datetime.datetime.now(datetime.timezone.utc).isoformat(), public, secret))
                os.chmod(key_path, 0o600)
        finally:
            os.umask(old)
        print("[access] secret key stored: %s (0600 — NEVER submit or paste it anywhere)" % key_path)
    print("[access] public key: %s" % public)
    print("[access] fingerprint: sha256:%s" % hashlib.sha256(public.encode()).hexdigest()[:16])

    body = "\n".join([
        "## AI Agent Access Request",
        "",
        "- **Agent identity:** %s" % args.agent,
        "- **Purpose:** %s" % args.purpose,
        "- **age PUBLIC key:** `%s`" % public,
        "- **Key fingerprint:** sha256:%s" % hashlib.sha256(public.encode()).hexdigest()[:16],
        "- **Applied:** %s" % datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "",
        "Process per `docs/ACCESS_APPLICATION.md`: owner adds label `approved` (grant) or",
        "`denied` (reject). On `approved`, the access-approval workflow appends the public key",
        "to `.sops.yaml` recipients, commits, comments confirmation, and adds `access-granted`.",
        "",
        "### Confirmations",
        "- [x] Secret key never leaves the agent's host; only this public key is submitted.",
        "- [x] Decrypted content is processed locally and never re-committed in plaintext (Law 9).",
        "- [x] Access is revocable at any time (remove recipient + `sops updatekeys`).",
    ])
    title = "[ACCESS] %s" % args.agent

    if args.print_body:
        print("\n----- issue title -----\n%s\n----- issue body -----\n%s" % (title, body))
        return 0

    if shutil.which("gh"):
        proc = subprocess.run(["gh", "issue", "create", "--repo", args.repo,
                               "--title", title, "--body", body, "--label", "access-request"],
                              capture_output=True, text=True, timeout=60)
        if proc.returncode == 0:
            print("[access] issue created: %s" % proc.stdout.strip())
            return 0
        print("[access] gh issue create failed (%s) — falling back to manual body above" % proc.stderr.strip()[:150])
    token = os.environ.get("GITHUB_TOKEN", "").strip()
    if token:
        req = urllib.request.Request(
            "https://api.github.com/repos/%s/issues" % args.repo,
            data=json.dumps({"title": title, "body": body, "labels": ["access-request"]}).encode(),
            method="POST",
            headers={"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
                     "User-Agent": "nexo-access-request/1.0", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                created = json.loads(resp.read().decode())
            print("[access] issue created: %s" % created.get("html_url"))
            return 0
        except urllib.error.HTTPError as exc:
            print("[access] API create failed HTTP %d — manual body printed above" % exc.code)
            return 1
    print("[access] no gh/GITHUB_TOKEN available — create the issue manually with the body above (label: access-request)")
    print(body)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        sys.stderr.write("[access] FATAL: %r\n" % (exc,))
        raise SystemExit(1)
