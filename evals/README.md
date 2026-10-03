# Inky evals

Measures whether Inky picks the right action and puts it in the right place, through the **same pipeline
the app uses**: the page is rendered with the grid overlay, OCR'd with Apple Vision, existing marks are
outlined, and the request body is built by `InkyPromptBuilder` — then sent through `/proxy` to OpenAI,
validated (+1 retry, like `ValidatingInkyModelClient`) and scored.

```
generate.py            synthetic pages (PIL + RDKit) + cases.json, ground truth from the drawing calls
pages/                 35 pages (PNG + text layer JSON): molecules, functions, diagrams, worksheets, notes
cases.json             45 cases: question, lasso, existing marks, conversation history, expectations
export_packets.sh      runs EvalPacketExportTests in the simulator -> out/packets/<case>.json (exact request bodies)
run_evals.py           sends packets through the proxy, validates, scores, writes out/runs/<stamp>/
inky_eval/             draw (page drawing), client (SSE + retry), validate (mirror of the Swift validator),
                       score (IoU, points, SMILES via RDKit, graph sampling, fill answers), overlay (debug PNGs)
tests/                 python unit tests (validator parity with /shared/fixtures/validation, scoring)
RESULTS.md             results, thresholds, what changed between iterations
```

## Run
```bash
python3 -m venv evals/.venv && evals/.venv/bin/pip install rdkit pillow numpy requests   # once
evals/.venv/bin/python evals/generate.py          # only after editing pages/cases
evals/export_packets.sh                           # after changing AICore localization / prompt builder
(cd proxy && npm start) &                         # proxy on :8787
evals/.venv/bin/python evals/run_evals.py         # all cases; exit 1 if a threshold is missed
evals/.venv/bin/python evals/run_evals.py --only notes_title,ws_arith_fill --model gpt-5.4 --reasoning low
evals/.venv/bin/python evals/run_evals.py --resume evals/out/runs/<stamp>   # finish a run cut short by quota
evals/.venv/bin/python -m unittest discover -s evals/tests
```
`run_evals.py` re-reads `shared/inky_system_prompt.md` by default, so prompt edits don't need a re-export
(`--prompt packet` uses the exported one). Failures get an overlay PNG in the run folder: green = expected
region, blue = expected point area, red = Inky's marks, orange = cards/label anchors, purple = lasso.

**Quota:** the current OpenAI org allows 50 requests per day per model, and requests rejected for the
per-minute token limit count too. The runner paces requests (`--workers 2 --min-interval 4` by default; use
`--workers 1 --min-interval 30` for 10k-TPM models), stops at the daily cap, and `--resume` finishes later.

## Case format
```jsonc
{
  "id": "ws_chem_lasso_one", "page": "ws_chem_typed", "category": "worksheet", "style": "typed",
  "question": "fill this one in",
  "lasso": [x, y, w, h] | null,          // normalized; exported as the lasso path + crop
  "pdfText": false,                      // true: use the page's text layer like a PDF (else Vision OCR)
  "existing": [{ "action": {…}, "question": "…" }],              // marks already on the page -> m1, m2, …
  "history": [{ "question": "…", "actions": [ … ], "created": [0] }],  // indices into existing
  "expect": {
    "types":   { "required": ["fillText"], "forbidden": ["openSidebar"] },
    "targets": [{ "types": ["highlight"], "regions": [[x,y,w,h], …alternatives], "minIoU": 0.5 }],
    "points":  [{ "types": ["star"], "region": [x,y,w,h], "keywords": ["fric"] }],   // or "segment"+"maxDist"
    "molecule": { "smiles": "CCO", "groups": ["[OX2H]"] },     // canonical SMILES match; groups covered by highlight/starGroups
    "graph":   { "fns": ["x**2 - 4*x + 3"], "asymptotes": [{ "orientation": "vertical", "value": 2 }], "mustShowX": [1, 3] },
    "fill":    [{ "box": [x,y,w,h], "answers": ["6"] }], "noFillIn": [[x,y,w,h]],
    "remove":  ["m2"], "sidebarKeywords": ["vertex"], "sayKeywords": ["ester"]
  }
}
```
A case passes when the request succeeded (after at most one retry) and every check present passes.
Regions: best IoU between any allowed-type action and any acceptable region; `minIoU` is 0.5 for text and
0.3 for parts of drawings (small targets, where a few points of padding move IoU a lot).
