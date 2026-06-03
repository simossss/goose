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

That builds the Rust Android libraries, assembles the debug app and
instrumentation APK, and runs the smoke harness when an adb device or emulator
is online.

Manual build:

```sh
Scripts/build_android_rust.sh
cd GooseAndroid
./gradlew :app:assembleDebug
./gradlew :app:assembleDebugAndroidTest
```

Run the on-device/emulator smoke harness:

```sh
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb install -r app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb shell am instrument -w com.goose.android.test/com.goose.android.GooseRustBridgeInstrumentationTest
```

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
- Sends the physical WHOOP command frames for range, historical data, and
  abort-history through the serialized GATT write queue.
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
- Declares the Android Health Connect read/write permissions for Goose-owned
  metric families, exposes permission/status actions, and feeds granted
  permissions into the Rust `health_sync.dry_run` gate.
- Includes an instrumentation smoke harness for native loading, `core.version`,
  isolated `storage.check`, `protocol.parse_frame_hex`,
  `health_sync.dry_run`, and `privacy.lint`.

## Physical Device Workflow

1. Install and open the debug app on an Android phone.
2. Grant Bluetooth and location permissions.
3. Press `Scan`, then tap the WHOOP candidate when it appears.
4. Wait for `Ready; subscribed ...; hello sent`.
5. Optional but recommended for owned captures: press `Cap Start` before a
   controlled test and `Cap End` afterwards.
6. Press `Range` to confirm command writes, or `History` to request historical
   data. Use `Abort` if a history transfer should be stopped.
7. Use `HR`, `Sensors`, `Steps`, and `Sessions` for compact summaries instead
   of dumping large raw JSON in the UI.

The current build has captured live heart-rate packets and imported WHOOP
historical data from a physical WHOOP 5.0. Explicit step-counter extraction is
not confirmed yet; keep step tests as capture-session-bound evidence and resume
decoder work separately.

## Remaining Port Slices

- Replace the Java debug surface with a production Android UI once BLE and
  report behavior are stable.
- Add richer connection/history progress state and structured command results.
- Continue packet decoder work for step counters and other packet-derived
  metrics.
- Health Connect write adapter implementation after phone/platform permission
  testing.
- Export/debug/privacy screens equivalent to the iOS More tab.
- Kotlin/Compose UI migration once the bridge and BLE behavior are stable.
