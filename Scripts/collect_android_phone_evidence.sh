#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_DIR="${1:-$APP_DIR/tmp/android-phone-evidence-$STAMP}"
REQUIRE_INSTALLED_PACKAGE="${GOOSE_ANDROID_REQUIRE_INSTALLED_PACKAGE:-0}"
REQUIRE_PHYSICAL_DEVICE="${GOOSE_ANDROID_REQUIRE_PHYSICAL_DEVICE:-0}"

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
  devices=()
  while IFS= read -r serial; do
    devices+=("$serial")
  done < <("$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1 }')
  if [[ "${#devices[@]}" -eq 1 ]]; then
    device_serial="${devices[0]}"
  elif [[ "${#devices[@]}" -eq 0 ]]; then
    echo "No adb device online. Status snapshot was written, but device evidence was not collected." | tee "$OUTPUT_DIR/collect-error.txt"
    exit 1
  else
    {
      echo "Multiple adb devices are online. Set ANDROID_SERIAL to one of:"
      printf '  %s\n' "${devices[@]}"
    } | tee "$OUTPUT_DIR/collect-error.txt"
    exit 1
  fi
fi

device_state="$("$ADB" -s "$device_serial" get-state 2>/dev/null || true)"
if [[ "$device_state" != "device" ]]; then
  echo "adb target is not online: $device_serial ($device_state)" | tee "$OUTPUT_DIR/collect-error.txt"
  exit 1
fi

echo "$device_serial" > "$OUTPUT_DIR/android-serial.txt"
"$ADB" -s "$device_serial" shell getprop ro.product.manufacturer > "$OUTPUT_DIR/device-manufacturer.txt" 2>&1 || true
"$ADB" -s "$device_serial" shell getprop ro.product.model > "$OUTPUT_DIR/device-model.txt" 2>&1 || true
"$ADB" -s "$device_serial" shell getprop ro.build.version.release > "$OUTPUT_DIR/android-version.txt" 2>&1 || true
"$ADB" -s "$device_serial" shell getprop ro.build.version.sdk > "$OUTPUT_DIR/android-sdk.txt" 2>&1 || true
"$ADB" -s "$device_serial" shell pm path com.goose.android > "$OUTPUT_DIR/goose-package-path.txt" 2>&1 || true
"$ADB" -s "$device_serial" shell dumpsys package com.goose.android > "$OUTPUT_DIR/goose-package-dumpsys.txt" 2>&1 || true
"$ADB" -s "$device_serial" shell dumpsys package com.goose.android \
  | awk '/versionCode=|versionName=|firstInstallTime=|lastUpdateTime=|installerPackageName=|signatures=|pkgFlags=|privateFlags=|User [0-9]+:/' \
  > "$OUTPUT_DIR/goose-package-summary.txt" 2>&1 || true
"$ADB" -s "$device_serial" logcat -d -v threadtime > "$OUTPUT_DIR/logcat-threadtime.txt" 2>&1 || true
"$ADB" -s "$device_serial" logcat -d -v brief AndroidRuntime:E GooseBridgeSmoke:I '*:S' > "$OUTPUT_DIR/logcat-goose-brief.txt" 2>&1 || true

device_kind="physical"
device_manufacturer="$(sed -n '1p' "$OUTPUT_DIR/device-manufacturer.txt" | tr -d '\r')"
device_model="$(sed -n '1p' "$OUTPUT_DIR/device-model.txt" | tr -d '\r')"
if [[ "$device_serial" == emulator-* ]] \
  || [[ "$device_manufacturer" == "Google" && "$device_model" == sdk_* ]] \
  || [[ "$device_model" == *"Android SDK built for"* ]] \
  || [[ "$device_model" == *"sdk_gphone"* ]]; then
  device_kind="emulator"
fi
echo "$device_kind" > "$OUTPUT_DIR/android-device-kind.txt"

ANDROID_SERIAL="$device_serial" "$SCRIPT_DIR/pull_android_database.sh" "$OUTPUT_DIR/goose-phone.sqlite" \
  > "$OUTPUT_DIR/pull-android-database.txt" 2>&1

if [[ "${GOOSE_ANDROID_STRICT_EVIDENCE:-0}" == "1" ]]; then
  export GOOSE_ANDROID_MIN_RAW_EVIDENCE="${GOOSE_ANDROID_MIN_RAW_EVIDENCE:-1}"
  export GOOSE_ANDROID_MIN_CAPTURE_SESSIONS="${GOOSE_ANDROID_MIN_CAPTURE_SESSIONS:-1}"
fi

cat > "$OUTPUT_DIR/evidence-gates.txt" <<GATES
GOOSE_ANDROID_STRICT_EVIDENCE=${GOOSE_ANDROID_STRICT_EVIDENCE:-0}
GOOSE_ANDROID_MIN_RAW_EVIDENCE=${GOOSE_ANDROID_MIN_RAW_EVIDENCE:-0}
GOOSE_ANDROID_MIN_CAPTURE_SESSIONS=${GOOSE_ANDROID_MIN_CAPTURE_SESSIONS:-0}
GOOSE_ANDROID_MIN_SESSION_RAW_EVIDENCE=${GOOSE_ANDROID_MIN_SESSION_RAW_EVIDENCE:-0}
GOOSE_ANDROID_MIN_SESSION_LIVE_NOTIFICATION_RAW_EVIDENCE=${GOOSE_ANDROID_MIN_SESSION_LIVE_NOTIFICATION_RAW_EVIDENCE:-0}
GOOSE_ANDROID_MIN_FINISHED_CAPTURE_SESSIONS=${GOOSE_ANDROID_MIN_FINISHED_CAPTURE_SESSIONS:-0}
GOOSE_ANDROID_REQUIRE_INSTALLED_PACKAGE=${GOOSE_ANDROID_REQUIRE_INSTALLED_PACKAGE:-0}
GOOSE_ANDROID_REQUIRE_PHYSICAL_DEVICE=${GOOSE_ANDROID_REQUIRE_PHYSICAL_DEVICE:-0}
GOOSE_ANDROID_REQUIRE_BLE_SESSION_AUDIT=${GOOSE_ANDROID_REQUIRE_BLE_SESSION_AUDIT:-0}
GOOSE_ANDROID_REQUIRE_BLE_HELLO_SENT=${GOOSE_ANDROID_REQUIRE_BLE_HELLO_SENT:-0}
GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_AUDIT=${GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_AUDIT:-0}
GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_PASS=${GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_PASS:-0}
GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_SESSION=${GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_SESSION:-0}
GOOSE_ANDROID_REQUIRE_HEALTH_AUDIT=${GOOSE_ANDROID_REQUIRE_HEALTH_AUDIT:-0}
GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_ATTEMPT=${GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_ATTEMPT:-0}
GOOSE_ANDROID_REQUIRE_HEALTH_READY_WRITE_PLAN=${GOOSE_ANDROID_REQUIRE_HEALTH_READY_WRITE_PLAN:-0}
GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_SUCCESS=${GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_SUCCESS:-0}
GATES

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

summary_section() {
  local title="$1"
  awk -v title="$title" '
    $0 == title { in_section = 1; print; next }
    in_section && /^$/ { exit }
    in_section { print }
  ' "$OUTPUT_DIR/inspect-android-capture.txt"
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
package_path="$(first_line "$OUTPUT_DIR/goose-package-path.txt")"
package_result="PASS"
if [[ "$package_path" != package:* ]] \
  || ! grep -q 'versionName=0.1.0' "$OUTPUT_DIR/goose-package-summary.txt" 2>/dev/null; then
  package_result="FAIL"
fi
if [[ "$REQUIRE_INSTALLED_PACKAGE" == "1" && "$package_result" != "PASS" ]]; then
  inspection_status=1
  inspection_result="FAIL"
  echo "FAIL: installed com.goose.android package metadata missing or unexpected" >> "$OUTPUT_DIR/collect-error.txt"
  echo "RESULT: FAIL" > "$OUTPUT_DIR/evidence-result.txt"
fi
device_result="PASS"
if [[ "$REQUIRE_PHYSICAL_DEVICE" == "1" && "$device_kind" != "physical" ]]; then
  device_result="FAIL"
  inspection_status=1
  inspection_result="FAIL"
  echo "FAIL: final evidence requires a physical Android device, got $device_kind ($device_serial)" >> "$OUTPUT_DIR/collect-error.txt"
  echo "RESULT: FAIL" > "$OUTPUT_DIR/evidence-result.txt"
fi

cat > "$OUTPUT_DIR/phone-handoff-summary.md" <<SUMMARY
# Goose Android Phone Evidence

Generated at: $STAMP
Device serial: $device_serial
Device kind: $device_kind
Device: $(first_line "$OUTPUT_DIR/device-manufacturer.txt") $(first_line "$OUTPUT_DIR/device-model.txt")
Android: $(first_line "$OUTPUT_DIR/android-version.txt") (SDK $(first_line "$OUTPUT_DIR/android-sdk.txt"))
Commit: ${port_commit:-unknown}
Result: ${inspection_result:-unknown}

## Gate Configuration

- Gate snapshot: evidence-gates.txt
- Strict evidence: ${GOOSE_ANDROID_STRICT_EVIDENCE:-0}
- Require installed package: ${GOOSE_ANDROID_REQUIRE_INSTALLED_PACKAGE:-0}
- Require physical device: ${GOOSE_ANDROID_REQUIRE_PHYSICAL_DEVICE:-0}
- Require BLE hello sent: ${GOOSE_ANDROID_REQUIRE_BLE_HELLO_SENT:-0}
- Require step validation pass: ${GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_PASS:-0}
- Require step validation session: ${GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_SESSION:-0}
- Require Health Connect write attempt: ${GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_ATTEMPT:-0}
- Require Health Connect ready write plan: ${GOOSE_ANDROID_REQUIRE_HEALTH_READY_WRITE_PLAN:-0}
- Require Health Connect write success: ${GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_SUCCESS:-0}

## Device

- Device result: $device_result
- Kind: $device_kind

## Installed App

- Result: $package_result
- Package path: $package_path
- Package summary: goose-package-summary.txt
- Package dump: goose-package-dumpsys.txt

## Capture

- Raw evidence rows: $(summary_value "raw evidence")
- Decoded frame rows: $(summary_value "decoded frames")
- Capture sessions: $(summary_value "capture sessions")
- Session raw evidence rows: $(summary_value "session raw evidence")
- Session live notification raw evidence rows: $(summary_value "session live notification raw evidence")
- Finished nonempty capture sessions: $(summary_value "finished nonempty capture sessions")
- Step samples: $(summary_value "step samples")
- Daily activity metrics: $(summary_value "daily activity metrics")
- Latest raw capture: $(summary_value "latest raw capture")

## Capture Session Evidence Detail

\`\`\`
$(summary_section "Capture session evidence detail")
\`\`\`

## BLE Session

- Audit log: $(summary_value "ble session audit")
- Audit bytes: $(summary_value "ble session audit bytes")
- Ready events: $(summary_value "ble session ready events")
- Hello sent events: $(summary_value "ble session hello sent events")
- Command ready events: $(summary_value "ble session command ready events")

## Health Connect

- Audit log: $(summary_value "health sync audit")
- Audit bytes: $(summary_value "health sync audit bytes")
- Blocked events: $(summary_value "health sync blocked events")
- Write started events: $(summary_value "health sync write started events")
- Ready write started events: $(summary_value "health sync ready write started events")
- Planned write started events: $(summary_value "health sync planned write started events")
- Candidate write started events: $(summary_value "health sync candidate write started events")
- Records attempted events: $(summary_value "health sync records attempted events")
- Write succeeded events: $(summary_value "health sync write succeeded events")
- Write failed events: $(summary_value "health sync write failed events")

## Step Validation

- Audit log: $(summary_value "step validation audit")
- Audit bytes: $(summary_value "step validation audit bytes")
- Completed events: $(summary_value "step validation completed events")
- Passed events: $(summary_value "step validation passed events")
- Failed events: $(summary_value "step validation failed events")
- Session-bound events: $(summary_value "step validation session-bound events")
- Session decoded events: $(summary_value "step validation session decoded events")
- Selected delta events: $(summary_value "step validation selected delta events")

## Evidence Files

- android-port-status.txt
- evidence-gates.txt
- android-device-kind.txt
- goose-package-path.txt
- goose-package-summary.txt
- goose-package-dumpsys.txt
- inspect-android-capture.txt
- goose-phone.sqlite
- goose-phone-ble-session-log.jsonl, when present
- goose-phone-health-connect-sync-log.jsonl, when present
- goose-phone-step-validation-log.jsonl, when present
- logcat-goose-brief.txt
SUMMARY

cat > "$OUTPUT_DIR/README.txt" <<README
Goose Android phone evidence bundle

Generated at: $STAMP
Device serial: $device_serial
Device kind: $device_kind

Key files:
- android-port-status.txt: branch, commit, APK metadata, generated artifact status.
- evidence-gates.txt: strict gate environment used for this bundle.
- adb-devices.txt: adb device list at collection time.
- android-device-kind.txt: physical or emulator classification used by final gates.
- goose-package-path.txt: installed com.goose.android package path from the device.
- goose-package-summary.txt: focused package version, install time, flags, and user state.
- goose-package-dumpsys.txt: full installed package metadata for com.goose.android.
- logcat-threadtime.txt: full device logcat snapshot.
- logcat-goose-brief.txt: focused AndroidRuntime/Goose instrumentation logcat.
- goose-phone.sqlite plus -wal/-shm: pulled debug app database files when present.
- goose-phone-ble-session-log.jsonl: BLE scan/connect/session audit log when present.
- goose-phone-health-connect-sync-log.jsonl: Health Connect sync audit log when present.
- goose-phone-step-validation-log.jsonl: counted-step validation audit log when present.
- inspect-android-capture.txt: read-only SQLite capture summary.
- phone-handoff-summary.md: concise PR and phone-session summary.
- pull-android-database.txt: pull helper output.
- evidence-result.txt: PASS/FAIL for the capture inspection gate.

Strict mode:
GOOSE_ANDROID_STRICT_EVIDENCE=1 Scripts/collect_android_phone_evidence.sh

Strict mode requires at least one raw_evidence row and one capture_sessions row.
The final phone gate additionally requires session-tagged raw_evidence, at least
one session-tagged Android BLE live-notification raw_evidence row, and a finished
nonempty capture session. Set GOOSE_ANDROID_REQUIRE_INSTALLED_PACKAGE=1 to
require installed com.goose.android package metadata.
Set GOOSE_ANDROID_REQUIRE_PHYSICAL_DEVICE=1 to reject emulator evidence.
Set GOOSE_ANDROID_REQUIRE_BLE_SESSION_AUDIT=1 to require a pulled BLE session
audit log and GOOSE_ANDROID_REQUIRE_BLE_HELLO_SENT=1 to require proof that the
client hello was sent after connecting.
Set GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_AUDIT=1 after a counted-step
validation attempt, or GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_PASS=1 when the
step validation should pass. Set GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_SESSION=1
to require a capture-session-bound validation with decoded session frames and a
selected counter delta.
Set GOOSE_ANDROID_REQUIRE_HEALTH_AUDIT=1 as well when validating a Health
Connect sync attempt. Set GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_ATTEMPT=1 to
require a platform write attempt, GOOSE_ANDROID_REQUIRE_HEALTH_READY_WRITE_PLAN=1
to require permissions-ready dry-run context with planned writes and attempted
records on the write attempt, and GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_SUCCESS=1
to require a successful write.
README

echo "Android phone evidence collection complete: $OUTPUT_DIR"
if [[ "$inspection_status" -ne 0 ]]; then
  echo "Android phone evidence inspection failed; see $OUTPUT_DIR/inspect-android-capture.txt" >&2
  exit "$inspection_status"
fi
