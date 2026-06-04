# Goose Android

This is the Android port for Goose. It currently proves the shared Rust core,
JNI bridge, BLE scan/connect path, queued GATT operations, fixed client-hello
write, live notification parsing, SQLite capture import, Android capture-session
tagging, historical command sends, and Rust-backed Health/Debug report controls.

## Build

From the repository root:

```sh
Scripts/validate_android.sh
```

That assembles debug, instrumentation, and release APKs. Gradle builds the
matching Rust Android libraries before each APK variant, then the script checks
APK native-library contents, verifies packaged manifest metadata, runs Android
lint, verifies local-first permission boundaries, and runs the smoke harness
when an adb device or emulator is online. Set `ANDROID_SERIAL` when more than
one adb target is online; validation refuses to install or launch on an
arbitrary device.

Print a concise Android port status snapshot for PR and phone handoff:

```sh
Scripts/android_port_status.sh
```

Generate a markdown PR readiness summary from current build state and an
optional phone evidence bundle:

```sh
Scripts/android_pr_readiness.sh [tmp/android-phone-final-gate-...]
Scripts/android_pr_readiness.sh --strict [tmp/android-phone-final-gate-...]
```

Use `--strict` after the final phone gate when the command should fail if any
phone-bound acceptance item remains unproven, or if the evidence bundle was
collected from a different checkout commit or dirty worktree.

Print the final real-phone run sheet before starting the controlled capture:

```sh
Scripts/android_final_phone_checklist.sh
```

Run local Android validation before preparing the scoped phone evidence. After
`Scripts/prepare_android_phone_evidence.sh` and the controlled phone capture,
run the final PR gate with `--skip-validate` so the gate does not clear logcat
or overwrite the start marker before evidence collection:

```sh
Scripts/android_final_pr_gate.sh tmp/android-phone-final-gate-real --skip-validate
```

`Scripts/validate_android.sh` bounds adb install, launch, logcat, and
instrumentation commands so a bad USB session fails explicitly instead of
hanging. Tune those waits with `GOOSE_ANDROID_ADB_COMMAND_TIMEOUT_SECONDS` and
`GOOSE_ANDROID_INSTRUMENTATION_TIMEOUT_SECONDS`; use
`GOOSE_ANDROID_SKIP_INSTRUMENTATION=1` only for non-device validation.

Without `--skip-validate`, this runs local Android validation, collects final
phone evidence with required step validation, then applies strict PR readiness.
Use that default only before a controlled capture. Add
`--require-health-success` when the run must prove a successful Health Connect
platform write, or `--dry-run` to print the command sequence without using adb.
The final PR gate
requires a clean git worktree whose `HEAD` exactly matches the configured
upstream branch, so the evidence bundle maps to the current pushed commit;
`--allow-dirty` is for local debugging only.

When counted-step validation is intentionally parked, use the partial phone gate
to prove the real-phone BLE/capture/installed-package/Health Connect evidence
without requiring step validation or strict PR readiness:

```sh
Scripts/android_partial_phone_gate.sh tmp/android-phone-partial-gate-real
```

The partial gate still requires a clean git worktree whose `HEAD` exactly
matches the configured upstream branch, plus a physical adb device by default,
then prints the remaining PR-readiness blockers from the collected evidence
bundle. Use `--allow-dirty` only for local debugging evidence.

Manual build from Android Studio or the command line:

```sh
cd GooseAndroid
./gradlew :app:assembleDebug
./gradlew :app:assembleDebugAndroidTest
```

For a release-native APK:

```sh
cd GooseAndroid
./gradlew :app:assembleRelease
```

The Gradle project wires `:app:preDebugBuild`,
`:app:preDebugAndroidTestBuild`, and `:app:preReleaseBuild` to
`Scripts/build_android_rust.sh`, so Android Studio builds refresh
`Rust/android/` automatically and verify each ABI's generated profile/target
markers before packaging. You can still run `Scripts/build_android_rust.sh`
directly when debugging the Rust cross-compile step.

Install and launch the debug APK on a connected phone:

```sh
Scripts/install_android_debug.sh
```

Use `Scripts/install_android_debug.sh --no-build` after Android Studio has
already built the APK. Set `ANDROID_SERIAL` when more than one adb device or
emulator is online. The helper installs `app-debug.apk`, verifies the installed
APK hash matches the local debug APK, launches Goose, checks for immediate
AndroidRuntime crashes, and prints the physical test checklist.
The final evidence and database-pull helpers also require `ANDROID_SERIAL` when
more than one adb target is online, so phone evidence is never collected from an
arbitrary emulator or secondary device.

Run the on-device/emulator smoke harness:

```sh
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb install -r app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb shell am instrument -w com.goose.android.test/com.goose.android.GooseRustBridgeInstrumentationTest
```

Pull the debug app's local SQLite store for desktop inspection:

```sh
Scripts/pull_android_database.sh tmp/goose-phone.sqlite
Scripts/inspect_android_capture.sh tmp/goose-phone.sqlite
```

Collect a timestamped phone evidence bundle after a real-device test:

```sh
Scripts/collect_android_phone_evidence.sh
```

Use a fresh output directory for final evidence. The collector refuses a
non-empty output directory by default so stale files cannot be included in a new
evidence manifest.

For a stricter post-capture pass/fail bundle:

```sh
GOOSE_ANDROID_STRICT_EVIDENCE=1 Scripts/collect_android_phone_evidence.sh
```

For the final phone handoff gate after a controlled capture and Health Connect
sync attempt. It requires a physical adb device by default:

```sh
Scripts/android_phone_final_gate.sh
```

Run `Scripts/prepare_android_phone_evidence.sh` immediately before the
controlled capture. It clears logcat and writes the start marker required by
the final gate, so AndroidRuntime crash evidence is scoped to the current run.
The final gate also checks that the latest pulled raw capture timestamp is at
or after that marker, so stale database rows cannot satisfy a fresh logcat
marker.

Add `--require-health-success` after granting Health Connect permissions when
the session should prove a successful platform write, not just a write attempt.
The standard write-attempt gate also requires the audit row to include
permissions-ready dry-run context, planned writes, candidate count, and attempted
records.
Add `--require-step-validation` after running counted-step validation in the app
when the final phone session should prove a passing, capture-session-bound
step-validation audit row with decoded session frames and a selected counter
delta.

Set `ANDROID_SERIAL` when more than one adb device is online. The helper uses
`run-as com.goose.android`, so it expects the debug APK. It also pulls the
bounded BLE session, Health Connect sync, and step-validation audit logs,
snapshots the installed `com.goose.android` package metadata, compares the installed APK hash
against the local debug APK, records `logcat-start-marker.txt` and
`adb-state-final.txt` after collection, and
writes `evidence-gates.txt` with the effective gate configuration. Final
readiness requires that final adb state to be `device`, so the selected phone
must still be online after pull/hash/logcat collection. When BLE hello, Health
Connect write, or step-validation gates are enabled, the matching audit log
must be present in `evidence-files-manifest.txt` with valid byte counts and SHA-256 hashes. The
inspector prints table presence, row counts, recent raw evidence, recent capture
sessions, step sample rows when available, recent BLE session audit rows, and
recent Health Connect audit rows. For a
stricter post-capture gate, set
`GOOSE_ANDROID_MIN_RAW_EVIDENCE=1`,
`GOOSE_ANDROID_MIN_CAPTURE_SESSIONS=1`,
`GOOSE_ANDROID_MIN_SESSION_RAW_EVIDENCE=1`,
`GOOSE_ANDROID_MIN_SESSION_LIVE_NOTIFICATION_RAW_EVIDENCE=1`,
`GOOSE_ANDROID_MIN_FINISHED_CAPTURE_SESSIONS=1`,
`GOOSE_ANDROID_REQUIRE_BLE_HELLO_SENT=1`, or
`GOOSE_ANDROID_REQUIRE_HEALTH_AUDIT=1`. For Health Connect phone validation, add
`GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_ATTEMPT=1` to require a platform write
attempt, `GOOSE_ANDROID_REQUIRE_HEALTH_READY_WRITE_PLAN=1` to require
permissions-ready planned-write context on that attempt, and
`GOOSE_ANDROID_REQUIRE_HEALTH_WRITE_SUCCESS=1` to require a
successful write with permissions-ready planned-write context and inserted
records. `Scripts/android_phone_final_gate.sh` enables the physical device, BLE
hello in command-ready audit rows, raw, session, session-tagged raw,
finished-session, installed-package, logcat-start-marker,
no-focused-AndroidRuntime-crash, Health Connect audit, and write-attempt gates
by default. Add `--skip-health` only for development smoke tests and
`--allow-emulator` only for emulator smoke tests.
For counted-step validation, set `GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_AUDIT=1`,
`GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_PASS=1`, or
`GOOSE_ANDROID_REQUIRE_STEP_VALIDATION_SESSION=1`.

The Android build expects generated Rust libraries under `Rust/android/`:

- `arm64-v8a/libgoose_core.so`
- `armeabi-v7a/libgoose_core.so`
- `x86_64/libgoose_core.so`

These files are build artifacts and are ignored by git.

## Current Scope

- Loads `libgoose_core.so` through `libgoose_android_bridge.so`.
- Calls the Rust JSON bridge with `core.version` and `storage.check`.
- Requests Android Bluetooth runtime permissions.
- Scans for WHOOP Gen 5 and Gen 4 service UUIDs.
- Connects to a selected device and discovers GATT services.
- Subscribes to WHOOP notification characteristics plus standard HR/battery
  notifications where available.
- Queues descriptor writes, characteristic reads, and the client-hello write so
  Android GATT operations are serialized.
- Reads basic battery and device-information characteristics where available.
- Writes the fixed Goose client hello frame to the discovered command
  characteristic.
- Parses incoming notification frames with `protocol.parse_frame_hex`.
- Imports incoming notification frames into the app-local SQLite store through
  `capture.import_frame_batch`.
- Starts and finishes Android manual capture sessions through
  `capture.start_session` and `capture.finish_session`, then tags incoming raw
  evidence from `goose-android/live-notification/...` with the active
  `capture_session_id`.
- Prepares the physical WHOOP command frames for range, historical data, and
  abort-history with Rust-backed direct-send preflight output, then sends the
  frame only after a second tap within the confirmation window.
- Shows structured command progress for queued, writing, written, blocked, and
  failed physical command writes.
- Shows observed transfer progress from command events and parsed notifications:
  command responses, data packets, normal-history frames, motion/optical frames,
  marker events, and raw/decoded import counters.
- Shows structured connection progress across scanning, device selection,
  service discovery, notification/read candidate discovery, queued/completed GATT
  operations, subscription count, command readiness, and client-hello state.
- Keeps the default Capture tab status compact; full JSON-heavy storage,
  privacy, export, and bridge reports live behind Insights and More.
- Replaces the initial debug-only surface with a styled Android utility UI:
  Capture, Insights, More, and Log tabs with primary and destructive actions
  visually separated.
- Keeps the capture activity alive across orientation and screen-size changes
  so a controlled BLE capture is not torn down by accidental rotation.
- Exposes Android storage/privacy controls for export inventory, export cache
  clearing, and two-tap local SQLite plus evidence-log deletion.
- Exposes an Android evidence readiness report for phone handoff checks:
  raw/session/live-notification evidence rows, finished capture sessions,
  decoded/step counts, BLE ready/hello/command-ready audit counts, same-row
  command-ready client hello counts, Health Connect ready write-plan/write-attempt
  counts, Health Connect inserted-record success counts, step-validation
  session/decoded/selected-delta counts, and PASS/WAIT status.
- Records BLE scan/connect/session progress to
  `files/goose/ble-session-log.jsonl`, including ready state, command
  characteristic readiness, and same-row command-ready client-hello state for
  final phone evidence.
- Binds Android counted-step validation to the active or most recently finished
  capture session when one is available, so final phone checks do not mix
  packets from unrelated sessions in the same time window.
- Records counted-step validation attempts to
  `files/goose/step-validation-log.jsonl` so phone evidence bundles preserve the
  validation session id, pass/fail state, frame counts, selected delta, and
  issues.
- Runs Rust-backed operational reports:
  - `metrics.input_readiness`
  - `capture.timeline`
  - `capture.list_sessions`
  - `commands.definitions`
  - `commands.direct_send_gate`
  - `commands.direct_send_preflight`
  - `commands.list_validation_records`
  - `export.raw_timeframe`
  - `metrics.heart_rate_features`
  - `metrics.step_packet_discovery`
  - `metrics.step_capture_validation`
  - `metrics.recovery_sensor_discovery`
  - `metrics.activity_unavailable_daily_status`
  - `metrics.energy_unavailable_daily_status`
  - `metrics.recovery_unavailable_daily_status`
- Declares the Android Health Connect write permissions for Goose-owned metric
  families, exposes permission/status actions, feeds granted
  permissions into the Rust `health_sync.dry_run` gate, and routes approved
  Android 14+ planned writes through the platform `HealthConnectManager`
  adapter for steps, heart rate, and active calories. The app blocks `Sync`
  until the dry run has planned writes, write permissions are ready, all records
  are ready, and there are no dry-run blockers. Android builds
  Health Connect heart-rate candidates from trusted Goose-decoded heart-rate
  feature rows plus step and active-calorie candidates from existing daily
  activity metrics before syncing.
- Records Health Connect sync attempts, blocked writes, successes, and failures
  to `files/goose/health-connect-sync-log.jsonl` for real-device debugging,
  including dry-run readiness, candidate count, planned write count, attempted
  record counts on write attempts, and inserted record counts on successful
  writes.
- Disables Android backup and device-transfer extraction for app-local health
  data through manifest flags plus explicit backup/data-extraction rules.
- Provides the Health Connect permissions rationale activity and Android 14+
  permission-usage alias required by the platform permissions screen.
- Includes an instrumentation smoke harness for native loading, `core.version`,
  isolated `storage.check`, `protocol.parse_frame_hex`,
  `health_sync.dry_run`, and `privacy.lint`.

## Physical Device Workflow

1. Install and open the debug app on an Android phone with
   `Scripts/install_android_debug.sh`, or run the app from Android Studio.
   For the concise final-run sheet, run `Scripts/android_final_phone_checklist.sh`.
2. Grant Bluetooth permissions. Android 11 and older also require location for
   BLE scanning.
3. Press `Scan`, then tap the WHOOP candidate when it appears.
4. Wait for `Ready; subscribed ...; hello sent`.
5. For final owned captures, press `Start` in the capture session row before a
   controlled test and `Finish` afterwards.
6. Press `Range` to prepare a command write, review the frame/preflight text,
   then press `Range` again within 15 seconds to send. Use the same two-tap
   flow for `History` and `Abort`.
7. For counted-step validation, use the `Step validation` row: press `Start`
   before the counted walk, press `End` afterwards while the capture session is
   still active, enter the manual count, press capture-session `Finish`, then
   press `Validate`. The report should name the most recently finished capture
   session. The app blocks validation until the manual count is positive, the
   validation window is marked, and a capture session is active or recently
   finished. Starting a new capture or clearing local data resets the previous
   validation window and finished-session marker.
8. Use `Heart`, `Sensors`, `Steps`, `Blocked`, and `Sessions` for compact
   summaries instead of dumping large raw JSON in the UI.
9. Pull and inspect the debug store:
   `Scripts/pull_android_database.sh tmp/goose-phone.sqlite`, then
   `Scripts/inspect_android_capture.sh tmp/goose-phone.sqlite`.
10. For a PR/phone-session artifact, run
   `Scripts/collect_android_phone_evidence.sh`.
11. After final evidence collection, run
    `Scripts/android_pr_readiness.sh tmp/android-phone-final-gate-...` for the
    PR checklist summary, then
    `Scripts/android_pr_readiness.sh --strict tmp/android-phone-final-gate-...`
    for a nonzero exit if any final acceptance item is still missing. The
    composed command is
    `Scripts/android_final_pr_gate.sh tmp/android-phone-final-gate-real`.
    Final evidence must come from a physical adb device; emulator evidence is
    accepted only for development smoke tests with `--allow-emulator`.

The current build has captured live heart-rate packets and imported WHOOP
historical data from a physical WHOOP 5.0. Explicit step-counter extraction is
not confirmed yet; final step acceptance now requires a passing validation that
is bound to a capture session with decoded frames and a selected counter delta.

## Remaining Port Slices

- Continue packet decoder work for step counters and other packet-derived
  metrics.
- Health Connect phone/platform permission testing with real planned writes and
  inserted-record success evidence when `--require-health-success` is used.
  Trusted heart-rate candidate planning is implemented; daily step and
  active-calorie candidate planning is implemented once the parked
  decoder/rollup work produces `daily_activity_metrics` rows.
- Optional Kotlin/Compose UI migration once the bridge and BLE behavior are
  stable.
