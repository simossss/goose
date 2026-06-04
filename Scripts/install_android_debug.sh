#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ANDROID_DIR="$APP_DIR/GooseAndroid"
APK_PATH="$ANDROID_DIR/app/build/outputs/apk/debug/app-debug.apk"
PACKAGE="${PACKAGE:-com.goose.android}"
ACTIVITY="${ACTIVITY:-.MainActivity}"

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

file_sha256() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{ print $1 }'
  else
    shasum -a 256 "$file" | awk '{ print $1 }'
  fi
}

remote_file_sha256() {
  local remote_path="$1"
  "$ADB" -s "$device_serial" exec-out cat "$remote_path" | shasum -a 256 | awk '{ print $1 }'
}

usage() {
  cat <<'USAGE'
Usage: Scripts/install_android_debug.sh [--no-build]

Builds the Android debug APK unless --no-build or GOOSE_ANDROID_SKIP_BUILD=1 is
set, installs it on an adb device, launches Goose, and checks for immediate
AndroidRuntime crashes. After install, it reads the installed APK back over adb
and verifies its SHA-256 matches the local debug APK.

Set ANDROID_SERIAL when more than one adb device is online.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build)
      GOOSE_ANDROID_SKIP_BUILD=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! command -v "$ADB" >/dev/null 2>&1; then
  echo "adb not found. Set ADB or add Android platform-tools to PATH." >&2
  exit 1
fi

if [[ "${GOOSE_ANDROID_SKIP_BUILD:-0}" != "1" ]]; then
  echo "==> Building Android debug APK"
  (cd "$ANDROID_DIR" && ./gradlew :app:assembleDebug)
fi

if [[ ! -f "$APK_PATH" ]]; then
  echo "Debug APK not found: $APK_PATH" >&2
  echo "Run without --no-build first, or build :app:assembleDebug in Android Studio." >&2
  exit 1
fi

devices=()
while IFS= read -r serial; do
  devices+=("$serial")
done < <("$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1 }')
device_serial="${ANDROID_SERIAL:-}"
if [[ -z "$device_serial" ]]; then
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

device_state="$("$ADB" -s "$device_serial" get-state 2>/dev/null || true)"
if [[ "$device_state" != "device" ]]; then
  echo "adb target is not online: $device_serial ($device_state)" >&2
  exit 1
fi

echo "==> Installing $PACKAGE on $device_serial"
"$ADB" -s "$device_serial" install -r "$APK_PATH"

echo "==> Verifying installed APK hash"
package_path="$("$ADB" -s "$device_serial" shell pm path "$PACKAGE" 2>/dev/null | sed -n '1p' | tr -d '\r')"
if [[ "$package_path" != package:* ]]; then
  echo "Installed package path missing for $PACKAGE: $package_path" >&2
  exit 1
fi
installed_apk_path="${package_path#package:}"
local_apk_sha256="$(file_sha256 "$APK_PATH")"
if ! installed_apk_sha256="$(remote_file_sha256 "$installed_apk_path" 2>/dev/null)"; then
  echo "Unable to read installed APK for hash verification: $installed_apk_path" >&2
  exit 1
fi
echo "Local debug APK sha256: $local_apk_sha256"
echo "Installed APK sha256: $installed_apk_sha256"
if [[ "$local_apk_sha256" != "$installed_apk_sha256" ]]; then
  echo "Installed APK hash mismatch for $PACKAGE" >&2
  exit 1
fi

"$ADB" -s "$device_serial" logcat -c || true

echo "==> Launching $PACKAGE/$ACTIVITY on $device_serial"
launch_output="$("$ADB" -s "$device_serial" shell am start -W -n "$PACKAGE/$ACTIVITY" 2>&1)"
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
if grep -q "$PACKAGE" <<<"$launch_crash_log"; then
  printf '%s\n' "$launch_crash_log" >&2
  echo "Android app logged a fatal exception after launch" >&2
  exit 1
fi

cat <<NEXT_STEPS
==> Goose launched cleanly on $device_serial
Installed APK hash verified against $APK_PATH

Phone test checklist:
1. Run Scripts/android_final_phone_checklist.sh for the current final-run sheet.
2. Run Scripts/prepare_android_phone_evidence.sh immediately before the controlled capture.
3. Grant Bluetooth permissions.
4. Press Scan, tap the WHOOP candidate, then wait for "Ready; subscribed ...; hello sent".
5. Start a capture session and validation window before the counted walk.
6. Finish the capture session, press Validate, run Health Gate/Sync, then collect final PR evidence:
   Scripts/android_final_pr_gate.sh tmp/android-phone-final-gate-real --skip-validate
7. If you only need a diagnostic bundle without strict PR readiness, run:
   Scripts/android_phone_final_gate.sh tmp/android-phone-diagnostic-gate-real --require-step-validation
8. Reprint PR readiness from an existing bundle:
   Scripts/android_pr_readiness.sh tmp/android-phone-final-gate-real
   Scripts/android_pr_readiness.sh --strict tmp/android-phone-final-gate-real

Still phone-bound: physical WHOOP command-ready BLE hello evidence,
live-notification raw capture provenance, counted-step decoder confirmation,
and Health Connect ready write-attempt evidence from a real Android phone.
NEXT_STEPS
