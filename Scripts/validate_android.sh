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
SYNTHETIC_COMMIT="$(git -C "$APP_DIR" rev-parse --short HEAD) $(git -C "$APP_DIR" log -1 --pretty=%s)"

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

select_adb_target() {
  if [[ -n "${ANDROID_SERIAL:-}" ]]; then
    printf '%s\n' "$ANDROID_SERIAL"
    return
  fi

  local devices=()
  while IFS= read -r serial; do
    devices+=("$serial")
  done < <("$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1 }')

  if [[ "${#devices[@]}" -eq 1 ]]; then
    printf '%s\n' "${devices[0]}"
    return
  fi

  if [[ "${#devices[@]}" -eq 0 ]]; then
    return
  fi

  {
    echo "Multiple adb devices are online. Set ANDROID_SERIAL to one of:"
    printf '  %s\n' "${devices[@]}"
  } >&2
  return 2
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

write_synthetic_manifest() {
  local dir="$1"
  local manifest="$dir/evidence-files-manifest.txt"
  local tmp_manifest="$manifest.tmp"

  {
    echo "path	bytes	sha256"
    while IFS= read -r path; do
      local name="${path#$dir/}"
      if [[ "$name" == "evidence-files-manifest.txt" || "$name" == "evidence-files-manifest.txt.tmp" ]]; then
        continue
      fi
      printf '%s\t%s\t%s\n' "$name" "$(file_size "$path")" "$(file_sha256 "$path")"
    done < <(find "$dir" -maxdepth 1 -type f | sort)
  } > "$tmp_manifest"
  mv "$tmp_manifest" "$manifest"
}

write_required_evidence_artifacts() {
  local dir="$1"
  {
    printf 'commit: %s\n' "$SYNTHETIC_COMMIT"
    printf 'dirty tracked files: 0\n'
    printf 'untracked non-ignored files: 0\n'
    printf '\nDebug APK\n'
    printf 'sha256: 1111111111111111111111111111111111111111111111111111111111111111\n'
  } > "$dir/android-port-status.txt"
  printf 'List of devices attached\nphysical-android-smoke\tdevice\n' > "$dir/adb-devices.txt"
  printf 'physical-android-smoke\n' > "$dir/android-serial.txt"
  printf 'Synthetic\n' > "$dir/device-manufacturer.txt"
  printf 'Android\n' > "$dir/device-model.txt"
  printf '16\n' > "$dir/android-version.txt"
  printf '36\n' > "$dir/android-sdk.txt"
  printf 'physical\n' > "$dir/android-device-kind.txt"
  printf 'RESULT: PASS\n' > "$dir/evidence-result.txt"
  printf 'RESULT: PASS\n' > "$dir/pull-android-database-result.txt"
  printf 'device\n' > "$dir/adb-state-final.txt"
  printf 'synthetic sqlite placeholder\n' > "$dir/goose-phone.sqlite"
  printf 'package:/data/app/com.goose.android/base.apk\n' > "$dir/goose-package-path.txt"
  printf 'versionName=0.1.0\n' > "$dir/goose-package-summary.txt"
  printf 'Package [com.goose.android] synthetic dumpsys placeholder\n' > "$dir/goose-package-dumpsys.txt"
  printf '1111111111111111111111111111111111111111111111111111111111111111\n' > "$dir/goose-local-debug-apk-sha256.txt"
  printf '1111111111111111111111111111111111111111111111111111111111111111\n' > "$dir/goose-installed-apk-sha256.txt"
  printf '{"schema":"goose.android.ble-session-audit.v1","event":"connection_progress","details":{"phase":"operation_complete","active_operation_label":"client hello","command_ready":true,"hello_sent":true}}\n{"schema":"goose.android.ble-session-audit.v1","event":"connection_progress","details":{"phase":"ready","command_ready":true,"hello_sent":true}}\n' > "$dir/goose-phone-ble-session-log.jsonl"
  printf '{"schema":"goose.android.health-connect-sync-audit.v1","event":"write_started","permissions_ready":true,"planned_write_count":1,"candidate_count":1,"records_attempted":1}\n{"schema":"goose.android.health-connect-sync-audit.v1","event":"write_succeeded","permissions_ready":true,"planned_write_count":1,"candidate_count":1,"records_attempted":1,"records_inserted":1}\n' > "$dir/goose-phone-health-connect-sync-log.jsonl"
  printf '{"schema":"goose.android.step-validation-audit.v1","event":"completed","pass":true,"capture_session_id":"android-session-a","capture_session_decoded_frame_count":1,"selected_delta":1}\n' > "$dir/goose-phone-step-validation-log.jsonl"
  {
    printf 'Android capture inspection\n'
    printf 'database bytes: %s\n' "$(file_size "$dir/goose-phone.sqlite")"
    printf 'database sha256: %s\n' "$(file_sha256 "$dir/goose-phone.sqlite")"
    printf 'database wal bytes: 0\n'
    printf 'database wal sha256: missing\n'
    printf 'database shm bytes: 0\n'
    printf 'database shm sha256: missing\n'
    printf 'raw evidence: 2\n'
    printf 'decoded frames: 1\n'
    printf 'capture sessions: 1\n'
    printf 'session raw evidence: 1\n'
    printf 'session live notification raw evidence: 1\n'
    printf 'session decoded frames: 1\n'
    printf 'finished nonempty capture sessions: 1\n'
    printf 'step samples: 1\n'
    printf 'daily activity metrics: 1\n'
    printf 'latest raw capture: 2026-06-04T12:00:01.000Z\n'
    printf 'health sync write started events: 1\n'
    printf 'health sync ready write started events: 1\n'
    printf 'health sync planned write started events: 1\n'
    printf 'health sync candidate write started events: 1\n'
    printf 'health sync records attempted events: 1\n'
    printf 'health sync write succeeded events: 1\n'
    printf 'health sync ready write succeeded events: 1\n'
    printf 'health sync planned write succeeded events: 1\n'
    printf 'health sync records inserted events: 1\n'
    printf 'ble session ready events: 1\n'
    printf 'ble session hello sent events: 1\n'
    printf 'ble session client hello completed events: 1\n'
    printf 'ble session client hello command-ready completed events: 1\n'
    printf 'ble session command ready events: 1\n'
    printf 'ble session ready hello command-ready events: 1\n'
    printf 'step validation completed events: 1\n'
    printf 'step validation passed events: 1\n'
    printf 'step validation failed events: 0\n'
    printf 'step validation session-bound events: 1\n'
    printf 'step validation session decoded events: 1\n'
    printf 'step validation selected delta events: 1\n'
    printf 'step validation passing session selected-delta events: 1\n'
    printf 'RESULT: PASS\n'
  } > "$dir/inspect-android-capture.txt"
  printf 'goose-evidence-start 20260604T120000Z com.goose.android physical-android-smoke\n' > "$dir/logcat-start-marker.txt"
  printf 'I/GooseEvidenceStart(12345): goose-evidence-start 20260604T120000Z com.goose.android physical-android-smoke\nI/GooseBridgeSmoke(12345): com.goose.android smoke harness completed\n' > "$dir/logcat-goose-brief.txt"
  printf '06-04 12:00:00.000 12345 12345 I GooseEvidenceStart: goose-evidence-start 20260604T120000Z com.goose.android physical-android-smoke\n06-04 12:00:00.001 12345 12345 I GooseBridgeSmoke: synthetic full logcat snapshot\n' > "$dir/logcat-threadtime.txt"
}

copy_required_evidence_artifacts() {
  local source_dir="$1"
  local target_dir="$2"
  cp "$source_dir/android-port-status.txt" "$target_dir/android-port-status.txt"
  cp "$source_dir/adb-devices.txt" "$target_dir/adb-devices.txt"
  cp "$source_dir/android-serial.txt" "$target_dir/android-serial.txt"
  cp "$source_dir/device-manufacturer.txt" "$target_dir/device-manufacturer.txt"
  cp "$source_dir/device-model.txt" "$target_dir/device-model.txt"
  cp "$source_dir/android-version.txt" "$target_dir/android-version.txt"
  cp "$source_dir/android-sdk.txt" "$target_dir/android-sdk.txt"
  cp "$source_dir/android-device-kind.txt" "$target_dir/android-device-kind.txt"
  cp "$source_dir/evidence-result.txt" "$target_dir/evidence-result.txt"
  cp "$source_dir/pull-android-database-result.txt" "$target_dir/pull-android-database-result.txt"
  cp "$source_dir/adb-state-final.txt" "$target_dir/adb-state-final.txt"
  cp "$source_dir/goose-phone.sqlite" "$target_dir/goose-phone.sqlite"
  cp "$source_dir/goose-package-path.txt" "$target_dir/goose-package-path.txt"
  cp "$source_dir/goose-package-summary.txt" "$target_dir/goose-package-summary.txt"
  cp "$source_dir/goose-package-dumpsys.txt" "$target_dir/goose-package-dumpsys.txt"
  cp "$source_dir/goose-local-debug-apk-sha256.txt" "$target_dir/goose-local-debug-apk-sha256.txt"
  cp "$source_dir/goose-installed-apk-sha256.txt" "$target_dir/goose-installed-apk-sha256.txt"
  cp "$source_dir/goose-phone-ble-session-log.jsonl" "$target_dir/goose-phone-ble-session-log.jsonl"
  cp "$source_dir/goose-phone-health-connect-sync-log.jsonl" "$target_dir/goose-phone-health-connect-sync-log.jsonl"
  cp "$source_dir/goose-phone-step-validation-log.jsonl" "$target_dir/goose-phone-step-validation-log.jsonl"
  cp "$source_dir/inspect-android-capture.txt" "$target_dir/inspect-android-capture.txt"
  cp "$source_dir/logcat-goose-brief.txt" "$target_dir/logcat-goose-brief.txt"
  cp "$source_dir/logcat-threadtime.txt" "$target_dir/logcat-threadtime.txt"
  cp "$source_dir/logcat-start-marker.txt" "$target_dir/logcat-start-marker.txt"
}

write_manifest_omitting_file() {
  local dir="$1"
  local omitted_name="$2"

  {
    echo "path	bytes	sha256"
    while IFS= read -r path; do
      local name="${path#$dir/}"
      if [[ "$name" == "evidence-files-manifest.txt" \
        || "$name" == "evidence-files-manifest.txt.tmp" \
        || "$name" == "$omitted_name" ]]; then
        continue
      fi
      printf '%s\t%s\t%s\n' "$name" "$(file_size "$path")" "$(file_sha256 "$path")"
    done < <(find "$dir" -maxdepth 1 -type f | sort)
  } > "$dir/evidence-files-manifest.txt"
}

echo "==> Checking Android helper shell syntax"
bash -n "$SCRIPT_DIR/android_final_phone_checklist.sh"
bash -n "$SCRIPT_DIR/android_partial_phone_checklist.sh"
bash -n "$SCRIPT_DIR/android_final_pr_gate.sh"
bash -n "$SCRIPT_DIR/android_partial_phone_gate.sh"
bash -n "$SCRIPT_DIR/android_port_status.sh"
bash -n "$SCRIPT_DIR/android_phone_final_gate.sh"
bash -n "$SCRIPT_DIR/android_pr_readiness.sh"
bash -n "$SCRIPT_DIR/build_android_rust.sh"
bash -n "$SCRIPT_DIR/collect_android_phone_evidence.sh"
bash -n "$SCRIPT_DIR/install_android_debug.sh"
bash -n "$SCRIPT_DIR/inspect_android_capture.sh"
bash -n "$SCRIPT_DIR/prepare_android_phone_evidence.sh"
bash -n "$SCRIPT_DIR/pull_android_database.sh"
bash -n "$SCRIPT_DIR/validate_android.sh"

echo "==> Checking Android handoff helper output"
checklist_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-checklist.XXXXXX")"
partial_checklist_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-partial-checklist.XXXXXX")"
readiness_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-readiness.XXXXXX")"
readiness_strict_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-readiness-strict.XXXXXX")"
readiness_strict_pass_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-readiness-strict-pass.XXXXXX")"
readiness_partial_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-readiness-partial.XXXXXX")"
readiness_partial_strict_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-readiness-partial-strict.XXXXXX")"
readiness_crash_strict_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-readiness-crash-strict.XXXXXX")"
readiness_logcat_marker_strict_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-readiness-logcat-marker-strict.XXXXXX")"
readiness_stale_capture_marker_strict_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-readiness-stale-capture-marker-strict.XXXXXX")"
readiness_package_strict_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-readiness-package-strict.XXXXXX")"
readiness_ble_command_ready_strict_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-readiness-ble-command-ready-strict.XXXXXX")"
readiness_health_success_strict_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-readiness-health-success-strict.XXXXXX")"
readiness_manifest_strict_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-readiness-manifest-strict.XXXXXX")"
readiness_stale_manifest_strict_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-readiness-stale-manifest-strict.XXXXXX")"
readiness_incomplete_manifest_strict_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-readiness-incomplete-manifest-strict.XXXXXX")"
readiness_audit_manifest_strict_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-readiness-audit-manifest-strict.XXXXXX")"
readiness_health_audit_manifest_strict_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-readiness-health-audit-manifest-strict.XXXXXX")"
readiness_step_audit_manifest_strict_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-readiness-step-audit-manifest-strict.XXXXXX")"
readiness_rotated_audit_manifest_strict_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-readiness-rotated-audit-manifest-strict.XXXXXX")"
readiness_stale_commit_strict_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-stale-commit-strict.XXXXXX")"
readiness_stale_debug_apk_strict_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-stale-debug-apk-strict.XXXXXX")"
readiness_dirty_status_strict_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-dirty-status-strict.XXXXXX")"
readiness_collect_error_strict_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-collect-error-strict.XXXXXX")"
final_gate_dry_run_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-final-gate-dry-run.XXXXXX")"
partial_gate_dry_run_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-partial-gate-dry-run.XXXXXX")"
inspect_session_detail_output="$(mktemp "${TMPDIR:-/tmp}/goose-android-inspect-session-detail.XXXXXX")"
synthetic_session_db="$(mktemp "${TMPDIR:-/tmp}/goose-android-session-detail.XXXXXX.sqlite")"
TMP_FILES+=("$checklist_output" "$partial_checklist_output" "$readiness_output" "$readiness_strict_output" "$readiness_strict_pass_output" "$readiness_partial_output" "$readiness_partial_strict_output" "$readiness_crash_strict_output" "$readiness_logcat_marker_strict_output" "$readiness_stale_capture_marker_strict_output" "$readiness_package_strict_output" "$readiness_ble_command_ready_strict_output" "$readiness_health_success_strict_output" "$readiness_manifest_strict_output" "$readiness_stale_manifest_strict_output" "$readiness_incomplete_manifest_strict_output" "$readiness_audit_manifest_strict_output" "$readiness_health_audit_manifest_strict_output" "$readiness_step_audit_manifest_strict_output" "$readiness_rotated_audit_manifest_strict_output" "$readiness_stale_commit_strict_output" "$readiness_stale_debug_apk_strict_output" "$readiness_dirty_status_strict_output" "$readiness_collect_error_strict_output" "$final_gate_dry_run_output" "$partial_gate_dry_run_output" "$inspect_session_detail_output" "$synthetic_session_db")
synthetic_evidence_dir="$(mktemp -d "${TMPDIR:-/tmp}/goose-android-final-evidence.XXXXXX")"
synthetic_partial_evidence_dir="$(mktemp -d "${TMPDIR:-/tmp}/goose-android-partial-evidence.XXXXXX")"
synthetic_crash_evidence_dir="$(mktemp -d "${TMPDIR:-/tmp}/goose-android-crash-evidence.XXXXXX")"
synthetic_logcat_marker_evidence_dir="$(mktemp -d "${TMPDIR:-/tmp}/goose-android-logcat-marker-evidence.XXXXXX")"
synthetic_stale_capture_marker_evidence_dir="$(mktemp -d "${TMPDIR:-/tmp}/goose-android-stale-capture-marker-evidence.XXXXXX")"
synthetic_package_evidence_dir="$(mktemp -d "${TMPDIR:-/tmp}/goose-android-package-evidence.XXXXXX")"
synthetic_ble_command_ready_evidence_dir="$(mktemp -d "${TMPDIR:-/tmp}/goose-android-ble-command-ready-evidence.XXXXXX")"
synthetic_health_success_evidence_dir="$(mktemp -d "${TMPDIR:-/tmp}/goose-android-health-success-evidence.XXXXXX")"
synthetic_manifest_evidence_dir="$(mktemp -d "${TMPDIR:-/tmp}/goose-android-manifest-evidence.XXXXXX")"
synthetic_stale_manifest_evidence_dir="$(mktemp -d "${TMPDIR:-/tmp}/goose-android-stale-manifest-evidence.XXXXXX")"
synthetic_incomplete_manifest_evidence_dir="$(mktemp -d "${TMPDIR:-/tmp}/goose-android-incomplete-manifest-evidence.XXXXXX")"
synthetic_audit_manifest_evidence_dir="$(mktemp -d "${TMPDIR:-/tmp}/goose-android-audit-manifest-evidence.XXXXXX")"
synthetic_health_audit_manifest_evidence_dir="$(mktemp -d "${TMPDIR:-/tmp}/goose-android-health-audit-manifest-evidence.XXXXXX")"
synthetic_step_audit_manifest_evidence_dir="$(mktemp -d "${TMPDIR:-/tmp}/goose-android-step-audit-manifest-evidence.XXXXXX")"
synthetic_rotated_audit_manifest_evidence_dir="$(mktemp -d "${TMPDIR:-/tmp}/goose-android-rotated-audit-manifest-evidence.XXXXXX")"
synthetic_stale_commit_evidence_dir="$(mktemp -d "${TMPDIR:-/tmp}/goose-android-stale-commit-evidence.XXXXXX")"
synthetic_stale_debug_apk_evidence_dir="$(mktemp -d "${TMPDIR:-/tmp}/goose-android-stale-debug-apk-evidence.XXXXXX")"
synthetic_dirty_status_evidence_dir="$(mktemp -d "${TMPDIR:-/tmp}/goose-android-dirty-status-evidence.XXXXXX")"
synthetic_collect_error_evidence_dir="$(mktemp -d "${TMPDIR:-/tmp}/goose-android-collect-error-evidence.XXXXXX")"
TMP_DIRS+=("$synthetic_evidence_dir" "$synthetic_partial_evidence_dir" "$synthetic_crash_evidence_dir" "$synthetic_logcat_marker_evidence_dir" "$synthetic_stale_capture_marker_evidence_dir" "$synthetic_package_evidence_dir" "$synthetic_ble_command_ready_evidence_dir" "$synthetic_health_success_evidence_dir" "$synthetic_manifest_evidence_dir" "$synthetic_stale_manifest_evidence_dir" "$synthetic_incomplete_manifest_evidence_dir" "$synthetic_audit_manifest_evidence_dir" "$synthetic_health_audit_manifest_evidence_dir" "$synthetic_step_audit_manifest_evidence_dir" "$synthetic_rotated_audit_manifest_evidence_dir" "$synthetic_stale_commit_evidence_dir" "$synthetic_stale_debug_apk_evidence_dir" "$synthetic_dirty_status_evidence_dir" "$synthetic_collect_error_evidence_dir")
"$SCRIPT_DIR/android_final_phone_checklist.sh" > "$checklist_output"
"$SCRIPT_DIR/android_partial_phone_checklist.sh" > "$partial_checklist_output"
"$SCRIPT_DIR/android_final_pr_gate.sh" tmp/android-phone-final-gate-real --skip-validate --require-health-success --dry-run > "$final_gate_dry_run_output"
"$SCRIPT_DIR/android_partial_phone_gate.sh" tmp/android-phone-partial-gate-real --skip-validate --require-health-success --dry-run > "$partial_gate_dry_run_output"
"$SCRIPT_DIR/android_pr_readiness.sh" > "$readiness_output"
if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "sqlite3 is required to validate Android capture inspection output" >&2
  exit 1
fi
sqlite3 "$synthetic_session_db" <<'SQL'
CREATE TABLE capture_sessions (
  session_id TEXT PRIMARY KEY,
  source TEXT NOT NULL,
  started_at_unix_ms INTEGER NOT NULL,
  ended_at_unix_ms INTEGER,
  device_model TEXT NOT NULL,
  active_device_id TEXT,
  status TEXT NOT NULL,
  frame_count INTEGER NOT NULL DEFAULT 0,
  provenance_json TEXT NOT NULL
);
CREATE TABLE raw_evidence (
  evidence_id TEXT PRIMARY KEY,
  source TEXT NOT NULL,
  captured_at TEXT NOT NULL,
  device_model TEXT NOT NULL,
  payload_hex TEXT NOT NULL,
  sha256 TEXT NOT NULL,
  sensitivity TEXT NOT NULL,
  capture_session_id TEXT
);
CREATE TABLE decoded_frames (
  frame_id TEXT PRIMARY KEY,
  evidence_id TEXT NOT NULL,
  device_type TEXT NOT NULL,
  raw_len INTEGER NOT NULL,
  header_len INTEGER NOT NULL,
  declared_len INTEGER NOT NULL,
  payload_hex TEXT NOT NULL,
  payload_crc_hex TEXT NOT NULL,
  header_crc_valid INTEGER NOT NULL,
  payload_crc_valid INTEGER NOT NULL,
  parser_version TEXT NOT NULL,
  warnings_json TEXT NOT NULL
);
CREATE TABLE step_counter_samples (
  sample_id TEXT PRIMARY KEY,
  sample_time_unix_ms INTEGER NOT NULL,
  counter_value INTEGER NOT NULL,
  cadence_spm REAL,
  source_kind TEXT NOT NULL,
  packet_family TEXT NOT NULL,
  json_path TEXT NOT NULL,
  frame_id TEXT,
  evidence_id TEXT,
  capture_session_id TEXT,
  quality_flags_json TEXT NOT NULL,
  provenance_json TEXT NOT NULL
);
INSERT INTO capture_sessions VALUES ('android-session-a', 'goose-android/manual-capture', 1000, 2000, 'WHOOP 5.0 Goose Android', 'E4:B9:C9:42:F9:A8', 'finished', 2, '{}');
INSERT INTO raw_evidence VALUES ('raw-a', 'goose-android/live-notification/fd4b', '2026-06-03T00:00:01Z', 'WHOOP', 'aa', 'sha-a', 'raw_ble_packet', 'android-session-a');
INSERT INTO raw_evidence VALUES ('raw-b', 'goose-android/live-notification/fd4b', '2026-06-03T00:00:02Z', 'WHOOP', 'bb', 'sha-b', 'raw_ble_packet', 'android-session-a');
INSERT INTO decoded_frames VALUES ('frame-a', 'raw-a', 'whoop-5', 1, 0, 1, 'aa', '', 1, 1, 'goose.android-test', '[]');
INSERT INTO step_counter_samples VALUES ('step-a', 1001, 42, 80.0, 'candidate', 'fd4b', '$.counter', 'frame-a', 'raw-a', 'android-session-a', '[]', '{}');
SQL
"$SCRIPT_DIR/inspect_android_capture.sh" "$synthetic_session_db" > "$inspect_session_detail_output"
if "$SCRIPT_DIR/android_pr_readiness.sh" --strict > "$readiness_strict_output" 2>&1; then
  echo "PR readiness strict mode unexpectedly passed without phone evidence" >&2
  exit 1
fi
write_required_evidence_artifacts "$synthetic_evidence_dir"
cat > "$synthetic_evidence_dir/phone-handoff-summary.md" <<SUMMARY
# Goose Android Phone Evidence

Generated at: 20260603T000000Z
Device serial: physical-android-smoke
Device kind: physical
Device: Synthetic Android
Android: 16 (SDK 36)
Commit: $SYNTHETIC_COMMIT
Result: PASS

## Device

- Focused AndroidRuntime crash lines: 0
- Final adb state: device
- Logcat start marker result: PASS

## Installed App

- Result: PASS
- Package path: package:/data/app/com.goose.android/base.apk
- Local debug APK SHA-256: 1111111111111111111111111111111111111111111111111111111111111111
- Installed APK SHA-256: 1111111111111111111111111111111111111111111111111111111111111111
- Installed APK hash result: PASS

## Capture

- Database pull result: PASS
- Database bytes: $(file_size "$synthetic_evidence_dir/goose-phone.sqlite")
- Database SHA-256: $(file_sha256 "$synthetic_evidence_dir/goose-phone.sqlite")
- Database WAL bytes: 0
- Database WAL SHA-256: missing
- Database SHM bytes: 0
- Database SHM SHA-256: missing
- Raw evidence rows: 2
- Decoded frame rows: 1
- Capture sessions: 1
- Session raw evidence rows: 1
- Session live notification raw evidence rows: 1
- Session decoded frame rows: 1
- Finished nonempty capture sessions: 1
- Step samples: 1
- Daily activity metrics: 1
- Latest raw capture: 2026-06-04T12:00:01.000Z
- Latest raw capture after marker result: PASS

## BLE Session

- Ready events: 1
- Hello sent events: 1
- Client hello completed events: 1
- Client hello command-ready completed events: 1
- Command ready events: 1
- Ready hello command-ready events: 1

## Health Connect

- Write started events: 1
- Ready write started events: 1
- Planned write started events: 1
- Candidate write started events: 1
- Records attempted events: 1
- Write succeeded events: 1
- Ready write succeeded events: 1
- Planned write succeeded events: 1
- Records inserted events: 1
- Write failed events: 0

## Step Validation

- Completed events: 1
- Passed events: 1
- Failed events: 0
- Session-bound events: 1
- Session decoded events: 1
- Selected delta events: 1
- Passing session selected-delta events: 1
SUMMARY
cat > "$synthetic_evidence_dir/evidence-gates.txt" <<'GATES'
GOOSE_ANDROID_REQUIRE_BLE_HELLO_SENT=1
GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_PASS=1
GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_SESSION=1
GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_ATTEMPT=1
GOOSE_ANDROID_REQUIRE_HEALTH_READY_WRITE_PLAN=1
GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_SUCCESS=0
GOOSE_ANDROID_REQUIRE_LOGCAT_START_MARKER=1
GATES
write_synthetic_manifest "$synthetic_evidence_dir"
"$SCRIPT_DIR/android_pr_readiness.sh" --strict "$synthetic_evidence_dir" > "$readiness_strict_pass_output"

cp "$synthetic_evidence_dir"/* "$synthetic_rotated_audit_manifest_evidence_dir"/
mv "$synthetic_rotated_audit_manifest_evidence_dir/goose-phone-ble-session-log.jsonl" "$synthetic_rotated_audit_manifest_evidence_dir/goose-phone-ble-session-log.jsonl.old"
mv "$synthetic_rotated_audit_manifest_evidence_dir/goose-phone-health-connect-sync-log.jsonl" "$synthetic_rotated_audit_manifest_evidence_dir/goose-phone-health-connect-sync-log.jsonl.old"
mv "$synthetic_rotated_audit_manifest_evidence_dir/goose-phone-step-validation-log.jsonl" "$synthetic_rotated_audit_manifest_evidence_dir/goose-phone-step-validation-log.jsonl.old"
write_synthetic_manifest "$synthetic_rotated_audit_manifest_evidence_dir"
"$SCRIPT_DIR/android_pr_readiness.sh" --strict "$synthetic_rotated_audit_manifest_evidence_dir" > "$readiness_rotated_audit_manifest_strict_output"

cp "$synthetic_evidence_dir"/* "$synthetic_stale_commit_evidence_dir"/
stale_commit_summary_tmp="$synthetic_stale_commit_evidence_dir/phone-handoff-summary.md.tmp"
awk '
  $0 ~ /^Commit: / {
    print "Commit: stale-commit Synthetic stale evidence"
    next
  }
  { print }
' "$synthetic_stale_commit_evidence_dir/phone-handoff-summary.md" > "$stale_commit_summary_tmp"
mv "$stale_commit_summary_tmp" "$synthetic_stale_commit_evidence_dir/phone-handoff-summary.md"
printf 'commit: stale-commit Synthetic stale evidence\nDebug sha256: synthetic\n' > "$synthetic_stale_commit_evidence_dir/android-port-status.txt"
write_synthetic_manifest "$synthetic_stale_commit_evidence_dir"
if "$SCRIPT_DIR/android_pr_readiness.sh" --strict "$synthetic_stale_commit_evidence_dir" > "$readiness_stale_commit_strict_output" 2>&1; then
  echo "PR readiness strict mode unexpectedly passed with stale commit evidence" >&2
  exit 1
fi

cp "$synthetic_evidence_dir"/* "$synthetic_stale_debug_apk_evidence_dir"/
stale_debug_apk_status_tmp="$synthetic_stale_debug_apk_evidence_dir/android-port-status.txt.tmp"
awk '
  $0 == "sha256: 1111111111111111111111111111111111111111111111111111111111111111" && !replaced {
    print "sha256: 2222222222222222222222222222222222222222222222222222222222222222"
    replaced = 1
    next
  }
  { print }
' "$synthetic_stale_debug_apk_evidence_dir/android-port-status.txt" > "$stale_debug_apk_status_tmp"
mv "$stale_debug_apk_status_tmp" "$synthetic_stale_debug_apk_evidence_dir/android-port-status.txt"
write_synthetic_manifest "$synthetic_stale_debug_apk_evidence_dir"
if "$SCRIPT_DIR/android_pr_readiness.sh" --strict "$synthetic_stale_debug_apk_evidence_dir" > "$readiness_stale_debug_apk_strict_output" 2>&1; then
  echo "PR readiness strict mode unexpectedly passed with stale debug APK status evidence" >&2
  exit 1
fi

cp "$synthetic_evidence_dir"/* "$synthetic_dirty_status_evidence_dir"/
dirty_status_tmp="$synthetic_dirty_status_evidence_dir/android-port-status.txt.tmp"
awk '
  $0 == "dirty tracked files: 0" {
    print "dirty tracked files: 1"
    next
  }
  { print }
' "$synthetic_dirty_status_evidence_dir/android-port-status.txt" > "$dirty_status_tmp"
mv "$dirty_status_tmp" "$synthetic_dirty_status_evidence_dir/android-port-status.txt"
write_synthetic_manifest "$synthetic_dirty_status_evidence_dir"
if "$SCRIPT_DIR/android_pr_readiness.sh" --strict "$synthetic_dirty_status_evidence_dir" > "$readiness_dirty_status_strict_output" 2>&1; then
  echo "PR readiness strict mode unexpectedly passed with a dirty status snapshot" >&2
  exit 1
fi
cp "$synthetic_evidence_dir"/* "$synthetic_collect_error_evidence_dir"/
printf 'FAIL: synthetic collection diagnostic\n' > "$synthetic_collect_error_evidence_dir/collect-error.txt"
write_synthetic_manifest "$synthetic_collect_error_evidence_dir"
if "$SCRIPT_DIR/android_pr_readiness.sh" --strict "$synthetic_collect_error_evidence_dir" > "$readiness_collect_error_strict_output" 2>&1; then
  echo "PR readiness strict mode unexpectedly passed with collect-error diagnostics" >&2
  exit 1
fi
cp "$synthetic_evidence_dir/phone-handoff-summary.md" "$synthetic_audit_manifest_evidence_dir/phone-handoff-summary.md"
cp "$synthetic_evidence_dir/evidence-gates.txt" "$synthetic_audit_manifest_evidence_dir/evidence-gates.txt"
copy_required_evidence_artifacts "$synthetic_evidence_dir" "$synthetic_audit_manifest_evidence_dir"
write_manifest_omitting_file "$synthetic_audit_manifest_evidence_dir" "goose-phone-ble-session-log.jsonl"
if "$SCRIPT_DIR/android_pr_readiness.sh" --strict "$synthetic_audit_manifest_evidence_dir" > "$readiness_audit_manifest_strict_output" 2>&1; then
  echo "PR readiness strict mode unexpectedly passed with a required audit log omitted from the evidence manifest" >&2
  exit 1
fi
cp "$synthetic_evidence_dir/phone-handoff-summary.md" "$synthetic_health_audit_manifest_evidence_dir/phone-handoff-summary.md"
cp "$synthetic_evidence_dir/evidence-gates.txt" "$synthetic_health_audit_manifest_evidence_dir/evidence-gates.txt"
copy_required_evidence_artifacts "$synthetic_evidence_dir" "$synthetic_health_audit_manifest_evidence_dir"
write_manifest_omitting_file "$synthetic_health_audit_manifest_evidence_dir" "goose-phone-health-connect-sync-log.jsonl"
if "$SCRIPT_DIR/android_pr_readiness.sh" --strict "$synthetic_health_audit_manifest_evidence_dir" > "$readiness_health_audit_manifest_strict_output" 2>&1; then
  echo "PR readiness strict mode unexpectedly passed with the Health Connect audit log omitted from the evidence manifest" >&2
  exit 1
fi
cp "$synthetic_evidence_dir/phone-handoff-summary.md" "$synthetic_step_audit_manifest_evidence_dir/phone-handoff-summary.md"
cp "$synthetic_evidence_dir/evidence-gates.txt" "$synthetic_step_audit_manifest_evidence_dir/evidence-gates.txt"
copy_required_evidence_artifacts "$synthetic_evidence_dir" "$synthetic_step_audit_manifest_evidence_dir"
write_manifest_omitting_file "$synthetic_step_audit_manifest_evidence_dir" "goose-phone-step-validation-log.jsonl"
if "$SCRIPT_DIR/android_pr_readiness.sh" --strict "$synthetic_step_audit_manifest_evidence_dir" > "$readiness_step_audit_manifest_strict_output" 2>&1; then
  echo "PR readiness strict mode unexpectedly passed with the step-validation audit log omitted from the evidence manifest" >&2
  exit 1
fi
cp "$synthetic_evidence_dir/phone-handoff-summary.md" "$synthetic_crash_evidence_dir/phone-handoff-summary.md"
cp "$synthetic_evidence_dir/evidence-gates.txt" "$synthetic_crash_evidence_dir/evidence-gates.txt"
copy_required_evidence_artifacts "$synthetic_evidence_dir" "$synthetic_crash_evidence_dir"
crash_summary_tmp="$synthetic_crash_evidence_dir/phone-handoff-summary.md.tmp"
awk '
  $0 == "- Focused AndroidRuntime crash lines: 0" && !replaced {
    print "- Focused AndroidRuntime crash lines: 1"
    replaced = 1
    next
  }
  { print }
' "$synthetic_crash_evidence_dir/phone-handoff-summary.md" > "$crash_summary_tmp"
mv "$crash_summary_tmp" "$synthetic_crash_evidence_dir/phone-handoff-summary.md"
write_synthetic_manifest "$synthetic_crash_evidence_dir"
if "$SCRIPT_DIR/android_pr_readiness.sh" --strict "$synthetic_crash_evidence_dir" > "$readiness_crash_strict_output" 2>&1; then
  echo "PR readiness strict mode unexpectedly passed with AndroidRuntime crash evidence" >&2
  exit 1
fi
cp "$synthetic_evidence_dir/phone-handoff-summary.md" "$synthetic_logcat_marker_evidence_dir/phone-handoff-summary.md"
cp "$synthetic_evidence_dir/evidence-gates.txt" "$synthetic_logcat_marker_evidence_dir/evidence-gates.txt"
copy_required_evidence_artifacts "$synthetic_evidence_dir" "$synthetic_logcat_marker_evidence_dir"
printf 'goose-evidence-start 20260604T120000Z com.goose.android other-android-smoke\n' > "$synthetic_logcat_marker_evidence_dir/logcat-start-marker.txt"
printf 'I/GooseEvidenceStart(12345): goose-evidence-start 20260604T120000Z com.goose.android other-android-smoke\nI/GooseBridgeSmoke(12345): com.goose.android smoke harness completed\n' > "$synthetic_logcat_marker_evidence_dir/logcat-goose-brief.txt"
printf '06-04 12:00:00.000 12345 12345 I GooseEvidenceStart: goose-evidence-start 20260604T120000Z com.goose.android other-android-smoke\n06-04 12:00:00.001 12345 12345 I GooseBridgeSmoke: synthetic full logcat snapshot\n' > "$synthetic_logcat_marker_evidence_dir/logcat-threadtime.txt"
write_synthetic_manifest "$synthetic_logcat_marker_evidence_dir"
if "$SCRIPT_DIR/android_pr_readiness.sh" --strict "$synthetic_logcat_marker_evidence_dir" > "$readiness_logcat_marker_strict_output" 2>&1; then
  echo "PR readiness strict mode unexpectedly passed with mismatched logcat start marker evidence" >&2
  exit 1
fi

cp "$synthetic_evidence_dir"/* "$synthetic_stale_capture_marker_evidence_dir"/
stale_capture_summary_tmp="$synthetic_stale_capture_marker_evidence_dir/phone-handoff-summary.md.tmp"
awk '
  $0 == "- Latest raw capture: 2026-06-04T12:00:01.000Z" {
    print "- Latest raw capture: 2026-06-04T11:59:59.000Z"
    next
  }
  { print }
' "$synthetic_stale_capture_marker_evidence_dir/phone-handoff-summary.md" > "$stale_capture_summary_tmp"
mv "$stale_capture_summary_tmp" "$synthetic_stale_capture_marker_evidence_dir/phone-handoff-summary.md"
stale_capture_inspect_tmp="$synthetic_stale_capture_marker_evidence_dir/inspect-android-capture.txt.tmp"
awk '
  $0 == "latest raw capture: 2026-06-04T12:00:01.000Z" {
    print "latest raw capture: 2026-06-04T11:59:59.000Z"
    next
  }
  { print }
' "$synthetic_stale_capture_marker_evidence_dir/inspect-android-capture.txt" > "$stale_capture_inspect_tmp"
mv "$stale_capture_inspect_tmp" "$synthetic_stale_capture_marker_evidence_dir/inspect-android-capture.txt"
write_synthetic_manifest "$synthetic_stale_capture_marker_evidence_dir"
if "$SCRIPT_DIR/android_pr_readiness.sh" --strict "$synthetic_stale_capture_marker_evidence_dir" > "$readiness_stale_capture_marker_strict_output" 2>&1; then
  echo "PR readiness strict mode unexpectedly passed with stale raw capture evidence" >&2
  exit 1
fi

cp "$synthetic_evidence_dir/phone-handoff-summary.md" "$synthetic_package_evidence_dir/phone-handoff-summary.md"
cp "$synthetic_evidence_dir/evidence-gates.txt" "$synthetic_package_evidence_dir/evidence-gates.txt"
copy_required_evidence_artifacts "$synthetic_evidence_dir" "$synthetic_package_evidence_dir"
package_summary_tmp="$synthetic_package_evidence_dir/phone-handoff-summary.md.tmp"
awk '
  $0 == "- Result: PASS" && !replaced {
    print "- Result: FAIL"
    replaced = 1
    next
  }
  { print }
' "$synthetic_package_evidence_dir/phone-handoff-summary.md" > "$package_summary_tmp"
mv "$package_summary_tmp" "$synthetic_package_evidence_dir/phone-handoff-summary.md"
write_synthetic_manifest "$synthetic_package_evidence_dir"
if "$SCRIPT_DIR/android_pr_readiness.sh" --strict "$synthetic_package_evidence_dir" > "$readiness_package_strict_output" 2>&1; then
  echo "PR readiness strict mode unexpectedly passed with failed installed package evidence" >&2
  exit 1
fi
cp "$synthetic_evidence_dir/phone-handoff-summary.md" "$synthetic_ble_command_ready_evidence_dir/phone-handoff-summary.md"
cp "$synthetic_evidence_dir/evidence-gates.txt" "$synthetic_ble_command_ready_evidence_dir/evidence-gates.txt"
copy_required_evidence_artifacts "$synthetic_evidence_dir" "$synthetic_ble_command_ready_evidence_dir"
ble_command_ready_summary_tmp="$synthetic_ble_command_ready_evidence_dir/phone-handoff-summary.md.tmp"
awk '
  $0 == "- Client hello command-ready completed events: 1" && !replaced {
    print "- Client hello command-ready completed events: 0"
    replaced = 1
    next
  }
  { print }
' "$synthetic_ble_command_ready_evidence_dir/phone-handoff-summary.md" > "$ble_command_ready_summary_tmp"
mv "$ble_command_ready_summary_tmp" "$synthetic_ble_command_ready_evidence_dir/phone-handoff-summary.md"
write_synthetic_manifest "$synthetic_ble_command_ready_evidence_dir"
if "$SCRIPT_DIR/android_pr_readiness.sh" --strict "$synthetic_ble_command_ready_evidence_dir" > "$readiness_ble_command_ready_strict_output" 2>&1; then
  echo "PR readiness strict mode unexpectedly passed with missing command-ready client hello evidence" >&2
  exit 1
fi
cp "$synthetic_evidence_dir/phone-handoff-summary.md" "$synthetic_health_success_evidence_dir/phone-handoff-summary.md"
cp "$synthetic_evidence_dir/evidence-gates.txt" "$synthetic_health_success_evidence_dir/evidence-gates.txt"
copy_required_evidence_artifacts "$synthetic_evidence_dir" "$synthetic_health_success_evidence_dir"
health_success_gates_tmp="$synthetic_health_success_evidence_dir/evidence-gates.txt.tmp"
awk '
  $0 == "GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_SUCCESS=0" && !replaced {
    print "GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_SUCCESS=1"
    replaced = 1
    next
  }
  { print }
' "$synthetic_health_success_evidence_dir/evidence-gates.txt" > "$health_success_gates_tmp"
mv "$health_success_gates_tmp" "$synthetic_health_success_evidence_dir/evidence-gates.txt"
health_success_summary_tmp="$synthetic_health_success_evidence_dir/phone-handoff-summary.md.tmp"
awk '
  $0 == "- Write succeeded events: 1" && !replaced {
    print "- Write succeeded events: 0"
    replaced = 1
    next
  }
  { print }
' "$synthetic_health_success_evidence_dir/phone-handoff-summary.md" > "$health_success_summary_tmp"
mv "$health_success_summary_tmp" "$synthetic_health_success_evidence_dir/phone-handoff-summary.md"
write_synthetic_manifest "$synthetic_health_success_evidence_dir"
if "$SCRIPT_DIR/android_pr_readiness.sh" --strict "$synthetic_health_success_evidence_dir" > "$readiness_health_success_strict_output" 2>&1; then
  echo "PR readiness strict mode unexpectedly passed with missing required Health Connect success" >&2
  exit 1
fi
cp "$synthetic_evidence_dir/phone-handoff-summary.md" "$synthetic_manifest_evidence_dir/phone-handoff-summary.md"
cp "$synthetic_evidence_dir/evidence-gates.txt" "$synthetic_manifest_evidence_dir/evidence-gates.txt"
copy_required_evidence_artifacts "$synthetic_evidence_dir" "$synthetic_manifest_evidence_dir"
if "$SCRIPT_DIR/android_pr_readiness.sh" --strict "$synthetic_manifest_evidence_dir" > "$readiness_manifest_strict_output" 2>&1; then
  echo "PR readiness strict mode unexpectedly passed with missing evidence manifest" >&2
  exit 1
fi
cp "$synthetic_evidence_dir/phone-handoff-summary.md" "$synthetic_stale_manifest_evidence_dir/phone-handoff-summary.md"
cp "$synthetic_evidence_dir/evidence-gates.txt" "$synthetic_stale_manifest_evidence_dir/evidence-gates.txt"
copy_required_evidence_artifacts "$synthetic_evidence_dir" "$synthetic_stale_manifest_evidence_dir"
cat > "$synthetic_stale_manifest_evidence_dir/evidence-files-manifest.txt" <<'MANIFEST'
path	bytes	sha256
phone-handoff-summary.md	1	0000000000000000000000000000000000000000000000000000000000000000
MANIFEST
if "$SCRIPT_DIR/android_pr_readiness.sh" --strict "$synthetic_stale_manifest_evidence_dir" > "$readiness_stale_manifest_strict_output" 2>&1; then
  echo "PR readiness strict mode unexpectedly passed with stale evidence manifest" >&2
  exit 1
fi
cp "$synthetic_evidence_dir/phone-handoff-summary.md" "$synthetic_incomplete_manifest_evidence_dir/phone-handoff-summary.md"
cp "$synthetic_evidence_dir/evidence-gates.txt" "$synthetic_incomplete_manifest_evidence_dir/evidence-gates.txt"
copy_required_evidence_artifacts "$synthetic_evidence_dir" "$synthetic_incomplete_manifest_evidence_dir"
{
  echo "path	bytes	sha256"
  printf '%s\t%s\t%s\n' \
    "phone-handoff-summary.md" \
    "$(file_size "$synthetic_incomplete_manifest_evidence_dir/phone-handoff-summary.md")" \
    "$(file_sha256 "$synthetic_incomplete_manifest_evidence_dir/phone-handoff-summary.md")"
} > "$synthetic_incomplete_manifest_evidence_dir/evidence-files-manifest.txt"
if "$SCRIPT_DIR/android_pr_readiness.sh" --strict "$synthetic_incomplete_manifest_evidence_dir" > "$readiness_incomplete_manifest_strict_output" 2>&1; then
  echo "PR readiness strict mode unexpectedly passed with incomplete evidence manifest" >&2
  exit 1
fi
write_required_evidence_artifacts "$synthetic_partial_evidence_dir"
cat > "$synthetic_partial_evidence_dir/phone-handoff-summary.md" <<SUMMARY
# Goose Android Phone Evidence

Generated at: 20260603T000000Z
Device serial: physical-android-smoke
Device kind: physical
Device: Synthetic Android
Android: 16 (SDK 36)
Commit: synthetic
Result: PASS

## Device

- Focused AndroidRuntime crash lines: 0
- Final adb state: device
- Logcat start marker result: PASS

## Installed App

- Result: PASS
- Package path: package:/data/app/com.goose.android/base.apk
- Local debug APK SHA-256: 1111111111111111111111111111111111111111111111111111111111111111
- Installed APK SHA-256: 1111111111111111111111111111111111111111111111111111111111111111
- Installed APK hash result: PASS

## Capture

- Database bytes: $(file_size "$synthetic_partial_evidence_dir/goose-phone.sqlite")
- Database SHA-256: $(file_sha256 "$synthetic_partial_evidence_dir/goose-phone.sqlite")
- Database WAL bytes: 0
- Database WAL SHA-256: missing
- Database SHM bytes: 0
- Database SHM SHA-256: missing
- Raw evidence rows: 2
- Decoded frame rows: 1
- Capture sessions: 1
- Session raw evidence rows: 1
- Session live notification raw evidence rows: 1
- Session decoded frame rows: 1
- Finished nonempty capture sessions: 1
- Step samples: 1
- Daily activity metrics: 1
- Latest raw capture: 2026-06-04T12:00:01.000Z
- Latest raw capture after marker result: PASS

## BLE Session

- Ready events: 1
- Hello sent events: 1
- Client hello completed events: 1
- Client hello command-ready completed events: 1
- Command ready events: 1
- Ready hello command-ready events: 1

## Health Connect

- Write started events: 1
- Ready write started events: 1
- Planned write started events: 1
- Candidate write started events: 1
- Records attempted events: 1
- Write succeeded events: 0
- Ready write succeeded events: 0
- Planned write succeeded events: 0
- Records inserted events: 0
- Write failed events: 0

## Step Validation

- Completed events: 0
- Passed events: 0
- Failed events: 0
- Session-bound events: 0
- Session decoded events: 0
- Selected delta events: 0
- Passing session selected-delta events: 0
SUMMARY
cat > "$synthetic_partial_evidence_dir/evidence-gates.txt" <<'GATES'
GOOSE_ANDROID_REQUIRE_BLE_HELLO_SENT=1
GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_PASS=0
GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_SESSION=0
GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_ATTEMPT=1
GOOSE_ANDROID_REQUIRE_HEALTH_READY_WRITE_PLAN=1
GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_SUCCESS=0
GOOSE_ANDROID_REQUIRE_LOGCAT_START_MARKER=1
GATES
write_synthetic_manifest "$synthetic_partial_evidence_dir"
"$SCRIPT_DIR/android_pr_readiness.sh" "$synthetic_partial_evidence_dir" > "$readiness_partial_output"
if "$SCRIPT_DIR/android_pr_readiness.sh" --strict "$synthetic_partial_evidence_dir" > "$readiness_partial_strict_output" 2>&1; then
  echo "PR readiness strict mode unexpectedly passed with partial phone evidence" >&2
  exit 1
fi
assert_file_contains "$checklist_output" "Goose Android Final Phone Checklist" "final phone checklist"
assert_file_contains "$checklist_output" "Scripts/android_final_pr_gate.sh tmp/android-phone-final-gate-real" "final phone checklist"
assert_file_contains "$checklist_output" "Scripts/prepare_android_phone_evidence.sh" "final phone checklist"
assert_file_contains "$checklist_output" "Scripts/android_phone_final_gate.sh tmp/android-phone-diagnostic-gate-real --require-step-validation" "final phone checklist"
assert_file_contains "$checklist_output" "without strict PR readiness" "final phone checklist"
assert_file_contains "$checklist_output" "Reprint the PR-ready summary" "final phone checklist"
assert_file_contains "$checklist_output" "Focused AndroidRuntime crash lines: 0." "final phone checklist"
assert_file_contains "$checklist_output" "Installed com.goose.android package metadata and APK hash match: PASS." "final phone checklist"
assert_file_contains "$checklist_output" "Logcat start marker result: PASS." "final phone checklist"
assert_file_contains "$checklist_output" "Latest raw capture after marker result: PASS." "final phone checklist"
assert_file_contains "$checklist_output" "Decoded frame rows: at least 1." "final phone checklist"
assert_file_contains "$checklist_output" "Session decoded frame rows: at least 1." "final phone checklist"
assert_file_contains "$checklist_output" "\`adb-devices.txt\`" "final phone checklist"
assert_file_contains "$checklist_output" "\`android-serial.txt\`" "final phone checklist"
assert_file_contains "$checklist_output" "\`device-model.txt\`" "final phone checklist"
assert_file_contains "$checklist_output" "\`goose-package-path.txt\`" "final phone checklist"
assert_file_contains "$checklist_output" "\`goose-package-dumpsys.txt\`" "final phone checklist"
assert_file_contains "$checklist_output" "BLE session hello sent events: at least 1." "final phone checklist"
assert_file_contains "$checklist_output" "BLE session client hello command-ready completed events: at least 1." "final phone checklist"
assert_file_contains "$checklist_output" "BLE session ready hello command-ready events: at least 1." "final phone checklist"
assert_file_contains "$checklist_output" "Session live notification raw evidence rows: at least 1." "final phone checklist"
assert_file_contains "$checklist_output" "Step validation passed events: at least 1." "final phone checklist"
assert_file_contains "$checklist_output" "Step validation session decoded events: at least 1." "final phone checklist"
assert_file_contains "$checklist_output" "Tap validation \`End\` while the capture session is still active." "final phone checklist"
assert_file_contains "$checklist_output" "Scripts/android_final_pr_gate.sh tmp/android-phone-final-gate-real --skip-validate" "final phone checklist"
assert_file_contains "$checklist_output" "validation does not clear that scoped evidence before collection" "final phone checklist"
assert_file_contains "$checklist_output" "Health Connect ready write started events: at least 1." "final phone checklist"
assert_file_contains "$SCRIPT_DIR/install_android_debug.sh" "tap validation End while the capture session is still active." "Android install handoff"
assert_file_contains "$partial_checklist_output" "Goose Android Partial Phone Checklist" "partial phone checklist"
assert_file_contains "$partial_checklist_output" "Use this while counted-step validation is parked." "partial phone checklist"
assert_file_contains "$partial_checklist_output" "Scripts/android_partial_phone_gate.sh tmp/android-phone-partial-gate-real" "partial phone checklist"
assert_file_contains "$partial_checklist_output" "Scripts/prepare_android_phone_evidence.sh" "partial phone checklist"
assert_file_contains "$partial_checklist_output" "Scripts/android_phone_final_gate.sh tmp/android-phone-partial-diagnostic-gate-real" "partial phone checklist"
assert_file_contains "$partial_checklist_output" "separate diagnostic bundle" "partial phone checklist"
assert_file_contains "$partial_checklist_output" "Installed com.goose.android package metadata and APK hash match: PASS." "partial phone checklist"
assert_file_contains "$partial_checklist_output" "Logcat start marker result: PASS." "partial phone checklist"
assert_file_contains "$partial_checklist_output" "Latest raw capture after marker result: PASS." "partial phone checklist"
assert_file_contains "$partial_checklist_output" "Decoded frame rows: at least 1." "partial phone checklist"
assert_file_contains "$partial_checklist_output" "Session decoded frame rows: at least 1." "partial phone checklist"
assert_file_contains "$partial_checklist_output" "BLE session client hello command-ready completed events: at least 1." "partial phone checklist"
assert_file_contains "$partial_checklist_output" "BLE session ready hello command-ready events: at least 1." "partial phone checklist"
assert_file_contains "$partial_checklist_output" "Session live notification raw evidence rows: at least 1." "partial phone checklist"
assert_file_contains "$partial_checklist_output" "Health Connect ready write started events: at least 1." "partial phone checklist"
assert_file_contains "$partial_checklist_output" "Counted-step validation with" "partial phone checklist"
assert_file_contains "$readiness_output" "Goose Android PR Readiness" "PR readiness"
assert_file_contains "$readiness_output" "No phone evidence directory supplied." "PR readiness"
assert_file_contains "$readiness_output" "Remaining Phone-Bound Acceptance" "PR readiness"
assert_file_contains "$readiness_output" "Scripts/android_final_pr_gate.sh tmp/android-phone-final-gate-real" "PR readiness"
assert_file_contains "$readiness_output" "Scripts/android_phone_final_gate.sh tmp/android-phone-diagnostic-gate-real --require-step-validation" "PR readiness"
assert_file_contains "$readiness_output" "Scripts/android_pr_readiness.sh --strict tmp/android-phone-final-gate-real" "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "Phone evidence commit must match the current checkout commit." "PR readiness"
assert_file_contains "$readiness_strict_output" "Strict PR readiness: FAIL" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Bundle profile: final PR evidence" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "required counted-step validation gates enabled" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Evidence result file: PASS" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Phone handoff summary result matches evidence-result.txt." "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Android database pull helper result is PASS in the evidence bundle." "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Inspect database SHA-256:" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Pulled SQLite database artifact hashes match inspect-android-capture.txt and phone handoff summary." "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Inspect raw evidence rows: 2" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Inspect decoded frame rows: 1" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Inspect session live notification raw evidence rows: 1" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Inspect session decoded frame rows: 1" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Phone handoff capture counts match inspect-android-capture.txt." "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Inspect hello sent events: 1" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Inspect client hello command-ready completed events: 1" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Inspect ready hello command-ready events: 1" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Phone handoff BLE session counts match inspect-android-capture.txt." "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "BLE session audit log, current or rotated, is included in the evidence byte/hash manifest." "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "completed client hello write in command-ready rows." "PR readiness strict"
assert_file_contains "$readiness_ble_command_ready_strict_output" "BLE session audit from the final gate must prove completed client hello write in command-ready rows." "PR readiness BLE command-ready strict"
assert_file_contains "$readiness_strict_pass_output" "Inspect records attempted events: 1" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Inspect ready write succeeded events: 1" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Inspect planned write succeeded events: 1" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Inspect records inserted events: 1" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Phone handoff Health Connect counts match inspect-android-capture.txt." "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Health Connect audit log, current or rotated, is included in the evidence byte/hash manifest." "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Inspect selected delta events: 1" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Phone handoff step-validation counts match inspect-android-capture.txt." "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Step-validation audit log, current or rotated, is included in the evidence byte/hash manifest." "PR readiness strict"
assert_file_contains "$readiness_rotated_audit_manifest_strict_output" "Strict PR readiness: PASS" "PR readiness rotated audit manifest strict"
assert_file_contains "$readiness_rotated_audit_manifest_strict_output" "BLE session audit log, current or rotated, is included in the evidence byte/hash manifest." "PR readiness rotated audit manifest strict"
assert_file_contains "$readiness_strict_pass_output" "Summary commit: $SYNTHETIC_COMMIT" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Status snapshot commit: $SYNTHETIC_COMMIT" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Current checkout commit: $SYNTHETIC_COMMIT" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Status snapshot dirty tracked files: 0" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Status snapshot untracked non-ignored files: 0" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Status snapshot debug APK SHA-256: 1111111111111111111111111111111111111111111111111111111111111111" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Phone handoff summary commit matches the Android port status snapshot." "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Phone evidence commit matches the current checkout commit." "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Phone evidence status snapshot was collected from a clean worktree." "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Phone evidence local debug APK hash matches android-port-status.txt." "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Evidence serial file: physical-android-smoke" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Phone handoff summary device serial matches android-serial.txt." "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Evidence device kind file: physical" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Phone handoff summary device kind matches android-device-kind.txt." "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Evidence device files: Synthetic Android" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Phone handoff summary device identity matches device-manufacturer.txt and device-model.txt." "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Evidence Android files: 16 (SDK 36)" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Phone handoff summary Android version matches android-version.txt and android-sdk.txt." "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "adb device state: device" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "adb-devices.txt lists the handoff device serial as online." "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Final adb state: device" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Evidence final adb state file: device" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "adb-state-final.txt confirms the handoff device was still online after evidence collection." "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Evidence package path file: package:/data/app/com.goose.android/base.apk" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Evidence package summary versionName=0.1.0: 1" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Evidence package dumpsys com.goose.android: 1" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Evidence local debug APK SHA-256 file: 1111111111111111111111111111111111111111111111111111111111111111" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Evidence installed APK SHA-256 file: 1111111111111111111111111111111111111111111111111111111111111111" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Evidence focused AndroidRuntime crash lines: 0" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Logcat start marker result: PASS" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Logcat start marker scopes the focused AndroidRuntime crash evidence to com.goose.android on the handoff serial." "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Latest raw capture after marker result: PASS" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Latest raw capture timestamp is at or after the controlled-run logcat start marker." "PR readiness strict"
assert_file_contains "$synthetic_evidence_dir/logcat-goose-brief.txt" "GooseBridgeSmoke" "PR readiness strict"
assert_file_contains "$synthetic_evidence_dir/evidence-files-manifest.txt" "logcat-start-marker.txt" "PR readiness strict"
assert_file_contains "$synthetic_evidence_dir/logcat-goose-brief.txt" "com.goose.android smoke harness completed" "PR readiness strict"
assert_file_contains "$synthetic_evidence_dir/evidence-files-manifest.txt" "logcat-threadtime.txt" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "Strict PR readiness: PASS" "PR readiness strict"
assert_file_contains "$readiness_strict_pass_output" "- None from the supplied evidence bundle." "PR readiness strict"
assert_file_contains "$readiness_crash_strict_output" "Focused AndroidRuntime logcat must have 0 com.goose.android crash lines." "PR readiness crash strict"
assert_file_contains "$readiness_crash_strict_output" "Strict PR readiness: FAIL" "PR readiness crash strict"
assert_file_contains "$readiness_package_strict_output" "Installed com.goose.android package metadata and APK hash match must pass the evidence gate." "PR readiness package strict"
assert_file_contains "$readiness_package_strict_output" "Strict PR readiness: FAIL" "PR readiness package strict"
assert_file_contains "$readiness_health_success_strict_output" "Health Connect successful platform write must include permissions-ready planned-write context and inserted records because the final gate required it." "PR readiness health success strict"
assert_file_contains "$readiness_health_success_strict_output" "Strict PR readiness: FAIL" "PR readiness health success strict"
assert_file_contains "$readiness_manifest_strict_output" "Evidence bundle must include a valid evidence-files-manifest.txt with matching path, byte, and SHA-256 columns for required evidence files." "PR readiness manifest strict"
assert_file_contains "$readiness_manifest_strict_output" "Strict PR readiness: FAIL" "PR readiness manifest strict"
assert_file_contains "$readiness_stale_manifest_strict_output" "Evidence bundle must include a valid evidence-files-manifest.txt with matching path, byte, and SHA-256 columns for required evidence files." "PR readiness stale manifest strict"
assert_file_contains "$readiness_stale_manifest_strict_output" "Strict PR readiness: FAIL" "PR readiness stale manifest strict"
assert_file_contains "$readiness_incomplete_manifest_strict_output" "Evidence bundle must include a valid evidence-files-manifest.txt with matching path, byte, and SHA-256 columns for required evidence files." "PR readiness incomplete manifest strict"
assert_file_contains "$readiness_incomplete_manifest_strict_output" "Strict PR readiness: FAIL" "PR readiness incomplete manifest strict"
assert_file_contains "$readiness_audit_manifest_strict_output" "BLE session audit log, current or rotated, must be included in the evidence byte/hash manifest." "PR readiness audit manifest strict"
assert_file_contains "$readiness_audit_manifest_strict_output" "Strict PR readiness: FAIL" "PR readiness audit manifest strict"
assert_file_contains "$readiness_health_audit_manifest_strict_output" "Health Connect audit log, current or rotated, must be included in the evidence byte/hash manifest." "PR readiness health audit manifest strict"
assert_file_contains "$readiness_health_audit_manifest_strict_output" "Strict PR readiness: FAIL" "PR readiness health audit manifest strict"
assert_file_contains "$readiness_step_audit_manifest_strict_output" "Step-validation audit log, current or rotated, must be included in the evidence byte/hash manifest." "PR readiness step audit manifest strict"
assert_file_contains "$readiness_step_audit_manifest_strict_output" "Strict PR readiness: FAIL" "PR readiness step audit manifest strict"
assert_file_contains "$readiness_stale_commit_strict_output" "Phone evidence commit must match the current checkout commit." "PR readiness stale commit strict"
assert_file_contains "$readiness_stale_commit_strict_output" "Strict PR readiness: FAIL" "PR readiness stale commit strict"
assert_file_contains "$readiness_stale_debug_apk_strict_output" "Phone evidence local debug APK hash must match android-port-status.txt." "PR readiness stale debug APK strict"
assert_file_contains "$readiness_stale_debug_apk_strict_output" "Strict PR readiness: FAIL" "PR readiness stale debug APK strict"
assert_file_contains "$readiness_dirty_status_strict_output" "Phone evidence status snapshot must show 0 dirty tracked files and 0 untracked non-ignored files." "PR readiness dirty status strict"
assert_file_contains "$readiness_dirty_status_strict_output" "Strict PR readiness: FAIL" "PR readiness dirty status strict"
assert_file_contains "$readiness_collect_error_strict_output" "Evidence bundle must not contain nonempty collect-error.txt diagnostics." "PR readiness collect error strict"
assert_file_contains "$readiness_collect_error_strict_output" "Strict PR readiness: FAIL" "PR readiness collect error strict"
assert_file_contains "$readiness_logcat_marker_strict_output" "Logcat start marker from Scripts/prepare_android_phone_evidence.sh must be present in marker, full logcat, focused logcat, manifest evidence, com.goose.android package scope, and the handoff serial." "PR readiness logcat marker strict"
assert_file_contains "$readiness_logcat_marker_strict_output" "Strict PR readiness: FAIL" "PR readiness logcat marker strict"
assert_file_contains "$readiness_stale_capture_marker_strict_output" "Latest raw capture timestamp must be present, match inspect-android-capture.txt, and be at or after the controlled-run logcat start marker." "PR readiness stale capture marker strict"
assert_file_contains "$readiness_stale_capture_marker_strict_output" "Strict PR readiness: FAIL" "PR readiness stale capture marker strict"
assert_file_contains "$readiness_partial_output" "Bundle profile: partial phone evidence" "PR readiness partial"
assert_file_contains "$readiness_partial_output" "not enough for final PR readiness" "PR readiness partial"
assert_file_contains "$readiness_partial_strict_output" "Strict PR readiness: FAIL" "PR readiness partial strict"
assert_file_contains "$readiness_partial_strict_output" "Step-counter decoder confirmation" "PR readiness partial strict"
assert_file_contains "$final_gate_dry_run_output" "skip validate" "final PR gate dry run"
assert_file_contains "$final_gate_dry_run_output" "clean pushed worktree: required" "final PR gate dry run"
assert_file_contains "$final_gate_dry_run_output" "android_phone_final_gate.sh tmp/android-phone-final-gate-real --require-step-validation --require-health-success" "final PR gate dry run"
assert_file_contains "$final_gate_dry_run_output" "android_pr_readiness.sh --strict tmp/android-phone-final-gate-real" "final PR gate dry run"
assert_file_contains "$partial_gate_dry_run_output" "skip validate" "partial phone gate dry run"
assert_file_contains "$partial_gate_dry_run_output" "clean pushed worktree: required" "partial phone gate dry run"
assert_file_contains "$partial_gate_dry_run_output" "android_phone_final_gate.sh tmp/android-phone-partial-gate-real --require-health-success" "partial phone gate dry run"
assert_file_contains "$partial_gate_dry_run_output" "android_pr_readiness.sh tmp/android-phone-partial-gate-real" "partial phone gate dry run"
assert_file_contains "$SCRIPT_DIR/android_gate_worktree.sh" "require_clean_pushed_worktree" "Android gate worktree helper"
assert_file_contains "$SCRIPT_DIR/android_gate_worktree.sh" "\$gate_label requires a clean git worktree." "Android gate worktree helper"
assert_file_contains "$SCRIPT_DIR/android_gate_worktree.sh" "\$gate_label requires HEAD (\$head_commit) to match upstream" "Android gate worktree helper"
assert_file_contains "$SCRIPT_DIR/android_gate_worktree.sh" "Pull/rebase or push the current commit first" "Android gate worktree helper"
assert_file_contains "$SCRIPT_DIR/android_final_pr_gate.sh" 'source "$SCRIPT_DIR/android_gate_worktree.sh"' "final PR gate"
assert_file_contains "$SCRIPT_DIR/android_final_pr_gate.sh" 'require_clean_pushed_worktree "$APP_DIR" "Final PR gate"' "final PR gate"
assert_file_contains "$SCRIPT_DIR/android_final_pr_gate.sh" "requires HEAD to match the configured upstream" "final PR gate"
assert_file_contains "$SCRIPT_DIR/android_partial_phone_gate.sh" 'source "$SCRIPT_DIR/android_gate_worktree.sh"' "partial phone gate"
assert_file_contains "$SCRIPT_DIR/android_partial_phone_gate.sh" 'require_clean_pushed_worktree "$APP_DIR" "Partial phone gate"' "partial phone gate"
assert_file_contains "$SCRIPT_DIR/android_partial_phone_gate.sh" "requires HEAD to match the configured upstream" "partial phone gate"
assert_file_contains "$SCRIPT_DIR/android_phone_final_gate.sh" "GOOSE_ANDROID_REQUIRE_NO_ANDROID_RUNTIME_CRASH=1" "final phone gate"
assert_file_contains "$SCRIPT_DIR/android_phone_final_gate.sh" "GOOSE_ANDROID_REQUIRE_LOGCAT_START_MARKER=1" "final phone gate"
assert_file_contains "$SCRIPT_DIR/android_phone_final_gate.sh" "Final gate diagnostics:" "final phone gate"
assert_file_contains "$SCRIPT_DIR/android_phone_final_gate.sh" "collect-error.txt" "final phone gate"
assert_file_contains "$SCRIPT_DIR/android_phone_final_gate.sh" "Android final phone gate failed:" "final phone gate"
assert_file_contains "$SCRIPT_DIR/install_android_debug.sh" "Verifying installed APK hash" "Android debug installer"
assert_file_contains "$SCRIPT_DIR/install_android_debug.sh" "Installed APK hash mismatch" "Android debug installer"
assert_file_contains "$SCRIPT_DIR/install_android_debug.sh" "collect final PR evidence" "Android debug installer"
assert_file_contains "$SCRIPT_DIR/install_android_debug.sh" "latest raw capture timestamp to be at or after the logcat start marker" "Android debug installer"
assert_file_contains "$SCRIPT_DIR/install_android_debug.sh" "android_partial_phone_gate.sh tmp/android-phone-partial-gate-real --skip-validate" "Android debug installer"
assert_file_contains "$SCRIPT_DIR/install_android_debug.sh" "without strict PR readiness" "Android debug installer"
assert_file_contains "$SCRIPT_DIR/collect_android_phone_evidence.sh" "GOOSE_ANDROID_REQUIRE_NO_ANDROID_RUNTIME_CRASH" "phone evidence collector"
assert_file_contains "$SCRIPT_DIR/collect_android_phone_evidence.sh" "Focused AndroidRuntime crash lines:" "phone evidence collector"
assert_file_contains "$SCRIPT_DIR/collect_android_phone_evidence.sh" "Logcat start marker result:" "phone evidence collector"
assert_file_contains "$SCRIPT_DIR/collect_android_phone_evidence.sh" "/AndroidRuntime/ && /com[.]goose[.]android/" "phone evidence collector"
assert_file_contains "$SCRIPT_DIR/collect_android_phone_evidence.sh" "logcat-threadtime.txt: full device logcat snapshot." "phone evidence collector"
assert_file_contains "$SCRIPT_DIR/collect_android_phone_evidence.sh" "logcat-start-marker.txt" "phone evidence collector"
assert_file_contains "$SCRIPT_DIR/collect_android_phone_evidence.sh" "evidence-files-manifest.txt" "phone evidence collector"
assert_file_contains "$SCRIPT_DIR/collect_android_phone_evidence.sh" "path	bytes	sha256" "phone evidence collector"
assert_file_contains "$SCRIPT_DIR/collect_android_phone_evidence.sh" "Evidence output directory is not empty:" "phone evidence collector"
assert_file_contains "$SCRIPT_DIR/collect_android_phone_evidence.sh" "GOOSE_ANDROID_ALLOW_EXISTING_EVIDENCE_DIR=1" "phone evidence collector"
assert_file_contains "$SCRIPT_DIR/collect_android_phone_evidence.sh" "Installed APK hash result:" "phone evidence collector"
assert_file_contains "$SCRIPT_DIR/collect_android_phone_evidence.sh" "adb-state-final.txt" "phone evidence collector"
assert_file_contains "$SCRIPT_DIR/collect_android_phone_evidence.sh" "adb target was not online after evidence collection" "phone evidence collector"
assert_file_contains "$SCRIPT_DIR/collect_android_phone_evidence.sh" "required when BLE hello gates are enabled" "phone evidence collector"
assert_file_contains "$SCRIPT_DIR/collect_android_phone_evidence.sh" "required when Health Connect write gates are enabled" "phone evidence collector"
assert_file_contains "$SCRIPT_DIR/collect_android_phone_evidence.sh" "required when step-validation gates are enabled" "phone evidence collector"
assert_file_contains "$SCRIPT_DIR/collect_android_phone_evidence.sh" 'Database pull result: $(summary_value_from "RESULT" "$OUTPUT_DIR/pull-android-database-result.txt")' "phone evidence collector"
assert_file_contains "$SCRIPT_DIR/collect_android_phone_evidence.sh" "Android capture inspection failed with exit status" "phone evidence collector"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "goose-installed-apk-sha256.txt" "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "/AndroidRuntime/ && /com[.]goose[.]android/" "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "logcat-threadtime.txt" "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "logcat-start-marker.txt" "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "valid_logcat_start_marker" "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "capture_at_or_after_marker" "PR readiness"
assert_file_contains "$SCRIPT_DIR/collect_android_phone_evidence.sh" "valid_logcat_start_marker" "phone evidence collector"
assert_file_contains "$SCRIPT_DIR/collect_android_phone_evidence.sh" "latest raw capture is missing, unparseable, or older than the logcat start marker" "phone evidence collector"
assert_file_contains "$SCRIPT_DIR/prepare_android_phone_evidence.sh" "Goose evidence start marker written" "phone evidence prep"
assert_file_contains "$SCRIPT_DIR/prepare_android_phone_evidence.sh" "latest pulled raw capture timestamp to be at or" "phone evidence prep"
assert_file_contains "$SCRIPT_DIR/prepare_android_phone_evidence.sh" "android_partial_phone_gate.sh tmp/android-phone-partial-gate-real --skip-validate" "phone evidence prep"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "android-port-status.txt" "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "goose-package-path.txt" "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "goose-package-dumpsys.txt" "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "adb-devices.txt" "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "adb-state-final.txt" "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "device-manufacturer.txt" "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "android-sdk.txt" "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "Phone handoff summary commit must match android-port-status.txt." "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "Phone handoff summary result must match evidence-result.txt." "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "Android database pull helper result must be present and PASS." "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "Phone evidence local debug APK hash must match android-port-status.txt." "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "Phone handoff capture counts, including decoded frame counts, must match inspect-android-capture.txt." "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "Phone handoff BLE session counts must match inspect-android-capture.txt." "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "Phone handoff Health Connect counts must match inspect-android-capture.txt." "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "Phone handoff step-validation counts must match inspect-android-capture.txt." "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "BLE session audit log, current or rotated, must be included in the evidence byte/hash manifest." "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "Health Connect audit log, current or rotated, must be included in the evidence byte/hash manifest." "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "Step-validation audit log, current or rotated, must be included in the evidence byte/hash manifest." "PR readiness"
assert_file_contains "$SCRIPT_DIR/inspect_android_capture.sh" "audit_files_for" "capture inspection"
assert_file_contains "$SCRIPT_DIR/collect_android_phone_evidence.sh" ".jsonl.old" "phone evidence collector"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "Phone handoff summary device serial must match android-serial.txt." "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "Phone handoff summary device kind must match android-device-kind.txt." "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "Phone handoff summary device identity must match device-manufacturer.txt and device-model.txt." "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "Phone handoff summary Android version must match android-version.txt and android-sdk.txt." "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "adb-devices.txt must list the handoff device serial as online." "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "adb-state-final.txt must show the handoff device was still online after evidence collection." "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "Evidence package path file:" "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "Evidence package summary versionName=0.1.0:" "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "Evidence package dumpsys com.goose.android:" "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "Evidence local debug APK SHA-256 file:" "PR readiness"
assert_file_contains "$SCRIPT_DIR/android_pr_readiness.sh" "Evidence installed APK SHA-256 file:" "PR readiness"
assert_file_contains "$APP_DIR/README.md" "a logcat start marker, no focused" "root README"
assert_file_contains "$APP_DIR/README.md" "latest raw capture timestamp at or after" "root README"
assert_file_contains "$APP_DIR/README.md" "byte/hash file manifest" "root README"
assert_file_contains "$APP_DIR/README.md" "APK hash comparison" "root README"
assert_file_contains "$APP_DIR/README.md" 'requires a clean git worktree whose `HEAD` exactly matches the configured' "root README"
assert_file_contains "$APP_DIR/README.md" "maps to the current pushed commit" "root README"
assert_file_contains "$APP_DIR/README.md" "reads the installed APK back over adb" "root README"
assert_file_contains "$APP_DIR/README.md" "prepare_android_phone_evidence.sh" "root README"
assert_file_contains "$APP_DIR/README.md" "Scripts/android_partial_phone_checklist.sh" "root README"
assert_file_contains "$APP_DIR/README.md" "only after pressing step-validation \`End\` while the capture session is still" "root README"
assert_file_contains "$APP_DIR/README.md" "run the final PR gate with \`--skip-validate\` so the gate does not clear logcat" "root README"
assert_file_contains "$ANDROID_DIR/README.md" "no-focused-AndroidRuntime-crash" "Android README"
assert_file_contains "$ANDROID_DIR/README.md" "compares the installed APK hash" "Android README"
assert_file_contains "$ANDROID_DIR/README.md" 'requires a clean git worktree whose `HEAD` exactly matches the configured' "Android README"
assert_file_contains "$ANDROID_DIR/README.md" "maps to the current pushed commit" "Android README"
assert_file_contains "$ANDROID_DIR/README.md" "APK hash matches the local debug APK" "Android README"
assert_file_contains "$ANDROID_DIR/README.md" "logcat-start-marker" "Android README"
assert_file_contains "$ANDROID_DIR/README.md" "latest pulled raw capture timestamp is at" "Android README"
assert_file_contains "$ANDROID_DIR/README.md" "bounded BLE session, Health Connect sync, and step-validation audit logs" "Android README"
assert_file_contains "$ANDROID_DIR/README.md" "must be present in" "Android README"
assert_file_contains "$ANDROID_DIR/README.md" "press \`End\` afterwards while the capture session is" "Android README"
assert_file_contains "$ANDROID_DIR/README.md" "run the final PR gate with \`--skip-validate\` so the gate does not clear logcat" "Android README"
assert_file_contains "$ANDROID_DIR/app/src/main/java/com/goose/android/GooseStoreReporter.java" "health sync ready write succeeded events" "Android evidence report"
assert_file_contains "$ANDROID_DIR/app/src/main/java/com/goose/android/GooseStoreReporter.java" "health sync planned write succeeded events" "Android evidence report"
assert_file_contains "$ANDROID_DIR/app/src/main/java/com/goose/android/GooseStoreReporter.java" "health sync records inserted events" "Android evidence report"
assert_file_contains "$ANDROID_DIR/app/src/main/java/com/goose/android/GooseStoreReporter.java" "attemptedManualStepDelta" "Android step-validation failure audit"
assert_file_contains "$ANDROID_DIR/app/src/main/java/com/goose/android/GooseStoreReporter.java" "attemptedCaptureSessionId" "Android step-validation failure audit"
assert_file_contains "$ANDROID_DIR/app/src/main/java/com/goose/android/GooseBleClient.java" "if (closed || !scanning)" "BLE scan callback lifecycle"
assert_file_contains "$ANDROID_DIR/app/src/main/java/com/goose/android/GooseBleClient.java" "publishQueued = false;" "BLE scan publish lifecycle"
assert_file_contains "$ANDROID_DIR/app/src/main/java/com/goose/android/GooseBleClient.java" "isCurrentGattCallback" "BLE stale GATT callback guardrail"
assert_file_contains "$ANDROID_DIR/app/src/androidTest/java/com/goose/android/GooseRustBridgeInstrumentationTest.java" "assertBleStaleGattCallbackGuardrails" "BLE stale GATT callback guardrail"
assert_file_contains "$ANDROID_DIR/app/src/main/java/com/goose/android/GooseCommandBuilder.java" "executeIfOpen" "Android closed executor guardrail"
assert_file_contains "$ANDROID_DIR/app/src/main/java/com/goose/android/GoosePacketIngestor.java" "executeIfOpen" "Android closed executor guardrail"
assert_file_contains "$ANDROID_DIR/app/src/main/java/com/goose/android/GooseStoreReporter.java" "executeIfOpen" "Android closed executor guardrail"
assert_file_contains "$ANDROID_DIR/app/src/androidTest/java/com/goose/android/GooseRustBridgeInstrumentationTest.java" "assertClosedExecutorSubmissionGuardrails" "Android closed executor guardrail"
assert_file_contains "$ANDROID_DIR/app/src/main/java/com/goose/android/MainActivity.java" "stepValidationStartBlockReason" "Android step-validation start guardrail"
assert_file_contains "$ANDROID_DIR/app/src/main/java/com/goose/android/MainActivity.java" "Start a capture session before Step validation Start." "Android step-validation start guardrail"
assert_file_contains "$ANDROID_DIR/app/src/main/java/com/goose/android/MainActivity.java" "stepValidationEndBlockReason" "Android step-validation end guardrail"
assert_file_contains "$ANDROID_DIR/app/src/main/java/com/goose/android/MainActivity.java" "Keep the capture session active until Step validation End." "Android step-validation end guardrail"
assert_file_contains "$ANDROID_DIR/app/src/androidTest/java/com/goose/android/GooseRustBridgeInstrumentationTest.java" "step validation audit missing selected_delta" "Android step-validation audit smoke"
assert_file_contains "$ANDROID_DIR/app/src/androidTest/java/com/goose/android/GooseRustBridgeInstrumentationTest.java" "step validation audit missing capture_session_decoded_frame_count" "Android step-validation audit smoke"
assert_file_contains "$ANDROID_DIR/app/src/androidTest/java/com/goose/android/GooseRustBridgeInstrumentationTest.java" "assertStepValidationStartGuardrails" "Android step-validation start guardrail"
assert_file_contains "$ANDROID_DIR/app/src/androidTest/java/com/goose/android/GooseRustBridgeInstrumentationTest.java" "assertStepValidationEndGuardrails" "Android step-validation end guardrail"
assert_file_contains "$SCRIPT_DIR/android_port_status.sh" "Focused AndroidRuntime logcat has no com.goose.android crash lines." "Android port status"
assert_file_contains "$SCRIPT_DIR/android_port_status.sh" "Installed com.goose.android package metadata and APK hash match" "Android port status"
assert_file_contains "$SCRIPT_DIR/android_port_status.sh" "Latest raw capture timestamp is at or after the controlled-run logcat start marker." "Android port status"
assert_file_contains "$SCRIPT_DIR/android_port_status.sh" "Final PR evidence gate:" "Android port status"
assert_file_contains "$SCRIPT_DIR/android_port_status.sh" "Lower-level diagnostic phone evidence gate:" "Android port status"
assert_file_contains "$inspect_session_detail_output" "Capture session evidence detail" "capture inspector session detail"
assert_file_contains "$inspect_session_detail_output" "android-session-a" "capture inspector session detail"
assert_file_contains "$inspect_session_detail_output" "live_notification_rows" "capture inspector session detail"
assert_file_contains "$inspect_session_detail_output" "decoded_frames" "capture inspector session detail"
assert_file_contains "$inspect_session_detail_output" "step_samples" "capture inspector session detail"
assert_file_contains "$SCRIPT_DIR/collect_android_phone_evidence.sh" "## Capture Session Evidence Detail" "phone evidence collector"
assert_file_contains "$SCRIPT_DIR/collect_android_phone_evidence.sh" 'summary_section "Capture session evidence detail"' "phone evidence collector"
assert_file_contains "$SCRIPT_DIR/collect_android_phone_evidence.sh" "Multiple adb devices are online. Set ANDROID_SERIAL to one of:" "phone evidence collector"
assert_file_contains "$SCRIPT_DIR/pull_android_database.sh" "Multiple adb devices are online. Set ANDROID_SERIAL to one of:" "database pull"
assert_file_contains "$SCRIPT_DIR/pull_android_database.sh" 'rm -f "$output_path"' "database pull optional stale cleanup"
assert_file_contains "$SCRIPT_DIR/validate_android.sh" "Multiple adb devices are online. Set ANDROID_SERIAL to one of:" "Android validation"

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

device_serial="$(select_adb_target)"

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
