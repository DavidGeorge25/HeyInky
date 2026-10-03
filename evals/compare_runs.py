#!/usr/bin/env python3
"""Prints a Markdown comparison table of eval runs (for RESULTS.md).

    evals/.venv/bin/python evals/compare_runs.py out/runs/<a> out/runs/<b> ...
"""
import json
import statistics
import sys
from pathlib import Path

KEYS = ["pass_rate", "type_accuracy", "region_hit_rate", "mean_iou", "point_hit_rate", "smiles_accuracy",
        "group_recall", "graph_accuracy", "fill_accuracy", "followup_accuracy", "valid_rate", "say_first_rate"]


def fmt(v):
    return "–" if v is None else (f"{v:.2f}" if isinstance(v, float) else str(v))


def latency(rows, key):
    vals = sorted(r["result"]["timeline"].get(key) for r in rows if r["result"]["timeline"].get(key) is not None)
    return statistics.median(vals) if vals else None


def main(paths):
    print("| run | cases | " + " | ".join(KEYS) + " | first say p50 (s) |")
    print("|---|---|" + "---|" * len(KEYS) + "---|")
    for p in paths:
        data = json.loads((Path(p) / "results.json").read_text())
        s = data["summary"]
        print(f"| {Path(p).name} | {s['cases']} | " + " | ".join(fmt(s.get(k)) for k in KEYS) +
              f" | {fmt(latency(data['rows'], 'first_say'))} |")


if __name__ == "__main__":
    main(sys.argv[1:])
