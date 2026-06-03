#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ANDROID_DIR="$APP_DIR/GooseAndroid"

GRADLEW="$ANDROID_DIR/gradlew"
if [[ -z "${ADB:-}" && -x "$HOME/Library/Android/sdk/platform-tools/adb" ]]; then
  ADB="$HOME/Library/Android/sdk/platform-tools/adb"
fi
ADB="${ADB:-adb}"

export ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"

if [[ -d "/Applications/Android Studio.app/Contents/jbr/Contents/Home" ]]; then
  export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
fi

if [[ -n "${JAVA_HOME:-}" ]]; then
  export PATH="$JAVA_HOME/bin:$PATH"
fi

IFS=' ' read -r -a GOOSE_ANDROID_ABIS <<< "${ANDROID_ABIS:-arm64-v8a armeabi-v7a x86_64}"

TMP_FILES=()
TMP_DIRS=()
cleanup_tmp_files() {
  for file in "${TMP_FILES[@]}"; do
    rm -f "$file"
  done
  for dir in "${TMP_DIRS[@]}"; do
    rm -rf "$dir"
  done
}
trap cleanup_tmp_files EXIT

assert_file_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"

  if ! grep -Fq -- "$needle" "$file"; then
    echo "$label missing expected output: $needle" >&2
    exit 1
  fi
}

echo "==> Checking Android helper shell syntax"
bash -n "$SCRIPT_DIR/android_final_phone_checklist.sh"
bash -n "$SCRIPT_DIR/android_final_pr_gate.sh"
bash -n "$SCRIPT_DIR/android_partial_phone_gate.sh"
bash -n "$SCRIPT_DIR/android_port_status.sh"
bash -n "$SCRIPT_DIR/android_phone_final_gate.sh"
bash -n "$SCRIPT_DIR/android_pr_readiness.sh"
bash -n "$SCRIPT_DIR/build_android_rust.sh"
bash -n "$SCRIPT_DIR/collect_android_phone_evidence.sh"
bash -n "$SCRIPT_DIR/install_android_debug.sh"
bash -n "$SCRIPT_DIR/inspect_android_capture.sh"
bash -n "$SCRIPT_DIR/pull_android_database.sh"
bash -n "$SCRIPT_DIR/validate_android.sh"

echo "==> Checking Android handoff helper output"
checklist_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-checklist.XXXXXX")"
readiness_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-readiness.XXXXXX")"
readiness_strict_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-readiness-strict.XXXXXX")"
readiness_strict_pass_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-readiness-strict-pass.XXXXXX")"
final_gate_dry_run_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-final-gate-dry-run.XXXXXX")"
partial_gate_dry_run_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-partial-gate-dry-run.XXXXXX")"
TMP_FILES+=("$checklist_output" "$readiness_output" "$readiness_strict_output" "$readiness_strict_pass_output" "$final_gate_dry_run_output" "$partial_gate_dry_run_output")
synthetic_evidence_dir="$(mktemp -d "${TMPDIR:-/tmp}/goose-android-final-evidence.XXXXXX")"
TMP_DIRS+=("$synthetic_evidence_dir")
"$SCRIPT_DIR/android_final_phone_checklist.sh" > "$checklist_output"
"$SCRIPT_DIR/android_final_pr_gate.sh" tmp/android-phone-final-gate-real --skip-validate --require-health-success --dry-run > "$final_gate_dry_run_output"
"$SCRIPT_DIR/android_partial_phone_gate.sh" tmp/android-phone-partial-gate-real --skip-validate --require-health-success --dry-run > "$partial_gate_dry_run_output"
"$SCRIPT_DIR/android_pr_readiness.sh" > "$readiness_output"
if "$SCRIPT_DIR/android_pr_readiness.sh" --strict > "$readiness_strict_output" 2>&1; then
  echo "PR readiness strict mode unexpectedly passed without phone evidence" >&2
  exit 1
fi
cat > "$synthetic_evidence_dir/phone-handoff-summary.md" <<'SUMMARY'
# Goose Android Phone Evidence

Generated at: 20260603T000000Z
Device serial: physical-android-smoke
Device kind: physical
Device: Synthetic Android
Android: 16 (SDK 36)
Commit: synthetic
Result: PASS

## Installed App

- Result: PASS
- Package path: package:/data/app/com.goose.android/base.apk

## Capture

- Raw evidence rows: 2
- Decoded frame rows: 1
- Capture sessions: 1
- Session raw evidence rows: 1
- Session live notification raw evidence rows: 1
- Finished nonempty capture sessions: 1
- Step samples: 1
- Daily activity metrics: 1

## BLE Session

- Ready events: 1
- Hello sent events: 1
- Command ready events: 1

## Health Connect

- Write started events: 1
- Ready write started events: 1
- Planned write started events: 1
- Candidate write started events: 1
- Records attempted events: 1
- Write succeeded events: 1
- Write failed events: 0

## Step Validation

- Completed events: 1
- Passed events: 1
- Failed events: 0
- Session-bound events: 1
- Session decoded events: 1
- Selected delta events: 1
SUMMARY
cat > "$synthetic_evidence_dir/evidence-gates.txt" <<'GATES'
GOOSE_ANDROID_REQUIRE_BLE_HELLO_SENT=1
GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_PASS=1
GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_SESSION=1
GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_ATTEMPT=1
GOOSE_ANDROID_REQUIRE_HEALTH_READY_WRITE_PLAN=1
GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_SUCCESS=0
GATES
"$SCRIPT_DIR/android_pr_readiness.sh" --strict "$synthetic_evidence_dir" > "$readiness_strict_pass_output"
assert_file_contains "$checklist_output" "Goose Android Final Phone Checklist" "final phone checklist"
assert_file_contains "$checklist_output" "Scripts/android_final_pr_gate.sh tmp/android-phone-final-gate-real" "final phone checklist"
assert_file_contains "$checklist_output" "Scripts/android_phone_final_gate.sh tmp/android-phone-final-gate-real --require-step-validation" "final phone checklist"
assert_file_contains "$checklist_output" "BLE session hello sent events: at least 1." "final phone checklist"
assert_file_contains "$checklist_output" "Session live notification raw evidence rows: at least 1." "final phone checklist"
assert_file_contains "$checklist_output" "Step validation passed events: at least 1." "final phone checklist"
assert_file_contains "$checklist_output" "Step validation session decoded events: at least 1." "final phone checklist"
assert_file_contains "$checklist_output" "Health Connect ready write started events: at least 1." "final phone checklist"
assert_file_contains "$readiness_output" "Goose Android PR Readiness" "PR readiness"
assert_file_contains "$readiness_output" "No phone evidence directory supplied." "PR readiness"
assert_file_contains "$readiness_output" "Remaining Phone-Bound Acceptance" "PR readiness"
assert_file_contains "$readiness_output" "Scripts/android_pr_readiness.sh --strict [output-dir]" "PR readiness"
assert_file_contains "$readiness_strict_output" "Strict PR readiness: FAIL" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Strict PR readiness: PASS" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "- None from the supplied evidence bundle." "PR readiness strict"
assert_file_contains "$final_gate_dry_run_output" "skip validate" "final PR gate dry run"
assert_file_contains "$final_gate_dry_run_output" "android_phone_final_gate.sh tmp/android-phone-final-gate-real --require-step-validation --require-health-success" "final PR gate dry run"
assert_file_contains "$final_gate_dry_run_output" "android_pr_readiness.sh --strict tmp/android-phone-final-gate-real" "final PR gate dry run"
assert_file_contains "$partial_gate_dry_run_output" "skip validate" "partial phone gate dry run"
assert_file_contains "$partial_gate_dry_run_output" "android_phone_final_gate.sh tmp/android-phone-partial-gate-real --require-health-success" "partial phone gate dry run"
assert_file_contains "$partial_gate_dry_run_output" "android_pr_readiness.sh tmp/android-phone-partial-gate-real" "partial phone gate dry run"
assert_file_contains "$SCRIPT_DIR/collect_android_phone_evidence.sh" "Multiple adb devices are online. Set ANDROID_SERIAL to one of:" "phone evidence collector"
assert_file_contains "$SCRIPT_DIR/pull_android_database.sh" "Multiple adb devices are online. Set ANDROID_SERIAL to one of:" "database pull"

find_build_tool() {
  local tool="$1"
  if [[ -n "${ANDROID_HOME:-}" && -d "$ANDROID_HOME/build-tools" ]]; then
    find "$ANDROID_HOME/build-tools" -mindepth 2 -maxdepth 2 -type f -name "$tool" | sort | tail -n 1
    return
  fi
  if command -v "$tool" >/dev/null 2>&1; then
    command -v "$tool"
  fi
}

assert_apk_native_libs() {
  local apk_path="$1"
  local label="$2"

  if [[ ! -f "$apk_path" ]]; then
    echo "Missing $label APK: $apk_path" >&2
    exit 1
  fi
  if ! command -v zipinfo >/dev/null 2>&1; then
    echo "zipinfo is required to validate $label APK native libraries" >&2
    exit 1
  fi

  local listing
  listing="$(zipinfo -1 "$apk_path")"
  for abi in "${GOOSE_ANDROID_ABIS[@]}"; do
    for library in libgoose_core.so libgoose_android_bridge.so; do
      if ! grep -qx "lib/$abi/$library" <<<"$listing"; then
        echo "$label APK missing lib/$abi/$library" >&2
        exit 1
      fi
    done
  done
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"

  if ! grep -Fq "$needle" <<<"$haystack"; then
    echo "$label missing expected APK metadata: $needle" >&2
    exit 1
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"

  if grep -Fq "$needle" <<<"$haystack"; then
    echo "$label contains unexpected APK metadata: $needle" >&2
    exit 1
  fi
}

assert_apk_manifest_contract() {
  local apk_path="$1"
  local label="$2"
  local expect_debuggable="$3"

  local aapt
  aapt="$(find_build_tool aapt)"
  if [[ -z "$aapt" || ! -x "$aapt" ]]; then
    echo "aapt is required to validate $label APK manifest metadata" >&2
    exit 1
  fi

  local badging
  badging="$("$aapt" dump badging "$apk_path")"
  assert_contains "$badging" "package: name='com.goose.android' versionCode='1' versionName='0.1.0'" "$label"
  assert_contains "$badging" "sdkVersion:'23'" "$label"
  assert_contains "$badging" "targetSdkVersion:'36'" "$label"
  assert_contains "$badging" "uses-permission: name='android.permission.BLUETOOTH_CONNECT'" "$label"
  assert_contains "$badging" "uses-permission: name='android.permission.BLUETOOTH_SCAN'" "$label"
  assert_contains "$badging" "uses-permission: name='android.permission.health.WRITE_ACTIVE_CALORIES_BURNED'" "$label"
  assert_contains "$badging" "uses-permission: name='android.permission.health.WRITE_HEART_RATE'" "$label"
  assert_contains "$badging" "uses-permission: name='android.permission.health.WRITE_STEPS'" "$label"
  assert_not_contains "$badging" "uses-permission: name='android.permission.INTERNET'" "$label"
  assert_not_contains "$badging" "uses-permission: name='android.permission.ACCESS_NETWORK_STATE'" "$label"
  assert_not_contains "$badging" "uses-permission: name='android.permission.READ_EXTERNAL_STORAGE'" "$label"
  assert_not_contains "$badging" "uses-permission: name='android.permission.WRITE_EXTERNAL_STORAGE'" "$label"
  assert_not_contains "$badging" "uses-permission: name='android.permission.MANAGE_EXTERNAL_STORAGE'" "$label"
  assert_contains "$badging" "application-label:'Goose'" "$label"
  assert_contains "$badging" "application:" "$label"
  assert_contains "$badging" "launchable-activity: name='com.goose.android.MainActivity'" "$label"
  assert_contains "$badging" "uses-feature: name='android.hardware.bluetooth_le'" "$label"
  assert_contains "$badging" "native-code: 'arm64-v8a' 'armeabi-v7a' 'x86_64'" "$label"
  if [[ "$expect_debuggable" == "1" ]]; then
    assert_contains "$badging" "application-debuggable" "$label"
  else
    assert_not_contains "$badging" "application-debuggable" "$label"
  fi

  local xmltree
  xmltree="$("$aapt" dump xmltree "$apk_path" AndroidManifest.xml)"
  assert_contains "$xmltree" 'A: android:allowBackup(0x01010280)=(type 0x12)0x0' "$label"
  assert_contains "$xmltree" 'A: android:usesCleartextTraffic(0x010104ec)=(type 0x12)0x0' "$label"
  assert_contains "$xmltree" 'A: android:fullBackupContent' "$label"
  assert_contains "$xmltree" 'A: android:dataExtractionRules' "$label"
  assert_contains "$xmltree" 'A: android:usesPermissionFlags(0x01010644)=(type 0x11)0x10000' "$label"
  assert_contains "$xmltree" 'android.health.connect.action.MANAGE_HEALTH_PERMISSIONS' "$label"
  assert_contains "$xmltree" 'androidx.health.ACTION_SHOW_PERMISSIONS_RATIONALE' "$label"
  assert_contains "$xmltree" 'android.intent.action.VIEW_PERMISSION_USAGE' "$label"
  assert_contains "$xmltree" 'android.permission.START_VIEW_PERMISSION_USAGE' "$label"
}

echo "==> Building Android debug and instrumentation APKs"
(cd "$ANDROID_DIR" && "$GRADLEW" :app:assembleDebug :app:assembleDebugAndroidTest)

echo "==> Validating Android debug APK native libraries"
assert_apk_native_libs "$ANDROID_DIR/app/build/outputs/apk/debug/app-debug.apk" "debug"
echo "==> Validating Android debug APK manifest metadata"
assert_apk_manifest_contract "$ANDROID_DIR/app/build/outputs/apk/debug/app-debug.apk" "debug" 1

echo "==> Running Android lint"
(cd "$ANDROID_DIR" && "$GRADLEW" :app:lintDebug)

echo "==> Building Android release APK"
(cd "$ANDROID_DIR" && "$GRADLEW" :app:assembleRelease)

echo "==> Validating Android release APK native libraries"
assert_apk_native_libs "$ANDROID_DIR/app/build/outputs/apk/release/app-release-unsigned.apk" "release"
echo "==> Validating Android release APK manifest metadata"
assert_apk_manifest_contract "$ANDROID_DIR/app/build/outputs/apk/release/app-release-unsigned.apk" "release" 0

if [[ "${GOOSE_ANDROID_SKIP_INSTRUMENTATION:-0}" == "1" ]]; then
  echo "==> Skipping Android instrumentation because GOOSE_ANDROID_SKIP_INSTRUMENTATION=1"
  exit 0
fi

if ! command -v "$ADB" >/dev/null 2>&1; then
  echo "==> adb not found; skipping Android instrumentation smoke"
  exit 0
fi

device_serial="${ANDROID_SERIAL:-}"
if [[ -z "$device_serial" ]]; then
  device_serial="$("$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')"
fi

if [[ -z "$device_serial" ]]; then
  echo "==> No adb device/emulator online; skipping Android instrumentation smoke"
  exit 0
fi

echo "==> Installing debug APKs on $device_serial"
"$ADB" -s "$device_serial" install -r "$ANDROID_DIR/app/build/outputs/apk/debug/app-debug.apk"
"$ADB" -s "$device_serial" install -r "$ANDROID_DIR/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"

"$ADB" -s "$device_serial" logcat -c || true

echo "==> Launching Goose Android app on $device_serial"
launch_output="$("$ADB" -s "$device_serial" shell am start -W -n com.goose.android/.MainActivity 2>&1)"
printf '%s\n' "$launch_output"

if grep -qE "Error:|Exception" <<<"$launch_output"; then
  echo "Android app launch failed" >&2
  exit 1
fi
launch_status="$(awk -F': ' '$1 == "Status" { print $2; exit }' <<<"$launch_output")"
if [[ -n "$launch_status" && "$launch_status" != "ok" ]]; then
  echo "Android app launch failed with status: $launch_status" >&2
  exit 1
fi
sleep 2
launch_crash_log="$("$ADB" -s "$device_serial" logcat -d -v brief AndroidRuntime:E '*:S' 2>/dev/null || true)"
if grep -q "com.goose.android" <<<"$launch_crash_log"; then
  printf '%s\n' "$launch_crash_log" >&2
  echo "Android app logged a fatal exception after launch" >&2
  exit 1
fi

echo "==> Running Goose Android bridge instrumentation on $device_serial"
instrumentation_output="$("$ADB" -s "$device_serial" shell am instrument -w \
  com.goose.android.test/com.goose.android.GooseRustBridgeInstrumentationTest 2>&1)"
printf '%s\n' "$instrumentation_output"

if ! grep -q "INSTRUMENTATION_RESULT: result=passed" <<<"$instrumentation_output"; then
  echo "Android instrumentation did not report result=passed" >&2
  exit 1
fi

if ! grep -q "INSTRUMENTATION_CODE: 0" <<<"$instrumentation_output"; then
  echo "Android instrumentation did not report INSTRUMENTATION_CODE: 0" >&2
  exit 1
fi
