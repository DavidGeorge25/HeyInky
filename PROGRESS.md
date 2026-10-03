# Progress

_Last updated: 2026-10-03 (foundation session)._

## Status: foundation complete ✅
- App builds with **zero warnings** (Swift 6, strict concurrency) and runs on the iPad simulator.
- **Unit tests:** 49 Swift Testing tests green (schema decoding, schema⇄Swift sync, stream parsing,
  prompt builder, proxy client, mock client, store/persistence, PDF import + text extraction, image
  insert, renderers, Inky layer placement/move/hide, session apply/error paths, localization, markdown).
- **UI tests:** 3 XCUITests green (mock client): summon Inky → ask → highlight/circle/star/label/fillText
  + toast appear → select & delete one annotation; "explain" opens the sidebar with a play button;
  create notebook → draw → add page.
- **Proxy:** 14 Node tests green (handler, streaming server, token, error passthrough, strict-schema
  rules, `type`-first ordering, fixtures validate with Ajv). `npm run smoke` passes against real OpenAI.
- **Live end-to-end** (`LiveProxyIntegrationTests`, opt-in): the real app pipeline renders the sample
  lecture page, sends it through the proxy, and "highlight the title of this page" lands on the title
  (IoU 0.75–0.79 vs. the true title box) in ~1.5–3 s.

## What's built
| Area | Done |
|---|---|
| Project | XcodeGen `App/project.yml`; app + unit + UI test targets; module folders globbed in |
| Library | Notebook grid with live thumbnails, new notebook (blank/lined/grid/dotted), import PDF as notebook, rename/delete, sample notebook on first launch |
| Notebook | PencilKit canvas with zoom, tool picker, undo/redo, page strip, prev/next, add page (paper styles), delete page, import PDF into notebook, insert image (Photos/Files) with move/resize/delete, autosave (debounced + on background/page switch) |
| Inky summon | Floating Inky button, Pencil Pro squeeze (anchored at hover), custom Inky tool-picker item, lasso a region for context, minimal ask popover (text + on-device voice), thinking state, cancel |
| AI | `InkyModelClient` protocol, `ProxyInkyModelClient` (SSE, incremental actions), `MockInkyModelClient`, prompt builder, grid-overlay localization + PDF text + Vision OCR |
| Inky layer | Renderers for highlight, circle, star, label (+arrow), fillText (handwriting font); stub cards for molecule/graph; select → edit / hide / delete; drag to move; layer menu with per-annotation visibility and clear; persisted per page |
| Replies | `say` toast; `openSidebar` Markdown explainer with play/pause TTS |
| Proxy | Node/TS server + Worker entry, `.env` loading, optional shared token, field allow-list, `store:false` |

## Known gaps / follow-ups for the lead
- App icon artwork is empty (asset slot exists).
- Simulator can't test real Pencil squeeze / hover; verify on device (`-InkyProxyURL http://<mac-ip>:8787`,
  proxy with `INKY_PROXY_HOST=0.0.0.0`).
- PDF pages with rotation: rendered correctly, but text-layer boxes are skipped (OCR covers them).
- One page on screen at a time (no continuous vertical scroll yet).
- Annotations don't scale with the page if a page's size changes (not currently possible).
- No iCloud sync, search, or export yet.

## Next steps per module agent
- **AICore** (`App/Modules/AICore/README.md`): "Sign in with ChatGPT" client (one file + factory switch),
  follow-up turns/conversation memory, an IoU eval set for localization tuning, image cost/latency tuning.
- **Chemistry** (`App/Modules/Chemistry/README.md`): replace `MoleculeCardView` stub with bundled RDKit.js
  rendering + SMARTS highlight/star, Ketcher editing, offline assets, tests.
- **Graphs** (`App/Modules/Graphs/README.md`): replace `GraphCardView` stub with bundled JSXGraph,
  sliders/draggable points, safe expression compilation, persist interactive state, tests.
- **InkyCharacter** (`App/Modules/InkyCharacter/README.md`): final Inky art + per-state motion,
  Reduce Motion support.
