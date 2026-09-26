// =============================================================================
// infra/cloudflare/worker.js — AcidWurx mesh edge router (archive-validated).
// Responsibilities:
//   * POST-only inference routing with token-length inspection (<4000 tokens
//     => local appliance; longer => edge failover model).
//   * Node health probe (HEAD, 1500ms AbortSignal timeout).
//   * Wake-on-LAN trigger through the private mesh to markslone
//     (POST http://$SUBNET_ROUTER_IP:9000/wake {"mac": $TARGET_APPLIANCE_MAC})
//     when the appliance is asleep in S5 (0W idle lifecycle).
//   * Serverless failover to Workers AI free tier while the node PXE-boots.
//   * GET /health for synthetic monitoring (returns 200 JSON).
// Env bindings (wrangler.toml [vars] + [[ai]]): SUBNET_ROUTER_IP,
//   TARGET_APPLIANCE_MAC, HEALTH_URL, AI.
// Safe-navigation guardrails are mandatory (archive fix: V8 isolate crashes on
// malformed payloads).
// =============================================================================

async function verifyNodeHealth(url) {
  try {
    const res = await fetch(url, { method: "HEAD", signal: AbortSignal.timeout(1500) });
    return res.status === 200;
  } catch {
    return false;
  }
}

async function triggerWakeOnLan(env) {
  if (!env.SUBNET_ROUTER_IP || !env.TARGET_APPLIANCE_MAC) {
    return;
  }
  const wolEndpoint = `http://${env.SUBNET_ROUTER_IP}:9000/wake`;
  try {
    await fetch(wolEndpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ mac: env.TARGET_APPLIANCE_MAC }),
      signal: AbortSignal.timeout(3000),
    });
  } catch {
    // WoL is best-effort; the failover model covers the boot window.
  }
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (request.method === "GET" && (url.pathname === "/health" || url.pathname === "/")) {
      return new Response(JSON.stringify({ status: "ok", worker: "acidwurx-mesh-router" }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    if (request.method !== "POST") {
      return new Response("Method Not Allowed", { status: 405 });
    }

    let payload;
    try {
      payload = await request.json();
    } catch {
      return new Response(JSON.stringify({ error: "Invalid JSON body" }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      });
    }

    // Safe navigation (archive guardrail): never trust payload shape.
    const messagesArray = Array.isArray(payload.messages) ? payload.messages : [];
    const promptText = messagesArray.map((m) => (m && typeof m.content === "string" ? m.content : "")).join(" ");
    const promptTokens = promptText.length / 4;

    const useLocalNode = promptTokens < 4000;
    const targetUrl = env.HEALTH_URL || "https://acidwurx.org";

    if (useLocalNode) {
      const isApplianceAwake = await verifyNodeHealth(targetUrl);

      if (!isApplianceAwake) {
        // Asynchronously wake the S5 appliance; serve this request from edge AI.
        ctx.waitUntil(triggerWakeOnLan(env));
      } else {
        try {
          const response = await fetch(`${targetUrl}/v1/chat/completions`, {
            method: "POST",
            headers: { "Content-Type": "application/json", Accept: "text/event-stream" },
            body: JSON.stringify(payload),
          });
          if (response.ok) {
            return new Response(response.body, {
              status: response.status,
              headers: { "Content-Type": response.headers.get("Content-Type") || "text/event-stream" },
            });
          }
        } catch {
          // Fall through to edge failover if the transport stalls.
        }
      }
    }

    // SERVERLESS EDGE FAILOVER (Workers AI free tier; budget sentinel caps spend).
    try {
      const aiResponse = await env.AI.run("@cf/meta/llama-3-8b-instruct", payload);
      return new Response(JSON.stringify(aiResponse), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    } catch (err) {
      return new Response(JSON.stringify({ error: "edge failover exhausted", detail: String(err) }), {
        status: 502,
        headers: { "Content-Type": "application/json" },
      });
    }
  },
};
