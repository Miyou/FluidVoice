#!/bin/bash
# Fork-only: download the latest "Fork Build" artifact, re-sign it with the local Apple
# Development identity (so macOS permissions survive updates), and install it as
# /Applications/FluidVoice.app, so every launch path (Dock, Spotlight, "Quit & Reopen") opens it.
# An official build found there is first zipped to ~/Applications (a zip, not a second app with the
# same bundle ID that macOS could launch instead).
#
# Usage: ./fork-install.sh [run-id]

set -euo pipefail

REPO="${FLUIDVOICE_FORK_REPO:-Miyou/FluidVoice}"
DEST_DIR="${FLUIDVOICE_FORK_DEST:-/Applications}"
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
if pgrep -f "FluidVoice.app/Contents/MacOS/FluidVoice" > /dev/null; then
    echo "Quit FluidVoice first." >&2
    exit 1
fi
TARGET="${DEST_DIR}/FluidVoice.app"
if [ -d "${TARGET}" ]; then
    MY_TEAM="$(codesign -dv "${APP}" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    THEIR_TEAM="$(codesign -dv "${TARGET}" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    if [ "${THEIR_TEAM}" != "${MY_TEAM}" ]; then
        VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${TARGET}/Contents/Info.plist")"
        BACKUP="$HOME/Applications/FluidVoice-official-${VERSION}.zip"
        mkdir -p "$HOME/Applications"
        ditto -c -k --keepParent "${TARGET}" "${BACKUP}"
        echo "Backed up official ${VERSION} to ${BACKUP}"
    fi
    rm -rf "${TARGET}"
fi
ditto "${APP}" "${TARGET}"
echo "Installed: ${TARGET}"
