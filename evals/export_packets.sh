#!/usr/bin/env bash
# Renders every eval case through the app's real context pipeline (grid overlay, Vision OCR,
# mark overlay, prompt builder) and writes request bodies to evals/out/packets/.
#   evals/export_packets.sh                       # all cases
#   INKY_EVAL_ONLY=notes_title,ws_arith_fill evals/export_packets.sh
#   INKY_EVAL_TUNING="fullPageLongEdge=1536" evals/export_packets.sh
#   SIM="iPad Pro 11-inch (M4)" or SIM_ID=<udid> to pick the simulator.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="platform=iOS Simulator,name=${SIM:-iPad Pro 11-inch (M5)}"
[[ -n "${SIM_ID:-}" ]] && DEST="id=$SIM_ID"

cd "$ROOT/App"
[[ -d HeyInky.xcodeproj ]] || xcodegen generate -q
OUT="${INKY_EVAL_OUT:-$ROOT/evals/out/packets}"
rm -rf "$OUT"
TEST_RUNNER_INKY_EVAL_DIR="$ROOT/evals" \
TEST_RUNNER_INKY_EVAL_ONLY="${INKY_EVAL_ONLY:-}" \
TEST_RUNNER_INKY_EVAL_TUNING="${INKY_EVAL_TUNING:-}" \
TEST_RUNNER_INKY_EVAL_OUT="$OUT" \
xcodebuild test -project HeyInky.xcodeproj -scheme HeyInky -destination "$DEST" \
  -derivedDataPath build/DerivedData -only-testing:HeyInkyTests/EvalPacketExportTests 2>&1 \
  | grep -E "error:|✘|passed|failed|TEST (SUCCEEDED|FAILED)" | tail -5
ls "$OUT"/*.json | grep -v meta | wc -l | xargs echo "packets:"
