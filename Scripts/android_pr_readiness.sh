#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PHONE_EVIDENCE_DIR="${1:-}"

status_value() {
  local key="$1"
  local file="$2"
  awk -F': ' -v key="$key" '$1 == key { print $2; exit }' "$file"
}

summary_bullet_value() {
  local key="$1"
  local file="$2"
  awk -F': ' -v key="- $key" '$1 == key { print $2; exit }' "$file"
}

latest_commit="$(git -C "$APP_DIR" rev-parse --short HEAD) $(git -C "$APP_DIR" log -1 --pretty=%s)"
branch="$(git -C "$APP_DIR" rev-parse --abbrev-ref HEAD)"
dirty_tracked="$(git -C "$APP_DIR" status --short --untracked-files=no | wc -l | tr -d ' ')"
untracked="$(git -C "$APP_DIR" ls-files --others --exclude-standard | wc -l | tr -d ' ')"

tmp_status="$(mktemp "${TMPDIR:-/tmp}/goose-android-status.XXXXXX")"
trap 'rm -f "$tmp_status"' EXIT
"$SCRIPT_DIR/android_port_status.sh" > "$tmp_status"

echo "# Goose Android PR Readiness"
echo
echo "Branch: $branch"
echo "Commit: $latest_commit"
echo "Dirty tracked files: $dirty_tracked"
echo "Untracked non-ignored files: $untracked"
echo
echo "## Local Build Snapshot"
echo
awk '
  /^Debug APK$/ { section = "debug"; next }
  /^Release APK$/ { section = "release"; next }
  /^Rust Android artifacts$/ { section = "rust"; print; next }
  section == "debug" && /^path:|^bytes:|^sha256:|^package:|^sdkVersion:|^targetSdkVersion:|^native-code:/ { print "Debug " $0; next }
  section == "release" && /^path:|^bytes:|^sha256:|^package:|^sdkVersion:|^targetSdkVersion:|^native-code:/ { print "Release " $0; next }
  section == "rust" && /^(arm64-v8a|armeabi-v7a|x86_64):/ { print; next }
' "$tmp_status"
echo
echo "## Validation Commands"
echo
echo "- \`Scripts/validate_android.sh\`"
echo "- \`Scripts/android_phone_final_gate.sh [output-dir] --require-step-validation\`"
echo "- Add \`--require-health-success\` only when the final phone run must prove a successful Health Connect platform write."
echo
echo "## Phone Evidence"
echo
if [[ -n "$PHONE_EVIDENCE_DIR" ]]; then
  summary="$PHONE_EVIDENCE_DIR/phone-handoff-summary.md"
  gates="$PHONE_EVIDENCE_DIR/evidence-gates.txt"
  if [[ -f "$summary" ]]; then
    echo "Evidence directory: $PHONE_EVIDENCE_DIR"
    echo "Result: $(status_value "Result" "$summary")"
    echo "Device serial: $(status_value "Device serial" "$summary")"
    echo "Device: $(status_value "Device" "$summary")"
    echo "Android: $(status_value "Android" "$summary")"
    echo
    echo "Installed app:"
    echo "- Result: $(summary_bullet_value "Result" "$summary")"
    echo "- Package path: $(summary_bullet_value "Package path" "$summary")"
    echo
    echo "Capture evidence:"
    echo "- Raw evidence rows: $(summary_bullet_value "Raw evidence rows" "$summary")"
    echo "- Capture sessions: $(summary_bullet_value "Capture sessions" "$summary")"
    echo "- Session raw evidence rows: $(summary_bullet_value "Session raw evidence rows" "$summary")"
    echo "- Finished nonempty capture sessions: $(summary_bullet_value "Finished nonempty capture sessions" "$summary")"
    echo "- Step samples: $(summary_bullet_value "Step samples" "$summary")"
    echo "- Daily activity metrics: $(summary_bullet_value "Daily activity metrics" "$summary")"
    echo
    echo "Health Connect evidence:"
    echo "- Write started events: $(summary_bullet_value "Write started events" "$summary")"
    echo "- Write succeeded events: $(summary_bullet_value "Write succeeded events" "$summary")"
    echo "- Write failed events: $(summary_bullet_value "Write failed events" "$summary")"
    echo
    echo "Step validation evidence:"
    echo "- Completed events: $(summary_bullet_value "Completed events" "$summary")"
    echo "- Passed events: $(summary_bullet_value "Passed events" "$summary")"
    echo "- Failed events: $(summary_bullet_value "Failed events" "$summary")"
    echo
    echo "Gate configuration:"
    if [[ -f "$gates" ]]; then
      sed 's/^/- /' "$gates"
    else
      echo "- missing evidence-gates.txt"
    fi
  else
    echo "Evidence directory supplied, but phone-handoff-summary.md is missing: $PHONE_EVIDENCE_DIR"
  fi
else
  echo "No phone evidence directory supplied."
fi
echo
echo "## Remaining Phone-Bound Acceptance"
echo
echo "- Physical WHOOP scan/connect/client-hello validation on a real Android phone."
echo "- Controlled capture pull inspected with \`Scripts/inspect_android_capture.sh\`."
echo "- Step-counter decoder confirmation from real counted-step evidence."
echo "- Health Connect permission grant and real planned write attempt on Android 14+."
