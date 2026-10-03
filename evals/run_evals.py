#!/usr/bin/env python3
"""Runs the exported packets through the proxy, validates (+1 retry), scores, summarizes.

    (cd proxy && npm start) &                 # proxy on :8787
    evals/export_packets.sh                   # app pipeline -> evals/out/packets
    evals/.venv/bin/python evals/run_evals.py [--only id,id] [--repeat 2] [--model m] [--reasoning low]

By default the system prompt is re-read from shared/inky_system_prompt.md so prompt edits
don't need a re-export. Results: evals/out/runs/<timestamp>/ (results.json, summary.md,
overlay PNGs for failures). Exit code 1 if any threshold in THRESHOLDS is missed.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import statistics
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import threading

from inky_eval import client as inky_client
from inky_eval.client import QuotaExhausted, run_packet
from inky_eval.overlay import render
from inky_eval.score import score_case

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent

# Documented in evals/RESULTS.md. Rates are over all case runs.
THRESHOLDS = {
    "pass_rate": 0.80,
    "type_accuracy": 0.90,
    "region_hit_rate": 0.80,
    "mean_iou": 0.55,
    "point_hit_rate": 0.75,
    "smiles_accuracy": 0.80,
    "graph_accuracy": 0.80,
    "fill_accuracy": 0.80,
    "followup_accuracy": 0.80,
    "valid_rate": 1.00,
    "say_first_rate": 0.90,
}


def pct(xs, q):
    xs = sorted(xs)
    if not xs:
        return None
    k = (len(xs) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def rate(xs):
    xs = list(xs)
    return sum(1 for x in xs if x) / len(xs) if xs else None


def summarize(scored, results):
    s = {}
    s["cases"] = len(scored)
    s["pass_rate"] = rate(r["passed"] for r in scored)
    s["type_accuracy"] = rate(r["checks"].get("types") for r in scored)
    ious = [v for r in scored for v in r["detail"].get("ious", [])]
    s["mean_iou"] = statistics.mean(ious) if ious else None
    s["region_hit_rate"] = rate(r["checks"]["regions"] for r in scored if "regions" in r["checks"])
    s["point_hit_rate"] = rate(p for r in scored for p in r["detail"].get("points", []))
    s["smiles_accuracy"] = rate(r["checks"]["smiles"] for r in scored if "smiles" in r["checks"])
    s["group_recall"] = (statistics.mean(r["detail"]["molecule"]["groupRecall"] for r in scored if "molecule" in r["detail"])
                         if any("molecule" in r["detail"] for r in scored) else None)
    s["graph_accuracy"] = rate(r["checks"]["graph"] for r in scored if "graph" in r["checks"])
    s["fill_accuracy"] = rate(r["checks"]["fill"] for r in scored if "fill" in r["checks"])
    s["followup_accuracy"] = rate(r["passed"] for r in scored if r["category"] == "followup")
    s["valid_rate"] = rate(not r["error"] for r in scored)
    s["first_try_valid_rate"] = rate(res["attempts"] == 1 for res in results)
    s["retry_rate"] = rate(res["attempts"] > 1 for res in results)
    s["say_first_rate"] = rate(r["sayFirst"] for r in scored)
    for key in ("first_say", "first_mark", "first_token"):
        vals = [res["timeline"].get(key) for res in results if res["timeline"].get(key) is not None]
        s[f"{key}_p50"] = pct(vals, 0.5)
        s[f"{key}_p90"] = pct(vals, 0.9)
    totals = [res["total"] for res in results]
    s["total_p50"] = pct(totals, 0.5)
    s["total_p90"] = pct(totals, 0.9)
    toks = [u for res in results for u in res.get("usage") or [] if u]
    if toks:
        s["input_tokens_mean"] = statistics.mean(u.get("input_tokens", 0) for u in toks)
        s["output_tokens_mean"] = statistics.mean(u.get("output_tokens", 0) for u in toks)
        s["cached_tokens_mean"] = statistics.mean((u.get("input_tokens_details") or {}).get("cached_tokens", 0) for u in toks)
    by = {}
    for key in ("category", "style"):
        for r in scored:
            by.setdefault(f"{key}:{r[key]}", []).append(r["passed"])
    s["breakdown"] = {k: f"{sum(v)}/{len(v)}" for k, v in sorted(by.items())}
    return s


def fmt(v):
    if v is None:
        return "–"
    if isinstance(v, float):
        return f"{v:.2f}"
    return str(v)


def summary_md(s, scored, args):
    lines = [f"model `{args.model or 'default'}`, reasoning `{args.reasoning or 'default'}`, repeat {args.repeat}, {s['cases']} case runs", "",
             "| metric | value | threshold |", "|---|---|---|"]
    for k, v in s.items():
        if k == "breakdown":
            continue
        thr = THRESHOLDS.get(k)
        mark = "" if thr is None else (" ✅" if v is not None and v >= thr else " ❌")
        lines.append(f"| {k} | {fmt(v)}{mark} | {fmt(thr) if thr is not None else ''} |")
    lines += ["", "| slice | passed |", "|---|---|"] + [f"| {k} | {v} |" for k, v in s["breakdown"].items()]
    fails = [r for r in scored if not r["passed"]]
    if fails:
        lines += ["", "Failures:", ""]
        for r in fails:
            bad = [k for k, v in r["checks"].items() if not v]
            lines.append(f"- `{r['id']}` failed {bad or r['error']} — {json.dumps(r['detail'], ensure_ascii=False)[:300]}")
    return "\n".join(lines)


def strip_text_aids(body):
    """Ablation: remove the word@x lines and the detected-blanks block from the context text,
    and use the pre-word-position wording."""
    import re

    first = body["input"][0]["content"][0]
    text = first["text"]
    text = re.sub(r"\n   \S+@\.?\d.*", "", text)
    text = re.sub(r"\n\nEmpty boxes detected on the page[^\n]*(\n\[[^\n]*)*", "", text)
    text = text.replace(", each followed by where its words start (word@x):", ":")
    first["text"] = text
    return body


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--proxy", default="http://127.0.0.1:8787")
    ap.add_argument("--only")
    ap.add_argument("--category")
    ap.add_argument("--repeat", type=int, default=1)
    ap.add_argument("--model")
    ap.add_argument("--reasoning")
    ap.add_argument("--prompt", default=str(REPO / "shared/inky_system_prompt.md"), help="'packet' keeps the exported prompt")
    ap.add_argument("--workers", type=int, default=2)
    ap.add_argument("--min-interval", type=float, default=4.0, help="seconds between request starts (TPM pacing)")
    ap.add_argument("--no-retry", action="store_true")
    ap.add_argument("--label", default="")
    ap.add_argument("--packets", help="packet dir (default out/packets), e.g. an ablation export")
    ap.add_argument("--strip-text-aids", action="store_true", help="ablation: drop word@x lines and detected blanks from packets")
    ap.add_argument("--resume", help="a previous run dir: re-run only its cases that hit quota/proxy errors and merge")
    args = ap.parse_args()

    inky_client.MIN_INTERVAL[0] = args.min_interval
    cases = json.loads((ROOT / "cases.json").read_text())["cases"]
    if args.only:
        keep = set(args.only.split(","))
        cases = [c for c in cases if c["id"] in keep]
    if args.category:
        cases = [c for c in cases if c["category"] == args.category]
    previous = []
    if args.resume:
        prev_dir = Path(args.resume)
        for line in (prev_dir / "rows.jsonl").read_text().splitlines():
            row = json.loads(line)
            err = row["result"].get("error") or ""
            if not err.startswith(("model failed: rate_limit", "proxy")) and "rate_limit_exceeded" not in err:
                previous.append(row)
        done = {r["case"] for r in previous}
        cases = [c for c in cases if c["id"] not in done]
        print(f"resuming {prev_dir.name}: {len(done)} kept, {len(cases)} to run")
    packets = Path(args.packets) if args.packets else ROOT / "out/packets"
    instructions = None if args.prompt == "packet" else Path(args.prompt).read_text()

    jobs = [(c, i) for c in cases for i in range(args.repeat)]

    quota_hit = threading.Event()

    def work(job):
        c, i = job
        if quota_hit.is_set():
            return c, i, None
        body = json.loads((packets / f"{c['id']}.json").read_text())
        if args.strip_text_aids:
            body = strip_text_aids(body)
        try:
            res = run_packet(args.proxy, body, len(c["existing"]), model=args.model, instructions=instructions,
                             reasoning=args.reasoning, max_retries=0 if args.no_retry else 1)
        except QuotaExhausted as e:
            quota_hit.set()
            print(f"QUOTA {c['id']}: {str(e)[:200]}", flush=True)
            return c, i, None
        return c, i, res

    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S") + (f"-{args.label}" if args.label else "")
    out = ROOT / "out/runs" / stamp
    out.mkdir(parents=True, exist_ok=True)
    scored, results, rows, skipped = [], [], [], []
    with ThreadPoolExecutor(args.workers) as pool:
        jsonl = (out / "rows.jsonl").open("w")
        for c, i, res in pool.map(work, jobs):
            if res is None:
                skipped.append(c["id"])
                continue
            sc = score_case(c, res)
            scored.append(sc)
            results.append(res)
            rows.append({"case": c["id"], "run": i, "score": sc, "result": res})
            jsonl.write(json.dumps(rows[-1], ensure_ascii=False) + "\n")
            jsonl.flush()
            flag = "PASS" if sc["passed"] else "FAIL"
            print(f"{flag} {c['id']:<32} {res['total']:5.1f}s att={res['attempts']} {[k for k, v in sc['checks'].items() if not v] or ''} {sc['error'] or ''}", flush=True)
            if not sc["passed"]:
                render(ROOT / f"pages/{c['page']}.png", c, res["actions"], out / f"{c['id']}-{i}.png")

    for row in previous:
        scored.append(row["score"])
        results.append(row["result"])
        rows.append(row)
        jsonl.write(json.dumps(row, ensure_ascii=False) + "\n")
    if not scored:
        print("no results (quota?)")
        sys.exit(2)
    s = summarize(scored, results)
    s["skipped_quota"] = len(skipped)
    (out / "results.json").write_text(json.dumps({"summary": s, "rows": rows}, indent=1, ensure_ascii=False))
    md = summary_md(s, scored, args)
    (out / "summary.md").write_text(md)
    print()
    print(md)
    print(f"\nwrote {out}")
    missed = [k for k, t in THRESHOLDS.items() if s.get(k) is not None and s[k] < t]
    sys.exit(1 if missed else 0)


if __name__ == "__main__":
    main()
