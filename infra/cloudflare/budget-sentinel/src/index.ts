// =============================================================================
// Budget Sentinel (archive-validated final code, t190). £5/month hard cap.
// KV ledger key: spend:YYYY-MM (integer pence). Free-model allowlist enforced;
// blocked-model denylist returns 403; cap breach returns 402.
// =============================================================================

export interface Env {
  SPEND_KV: KVNamespace;
  GATEWAY_ID: string;
  CAP_PENCE: string;
  DEFAULT_FREE_MODEL: string;
  ACCOUNT_ID: string;
}

const BLOCKED_MODELS = [
  "gpt-4",
  "gpt-4o",
  "claude-3-opus",
  "claude-3.5",
  "o1-",
  "o3-",
  "gemini-1.5-pro",
  "@cf/meta/llama-3.1-405b",
  "@cf/meta/llama-3-70b",
  "@cf/mistral/mistral-large",
];

const FREE_MODELS_ALLOWLIST = [
  "@cf/meta/llama-3.2-1b-instruct",
  "@cf/meta/llama-3.2-3b-instruct",
  "@cf/meta/llama-3-8b-instruct",
  "@cf/mistral/mistral-7b-instruct-v0.1",
  "@cf/google/gemma-2-2b-it",
  "@cf/qwen/qwen1.5-0.5b-chat",
];

function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization, cf-aig-authorization",
  };
}

function json(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders() },
  });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders() });
    }

    const url = new URL(request.url);
    const accountId =
      env.ACCOUNT_ID ||
      (url.hostname === "gateway.ai.cloudflare.com" ? url.pathname.split("/")[3] : "") ||
      "";
    const monthKey = `spend:${new Date().toISOString().slice(0, 7)}`;
    const cap = parseInt(env.CAP_PENCE || "500", 10);

    const currentSpend = parseInt((await env.SPEND_KV.get(monthKey)) || "0", 10);
    if (currentSpend >= cap) {
      return json({ error: `Budget cap hit. Current: ${currentSpend}p of ${cap}p` }, 402);
    }

    let body: Record<string, unknown> = {};
    try {
      body = await request.clone().json();
    } catch {
      // GET-style gateway probes carry no body; fall back to query param.
    }

    const requestedModel =
      (body.model as string) || url.searchParams.get("model") || env.DEFAULT_FREE_MODEL;

    if (BLOCKED_MODELS.some((m) => String(requestedModel).toLowerCase().includes(m.toLowerCase()))) {
      return json(
        { error: `Model ${requestedModel} blocked by budget policy. Use ${env.DEFAULT_FREE_MODEL}` },
        403,
      );
    }

    if (!FREE_MODELS_ALLOWLIST.includes(String(requestedModel))) {
      body.model = env.DEFAULT_FREE_MODEL;
    }

    const gatewayUrl = `https://gateway.ai.cloudflare.com/v1/${accountId}/${env.GATEWAY_ID}/compat/chat/completions`;

    const proxied = await fetch(gatewayUrl, {
      method: request.method,
      headers: {
        "Content-Type": "application/json",
        "cf-aig-authorization":
          request.headers.get("cf-aig-authorization") || request.headers.get("Authorization") || "",
      },
      body: request.method !== "GET" ? JSON.stringify(body) : undefined,
    });

    // Cost policy: allowlisted free models cost 0; requests to anything else
    // (post-enforcement this cannot happen) would increment the ledger by 1p.
    const costPence = FREE_MODELS_ALLOWLIST.includes(String(body.model)) ? 0 : 1;
    if (costPence > 0) {
      await env.SPEND_KV.put(monthKey, (currentSpend + costPence).toString());
    }

    const response = new Response(proxied.body, proxied);
    Object.entries(corsHeaders()).forEach(([k, v]) => response.headers.set(k, v));
    response.headers.set("X-AcidWurx-Spend", `${currentSpend}/${cap}p`);
    response.headers.set("X-AcidWurx-Model", String(body.model));
    return response;
  },
};
