#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${ADB:-}" && -x "$HOME/Library/Android/sdk/platform-tools/adb" ]]; then
  ADB="$HOME/Library/Android/sdk/platform-tools/adb"
fi
ADB="${ADB:-adb}"

PACKAGE="${PACKAGE:-com.goose.android}"
REMOTE_DIR="${REMOTE_DIR:-files/goose}"
OUTPUT="${1:-tmp/goose-phone.sqlite}"
OUTPUT_BASENAME="${OUTPUT%.sqlite}"

if ! command -v "$ADB" >/dev/null 2>&1; then
  echo "adb not found. Set ADB or add Android platform-tools to PATH." >&2
  exit 1
fi

device_serial="${ANDROID_SERIAL:-}"
if [[ -z "$device_serial" ]]; then
  device_serial="$("$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')"
fi

if [[ -z "$device_serial" ]]; then
  echo "No adb device/emulator online. Set ANDROID_SERIAL when multiple devices are connected." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"

pull_file() {
  local remote_path="$1"
  local output_path="$2"
  local required="$3"
  local tmp_path="${output_path}.tmp"

  rm -f "$tmp_path"
  if "$ADB" -s "$device_serial" exec-out run-as "$PACKAGE" sh -c "cat '$remote_path'" > "$tmp_path"; then
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
}

pull_file "$REMOTE_DIR/goose.sqlite" "$OUTPUT" 1
pull_file "$REMOTE_DIR/goose.sqlite-wal" "$OUTPUT-wal" 0
pull_file "$REMOTE_DIR/goose.sqlite-shm" "$OUTPUT-shm" 0
pull_file "$REMOTE_DIR/health-connect-sync-log.jsonl" "$OUTPUT_BASENAME-health-connect-sync-log.jsonl" 0
pull_file "$REMOTE_DIR/health-connect-sync-log.jsonl.old" "$OUTPUT_BASENAME-health-connect-sync-log.jsonl.old" 0

echo "Android Goose database pull complete from $device_serial."
