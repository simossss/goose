#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE="${PACKAGE:-com.goose.android}"
MARKER_FILE="${GOOSE_ANDROID_LOGCAT_MARKER_FILE:-/sdcard/goose-evidence-start-marker.txt}"

if [[ -z "${ADB:-}" && -x "$HOME/Library/Android/sdk/platform-tools/adb" ]]; then
  ADB="$HOME/Library/Android/sdk/platform-tools/adb"
fi
ADB="${ADB:-adb}"
GOOSE_ANDROID_ADB_COMMAND_TIMEOUT_SECONDS="${GOOSE_ANDROID_ADB_COMMAND_TIMEOUT_SECONDS:-60}"

run_with_timeout() {
  local label="$1"
  local timeout_seconds="$2"
  shift 2
  local output_file
  local pid
  local elapsed=0
  local status=0
  output_file="$(mktemp "${TMPDIR:-/tmp}/goose-android-prepare-command.XXXXXX")"

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

usage() {
  cat <<'USAGE'
Usage: Scripts/prepare_android_phone_evidence.sh

Prepares a connected Android phone for a scoped Goose evidence run:
- selects exactly one adb device, unless ANDROID_SERIAL is set
- clears logcat
- writes a unique Goose evidence start marker to logcat and /sdcard

Run this immediately before the controlled WHOOP capture. The final phone gate
requires the marker so AndroidRuntime crash evidence is scoped to this run.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

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
    echo "No adb device online. Enable USB debugging and accept the phone trust prompt." >&2
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

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
marker="goose-evidence-start $stamp $PACKAGE $device_serial"

echo "==> Clearing logcat on $device_serial"
run_with_timeout \
  "Android logcat clear" \
  "$GOOSE_ANDROID_ADB_COMMAND_TIMEOUT_SECONDS" \
  "$ADB" -s "$device_serial" logcat -c
printf '%s\n' "$marker" | run_with_timeout \
  "Android evidence marker file write" \
  "$GOOSE_ANDROID_ADB_COMMAND_TIMEOUT_SECONDS" \
  "$ADB" -s "$device_serial" shell "cat > '$MARKER_FILE'"
run_with_timeout \
  "Android evidence marker log write" \
  "$GOOSE_ANDROID_ADB_COMMAND_TIMEOUT_SECONDS" \
  "$ADB" -s "$device_serial" shell log -t GooseEvidenceStart "$marker"

cat <<NEXT_STEPS
==> Goose evidence start marker written
Device: $device_serial
Marker: $marker
Marker file: $MARKER_FILE

Now run the controlled WHOOP capture and then collect evidence with:
  Scripts/android_final_pr_gate.sh tmp/android-phone-final-gate-real --skip-validate

The final gate requires the latest pulled raw capture timestamp to be at or
after this marker. If counted-step validation is parked, collect the partial
phone bundle instead:
  Scripts/android_partial_phone_gate.sh tmp/android-phone-partial-gate-real --skip-validate
NEXT_STEPS
