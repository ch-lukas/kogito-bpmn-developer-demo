#!/usr/bin/env bash
# Replace the project's approval.bpmn with the most recently downloaded copy.
# After editing in the BPMN Editor (http://localhost:8480), click Download in
# the toolbar, then run this script. Quarkus dev mode hot-reloads automatically.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
TARGET="$REPO_ROOT/workflow/src/main/resources/org/acme/travels/approval.bpmn"
DOWNLOADS="${DOWNLOADS_DIR:-$HOME/Downloads}"

SRC=$(ls -t "$DOWNLOADS"/approval*.bpmn 2>/dev/null | head -1 || true)
if [[ -z "$SRC" ]]; then
  echo "No approval*.bpmn found in $DOWNLOADS." >&2
  echo "Click 'Download' in the BPMN Editor first, then re-run." >&2
  exit 1
fi

cp "$SRC" "$TARGET"
echo "Imported: $SRC"
echo "Target:   $TARGET"
echo "Quarkus dev mode will hot-reload on the next request."
