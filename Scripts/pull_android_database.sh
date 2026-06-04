#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${ADB:-}" && -x "$HOME/Library/Android/sdk/platform-tools/adb" ]]; then
  ADB="$HOME/Library/Android/sdk/platform-tools/adb"
fi
ADB="${ADB:-adb}"
GOOSE_ANDROID_ADB_COMMAND_TIMEOUT_SECONDS="${GOOSE_ANDROID_ADB_COMMAND_TIMEOUT_SECONDS:-60}"

PACKAGE="${PACKAGE:-com.goose.android}"
REMOTE_DIR="${REMOTE_DIR:-files/goose}"
OUTPUT="${1:-tmp/goose-phone.sqlite}"
OUTPUT_BASENAME="${OUTPUT%.sqlite}"

run_to_file_with_timeout() {
  local label="$1"
  local timeout_seconds="$2"
  local output_file="$3"
  shift 3
  local pid
  local elapsed=0
  local status=0

  "$@" > "$output_file" &
  pid="$!"
  while kill -0 "$pid" 2>/dev/null; do
    if [[ "$elapsed" -ge "$timeout_seconds" ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      echo "$label timed out after ${timeout_seconds}s" >&2
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  set +e
  wait "$pid"
  status="$?"
  set -e
  return "$status"
}

run_with_timeout() {
  local label="$1"
  local timeout_seconds="$2"
  shift 2
  local output_file
  local pid
  local elapsed=0
  local status=0
  output_file="$(mktemp "${TMPDIR:-/tmp}/goose-android-pull-command.XXXXXX")"

  "$@" > "$output_file" 2>&1 &
  pid="$!"
  while kill -0 "$pid" 2>/dev/null; do
    if [[ "$elapsed" -ge "$timeout_seconds" ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      cat "$output_file"
      rm -f "$output_file"
      echo "$label timed out after ${timeout_seconds}s" >&2
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  set +e
  wait "$pid"
  status="$?"
  set -e
  cat "$output_file"
  rm -f "$output_file"
  return "$status"
}

if ! command -v "$ADB" >/dev/null 2>&1; then
  echo "adb not found. Set ADB or add Android platform-tools to PATH." >&2
  exit 1
fi

device_serial="${ANDROID_SERIAL:-}"
if [[ -z "$device_serial" ]]; then
  devices=()
  adb_devices_output="$(run_with_timeout \
    "Android adb devices" \
    "$GOOSE_ANDROID_ADB_COMMAND_TIMEOUT_SECONDS" \
    "$ADB" devices)"
  while IFS= read -r serial; do
    devices+=("$serial")
  done < <(printf '%s\n' "$adb_devices_output" | awk 'NR > 1 && $2 == "device" { print $1 }')
  if [[ "${#devices[@]}" -eq 1 ]]; then
    device_serial="${devices[0]}"
  elif [[ "${#devices[@]}" -eq 0 ]]; then
    echo "No adb device/emulator online. Enable USB debugging and accept the phone trust prompt." >&2
    exit 1
  else
    echo "Multiple adb devices are online. Set ANDROID_SERIAL to one of:" >&2
    printf '  %s\n' "${devices[@]}" >&2
    exit 1
  fi
fi

device_state="$(run_with_timeout \
  "Android adb state" \
  "$GOOSE_ANDROID_ADB_COMMAND_TIMEOUT_SECONDS" \
  "$ADB" -s "$device_serial" get-state 2>/dev/null || true)"
if [[ "$device_state" != "device" ]]; then
  echo "adb target is not online: $device_serial ($device_state)" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"

pull_file() {
  local remote_path="$1"
  local output_path="$2"
  local required="$3"
  local tmp_path="${output_path}.tmp"

  rm -f "$tmp_path"
  if run_to_file_with_timeout \
    "adb pull $remote_path" \
    "$GOOSE_ANDROID_ADB_COMMAND_TIMEOUT_SECONDS" \
    "$tmp_path" \
    "$ADB" -s "$device_serial" exec-out run-as "$PACKAGE" sh -c "cat '$remote_path'"; then
    mv "$tmp_path" "$output_path"
    echo "Pulled $remote_path -> $output_path"
    return
  fi

  rm -f "$tmp_path"
  if [[ "$required" == "1" ]]; then
    echo "Could not pull $remote_path from $PACKAGE on $device_serial." >&2
    echo "Install a debug build first; run-as is not available for release APKs." >&2
    exit 1
  fi
  rm -f "$output_path"
}

pull_file "$REMOTE_DIR/goose.sqlite" "$OUTPUT" 1
pull_file "$REMOTE_DIR/goose.sqlite-wal" "$OUTPUT-wal" 0
pull_file "$REMOTE_DIR/goose.sqlite-shm" "$OUTPUT-shm" 0
pull_file "$REMOTE_DIR/health-connect-sync-log.jsonl" "$OUTPUT_BASENAME-health-connect-sync-log.jsonl" 0
pull_file "$REMOTE_DIR/health-connect-sync-log.jsonl.old" "$OUTPUT_BASENAME-health-connect-sync-log.jsonl.old" 0
pull_file "$REMOTE_DIR/step-validation-log.jsonl" "$OUTPUT_BASENAME-step-validation-log.jsonl" 0
pull_file "$REMOTE_DIR/step-validation-log.jsonl.old" "$OUTPUT_BASENAME-step-validation-log.jsonl.old" 0
pull_file "$REMOTE_DIR/ble-session-log.jsonl" "$OUTPUT_BASENAME-ble-session-log.jsonl" 0
pull_file "$REMOTE_DIR/ble-session-log.jsonl.old" "$OUTPUT_BASENAME-ble-session-log.jsonl.old" 0

echo "Android Goose database pull complete from $device_serial."
