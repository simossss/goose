#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEBUG_APK="$APP_DIR/GooseAndroid/app/build/outputs/apk/debug/app-debug.apk"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_DIR="${1:-$APP_DIR/tmp/android-phone-evidence-$STAMP}"
REQUIRE_INSTALLED_PACKAGE="${GOOSE_ANDROID_REQUIRE_INSTALLED_PACKAGE:-0}"
REQUIRE_PHYSICAL_DEVICE="${GOOSE_ANDROID_REQUIRE_PHYSICAL_DEVICE:-0}"
REQUIRE_NO_ANDROID_RUNTIME_CRASH="${GOOSE_ANDROID_REQUIRE_NO_ANDROID_RUNTIME_CRASH:-0}"
REQUIRE_LOGCAT_START_MARKER="${GOOSE_ANDROID_REQUIRE_LOGCAT_START_MARKER:-0}"
ALLOW_EXISTING_OUTPUT="${GOOSE_ANDROID_ALLOW_EXISTING_EVIDENCE_DIR:-0}"
LOGCAT_MARKER_FILE="${GOOSE_ANDROID_LOGCAT_MARKER_FILE:-/sdcard/goose-evidence-start-marker.txt}"

if [[ -z "${ADB:-}" && -x "$HOME/Library/Android/sdk/platform-tools/adb" ]]; then
  ADB="$HOME/Library/Android/sdk/platform-tools/adb"
fi
ADB="${ADB:-adb}"

file_size() {
  local file="$1"
  wc -c < "$file" | tr -d ' '
}

file_sha256() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{ print $1 }'
  else
    shasum -a 256 "$file" | awk '{ print $1 }'
  fi
}

write_file_manifest() {
  local manifest="$OUTPUT_DIR/evidence-files-manifest.txt"
  local tmp_manifest="$manifest.tmp"

  {
    echo "path	bytes	sha256"
    while IFS= read -r path; do
      local name="${path#$OUTPUT_DIR/}"
      if [[ "$name" == "evidence-files-manifest.txt" || "$name" == "evidence-files-manifest.txt.tmp" ]]; then
        continue
      fi
      printf '%s\t%s\t%s\n' "$name" "$(file_size "$path")" "$(file_sha256 "$path")"
    done < <(find "$OUTPUT_DIR" -maxdepth 1 -type f | sort)
  } > "$tmp_manifest"
  mv "$tmp_manifest" "$manifest"
}

fail_before_device_evidence() {
  echo "RESULT: FAIL" > "$OUTPUT_DIR/evidence-result.txt"
  write_file_manifest
}

if [[ -d "$OUTPUT_DIR" ]] && [[ "$ALLOW_EXISTING_OUTPUT" != "1" ]] && find "$OUTPUT_DIR" -mindepth 1 -print -quit | grep -q .; then
  echo "Evidence output directory is not empty: $OUTPUT_DIR" >&2
  echo "Use a fresh output directory, or set GOOSE_ANDROID_ALLOW_EXISTING_EVIDENCE_DIR=1 for local debugging." >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "Collecting Android phone evidence into $OUTPUT_DIR"

"$SCRIPT_DIR/android_port_status.sh" > "$OUTPUT_DIR/android-port-status.txt"

if ! command -v "$ADB" >/dev/null 2>&1; then
  echo "adb not found. Status snapshot was written, but device evidence was not collected." | tee "$OUTPUT_DIR/collect-error.txt"
  fail_before_device_evidence
  exit 1
fi

if ! "$ADB" devices > "$OUTPUT_DIR/adb-devices.txt" 2>&1; then
  echo "adb devices failed. Status snapshot was written, but device evidence was not collected." | tee "$OUTPUT_DIR/collect-error.txt"
  fail_before_device_evidence
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
    echo "No adb device online. Status snapshot was written, but device evidence was not collected." | tee "$OUTPUT_DIR/collect-error.txt"
    fail_before_device_evidence
    exit 1
  else
    {
      echo "Multiple adb devices are online. Set ANDROID_SERIAL to one of:"
      printf '  %s\n' "${devices[@]}"
    } | tee "$OUTPUT_DIR/collect-error.txt"
    fail_before_device_evidence
    exit 1
  fi
fi

echo "$device_serial" > "$OUTPUT_DIR/android-serial.txt"
device_state="$("$ADB" -s "$device_serial" get-state 2>/dev/null || true)"
if [[ "$device_state" != "device" ]]; then
  echo "adb target is not online: $device_serial ($device_state)" | tee "$OUTPUT_DIR/collect-error.txt"
  fail_before_device_evidence
  exit 1
fi

"$ADB" -s "$device_serial" shell getprop ro.product.manufacturer > "$OUTPUT_DIR/device-manufacturer.txt" 2>&1 || true
"$ADB" -s "$device_serial" shell getprop ro.product.model > "$OUTPUT_DIR/device-model.txt" 2>&1 || true
"$ADB" -s "$device_serial" shell getprop ro.build.version.release > "$OUTPUT_DIR/android-version.txt" 2>&1 || true
"$ADB" -s "$device_serial" shell getprop ro.build.version.sdk > "$OUTPUT_DIR/android-sdk.txt" 2>&1 || true
"$ADB" -s "$device_serial" shell pm path com.goose.android > "$OUTPUT_DIR/goose-package-path.txt" 2>&1 || true
"$ADB" -s "$device_serial" shell dumpsys package com.goose.android > "$OUTPUT_DIR/goose-package-dumpsys.txt" 2>&1 || true
"$ADB" -s "$device_serial" shell dumpsys package com.goose.android \
  | awk '/versionCode=|versionName=|firstInstallTime=|lastUpdateTime=|installerPackageName=|signatures=|pkgFlags=|privateFlags=|User [0-9]+:/' \
  > "$OUTPUT_DIR/goose-package-summary.txt" 2>&1 || true
"$ADB" -s "$device_serial" exec-out cat "$LOGCAT_MARKER_FILE" > "$OUTPUT_DIR/logcat-start-marker.txt" 2>/dev/null || true
"$ADB" -s "$device_serial" logcat -d -v threadtime > "$OUTPUT_DIR/logcat-threadtime.txt" 2>&1 || true
"$ADB" -s "$device_serial" logcat -d -v brief AndroidRuntime:E GooseBridgeSmoke:I GooseEvidenceStart:I '*:S' > "$OUTPUT_DIR/logcat-goose-brief.txt" 2>&1 || true

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

pull_status=0
if ANDROID_SERIAL="$device_serial" "$SCRIPT_DIR/pull_android_database.sh" "$OUTPUT_DIR/goose-phone.sqlite" \
  > "$OUTPUT_DIR/pull-android-database.txt" 2>&1; then
  echo "RESULT: PASS" > "$OUTPUT_DIR/pull-android-database-result.txt"
else
  pull_status=$?
  echo "RESULT: FAIL" > "$OUTPUT_DIR/pull-android-database-result.txt"
  echo "FAIL: Android database pull failed with exit status $pull_status" >> "$OUTPUT_DIR/collect-error.txt"
fi

if [[ "${GOOSE_ANDROID_STRICT_EVIDENCE:-0}" == "1" ]]; then
  export GOOSE_ANDROID_MIN_RAW_EVIDENCE="${GOOSE_ANDROID_MIN_RAW_EVIDENCE:-1}"
  export GOOSE_ANDROID_MIN_DECODED_FRAMES="${GOOSE_ANDROID_MIN_DECODED_FRAMES:-1}"
  export GOOSE_ANDROID_MIN_CAPTURE_SESSIONS="${GOOSE_ANDROID_MIN_CAPTURE_SESSIONS:-1}"
fi

cat > "$OUTPUT_DIR/evidence-gates.txt" <<GATES
GOOSE_ANDROID_STRICT_EVIDENCE=${GOOSE_ANDROID_STRICT_EVIDENCE:-0}
GOOSE_ANDROID_MIN_RAW_EVIDENCE=${GOOSE_ANDROID_MIN_RAW_EVIDENCE:-0}
GOOSE_ANDROID_MIN_DECODED_FRAMES=${GOOSE_ANDROID_MIN_DECODED_FRAMES:-0}
GOOSE_ANDROID_MIN_CAPTURE_SESSIONS=${GOOSE_ANDROID_MIN_CAPTURE_SESSIONS:-0}
GOOSE_ANDROID_MIN_SESSION_RAW_EVIDENCE=${GOOSE_ANDROID_MIN_SESSION_RAW_EVIDENCE:-0}
GOOSE_ANDROID_MIN_SESSION_LIVE_NOTIFICATION_RAW_EVIDENCE=${GOOSE_ANDROID_MIN_SESSION_LIVE_NOTIFICATION_RAW_EVIDENCE:-0}
GOOSE_ANDROID_MIN_SESSION_DECODED_FRAMES=${GOOSE_ANDROID_MIN_SESSION_DECODED_FRAMES:-0}
GOOSE_ANDROID_MIN_FINISHED_CAPTURE_SESSIONS=${GOOSE_ANDROID_MIN_FINISHED_CAPTURE_SESSIONS:-0}
GOOSE_ANDROID_REQUIRE_INSTALLED_PACKAGE=${GOOSE_ANDROID_REQUIRE_INSTALLED_PACKAGE:-0}
GOOSE_ANDROID_REQUIRE_PHYSICAL_DEVICE=${GOOSE_ANDROID_REQUIRE_PHYSICAL_DEVICE:-0}
GOOSE_ANDROID_REQUIRE_NO_ANDROID_RUNTIME_CRASH=${GOOSE_ANDROID_REQUIRE_NO_ANDROID_RUNTIME_CRASH:-0}
GOOSE_ANDROID_REQUIRE_LOGCAT_START_MARKER=${GOOSE_ANDROID_REQUIRE_LOGCAT_START_MARKER:-0}
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
  echo "FAIL: Android capture inspection failed with exit status $inspection_status; see inspect-android-capture.txt" >> "$OUTPUT_DIR/collect-error.txt"
fi

summary_value() {
  local key="$1"
  awk -F': ' -v key="$key" '$1 == key { print $2; exit }' "$OUTPUT_DIR/inspect-android-capture.txt"
}

summary_value_from() {
  local key="$1"
  local file="$2"
  if [[ -f "$file" ]]; then
    awk -F': ' -v key="$key" '$1 == key { print $2; exit }' "$file"
  fi
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

remote_file_sha256() {
  local remote_path="$1"
  "$ADB" -s "$device_serial" exec-out cat "$remote_path" | shasum -a 256 | awk '{ print $1 }'
}

android_runtime_crash_lines() {
  local file="$1"
  awk '/AndroidRuntime/ && /com[.]goose[.]android/ { count += 1 } END { print count + 0 }' "$file" 2>/dev/null
}

valid_logcat_start_marker() {
  local marker="$1"
  local expected_serial="$2"
  local prefix stamp package serial extra

  read -r prefix stamp package serial extra <<< "$marker"
  [[ "$prefix" == "goose-evidence-start" ]] || return 1
  [[ "$stamp" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || return 1
  [[ "$package" == "com.goose.android" ]] || return 1
  [[ "$serial" == "$expected_serial" ]] || return 1
  [[ -z "${extra:-}" ]] || return 1
}

marker_stamp() {
  local marker="$1"
  local prefix stamp package serial extra
  read -r prefix stamp package serial extra <<< "$marker"
  printf '%s' "$stamp"
}

normalize_utc_capture_timestamp() {
  local value="$1"
  if [[ "$value" =~ ^([0-9]{8}T[0-9]{6}Z)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  elif [[ "$value" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?Z$ ]]; then
    printf '%s%s%sT%s%s%sZ' \
      "${BASH_REMATCH[1]}" \
      "${BASH_REMATCH[2]}" \
      "${BASH_REMATCH[3]}" \
      "${BASH_REMATCH[4]}" \
      "${BASH_REMATCH[5]}" \
      "${BASH_REMATCH[6]}"
  fi
}

capture_at_or_after_marker() {
  local capture_at="$1"
  local marker="$2"
  local capture_stamp
  local start_stamp
  capture_stamp="$(normalize_utc_capture_timestamp "$capture_at")"
  start_stamp="$(marker_stamp "$marker")"
  [[ -n "$capture_stamp" && -n "$start_stamp" ]] || return 1
  [[ "$capture_stamp" > "$start_stamp" || "$capture_stamp" == "$start_stamp" ]]
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
package_apk_path="${package_path#package:}"
local_debug_apk_sha256="missing"
installed_apk_sha256="unavailable"
installed_apk_hash_result="FAIL"
if [[ -f "$DEBUG_APK" ]]; then
  local_debug_apk_sha256="$(file_sha256 "$DEBUG_APK")"
fi
if [[ "$package_path" == package:* ]] && [[ -n "$package_apk_path" ]]; then
  if ! installed_apk_sha256="$(remote_file_sha256 "$package_apk_path" 2>/dev/null)"; then
    installed_apk_sha256="unavailable"
  fi
fi
if [[ "$local_debug_apk_sha256" != "missing" ]] \
  && [[ "$installed_apk_sha256" != "unavailable" ]] \
  && [[ "$local_debug_apk_sha256" == "$installed_apk_sha256" ]]; then
  installed_apk_hash_result="PASS"
fi
printf '%s\n' "$local_debug_apk_sha256" > "$OUTPUT_DIR/goose-local-debug-apk-sha256.txt"
printf '%s\n' "$installed_apk_sha256" > "$OUTPUT_DIR/goose-installed-apk-sha256.txt"
android_runtime_crash_count="$(android_runtime_crash_lines "$OUTPUT_DIR/logcat-goose-brief.txt")"
logcat_start_marker="$(first_line "$OUTPUT_DIR/logcat-start-marker.txt")"
logcat_start_marker_result="FAIL"
if [[ -n "$logcat_start_marker" ]] \
  && valid_logcat_start_marker "$logcat_start_marker" "$device_serial" \
  && grep -Fq "$logcat_start_marker" "$OUTPUT_DIR/logcat-threadtime.txt" \
  && grep -Fq "$logcat_start_marker" "$OUTPUT_DIR/logcat-goose-brief.txt"; then
  logcat_start_marker_result="PASS"
fi
latest_raw_capture="$(summary_value "latest raw capture")"
latest_raw_capture_after_marker_result="FAIL"
if [[ "$logcat_start_marker_result" == "PASS" ]] \
  && capture_at_or_after_marker "$latest_raw_capture" "$logcat_start_marker"; then
  latest_raw_capture_after_marker_result="PASS"
fi
package_result="PASS"
if [[ "$package_path" != package:* ]] \
  || ! grep -q 'versionName=0.1.0' "$OUTPUT_DIR/goose-package-summary.txt" 2>/dev/null \
  || [[ "$installed_apk_hash_result" != "PASS" ]]; then
  package_result="FAIL"
fi
if [[ "$REQUIRE_INSTALLED_PACKAGE" == "1" && "$package_result" != "PASS" ]]; then
  inspection_status=1
  inspection_result="FAIL"
  echo "FAIL: installed com.goose.android package metadata/hash missing, stale, or unexpected" >> "$OUTPUT_DIR/collect-error.txt"
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
if [[ "$REQUIRE_NO_ANDROID_RUNTIME_CRASH" == "1" && "$android_runtime_crash_count" -gt 0 ]]; then
  inspection_status=1
  inspection_result="FAIL"
  echo "FAIL: focused AndroidRuntime logcat contains com.goose.android crash lines" >> "$OUTPUT_DIR/collect-error.txt"
  echo "RESULT: FAIL" > "$OUTPUT_DIR/evidence-result.txt"
fi
if [[ "$REQUIRE_LOGCAT_START_MARKER" == "1" && "$logcat_start_marker_result" != "PASS" ]]; then
  inspection_status=1
  inspection_result="FAIL"
  echo "FAIL: logcat start marker missing from marker file, full logcat, or focused logcat" >> "$OUTPUT_DIR/collect-error.txt"
  echo "RESULT: FAIL" > "$OUTPUT_DIR/evidence-result.txt"
fi
if [[ "$REQUIRE_LOGCAT_START_MARKER" == "1" && "$latest_raw_capture_after_marker_result" != "PASS" ]]; then
  inspection_status=1
  inspection_result="FAIL"
  echo "FAIL: latest raw capture is missing, unparseable, or older than the logcat start marker" >> "$OUTPUT_DIR/collect-error.txt"
  echo "RESULT: FAIL" > "$OUTPUT_DIR/evidence-result.txt"
fi

final_adb_state="$("$ADB" -s "$device_serial" get-state 2>/dev/null || true)"
printf '%s\n' "$final_adb_state" > "$OUTPUT_DIR/adb-state-final.txt"
if [[ "$final_adb_state" != "device" ]]; then
  inspection_status=1
  inspection_result="FAIL"
  echo "FAIL: adb target was not online after evidence collection: $device_serial ($final_adb_state)" >> "$OUTPUT_DIR/collect-error.txt"
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
- Require no AndroidRuntime crash: ${GOOSE_ANDROID_REQUIRE_NO_ANDROID_RUNTIME_CRASH:-0}
- Require logcat start marker: ${GOOSE_ANDROID_REQUIRE_LOGCAT_START_MARKER:-0}
- Require BLE hello sent: ${GOOSE_ANDROID_REQUIRE_BLE_HELLO_SENT:-0}
- Require step validation pass: ${GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_PASS:-0}
- Require step validation session: ${GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_SESSION:-0}
- Require Health Connect write attempt: ${GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_ATTEMPT:-0}
- Require Health Connect ready write plan: ${GOOSE_ANDROID_REQUIRE_HEALTH_READY_WRITE_PLAN:-0}
- Require Health Connect write success: ${GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_SUCCESS:-0}

## Device

- Device result: $device_result
- Kind: $device_kind
- Final adb state: $final_adb_state
- Logcat start marker result: $logcat_start_marker_result
- Latest raw capture after marker result: $latest_raw_capture_after_marker_result
- Focused AndroidRuntime crash lines: $android_runtime_crash_count

## Installed App

- Result: $package_result
- Package path: $package_path
- Local debug APK SHA-256: $local_debug_apk_sha256
- Installed APK SHA-256: $installed_apk_sha256
- Installed APK hash result: $installed_apk_hash_result
- Package summary: goose-package-summary.txt
- Package dump: goose-package-dumpsys.txt

## Capture

- Database pull result: $(summary_value_from "RESULT" "$OUTPUT_DIR/pull-android-database-result.txt")
- Database bytes: $(summary_value "database bytes")
- Database SHA-256: $(summary_value "database sha256")
- Database WAL bytes: $(summary_value "database wal bytes")
- Database WAL SHA-256: $(summary_value "database wal sha256")
- Database SHM bytes: $(summary_value "database shm bytes")
- Database SHM SHA-256: $(summary_value "database shm sha256")
- Raw evidence rows: $(summary_value "raw evidence")
- Decoded frame rows: $(summary_value "decoded frames")
- Capture sessions: $(summary_value "capture sessions")
- Session raw evidence rows: $(summary_value "session raw evidence")
- Session live notification raw evidence rows: $(summary_value "session live notification raw evidence")
- Session decoded frame rows: $(summary_value "session decoded frames")
- Finished nonempty capture sessions: $(summary_value "finished nonempty capture sessions")
- Step samples: $(summary_value "step samples")
- Daily activity metrics: $(summary_value "daily activity metrics")
- Daily local estimate metrics: $(summary_value "daily local estimate metrics")
- Daily device counter metrics: $(summary_value "daily device counter metrics")
- Latest raw capture: $latest_raw_capture
- Latest raw capture after marker result: $latest_raw_capture_after_marker_result

## Capture Session Evidence Detail

\`\`\`
$(summary_section "Capture session evidence detail")
\`\`\`

## BLE Session

- Audit log: $(summary_value "ble session audit")
- Audit bytes: $(summary_value "ble session audit bytes")
- Audit rotated bytes: $(summary_value "ble session audit rotated bytes")
- Ready events: $(summary_value "ble session ready events")
- Hello sent events: $(summary_value "ble session hello sent events")
- Client hello completed events: $(summary_value "ble session client hello completed events")
- Client hello command-ready completed events: $(summary_value "ble session client hello command-ready completed events")
- Command ready events: $(summary_value "ble session command ready events")
- Ready hello command-ready events: $(summary_value "ble session ready hello command-ready events")

## Health Connect

- Audit log: $(summary_value "health sync audit")
- Audit bytes: $(summary_value "health sync audit bytes")
- Audit rotated bytes: $(summary_value "health sync audit rotated bytes")
- Blocked events: $(summary_value "health sync blocked events")
- Write started events: $(summary_value "health sync write started events")
- Ready write started events: $(summary_value "health sync ready write started events")
- Planned write started events: $(summary_value "health sync planned write started events")
- Candidate write started events: $(summary_value "health sync candidate write started events")
- Records attempted events: $(summary_value "health sync records attempted events")
- Steps record started events: $(summary_value "health sync steps record started events")
- Local estimate record started events: $(summary_value "health sync local estimate record started events")
- Device counter record started events: $(summary_value "health sync device counter record started events")
- Write succeeded events: $(summary_value "health sync write succeeded events")
- Ready write succeeded events: $(summary_value "health sync ready write succeeded events")
- Planned write succeeded events: $(summary_value "health sync planned write succeeded events")
- Records inserted events: $(summary_value "health sync records inserted events")
- Write failed events: $(summary_value "health sync write failed events")

## Step Validation

- Audit log: $(summary_value "step validation audit")
- Audit bytes: $(summary_value "step validation audit bytes")
- Audit rotated bytes: $(summary_value "step validation audit rotated bytes")
- Completed events: $(summary_value "step validation completed events")
- Passed events: $(summary_value "step validation passed events")
- Failed events: $(summary_value "step validation failed events")
- Session-bound events: $(summary_value "step validation session-bound events")
- Session decoded events: $(summary_value "step validation session decoded events")
- Selected delta events: $(summary_value "step validation selected delta events")
- Passing session selected-delta events: $(summary_value "step validation passing session selected-delta events")

## Evidence Files

- android-port-status.txt
- evidence-gates.txt
- android-device-kind.txt
- adb-state-final.txt
- goose-package-path.txt
- goose-package-summary.txt
- goose-package-dumpsys.txt
- goose-local-debug-apk-sha256.txt
- goose-installed-apk-sha256.txt
- inspect-android-capture.txt
- pull-android-database-result.txt
- goose-phone.sqlite
- goose-phone-ble-session-log.jsonl or goose-phone-ble-session-log.jsonl.old, required when BLE hello gates are enabled
- goose-phone-health-connect-sync-log.jsonl or goose-phone-health-connect-sync-log.jsonl.old, required when Health Connect write gates are enabled
- goose-phone-step-validation-log.jsonl or goose-phone-step-validation-log.jsonl.old, required when step-validation gates are enabled
- logcat-goose-brief.txt
- logcat-start-marker.txt
- evidence-files-manifest.txt
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
- adb-state-final.txt: adb get-state for the selected device after evidence collection.
- android-device-kind.txt: physical or emulator classification used by final gates.
- goose-package-path.txt: installed com.goose.android package path from the device.
- goose-package-summary.txt: focused package version, install time, flags, and user state.
- goose-package-dumpsys.txt: full installed package metadata for com.goose.android.
- goose-local-debug-apk-sha256.txt: SHA-256 of the local debug APK used for comparison.
- goose-installed-apk-sha256.txt: SHA-256 of the installed APK read over adb.
- logcat-threadtime.txt: full device logcat snapshot.
- logcat-goose-brief.txt: focused AndroidRuntime/Goose instrumentation logcat.
- logcat-start-marker.txt: marker written by Scripts/prepare_android_phone_evidence.sh before the controlled run.
- goose-phone.sqlite plus -wal/-shm: pulled debug app database files when present.
- pull-android-database-result.txt: PASS/FAIL for the database pull helper.
- goose-phone-ble-session-log.jsonl and optional .old: BLE scan/connect/session audit log; current or rotated log is required when BLE hello gates are enabled.
- goose-phone-health-connect-sync-log.jsonl and optional .old: Health Connect sync audit log; current or rotated log is required when Health Connect write gates are enabled.
- goose-phone-step-validation-log.jsonl and optional .old: counted-step validation audit log; current or rotated log is required when step-validation gates are enabled.
- inspect-android-capture.txt: read-only SQLite capture summary.
- phone-handoff-summary.md: concise PR and phone-session summary.
- evidence-files-manifest.txt: pulled evidence files with byte counts and SHA-256 hashes.
- pull-android-database.txt: pull helper output.
- evidence-result.txt: PASS/FAIL for the capture inspection gate.

Use a fresh output directory for final evidence. The collector refuses a
non-empty output directory by default so stale files cannot be swept into a new
evidence manifest. Set GOOSE_ANDROID_ALLOW_EXISTING_EVIDENCE_DIR=1 only for
local debugging.

Strict mode:
GOOSE_ANDROID_STRICT_EVIDENCE=1 Scripts/collect_android_phone_evidence.sh

Strict mode requires at least one raw_evidence row, one decoded_frames row, and
one capture_sessions row. The final phone gate additionally requires
session-tagged raw_evidence, at least one session-tagged Android BLE
live-notification raw_evidence row, at least one session-tagged decoded_frames
row, and a finished nonempty capture session. Set
GOOSE_ANDROID_REQUIRE_INSTALLED_PACKAGE=1 to require installed com.goose.android
package metadata and an installed APK hash match.
Set GOOSE_ANDROID_REQUIRE_PHYSICAL_DEVICE=1 to reject emulator evidence.
Set GOOSE_ANDROID_REQUIRE_NO_ANDROID_RUNTIME_CRASH=1 to fail the bundle when
the focused AndroidRuntime logcat contains com.goose.android crash lines.
Set GOOSE_ANDROID_REQUIRE_LOGCAT_START_MARKER=1 to require a marker written by
Scripts/prepare_android_phone_evidence.sh before the controlled run.
Set GOOSE_ANDROID_REQUIRE_BLE_SESSION_AUDIT=1 to require a pulled BLE session
audit log and GOOSE_ANDROID_REQUIRE_BLE_HELLO_SENT=1 to require proof that the
client hello was sent after connecting, while the command characteristic was
ready in the same BLE session audit rows.
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
to require a successful write with inserted records.
README

write_file_manifest

echo "Android phone evidence collection complete: $OUTPUT_DIR"
if [[ "$inspection_status" -ne 0 ]]; then
  echo "Android phone evidence inspection failed; see $OUTPUT_DIR/inspect-android-capture.txt" >&2
  exit "$inspection_status"
fi
