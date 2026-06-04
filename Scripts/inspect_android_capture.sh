#!/usr/bin/env bash
set -euo pipefail

DATABASE="${1:-tmp/goose-phone.sqlite}"
DATABASE_BASENAME="${DATABASE%.sqlite}"
HEALTH_AUDIT_LOG="${HEALTH_AUDIT_LOG:-$DATABASE_BASENAME-health-connect-sync-log.jsonl}"
STEP_VALIDATION_LOG="${STEP_VALIDATION_LOG:-$DATABASE_BASENAME-step-validation-log.jsonl}"
BLE_SESSION_LOG="${BLE_SESSION_LOG:-$DATABASE_BASENAME-ble-session-log.jsonl}"
MIN_RAW_EVIDENCE="${GOOSE_ANDROID_MIN_RAW_EVIDENCE:-0}"
MIN_DECODED_FRAMES="${GOOSE_ANDROID_MIN_DECODED_FRAMES:-0}"
MIN_CAPTURE_SESSIONS="${GOOSE_ANDROID_MIN_CAPTURE_SESSIONS:-0}"
MIN_SESSION_RAW_EVIDENCE="${GOOSE_ANDROID_MIN_SESSION_RAW_EVIDENCE:-0}"
MIN_SESSION_LIVE_NOTIFICATION_RAW_EVIDENCE="${GOOSE_ANDROID_MIN_SESSION_LIVE_NOTIFICATION_RAW_EVIDENCE:-0}"
MIN_SESSION_DECODED_FRAMES="${GOOSE_ANDROID_MIN_SESSION_DECODED_FRAMES:-0}"
MIN_FINISHED_CAPTURE_SESSIONS="${GOOSE_ANDROID_MIN_FINISHED_CAPTURE_SESSIONS:-0}"
REQUIRE_BLE_SESSION_AUDIT="${GOOSE_ANDROID_REQUIRE_BLE_SESSION_AUDIT:-0}"
REQUIRE_BLE_HELLO_SENT="${GOOSE_ANDROID_REQUIRE_BLE_HELLO_SENT:-0}"
REQUIRE_STEP_VALIDATION_AUDIT="${GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_AUDIT:-0}"
REQUIRE_STEP_VALIDATION_PASS="${GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_PASS:-0}"
REQUIRE_STEP_VALIDATION_SESSION="${GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_SESSION:-0}"
REQUIRE_HEALTH_AUDIT="${GOOSE_ANDROID_REQUIRE_HEALTH_AUDIT:-0}"
REQUIRE_HEALTH_WRITE_ATTEMPT="${GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_ATTEMPT:-0}"
REQUIRE_HEALTH_READY_WRITE_PLAN="${GOOSE_ANDROID_REQUIRE_HEALTH_READY_WRITE_PLAN:-0}"
REQUIRE_HEALTH_WRITE_SUCCESS="${GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_SUCCESS:-0}"

usage() {
  cat <<'USAGE'
Usage: Scripts/inspect_android_capture.sh [path/to/goose-phone.sqlite]

Reads a pulled Android debug database and prints a compact capture-readiness
summary. Pair it with:

  Scripts/pull_android_database.sh tmp/goose-phone.sqlite
  Scripts/inspect_android_capture.sh tmp/goose-phone.sqlite

Optional assertions:
  GOOSE_ANDROID_MIN_RAW_EVIDENCE=1
  GOOSE_ANDROID_MIN_DECODED_FRAMES=1
  GOOSE_ANDROID_MIN_CAPTURE_SESSIONS=1
  GOOSE_ANDROID_MIN_SESSION_RAW_EVIDENCE=1
  GOOSE_ANDROID_MIN_SESSION_LIVE_NOTIFICATION_RAW_EVIDENCE=1
  GOOSE_ANDROID_MIN_SESSION_DECODED_FRAMES=1
  GOOSE_ANDROID_MIN_FINISHED_CAPTURE_SESSIONS=1
  GOOSE_ANDROID_REQUIRE_BLE_SESSION_AUDIT=1
  GOOSE_ANDROID_REQUIRE_BLE_HELLO_SENT=1
  GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_AUDIT=1
  GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_PASS=1
  GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_SESSION=1
  GOOSE_ANDROID_REQUIRE_HEALTH_AUDIT=1
  GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_ATTEMPT=1
  GOOSE_ANDROID_REQUIRE_HEALTH_READY_WRITE_PLAN=1
  GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_SUCCESS=1
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "sqlite3 not found. Install sqlite3 or add it to PATH." >&2
  exit 1
fi

file_sha256() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{ print $1 }'
  else
    shasum -a 256 "$file" | awk '{ print $1 }'
  fi
}

file_bytes_or_zero() {
  local file="$1"
  if [[ -f "$file" ]]; then
    wc -c < "$file" | tr -d ' '
  else
    printf '0'
  fi
}

file_sha256_or_missing() {
  local file="$1"
  if [[ -f "$file" ]]; then
    file_sha256 "$file"
  else
    printf 'missing'
  fi
}

audit_files_for() {
  local file="$1"
  [[ -f "$file" ]] && printf '%s\n' "$file"
  [[ -f "$file.old" ]] && printf '%s\n' "$file.old"
}

audit_total_bytes() {
  local total=0
  local file
  for file in "$@"; do
    [[ -f "$file" ]] || continue
    total=$((total + $(file_bytes_or_zero "$file")))
  done
  printf '%s' "$total"
}

audit_rotated_bytes() {
  local file="$1"
  file_bytes_or_zero "$file.old"
}

count_fixed_in_files() {
  local pattern="$1"
  shift
  local total=0
  local file
  local count
  for file in "$@"; do
    [[ -f "$file" ]] || continue
    count="$(grep -F -c "$pattern" "$file" || true)"
    total=$((total + count))
  done
  printf '%s' "$total"
}

count_regex_in_files() {
  local pattern="$1"
  shift
  local total=0
  local file
  local count
  for file in "$@"; do
    [[ -f "$file" ]] || continue
    count="$(grep -E -c "$pattern" "$file" || true)"
    total=$((total + count))
  done
  printf '%s' "$total"
}

if [[ ! -f "$DATABASE" ]]; then
  echo "Android database not found: $DATABASE" >&2
  echo "Pull it first with Scripts/pull_android_database.sh $DATABASE" >&2
  exit 1
fi

sqlite_scalar() {
  local sql="$1"
  sqlite3 -batch "$DATABASE" "$sql"
}

table_exists() {
  local table="$1"
  [[ "$(sqlite_scalar "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '$table';")" == "1" ]]
}

table_count() {
  local table="$1"
  if table_exists "$table"; then
    sqlite_scalar "SELECT COUNT(*) FROM $table;"
  else
    printf 'missing'
  fi
}

column_exists() {
  local table="$1"
  local column="$2"
  table_exists "$table" && [[ "$(sqlite_scalar "SELECT COUNT(*) FROM pragma_table_info('$table') WHERE name = '$column';")" == "1" ]]
}

latest_value() {
  local table="$1"
  local column="$2"
  if column_exists "$table" "$column"; then
    sqlite_scalar "SELECT COALESCE(MAX($column), '') FROM $table;"
  fi
}

table_scalar_or_missing() {
  local table="$1"
  local sql="$2"
  if table_exists "$table"; then
    sqlite_scalar "$sql"
  else
    printf 'missing'
  fi
}

raw_count="$(table_count raw_evidence)"
decoded_count="$(table_count decoded_frames)"
session_count="$(table_count capture_sessions)"
session_raw_count="$(table_scalar_or_missing raw_evidence "SELECT COUNT(*) FROM raw_evidence WHERE COALESCE(capture_session_id, '') != '';")"
session_live_notification_raw_count="$(table_scalar_or_missing raw_evidence "SELECT COUNT(*) FROM raw_evidence WHERE COALESCE(capture_session_id, '') != '' AND source LIKE 'goose-android/live-notification/%';")"
session_decoded_count="missing"
if table_exists raw_evidence && table_exists decoded_frames && column_exists raw_evidence capture_session_id && column_exists decoded_frames evidence_id; then
  session_decoded_count="$(sqlite_scalar "SELECT COUNT(decoded_frames.frame_id) FROM decoded_frames INNER JOIN raw_evidence ON raw_evidence.evidence_id = decoded_frames.evidence_id WHERE COALESCE(raw_evidence.capture_session_id, '') != '';")"
fi
finished_session_count="$(table_scalar_or_missing capture_sessions "SELECT COUNT(*) FROM capture_sessions WHERE status = 'finished' AND frame_count > 0;")"
step_count="$(table_count step_counter_samples)"
activity_metric_count="$(table_count daily_activity_metrics)"
activity_metric_local_estimate_count="missing"
activity_metric_device_counter_count="missing"
if table_exists daily_activity_metrics && column_exists daily_activity_metrics source_kind; then
  activity_metric_local_estimate_count="$(sqlite_scalar "SELECT COUNT(*) FROM daily_activity_metrics WHERE source_kind = 'local_estimate';")"
  activity_metric_device_counter_count="$(sqlite_scalar "SELECT COUNT(*) FROM daily_activity_metrics WHERE source_kind = 'device_counter';")"
fi
health_audit_files=()
while IFS= read -r audit_file; do
  health_audit_files+=("$audit_file")
done < <(audit_files_for "$HEALTH_AUDIT_LOG")
ble_session_files=()
while IFS= read -r audit_file; do
  ble_session_files+=("$audit_file")
done < <(audit_files_for "$BLE_SESSION_LOG")
step_validation_files=()
while IFS= read -r audit_file; do
  step_validation_files+=("$audit_file")
done < <(audit_files_for "$STEP_VALIDATION_LOG")
health_audit_bytes=0
health_audit_rotated_bytes=0
health_audit_blocked=0
health_audit_write_started=0
health_audit_ready_write_started=0
health_audit_planned_write_started=0
health_audit_candidate_write_started=0
health_audit_records_attempted=0
health_audit_record_summary_write_started=0
health_audit_steps_record_started=0
health_audit_local_estimate_record_started=0
health_audit_device_counter_record_started=0
health_audit_write_succeeded=0
health_audit_ready_write_succeeded=0
health_audit_planned_write_succeeded=0
health_audit_records_inserted=0
health_audit_write_failed=0
ble_session_bytes=0
ble_session_rotated_bytes=0
ble_session_ready=0
ble_session_hello_sent=0
ble_session_client_hello_completed=0
ble_session_client_hello_command_ready_completed=0
ble_session_command_ready=0
ble_session_ready_hello_command_ready=0
step_validation_bytes=0
step_validation_rotated_bytes=0
step_validation_completed=0
step_validation_passed=0
step_validation_failed=0
step_validation_session_bound=0
step_validation_session_decoded=0
step_validation_selected_delta=0
step_validation_passing_session_selected_delta=0
if [[ "${#health_audit_files[@]}" -gt 0 ]]; then
  health_audit_bytes="$(audit_total_bytes "${health_audit_files[@]}")"
  health_audit_rotated_bytes="$(audit_rotated_bytes "$HEALTH_AUDIT_LOG")"
  health_audit_blocked="$(count_fixed_in_files '"event":"blocked"' "${health_audit_files[@]}")"
  health_audit_write_started="$(count_fixed_in_files '"event":"write_started"' "${health_audit_files[@]}")"
  health_audit_ready_write_started="$(count_regex_in_files '"event":"write_started".*"permissions_ready":true' "${health_audit_files[@]}")"
  health_audit_planned_write_started="$(count_regex_in_files '"event":"write_started".*"planned_write_count":[1-9][0-9]*' "${health_audit_files[@]}")"
  health_audit_candidate_write_started="$(count_regex_in_files '"event":"write_started".*"candidate_count":[1-9][0-9]*' "${health_audit_files[@]}")"
  health_audit_records_attempted="$(count_regex_in_files '"event":"write_started".*"records_attempted":[1-9][0-9]*' "${health_audit_files[@]}")"
  health_audit_record_summary_write_started="$(count_regex_in_files '"event":"write_started".*"record_summary":\{' "${health_audit_files[@]}")"
  health_audit_steps_record_started="$(count_regex_in_files '"event":"write_started".*"record_summary":\{[^}]*"StepsRecord":[1-9][0-9]*' "${health_audit_files[@]}")"
  health_audit_local_estimate_record_started="$(count_regex_in_files '"event":"write_started".*"record_summary":\{[^}]*"local_estimate":[1-9][0-9]*' "${health_audit_files[@]}")"
  health_audit_device_counter_record_started="$(count_regex_in_files '"event":"write_started".*"record_summary":\{[^}]*"device_counter":[1-9][0-9]*' "${health_audit_files[@]}")"
  health_audit_write_succeeded="$(count_fixed_in_files '"event":"write_succeeded"' "${health_audit_files[@]}")"
  health_audit_ready_write_succeeded="$(count_regex_in_files '"event":"write_succeeded".*"permissions_ready":true' "${health_audit_files[@]}")"
  health_audit_planned_write_succeeded="$(count_regex_in_files '"event":"write_succeeded".*"planned_write_count":[1-9][0-9]*' "${health_audit_files[@]}")"
  health_audit_records_inserted="$(count_regex_in_files '"event":"write_succeeded".*"records_inserted":[1-9][0-9]*' "${health_audit_files[@]}")"
  health_audit_write_failed="$(count_fixed_in_files '"event":"write_failed"' "${health_audit_files[@]}")"
fi
if [[ "${#ble_session_files[@]}" -gt 0 ]]; then
  ble_session_bytes="$(audit_total_bytes "${ble_session_files[@]}")"
  ble_session_rotated_bytes="$(audit_rotated_bytes "$BLE_SESSION_LOG")"
  ble_session_ready="$(count_fixed_in_files '"phase":"ready"' "${ble_session_files[@]}")"
  ble_session_hello_sent="$(count_fixed_in_files '"hello_sent":true' "${ble_session_files[@]}")"
  ble_session_client_hello_completed="$(count_regex_in_files '"phase":"operation_complete".*"active_operation_label":"client hello".*"hello_sent":true' "${ble_session_files[@]}")"
  ble_session_client_hello_command_ready_completed="$(count_regex_in_files '"phase":"operation_complete".*"active_operation_label":"client hello".*"command_ready":true.*"hello_sent":true' "${ble_session_files[@]}")"
  ble_session_command_ready="$(count_fixed_in_files '"command_ready":true' "${ble_session_files[@]}")"
  ble_session_ready_hello_command_ready="$(count_regex_in_files '"phase":"ready".*"command_ready":true.*"hello_sent":true' "${ble_session_files[@]}")"
fi
if [[ "${#step_validation_files[@]}" -gt 0 ]]; then
  step_validation_bytes="$(audit_total_bytes "${step_validation_files[@]}")"
  step_validation_rotated_bytes="$(audit_rotated_bytes "$STEP_VALIDATION_LOG")"
  step_validation_completed="$(count_fixed_in_files '"event":"completed"' "${step_validation_files[@]}")"
  step_validation_passed="$(count_fixed_in_files '"pass":true' "${step_validation_files[@]}")"
  step_validation_failed="$(count_fixed_in_files '"event":"failed"' "${step_validation_files[@]}")"
  step_validation_session_bound="$(count_regex_in_files '"capture_session_id":"[^"]+"' "${step_validation_files[@]}")"
  step_validation_session_decoded="$(count_regex_in_files '"capture_session_decoded_frame_count":[1-9][0-9]*' "${step_validation_files[@]}")"
  step_validation_selected_delta="$(count_regex_in_files '"selected_delta":-?[0-9]+' "${step_validation_files[@]}")"
  step_validation_passing_session_selected_delta="$(count_regex_in_files '"event":"completed".*"pass":true.*"capture_session_id":"[^"]+".*"capture_session_decoded_frame_count":[1-9][0-9]*.*"selected_delta":-?[1-9][0-9]*' "${step_validation_files[@]}")"
fi

echo "Android capture inspection"
echo "database: $DATABASE"
echo "database bytes: $(file_bytes_or_zero "$DATABASE")"
echo "database sha256: $(file_sha256_or_missing "$DATABASE")"
echo "database wal bytes: $(file_bytes_or_zero "$DATABASE-wal")"
echo "database wal sha256: $(file_sha256_or_missing "$DATABASE-wal")"
echo "database shm bytes: $(file_bytes_or_zero "$DATABASE-shm")"
echo "database shm sha256: $(file_sha256_or_missing "$DATABASE-shm")"
echo "raw evidence: $raw_count"
echo "decoded frames: $decoded_count"
echo "capture sessions: $session_count"
echo "session raw evidence: $session_raw_count"
echo "session live notification raw evidence: $session_live_notification_raw_count"
echo "session decoded frames: $session_decoded_count"
echo "finished nonempty capture sessions: $finished_session_count"
echo "step samples: $step_count"
echo "daily activity metrics: $activity_metric_count"
echo "daily local estimate metrics: $activity_metric_local_estimate_count"
echo "daily device counter metrics: $activity_metric_device_counter_count"
echo "latest raw capture: $(latest_value raw_evidence captured_at)"
echo "health sync audit: $HEALTH_AUDIT_LOG"
echo "health sync audit bytes: $health_audit_bytes"
echo "health sync audit rotated bytes: $health_audit_rotated_bytes"
echo "health sync blocked events: $health_audit_blocked"
echo "health sync write started events: $health_audit_write_started"
echo "health sync ready write started events: $health_audit_ready_write_started"
echo "health sync planned write started events: $health_audit_planned_write_started"
echo "health sync candidate write started events: $health_audit_candidate_write_started"
echo "health sync records attempted events: $health_audit_records_attempted"
echo "health sync record-summary write started events: $health_audit_record_summary_write_started"
echo "health sync steps record started events: $health_audit_steps_record_started"
echo "health sync local estimate record started events: $health_audit_local_estimate_record_started"
echo "health sync device counter record started events: $health_audit_device_counter_record_started"
echo "health sync write succeeded events: $health_audit_write_succeeded"
echo "health sync ready write succeeded events: $health_audit_ready_write_succeeded"
echo "health sync planned write succeeded events: $health_audit_planned_write_succeeded"
echo "health sync records inserted events: $health_audit_records_inserted"
echo "health sync write failed events: $health_audit_write_failed"
echo "ble session audit: $BLE_SESSION_LOG"
echo "ble session audit bytes: $ble_session_bytes"
echo "ble session audit rotated bytes: $ble_session_rotated_bytes"
echo "ble session ready events: $ble_session_ready"
echo "ble session hello sent events: $ble_session_hello_sent"
echo "ble session client hello completed events: $ble_session_client_hello_completed"
echo "ble session client hello command-ready completed events: $ble_session_client_hello_command_ready_completed"
echo "ble session command ready events: $ble_session_command_ready"
echo "ble session ready hello command-ready events: $ble_session_ready_hello_command_ready"
echo "step validation audit: $STEP_VALIDATION_LOG"
echo "step validation audit bytes: $step_validation_bytes"
echo "step validation audit rotated bytes: $step_validation_rotated_bytes"
echo "step validation completed events: $step_validation_completed"
echo "step validation passed events: $step_validation_passed"
echo "step validation failed events: $step_validation_failed"
echo "step validation session-bound events: $step_validation_session_bound"
echo "step validation session decoded events: $step_validation_session_decoded"
echo "step validation selected delta events: $step_validation_selected_delta"
echo "step validation passing session selected-delta events: $step_validation_passing_session_selected_delta"

if table_exists raw_evidence; then
  echo
  echo "Recent raw evidence"
  sqlite3 -header -column -batch "$DATABASE" "
    SELECT captured_at, substr(source, 1, 48) AS source, length(payload_hex) AS payload_hex_chars
    FROM raw_evidence
    ORDER BY captured_at DESC
    LIMIT 8;
  "

  echo
  echo "Raw source mix"
  sqlite3 -header -column -batch "$DATABASE" "
    SELECT substr(source, 1, 72) AS source, COUNT(*) AS rows
    FROM raw_evidence
    GROUP BY source
    ORDER BY rows DESC, source
    LIMIT 12;
  "
fi

if table_exists capture_sessions; then
  echo
  echo "Recent capture sessions"
  if column_exists capture_sessions started_at_unix_ms; then
    sqlite3 -header -column -batch "$DATABASE" "
      SELECT session_id, status, frame_count, started_at_unix_ms, ended_at_unix_ms
      FROM capture_sessions
      ORDER BY started_at_unix_ms DESC
      LIMIT 8;
    "
  else
    sqlite3 -header -column -batch "$DATABASE" "
      SELECT *
      FROM capture_sessions
      LIMIT 8;
    "
  fi

  if table_exists raw_evidence && column_exists raw_evidence capture_session_id; then
    echo
    echo "Capture session evidence detail"
    step_join=""
    step_columns="0 AS step_samples"
    if table_exists step_counter_samples && column_exists step_counter_samples capture_session_id; then
      step_join="
      LEFT JOIN (
        SELECT capture_session_id, COUNT(*) AS step_samples
        FROM step_counter_samples
        WHERE COALESCE(capture_session_id, '') != ''
        GROUP BY capture_session_id
      ) AS steps ON steps.capture_session_id = sessions.session_id"
      step_columns="COALESCE(steps.step_samples, 0) AS step_samples"
    fi
    decoded_join=""
    decoded_columns="0 AS decoded_frames"
    if table_exists decoded_frames && column_exists decoded_frames evidence_id; then
      decoded_join="
      LEFT JOIN (
        SELECT raw_evidence.capture_session_id, COUNT(decoded_frames.frame_id) AS decoded_frames
        FROM decoded_frames
        INNER JOIN raw_evidence ON raw_evidence.evidence_id = decoded_frames.evidence_id
        WHERE COALESCE(raw_evidence.capture_session_id, '') != ''
        GROUP BY raw_evidence.capture_session_id
      ) AS decoded ON decoded.capture_session_id = sessions.session_id"
      decoded_columns="COALESCE(decoded.decoded_frames, 0) AS decoded_frames"
    fi
    sqlite3 -header -column -batch "$DATABASE" "
      SELECT
        sessions.session_id,
        sessions.status,
        sessions.frame_count,
        COALESCE(raw.raw_rows, 0) AS raw_rows,
        COALESCE(raw.live_notification_rows, 0) AS live_notification_rows,
        $decoded_columns,
        $step_columns
      FROM capture_sessions AS sessions
      LEFT JOIN (
        SELECT
          capture_session_id,
          COUNT(*) AS raw_rows,
          SUM(CASE WHEN source LIKE 'goose-android/live-notification/%' THEN 1 ELSE 0 END) AS live_notification_rows
        FROM raw_evidence
        WHERE COALESCE(capture_session_id, '') != ''
        GROUP BY capture_session_id
      ) AS raw ON raw.capture_session_id = sessions.session_id
      $decoded_join
      $step_join
      ORDER BY sessions.started_at_unix_ms DESC
      LIMIT 8;
    "
  fi
fi

if table_exists step_counter_samples; then
  echo
  echo "Recent step samples"
  if column_exists step_counter_samples source_kind; then
    sqlite3 -header -column -batch "$DATABASE" "
      SELECT sample_time_unix_ms, counter_value, cadence_spm, source_kind
      FROM step_counter_samples
      ORDER BY sample_time_unix_ms DESC
      LIMIT 8;
    "
  else
    sqlite3 -header -column -batch "$DATABASE" "
      SELECT sample_time_unix_ms, counter_value, cadence_spm
      FROM step_counter_samples
      ORDER BY sample_time_unix_ms DESC
      LIMIT 8;
    "
  fi
fi

if table_exists daily_activity_metrics; then
  echo
  echo "Recent daily activity metrics"
  if column_exists daily_activity_metrics source_kind; then
    sqlite3 -header -column -batch "$DATABASE" "
      SELECT date_key, steps, active_kcal, average_cadence_spm, source_kind
      FROM daily_activity_metrics
      ORDER BY start_time_unix_ms DESC
      LIMIT 8;
    "
  else
    sqlite3 -header -column -batch "$DATABASE" "
      SELECT date_key, steps, active_kcal, average_cadence_spm
      FROM daily_activity_metrics
      ORDER BY start_time_unix_ms DESC
      LIMIT 8;
    "
  fi
fi

if [[ "${#health_audit_files[@]}" -gt 0 ]]; then
  echo
  echo "Recent Health Connect audit rows"
  tail -n 5 "${health_audit_files[@]}"
fi

if [[ "${#ble_session_files[@]}" -gt 0 ]]; then
  echo
  echo "Recent BLE session audit rows"
  tail -n 8 "${ble_session_files[@]}"
fi

if [[ "${#step_validation_files[@]}" -gt 0 ]]; then
  echo
  echo "Recent step validation audit rows"
  tail -n 5 "${step_validation_files[@]}"
fi

failures=0
if [[ "$raw_count" != "missing" && "$raw_count" -lt "$MIN_RAW_EVIDENCE" ]]; then
  echo "FAIL: raw_evidence rows $raw_count < required $MIN_RAW_EVIDENCE" >&2
  failures=$((failures + 1))
elif [[ "$raw_count" == "missing" && "$MIN_RAW_EVIDENCE" -gt 0 ]]; then
  echo "FAIL: raw_evidence table missing" >&2
  failures=$((failures + 1))
fi

if [[ "$decoded_count" != "missing" && "$decoded_count" -lt "$MIN_DECODED_FRAMES" ]]; then
  echo "FAIL: decoded_frames rows $decoded_count < required $MIN_DECODED_FRAMES" >&2
  failures=$((failures + 1))
elif [[ "$decoded_count" == "missing" && "$MIN_DECODED_FRAMES" -gt 0 ]]; then
  echo "FAIL: decoded_frames table missing" >&2
  failures=$((failures + 1))
fi

if [[ "$session_count" != "missing" && "$session_count" -lt "$MIN_CAPTURE_SESSIONS" ]]; then
  echo "FAIL: capture_sessions rows $session_count < required $MIN_CAPTURE_SESSIONS" >&2
  failures=$((failures + 1))
elif [[ "$session_count" == "missing" && "$MIN_CAPTURE_SESSIONS" -gt 0 ]]; then
  echo "FAIL: capture_sessions table missing" >&2
  failures=$((failures + 1))
fi

if [[ "$session_raw_count" != "missing" && "$session_raw_count" -lt "$MIN_SESSION_RAW_EVIDENCE" ]]; then
  echo "FAIL: session-tagged raw_evidence rows $session_raw_count < required $MIN_SESSION_RAW_EVIDENCE" >&2
  failures=$((failures + 1))
elif [[ "$session_raw_count" == "missing" && "$MIN_SESSION_RAW_EVIDENCE" -gt 0 ]]; then
  echo "FAIL: raw_evidence table missing" >&2
  failures=$((failures + 1))
fi

if [[ "$session_live_notification_raw_count" != "missing" && "$session_live_notification_raw_count" -lt "$MIN_SESSION_LIVE_NOTIFICATION_RAW_EVIDENCE" ]]; then
  echo "FAIL: session-tagged Android BLE live notification raw_evidence rows $session_live_notification_raw_count < required $MIN_SESSION_LIVE_NOTIFICATION_RAW_EVIDENCE" >&2
  failures=$((failures + 1))
elif [[ "$session_live_notification_raw_count" == "missing" && "$MIN_SESSION_LIVE_NOTIFICATION_RAW_EVIDENCE" -gt 0 ]]; then
  echo "FAIL: raw_evidence table missing" >&2
  failures=$((failures + 1))
fi

if [[ "$session_decoded_count" != "missing" && "$session_decoded_count" -lt "$MIN_SESSION_DECODED_FRAMES" ]]; then
  echo "FAIL: session-tagged decoded_frames rows $session_decoded_count < required $MIN_SESSION_DECODED_FRAMES" >&2
  failures=$((failures + 1))
elif [[ "$session_decoded_count" == "missing" && "$MIN_SESSION_DECODED_FRAMES" -gt 0 ]]; then
  echo "FAIL: session-tagged decoded_frames unavailable" >&2
  failures=$((failures + 1))
fi

if [[ "$finished_session_count" != "missing" && "$finished_session_count" -lt "$MIN_FINISHED_CAPTURE_SESSIONS" ]]; then
  echo "FAIL: finished nonempty capture_sessions rows $finished_session_count < required $MIN_FINISHED_CAPTURE_SESSIONS" >&2
  failures=$((failures + 1))
elif [[ "$finished_session_count" == "missing" && "$MIN_FINISHED_CAPTURE_SESSIONS" -gt 0 ]]; then
  echo "FAIL: capture_sessions table missing" >&2
  failures=$((failures + 1))
fi

if [[ "$REQUIRE_STEP_VALIDATION_AUDIT" == "1" && "$step_validation_completed" -le 0 ]]; then
  echo "FAIL: step validation audit has no completed event" >&2
  failures=$((failures + 1))
fi

if [[ "$REQUIRE_BLE_SESSION_AUDIT" == "1" && "$ble_session_bytes" -le 0 ]]; then
  echo "FAIL: BLE session audit log missing or empty" >&2
  failures=$((failures + 1))
fi

if [[ "$REQUIRE_BLE_HELLO_SENT" == "1" && "$ble_session_hello_sent" -le 0 ]]; then
  echo "FAIL: BLE session audit has no hello_sent=true event" >&2
  failures=$((failures + 1))
fi

if [[ "$REQUIRE_BLE_HELLO_SENT" == "1" && "$ble_session_client_hello_completed" -le 0 ]]; then
  echo "FAIL: BLE session audit has no completed client hello write event" >&2
  failures=$((failures + 1))
fi

if [[ "$REQUIRE_BLE_HELLO_SENT" == "1" && "$ble_session_client_hello_command_ready_completed" -le 0 ]]; then
  echo "FAIL: BLE session audit has no completed client hello write event with command_ready=true in the same row" >&2
  failures=$((failures + 1))
fi

if [[ "$REQUIRE_BLE_HELLO_SENT" == "1" && "$ble_session_command_ready" -le 0 ]]; then
  echo "FAIL: BLE session audit has no command_ready=true event" >&2
  failures=$((failures + 1))
fi

if [[ "$REQUIRE_BLE_HELLO_SENT" == "1" && "$ble_session_ready" -le 0 ]]; then
  echo "FAIL: BLE session audit has no ready phase event" >&2
  failures=$((failures + 1))
fi

if [[ "$REQUIRE_BLE_HELLO_SENT" == "1" && "$ble_session_ready_hello_command_ready" -le 0 ]]; then
  echo "FAIL: BLE session audit has no ready phase event with command_ready=true and hello_sent=true in the same row" >&2
  failures=$((failures + 1))
fi

if [[ "$REQUIRE_STEP_VALIDATION_PASS" == "1" && "$step_validation_passed" -le 0 ]]; then
  echo "FAIL: step validation audit has no passing event" >&2
  failures=$((failures + 1))
fi

if [[ "$REQUIRE_STEP_VALIDATION_SESSION" == "1" && "$step_validation_session_bound" -le 0 ]]; then
  echo "FAIL: step validation audit has no capture_session_id" >&2
  failures=$((failures + 1))
fi

if [[ "$REQUIRE_STEP_VALIDATION_SESSION" == "1" && "$step_validation_session_decoded" -le 0 ]]; then
  echo "FAIL: step validation audit has no session decoded frames" >&2
  failures=$((failures + 1))
fi

if [[ "$REQUIRE_STEP_VALIDATION_SESSION" == "1" && "$step_validation_selected_delta" -le 0 ]]; then
  echo "FAIL: step validation audit has no selected counter delta" >&2
  failures=$((failures + 1))
fi

if [[ "$REQUIRE_STEP_VALIDATION_SESSION" == "1" && "$step_validation_passing_session_selected_delta" -le 0 ]]; then
  echo "FAIL: step validation audit has no passing session row with decoded frames and nonzero selected counter delta" >&2
  failures=$((failures + 1))
fi

if [[ "$REQUIRE_HEALTH_AUDIT" == "1" && "$health_audit_bytes" -le 0 ]]; then
  echo "FAIL: Health Connect audit log missing or empty" >&2
  failures=$((failures + 1))
fi

if [[ "$REQUIRE_HEALTH_WRITE_ATTEMPT" == "1" && "$health_audit_write_started" -le 0 ]]; then
  echo "FAIL: Health Connect audit has no write_started event" >&2
  failures=$((failures + 1))
fi

if [[ "$REQUIRE_HEALTH_READY_WRITE_PLAN" == "1" && "$health_audit_ready_write_started" -le 0 ]]; then
  echo "FAIL: Health Connect write_started audit has no permissions_ready=true context" >&2
  failures=$((failures + 1))
fi

if [[ "$REQUIRE_HEALTH_READY_WRITE_PLAN" == "1" && "$health_audit_planned_write_started" -le 0 ]]; then
  echo "FAIL: Health Connect write_started audit has no planned_write_count > 0" >&2
  failures=$((failures + 1))
fi

if [[ "$REQUIRE_HEALTH_READY_WRITE_PLAN" == "1" && "$health_audit_candidate_write_started" -le 0 ]]; then
  echo "FAIL: Health Connect write_started audit has no candidate_count > 0" >&2
  failures=$((failures + 1))
fi

if [[ "$REQUIRE_HEALTH_READY_WRITE_PLAN" == "1" && "$health_audit_records_attempted" -le 0 ]]; then
  echo "FAIL: Health Connect write_started audit has no records_attempted > 0" >&2
  failures=$((failures + 1))
fi

if [[ "$REQUIRE_HEALTH_READY_WRITE_PLAN" == "1" && "$health_audit_record_summary_write_started" -le 0 ]]; then
  echo "FAIL: Health Connect write_started audit has no record_summary provenance" >&2
  failures=$((failures + 1))
fi

if [[ "$REQUIRE_HEALTH_WRITE_SUCCESS" == "1" && "$health_audit_write_succeeded" -le 0 ]]; then
  echo "FAIL: Health Connect audit has no write_succeeded event" >&2
  failures=$((failures + 1))
fi

if [[ "$REQUIRE_HEALTH_WRITE_SUCCESS" == "1" && "$health_audit_ready_write_succeeded" -le 0 ]]; then
  echo "FAIL: Health Connect write_succeeded audit has no permissions_ready=true context" >&2
  failures=$((failures + 1))
fi

if [[ "$REQUIRE_HEALTH_WRITE_SUCCESS" == "1" && "$health_audit_planned_write_succeeded" -le 0 ]]; then
  echo "FAIL: Health Connect write_succeeded audit has no planned_write_count > 0" >&2
  failures=$((failures + 1))
fi

if [[ "$REQUIRE_HEALTH_WRITE_SUCCESS" == "1" && "$health_audit_records_inserted" -le 0 ]]; then
  echo "FAIL: Health Connect write_succeeded audit has no records_inserted > 0" >&2
  failures=$((failures + 1))
fi

if [[ "$failures" -gt 0 ]]; then
  echo "RESULT: FAIL"
  exit 1
fi

echo
echo "RESULT: PASS"
