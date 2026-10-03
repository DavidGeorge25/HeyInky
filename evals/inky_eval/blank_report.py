"""Offline check of on-device blank detection vs. expected answer boxes (no API calls).
    evals/.venv/bin/python -m inky_eval.blank_report   (from evals/)"""
import json
from pathlib import Path

from .score import iou

ROOT = Path(__file__).resolve().parents[1]


def main():
    cases = json.loads((ROOT / "cases.json").read_text())["cases"]
    tot = hit = fp = n = 0
    for c in cases:
        meta = ROOT / f"out/packets/{c['id']}.meta.json"
        if not meta.exists():
            continue
        n += 1
        blanks = json.loads(meta.read_text())["blanks"]
        want = [f["box"] for f in c["expect"].get("fill", [])]
        best = [max([iou(w, b) for b in blanks], default=0) for w in want]
        tot += len(want)
        hit += sum(b > 0.5 for b in best)
        extra = [b for b in blanks if all(iou(b, w) <= 0.5 for w in want)]
        fp += len(extra)
        if want or blanks:
            print(f"{c['id']:<28} want={len(want)} detected={len(blanks)} best={[round(b, 2) for b in best]} extra={len(extra)}")
    print(f"{n} cases: recall {hit}/{tot}, false positives {fp}")


if __name__ == "__main__":
    main()
