#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_DIR="$APP_DIR/tmp/android-phone-partial-gate-$STAMP"
RUN_VALIDATE=1
REQUIRE_HEALTH_SUCCESS=0
DRY_RUN=0
ALLOW_DIRTY=0

usage() {
  cat <<'USAGE'
Usage: Scripts/android_partial_phone_gate.sh [output-dir] [--skip-validate] [--require-health-success] [--allow-dirty] [--dry-run]

Runs the Android phone evidence gate without requiring counted-step validation:
1. Scripts/validate_android.sh, unless --skip-validate is set.
2. Scripts/android_phone_final_gate.sh [output-dir].
3. Scripts/android_pr_readiness.sh [output-dir].

Use this while step-counter validation is parked to prove physical-phone BLE,
capture-session, installed-package, and Health Connect write-attempt evidence.
It intentionally does not run strict PR readiness, because the full PR gate still
requires counted-step validation.

The partial phone gate requires a clean git worktree by default, including no
untracked non-ignored files, and requires HEAD to match the configured upstream
branch, so the evidence bundle maps to the pushed current commit.
Use --allow-dirty only for local debugging evidence that will not be used for
PR acceptance.

The phone evidence step requires a physical adb device by default. Set
ANDROID_SERIAL when more than one adb device is online.

Use --require-health-success only when this partial run must prove a successful
Health Connect platform write with inserted records, not just a ready write
attempt.
Use --dry-run to print the command sequence without building, using adb, or
collecting evidence.
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
    --allow-dirty)
      ALLOW_DIRTY=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
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

echo "Running Goose Android partial phone gate"
echo "output: $OUTPUT_DIR"
if [[ "$ALLOW_DIRTY" == "1" ]]; then
  echo "clean pushed worktree: skipped by --allow-dirty"
else
  echo "clean pushed worktree: required"
fi

phone_gate_args=("$OUTPUT_DIR")
if [[ "$REQUIRE_HEALTH_SUCCESS" == "1" ]]; then
  phone_gate_args+=("--require-health-success")
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "Dry run command sequence:"
  if [[ "$RUN_VALIDATE" == "1" ]]; then
    printf '  %q\n' "$SCRIPT_DIR/validate_android.sh"
  else
    echo "  skip validate"
  fi
  printf '  '
  printf '%q ' "$SCRIPT_DIR/android_phone_final_gate.sh" "${phone_gate_args[@]}"
  printf '\n'
  printf '  '
  printf '%q ' "$SCRIPT_DIR/android_pr_readiness.sh" "$OUTPUT_DIR"
  printf '\n'
  exit 0
fi

if [[ "$ALLOW_DIRTY" != "1" ]]; then
  dirty_tracked="$(git -C "$APP_DIR" status --short --untracked-files=no | wc -l | tr -d ' ')"
  untracked="$(git -C "$APP_DIR" ls-files --others --exclude-standard | wc -l | tr -d ' ')"
  if [[ "$dirty_tracked" != "0" || "$untracked" != "0" ]]; then
    echo "Partial phone gate requires a clean git worktree." >&2
    echo "Dirty tracked files: $dirty_tracked" >&2
    echo "Untracked non-ignored files: $untracked" >&2
    echo "Commit/stash changes first, or rerun with --allow-dirty for local debugging only." >&2
    exit 1
  fi
  if ! upstream_ref="$(git -C "$APP_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"; then
    echo "Partial phone gate requires the current branch to have a configured upstream." >&2
    echo "Push the branch and set upstream first, or rerun with --allow-dirty for local debugging only." >&2
    exit 1
  fi
  head_commit="$(git -C "$APP_DIR" rev-parse HEAD)"
  upstream_commit="$(git -C "$APP_DIR" rev-parse '@{u}')"
  if [[ "$head_commit" != "$upstream_commit" ]]; then
    head_commit="$(git -C "$APP_DIR" rev-parse --short HEAD)"
    upstream_commit="$(git -C "$APP_DIR" rev-parse --short '@{u}')"
    echo "Partial phone gate requires HEAD ($head_commit) to match upstream $upstream_ref ($upstream_commit)." >&2
    echo "Pull/rebase or push the current commit first, or rerun with --allow-dirty for local debugging only." >&2
    exit 1
  fi
  echo "upstream: $upstream_ref"
fi

if [[ "$RUN_VALIDATE" == "1" ]]; then
  "$SCRIPT_DIR/validate_android.sh"
else
  echo "Skipping local validation by request"
fi

"$SCRIPT_DIR/android_phone_final_gate.sh" "${phone_gate_args[@]}"
"$SCRIPT_DIR/android_pr_readiness.sh" "$OUTPUT_DIR"

echo
echo "Android partial phone gate passed: $OUTPUT_DIR"
echo "Run Scripts/android_final_pr_gate.sh after counted-step validation is resolved."
