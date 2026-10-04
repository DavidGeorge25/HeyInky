# Hey Inky

An AI-native handwritten notes app for iPad, for STEM students. Write with Apple Pencil, import
lecture slides and worksheets, and summon **Inky**, an AI pen that tutors you *on the page*: it hops
over and highlights, circles and labels what matters, draws with real ink (missing hydrogens, mechanism
arrows, diagrams, graph sketches), writes out worked steps in handwriting, fills in blanks, adds
interactive molecule and graph cards, and starts a fresh page when the work needs room. A read-aloud
sidebar is there for the rare "give me notes" request.

## Using it
- **Ask Inky:** tap the Inky button (bottom right), squeeze Apple Pencil Pro, or pick Inky in the tool bar.
  Type or tap the mic. Circle part of the page first to point Inky at it.
- **Select tool** (lasso icon in the tool bar): lasso or tap ink, images, text and Inky's marks → drag to
  move, corner handle to resize, Copy / Cut / Duplicate / Delete, **Ask Inky** about just the selection,
  **Convert to Text** (handwriting → typed), **Make it my ink** (Inky's drawing → your strokes). Tap empty
  paper to paste.
- **Text tool** (Aa): tap to type; size, typed/handwriting style and color in the bar above the text.
- **Shapes:** draw a line, circle, triangle, rectangle or polygon and **hold** the pen at the end — it snaps
  clean (More → Shape Correction to turn off).
- **Undo** covers ink, Inky's answers (one step each) and every edit; the ✨ menu hides Inky's layer.
- **More → Export PDF** (with or without Inky's marks) to share.

```
App/      iPadOS app (SwiftUI + PencilKit, Swift 6, iPadOS 18+), modules for AI, chemistry, graphs, Inky
proxy/    Node 22 proxy that holds the OpenAI key (also deployable as a Cloudflare Worker)
shared/   the InkyAction JSON schema, Inky's system prompt, shared test fixtures
evals/    offline accuracy evals for Inky (synthetic pages → proxy → scored)
```

## Requirements
- macOS with **Xcode 26** (iOS 26 simulator SDK; the app targets iPadOS 18+)
- `brew install xcodegen`
- **Node 22+** for the proxy
- An OpenAI API key in the repo-root `.env` (never committed):
  ```
  OpenAI_API_Key=sk-...
  # optional: INKY_PROXY_TOKEN=<shared secret>, INKY_PROXY_HOST=0.0.0.0 (to reach it from an iPad)
  ```

## Run it
```bash
# 1. Proxy: reads ../.env, listens on http://127.0.0.1:8787
cd proxy && npm install && npm start
#    check it:  curl http://127.0.0.1:8787/health   ·   npm run smoke  (one real OpenAI round trip)

# 2. App
cd App && xcodegen generate && open HeyInky.xcodeproj
#    pick an iPad simulator (e.g. iPad Pro 11-inch (M5)) and Run
```
Open **Welcome to Hey Inky**, tap the Inky button (bottom right) and ask "highlight the title of this
page". Draw a loop around something first to point Inky at it.

**Offline / demo mode:** add the launch argument `-InkyUseMockClient YES` (scheme → Run → Arguments) for
canned answers without the proxy.

### On a real iPad
1. In `.env` set `INKY_PROXY_HOST=0.0.0.0` (and ideally `INKY_PROXY_TOKEN=<secret>`), then `npm start`.
2. In the scheme's Run arguments: `-InkyProxyURL http://<your-mac-ip>:8787` (and `-InkyProxyToken <secret>`).
3. Select your iPad as the run destination (signing team required) and Run. Mac and iPad must share a network.

### Launch arguments
| Argument | Effect |
|---|---|
| `-InkyUseMockClient YES` | canned Inky answers, no network |
| `-InkyProxyURL <url>` / `-InkyProxyToken <t>` | where the proxy is / its shared token |
| `-InkyModel <name>` | override the model (default in `InkyConfig`) |
| `-InkyReasoning <low\|medium\|high>` | force the reasoning effort (default: medium for draw/solve/explain, low otherwise) |
| `-InkyUITestReset YES` | fresh temporary library with the sample notebook |
| `-InkySkipSample YES` | don't create the sample notebook |
| `-InkyMotionScale 3` | slow Inky's animations down (recordings) |
| DEBUG: `-InkyUITestScenario molecule,asymptotes,worksheet,skeleton` | seed QA notebooks (handwritten structure via `-InkyUITestImage <png>`, a PDF slide with a rational function, a worksheet with blank boxes, a pen-drawn methylcyclohexane) |
| DEBUG: `-InkyUITestLibrary <name>` | fixed temp library that survives relaunch |
| DEBUG: `-InkyUITestSpeech "<text>"` | the mic "hears" this text (simulator voice flow) |

## Test
```bash
DEST='platform=iOS Simulator,name=iPad Pro 11-inch (M5)'
cd App && xcodegen generate && cd ..

# Everything (unit + UI, mock client, offline)
xcodebuild test -project App/HeyInky.xcodeproj -scheme HeyInky -destination "$DEST" -derivedDataPath App/build/DerivedData

# Unit tests only
xcodebuild test ... -only-testing:HeyInkyTests

# End-to-end flows against the real proxy + OpenAI (start the proxy first; a few cents)
TEST_RUNNER_INKY_LIVE=1 xcodebuild test ... -only-testing:HeyInkyUITests/EndToEndUITests
TEST_RUNNER_INKY_LIVE=1 xcodebuild test ... -only-testing:HeyInkyUITests/InkyTutorUITests
#   TEST_RUNNER_INKY_MODEL=gpt-5.4 / TEST_RUNNER_INKY_REASONING=medium to compare
TEST_RUNNER_INKY_LIVE=1 xcodebuild test ... -only-testing:HeyInkyTests/LiveProxyIntegrationTests
#   add TEST_RUNNER_INKY_UI_SHOTS=/tmp/shots to save a screenshot per step

# Proxy
cd proxy && npm run check        # typecheck + tests

# Evals (see evals/README.md)
```
`EndToEndUITests` covers: functional groups on a handwritten molecule → molecule card with highlights;
"label the asymptotes" on an imported PDF slide → graph card with labeled asymptotes and a working
slider; "fill these in" on a worksheet; a long explanation → sidebar + read aloud; a voice question;
undo / redo / delete / hide the Inky layer and relaunch. `InkyTutorUITests` covers Inky drawing the
hidden hydrogens on a pen-drawn structure, working a problem on a new page, explaining on the page, and
the Select tool (move, undo, Ask Inky, Make it my ink). `NotebookToolsUITests` covers the text tool,
draw-and-hold shapes and PDF export.

**API quota:** the OpenAI org this was built with allows 50 requests/day per model; when a model is used up
Inky says it's "getting too many questions" — use `-InkyModel` with another model.

If tests fail with "Application failed preflight checks / Busy", the simulator is wedged:
`xcrun simctl shutdown all && xcrun simctl erase <udid>`.

## Docs
[CLAUDE.md](CLAUDE.md) architecture and conventions · [DECISIONS.md](DECISIONS.md) why things are the way
they are · [PROGRESS.md](PROGRESS.md) status and what needs a real iPad · [INTERFACE_REQUESTS.md](INTERFACE_REQUESTS.md)
cross-module requests · module READMEs in `App/Modules/*/README.md`.
