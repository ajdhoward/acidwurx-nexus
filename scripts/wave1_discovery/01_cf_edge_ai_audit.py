#!/usr/bin/env python3
"""01_cf_edge_ai_audit.py — zero-dependency Cloudflare API v4 structural explorer.
Read-only GETs: token verify, zones (+DNS violation scan against private/CGNAT
space), tunnels, workers scripts (burn-risk flag >50), KV namespaces, R2
buckets, AI gateways (probes both universal_gateways and gateways API shapes),
workers subdomain. Writes <NEXO_OUT_DIR>/01_cf_edge_ai_audit_result.json.
Env: CF_API_TOKEN, CF_ACCOUNT_ID, CF_ZONE_ID (optional), ISP_CGNAT_IP
(optional leak canary). Missing token => status=skipped (zero-prompt law).
"""
import datetime
import ipaddress
import json
import os
import sys
import urllib.error
import urllib.request

OUT_DIR = os.environ.get("NEXO_OUT_DIR", ".")
RESULT_PATH = os.path.join(OUT_DIR, "01_cf_edge_ai_audit_result.json")
API = "https://api.cloudflare.com/client/v4"
TIMEOUT = 15

PRIVATE_NETS = [
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
    ipaddress.ip_network("100.64.0.0/10"),
    ipaddress.ip_network("169.254.0.0/16"),
]


def emit(status, data, errors=None):
    payload = {
        "probe": "01_cf_edge_ai_audit",
        "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "node": os.environ.get("NEXO_NODE_NAME", "unknown"),
        "status": status,
        "data": data,
        "errors": errors or [],
    }
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(RESULT_PATH, "w") as fh:
        json.dump(payload, fh, indent=2, sort_keys=True)
    print("[01] status=%s -> %s" % (status, RESULT_PATH))


def cf_get(path, token, errors):
    req = urllib.request.Request(
        API + path,
        headers={
            "Authorization": "Bearer " + token,
            "Content-Type": "application/json",
            "User-Agent": "acidwurx-nexo-engine/1.0",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            body = json.loads(resp.read().decode("utf-8"))
            return body
    except urllib.error.HTTPError as exc:
        detail = ""
        try:
            detail = exc.read().decode("utf-8", "replace")[:400]
        except Exception:
            pass
        errors.append({"path": path, "http": exc.code, "detail": detail})
        return None
    except Exception as exc:
        errors.append({"path": path, "error": repr(exc)})
        return None


def is_private_ip(value):
    try:
        addr = ipaddress.ip_address(value)
    except ValueError:
        return False
    return any(addr in net for net in PRIVATE_NETS)


def main():
    token = os.environ.get("CF_API_TOKEN", "").strip()
    account = os.environ.get("CF_ACCOUNT_ID", "").strip()
    zone_pref = os.environ.get("CF_ZONE_ID", "").strip()
    isp_ip = os.environ.get("ISP_CGNAT_IP", "").strip()
    if not token:
        emit("skipped", {"reason": "CF_API_TOKEN not set — hydrate .env to enable edge audit"})
        return 0

    errors = []
    data = {"zones": [], "tunnels": [], "workers": [], "kv_namespaces": [],
            "r2_buckets": [], "gateways": [], "dns_violations": [], "worker_count": 0}

    verify = cf_get("/user/tokens/verify", token, errors)
    data["token_valid"] = bool(verify and verify.get("success"))

    zones_resp = cf_get("/zones?per_page=50", token, errors)
    zone_ids = []
    if zones_resp and zones_resp.get("success"):
        for z in zones_resp.get("result", []):
            data["zones"].append({"name": z.get("name"), "id": z.get("id"),
                                  "plan": (z.get("plan") or {}).get("name"),
                                  "status": z.get("status")})
            zone_ids.append(z.get("id"))
    if zone_pref and zone_pref not in zone_ids:
        zone_ids.insert(0, zone_pref)

    for zid in zone_ids[:5]:
        recs = cf_get("/zones/%s/dns_records?per_page=200" % zid, token, errors)
        if recs and recs.get("success"):
            for rec in recs.get("result", []):
                content = rec.get("content", "")
                if rec.get("type") in ("A", "AAAA") and is_private_ip(content):
                    data["dns_violations"].append(
                        {"zone": zid, "name": rec.get("name"), "type": rec.get("type"),
                         "content": content, "rule": "Law5-no-private-origin"})
                if rec.get("type") in ("A", "AAAA") and isp_ip and content == isp_ip:
                    data["dns_violations"].append(
                        {"zone": zid, "name": rec.get("name"), "type": rec.get("type"),
                         "content": content, "rule": "Law5-no-isp-cgnat-origin"})

    if account:
        tunnels = cf_get("/accounts/%s/cfd_tunnel" % account, token, errors)
        if tunnels and tunnels.get("success"):
            for t in tunnels.get("result", []):
                data["tunnels"].append({"name": t.get("name"), "id": t.get("id"),
                                        "status": t.get("status"),
                                        "remote": t.get("remote_config")})
        scripts = cf_get("/accounts/%s/workers/scripts?per_page=100" % account, token, errors)
        if scripts and scripts.get("success"):
            names = [s.get("id") for s in scripts.get("result", [])]
            data["workers"] = names
            data["worker_count"] = len(names)
            data["worker_burn_risk"] = len(names) > 50
            overlap = [n for n in names if n in ("acidwurx-cost-monitor", "ai-router", "acidwurx-ai-proxy")]
            data["sentinel_overlap_candidates"] = overlap
        kv = cf_get("/accounts/%s/workers/kv/namespaces?per_page=100" % account, token, errors)
        if kv and kv.get("success"):
            data["kv_namespaces"] = [{"id": n.get("id"), "title": n.get("title")}
                                     for n in kv.get("result", [])]
        r2 = cf_get("/accounts/%s/r2/buckets" % account, token, errors)
        if r2 and r2.get("success"):
            data["r2_buckets"] = [b.get("name") for b in r2.get("result", [])]
        gateways = cf_get("/accounts/%s/ai_gateway/universal_gateways" % account, token, errors)
        if not (gateways and gateways.get("success")):
            gateways = cf_get("/accounts/%s/ai_gateway/gateways" % account, token, errors)
        if gateways and gateways.get("success"):
            result = gateways.get("result", [])
            if isinstance(result, dict):
                result = result.get("gateways", [])
            for g in result:
                data["gateways"].append({
                    "id": g.get("id") or g.get("name"),
                    "cache": g.get("cache"),
                    "cache_ttl": g.get("cache_ttl"),
                    "rate_limit": g.get("rate_limit"),
                    "auth": g.get("auth_header"),
                })
        subdomain = cf_get("/accounts/%s/workers/subdomain" % account, token, errors)
        if subdomain and subdomain.get("success"):
            data["workers_subdomain"] = (subdomain.get("result") or {}).get("subdomain")

    status = "ok" if data.get("token_valid") else "degraded"
    emit(status, data, errors)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        emit("error", {"fatal": repr(exc)})
        sys.exit(1)
