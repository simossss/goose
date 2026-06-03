package com.goose.android;

import android.app.Instrumentation;
import android.content.Context;
import android.os.Bundle;
import android.os.Process;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;

public final class GooseRustBridgeInstrumentationTest extends Instrumentation {
    private static final String TAG = "GooseBridgeSmoke";

    @Override
    public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        start();
    }

    @Override
    public void onStart() {
        try {
            Log.i(TAG, "starting bridge smoke checks");
            startTimeoutWatchdog();
            runBridgeChecks(getTargetContext());
            Bundle results = new Bundle();
            results.putString("result", "passed");
            Log.i(TAG, "bridge smoke checks passed");
            finish(0, results);
        } catch (Throwable error) {
            Log.e(TAG, "bridge smoke checks failed", error);
            throw new RuntimeException(error);
        }
    }

    private void runBridgeChecks(Context context) throws Exception {
        GooseRustBridge bridge = new GooseRustBridge();
        Log.i(TAG, "calling core.version");
        JSONObject version = bridge.request("core.version");
        if (version.length() == 0) {
            throw new AssertionError("core.version returned an empty object");
        }

        Log.i(TAG, "calling storage.check");
        File databaseFile = new File(context.getCacheDir(), "goose-smoke.sqlite");
        if (databaseFile.exists() && !databaseFile.delete()) {
            throw new AssertionError("Could not delete stale smoke database: " + databaseFile);
        }
        JSONObject storageArgs = new JSONObject()
                .put("database_path", databaseFile.getAbsolutePath())
                .put("self_test", true);
        JSONObject storage = bridge.request("storage.check", storageArgs);
        if (!storage.optBoolean("pass", false)) {
            throw new AssertionError("storage.check did not pass: " + storage);
        }

        Log.i(TAG, "calling protocol.parse_frame_hex");
        JSONObject parseArgs = new JSONObject()
                .put("device_type", "Goose")
                .put("frame_hex", "aa0108000001e67123019101363e5c8d");
        bridge.request("protocol.parse_frame_hex", parseArgs);

        Log.i(TAG, "calling health_sync.dry_run");
        JSONObject healthSyncArgs = new JSONObject()
                .put("schema", "goose.health-sync-dry-run-input.v1")
                .put("platform", "health_connect")
                .put("permission_grants", new JSONArray())
                .put("backfill", new JSONObject()
                        .put("start", "2026-01-01T00:00:00.000Z")
                        .put("end", "2026-01-02T00:00:00.000Z"))
                .put("candidates", new JSONArray())
                .put("existing_records", new JSONArray())
                .put("partial_plan_policy", "require_all_records_ready")
                .put("delete_policy", "none");
        JSONObject healthSync = bridge.request("health_sync.dry_run", healthSyncArgs);
        if (!"goose.health-sync-dry-run-report.v1".equals(healthSync.optString("schema"))) {
            throw new AssertionError("health_sync.dry_run returned unexpected schema: " + healthSync);
        }

        Log.i(TAG, "calling privacy.lint");
        File lintDir = new File(context.getCacheDir(), "goose-smoke-privacy");
        if (!lintDir.exists() && !lintDir.mkdirs()) {
            throw new AssertionError("Could not create privacy lint directory: " + lintDir);
        }
        JSONObject privacyLint = bridge.request("privacy.lint",
                new JSONObject().put("path", lintDir.getAbsolutePath()));
        if (privacyLint.length() == 0) {
            throw new AssertionError("privacy.lint returned an empty object");
        }
    }

    private void startTimeoutWatchdog() {
        Thread watchdog = new Thread(() -> {
            try {
                Thread.sleep(15000);
                Log.e(TAG, "bridge smoke checks timed out");
                Bundle results = new Bundle();
                results.putString("error", "bridge smoke checks timed out");
                finish(1, results);
                Process.killProcess(Process.myPid());
            } catch (InterruptedException ignored) {
            }
        }, "goose-smoke-watchdog");
        watchdog.setDaemon(true);
        watchdog.start();
    }
}
