#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

commit="$(git -C "$APP_DIR" rev-parse --short HEAD) $(git -C "$APP_DIR" log -1 --pretty=%s)"
branch="$(git -C "$APP_DIR" rev-parse --abbrev-ref HEAD)"

cat <<CHECKLIST
# Goose Android Partial Phone Checklist

Branch: $branch
Commit: $commit

Use this while counted-step validation is parked. It proves the real-phone
BLE/capture/installed-package/Health Connect evidence without requiring a
passing step-validation audit.

## Before Capture

1. Install or run the debug app on the phone:
   \`Scripts/install_android_debug.sh\`
2. Prepare scoped logcat evidence:
   \`Scripts/prepare_android_phone_evidence.sh\`
3. Open Goose, grant Bluetooth permissions, and grant location if Android 11 or older asks for it.
4. Tap \`Scan\`, then tap the WHOOP candidate.
5. Wait for the status text to include \`Ready; subscribed ...; hello sent\`.
6. Tap capture-session \`Start\`.

## Controlled Capture

1. Keep Goose connected long enough for live notification packets to appear.
2. Confirm the packet area shows notifications increasing.
3. If you counted a short window and want activity candidates before explicit
   device-counter rows are confirmed, mark validation \`Start\`/\`End\`, enter
   the manual count, then tap \`Motion\`.
4. Tap capture-session \`Finish\`.
5. Tap \`Evidence\` and confirm raw/session/live-notification counts are nonzero if visible.

## Health Connect

1. Tap \`Evidence\` and check whether daily activity rows exist. A Motion-backed
   run should show \`Daily local estimate metrics\` above zero; an explicit
   counter-backed run should show \`Daily device counter metrics\` above zero.
2. Tap \`Health Gate\`.
3. If planned writes are available, grant Android Health Connect write permissions when prompted.
4. Tap \`Sync\`.
5. The partial gate requires a permissions-ready planned-write attempt.
6. Use \`--require-health-success\` only when this run should prove a successful platform write.

## Pull Partial Evidence

Use the partial phone gate after the app-side run. This requires a physical adb
device by default; \`--allow-emulator\` is intentionally not exposed here.

\`\`\`sh
Scripts/android_partial_phone_gate.sh tmp/android-phone-partial-gate-real
\`\`\`

Require successful Health Connect write as well:

\`\`\`sh
Scripts/android_partial_phone_gate.sh tmp/android-phone-partial-gate-real --require-health-success
\`\`\`

For manual debugging, collect a separate diagnostic bundle with the lower-level
commands:

\`\`\`sh
Scripts/android_phone_final_gate.sh tmp/android-phone-partial-diagnostic-gate-real
Scripts/android_pr_readiness.sh tmp/android-phone-partial-diagnostic-gate-real
\`\`\`

## Evidence Expected To Pass

- Installed com.goose.android package metadata and APK hash match: PASS.
- Device kind: physical.
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
- Session raw evidence rows: at least 1.
- Session live notification raw evidence rows: at least 1.
- Session decoded frame rows: at least 1.
- Finished nonempty capture sessions: at least 1.
- Daily activity metrics: at least 1 when Health Connect planned writes include activity rows.
- Daily local estimate metrics: at least 1 after a passing \`Motion\` run.
- Daily device counter metrics: at least 1 only after explicit WHOOP step-counter rows are confirmed.
- Health Connect write started events: at least 1.
- Health Connect ready write started events: at least 1.
- Health Connect planned write started events: at least 1.
- Health Connect candidate write started events: at least 1.
- Health Connect records attempted events: at least 1.
- Health Connect write succeeded events: at least 1 only when \`--require-health-success\` is used.

## Still Remaining After A Passing Partial Gate

- Counted-step validation with \`Scripts/android_final_pr_gate.sh\`.
- Step-validation audit pass bound to a decoded capture session.
- Selected counter delta from real counted-step evidence.
CHECKLIST
