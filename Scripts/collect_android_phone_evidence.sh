#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_DIR="${1:-$APP_DIR/tmp/android-phone-evidence-$STAMP}"

if [[ -z "${ADB:-}" && -x "$HOME/Library/Android/sdk/platform-tools/adb" ]]; then
  ADB="$HOME/Library/Android/sdk/platform-tools/adb"
fi
ADB="${ADB:-adb}"

mkdir -p "$OUTPUT_DIR"

echo "Collecting Android phone evidence into $OUTPUT_DIR"

"$SCRIPT_DIR/android_port_status.sh" > "$OUTPUT_DIR/android-port-status.txt"

if ! command -v "$ADB" >/dev/null 2>&1; then
  echo "adb not found. Status snapshot was written, but device evidence was not collected." | tee "$OUTPUT_DIR/collect-error.txt"
  exit 1
fi

"$ADB" devices > "$OUTPUT_DIR/adb-devices.txt"

device_serial="${ANDROID_SERIAL:-}"
if [[ -z "$device_serial" ]]; then
  device_serial="$("$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')"
fi

if [[ -z "$device_serial" ]]; then
  echo "No adb device online. Status snapshot was written, but device evidence was not collected." | tee "$OUTPUT_DIR/collect-error.txt"
  exit 1
fi

echo "$device_serial" > "$OUTPUT_DIR/android-serial.txt"
"$ADB" -s "$device_serial" shell getprop ro.product.manufacturer > "$OUTPUT_DIR/device-manufacturer.txt" 2>&1 || true
"$ADB" -s "$device_serial" shell getprop ro.product.model > "$OUTPUT_DIR/device-model.txt" 2>&1 || true
"$ADB" -s "$device_serial" shell getprop ro.build.version.release > "$OUTPUT_DIR/android-version.txt" 2>&1 || true
"$ADB" -s "$device_serial" shell getprop ro.build.version.sdk > "$OUTPUT_DIR/android-sdk.txt" 2>&1 || true
"$ADB" -s "$device_serial" logcat -d -v threadtime > "$OUTPUT_DIR/logcat-threadtime.txt" 2>&1 || true
"$ADB" -s "$device_serial" logcat -d -v brief AndroidRuntime:E GooseBridgeSmoke:I '*:S' > "$OUTPUT_DIR/logcat-goose-brief.txt" 2>&1 || true

ANDROID_SERIAL="$device_serial" "$SCRIPT_DIR/pull_android_database.sh" "$OUTPUT_DIR/goose-phone.sqlite" \
  > "$OUTPUT_DIR/pull-android-database.txt" 2>&1

"$SCRIPT_DIR/inspect_android_capture.sh" "$OUTPUT_DIR/goose-phone.sqlite" \
  > "$OUTPUT_DIR/inspect-android-capture.txt" 2>&1

cat > "$OUTPUT_DIR/README.txt" <<README
Goose Android phone evidence bundle

Generated at: $STAMP
Device serial: $device_serial

Key files:
- android-port-status.txt: branch, commit, APK metadata, generated artifact status.
- adb-devices.txt: adb device list at collection time.
- logcat-threadtime.txt: full device logcat snapshot.
- logcat-goose-brief.txt: focused AndroidRuntime/Goose instrumentation logcat.
- goose-phone.sqlite plus -wal/-shm: pulled debug app database files when present.
- goose-phone-health-connect-sync-log.jsonl: Health Connect sync audit log when present.
- inspect-android-capture.txt: read-only SQLite capture summary.
- pull-android-database.txt: pull helper output.

For stricter capture checks, rerun inspect_android_capture.sh with:
GOOSE_ANDROID_MIN_RAW_EVIDENCE=1 GOOSE_ANDROID_MIN_CAPTURE_SESSIONS=1
README

echo "Android phone evidence collection complete: $OUTPUT_DIR"
