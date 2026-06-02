# Goose Android

This is the Android port scaffold for Goose. It currently proves the shared
Rust core, JNI bridge, BLE scan/connect path, queued GATT operations, fixed
client-hello write, live notification parsing, SQLite capture import, and the
first Rust-backed Health/Debug report controls.

## Build

From the repository root:

```sh
Scripts/build_android_rust.sh
cd GooseAndroid
./gradlew :app:assembleDebug
```

Build the instrumentation smoke APK:

```sh
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
- Runs Rust-backed operational reports:
  - `metrics.input_readiness`
  - `capture.timeline`
  - `commands.definitions`
  - `commands.direct_send_gate`
  - `commands.direct_send_preflight`
  - `commands.list_validation_records`
  - `export.raw_timeframe`
- Includes an instrumentation smoke harness for native loading, `core.version`,
  isolated `storage.check`, and `protocol.parse_frame_hex`.

## Remaining Port Slices

- Device runtime testing with a physical Android phone and WHOOP strap.
- Historical sync commands and command validation UI.
- Health metric screens backed by stored packet-derived reports.
- Health Connect dry-run and eventual sync adapter.
- Export/debug/privacy screens equivalent to the iOS More tab.
- Kotlin/Compose UI migration once the bridge and BLE behavior are stable.
