// Node entry point: `npm start` (Node >= 22.18 runs TypeScript directly).
import fs from "node:fs";
import http from "node:http";
import { Readable } from "node:stream";
import { fileURLToPath } from "node:url";
import { handleRequest, jsonError, type ProxyEnv } from "./handler.ts";
import { loadRepoEnv } from "./env.ts";

export function createServer(env: ProxyEnv): http.Server {
  return http.createServer(async (req, res) => {
    const started = Date.now();
    const controller = new AbortController();
    res.on("close", () => {
      if (!res.writableFinished) controller.abort();
    });

    let response: Response;
    try {
      const hasBody = req.method !== "GET" && req.method !== "HEAD";
      const request = new Request(`http://${req.headers.host ?? "localhost"}${req.url ?? "/"}`, {
        method: req.method,
        headers: req.headers as Record<string, string>,
        body: hasBody ? (Readable.toWeb(req) as ReadableStream<Uint8Array>) : undefined,
        signal: controller.signal,
        // @ts-expect-error `duplex` is required by Node for streaming request bodies but missing from lib.dom.
        duplex: "half",
      });
      response = await handleRequest(request, env);
    } catch (err) {
      response = jsonError(500, `Proxy error: ${(err as Error).message}`);
    }

    res.writeHead(response.status, Object.fromEntries(response.headers));
    // INKY_PROXY_LOG=<file>: append each response stream (local debugging; never in production).
    const log = process.env.INKY_PROXY_LOG ? fs.createWriteStream(process.env.INKY_PROXY_LOG, { flags: "a" }) : null;
    log?.write(`\n=== ${new Date().toISOString()} ${req.method} ${req.url} ${response.status}\n`);
    if (response.body) {
      try {
        for await (const chunk of response.body as unknown as AsyncIterable<Uint8Array>) {
          res.write(chunk);
          log?.write(chunk);
        }
      } catch {
        // client went away or upstream aborted
      }
    }
    res.end();
    log?.end();
    console.log(`${req.method} ${req.url} -> ${response.status} (${Date.now() - started} ms)`);
  });
}

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (isMain) {
  const env = loadRepoEnv();
  const port = Number(process.env.PORT ?? 8787);
  const host = process.env.INKY_PROXY_HOST ?? "127.0.0.1";
  createServer(env).listen(port, host, () => {
    console.log(`Hey Inky proxy listening on http://${host}:${port} (key ${env.OpenAI_API_Key ? "loaded" : "MISSING"})`);
  });
}
