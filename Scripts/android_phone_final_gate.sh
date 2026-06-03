#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_DIR="$APP_DIR/tmp/android-phone-final-gate-$STAMP"
REQUIRE_HEALTH_SUCCESS=0
REQUIRE_HEALTH=1
REQUIRE_STEP_VALIDATION=0
ALLOW_EMULATOR=0

usage() {
  cat <<'USAGE'
Usage: Scripts/android_phone_final_gate.sh [output-dir] [--require-step-validation] [--require-health-success] [--skip-health] [--allow-emulator]

Collects the final Android phone evidence bundle with strict pass/fail gates:
- physical Android device, unless --allow-emulator is set
- at least one raw_evidence row
- at least one capture_sessions row
- at least one session-tagged raw_evidence row
- at least one finished capture session with frame_count > 0
- installed com.goose.android package metadata
- Health Connect audit log and write_started event, unless --skip-health is set

Use --require-health-success only after granting Health Connect permissions and
creating at least one writeable planned record in the app.
Use --require-step-validation after running the counted-step validation action
in the app for the controlled capture session.
Use --allow-emulator only for development smoke tests. PR acceptance still needs
evidence from a physical Android phone.

Set ANDROID_SERIAL when more than one adb device is online.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --require-health-success)
      REQUIRE_HEALTH_SUCCESS=1
      shift
      ;;
    --require-step-validation)
      REQUIRE_STEP_VALIDATION=1
      shift
      ;;
    --skip-health)
      REQUIRE_HEALTH=0
      shift
      ;;
    --allow-emulator)
      ALLOW_EMULATOR=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      OUTPUT_DIR="$1"
      shift
      ;;
  esac
done

echo "Running Goose Android final phone gate"
echo "output: $OUTPUT_DIR"
echo "strict capture evidence: required"
if [[ "$ALLOW_EMULATOR" == "1" ]]; then
  echo "Physical Android device: skipped for emulator smoke"
else
  echo "Physical Android device: required"
fi
if [[ "$REQUIRE_STEP_VALIDATION" == "1" ]]; then
  echo "Step validation audit/pass: required"
fi
if [[ "$REQUIRE_HEALTH" == "1" ]]; then
  echo "Health Connect audit/write attempt: required"
  if [[ "$REQUIRE_HEALTH_SUCCESS" == "1" ]]; then
    echo "Health Connect write success: required"
  fi
else
  echo "Health Connect gates: skipped"
fi

export GOOSE_ANDROID_STRICT_EVIDENCE=1
export GOOSE_ANDROID_MIN_RAW_EVIDENCE=1
export GOOSE_ANDROID_MIN_CAPTURE_SESSIONS=1
export GOOSE_ANDROID_MIN_SESSION_RAW_EVIDENCE=1
export GOOSE_ANDROID_MIN_FINISHED_CAPTURE_SESSIONS=1
export GOOSE_ANDROID_REQUIRE_INSTALLED_PACKAGE=1
if [[ "$ALLOW_EMULATOR" != "1" ]]; then
  export GOOSE_ANDROID_REQUIRE_PHYSICAL_DEVICE=1
fi

if [[ "$REQUIRE_STEP_VALIDATION" == "1" ]]; then
  export GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_AUDIT=1
  export GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_PASS=1
fi

if [[ "$REQUIRE_HEALTH" == "1" ]]; then
  export GOOSE_ANDROID_REQUIRE_HEALTH_AUDIT=1
  export GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_ATTEMPT=1
fi

if [[ "$REQUIRE_HEALTH_SUCCESS" == "1" ]]; then
  export GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_SUCCESS=1
fi

"$SCRIPT_DIR/collect_android_phone_evidence.sh" "$OUTPUT_DIR"

echo
echo "Final gate summary:"
sed -n '1,80p' "$OUTPUT_DIR/phone-handoff-summary.md"
