#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PHONE_EVIDENCE_DIR="${1:-}"

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
echo "- \`Scripts/android_phone_final_gate.sh [output-dir] --require-step-validation\`"
echo "- Add \`--require-health-success\` only when the final phone run must prove a successful Health Connect platform write."
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
step_validation_verified=0
health_attempt_verified=0
health_success_verified=0
if [[ -n "$PHONE_EVIDENCE_DIR" ]]; then
  summary="$PHONE_EVIDENCE_DIR/phone-handoff-summary.md"
  gates="$PHONE_EVIDENCE_DIR/evidence-gates.txt"
  if [[ -f "$summary" ]]; then
    phone_evidence_supplied=1
    phone_summary_valid=1
    phone_result="$(status_value "Result" "$summary")"
    device_serial="$(status_value "Device serial" "$summary")"
    device_kind="$(status_value "Device kind" "$summary")"
    if [[ -z "$device_kind" ]]; then
      if [[ "$device_serial" == emulator-* ]]; then
        device_kind="emulator"
      else
        device_kind="physical"
      fi
    fi
    installed_result="$(summary_bullet_value "Result" "$summary")"
    raw_rows="$(summary_bullet_value "Raw evidence rows" "$summary")"
    capture_sessions="$(summary_bullet_value "Capture sessions" "$summary")"
    session_raw_rows="$(summary_bullet_value "Session raw evidence rows" "$summary")"
    finished_sessions="$(summary_bullet_value "Finished nonempty capture sessions" "$summary")"
    ble_ready_events="$(summary_bullet_value "Ready events" "$summary")"
    ble_hello_sent_events="$(summary_bullet_value "Hello sent events" "$summary")"
    ble_command_ready_events="$(summary_bullet_value "Command ready events" "$summary")"
    health_write_started="$(summary_bullet_value "Write started events" "$summary")"
    health_write_succeeded="$(summary_bullet_value "Write succeeded events" "$summary")"
    step_completed="$(summary_bullet_value "Completed events" "$summary")"
    step_passed="$(summary_bullet_value "Passed events" "$summary")"
    require_step_pass=0
    require_ble_hello=0
    require_health_attempt=0
    require_health_success=0
    if [[ -f "$gates" ]]; then
      require_ble_hello="$(gate_value "GOOSE_ANDROID_REQUIRE_BLE_HELLO_SENT" "$gates")"
      require_step_pass="$(gate_value "GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_PASS" "$gates")"
      require_health_attempt="$(gate_value "GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_ATTEMPT" "$gates")"
      require_health_success="$(gate_value "GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_SUCCESS" "$gates")"
    fi
    if [[ "$phone_result" == "PASS" ]] \
      && is_positive_int "$raw_rows" \
      && is_positive_int "$capture_sessions" \
      && is_positive_int "$session_raw_rows" \
      && is_positive_int "$finished_sessions"; then
      capture_verified=1
    fi
    if [[ "$capture_verified" == "1" && "$device_kind" == "physical" ]]; then
      physical_capture_verified=1
    fi
    if [[ "$phone_result" == "PASS" && "$installed_result" == "PASS" ]]; then
      installed_package_verified=1
    fi
    if [[ "$phone_result" == "PASS" && "$require_ble_hello" == "1" ]] \
      && is_positive_int "$ble_ready_events" \
      && is_positive_int "$ble_hello_sent_events" \
      && is_positive_int "$ble_command_ready_events"; then
      ble_hello_verified=1
    fi
    if [[ "$phone_result" == "PASS" && "$require_step_pass" == "1" ]] \
      && is_positive_int "$step_completed" \
      && is_positive_int "$step_passed"; then
      step_validation_verified=1
    fi
    if [[ "$phone_result" == "PASS" && "$require_health_attempt" == "1" ]] \
      && is_positive_int "$health_write_started"; then
      health_attempt_verified=1
    fi
    if [[ "$phone_result" == "PASS" && "$require_health_success" == "1" ]] \
      && is_positive_int "$health_write_succeeded"; then
      health_success_verified=1
    fi
    echo "Evidence directory: $PHONE_EVIDENCE_DIR"
    echo "Result: $phone_result"
    echo "Device serial: $device_serial"
    echo "Device kind: $device_kind"
    echo "Device: $(status_value "Device" "$summary")"
    echo "Android: $(status_value "Android" "$summary")"
    echo
    echo "Installed app:"
    echo "- Result: $installed_result"
    echo "- Package path: $(summary_bullet_value "Package path" "$summary")"
    echo
    echo "Capture evidence:"
    echo "- Raw evidence rows: $raw_rows"
    echo "- Capture sessions: $capture_sessions"
    echo "- Session raw evidence rows: $session_raw_rows"
    echo "- Finished nonempty capture sessions: $finished_sessions"
    echo "- Step samples: $(summary_bullet_value "Step samples" "$summary")"
    echo "- Daily activity metrics: $(summary_bullet_value "Daily activity metrics" "$summary")"
    echo
    echo "BLE session evidence:"
    echo "- Ready events: $ble_ready_events"
    echo "- Hello sent events: $ble_hello_sent_events"
    echo "- Command ready events: $ble_command_ready_events"
    echo
    echo "Health Connect evidence:"
    echo "- Write started events: $health_write_started"
    echo "- Write succeeded events: $health_write_succeeded"
    echo "- Write failed events: $(summary_bullet_value "Write failed events" "$summary")"
    echo
    echo "Step validation evidence:"
    echo "- Completed events: $step_completed"
    echo "- Passed events: $step_passed"
    echo "- Failed events: $(summary_bullet_value "Failed events" "$summary")"
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
echo "## Verified Phone Acceptance"
echo
verified_any=0
if [[ "$capture_verified" == "1" ]]; then
  echo "- Controlled capture database pull has raw evidence, capture session, session-tagged raw evidence, and a finished nonempty session."
  verified_any=1
fi
if [[ "$physical_capture_verified" == "1" ]]; then
  echo "- Capture evidence came from a non-emulator Android device."
  verified_any=1
fi
if [[ "$installed_package_verified" == "1" ]]; then
  echo "- Installed com.goose.android package metadata is present and passed the evidence gate."
  verified_any=1
fi
if [[ "$ble_hello_verified" == "1" ]]; then
  echo "- BLE session audit proves the app reached ready state with command characteristic ready and client hello sent."
  verified_any=1
fi
if [[ "$step_validation_verified" == "1" ]]; then
  echo "- Counted-step validation passed under the required final gate."
  verified_any=1
fi
if [[ "$health_attempt_verified" == "1" ]]; then
  echo "- Health Connect write attempt was recorded under the required final gate."
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
if [[ "$ble_hello_verified" != "1" ]]; then
  echo "- BLE session audit from the final gate must prove command characteristic readiness and client hello sent."
  remaining_any=1
fi
if [[ "$step_validation_verified" != "1" ]]; then
  echo "- Step-counter decoder confirmation from real counted-step evidence with \`--require-step-validation\`."
  remaining_any=1
fi
if [[ "$health_attempt_verified" != "1" ]]; then
  echo "- Health Connect permission grant and real planned write attempt on Android 14+."
  remaining_any=1
fi
if [[ "$remaining_any" == "0" ]]; then
  echo "- None from the supplied evidence bundle."
fi
