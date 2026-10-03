// Platform-neutral request handler (Fetch API types only) so the same code runs
// under Node (src/server.ts) and as a Cloudflare Worker (src/worker.ts).
//
// Contract: POST /inky with an OpenAI Responses API request body (minus credentials).
// The app builds the body (prompt, page image, json_schema format); the proxy adds the
// API key, applies defaults, and streams OpenAI's server-sent events straight back.

export const DEFAULT_MODEL = "gpt-5.4-mini";
export const OPENAI_RESPONSES_URL = "https://api.openai.com/v1/responses";
export const MAX_BODY_BYTES = 20 * 1024 * 1024;

// Top-level Responses API fields the app may set. Anything else is dropped.
const ALLOWED_FIELDS = new Set([
  "model",
  "input",
  "instructions",
  "text",
  "reasoning",
  "max_output_tokens",
  "stream",
  "temperature",
  "metadata",
  "prompt_cache_key",
]);

export interface ProxyEnv {
  OpenAI_API_Key?: string;
  /** Optional shared secret. When set, requests must send `X-Inky-Token`. */
  INKY_PROXY_TOKEN?: string;
  /** Optional fallback model when the request does not name one. */
  INKY_MODEL?: string;
  /** Injectable for tests. */
  fetch?: typeof fetch;
}

export function jsonError(status: number, message: string, extra: Record<string, unknown> = {}): Response {
  return new Response(JSON.stringify({ error: { message, ...extra } }), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export async function handleRequest(request: Request, env: ProxyEnv): Promise<Response> {
  const url = new URL(request.url);

  if (url.pathname === "/health" && request.method === "GET") {
    return Response.json({ ok: true, keyConfigured: Boolean(env.OpenAI_API_Key) });
  }
  if (url.pathname !== "/inky") return jsonError(404, "Not found");
  if (request.method !== "POST") return jsonError(405, "Use POST");

  if (env.INKY_PROXY_TOKEN && request.headers.get("x-inky-token") !== env.INKY_PROXY_TOKEN) {
    return jsonError(401, "Missing or wrong X-Inky-Token");
  }
  if (!env.OpenAI_API_Key) {
    return jsonError(500, "Proxy has no OpenAI_API_Key. Add it to the repo-root .env.");
  }

  const declaredLength = Number(request.headers.get("content-length") ?? "0");
  if (declaredLength > MAX_BODY_BYTES) return jsonError(413, "Request too large");

  let raw: string;
  try {
    raw = await request.text();
  } catch {
    return jsonError(400, "Could not read request body");
  }
  if (raw.length > MAX_BODY_BYTES) return jsonError(413, "Request too large");

  let body: unknown;
  try {
    body = JSON.parse(raw);
  } catch {
    return jsonError(400, "Body must be JSON");
  }

  const prepared = prepareUpstreamBody(body, env);
  if ("error" in prepared) return jsonError(400, prepared.error);

  const doFetch = env.fetch ?? fetch;
  let upstream: Response;
  try {
    upstream = await doFetch(OPENAI_RESPONSES_URL, {
      method: "POST",
      headers: {
        authorization: `Bearer ${env.OpenAI_API_Key}`,
        "content-type": "application/json",
        accept: prepared.body.stream ? "text/event-stream" : "application/json",
      },
      body: JSON.stringify(prepared.body),
      signal: request.signal,
    });
  } catch (err) {
    return jsonError(502, `Could not reach OpenAI: ${(err as Error).message}`);
  }

  if (!upstream.ok) {
    const text = await upstream.text().catch(() => "");
    let message = `OpenAI returned ${upstream.status}`;
    try {
      const parsed = JSON.parse(text) as { error?: { message?: string } };
      if (parsed.error?.message) message = parsed.error.message;
    } catch {
      // keep generic message
    }
    return jsonError(upstream.status, message, { upstreamStatus: upstream.status });
  }

  const headers = new Headers({
    "content-type": upstream.headers.get("content-type") ?? (prepared.body.stream ? "text/event-stream" : "application/json"),
    "cache-control": "no-cache",
  });
  return new Response(upstream.body, { status: 200, headers });
}

export type UpstreamBody = Record<string, unknown> & { model: string; stream: boolean; store: false };

export function prepareUpstreamBody(body: unknown, env: ProxyEnv): { body: UpstreamBody } | { error: string } {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { error: "Body must be a JSON object" };
  }
  const source = body as Record<string, unknown>;
  if (!("input" in source)) return { error: "Missing `input`" };

  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(source)) {
    if (ALLOWED_FIELDS.has(key)) out[key] = value;
  }
  const model = typeof source.model === "string" && source.model.length > 0 ? source.model : env.INKY_MODEL || DEFAULT_MODEL;
  const stream = typeof source.stream === "boolean" ? source.stream : true;
  return { body: { ...out, model, stream, store: false } };
}
