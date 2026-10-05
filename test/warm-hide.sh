#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d /tmp/mlqs-warm-hide.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
ui=${MLQS_UI_ROOT:-$repo/ui}
cp -R "$ui" "$tmp/ui"
chmod -R u+w "$tmp/ui"
cp "$ui/shell.qml" "$tmp/ui/MlqsWindow.qml"
cp "$repo/test/warm-hide.qml" "$tmp/ui/shell.qml"
printf '\nMlqsWindow MlqsWindow.qml\n' >> "$tmp/ui/qmldir"
mkdir -m 700 "$tmp/runtime" "$tmp/home" "$tmp/bin"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/mlqs-daemon-ensure"
chmod +x "$tmp/bin/mlqs-daemon-ensure"
imports="$HOME/.local/share/qml:$tmp/ui/vendor${QML_IMPORT_PATH:+:$QML_IMPORT_PATH}"
if ! env -u WAYLAND_DISPLAY -u DISPLAY HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/runtime" \
    PATH="$tmp/bin:$PATH" QT_QPA_PLATFORM=offscreen \
    QML_IMPORT_PATH="$imports" QML2_IMPORT_PATH="$imports" \
    timeout 12s dbus-run-session -- quickshell -p "$tmp/ui" > "$tmp/output.log" 2>&1; then
    tail -30 "$tmp/output.log"
    exit 1
fi
grep 'PASS: cold show' "$tmp/output.log"
