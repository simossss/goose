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

verify_evidence_manifest() {
  local dir="$1"
  local manifest="$2"
  local line_number=0
  local verified_count=0
  local saw_summary=0
  local saw_gates=0
  local saw_inspection=0
  local saw_database=0
  local saw_logcat=0
  local saw_package_summary=0
  local saw_local_apk_sha=0
  local saw_installed_apk_sha=0
  local saw_device_kind=0
  local saw_result=0

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
    if [[ "$rel_path" == "phone-handoff-summary.md" ]]; then
      saw_summary=1
    elif [[ "$rel_path" == "evidence-gates.txt" ]]; then
      saw_gates=1
    elif [[ "$rel_path" == "inspect-android-capture.txt" ]]; then
      saw_inspection=1
    elif [[ "$rel_path" == "goose-phone.sqlite" ]]; then
      saw_database=1
    elif [[ "$rel_path" == "logcat-goose-brief.txt" ]]; then
      saw_logcat=1
    elif [[ "$rel_path" == "goose-package-summary.txt" ]]; then
      saw_package_summary=1
    elif [[ "$rel_path" == "goose-local-debug-apk-sha256.txt" ]]; then
      saw_local_apk_sha=1
    elif [[ "$rel_path" == "goose-installed-apk-sha256.txt" ]]; then
      saw_installed_apk_sha=1
    elif [[ "$rel_path" == "android-device-kind.txt" ]]; then
      saw_device_kind=1
    elif [[ "$rel_path" == "evidence-result.txt" ]]; then
      saw_result=1
    fi
    verified_count=$((verified_count + 1))
  done < "$manifest"

  [[ "$verified_count" -gt 0 \
    && "$saw_summary" == "1" \
    && "$saw_gates" == "1" \
    && "$saw_inspection" == "1" \
    && "$saw_database" == "1" \
    && "$saw_logcat" == "1" \
    && "$saw_package_summary" == "1" \
    && "$saw_local_apk_sha" == "1" \
    && "$saw_installed_apk_sha" == "1" \
    && "$saw_device_kind" == "1" \
    && "$saw_result" == "1" ]]
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
echo "- \`Scripts/android_pr_readiness.sh --strict [output-dir]\` after final phone evidence is collected."
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
step_validation_verified=0
health_attempt_verified=0
health_success_verified=0
require_health_success=0
bundle_profile="not supplied"
if [[ -n "$PHONE_EVIDENCE_DIR" ]]; then
  summary="$PHONE_EVIDENCE_DIR/phone-handoff-summary.md"
  gates="$PHONE_EVIDENCE_DIR/evidence-gates.txt"
  manifest="$PHONE_EVIDENCE_DIR/evidence-files-manifest.txt"
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
    android_runtime_crash_lines="$(summary_bullet_value "Focused AndroidRuntime crash lines" "$summary")"
    raw_rows="$(summary_bullet_value "Raw evidence rows" "$summary")"
    capture_sessions="$(summary_bullet_value "Capture sessions" "$summary")"
    session_raw_rows="$(summary_bullet_value "Session raw evidence rows" "$summary")"
    session_live_notification_raw_rows="$(summary_bullet_value "Session live notification raw evidence rows" "$summary")"
    finished_sessions="$(summary_bullet_value "Finished nonempty capture sessions" "$summary")"
    ble_ready_events="$(summary_bullet_value "Ready events" "$summary")"
    ble_hello_sent_events="$(summary_bullet_value "Hello sent events" "$summary")"
    ble_command_ready_events="$(summary_bullet_value "Command ready events" "$summary")"
    health_write_started="$(summary_bullet_value "Write started events" "$summary")"
    health_ready_write_started="$(summary_bullet_value "Ready write started events" "$summary")"
    health_planned_write_started="$(summary_bullet_value "Planned write started events" "$summary")"
    health_candidate_write_started="$(summary_bullet_value "Candidate write started events" "$summary")"
    health_records_attempted="$(summary_bullet_value "Records attempted events" "$summary")"
    health_write_succeeded="$(summary_bullet_value "Write succeeded events" "$summary")"
    step_completed="$(summary_bullet_value "Completed events" "$summary")"
    step_passed="$(summary_bullet_value "Passed events" "$summary")"
    step_session_bound="$(summary_bullet_value "Session-bound events" "$summary")"
    step_session_decoded="$(summary_bullet_value "Session decoded events" "$summary")"
    step_selected_delta="$(summary_bullet_value "Selected delta events" "$summary")"
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
    if [[ "$phone_result" == "PASS" ]] \
      && is_positive_int "$raw_rows" \
      && is_positive_int "$capture_sessions" \
      && is_positive_int "$session_raw_rows" \
      && is_positive_int "$session_live_notification_raw_rows" \
      && is_positive_int "$finished_sessions"; then
      capture_verified=1
    fi
    if [[ "$capture_verified" == "1" && "$device_kind" == "physical" ]]; then
      physical_capture_verified=1
    fi
    if [[ "$phone_result" == "PASS" && "$installed_result" == "PASS" ]]; then
      installed_package_verified=1
    fi
    if [[ "$phone_result" == "PASS" && "$android_runtime_crash_lines" =~ ^[0-9]+$ && "$android_runtime_crash_lines" -eq 0 ]]; then
      no_android_runtime_crash_verified=1
    fi
    if [[ "$phone_result" == "PASS" ]] && verify_evidence_manifest "$PHONE_EVIDENCE_DIR" "$manifest"; then
      evidence_manifest_verified=1
    fi
    if [[ "$phone_result" == "PASS" && "$require_ble_hello" == "1" ]] \
      && is_positive_int "$ble_ready_events" \
      && is_positive_int "$ble_hello_sent_events" \
      && is_positive_int "$ble_command_ready_events"; then
      ble_hello_verified=1
    fi
    if [[ "$phone_result" == "PASS" && "$require_step_pass" == "1" ]] \
      && is_positive_int "$step_completed" \
      && is_positive_int "$step_passed" \
      && { [[ "$require_step_session" != "1" ]] \
        || { is_positive_int "$step_session_bound" \
          && is_positive_int "$step_session_decoded" \
          && is_positive_int "$step_selected_delta"; }; }; then
      step_validation_verified=1
    fi
    if [[ "$phone_result" == "PASS" && "$require_health_attempt" == "1" ]] \
      && is_positive_int "$health_write_started" \
      && { [[ "$require_health_ready_plan" != "1" ]] \
        || { is_positive_int "$health_ready_write_started" \
          && is_positive_int "$health_planned_write_started" \
          && is_positive_int "$health_candidate_write_started" \
          && is_positive_int "$health_records_attempted"; }; }; then
      health_attempt_verified=1
    fi
    if [[ "$phone_result" == "PASS" && "$require_health_success" == "1" ]] \
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
    echo "Bundle profile: $bundle_profile"
    echo "Device serial: $device_serial"
    echo "Device kind: $device_kind"
    echo "Device: $(status_value "Device" "$summary")"
    echo "Android: $(status_value "Android" "$summary")"
    echo "Focused AndroidRuntime crash lines: $android_runtime_crash_lines"
    echo
    echo "Installed app:"
    echo "- Result: $installed_result"
    echo "- Package path: $(summary_bullet_value "Package path" "$summary")"
    echo "- Local debug APK SHA-256: $(summary_bullet_value "Local debug APK SHA-256" "$summary")"
    echo "- Installed APK SHA-256: $(summary_bullet_value "Installed APK SHA-256" "$summary")"
    echo "- Installed APK hash result: $(summary_bullet_value "Installed APK hash result" "$summary")"
    echo
    echo "Capture evidence:"
    echo "- Raw evidence rows: $raw_rows"
    echo "- Capture sessions: $capture_sessions"
    echo "- Session raw evidence rows: $session_raw_rows"
    echo "- Session live notification raw evidence rows: $session_live_notification_raw_rows"
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
    echo "- Ready write started events: $health_ready_write_started"
    echo "- Planned write started events: $health_planned_write_started"
    echo "- Candidate write started events: $health_candidate_write_started"
    echo "- Records attempted events: $health_records_attempted"
    echo "- Write succeeded events: $health_write_succeeded"
    echo "- Write failed events: $(summary_bullet_value "Write failed events" "$summary")"
    echo
    echo "Step validation evidence:"
    echo "- Completed events: $step_completed"
    echo "- Passed events: $step_passed"
    echo "- Failed events: $(summary_bullet_value "Failed events" "$summary")"
    echo "- Session-bound events: $step_session_bound"
    echo "- Session decoded events: $step_session_decoded"
    echo "- Selected delta events: $step_selected_delta"
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
  echo "- Controlled capture database pull has raw evidence, capture session, session-tagged Android BLE live-notification raw evidence, and a finished nonempty session."
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
if [[ "$ble_hello_verified" == "1" ]]; then
  echo "- BLE session audit proves the app reached ready state with command characteristic ready and client hello sent."
  verified_any=1
fi
if [[ "$step_validation_verified" == "1" ]]; then
  echo "- Counted-step validation passed under the required final gate with capture-session-bound decoded frames."
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
  echo "- BLE session audit from the final gate must prove command characteristic readiness and client hello sent."
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
if [[ "$step_validation_verified" != "1" ]]; then
  echo "- Step-counter decoder confirmation from real counted-step evidence with \`--require-step-validation\`, capture-session binding, decoded session frames, and selected counter delta."
  remaining_any=1
fi
if [[ "$health_attempt_verified" != "1" ]]; then
  echo "- Health Connect permission grant and real planned write attempt on Android 14+, including permissions-ready planned-write context."
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
