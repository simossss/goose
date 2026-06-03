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

echo "==> Building Android Rust libraries"
"$APP_DIR/Scripts/build_android_rust.sh"

echo "==> Building Android debug, release, and instrumentation APKs"
(cd "$ANDROID_DIR" && "$GRADLEW" :app:assembleDebug :app:assembleRelease :app:assembleDebugAndroidTest)

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
