#!/bin/bash
# Build ThermalWatch.app into .build/. With --install, copy it to ~/Applications and launch it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        *) echo "unknown arg: $arg" >&2; exit 1 ;;
    esac
done

arch -arm64 swift build -c release --package-path "$ROOT" --product ThermalWatch
BIN_DIR="$(arch -arm64 swift build -c release --package-path "$ROOT" --show-bin-path)"

STAGE="$ROOT/.build/ThermalWatch.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS"
cp "$BIN_DIR/ThermalWatch" "$STAGE/Contents/MacOS/ThermalWatch"
cp "$ROOT/Resources/Info.plist" "$STAGE/Contents/Info.plist"

# A stable self-signed identity keeps notification permission across rebuilds.
IDENTITY="-"
if security find-identity -p codesigning 2>/dev/null | grep -q '"KonaClaw Dev"'; then
    IDENTITY="KonaClaw Dev"
fi
codesign --force --sign "$IDENTITY" "$STAGE"
echo "[thermalwatch] built $STAGE (signed: $IDENTITY)"

if [[ $INSTALL -eq 1 ]]; then
    if pgrep -x ThermalWatch >/dev/null; then
        osascript -e 'quit app "ThermalWatch"' >/dev/null 2>&1 || true
        sleep 2
    fi
    mkdir -p "$HOME/Applications"
    rsync -a --delete "$STAGE/" "$HOME/Applications/ThermalWatch.app/"
    open "$HOME/Applications/ThermalWatch.app"
    echo "[thermalwatch] installed ~/Applications/ThermalWatch.app"
fi
