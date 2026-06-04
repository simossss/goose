#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE="${PACKAGE:-com.goose.android}"
MARKER_FILE="${GOOSE_ANDROID_LOGCAT_MARKER_FILE:-/sdcard/goose-evidence-start-marker.txt}"

if [[ -z "${ADB:-}" && -x "$HOME/Library/Android/sdk/platform-tools/adb" ]]; then
  ADB="$HOME/Library/Android/sdk/platform-tools/adb"
fi
ADB="${ADB:-adb}"

usage() {
  cat <<'USAGE'
Usage: Scripts/prepare_android_phone_evidence.sh

Prepares a connected Android phone for a scoped Goose evidence run:
- selects exactly one adb device, unless ANDROID_SERIAL is set
- clears logcat
- writes a unique Goose evidence start marker to logcat and /sdcard

Run this immediately before the controlled WHOOP capture. The final phone gate
requires the marker so AndroidRuntime crash evidence is scoped to this run.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if ! command -v "$ADB" >/dev/null 2>&1; then
  echo "adb not found. Set ADB or add Android platform-tools to PATH." >&2
  exit 1
fi

device_serial="${ANDROID_SERIAL:-}"
if [[ -z "$device_serial" ]]; then
  devices=()
  while IFS= read -r serial; do
    devices+=("$serial")
  done < <("$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1 }')
  if [[ "${#devices[@]}" -eq 1 ]]; then
    device_serial="${devices[0]}"
  elif [[ "${#devices[@]}" -eq 0 ]]; then
    echo "No adb device online. Enable USB debugging and accept the phone trust prompt." >&2
    exit 1
  else
    echo "Multiple adb devices are online. Set ANDROID_SERIAL to one of:" >&2
    printf '  %s\n' "${devices[@]}" >&2
    exit 1
  fi
fi

device_state="$("$ADB" -s "$device_serial" get-state 2>/dev/null || true)"
if [[ "$device_state" != "device" ]]; then
  echo "adb target is not online: $device_serial ($device_state)" >&2
  exit 1
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
marker="goose-evidence-start $stamp $PACKAGE $device_serial"

echo "==> Clearing logcat on $device_serial"
"$ADB" -s "$device_serial" logcat -c
printf '%s\n' "$marker" | "$ADB" -s "$device_serial" shell "cat > '$MARKER_FILE'"
"$ADB" -s "$device_serial" shell log -t GooseEvidenceStart "$marker"

cat <<NEXT_STEPS
==> Goose evidence start marker written
Device: $device_serial
Marker: $marker
Marker file: $MARKER_FILE

Now run the controlled WHOOP capture and then collect evidence with:
  Scripts/android_final_pr_gate.sh tmp/android-phone-final-gate-real --skip-validate
NEXT_STEPS
