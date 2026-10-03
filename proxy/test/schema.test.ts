import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import Ajv from "ajv";
import { REPO_ROOT } from "../src/env.ts";

const schemaPath = path.join(REPO_ROOT, "shared/inky_actions.schema.json");
const fixturesDir = path.join(REPO_ROOT, "shared/fixtures");
const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8"));

type Node = Record<string, unknown>;

/** OpenAI strict structured outputs: every object closes additionalProperties and requires all keys. */
function strictViolations(node: unknown, where: string, out: string[] = []): string[] {
  if (Array.isArray(node)) {
    node.forEach((child, i) => strictViolations(child, `${where}[${i}]`, out));
    return out;
  }
  if (typeof node !== "object" || node === null) return out;
  const obj = node as Node;
  if (obj.type === "object" || (Array.isArray(obj.type) && obj.type.includes("object"))) {
    if (obj.additionalProperties !== false) out.push(`${where}: additionalProperties must be false`);
    const keys = Object.keys((obj.properties as Node) ?? {}).sort();
    const required = [...((obj.required as string[]) ?? [])].sort();
    if (JSON.stringify(keys) !== JSON.stringify(required)) out.push(`${where}: required ${required} != properties ${keys}`);
  }
  for (const [key, value] of Object.entries(obj)) strictViolations(value, `${where}.${key}`, out);
  return out;
}

const ajv = new Ajv.default({ allErrors: true, strict: false });
const validate = ajv.compile(schema);

test("schema is compatible with OpenAI strict mode", () => {
  assert.deepEqual(strictViolations(schema, "$"), []);
});

test("every action type is listed in the root anyOf", () => {
  const refs = (schema.properties.actions.items.anyOf as Array<{ $ref: string }>).map((r) => r.$ref.split("/").pop());
  const actionDefs = Object.entries(schema.$defs as Record<string, Node>)
    .filter(([, def]) => (def.properties as Node | undefined)?.type !== undefined)
    .map(([name]) => name);
  assert.deepEqual([...refs].sort(), [...actionDefs].sort());
  assert.equal(refs.length, 9);
});

test("valid fixtures validate", () => {
  for (const name of ["all_actions.json", "highlight_title.json"]) {
    const data = JSON.parse(fs.readFileSync(path.join(fixturesDir, name), "utf8"));
    assert.ok(validate(data), `${name}: ${ajv.errorsText(validate.errors)}`);
  }
});

test("invalid fixture is rejected", () => {
  const data = JSON.parse(fs.readFileSync(path.join(fixturesDir, "invalid_unknown_type.json"), "utf8"));
  assert.equal(validate(data), false);
});

test("out-of-range coordinates are rejected", () => {
  const bad = { actions: [{ type: "star", point: { x: 1.4, y: 0.2 } }] };
  assert.equal(validate(bad), false);
});
