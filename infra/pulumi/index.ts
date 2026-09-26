// =============================================================================
// infra/pulumi/index.ts — AcidWurx Zero Trust edge plane (Pulumi TypeScript)
// Provider: @pulumi/cloudflare ~5.49 (v5 resource naming verified against the
// Pulumi registry: ZeroTrustTunnelCloudflared[Config], ZeroTrustTunnelRoute,
// ZeroTrustTunnelVirtualNetwork, ZeroTrustAccessApplication/Policy, Record,
// D1Database, WorkerScript, WorkerDomain) + @pulumi/command for the AI
// Gateway REST upsert (the provider has no native AI Gateway resource on the
// pinned version — archive-verified limitation; `pulumi preview` is the
// authoritative schema gate, Law 7).
//
// Topology implemented (all constants extracted from the operational archive):
//   * Tunnel `acidwurx-bare-metal`, remotely-managed ingress:
//       api.acidwurx.org     ^/v1/.*  -> http://192.168.1.138:8080 (llama.cpp)
//       api.acidwurx.org     ^/mcp/.* -> http://192.168.1.138:8000 (MCP tools)
//       cockpit.acidwurx.org          -> http://192.168.1.179:3000 (Open WebUI)
//       catch-all                     -> http_status:404
//   * Virtual network `acidwurx-mesh` + private tunnel route advertising
//     192.168.1.0/24 into the Cloudflare mesh (WARP clients reach the LAN
//     without any public exposure of it).
//   * Cloudflare Access JWT validation profiles: self-hosted applications on
//     api + cockpit hostnames, WebAuthn (`swk`, FIDO2/YubiKey) allow policies,
//     24h sessions. Access validates the cf-access-jwt-aud claim per hostname;
//     upstream services trust ONLY tunnel-forwarded JWTs (Law 5: zero public
//     origin IPs). The ingest hostname is deliberately NOT Access-gated —
//     machine telemetry authenticates with HMAC-SHA256 envelopes instead
//     (docs/interop/ZAI_HANDOFF_SCHEMA.md §2); a WebAuthn gate would break
//     headless probe pushes.
//   * D1 database `nexo-telemetry` + edge worker `nexo-telemetry-ingest`
//     (module source read from infra/cloudflare/telemetry-ingest/worker.js —
//     single source of truth shared with the wrangler fallback path), bound
//     via WorkerDomain on ingest.<zone>.
//   * AI Gateway `acidwurx` token-caching rules (cache 30d = 2592000s,
//     60 req/min, auth header on) applied idempotently through a REST
//     GET->PATCH/POST command resource (account audit: reuse the existing
//     gateway; never create duplicates acidwurx2/master).
//
// Hydration (zero prompts): pulumi config OR environment variables —
//   CF_ACCOUNT_ID, CF_ZONE_ID (optional; zone looked up by name), ADMIN_EMAIL,
//   CLOUDFLARE_TUNNEL_SECRET, CLOUDFLARE_API_TOKEN (provider + command env),
//   NEXO_INGEST_HMAC_KEY (optional; empty binding => ingest rejects pushes
//   until hydrated — fail-closed, never fail-open), LAN_SUBNET, node IPs.
// =============================================================================

import * as pulumi from "@pulumi/pulumi";
import * as cloudflare from "@pulumi/cloudflare";
import * as command from "@pulumi/command";
import * as fs from "fs";
import * as path from "path";

function envOr(name: string, fallback: string): string {
  const v = process.env[name];
  return v && v.length > 0 ? v : fallback;
}

const config = new pulumi.Config();

const accountId: string = config.get("accountId") ?? envOr("CF_ACCOUNT_ID", "");
const zoneName: string = config.get("zoneName") ?? envOr("APPLIANCE_DOMAIN", "acidwurx.org");
const adminEmail: string = config.get("adminEmail") ?? envOr("ADMIN_EMAIL", "");
const tunnelSecret: string =
  config.get("tunnelSecret") ?? envOr("CLOUDFLARE_TUNNEL_SECRET", "");
const lanSubnet: string = envOr("LAN_SUBNET", "192.168.1.0/24");
const applianceIp: string = envOr("JESSICAFLETCHER_LAN_IP", "192.168.1.138");
const gatewayIp: string = envOr("MARKSLONE_LAN_IP", "192.168.1.179");
const apiHostname: string = config.get("apiHostname") ?? "api." + zoneName;
const cockpitHostname: string = config.get("cockpitHostname") ?? "cockpit." + zoneName;
const ingestHostname: string = config.get("ingestHostname") ?? "ingest." + zoneName;
const aiGatewayId: string = envOr("AI_GATEWAY_ID", "acidwurx");
const aiGatewayCacheTtl: string = envOr("AI_GATEWAY_CACHE_TTL", "2592000"); // 30 days (archive config)
const aiGatewayRateLimit: string = envOr("AI_GATEWAY_RATE_LIMIT", "60");    // 60 req/min (archive config)
const cfApiToken: string = process.env["CLOUDFLARE_API_TOKEN"] ?? "";

if (!accountId) {
  throw new Error(
    "CF_ACCOUNT_ID (or pulumi config accountId) must be hydrated before preview/up. " +
      "Stage 1 rule: hydrate all variables up front — never mid-run.",
  );
}
if (!tunnelSecret) {
  throw new Error(
    "CLOUDFLARE_TUNNEL_SECRET (or pulumi config tunnelSecret) must be set. " +
      "Generate: openssl rand -base64 32",
  );
}

// Ingest worker secret: fail-CLOSED when unset (worker rejects all pushes).
const ingestHmacKey: pulumi.Output<string> =
  config.getSecret("ingestHmacKey") ??
  pulumi.secret(process.env["NEXO_INGEST_HMAC_KEY"] ?? "");

// Zone lookup (read-only data source; requires CLOUDFLARE_API_TOKEN env).
const zone = cloudflare.getZone({ name: zoneName });
const zoneId = pulumi.output(zone).id;

// ---------------------------------------------------------------------------
// 1. Mesh plumbing: virtual network + tunnel + private route advertisement
// ---------------------------------------------------------------------------
const meshVnet = new cloudflare.ZeroTrustTunnelVirtualNetwork("acidwurx-mesh", {
  accountId: accountId,
  name: "acidwurx-mesh",
  comment: "AcidWurx LAN virtual network (mesh route segregation)",
  isDefaultNetwork: true,
});

const tunnel = new cloudflare.ZeroTrustTunnelCloudflared("acidwurx-bare-metal", {
  accountId: accountId,
  name: "acidwurx-bare-metal",
  secret: tunnelSecret,
  configSrc: "cloudflare",
});

const tunnelConfig = new cloudflare.ZeroTrustTunnelCloudflaredConfig(
  "appliance-config",
  {
    accountId: accountId,
    tunnelId: tunnel.id,
    config: {
      ingressRules: [
        {
          hostname: apiHostname,
          path: "^/v1/.*$",
          service: "http://" + applianceIp + ":8080",
        },
        {
          hostname: apiHostname,
          path: "^/mcp/.*$",
          service: "http://" + applianceIp + ":8000",
        },
        {
          hostname: cockpitHostname,
          service: "http://" + gatewayIp + ":3000",
        },
        {
          service: "http_status:404",
        },
      ],
    },
  },
);

// Private route: advertise the LAN subnet into the CF mesh (outbound-only;
// enrolled WARP devices reach 192.168.1.0/24 through this tunnel — the
// archive's CGNAT-bypass mandate with zero inbound port forwarding).
const lanRoute = new cloudflare.ZeroTrustTunnelRoute("lan-private-route", {
  accountId: accountId,
  tunnelId: tunnel.id,
  network: lanSubnet,
  virtualNetworkId: meshVnet.id,
  comment: "AcidWurx LAN advertisement (192.168.1.0/24) via markslone",
});

// ---------------------------------------------------------------------------
// 2. Zero Trust Access JWT validation profiles (WebAuthn/YubiKey, 24h)
// ---------------------------------------------------------------------------
const apiAccessApp = new cloudflare.ZeroTrustAccessApplication("api-gateway", {
  zoneId: zoneId,
  name: "AcidWurx AI API Gateway",
  domain: apiHostname,
  type: "self_hosted",
  sessionDuration: "24h",
});

const apiAccessPolicy = new cloudflare.ZeroTrustAccessPolicy("api-webauthn-policy", {
  zoneId: zoneId,
  applicationId: apiAccessApp.id,
  name: "Hardware YubiKey Requirement",
  decision: "allow",
  includes: [{ email: adminEmail ? [adminEmail] : [] }],
  requires: [{ authMethod: "swk" }],
});

const cockpitAccessApp = new cloudflare.ZeroTrustAccessApplication("cockpit-gateway", {
  zoneId: zoneId,
  name: "AcidWurx Cockpit (Open WebUI)",
  domain: cockpitHostname,
  type: "self_hosted",
  sessionDuration: "24h",
});

const cockpitAccessPolicy = new cloudflare.ZeroTrustAccessPolicy("cockpit-webauthn-policy", {
  zoneId: zoneId,
  applicationId: cockpitAccessApp.id,
  name: "Hardware YubiKey Requirement",
  decision: "allow",
  includes: [{ email: adminEmail ? [adminEmail] : [] }],
  requires: [{ authMethod: "swk" }],
});

// ---------------------------------------------------------------------------
// 3. Proxied DNS bindings (never origin IPs — Law 5)
// ---------------------------------------------------------------------------
const apiCname = new cloudflare.Record("api-cname", {
  zoneId: zoneId,
  name: "api",
  type: "CNAME",
  value: pulumi.interpolate`${tunnel.id}.cfargotunnel.com`,
  proxied: true,
  ttl: 1,
  comment: "AcidWurx inference API via acidwurx-bare-metal tunnel",
});

const cockpitCname = new cloudflare.Record("cockpit-cname", {
  zoneId: zoneId,
  name: "cockpit",
  type: "CNAME",
  value: pulumi.interpolate`${tunnel.id}.cfargotunnel.com`,
  proxied: true,
  ttl: 1,
  comment: "Open WebUI cockpit on markslone via tunnel",
});

// ---------------------------------------------------------------------------
// 4. z.ai handoff plane: D1 + ingest worker + custom domain
// ---------------------------------------------------------------------------
const telemetryDb = new cloudflare.D1Database("nexo-telemetry-db", {
  accountId: accountId,
  name: "nexo-telemetry",
});

// Single source of truth: the same worker.js the wrangler fallback deploys.
const ingestWorkerSource = fs.readFileSync(
  path.join(__dirname, "..", "cloudflare", "telemetry-ingest", "worker.js"),
  "utf-8",
);

const ingestWorker = new cloudflare.WorkerScript("telemetry-ingest", {
  accountId: accountId,
  name: "nexo-telemetry-ingest",
  module: ingestWorkerSource,
  compatibilityDate: "2026-07-23",
  d1DatabaseBindings: [
    {
      name: "DB",
      databaseId: telemetryDb.id,
    },
  ],
  plainTextBindings: {
    SCHEMA_VERSION: "1",
    RATE_LIMIT_PER_MIN: "30",
  },
  secretTextBindings: {
    NEXO_INGEST_HMAC_KEY: ingestHmacKey,
  },
});

const ingestDomain = new cloudflare.WorkerDomain("ingest-domain", {
  accountId: accountId,
  hostname: ingestHostname,
  zoneName: zoneName,
  service: ingestWorker.name,
  enabled: true,
});

// ---------------------------------------------------------------------------
// 5. AI Gateway token-caching rules (REST upsert; provider has no native
//    resource on the pinned version). GET-before-mutate keeps it idempotent
//    and honors the audit directive to REUSE gateway `acidwurx`.
// ---------------------------------------------------------------------------
const aiGateway = new command.local.Command("ai-gateway-cache-rules", {
  create: [
    `set -euo pipefail`,
    `API="https://api.cloudflare.com/client/v4"`,
    `GW="$API/accounts/$CF_ACCOUNT_ID/ai_gateway/universal_gateways/$GATEWAY_ID"`,
    `SETTINGS=$(printf '{"auth_header":true,"cache":true,"cache_ttl":%s,"rate_limit":%s,"rate_limit_period":"m","collect_detailed_logs":false}' "$CACHE_TTL" "$RATE_LIMIT")`,
    `CREATE_BODY=$(printf '{"id":"%s","auth_header":true,"cache":true,"cache_ttl":%s,"rate_limit":%s,"rate_limit_period":"m","collect_detailed_logs":false}' "$GATEWAY_ID" "$CACHE_TTL" "$RATE_LIMIT")`,
    `EXISTING=$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" "$GW" || true)`,
    `if printf "%s" "$EXISTING" | grep -q '"success":[[:space:]]*true'; then`,
    `  OUT=$(curl -sf -X PATCH "$GW" -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" --data "$SETTINGS")`,
    `else`,
    `  OUT=$(curl -sf -X POST "$API/accounts/$CF_ACCOUNT_ID/ai_gateway/universal_gateways" -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" --data "$CREATE_BODY")`,
    `fi`,
    `printf "%s" "$OUT" | grep -q '"success":[[:space:]]*true' || { printf "ai-gateway upsert failed: %s\\n" "$OUT" >&2; exit 1; }`,
    `printf "ai-gateway %s ready: cache_ttl=%ss rate_limit=%s/min auth_header=on\\n" "$GATEWAY_ID" "$CACHE_TTL" "$RATE_LIMIT"`,
  ].join("\n"),
  delete:
    `curl -s -X DELETE "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/ai_gateway/universal_gateways/$GATEWAY_ID" -H "Authorization: Bearer $CF_API_TOKEN" >/dev/null || true`,
  environment: {
    CF_API_TOKEN: pulumi.secret(cfApiToken),
    CF_ACCOUNT_ID: accountId,
    GATEWAY_ID: aiGatewayId,
    CACHE_TTL: aiGatewayCacheTtl,
    RATE_LIMIT: aiGatewayRateLimit,
  },
  triggers: [accountId, aiGatewayId, aiGatewayCacheTtl, aiGatewayRateLimit],
});

// ---------------------------------------------------------------------------
// Stack outputs (non-sensitive only)
// ---------------------------------------------------------------------------
export const tunnelId = tunnel.id;
export const virtualNetworkId = meshVnet.id;
export const privateRouteNetwork = lanRoute.network;
export const apiAccessApplicationId = apiAccessApp.id;
export const cockpitAccessApplicationId = cockpitAccessApp.id;
export const d1DatabaseId = telemetryDb.id;
export const ingestWorkerName = ingestWorker.name;
export const ingestEndpoint = pulumi.interpolate`https://${ingestHostname}/v1/telemetry`;
export const apiEndpoint = pulumi.interpolate`https://${apiHostname}/v1/chat/completions`;
export const cockpitEndpoint = pulumi.interpolate`https://${cockpitHostname}`;
export const aiGatewayStdout = aiGateway.stdout;
