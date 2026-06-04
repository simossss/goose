#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ANDROID_DIR="$APP_DIR/GooseAndroid"
DEBUG_APK="$ANDROID_DIR/app/build/outputs/apk/debug/app-debug.apk"
RELEASE_APK="$ANDROID_DIR/app/build/outputs/apk/release/app-release-unsigned.apk"

export ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"

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

file_sha256() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{ print $1 }'
    return
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{ print $1 }'
    return
  fi
  printf 'sha256 unavailable'
}

apk_summary() {
  local apk_path="$1"
  local label="$2"
  echo
  echo "$label APK"
  if [[ ! -f "$apk_path" ]]; then
    echo "path: $apk_path"
    echo "status: not built"
    return
  fi
  echo "path: $apk_path"
  echo "bytes: $(wc -c < "$apk_path" | tr -d ' ')"
  echo "sha256: $(file_sha256 "$apk_path")"
  local aapt
  aapt="$(find_build_tool aapt)"
  if [[ -n "$aapt" && -x "$aapt" ]]; then
    "$aapt" dump badging "$apk_path" \
      | awk '/^package:|^sdkVersion:|^targetSdkVersion:|^application-label:|^launchable-activity:|^native-code:/ { print }'
  else
    echo "aapt: unavailable; metadata not shown"
  fi
}

rust_android_artifact_summary() {
  echo
  echo "Rust Android artifacts"
  for abi in arm64-v8a armeabi-v7a x86_64; do
    local library="$APP_DIR/Rust/android/$abi/libgoose_core.so"
    local profile="$APP_DIR/Rust/android/$abi/.goose_core.profile"
    local target="$APP_DIR/Rust/android/$abi/.goose_core.target"
    if [[ -f "$library" ]]; then
      echo "$abi: present $(wc -c < "$library" | tr -d ' ') bytes, profile=$(cat "$profile" 2>/dev/null || echo '?'), target=$(cat "$target" 2>/dev/null || echo '?')"
    else
      echo "$abi: missing"
    fi
  done
}

echo "Goose Android port status"
echo "repository: $APP_DIR"
echo "branch: $(git -C "$APP_DIR" rev-parse --abbrev-ref HEAD)"
echo "commit: $(git -C "$APP_DIR" rev-parse --short HEAD) $(git -C "$APP_DIR" log -1 --pretty=%s)"
echo "dirty tracked files: $(git -C "$APP_DIR" status --short --untracked-files=no | wc -l | tr -d ' ')"
echo "untracked non-ignored files: $(git -C "$APP_DIR" ls-files --others --exclude-standard | wc -l | tr -d ' ')"

apk_summary "$DEBUG_APK" "Debug"
apk_summary "$RELEASE_APK" "Release"
rust_android_artifact_summary

cat <<'STATUS'

Validation gate:
  Scripts/validate_android.sh

Final PR evidence gate:
  Scripts/android_final_pr_gate.sh tmp/android-phone-final-gate-real

Lower-level diagnostic phone evidence gate:
  Scripts/android_phone_final_gate.sh tmp/android-phone-diagnostic-gate-real --require-step-validation

Partial phone evidence gate while counted-step validation is parked:
  Scripts/android_partial_phone_gate.sh tmp/android-phone-partial-gate-real

Strict PR readiness after final phone evidence:
  Scripts/android_pr_readiness.sh --strict tmp/android-phone-final-gate-real

Phone-bound completion checks:
  1. Physical WHOOP scan/connect validation on a real Android phone.
  2. BLE session audit proving completed client hello write in command-ready rows.
  3. Controlled capture pull with decoded frames and session-tagged Android BLE live-notification raw evidence inspected with Scripts/inspect_android_capture.sh.
  4. Evidence bundle manifest with path, byte count, and SHA-256 for pulled files.
  5. Step-counter decoder confirmation from real counted-step evidence bound to a decoded capture session with a nonzero selected counter delta.
  6. Health Connect permission grant and real planned write attempt on Android 14+ with permissions-ready planned-write evidence.
  7. Focused AndroidRuntime logcat has no com.goose.android crash lines.

Generated artifact policy:
  Rust/android/, GooseAndroid/**/build/, GooseAndroid/**/.cxx/, local.properties,
  and tmp/ are ignored build or local-device artifacts.
STATUS
