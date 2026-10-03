// Cloudflare Worker entry. Deploy later with `wrangler deploy` (see wrangler.toml);
// set the key with `wrangler secret put OpenAI_API_Key`.
import { handleRequest, type ProxyEnv } from "./handler.ts";

export default {
  fetch(request: Request, env: ProxyEnv): Promise<Response> {
    return handleRequest(request, { ...env, fetch: undefined });
  },
};
