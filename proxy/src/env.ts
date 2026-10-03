import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { ProxyEnv } from "./handler.ts";

export const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

/** Reads the repo-root .env (exact variable name `OpenAI_API_Key`); process env wins. */
export function loadRepoEnv(envPath = path.join(REPO_ROOT, ".env")): ProxyEnv {
  const fromFile: Record<string, string> = {};
  if (fs.existsSync(envPath)) {
    for (const line of fs.readFileSync(envPath, "utf8").split(/\r?\n/)) {
      const match = line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$/);
      if (!match) continue;
      let value = match[2];
      if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
        value = value.slice(1, -1);
      }
      fromFile[match[1]] = value;
    }
  }
  const pick = (name: string) => process.env[name] ?? fromFile[name] ?? undefined;
  return {
    OpenAI_API_Key: pick("OpenAI_API_Key"),
    INKY_PROXY_TOKEN: pick("INKY_PROXY_TOKEN"),
    INKY_MODEL: pick("INKY_MODEL"),
  };
}
