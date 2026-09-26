#!/usr/bin/env python3
"""08_cloud_deep_audit.py — full Cloudflare account IMAGING (read-only GETs).
Beyond probe 01's structural scan, this captures the decision-grade picture:
every DNS record per zone (with Law-5 violation classification), Access
applications + policies (swk/WebAuthn presence), Zero Trust enrolled devices,
tunnels + their routes/vnets, AI Gateway full settings (cache TTL, rate limit,
auth), worker inventory with modified timestamps, KV namespaces, R2 buckets,
Pages projects. Emits account_flags (gateway duplicates acidwurx2/master,
worker burn risk, dns violation count) consumed directly by the remediation
engine's rules. Env: CF_API_TOKEN, CF_ACCOUNT_ID. Missing => status=skipped.
"""
import datetime
import ipaddress
import json
import os
import sys
import urllib.error
import urllib.request

OUT_DIR = os.environ.get("NEXO_OUT_DIR", ".")
RESULT = os.path.join(OUT_DIR, "08_cloud_deep_audit_result.json")
API = "https://api.cloudflare.com/client/v4"
TIMEOUT = 15
PRIVATE_NETS = [ipaddress.ip_network(n) for n in
                ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16")]


def emit(status, data, errors=None):
    payload = {"probe": "08_cloud_deep_audit",
               "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
               "node": os.environ.get("NEXO_NODE_NAME", "unknown"),
               "status": status, "data": data, "errors": errors or []}
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(RESULT, "w") as fh:
        json.dump(payload, fh, indent=2, sort_keys=True)
    print("[08] status=%s -> %s" % (status, RESULT))


def cf(path, token, errors):
    req = urllib.request.Request(API + path, headers={
        "Authorization": "Bearer " + token, "Content-Type": "application/json",
        "User-Agent": "acidwurx-nexo-engine/2.3"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        errors.append({"path": path, "http": exc.code})
        return None
    except Exception as exc:
        errors.append({"path": path, "error": repr(exc)[:150]})
        return None


def result_of(body):
    if body and body.get("success"):
        return body.get("result")
    return None


def main():
    token = os.environ.get("CF_API_TOKEN", "").strip()
    account = os.environ.get("CF_ACCOUNT_ID", "").strip()
    isp_ip = os.environ.get("ISP_CGNAT_IP", "").strip()
    if not token:
        emit("skipped", {"reason": "CF_API_TOKEN not set"})
        return 0
    errors = []
    data = {"zones_full": [], "access_apps": [], "zt_devices": [], "tunnels_full": [],
            "gateways_full": [], "workers_detail": [], "kv": [], "r2": [], "pages": [],
            "records_total": 0, "dns_violations": [], "account_flags": {}}

    zones = result_of(cf("/zones?per_page=50", token, errors)) or []
    for z in zones:
        zid, zname = z.get("id"), z.get("name")
        records = []
        for page in (1, 2, 3):
            batch = result_of(cf("/zones/%s/dns_records?per_page=200&page=%d" % (zid, page), token, errors))
            if not batch:
                break
            for r in batch:
                rec = {"name": r.get("name"), "type": r.get("type"), "content": r.get("content"),
                       "proxied": r.get("proxied"), "ttl": r.get("ttl"), "comment": r.get("comment")}
                records.append(rec)
                if r.get("type") in ("A", "AAAA"):
                    try:
                        addr = ipaddress.ip_address(r.get("content", ""))
                        if any(addr in net for net in PRIVATE_NETS) or (isp_ip and r.get("content") == isp_ip):
                            data["dns_violations"].append({"zone": zname, "name": rec["name"],
                                                           "content": rec["content"], "rule": "Law5-no-private-origin"})
                    except ValueError:
                        pass
            if len(batch) < 200:
                break
        data["records_total"] += len(records)
        data["zones_full"].append({"zone": zname, "id": zid, "plan": (z.get("plan") or {}).get("name"),
                                   "status": z.get("status"), "record_count": len(records), "records": records})
        apps = result_of(cf("/zones/%s/access/apps?per_page=50" % zid, token, errors)) or []
        for app in apps:
            policies = result_of(cf("/zones/%s/access/apps/%s/policies" % (zid, app.get("id")), token, errors)) or []
            data["access_apps"].append({
                "zone": zname, "name": app.get("name"), "domain": app.get("domain"),
                "session_duration": app.get("session_duration"),
                "policies": [{"name": p.get("name"), "decision": p.get("decision"),
                              "swk_required": any("swk" in json.dumps(req) for req in (p.get("require") or []))}
                             for p in policies]})

    if account:
        devices = result_of(cf("/accounts/%s/devices?per_page=100" % account, token, errors)) or []
        data["zt_devices"] = [{"name": d.get("name"), "ip": (d.get("interface_ips") or [None])[0],
                               "last_seen": d.get("last_seen"), "revoked": d.get("revoked_at") is not None}
                              for d in devices]
        tunnels = result_of(cf("/accounts/%s/cfd_tunnel?per_page=50" % account, token, errors)) or []
        for t in tunnels:
            routes = result_of(cf("/accounts/%s/cfd_tunnel/%s/routes" % (account, t.get("id")), token, errors))
            vnets = result_of(cf("/accounts/%s/cfd_tunnel/%s/vnet" % (account, t.get("id")), token, errors))
            data["tunnels_full"].append({"name": t.get("name"), "id": t.get("id"), "status": t.get("status"),
                                         "remote_config": t.get("remote_config"),
                                         "routes": [r.get("network") for r in (routes or [])],
                                         "vnets": [v.get("name") for v in (vnets or []) if isinstance(v, dict)]})
        gws = result_of(cf("/accounts/%s/ai_gateway/universal_gateways" % account, token, errors))
        if isinstance(gws, dict):
            gws = gws.get("gateways", [])
        for g in (gws or []):
            data["gateways_full"].append({"id": g.get("id") or g.get("name"), "cache": g.get("cache"),
                                          "cache_ttl": g.get("cache_ttl"), "rate_limit": g.get("rate_limit"),
                                          "auth": g.get("auth_header"), "billing": g.get("workers_ai_billing_mode")})
        scripts = result_of(cf("/accounts/%s/workers/scripts?per_page=100" % account, token, errors)) or []
        data["workers_detail"] = [{"id": s.get("id"), "modified_on": s.get("modified_on")} for s in scripts]
        data["kv"] = [{"title": n.get("title"), "id": n.get("id")}
                      for n in (result_of(cf("/accounts/%s/workers/kv/namespaces?per_page=100" % account, token, errors)) or [])]
        data["r2"] = [b.get("name") for b in (result_of(cf("/accounts/%s/r2/buckets" % account, token, errors)) or [])]
        data["pages"] = [p.get("name") for p in (result_of(cf("/accounts/%s/pages/projects" % account, token, errors)) or [])]

        gw_ids = [g["id"] for g in data["gateways_full"] if g.get("id")]
        data["account_flags"] = {
            "worker_count": len(data["workers_detail"]),
            "worker_burn_risk": len(data["workers_detail"]) > 50,
            "gateway_duplicates": [g for g in gw_ids if g in ("acidwurx2", "master")],
            "gateway_primary_present": "acidwurx" in gw_ids,
            "dns_violation_count": len(data["dns_violations"]),
            "sentinel_overlap": [w["id"] for w in data["workers_detail"]
                                 if w["id"] in ("acidwurx-cost-monitor", "ai-router", "acidwurx-ai-proxy")],
            "tunnel_private_routes": [r for t in data["tunnels_full"] for r in t.get("routes", [])],
        }
    emit("ok", data, errors)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        emit("error", {"fatal": repr(exc)})
        sys.exit(1)
