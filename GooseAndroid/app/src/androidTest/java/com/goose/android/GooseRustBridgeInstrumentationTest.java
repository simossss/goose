package com.goose.android;

import android.app.Instrumentation;
import android.content.Context;
import android.os.Bundle;
import android.os.Process;
import android.util.Log;

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
