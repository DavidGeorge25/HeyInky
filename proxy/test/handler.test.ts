import { test } from "node:test";
import assert from "node:assert/strict";
import type { AddressInfo } from "node:net";
import { DEFAULT_MODEL, handleRequest, prepareUpstreamBody, type ProxyEnv } from "../src/handler.ts";
import { createServer } from "../src/server.ts";

const sse = [
  'event: response.output_text.delta\ndata: {"type":"response.output_text.delta","delta":"{\\"actions\\":"}\n\n',
  'event: response.output_text.delta\ndata: {"type":"response.output_text.delta","delta":"[]}"}\n\n',
  'event: response.completed\ndata: {"type":"response.completed","response":{"status":"completed"}}\n\n',
];

function fakeFetch(calls: Array<{ url: string; init: RequestInit }>, response?: () => Response): typeof fetch {
  return (async (url: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(url), init: init ?? {} });
    if (response) return response();
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        for (const chunk of sse) controller.enqueue(new TextEncoder().encode(chunk));
        controller.close();
      },
    });
    return new Response(stream, { status: 200, headers: { "content-type": "text/event-stream" } });
  }) as typeof fetch;
}

const post = (body: unknown, headers: Record<string, string> = {}) =>
  new Request("http://localhost/inky", {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });

test("health reports whether the key is configured", async () => {
  const res = await handleRequest(new Request("http://localhost/health"), { OpenAI_API_Key: "k" });
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { ok: true, keyConfigured: true });
});

test("forwards to OpenAI with the key, defaults, and streams the body back", async () => {
  const calls: Array<{ url: string; init: RequestInit }> = [];
  const env: ProxyEnv = { OpenAI_API_Key: "sk-test", fetch: fakeFetch(calls) };
  const res = await handleRequest(post({ input: "hi", evil: true, store: true }), env);
  assert.equal(res.status, 200);
  assert.match(res.headers.get("content-type") ?? "", /event-stream/);
  assert.equal(await res.text(), sse.join(""));

  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "https://api.openai.com/v1/responses");
  const headers = calls[0].init.headers as Record<string, string>;
  assert.equal(headers.authorization, "Bearer sk-test");
  const sent = JSON.parse(String(calls[0].init.body));
  assert.equal(sent.model, DEFAULT_MODEL);
  assert.equal(sent.stream, true);
  assert.equal(sent.store, false);
  assert.equal(sent.evil, undefined, "unknown fields are dropped");
});

test("request model wins over env fallback", () => {
  const prepared = prepareUpstreamBody({ input: [], model: "gpt-x" }, { INKY_MODEL: "gpt-y" });
  assert.ok("body" in prepared);
  assert.equal(prepared.body.model, "gpt-x");
  const fallback = prepareUpstreamBody({ input: [] }, { INKY_MODEL: "gpt-y" });
  assert.ok("body" in fallback);
  assert.equal(fallback.body.model, "gpt-y");
});

test("rejects bad input", async () => {
  const env: ProxyEnv = { OpenAI_API_Key: "k", fetch: fakeFetch([]) };
  assert.equal((await handleRequest(post("not json"), env)).status, 400);
  assert.equal((await handleRequest(post({ nope: 1 }), env)).status, 400);
  assert.equal((await handleRequest(post([1, 2]), env)).status, 400);
  assert.equal((await handleRequest(new Request("http://localhost/inky"), env)).status, 405);
  assert.equal((await handleRequest(new Request("http://localhost/other"), env)).status, 404);
});

test("missing key is a clear 500", async () => {
  const res = await handleRequest(post({ input: "x" }), {});
  assert.equal(res.status, 500);
  assert.match((await res.json()).error.message, /OpenAI_API_Key/);
});

test("optional shared token is enforced", async () => {
  const env: ProxyEnv = { OpenAI_API_Key: "k", INKY_PROXY_TOKEN: "secret", fetch: fakeFetch([]) };
  assert.equal((await handleRequest(post({ input: "x" }), env)).status, 401);
  assert.equal((await handleRequest(post({ input: "x" }, { "x-inky-token": "secret" }), env)).status, 200);
});

test("upstream errors are passed through with OpenAI's message", async () => {
  const env: ProxyEnv = {
    OpenAI_API_Key: "k",
    fetch: fakeFetch([], () => Response.json({ error: { message: "Invalid schema" } }, { status: 400 })),
  };
  const res = await handleRequest(post({ input: "x" }), env);
  assert.equal(res.status, 400);
  const json = await res.json();
  assert.equal(json.error.message, "Invalid schema");
  assert.equal(json.error.upstreamStatus, 400);
});

test("node server streams end to end", async () => {
  const calls: Array<{ url: string; init: RequestInit }> = [];
  const server = createServer({ OpenAI_API_Key: "k", fetch: fakeFetch(calls) });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  try {
    const res = await fetch(`http://127.0.0.1:${port}/inky`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ input: "hello" }),
    });
    assert.equal(res.status, 200);
    assert.equal(await res.text(), sse.join(""));
    assert.equal(JSON.parse(String(calls[0].init.body)).input, "hello");
  } finally {
    server.close();
  }
});

test("retries once when OpenAI can't be reached, then reports 502", async () => {
  const calls: Array<{ url: string; init: RequestInit }> = [];
  let failures = 1;
  const flaky = (async (url: string | URL | Request, init?: RequestInit) => {
    if (failures-- > 0) {
      calls.push({ url: String(url), init: init ?? {} });
      throw new TypeError("fetch failed");
    }
    return fakeFetch(calls)(url, init);
  }) as typeof fetch;
  const ok = await handleRequest(post({ input: "hi" }), { OpenAI_API_Key: "k", fetch: flaky });
  assert.equal(ok.status, 200);
  assert.equal(calls.length, 2);

  const down = (async () => {
    throw new TypeError("fetch failed");
  }) as typeof fetch;
  const res = await handleRequest(post({ input: "hi" }), { OpenAI_API_Key: "k", fetch: down });
  assert.equal(res.status, 502);
});

test("prompt_cache_key passes the allow-list", () => {
  const out = prepareUpstreamBody({ input: "x", prompt_cache_key: "inky-v2", secret: 1 }, {});
  assert.ok("body" in out);
  if ("body" in out) {
    assert.equal(out.body.prompt_cache_key, "inky-v2");
    assert.equal("secret" in out.body, false);
  }
});
