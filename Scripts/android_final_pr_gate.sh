#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_DIR="$APP_DIR/tmp/android-phone-final-gate-$STAMP"
RUN_VALIDATE=1
REQUIRE_HEALTH_SUCCESS=0

usage() {
  cat <<'USAGE'
Usage: Scripts/android_final_pr_gate.sh [output-dir] [--skip-validate] [--require-health-success]

Runs the full Android PR handoff gate:
1. Scripts/validate_android.sh, unless --skip-validate is set.
2. Scripts/android_phone_final_gate.sh [output-dir] --require-step-validation.
3. Scripts/android_pr_readiness.sh --strict [output-dir].

The phone evidence step requires a physical adb device by default. Set
ANDROID_SERIAL when more than one adb device is online.

Use --require-health-success only when the final phone run must prove a
successful Health Connect platform write, not just a ready write attempt.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-validate)
      RUN_VALIDATE=0
      shift
      ;;
    --require-health-success)
      REQUIRE_HEALTH_SUCCESS=1
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

echo "Running Goose Android final PR gate"
echo "output: $OUTPUT_DIR"

if [[ "$RUN_VALIDATE" == "1" ]]; then
  "$SCRIPT_DIR/validate_android.sh"
else
  echo "Skipping local validation by request"
fi

phone_gate_args=("$OUTPUT_DIR" "--require-step-validation")
if [[ "$REQUIRE_HEALTH_SUCCESS" == "1" ]]; then
  phone_gate_args+=("--require-health-success")
fi

"$SCRIPT_DIR/android_phone_final_gate.sh" "${phone_gate_args[@]}"
"$SCRIPT_DIR/android_pr_readiness.sh" --strict "$OUTPUT_DIR"

echo
echo "Android final PR gate passed: $OUTPUT_DIR"
