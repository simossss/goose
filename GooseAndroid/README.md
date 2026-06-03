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
APK native-library contents and runs the smoke harness when an adb device or
emulator is online.

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

Run the on-device/emulator smoke harness:

```sh
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb install -r app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb shell am instrument -w com.goose.android.test/com.goose.android.GooseRustBridgeInstrumentationTest
```

Pull the debug app's local SQLite store for desktop inspection:

```sh
Scripts/pull_android_database.sh tmp/goose-phone.sqlite
```

Set `ANDROID_SERIAL` when more than one adb device is online. The helper uses
`run-as com.goose.android`, so it expects the debug APK.

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
  evidence with the active `capture_session_id`.
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
- Exposes Android storage/privacy controls for export inventory, export cache
  clearing, and two-tap local SQLite data deletion.
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
- Declares the Android Health Connect write permissions for Goose-owned metric
  families, exposes permission/status actions, feeds granted
  permissions into the Rust `health_sync.dry_run` gate, and routes approved
  Android 14+ planned writes through the platform `HealthConnectManager`
  adapter for steps, heart rate, and active calories. Android builds
  Health Connect heart-rate candidates from trusted Goose-decoded heart-rate
  feature rows plus step and active-calorie candidates from existing daily
  activity metrics before syncing.
- Provides the Health Connect permissions rationale activity and Android 14+
  permission-usage alias required by the platform permissions screen.
- Includes an instrumentation smoke harness for native loading, `core.version`,
  isolated `storage.check`, `protocol.parse_frame_hex`,
  `health_sync.dry_run`, and `privacy.lint`.

## Physical Device Workflow

1. Install and open the debug app on an Android phone.
2. Grant Bluetooth permissions. Android 11 and older also require location for
   BLE scanning.
3. Press `Scan`, then tap the WHOOP candidate when it appears.
4. Wait for `Ready; subscribed ...; hello sent`.
5. Optional but recommended for owned captures: press `Start` in the capture
   session row before a controlled test and `Finish` afterwards.
6. Press `Range` to prepare a command write, review the frame/preflight text,
   then press `Range` again within 15 seconds to send. Use the same two-tap
   flow for `History` and `Abort`.
7. Use `HR`, `Sensors`, `Steps`, and `Sessions` for compact summaries instead
   of dumping large raw JSON in the UI.

The current build has captured live heart-rate packets and imported WHOOP
historical data from a physical WHOOP 5.0. Explicit step-counter extraction is
not confirmed yet; keep step tests as capture-session-bound evidence and resume
decoder work separately.

## Remaining Port Slices

- Continue packet decoder work for step counters and other packet-derived
  metrics.
- Health Connect phone/platform permission testing with real planned writes.
  Trusted heart-rate candidate planning is implemented; daily step and
  active-calorie candidate planning is implemented once the parked
  decoder/rollup work produces `daily_activity_metrics` rows.
- Optional Kotlin/Compose UI migration once the bridge and BLE behavior are
  stable.
