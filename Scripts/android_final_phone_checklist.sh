#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

commit="$(git -C "$APP_DIR" rev-parse --short HEAD) $(git -C "$APP_DIR" log -1 --pretty=%s)"
branch="$(git -C "$APP_DIR" rev-parse --abbrev-ref HEAD)"

cat <<CHECKLIST
# Goose Android Final Phone Checklist

Branch: $branch
Commit: $commit

## Before The Walk

1. Install or run the debug app on the phone:
   \`Scripts/install_android_debug.sh\`
2. Prepare scoped logcat evidence:
   \`Scripts/prepare_android_phone_evidence.sh\`
3. Open Goose, grant Bluetooth permissions, and grant location if Android 11 or older asks for it.
4. Tap \`Scan\`, then tap the WHOOP candidate.
5. Wait for the status text to include \`Ready; subscribed ...; hello sent\`.
6. Tap capture-session \`Start\`.
7. Tap validation \`Start\`.

## Controlled Step Capture

1. Walk the counted route.
2. Tap validation \`End\` while the capture session is still active.
3. Enter the manual counted steps.
4. Tap capture-session \`Finish\`.
5. Tap \`Validate\`.
6. Confirm the validation report names the most recently finished capture session.
7. Tap \`Motion\` with the same marked window and manual count if Health Connect
   needs validated local-estimate step rows before explicit device-counter rows
   are confirmed.

## Health Connect

1. Tap \`Evidence\` and check whether daily activity rows exist. A Motion-backed
   run should show \`Daily local estimate metrics\` above zero; an explicit
   counter-backed run should show \`Daily device counter metrics\` above zero.
2. Tap \`Health Gate\`.
3. If planned writes are available, grant Android Health Connect write permissions when prompted.
4. Tap \`Sync\`.
5. For final completion, the pulled evidence must include at least a write attempt.
6. Use \`--require-health-success\` only when this run should prove a successful platform write.

## Pull Final Evidence

Use the strict final gate after the app-side run. Because
\`Scripts/prepare_android_phone_evidence.sh\` already cleared logcat and wrote
the start marker before the controlled capture, use \`--skip-validate\` here so
validation does not clear that scoped evidence before collection. This requires
a physical adb device by default; \`--allow-emulator\` is only for development
smoke tests.

\`\`\`sh
Scripts/android_final_pr_gate.sh tmp/android-phone-final-gate-real --skip-validate
\`\`\`

Require successful Health Connect write as well:

\`\`\`sh
Scripts/android_final_pr_gate.sh tmp/android-phone-final-gate-real --skip-validate --require-health-success
\`\`\`

For manual debugging without strict PR readiness, collect a separate diagnostic
bundle with the lower-level command:

\`\`\`sh
Scripts/android_phone_final_gate.sh tmp/android-phone-diagnostic-gate-real --require-step-validation
\`\`\`

Lower-level Health Connect success gate:

\`\`\`sh
Scripts/android_phone_final_gate.sh tmp/android-phone-diagnostic-gate-real --require-step-validation --require-health-success
\`\`\`

The final PR gate already prints strict readiness. Reprint the PR-ready summary
from an existing final bundle with:

\`\`\`sh
Scripts/android_pr_readiness.sh tmp/android-phone-final-gate-real
Scripts/android_pr_readiness.sh --strict tmp/android-phone-final-gate-real
\`\`\`

## Evidence Expected To Pass

- Installed com.goose.android package metadata and APK hash match: PASS.
- Logcat start marker result: PASS.
- Latest raw capture after marker result: PASS.
- Focused AndroidRuntime crash lines: 0.
- BLE session ready events: at least 1.
- BLE session hello sent events: at least 1.
- BLE session client hello command-ready completed events: at least 1.
- BLE session command ready events: at least 1.
- BLE session ready hello command-ready events: at least 1.
- Raw evidence rows: at least 1.
- Decoded frame rows: at least 1.
- Capture sessions: at least 1.
- Session-tagged raw evidence rows: at least 1.
- Session live notification raw evidence rows: at least 1.
- Session decoded frame rows: at least 1.
- Finished nonempty capture sessions: at least 1.
- Daily activity metrics: at least 1 when Health Connect planned writes include activity rows.
- Daily local estimate metrics: at least 1 after a passing \`Motion\` run.
- Daily device counter metrics: at least 1 only after explicit WHOOP step-counter rows are confirmed.
- Step validation completed events: at least 1.
- Step validation passed events: at least 1.
- Step validation session-bound events: at least 1.
- Step validation session decoded events: at least 1.
- Step validation selected delta events: at least 1.
- Health Connect write started events: at least 1.
- Health Connect ready write started events: at least 1.
- Health Connect planned write started events: at least 1.
- Health Connect candidate write started events: at least 1.
- Health Connect records attempted events: at least 1.
- Health Connect record-summary write started events: at least 1.
- Health Connect write succeeded events: at least 1 only when \`--require-health-success\` is used.

## Files To Keep For PR Review

- \`phone-handoff-summary.md\`
- \`evidence-gates.txt\`
- \`adb-devices.txt\`
- \`android-serial.txt\`
- \`android-device-kind.txt\`
- \`device-manufacturer.txt\`
- \`device-model.txt\`
- \`android-version.txt\`
- \`android-sdk.txt\`
- \`inspect-android-capture.txt\`
- \`goose-package-path.txt\`
- \`goose-package-summary.txt\`
- \`goose-package-dumpsys.txt\`
- \`goose-local-debug-apk-sha256.txt\`
- \`goose-installed-apk-sha256.txt\`
- \`goose-phone.sqlite\`
- \`goose-phone-ble-session-log.jsonl\`
- \`goose-phone-health-connect-sync-log.jsonl\`
- \`goose-phone-step-validation-log.jsonl\`
- \`logcat-goose-brief.txt\`
- \`logcat-start-marker.txt\`
- \`evidence-files-manifest.txt\`
CHECKLIST
