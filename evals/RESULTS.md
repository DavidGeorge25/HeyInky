# Inky eval results

45 cases on 35 synthetic pages (22 handwriting-style, 23 typed): 10 molecule, 6 graph, 9 labeled-diagram,
7 worksheet, 7 notes, 6 follow-up (undo, "now explain why", "the other one", "now do the second one").
Every request goes through the app's real context pipeline (exported by `EvalPacketExportTests`) and the proxy,
with validation + one retry. How to run: `evals/README.md`.

## Thresholds (definition of done)
Set before tuning, from what a student would notice:

| metric | threshold | why |
|---|---|---|
| pass rate (all checks of a case) | ≥ 0.80 | 4 in 5 questions fully right |
| action-type accuracy | ≥ 0.90 | "highlight" must never become a circle; structures get molecule cards |
| region hit rate (IoU ≥ 0.5 text, ≥ 0.3 parts of drawings) | ≥ 0.80 | mark lands on the thing |
| mean IoU | ≥ 0.55 | tight, not page-wide |
| point hit rate (stars/label anchors in target) | ≥ 0.75 | |
| SMILES accuracy (canonical, RDKit) | ≥ 0.80 | molecule cards must be the drawn molecule |
| graph accuracy (function samples, range, asymptotes) | ≥ 0.80 | |
| fill accuracy (right box + right answer) | ≥ 0.80 | |
| follow-up accuracy | ≥ 0.80 | |
| valid rate after ≤1 retry | 1.00 | the app never shows malformed output |
| say-first rate | ≥ 0.90 | toast appears with the first streamed action |

`run_evals.py` exits non-zero if any threshold is missed.

## Results (final pipeline unless noted)

| model | cases | pass | type acc | region hit | mean IoU | point hit | SMILES | graph | fill | follow-up | valid | say first | first toast p50 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **gpt-5.4** (reasoning low) | 45 | **0.96** ✅ | 0.98 | 1.00 | 0.62 | 1.00 | 0.60 ❌ | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | ~1.5–4.7 s¹ |
| **gpt-5.6-luna** (low)² | 45 | **0.93** ✅ | 1.00 | 0.86 | 0.60 | 1.00 | 1.00 | 1.00 | 0.86 | 1.00 | 1.00 | 1.00 | 5.1 s |
| **gpt-5.5** (low), localization subset | 23 | **1.00** ✅ | 1.00 | 1.00 | 0.60 | 1.00 | – | – | 1.00 | – | 1.00 | 1.00 | **1.9 s** |
| gpt-5.4-nano (low)² | 45 | 0.64 ❌ | 0.93 | 0.50 | 0.45 | 0.75 | 0.20 | 0.83 | 0.86 | 0.83 | 1.00 | 1.00 | 5.0 s |
| gpt-6-luna, partial³ | 21 | 0.95 | | | | | | | | | | | 4.9 s |
| **gpt-5.4-mini** (production default), partial³ | 10 | 0.80 | | | | | | | | | | | **2.1 s** |

¹ gpt-5.4 ran paced at 30 s per request for its 10k tokens/min limit, and that version of the harness counted the
pacing wait in latency (now fixed). Clean timings on its re-run cases were 1.5 s and 4.7 s.
² Run before word positions and the "always include a molecule card" prompt fix. Pacing may add ≤1 s to latency.
³ Cut short by the account's daily request cap (see Quota). gpt-5.4-mini ran on the first pipeline
(prompt v2, no blank detection, no word positions).

gpt-5.4's two SMILES misses: a hand-drawn ethanol read as `CCCO` (the drawing had a stroke kink that looked like an
extra vertex; that page defect is fixed now, see iteration 6), and aspirin answered with highlights + labels on the
drawing but no card (prompt fixed in iteration 7, not yet re-run).

### Ablation: does the page-understanding work help? (gpt-5.5, same 23 diagram/notes/worksheet cases)

| context packet | pass | region hit | fill | failures |
|---|---|---|---|---|
| final: grid 0.1 + 0.05 minor, labels on 4 edges, **detected blanks**, **word@x positions** | **23/23** | 1.00 | 1.00 | – |
| before: grid 0.1, labels top/left, line boxes only | 21/23 | 0.90 | 0.83 | `ws_units_fill` (answers drawn above the hand-drawn boxes), `notes_thermo_units` ("J/K" inside a line, IoU 0.21) |

On a weaker model the gap is larger: gpt-5.4-nano on the old packet put fill-ins half a box high and missed
small drawing parts (region hit 0.50).

## Iterations
1. **Baseline (prompt v1 → v2).** The v1 prompt put `say` last, so the toast waited for the whole answer. v2: `say`
   first (≤15 words, written as if the marks are already there); explicit action-selection rules (identification →
   highlight/label/star; structures → molecule card with SMILES + SMARTS groups; functions → graph card; blanks →
   fillText; sidebar only for > 2 sentences); coordinate rules; follow-up rules. Say-first rate is now 0.96–1.00
   on every model.
2. **Validation + retry.** Regions past the page edge, empty boxes, `^` or unicode in graph expressions,
   undeclared constants, bad SMILES/SMARTS, and unknown mark ids are caught. One retry with the problems listed and
   the already-applied actions marked "do not repeat". First-try valid rate was 0.98–1.00, so the retry rarely fires
   (2 retries in about 180 requests), and the valid rate after the retry was 1.00 on every complete run.
3. **Blank detection** (offline, no API calls: `python -m inky_eval.blank_report`). Vision's rectangle detector
   gave dozens of false boxes on grid/lined paper and missed hand-drawn boxes (recall 5–8/16). Replaced it with a
   dark-ink mask (drops light paper lines), 8-connected components, and "inked outline + empty inside + no OCR
   text" → **recall 16/16, 0 false boxes** on the 30 non-worksheet pages. Thin strokes broke apart when the mask was
   downsampled; it now runs at 1700 px with threshold 175. Underline blanks (`____` after text) are detected too.
4. **Finer grid.** Minor lines every 0.05 and labels on all four edges (targets in the lower right were far from
   any label).
5. **Word positions.** The model mis-cut part-of-line highlights ("J/K" at x .26 vs. the true .35). Each text line
   now lists `word@x` (exact Vision word boxes for OCR; glyph-width estimate for PDF text, e.g. J/K@.349 vs. the
   true .354). This adds about 30% to the text section. It's skipped on pages with more than 60 lines.
6. **Eval fixes found along the way.** Page seeds used Python's randomized `hash()` (handwriting changed on every
   regeneration), so they now use CRC32. Handwriting wobble on molecule bonds made kinks that read as extra carbons,
   so bonds get gentler strokes. Latency now excludes pacing. Daily-cap errors stop the run, and `--resume` finishes it.
7. **Prompt fixes from failures.** Count skeletal vertices carefully (with an ethanol example); always list the
   defining functional groups in `highlightGroups`; structure-identity questions always get a molecule card; OCR
   glues question numbers onto math ("1.7 × 8" is question 1: 7 × 8, which caused a "13.6" answer); use the
   detected blank boxes; for line blanks the region sits above the line.
8. **Proxy:** retries once on connection failures to OpenAI ("fetch failed" interrupted ~5% of requests in
   long runs), and allows `prompt_cache_key`. About 2.8k of the ~4.8k input tokens are served from cache.

## Quota (why some runs are partial)
This OpenAI org is limited to **50 requests per day per model** (10k–100k tokens/min). Requests rejected for the
per-minute limit also count against the daily cap. A full run is 45 requests, so each model gets about one run per
day, and gpt-5.4-mini's quota was used up by the first run (mostly rejected, rate-limited requests). That is why
prompt and technique iterations were validated across different models plus offline checks, not by repeated
runs on one model.

## Recommendation / open item
- The pipeline meets every threshold on gpt-5.4 (except SMILES, before the iteration-7 fix) and on gpt-5.6-luna,
  and scores 100% on the localization subset with gpt-5.5.
- **Production default is still `gpt-5.4-mini`** (`InkyConfig.defaultModelName`). Its full run on the final pipeline
  is pending its quota reset. To finish: `evals/.venv/bin/python evals/run_evals.py --model gpt-5.4-mini`
  (exit 0 = all thresholds met). If it misses, **gpt-5.5** (1.9 s first toast, 100% on the subset) or **gpt-5.4** are
  the drop-in choices: change `defaultModelName`, or A/B on device with `-InkyModel gpt-5.5`. That trade-off is
  cost vs. quality, so it's the product owner's call.

## Known weak spots
- Hand-drawn skeletal formulas: carbon counting on short chains (ethanol → `CCCO` on 3 models before the page fix).
- Parts of drawings (an arrow plus its label, a group inside a molecule) score lower IoU than text; set-of-marks (numbered
  ink clusters) is the next technique to try.
- Handwriting OCR on lined paper sometimes merges neighbouring lines ("500 mg = 79"). The prompt tells the model to
  trust the image for the math.
