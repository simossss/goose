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

if [[ "${GOOSE_ANDROID_STRICT_EVIDENCE:-0}" == "1" ]]; then
  export GOOSE_ANDROID_MIN_RAW_EVIDENCE="${GOOSE_ANDROID_MIN_RAW_EVIDENCE:-1}"
  export GOOSE_ANDROID_MIN_CAPTURE_SESSIONS="${GOOSE_ANDROID_MIN_CAPTURE_SESSIONS:-1}"
fi

inspection_status=0
if "$SCRIPT_DIR/inspect_android_capture.sh" "$OUTPUT_DIR/goose-phone.sqlite" \
  > "$OUTPUT_DIR/inspect-android-capture.txt" 2>&1; then
  echo "RESULT: PASS" > "$OUTPUT_DIR/evidence-result.txt"
else
  inspection_status=$?
  echo "RESULT: FAIL" > "$OUTPUT_DIR/evidence-result.txt"
fi

summary_value() {
  local key="$1"
  awk -F': ' -v key="$key" '$1 == key { print $2; exit }' "$OUTPUT_DIR/inspect-android-capture.txt"
}

first_line() {
  local file="$1"
  if [[ -f "$file" ]]; then
    sed -n '1p' "$file" | tr -d '\r'
  fi
}

port_commit="$(summary_value "commit")"
if [[ -z "$port_commit" ]]; then
  port_commit="$(awk -F': ' '$1 == "commit" { print $2; exit }' "$OUTPUT_DIR/android-port-status.txt")"
fi
inspection_result="$(summary_value "RESULT")"
if [[ -z "$inspection_result" ]]; then
  inspection_result="$(awk -F': ' '$1 == "RESULT" { print $2; exit }' "$OUTPUT_DIR/evidence-result.txt")"
fi

cat > "$OUTPUT_DIR/phone-handoff-summary.md" <<SUMMARY
# Goose Android Phone Evidence

Generated at: $STAMP
Device serial: $device_serial
Device: $(first_line "$OUTPUT_DIR/device-manufacturer.txt") $(first_line "$OUTPUT_DIR/device-model.txt")
Android: $(first_line "$OUTPUT_DIR/android-version.txt") (SDK $(first_line "$OUTPUT_DIR/android-sdk.txt"))
Commit: ${port_commit:-unknown}
Result: ${inspection_result:-unknown}

## Capture

- Raw evidence rows: $(summary_value "raw evidence")
- Decoded frame rows: $(summary_value "decoded frames")
- Capture sessions: $(summary_value "capture sessions")
- Step samples: $(summary_value "step samples")
- Daily activity metrics: $(summary_value "daily activity metrics")
- Latest raw capture: $(summary_value "latest raw capture")

## Health Connect

- Audit log: $(summary_value "health sync audit")
- Audit bytes: $(summary_value "health sync audit bytes")

## Evidence Files

- android-port-status.txt
- inspect-android-capture.txt
- goose-phone.sqlite
- goose-phone-health-connect-sync-log.jsonl, when present
- logcat-goose-brief.txt
SUMMARY

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
- phone-handoff-summary.md: concise PR and phone-session summary.
- pull-android-database.txt: pull helper output.
- evidence-result.txt: PASS/FAIL for the capture inspection gate.

Strict mode:
GOOSE_ANDROID_STRICT_EVIDENCE=1 Scripts/collect_android_phone_evidence.sh

Strict mode requires at least one raw_evidence row and one capture_sessions row.
Set GOOSE_ANDROID_REQUIRE_HEALTH_AUDIT=1 as well when validating a Health
Connect sync attempt.
README

echo "Android phone evidence collection complete: $OUTPUT_DIR"
if [[ "$inspection_status" -ne 0 ]]; then
  echo "Android phone evidence inspection failed; see $OUTPUT_DIR/inspect-android-capture.txt" >&2
  exit "$inspection_status"
fi
