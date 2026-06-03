#!/usr/bin/env bash
set -euo pipefail

DATABASE="${1:-tmp/goose-phone.sqlite}"
DATABASE_BASENAME="${DATABASE%.sqlite}"
HEALTH_AUDIT_LOG="${HEALTH_AUDIT_LOG:-$DATABASE_BASENAME-health-connect-sync-log.jsonl}"
MIN_RAW_EVIDENCE="${GOOSE_ANDROID_MIN_RAW_EVIDENCE:-0}"
MIN_CAPTURE_SESSIONS="${GOOSE_ANDROID_MIN_CAPTURE_SESSIONS:-0}"
REQUIRE_HEALTH_AUDIT="${GOOSE_ANDROID_REQUIRE_HEALTH_AUDIT:-0}"
REQUIRE_HEALTH_WRITE_ATTEMPT="${GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_ATTEMPT:-0}"
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
  GOOSE_ANDROID_MIN_CAPTURE_SESSIONS=1
  GOOSE_ANDROID_REQUIRE_HEALTH_AUDIT=1
  GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_ATTEMPT=1
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

raw_count="$(table_count raw_evidence)"
decoded_count="$(table_count decoded_frames)"
session_count="$(table_count capture_sessions)"
step_count="$(table_count step_counter_samples)"
activity_metric_count="$(table_count daily_activity_metrics)"
health_audit_bytes=0
health_audit_blocked=0
health_audit_write_started=0
health_audit_write_succeeded=0
health_audit_write_failed=0
if [[ -f "$HEALTH_AUDIT_LOG" ]]; then
  health_audit_bytes="$(wc -c < "$HEALTH_AUDIT_LOG" | tr -d ' ')"
  health_audit_blocked="$(grep -c '"event":"blocked"' "$HEALTH_AUDIT_LOG" || true)"
  health_audit_write_started="$(grep -c '"event":"write_started"' "$HEALTH_AUDIT_LOG" || true)"
  health_audit_write_succeeded="$(grep -c '"event":"write_succeeded"' "$HEALTH_AUDIT_LOG" || true)"
  health_audit_write_failed="$(grep -c '"event":"write_failed"' "$HEALTH_AUDIT_LOG" || true)"
fi

echo "Android capture inspection"
echo "database: $DATABASE"
echo "database bytes: $(wc -c < "$DATABASE" | tr -d ' ')"
echo "raw evidence: $raw_count"
echo "decoded frames: $decoded_count"
echo "capture sessions: $session_count"
echo "step samples: $step_count"
echo "daily activity metrics: $activity_metric_count"
echo "latest raw capture: $(latest_value raw_evidence captured_at)"
echo "health sync audit: $HEALTH_AUDIT_LOG"
echo "health sync audit bytes: $health_audit_bytes"
echo "health sync blocked events: $health_audit_blocked"
echo "health sync write started events: $health_audit_write_started"
echo "health sync write succeeded events: $health_audit_write_succeeded"
echo "health sync write failed events: $health_audit_write_failed"

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

if [[ -f "$HEALTH_AUDIT_LOG" ]]; then
  echo
  echo "Recent Health Connect audit rows"
  tail -n 5 "$HEALTH_AUDIT_LOG"
fi

failures=0
if [[ "$raw_count" != "missing" && "$raw_count" -lt "$MIN_RAW_EVIDENCE" ]]; then
  echo "FAIL: raw_evidence rows $raw_count < required $MIN_RAW_EVIDENCE" >&2
  failures=$((failures + 1))
elif [[ "$raw_count" == "missing" && "$MIN_RAW_EVIDENCE" -gt 0 ]]; then
  echo "FAIL: raw_evidence table missing" >&2
  failures=$((failures + 1))
fi

if [[ "$session_count" != "missing" && "$session_count" -lt "$MIN_CAPTURE_SESSIONS" ]]; then
  echo "FAIL: capture_sessions rows $session_count < required $MIN_CAPTURE_SESSIONS" >&2
  failures=$((failures + 1))
elif [[ "$session_count" == "missing" && "$MIN_CAPTURE_SESSIONS" -gt 0 ]]; then
  echo "FAIL: capture_sessions table missing" >&2
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

if [[ "$REQUIRE_HEALTH_WRITE_SUCCESS" == "1" && "$health_audit_write_succeeded" -le 0 ]]; then
  echo "FAIL: Health Connect audit has no write_succeeded event" >&2
  failures=$((failures + 1))
fi

if [[ "$failures" -gt 0 ]]; then
  echo "RESULT: FAIL"
  exit 1
fi

echo
echo "RESULT: PASS"
