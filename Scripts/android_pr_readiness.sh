#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PHONE_EVIDENCE_DIR=""
STRICT=0

usage() {
  cat <<'USAGE'
Usage: Scripts/android_pr_readiness.sh [--strict] [phone-evidence-dir]

Prints the Android PR readiness summary. With --strict, exits nonzero when the
supplied final phone evidence bundle leaves any phone-bound acceptance item
unproven.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict)
      STRICT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "$PHONE_EVIDENCE_DIR" ]]; then
        echo "Unexpected extra evidence directory: $1" >&2
        usage >&2
        exit 1
      fi
      PHONE_EVIDENCE_DIR="$1"
      shift
      ;;
  esac
done

status_value() {
  local key="$1"
  local file="$2"
  awk -F': ' -v key="$key" '$1 == key { print $2; exit }' "$file"
}

summary_bullet_value() {
  local key="$1"
  local file="$2"
  awk -F': ' -v key="- $key" '$1 == key { print $2; exit }' "$file"
}

gate_value() {
  local key="$1"
  local file="$2"
  awk -F'=' -v key="$key" '$1 == key { print $2; exit }' "$file"
}

is_positive_int() {
  [[ "${1:-}" =~ ^[0-9]+$ && "$1" -gt 0 ]]
}

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

android_runtime_crash_lines() {
  local file="$1"
  awk '/AndroidRuntime/ && /com[.]goose[.]android/ { count += 1 } END { print count + 0 }' "$file" 2>/dev/null
}

verify_evidence_manifest() {
  local dir="$1"
  local manifest="$2"
  local line_number=0
  local verified_count=0
  local saw_port_status=0
  local saw_summary=0
  local saw_gates=0
  local saw_inspection=0
  local saw_database=0
  local saw_logcat=0
  local saw_full_logcat=0
  local saw_package_path=0
  local saw_package_summary=0
  local saw_package_dumpsys=0
  local saw_local_apk_sha=0
  local saw_installed_apk_sha=0
  local saw_adb_devices=0
  local saw_serial=0
  local saw_manufacturer=0
  local saw_model=0
  local saw_android_version=0
  local saw_android_sdk=0
  local saw_device_kind=0
  local saw_result=0
  local saw_pull_result=0

  [[ -f "$manifest" ]] || return 1
  while IFS=$'\t' read -r rel_path expected_bytes expected_sha extra || [[ -n "$rel_path" ]]; do
    line_number=$((line_number + 1))
    if [[ "$line_number" -eq 1 ]]; then
      [[ "$rel_path" == "path" && "$expected_bytes" == "bytes" && "$expected_sha" == "sha256" && -z "${extra:-}" ]] || return 1
      continue
    fi
    [[ -n "$rel_path" && -n "$expected_bytes" && -n "$expected_sha" && -z "${extra:-}" ]] || return 1
    [[ "$rel_path" != /* && "$rel_path" != *".."* && "$rel_path" != *$'\n'* ]] || return 1
    [[ "$expected_bytes" =~ ^[0-9]+$ ]] || return 1
    [[ "$expected_sha" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
    local file="$dir/$rel_path"
    [[ -f "$file" ]] || return 1
    [[ "$(file_size "$file")" == "$expected_bytes" ]] || return 1
    local normalized_sha
    normalized_sha="$(printf '%s' "$expected_sha" | tr 'A-F' 'a-f')"
    [[ "$(file_sha256 "$file")" == "$normalized_sha" ]] || return 1
    if [[ "$rel_path" == "android-port-status.txt" ]]; then
      saw_port_status=1
    elif [[ "$rel_path" == "phone-handoff-summary.md" ]]; then
      saw_summary=1
    elif [[ "$rel_path" == "evidence-gates.txt" ]]; then
      saw_gates=1
    elif [[ "$rel_path" == "inspect-android-capture.txt" ]]; then
      saw_inspection=1
    elif [[ "$rel_path" == "goose-phone.sqlite" ]]; then
      saw_database=1
    elif [[ "$rel_path" == "logcat-goose-brief.txt" ]]; then
      saw_logcat=1
    elif [[ "$rel_path" == "logcat-threadtime.txt" ]]; then
      saw_full_logcat=1
    elif [[ "$rel_path" == "goose-package-path.txt" ]]; then
      saw_package_path=1
    elif [[ "$rel_path" == "goose-package-summary.txt" ]]; then
      saw_package_summary=1
    elif [[ "$rel_path" == "goose-package-dumpsys.txt" ]]; then
      saw_package_dumpsys=1
    elif [[ "$rel_path" == "goose-local-debug-apk-sha256.txt" ]]; then
      saw_local_apk_sha=1
    elif [[ "$rel_path" == "goose-installed-apk-sha256.txt" ]]; then
      saw_installed_apk_sha=1
    elif [[ "$rel_path" == "adb-devices.txt" ]]; then
      saw_adb_devices=1
    elif [[ "$rel_path" == "android-serial.txt" ]]; then
      saw_serial=1
    elif [[ "$rel_path" == "device-manufacturer.txt" ]]; then
      saw_manufacturer=1
    elif [[ "$rel_path" == "device-model.txt" ]]; then
      saw_model=1
    elif [[ "$rel_path" == "android-version.txt" ]]; then
      saw_android_version=1
    elif [[ "$rel_path" == "android-sdk.txt" ]]; then
      saw_android_sdk=1
    elif [[ "$rel_path" == "android-device-kind.txt" ]]; then
      saw_device_kind=1
    elif [[ "$rel_path" == "evidence-result.txt" ]]; then
      saw_result=1
    elif [[ "$rel_path" == "pull-android-database-result.txt" ]]; then
      saw_pull_result=1
    fi
    verified_count=$((verified_count + 1))
  done < "$manifest"

  [[ "$verified_count" -gt 0 \
    && "$saw_port_status" == "1" \
    && "$saw_summary" == "1" \
    && "$saw_gates" == "1" \
    && "$saw_inspection" == "1" \
    && "$saw_database" == "1" \
    && "$saw_logcat" == "1" \
    && "$saw_full_logcat" == "1" \
    && "$saw_package_path" == "1" \
    && "$saw_package_summary" == "1" \
    && "$saw_package_dumpsys" == "1" \
    && "$saw_local_apk_sha" == "1" \
    && "$saw_installed_apk_sha" == "1" \
    && "$saw_adb_devices" == "1" \
    && "$saw_serial" == "1" \
    && "$saw_manufacturer" == "1" \
    && "$saw_model" == "1" \
    && "$saw_android_version" == "1" \
    && "$saw_android_sdk" == "1" \
    && "$saw_device_kind" == "1" \
    && "$saw_result" == "1" \
    && "$saw_pull_result" == "1" ]]
}

verify_manifest_file() {
  local dir="$1"
  local manifest="$2"
  local required_path="$3"
  local line_number=0

  [[ -f "$manifest" ]] || return 1
  while IFS=$'\t' read -r rel_path expected_bytes expected_sha extra || [[ -n "$rel_path" ]]; do
    line_number=$((line_number + 1))
    if [[ "$line_number" -eq 1 ]]; then
      continue
    fi
    if [[ "$rel_path" != "$required_path" ]]; then
      continue
    fi
    [[ -n "$expected_bytes" && -n "$expected_sha" && -z "${extra:-}" ]] || return 1
    [[ "$rel_path" != /* && "$rel_path" != *".."* && "$rel_path" != *$'\n'* ]] || return 1
    [[ "$expected_bytes" =~ ^[0-9]+$ ]] || return 1
    [[ "$expected_sha" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
    local file="$dir/$rel_path"
    [[ -f "$file" ]] || return 1
    [[ "$(file_size "$file")" == "$expected_bytes" ]] || return 1
    local normalized_sha
    normalized_sha="$(printf '%s' "$expected_sha" | tr 'A-F' 'a-f')"
    [[ "$(file_sha256 "$file")" == "$normalized_sha" ]] || return 1
    return 0
  done < "$manifest"

  return 1
}

latest_commit="$(git -C "$APP_DIR" rev-parse --short HEAD) $(git -C "$APP_DIR" log -1 --pretty=%s)"
branch="$(git -C "$APP_DIR" rev-parse --abbrev-ref HEAD)"
dirty_tracked="$(git -C "$APP_DIR" status --short --untracked-files=no | wc -l | tr -d ' ')"
untracked="$(git -C "$APP_DIR" ls-files --others --exclude-standard | wc -l | tr -d ' ')"

tmp_status="$(mktemp "${TMPDIR:-/tmp}/goose-android-status.XXXXXX")"
trap 'rm -f "$tmp_status"' EXIT
"$SCRIPT_DIR/android_port_status.sh" > "$tmp_status"

echo "# Goose Android PR Readiness"
echo
echo "Branch: $branch"
echo "Commit: $latest_commit"
echo "Dirty tracked files: $dirty_tracked"
echo "Untracked non-ignored files: $untracked"
echo
echo "## Local Build Snapshot"
echo
awk '
  /^Debug APK$/ { section = "debug"; next }
  /^Release APK$/ { section = "release"; next }
  /^Rust Android artifacts$/ { section = "rust"; print; next }
  section == "debug" && /^path:|^bytes:|^sha256:|^package:|^sdkVersion:|^targetSdkVersion:|^native-code:/ { print "Debug " $0; next }
  section == "release" && /^path:|^bytes:|^sha256:|^package:|^sdkVersion:|^targetSdkVersion:|^native-code:/ { print "Release " $0; next }
  section == "rust" && /^(arm64-v8a|armeabi-v7a|x86_64):/ { print; next }
' "$tmp_status"
echo
echo "## Validation Commands"
echo
echo "- \`Scripts/validate_android.sh\`"
echo "- \`Scripts/android_final_pr_gate.sh tmp/android-phone-final-gate-real\`"
echo "- Add \`--require-health-success\` only when the final phone run must prove a successful Health Connect platform write."
echo "- \`Scripts/android_phone_final_gate.sh tmp/android-phone-diagnostic-gate-real --require-step-validation\` only for a lower-level diagnostic bundle."
echo "- \`Scripts/android_pr_readiness.sh --strict tmp/android-phone-final-gate-real\` to reprint readiness for an existing final bundle."
echo
echo "## Phone Evidence"
echo
phone_evidence_supplied=0
phone_summary_valid=0
phone_result=""
device_kind=""
capture_verified=0
physical_capture_verified=0
ble_hello_verified=0
installed_package_verified=0
no_android_runtime_crash_verified=0
evidence_manifest_verified=0
evidence_result_verified=0
evidence_pull_result_verified=0
evidence_capture_inspection_verified=0
evidence_ble_inspection_verified=0
evidence_health_inspection_verified=0
evidence_step_inspection_verified=0
evidence_ble_audit_manifest_verified=0
evidence_health_audit_manifest_verified=0
evidence_step_audit_manifest_verified=0
evidence_commit_verified=0
evidence_current_commit_verified=0
evidence_clean_status_verified=0
evidence_device_serial_verified=0
evidence_device_kind_verified=0
evidence_device_identity_verified=0
evidence_android_version_verified=0
evidence_adb_device_verified=0
evidence_collect_error_free=0
step_validation_verified=0
health_attempt_verified=0
health_success_verified=0
require_step_pass=0
require_step_session=0
require_ble_hello=0
require_health_attempt=0
require_health_ready_plan=0
require_health_success=0
bundle_profile="not supplied"
if [[ -n "$PHONE_EVIDENCE_DIR" ]]; then
  summary="$PHONE_EVIDENCE_DIR/phone-handoff-summary.md"
  gates="$PHONE_EVIDENCE_DIR/evidence-gates.txt"
  manifest="$PHONE_EVIDENCE_DIR/evidence-files-manifest.txt"
  inspection_file="$PHONE_EVIDENCE_DIR/inspect-android-capture.txt"
  evidence_result_file="$PHONE_EVIDENCE_DIR/evidence-result.txt"
  pull_result_file="$PHONE_EVIDENCE_DIR/pull-android-database-result.txt"
  collect_error_file="$PHONE_EVIDENCE_DIR/collect-error.txt"
  focused_logcat_file="$PHONE_EVIDENCE_DIR/logcat-goose-brief.txt"
  port_status="$PHONE_EVIDENCE_DIR/android-port-status.txt"
  adb_devices_file="$PHONE_EVIDENCE_DIR/adb-devices.txt"
  android_serial_file="$PHONE_EVIDENCE_DIR/android-serial.txt"
  android_device_kind_file="$PHONE_EVIDENCE_DIR/android-device-kind.txt"
  device_manufacturer_file="$PHONE_EVIDENCE_DIR/device-manufacturer.txt"
  device_model_file="$PHONE_EVIDENCE_DIR/device-model.txt"
  android_version_file="$PHONE_EVIDENCE_DIR/android-version.txt"
  android_sdk_file="$PHONE_EVIDENCE_DIR/android-sdk.txt"
  package_path_file="$PHONE_EVIDENCE_DIR/goose-package-path.txt"
  package_summary_file="$PHONE_EVIDENCE_DIR/goose-package-summary.txt"
  package_dumpsys_file="$PHONE_EVIDENCE_DIR/goose-package-dumpsys.txt"
  local_debug_apk_sha_file="$PHONE_EVIDENCE_DIR/goose-local-debug-apk-sha256.txt"
  installed_apk_sha_file="$PHONE_EVIDENCE_DIR/goose-installed-apk-sha256.txt"
  if [[ -f "$summary" ]]; then
    phone_evidence_supplied=1
    phone_summary_valid=1
    phone_result="$(status_value "Result" "$summary")"
    evidence_result=""
    if [[ -f "$evidence_result_file" ]]; then
      evidence_result="$(awk -F': ' '$1 == "RESULT" { print $2; exit }' "$evidence_result_file")"
    fi
    pull_result=""
    if [[ -f "$pull_result_file" ]]; then
      pull_result="$(awk -F': ' '$1 == "RESULT" { print $2; exit }' "$pull_result_file")"
    fi
    collect_error_bytes=0
    if [[ -f "$collect_error_file" ]]; then
      collect_error_bytes="$(file_size "$collect_error_file")"
    fi
    summary_commit="$(status_value "Commit" "$summary")"
    port_status_commit=""
    port_status_dirty_tracked=""
    port_status_untracked=""
    if [[ -f "$port_status" ]]; then
      port_status_commit="$(status_value "commit" "$port_status")"
      port_status_dirty_tracked="$(status_value "dirty tracked files" "$port_status")"
      port_status_untracked="$(status_value "untracked non-ignored files" "$port_status")"
    fi
    device_serial="$(status_value "Device serial" "$summary")"
    evidence_device_serial=""
    if [[ -f "$android_serial_file" ]]; then
      evidence_device_serial="$(sed -n '1p' "$android_serial_file" | tr -d '\r')"
    fi
    evidence_adb_device_state=""
    if [[ -f "$adb_devices_file" && -n "$device_serial" ]]; then
      evidence_adb_device_state="$(awk -v serial="$device_serial" '$1 == serial { print $2; exit }' "$adb_devices_file")"
    fi
    device_kind="$(status_value "Device kind" "$summary")"
    if [[ -z "$device_kind" ]]; then
      if [[ "$device_serial" == emulator-* ]]; then
        device_kind="emulator"
      else
        device_kind="physical"
      fi
    fi
    evidence_device_kind=""
    if [[ -f "$android_device_kind_file" ]]; then
      evidence_device_kind="$(sed -n '1p' "$android_device_kind_file" | tr -d '\r')"
    fi
    device_identity="$(status_value "Device" "$summary")"
    evidence_device_manufacturer=""
    evidence_device_model=""
    evidence_device_identity=""
    if [[ -f "$device_manufacturer_file" ]]; then
      evidence_device_manufacturer="$(sed -n '1p' "$device_manufacturer_file" | tr -d '\r')"
    fi
    if [[ -f "$device_model_file" ]]; then
      evidence_device_model="$(sed -n '1p' "$device_model_file" | tr -d '\r')"
    fi
    if [[ -n "$evidence_device_manufacturer" || -n "$evidence_device_model" ]]; then
      evidence_device_identity="$evidence_device_manufacturer $evidence_device_model"
    fi
    android_version="$(status_value "Android" "$summary")"
    evidence_android_release=""
    evidence_android_sdk=""
    evidence_android_version=""
    if [[ -f "$android_version_file" ]]; then
      evidence_android_release="$(sed -n '1p' "$android_version_file" | tr -d '\r')"
    fi
    if [[ -f "$android_sdk_file" ]]; then
      evidence_android_sdk="$(sed -n '1p' "$android_sdk_file" | tr -d '\r')"
    fi
    if [[ -n "$evidence_android_release" || -n "$evidence_android_sdk" ]]; then
      evidence_android_version="$evidence_android_release (SDK $evidence_android_sdk)"
    fi
    installed_result="$(summary_bullet_value "Result" "$summary")"
    installed_package_path="$(summary_bullet_value "Package path" "$summary")"
    summary_local_debug_apk_sha="$(summary_bullet_value "Local debug APK SHA-256" "$summary")"
    summary_installed_apk_sha="$(summary_bullet_value "Installed APK SHA-256" "$summary")"
    summary_installed_apk_hash_result="$(summary_bullet_value "Installed APK hash result" "$summary")"
    evidence_package_path=""
    evidence_local_debug_apk_sha=""
    evidence_installed_apk_sha=""
    evidence_package_summary_verified=0
    evidence_package_dumpsys_verified=0
    if [[ -f "$package_path_file" ]]; then
      evidence_package_path="$(sed -n '1p' "$package_path_file" | tr -d '\r')"
    fi
    if [[ -f "$package_summary_file" ]] && grep -q 'versionName=0.1.0' "$package_summary_file"; then
      evidence_package_summary_verified=1
    fi
    if [[ -f "$package_dumpsys_file" ]] && grep -q 'Package \[com.goose.android\]' "$package_dumpsys_file"; then
      evidence_package_dumpsys_verified=1
    fi
    if [[ -f "$local_debug_apk_sha_file" ]]; then
      evidence_local_debug_apk_sha="$(sed -n '1p' "$local_debug_apk_sha_file" | tr -d '\r')"
    fi
    if [[ -f "$installed_apk_sha_file" ]]; then
      evidence_installed_apk_sha="$(sed -n '1p' "$installed_apk_sha_file" | tr -d '\r')"
    fi
    android_runtime_crash_lines="$(summary_bullet_value "Focused AndroidRuntime crash lines" "$summary")"
    evidence_android_runtime_crash_lines=""
    if [[ -f "$focused_logcat_file" ]]; then
      evidence_android_runtime_crash_lines="$(android_runtime_crash_lines "$focused_logcat_file")"
    fi
    raw_rows="$(summary_bullet_value "Raw evidence rows" "$summary")"
    decoded_rows="$(summary_bullet_value "Decoded frame rows" "$summary")"
    capture_sessions="$(summary_bullet_value "Capture sessions" "$summary")"
    session_raw_rows="$(summary_bullet_value "Session raw evidence rows" "$summary")"
    session_live_notification_raw_rows="$(summary_bullet_value "Session live notification raw evidence rows" "$summary")"
    session_decoded_rows="$(summary_bullet_value "Session decoded frame rows" "$summary")"
    finished_sessions="$(summary_bullet_value "Finished nonempty capture sessions" "$summary")"
    inspection_result=""
    inspection_raw_rows=""
    inspection_decoded_rows=""
    inspection_capture_sessions=""
    inspection_session_raw_rows=""
    inspection_session_live_notification_raw_rows=""
    inspection_session_decoded_rows=""
    inspection_finished_sessions=""
    if [[ -f "$inspection_file" ]]; then
      inspection_result="$(status_value "RESULT" "$inspection_file")"
      inspection_raw_rows="$(status_value "raw evidence" "$inspection_file")"
      inspection_decoded_rows="$(status_value "decoded frames" "$inspection_file")"
      inspection_capture_sessions="$(status_value "capture sessions" "$inspection_file")"
      inspection_session_raw_rows="$(status_value "session raw evidence" "$inspection_file")"
      inspection_session_live_notification_raw_rows="$(status_value "session live notification raw evidence" "$inspection_file")"
      inspection_session_decoded_rows="$(status_value "session decoded frames" "$inspection_file")"
      inspection_finished_sessions="$(status_value "finished nonempty capture sessions" "$inspection_file")"
    fi
    ble_ready_events="$(summary_bullet_value "Ready events" "$summary")"
    ble_hello_sent_events="$(summary_bullet_value "Hello sent events" "$summary")"
    ble_client_hello_completed_events="$(summary_bullet_value "Client hello completed events" "$summary")"
    ble_command_ready_events="$(summary_bullet_value "Command ready events" "$summary")"
    inspection_ble_ready_events=""
    inspection_ble_hello_sent_events=""
    inspection_ble_client_hello_completed_events=""
    inspection_ble_command_ready_events=""
    if [[ -f "$inspection_file" ]]; then
      inspection_ble_ready_events="$(status_value "ble session ready events" "$inspection_file")"
      inspection_ble_hello_sent_events="$(status_value "ble session hello sent events" "$inspection_file")"
      inspection_ble_client_hello_completed_events="$(status_value "ble session client hello completed events" "$inspection_file")"
      inspection_ble_command_ready_events="$(status_value "ble session command ready events" "$inspection_file")"
    fi
    health_write_started="$(summary_bullet_value "Write started events" "$summary")"
    health_ready_write_started="$(summary_bullet_value "Ready write started events" "$summary")"
    health_planned_write_started="$(summary_bullet_value "Planned write started events" "$summary")"
    health_candidate_write_started="$(summary_bullet_value "Candidate write started events" "$summary")"
    health_records_attempted="$(summary_bullet_value "Records attempted events" "$summary")"
    health_write_succeeded="$(summary_bullet_value "Write succeeded events" "$summary")"
    inspection_health_write_started=""
    inspection_health_ready_write_started=""
    inspection_health_planned_write_started=""
    inspection_health_candidate_write_started=""
    inspection_health_records_attempted=""
    inspection_health_write_succeeded=""
    if [[ -f "$inspection_file" ]]; then
      inspection_health_write_started="$(status_value "health sync write started events" "$inspection_file")"
      inspection_health_ready_write_started="$(status_value "health sync ready write started events" "$inspection_file")"
      inspection_health_planned_write_started="$(status_value "health sync planned write started events" "$inspection_file")"
      inspection_health_candidate_write_started="$(status_value "health sync candidate write started events" "$inspection_file")"
      inspection_health_records_attempted="$(status_value "health sync records attempted events" "$inspection_file")"
      inspection_health_write_succeeded="$(status_value "health sync write succeeded events" "$inspection_file")"
    fi
    step_completed="$(summary_bullet_value "Completed events" "$summary")"
    step_passed="$(summary_bullet_value "Passed events" "$summary")"
    step_failed="$(summary_bullet_value "Failed events" "$summary")"
    step_session_bound="$(summary_bullet_value "Session-bound events" "$summary")"
    step_session_decoded="$(summary_bullet_value "Session decoded events" "$summary")"
    step_selected_delta="$(summary_bullet_value "Selected delta events" "$summary")"
    step_passing_session_selected_delta="$(summary_bullet_value "Passing session selected-delta events" "$summary")"
    inspection_step_completed=""
    inspection_step_passed=""
    inspection_step_failed=""
    inspection_step_session_bound=""
    inspection_step_session_decoded=""
    inspection_step_selected_delta=""
    inspection_step_passing_session_selected_delta=""
    if [[ -f "$inspection_file" ]]; then
      inspection_step_completed="$(status_value "step validation completed events" "$inspection_file")"
      inspection_step_passed="$(status_value "step validation passed events" "$inspection_file")"
      inspection_step_failed="$(status_value "step validation failed events" "$inspection_file")"
      inspection_step_session_bound="$(status_value "step validation session-bound events" "$inspection_file")"
      inspection_step_session_decoded="$(status_value "step validation session decoded events" "$inspection_file")"
      inspection_step_selected_delta="$(status_value "step validation selected delta events" "$inspection_file")"
      inspection_step_passing_session_selected_delta="$(status_value "step validation passing session selected-delta events" "$inspection_file")"
    fi
    require_step_pass=0
    require_step_session=0
    require_ble_hello=0
    require_health_attempt=0
    require_health_ready_plan=0
    if [[ -f "$gates" ]]; then
      require_ble_hello="$(gate_value "GOOSE_ANDROID_REQUIRE_BLE_HELLO_SENT" "$gates")"
      require_step_pass="$(gate_value "GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_PASS" "$gates")"
      require_step_session="$(gate_value "GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_SESSION" "$gates")"
      require_health_attempt="$(gate_value "GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_ATTEMPT" "$gates")"
      require_health_ready_plan="$(gate_value "GOOSE_ANDROID_REQUIRE_HEALTH_READY_WRITE_PLAN" "$gates")"
      require_health_success="$(gate_value "GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_SUCCESS" "$gates")"
    fi
    if [[ "$phone_result" == "PASS" ]] && verify_evidence_manifest "$PHONE_EVIDENCE_DIR" "$manifest"; then
      evidence_manifest_verified=1
    fi
    if [[ "$evidence_manifest_verified" == "1" \
      && "$phone_result" == "PASS" \
      && "$evidence_result" == "PASS" ]]; then
      evidence_result_verified=1
    fi
    if [[ "$evidence_manifest_verified" == "1" && "$pull_result" == "PASS" ]]; then
      evidence_pull_result_verified=1
    fi
    if [[ "$evidence_manifest_verified" == "1" && "$collect_error_bytes" == "0" ]]; then
      evidence_collect_error_free=1
    fi
    if [[ "$evidence_result_verified" == "1" \
      && "$inspection_result" == "PASS" \
      && "$raw_rows" == "$inspection_raw_rows" \
      && "$decoded_rows" == "$inspection_decoded_rows" \
      && "$capture_sessions" == "$inspection_capture_sessions" \
      && "$session_raw_rows" == "$inspection_session_raw_rows" \
      && "$session_live_notification_raw_rows" == "$inspection_session_live_notification_raw_rows" \
      && "$session_decoded_rows" == "$inspection_session_decoded_rows" \
      && "$finished_sessions" == "$inspection_finished_sessions" ]] \
      && is_positive_int "$raw_rows" \
      && is_positive_int "$decoded_rows" \
      && is_positive_int "$capture_sessions" \
      && is_positive_int "$session_raw_rows" \
      && is_positive_int "$session_live_notification_raw_rows" \
      && is_positive_int "$session_decoded_rows" \
      && is_positive_int "$finished_sessions"; then
      evidence_capture_inspection_verified=1
      capture_verified=1
    fi
    if [[ "$evidence_result_verified" == "1" \
      && "$ble_ready_events" == "$inspection_ble_ready_events" \
      && "$ble_hello_sent_events" == "$inspection_ble_hello_sent_events" \
      && "$ble_client_hello_completed_events" == "$inspection_ble_client_hello_completed_events" \
      && "$ble_command_ready_events" == "$inspection_ble_command_ready_events" ]]; then
      evidence_ble_inspection_verified=1
    fi
    if [[ "$evidence_result_verified" == "1" \
      && "$health_write_started" == "$inspection_health_write_started" \
      && "$health_ready_write_started" == "$inspection_health_ready_write_started" \
      && "$health_planned_write_started" == "$inspection_health_planned_write_started" \
      && "$health_candidate_write_started" == "$inspection_health_candidate_write_started" \
      && "$health_records_attempted" == "$inspection_health_records_attempted" \
      && "$health_write_succeeded" == "$inspection_health_write_succeeded" ]]; then
      evidence_health_inspection_verified=1
    fi
    if [[ "$evidence_result_verified" == "1" \
      && "$step_completed" == "$inspection_step_completed" \
      && "$step_passed" == "$inspection_step_passed" \
      && "$step_failed" == "$inspection_step_failed" \
      && "$step_session_bound" == "$inspection_step_session_bound" \
      && "$step_session_decoded" == "$inspection_step_session_decoded" \
      && "$step_selected_delta" == "$inspection_step_selected_delta" \
      && "$step_passing_session_selected_delta" == "$inspection_step_passing_session_selected_delta" ]]; then
      evidence_step_inspection_verified=1
    fi
    if [[ "$evidence_manifest_verified" == "1" ]] \
      && verify_manifest_file "$PHONE_EVIDENCE_DIR" "$manifest" "goose-phone-ble-session-log.jsonl"; then
      evidence_ble_audit_manifest_verified=1
    fi
    if [[ "$evidence_manifest_verified" == "1" ]] \
      && verify_manifest_file "$PHONE_EVIDENCE_DIR" "$manifest" "goose-phone-health-connect-sync-log.jsonl"; then
      evidence_health_audit_manifest_verified=1
    fi
    if [[ "$evidence_manifest_verified" == "1" ]] \
      && verify_manifest_file "$PHONE_EVIDENCE_DIR" "$manifest" "goose-phone-step-validation-log.jsonl"; then
      evidence_step_audit_manifest_verified=1
    fi
    if [[ "$capture_verified" == "1" && "$device_kind" == "physical" ]]; then
      physical_capture_verified=1
    fi
    if [[ "$evidence_result_verified" == "1" \
      && "$android_runtime_crash_lines" =~ ^[0-9]+$ \
      && "$evidence_android_runtime_crash_lines" =~ ^[0-9]+$ \
      && "$android_runtime_crash_lines" == "$evidence_android_runtime_crash_lines" \
      && "$evidence_android_runtime_crash_lines" -eq 0 ]]; then
      no_android_runtime_crash_verified=1
    fi
    if [[ "$evidence_manifest_verified" == "1" \
      && -n "$summary_commit" \
      && -n "$port_status_commit" \
      && "$summary_commit" == "$port_status_commit" ]]; then
      evidence_commit_verified=1
    fi
    if [[ "$evidence_commit_verified" == "1" && "$summary_commit" == "$latest_commit" ]]; then
      evidence_current_commit_verified=1
    fi
    if [[ "$evidence_manifest_verified" == "1" \
      && "$port_status_dirty_tracked" == "0" \
      && "$port_status_untracked" == "0" ]]; then
      evidence_clean_status_verified=1
    fi
    if [[ "$evidence_manifest_verified" == "1" \
      && -n "$device_serial" \
      && -n "$evidence_device_serial" \
      && "$device_serial" == "$evidence_device_serial" ]]; then
      evidence_device_serial_verified=1
    fi
    if [[ "$evidence_manifest_verified" == "1" \
      && -n "$device_kind" \
      && -n "$evidence_device_kind" \
      && "$device_kind" == "$evidence_device_kind" ]]; then
      evidence_device_kind_verified=1
    fi
    if [[ "$evidence_manifest_verified" == "1" \
      && -n "$device_identity" \
      && -n "$evidence_device_identity" \
      && "$device_identity" == "$evidence_device_identity" ]]; then
      evidence_device_identity_verified=1
    fi
    if [[ "$evidence_manifest_verified" == "1" \
      && -n "$android_version" \
      && -n "$evidence_android_version" \
      && "$android_version" == "$evidence_android_version" ]]; then
      evidence_android_version_verified=1
    fi
    if [[ "$evidence_manifest_verified" == "1" \
      && -n "$device_serial" \
      && "$evidence_adb_device_state" == "device" ]]; then
      evidence_adb_device_verified=1
    fi
    if [[ "$evidence_manifest_verified" == "1" \
      && "$phone_result" == "PASS" \
      && "$installed_result" == "PASS" \
      && "$summary_installed_apk_hash_result" == "PASS" \
      && "$installed_package_path" == package:* \
      && "$installed_package_path" == "$evidence_package_path" \
      && "$evidence_package_summary_verified" == "1" \
      && "$evidence_package_dumpsys_verified" == "1" \
      && "$summary_local_debug_apk_sha" =~ ^[0-9A-Fa-f]{64}$ \
      && "$summary_installed_apk_sha" =~ ^[0-9A-Fa-f]{64}$ \
      && "$evidence_local_debug_apk_sha" =~ ^[0-9A-Fa-f]{64}$ \
      && "$evidence_installed_apk_sha" =~ ^[0-9A-Fa-f]{64}$ \
      && "$(printf '%s' "$summary_local_debug_apk_sha" | tr 'A-F' 'a-f')" == "$(printf '%s' "$evidence_local_debug_apk_sha" | tr 'A-F' 'a-f')" \
      && "$(printf '%s' "$summary_installed_apk_sha" | tr 'A-F' 'a-f')" == "$(printf '%s' "$evidence_installed_apk_sha" | tr 'A-F' 'a-f')" \
      && "$(printf '%s' "$evidence_local_debug_apk_sha" | tr 'A-F' 'a-f')" == "$(printf '%s' "$evidence_installed_apk_sha" | tr 'A-F' 'a-f')" ]]; then
      installed_package_verified=1
    fi
    if [[ "$evidence_ble_inspection_verified" == "1" \
      && "$evidence_ble_audit_manifest_verified" == "1" \
      && "$phone_result" == "PASS" \
      && "$require_ble_hello" == "1" ]] \
      && is_positive_int "$ble_ready_events" \
      && is_positive_int "$ble_hello_sent_events" \
      && is_positive_int "$ble_client_hello_completed_events" \
      && is_positive_int "$ble_command_ready_events"; then
      ble_hello_verified=1
    fi
    if [[ "$evidence_step_inspection_verified" == "1" \
      && "$evidence_step_audit_manifest_verified" == "1" \
      && "$phone_result" == "PASS" \
      && "$require_step_pass" == "1" ]] \
      && is_positive_int "$step_completed" \
      && is_positive_int "$step_passed" \
      && { [[ "$require_step_session" != "1" ]] \
        || { is_positive_int "$step_session_bound" \
          && is_positive_int "$step_session_decoded" \
          && is_positive_int "$step_selected_delta" \
          && is_positive_int "$step_passing_session_selected_delta"; }; }; then
      step_validation_verified=1
    fi
    if [[ "$evidence_health_inspection_verified" == "1" \
      && "$evidence_health_audit_manifest_verified" == "1" \
      && "$phone_result" == "PASS" \
      && "$require_health_attempt" == "1" ]] \
      && is_positive_int "$health_write_started" \
      && { [[ "$require_health_ready_plan" != "1" ]] \
        || { is_positive_int "$health_ready_write_started" \
          && is_positive_int "$health_planned_write_started" \
          && is_positive_int "$health_candidate_write_started" \
          && is_positive_int "$health_records_attempted"; }; }; then
      health_attempt_verified=1
    fi
    if [[ "$evidence_health_inspection_verified" == "1" \
      && "$evidence_health_audit_manifest_verified" == "1" \
      && "$phone_result" == "PASS" \
      && "$require_health_success" == "1" ]] \
      && is_positive_int "$health_write_succeeded"; then
      health_success_verified=1
    fi
    if [[ "$device_kind" == "emulator" ]]; then
      bundle_profile="development emulator evidence"
    elif [[ "$require_step_pass" == "1" && "$require_step_session" == "1" ]]; then
      bundle_profile="final PR evidence"
    elif [[ "$require_ble_hello" == "1" || "$require_health_attempt" == "1" ]]; then
      bundle_profile="partial phone evidence"
    else
      bundle_profile="informational phone evidence"
    fi
    echo "Evidence directory: $PHONE_EVIDENCE_DIR"
    echo "Result: $phone_result"
    echo "Evidence result file: $evidence_result"
    echo "Database pull result file: $pull_result"
    echo "Collection error bytes: $collect_error_bytes"
    echo "Bundle profile: $bundle_profile"
    echo "Device serial: $device_serial"
    echo "Evidence serial file: $evidence_device_serial"
    echo "Device kind: $device_kind"
    echo "Evidence device kind file: $evidence_device_kind"
    echo "Device: $device_identity"
    echo "Evidence device files: $evidence_device_identity"
    echo "Android: $android_version"
    echo "Evidence Android files: $evidence_android_version"
    echo "adb device state: $evidence_adb_device_state"
    echo "Summary commit: $summary_commit"
    echo "Status snapshot commit: $port_status_commit"
    echo "Current checkout commit: $latest_commit"
    echo "Status snapshot dirty tracked files: $port_status_dirty_tracked"
    echo "Status snapshot untracked non-ignored files: $port_status_untracked"
    echo "Focused AndroidRuntime crash lines: $android_runtime_crash_lines"
    echo "Evidence focused AndroidRuntime crash lines: $evidence_android_runtime_crash_lines"
    echo
    echo "Installed app:"
    echo "- Result: $installed_result"
    echo "- Package path: $installed_package_path"
    echo "- Evidence package path file: $evidence_package_path"
    echo "- Evidence package summary versionName=0.1.0: $evidence_package_summary_verified"
    echo "- Evidence package dumpsys com.goose.android: $evidence_package_dumpsys_verified"
    echo "- Local debug APK SHA-256: $summary_local_debug_apk_sha"
    echo "- Evidence local debug APK SHA-256 file: $evidence_local_debug_apk_sha"
    echo "- Installed APK SHA-256: $summary_installed_apk_sha"
    echo "- Evidence installed APK SHA-256 file: $evidence_installed_apk_sha"
    echo "- Installed APK hash result: $summary_installed_apk_hash_result"
    echo
    echo "Capture evidence:"
    echo "- Raw evidence rows: $raw_rows"
    echo "- Inspect raw evidence rows: $inspection_raw_rows"
    echo "- Decoded frame rows: $decoded_rows"
    echo "- Inspect decoded frame rows: $inspection_decoded_rows"
    echo "- Capture sessions: $capture_sessions"
    echo "- Inspect capture sessions: $inspection_capture_sessions"
    echo "- Session raw evidence rows: $session_raw_rows"
    echo "- Inspect session raw evidence rows: $inspection_session_raw_rows"
    echo "- Session live notification raw evidence rows: $session_live_notification_raw_rows"
    echo "- Inspect session live notification raw evidence rows: $inspection_session_live_notification_raw_rows"
    echo "- Session decoded frame rows: $session_decoded_rows"
    echo "- Inspect session decoded frame rows: $inspection_session_decoded_rows"
    echo "- Finished nonempty capture sessions: $finished_sessions"
    echo "- Inspect finished nonempty capture sessions: $inspection_finished_sessions"
    echo "- Step samples: $(summary_bullet_value "Step samples" "$summary")"
    echo "- Daily activity metrics: $(summary_bullet_value "Daily activity metrics" "$summary")"
    echo
    echo "BLE session evidence:"
    echo "- Audit manifest verified: $evidence_ble_audit_manifest_verified"
    echo "- Ready events: $ble_ready_events"
    echo "- Inspect ready events: $inspection_ble_ready_events"
    echo "- Hello sent events: $ble_hello_sent_events"
    echo "- Inspect hello sent events: $inspection_ble_hello_sent_events"
    echo "- Client hello completed events: $ble_client_hello_completed_events"
    echo "- Inspect client hello completed events: $inspection_ble_client_hello_completed_events"
    echo "- Command ready events: $ble_command_ready_events"
    echo "- Inspect command ready events: $inspection_ble_command_ready_events"
    echo
    echo "Health Connect evidence:"
    echo "- Audit manifest verified: $evidence_health_audit_manifest_verified"
    echo "- Write started events: $health_write_started"
    echo "- Inspect write started events: $inspection_health_write_started"
    echo "- Ready write started events: $health_ready_write_started"
    echo "- Inspect ready write started events: $inspection_health_ready_write_started"
    echo "- Planned write started events: $health_planned_write_started"
    echo "- Inspect planned write started events: $inspection_health_planned_write_started"
    echo "- Candidate write started events: $health_candidate_write_started"
    echo "- Inspect candidate write started events: $inspection_health_candidate_write_started"
    echo "- Records attempted events: $health_records_attempted"
    echo "- Inspect records attempted events: $inspection_health_records_attempted"
    echo "- Write succeeded events: $health_write_succeeded"
    echo "- Inspect write succeeded events: $inspection_health_write_succeeded"
    echo "- Write failed events: $(summary_bullet_value "Write failed events" "$summary")"
    echo
    echo "Step validation evidence:"
    echo "- Audit manifest verified: $evidence_step_audit_manifest_verified"
    echo "- Completed events: $step_completed"
    echo "- Inspect completed events: $inspection_step_completed"
    echo "- Passed events: $step_passed"
    echo "- Inspect passed events: $inspection_step_passed"
    echo "- Failed events: $step_failed"
    echo "- Inspect failed events: $inspection_step_failed"
    echo "- Session-bound events: $step_session_bound"
    echo "- Inspect session-bound events: $inspection_step_session_bound"
    echo "- Session decoded events: $step_session_decoded"
    echo "- Inspect session decoded events: $inspection_step_session_decoded"
    echo "- Selected delta events: $step_selected_delta"
    echo "- Inspect selected delta events: $inspection_step_selected_delta"
    echo "- Passing session selected-delta events: $step_passing_session_selected_delta"
    echo "- Inspect passing session selected-delta events: $inspection_step_passing_session_selected_delta"
    echo
    echo "Gate configuration:"
    if [[ -f "$gates" ]]; then
      sed 's/^/- /' "$gates"
    else
      echo "- missing evidence-gates.txt"
    fi
  else
    echo "Evidence directory supplied, but phone-handoff-summary.md is missing: $PHONE_EVIDENCE_DIR"
  fi
else
  echo "No phone evidence directory supplied."
fi
echo
echo "## Evidence Bundle Classification"
echo
case "$bundle_profile" in
  "final PR evidence")
    echo "- The supplied bundle was collected with required counted-step validation gates enabled."
    ;;
  "partial phone evidence")
    echo "- The supplied bundle was collected without required counted-step validation gates. It can prove BLE/capture/Health Connect items, but it is not enough for final PR readiness."
    ;;
  "development emulator evidence")
    echo "- The supplied bundle is emulator/development evidence. It is useful for smoke tests, but final PR readiness requires a physical Android phone."
    ;;
  "informational phone evidence")
    echo "- The supplied bundle did not enable the final or partial acceptance gates. Treat it as diagnostic evidence only."
    ;;
  *)
    echo "- No phone evidence bundle was supplied."
    ;;
esac
echo
echo "## Verified Phone Acceptance"
echo
verified_any=0
if [[ "$capture_verified" == "1" ]]; then
  echo "- Controlled capture database pull has raw evidence, decoded frames, capture session, session-tagged Android BLE live-notification raw evidence, session-tagged decoded frames, and a finished nonempty session."
  verified_any=1
fi
if [[ "$physical_capture_verified" == "1" ]]; then
  echo "- Capture evidence came from a non-emulator Android device."
  verified_any=1
fi
if [[ "$installed_package_verified" == "1" ]]; then
  echo "- Installed com.goose.android package metadata and APK hash match passed the evidence gate."
  verified_any=1
fi
if [[ "$no_android_runtime_crash_verified" == "1" ]]; then
  echo "- Focused AndroidRuntime logcat has no com.goose.android crash lines."
  verified_any=1
fi
if [[ "$evidence_manifest_verified" == "1" ]]; then
  echo "- Evidence file manifest verifies byte counts and SHA-256 hashes for required evidence files."
  verified_any=1
fi
if [[ "$evidence_result_verified" == "1" ]]; then
  echo "- Phone handoff summary result matches evidence-result.txt."
  verified_any=1
fi
if [[ "$evidence_pull_result_verified" == "1" ]]; then
  echo "- Android database pull helper result is PASS in the evidence bundle."
  verified_any=1
fi
if [[ "$evidence_collect_error_free" == "1" ]]; then
  echo "- Evidence bundle has no collection error diagnostics."
  verified_any=1
fi
if [[ "$evidence_capture_inspection_verified" == "1" ]]; then
  echo "- Phone handoff capture counts match inspect-android-capture.txt."
  verified_any=1
fi
if [[ "$evidence_ble_inspection_verified" == "1" ]]; then
  echo "- Phone handoff BLE session counts match inspect-android-capture.txt."
  verified_any=1
fi
if [[ "$evidence_health_inspection_verified" == "1" ]]; then
  echo "- Phone handoff Health Connect counts match inspect-android-capture.txt."
  verified_any=1
fi
if [[ "$evidence_step_inspection_verified" == "1" ]]; then
  echo "- Phone handoff step-validation counts match inspect-android-capture.txt."
  verified_any=1
fi
if [[ "$evidence_ble_audit_manifest_verified" == "1" ]]; then
  echo "- BLE session audit log is included in the evidence byte/hash manifest."
  verified_any=1
fi
if [[ "$evidence_health_audit_manifest_verified" == "1" ]]; then
  echo "- Health Connect audit log is included in the evidence byte/hash manifest."
  verified_any=1
fi
if [[ "$evidence_step_audit_manifest_verified" == "1" ]]; then
  echo "- Step-validation audit log is included in the evidence byte/hash manifest."
  verified_any=1
fi
if [[ "$evidence_commit_verified" == "1" ]]; then
  echo "- Phone handoff summary commit matches the Android port status snapshot."
  verified_any=1
fi
if [[ "$evidence_current_commit_verified" == "1" ]]; then
  echo "- Phone evidence commit matches the current checkout commit."
  verified_any=1
fi
if [[ "$evidence_clean_status_verified" == "1" ]]; then
  echo "- Phone evidence status snapshot was collected from a clean worktree."
  verified_any=1
fi
if [[ "$evidence_device_serial_verified" == "1" ]]; then
  echo "- Phone handoff summary device serial matches android-serial.txt."
  verified_any=1
fi
if [[ "$evidence_device_kind_verified" == "1" ]]; then
  echo "- Phone handoff summary device kind matches android-device-kind.txt."
  verified_any=1
fi
if [[ "$evidence_device_identity_verified" == "1" ]]; then
  echo "- Phone handoff summary device identity matches device-manufacturer.txt and device-model.txt."
  verified_any=1
fi
if [[ "$evidence_android_version_verified" == "1" ]]; then
  echo "- Phone handoff summary Android version matches android-version.txt and android-sdk.txt."
  verified_any=1
fi
if [[ "$evidence_adb_device_verified" == "1" ]]; then
  echo "- adb-devices.txt lists the handoff device serial as online."
  verified_any=1
fi
if [[ "$ble_hello_verified" == "1" ]]; then
  echo "- BLE session audit proves the app reached ready state with command characteristic ready and completed client hello write."
  verified_any=1
fi
if [[ "$step_validation_verified" == "1" ]]; then
  echo "- Counted-step validation passed under the required final gate with capture-session-bound decoded frames and a nonzero selected counter delta in the same audit row."
  verified_any=1
fi
if [[ "$health_attempt_verified" == "1" ]]; then
  echo "- Health Connect write attempt was recorded under the required final gate with permissions-ready planned-write context."
  verified_any=1
fi
if [[ "$health_success_verified" == "1" ]]; then
  echo "- Health Connect write success was recorded under the required final gate."
  verified_any=1
fi
if [[ "$verified_any" == "0" ]]; then
  echo "- No phone-bound acceptance item is fully proven by the supplied evidence bundle."
fi
echo
echo "## Remaining Phone-Bound Acceptance"
echo
remaining_any=0
if [[ "$phone_evidence_supplied" != "1" || "$phone_summary_valid" != "1" || "$phone_result" != "PASS" ]]; then
  echo "- Final phone evidence bundle must pass on a real Android phone."
  remaining_any=1
fi
if [[ "$physical_capture_verified" != "1" ]]; then
  echo "- Physical WHOOP scan/connect validation and controlled capture pull inspected with \`Scripts/inspect_android_capture.sh\`."
  remaining_any=1
fi
if [[ "$installed_package_verified" != "1" ]]; then
  echo "- Installed com.goose.android package metadata and APK hash match must pass the evidence gate."
  remaining_any=1
fi
if [[ "$ble_hello_verified" != "1" ]]; then
  echo "- BLE session audit from the final gate must prove command characteristic readiness and completed client hello write."
  remaining_any=1
fi
if [[ "$require_ble_hello" == "1" && "$evidence_ble_audit_manifest_verified" != "1" ]]; then
  echo "- BLE session audit log must be included in the evidence byte/hash manifest."
  remaining_any=1
fi
if [[ "$no_android_runtime_crash_verified" != "1" ]]; then
  echo "- Focused AndroidRuntime logcat must have 0 com.goose.android crash lines."
  remaining_any=1
fi
if [[ "$evidence_manifest_verified" != "1" ]]; then
  echo "- Evidence bundle must include a valid evidence-files-manifest.txt with matching path, byte, and SHA-256 columns for required evidence files."
  remaining_any=1
fi
if [[ "$evidence_result_verified" != "1" ]]; then
  echo "- Phone handoff summary result must match evidence-result.txt."
  remaining_any=1
fi
if [[ "$evidence_pull_result_verified" != "1" ]]; then
  echo "- Android database pull helper result must be present and PASS."
  remaining_any=1
fi
if [[ "$evidence_collect_error_free" != "1" ]]; then
  echo "- Evidence bundle must not contain nonempty collect-error.txt diagnostics."
  remaining_any=1
fi
if [[ "$evidence_capture_inspection_verified" != "1" ]]; then
  echo "- Phone handoff capture counts, including decoded frame counts, must match inspect-android-capture.txt."
  remaining_any=1
fi
if [[ "$evidence_ble_inspection_verified" != "1" ]]; then
  echo "- Phone handoff BLE session counts must match inspect-android-capture.txt."
  remaining_any=1
fi
if [[ "$evidence_health_inspection_verified" != "1" ]]; then
  echo "- Phone handoff Health Connect counts must match inspect-android-capture.txt."
  remaining_any=1
fi
if [[ "$evidence_step_inspection_verified" != "1" ]]; then
  echo "- Phone handoff step-validation counts must match inspect-android-capture.txt."
  remaining_any=1
fi
if [[ "$evidence_commit_verified" != "1" ]]; then
  echo "- Phone handoff summary commit must match android-port-status.txt."
  remaining_any=1
fi
if [[ "$evidence_current_commit_verified" != "1" ]]; then
  echo "- Phone evidence commit must match the current checkout commit."
  remaining_any=1
fi
if [[ "$evidence_clean_status_verified" != "1" ]]; then
  echo "- Phone evidence status snapshot must show 0 dirty tracked files and 0 untracked non-ignored files."
  remaining_any=1
fi
if [[ "$evidence_device_serial_verified" != "1" ]]; then
  echo "- Phone handoff summary device serial must match android-serial.txt."
  remaining_any=1
fi
if [[ "$evidence_device_kind_verified" != "1" ]]; then
  echo "- Phone handoff summary device kind must match android-device-kind.txt."
  remaining_any=1
fi
if [[ "$evidence_device_identity_verified" != "1" ]]; then
  echo "- Phone handoff summary device identity must match device-manufacturer.txt and device-model.txt."
  remaining_any=1
fi
if [[ "$evidence_android_version_verified" != "1" ]]; then
  echo "- Phone handoff summary Android version must match android-version.txt and android-sdk.txt."
  remaining_any=1
fi
if [[ "$evidence_adb_device_verified" != "1" ]]; then
  echo "- adb-devices.txt must list the handoff device serial as online."
  remaining_any=1
fi
if [[ "$step_validation_verified" != "1" ]]; then
  echo "- Step-counter decoder confirmation from real counted-step evidence with \`--require-step-validation\`, capture-session binding, decoded session frames, and a nonzero selected counter delta in the same audit row."
  remaining_any=1
fi
if [[ "$require_step_pass" == "1" && "$evidence_step_audit_manifest_verified" != "1" ]]; then
  echo "- Step-validation audit log must be included in the evidence byte/hash manifest."
  remaining_any=1
fi
if [[ "$health_attempt_verified" != "1" ]]; then
  echo "- Health Connect permission grant and real planned write attempt on Android 14+, including permissions-ready planned-write context."
  remaining_any=1
fi
if [[ "$require_health_attempt" == "1" && "$evidence_health_audit_manifest_verified" != "1" ]]; then
  echo "- Health Connect audit log must be included in the evidence byte/hash manifest."
  remaining_any=1
fi
if [[ "$require_health_success" == "1" && "$health_success_verified" != "1" ]]; then
  echo "- Health Connect successful platform write must be recorded because the final gate required it."
  remaining_any=1
fi
if [[ "$remaining_any" == "0" ]]; then
  echo "- None from the supplied evidence bundle."
fi

if [[ "$STRICT" == "1" && "$remaining_any" != "0" ]]; then
  echo
  echo "Strict PR readiness: FAIL" >&2
  exit 1
fi

if [[ "$STRICT" == "1" ]]; then
  echo
  echo "Strict PR readiness: PASS"
fi
