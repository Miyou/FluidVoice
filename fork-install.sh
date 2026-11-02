#!/bin/bash
# Fork-only: download the latest "Fork Build" artifact, re-sign it with the local Apple
# Development identity (so macOS permissions survive updates), and place it at $DEST.
# The official /Applications/FluidVoice.app is never touched.
#
# Usage: ./fork-install.sh [run-id]

set -euo pipefail

REPO="${FLUIDVOICE_FORK_REPO:-Miyou/FluidVoice}"
DEST_DIR="${FLUIDVOICE_FORK_DEST:-$HOME/Applications/FluidVoice Fork}"
BRANCH="${FLUIDVOICE_FORK_BRANCH:-fork-daily}"
RUN_ID="${1:-}"

if [ -z "${RUN_ID}" ]; then
    RUN_ID="$(gh run list -R "${REPO}" --workflow fork-build.yml --branch "${BRANCH}" --status success --limit 1 --json databaseId --jq '.[0].databaseId')"
fi
[ -n "${RUN_ID}" ] || { echo "No successful Fork Build run found." >&2; exit 1; }

IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.* \([[:xdigit:]]\{40\}\) "Apple Development:.*/\1/p' | head -1)"
[ -n "${IDENTITY}" ] || { echo "No Apple Development signing identity found." >&2; exit 1; }

WORK="$(mktemp -d -t fluidvoice-fork)"
trap 'rm -rf "${WORK}"' EXIT

echo "Downloading run ${RUN_ID} from ${REPO}..."
gh run download "${RUN_ID}" -R "${REPO}" --dir "${WORK}/artifact"
ARTIFACT="$(find "${WORK}/artifact" -name FluidVoice.app.zip -print -quit)"
OUT="$(dirname "${ARTIFACT}")"
ditto -x -k "${ARTIFACT}" "${WORK}/app"
APP="${WORK}/app/FluidVoice.app"
echo "Built with: $(cat "${OUT}/xcode-version.txt")"
echo "Commit:     $(cat "${OUT}/commit.txt")"

# Nested code first, then the app, mirroring upstream's PR Archive signing order.
codesign --force --sign "${IDENTITY}" --timestamp=none "${APP}/Contents/Frameworks/CTranscribe.framework"
codesign --force --sign "${IDENTITY}" --timestamp=none "${APP}/Contents/Frameworks/MediaRemoteAdapter.framework"
codesign --force --sign "${IDENTITY}" --timestamp=none --options runtime "${APP}/Contents/Helpers/fv-serve"
codesign --force --sign "${IDENTITY}" --timestamp=none --options runtime \
    --entitlements "${OUT}/FluidVoice.entitlements" "${APP}"
codesign --verify --deep --strict "${APP}"

mkdir -p "${DEST_DIR}"
if pgrep -f "${DEST_DIR}/FluidVoice.app/Contents/MacOS/FluidVoice" > /dev/null; then
    echo "Quit the running fork build first." >&2
    exit 1
fi
rm -rf "${DEST_DIR}/FluidVoice.app"
ditto "${APP}" "${DEST_DIR}/FluidVoice.app"
echo "Installed: ${DEST_DIR}/FluidVoice.app"
