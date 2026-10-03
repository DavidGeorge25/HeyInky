// End-to-end smoke test against a running proxy and the real OpenAI API.
//   npm start            (in another terminal)
//   npm run smoke        (optionally: PROXY_URL=http://127.0.0.1:8787 MODEL=gpt-5.4-mini)
// Sends a text-only page description with the same prompt + schema the app uses,
// parses the SSE stream, validates the result against the schema, and checks the
// highlight lands on the title.
import fs from "node:fs";
import path from "node:path";
import Ajv from "ajv";
import { REPO_ROOT } from "../src/env.ts";

const proxyURL = process.env.PROXY_URL ?? "http://127.0.0.1:8787";
const schema = JSON.parse(fs.readFileSync(path.join(REPO_ROOT, "shared/inky_actions.schema.json"), "utf8"));
const instructions = fs.readFileSync(path.join(REPO_ROOT, "shared/inky_system_prompt.md"), "utf8");
delete schema.$comment;

const title = { x: 0.1, y: 0.06, width: 0.62, height: 0.045 };
const pageText = [
  `[${title.x}, ${title.y}, ${title.width}, ${title.height}] "Lecture 7: Chemical Equilibrium"`,
  `[0.1, 0.16, 0.7, 0.03] "Le Chatelier's principle: a system at equilibrium shifts to oppose a change."`,
  `[0.1, 0.22, 0.5, 0.03] "K = [C]^c[D]^d / [A]^a[B]^b"`,
].join("\n");

const body = {
  model: process.env.MODEL,
  instructions,
  input: [
    {
      role: "user",
      content: [
        { type: "input_text", text: `Recognized text (normalized x, y, width, height):\n${pageText}` },
        { type: "input_text", text: "Student: highlight the title of this page" },
      ],
    },
  ],
  text: { format: { type: "json_schema", name: "inky_actions", strict: true, schema } },
};

const started = Date.now();
const res = await fetch(`${proxyURL}/inky`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify(body),
});
if (!res.ok || !res.body) {
  console.error(`Proxy returned ${res.status}: ${await res.text()}`);
  process.exit(1);
}

let buffer = "";
let output = "";
let firstDeltaMs: number | undefined;
const decoder = new TextDecoder();
for await (const chunk of res.body as unknown as AsyncIterable<Uint8Array>) {
  buffer += decoder.decode(chunk, { stream: true });
  let idx: number;
  while ((idx = buffer.indexOf("\n\n")) >= 0) {
    const block = buffer.slice(0, idx);
    buffer = buffer.slice(idx + 2);
    const data = block
      .split("\n")
      .filter((l) => l.startsWith("data:"))
      .map((l) => l.slice(5).trim())
      .join("\n");
    if (!data || data === "[DONE]") continue;
    const event = JSON.parse(data);
    if (event.type === "response.output_text.delta") {
      firstDeltaMs ??= Date.now() - started;
      output += event.delta;
    } else if (event.type === "error" || event.type === "response.failed") {
      console.error("Stream error:", JSON.stringify(event));
      process.exit(1);
    }
  }
}

const parsed = JSON.parse(output);
const ajv = new Ajv.default({ strict: false });
if (!ajv.validate(schema, parsed)) {
  console.error("Schema validation failed:", ajv.errorsText());
  process.exit(1);
}
console.log(JSON.stringify(parsed, null, 2));
console.log(`first token ${firstDeltaMs} ms, total ${Date.now() - started} ms`);

const highlight = parsed.actions.find((a: { type: string }) => a.type === "highlight");
if (!highlight) {
  console.error("FAIL: no highlight action");
  process.exit(1);
}
const r = highlight.region;
const ix = Math.max(0, Math.min(r.x + r.width, title.x + title.width) - Math.max(r.x, title.x));
const iy = Math.max(0, Math.min(r.y + r.height, title.y + title.height) - Math.max(r.y, title.y));
const inter = ix * iy;
const iou = inter / (r.width * r.height + title.width * title.height - inter);
console.log(`highlight IoU with title: ${iou.toFixed(2)}`);
if (iou < 0.5) {
  console.error("FAIL: highlight does not cover the title");
  process.exit(1);
}
console.log("PASS");
