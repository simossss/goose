package com.goose.android;

import android.content.Context;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

final class GooseStoreReporter {
    interface Callback {
        void onReport(String report);
    }

    private final GooseRustBridge bridge = new GooseRustBridge();
    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final File exportDirectory;
    private final String databasePath;

    GooseStoreReporter(Context context, String databasePath) {
        this.databasePath = databasePath;
        exportDirectory = new File(context.getFilesDir(), "exports");
        if (!exportDirectory.exists()) {
            exportDirectory.mkdirs();
        }
    }

    void readiness(Callback callback) {
        executor.execute(() -> callback.onReport(runReadiness()));
    }

    void captureTimeline(Callback callback) {
        executor.execute(() -> callback.onReport(runCaptureTimeline()));
    }

    void commandDefinitions(Callback callback) {
        executor.execute(() -> callback.onReport(runCommandDefinitions()));
    }

    void commandGate(Callback callback) {
        executor.execute(() -> callback.onReport(runCommandGate()));
    }

    void commandPreflight(Callback callback) {
        executor.execute(() -> callback.onReport(runCommandPreflight()));
    }

    void commandValidationRecords(Callback callback) {
        executor.execute(() -> callback.onReport(runCommandValidationRecords()));
    }

    void rawExport(Callback callback) {
        executor.execute(() -> callback.onReport(runRawExport()));
    }

    void close() {
        executor.shutdownNow();
    }

    private String runReadiness() {
        try {
            JSONObject args = new JSONObject()
                    .put("database_path", databasePath)
                    .put("start", "0000")
                    .put("end", "9999")
                    .put("min_owned_captures", 2)
                    .put("require_owned_captures", false)
                    .put("require_scores_ready", true);
            JSONObject report = bridge.request("metrics.input_readiness", args);
            return "Packet readiness\n" + report.toString(2);
        } catch (Exception error) {
            return "Packet readiness failed\n" + error;
        }
    }

    private String runCaptureTimeline() {
        try {
            JSONObject args = new JSONObject()
                    .put("database_path", databasePath)
                    .put("start", "0000")
                    .put("end", "9999");
            JSONObject report = bridge.request("capture.timeline", args);
            return "Capture timeline\n" + report.toString(2);
        } catch (Exception error) {
            return "Capture timeline failed\n" + error;
        }
    }

    private String runCommandDefinitions() {
        try {
            JSONObject report = bridge.request("commands.definitions");
            return "Command definitions\n" + report.toString(2);
        } catch (Exception error) {
            return "Command definitions failed\n" + error;
        }
    }

    private String runCommandGate() {
        try {
            JSONObject args = new JSONObject()
                    .put("database_path", databasePath)
                    .put("command", "get_hello");
            JSONObject report = bridge.request("commands.direct_send_gate", args);
            return "Command gate: get_hello\n" + report.toString(2);
        } catch (Exception error) {
            return "Command gate failed\n" + error;
        }
    }

    private String runCommandPreflight() {
        try {
            JSONObject args = new JSONObject()
                    .put("database_path", databasePath)
                    .put("command", "get_hello")
                    .put("now_unix_ms", System.currentTimeMillis())
                    .put("visible_user_intent", true)
                    .put("dry_run_bytes_shown", true)
                    .put("dry_run_frame_hex", "aa0108000001e67123019101363e5c8d")
                    .put("dry_run_service_uuid", "fd4b0001-cce1-4033-93ce-002d5875f58a")
                    .put("dry_run_characteristic_uuid", "fd4b0002-cce1-4033-93ce-002d5875f58a")
                    .put("dry_run_write_type", "withResponse")
                    .put("session_log_ready", true)
                    .put("connection_state", "dry_run");
            JSONObject report = bridge.request("commands.direct_send_preflight", args);
            return "Command preflight: get_hello\n" + report.toString(2);
        } catch (Exception error) {
            return "Command preflight failed\n" + error;
        }
    }

    private String runCommandValidationRecords() {
        try {
            JSONObject args = new JSONObject()
                    .put("database_path", databasePath);
            JSONObject report = bridge.request("commands.list_validation_records", args);
            return "Command validation records\n" + report.toString(2);
        } catch (Exception error) {
            return "Command validation records failed\n" + error;
        }
    }

    private String runRawExport() {
        try {
            long now = System.currentTimeMillis();
            File outputDir = new File(exportDirectory, "goose-raw-export-" + now);
            File zipOutput = new File(exportDirectory, "goose-raw-export-" + now + ".zip");
            JSONObject args = new JSONObject()
                    .put("database_path", databasePath)
                    .put("output_dir", outputDir.getAbsolutePath())
                    .put("zip_output_path", zipOutput.getAbsolutePath())
                    .put("start", "0000")
                    .put("end", "9999")
                    .put("app_version", "goose-android-0.1.0")
                    .put("core_version", "android-bridge")
                    .put("include_sqlite", true)
                    .put("data_families", new JSONArray()
                            .put("raw_evidence")
                            .put("decoded_frames")
                            .put("packet_timeline")
                            .put("metric_inputs")
                            .put("algorithm_runs")
                            .put("sqlite"))
                    .put("include_raw_bytes", true);
            JSONObject report = bridge.request("export.raw_timeframe", args);
            return "Raw export\n" + report.toString(2);
        } catch (Exception error) {
            return "Raw export failed\n" + error;
        }
    }
}
