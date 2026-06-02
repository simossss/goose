package com.goose.android;

import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;

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

    void decodeBackfill(Callback callback) {
        executor.execute(() -> callback.onReport(runDecodeBackfill()));
    }

    void heartRateFeatures(Callback callback) {
        executor.execute(() -> callback.onReport(runHeartRateFeatures()));
    }

    void stepDiscovery(Callback callback) {
        executor.execute(() -> callback.onReport(runStepDiscovery()));
    }

    void recoverySensors(Callback callback) {
        executor.execute(() -> callback.onReport(runRecoverySensors()));
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

    private String runDecodeBackfill() {
        try {
            JSONArray frames = pendingGooseRawFrames();
            if (frames.length() == 0) {
                return "Decode backfill\nNo raw Goose frames pending decode.";
            }
            JSONObject args = new JSONObject()
                    .put("database_path", databasePath)
                    .put("parser_version", "goose-android/backfill")
                    .put("include_timeline_rows", false)
                    .put("compact_raw_payloads", false)
                    .put("include_results", false)
                    .put("frames", frames);
            JSONObject report = bridge.request("capture.import_frame_batch", args);
            return "Decode backfill\n"
                    + "pending batch: " + frames.length() + "\n"
                    + "raw inserted: " + report.optInt("raw_inserted", 0) + "\n"
                    + "raw existing: " + report.optInt("raw_existing", 0) + "\n"
                    + "decoded inserted: " + report.optInt("frames_inserted", 0) + "\n"
                    + "decoded existing: " + report.optInt("frames_existing", 0) + "\n"
                    + "issues: " + report.optJSONArray("issues");
        } catch (Exception error) {
            return "Decode backfill failed\n" + error;
        }
    }

    private JSONArray pendingGooseRawFrames() throws Exception {
        JSONArray frames = new JSONArray();
        SQLiteDatabase database = SQLiteDatabase.openDatabase(databasePath, null, SQLiteDatabase.OPEN_READONLY);
        try (Cursor cursor = database.rawQuery(
                "SELECT r.evidence_id, r.source, r.captured_at, r.device_model, r.payload_hex, r.sensitivity "
                        + "FROM raw_evidence r "
                        + "LEFT JOIN decoded_frames d ON d.evidence_id = r.evidence_id "
                        + "WHERE d.evidence_id IS NULL AND lower(r.payload_hex) LIKE 'aa%' "
                        + "ORDER BY r.created_at LIMIT 500",
                null
        )) {
            while (cursor.moveToNext()) {
                String evidenceId = cursor.getString(0);
                JSONObject frame = new JSONObject()
                        .put("evidence_id", evidenceId)
                        .put("frame_id", evidenceId + ".backfill.0")
                        .put("source", cursor.getString(1))
                        .put("captured_at", cursor.getString(2))
                        .put("device_model", cursor.getString(3))
                        .put("frame_hex", cursor.getString(4))
                        .put("sensitivity", cursor.getString(5))
                        .put("capture_session_id", JSONObject.NULL)
                        .put("device_type", "GOOSE");
                frames.put(frame);
            }
        } finally {
            database.close();
        }
        return frames;
    }

    private String runHeartRateFeatures() {
        try {
            JSONObject args = new JSONObject()
                    .put("database_path", databasePath)
                    .put("start", "0000")
                    .put("end", "9999");
            JSONObject report = bridge.request("metrics.heart_rate_features", args);
            return "Heart-rate features\n"
                    + "pass: " + report.optBoolean("pass", false) + "\n"
                    + "candidate frames: " + report.optInt("candidate_frame_count", 0) + "\n"
                    + "features: " + report.optInt("feature_count", 0) + "\n"
                    + "trusted features: " + report.optInt("trusted_feature_count", 0) + "\n"
                    + "issues: " + report.optJSONArray("issues");
        } catch (Exception error) {
            return "Heart-rate features failed\n" + error;
        }
    }

    private String runStepDiscovery() {
        try {
            JSONObject args = new JSONObject()
                    .put("database_path", databasePath)
                    .put("start", "0000")
                    .put("end", "9999")
                    .put("max_candidate_fields", 5000);
            JSONObject report = bridge.request("metrics.step_packet_discovery", args);
            return "Step discovery\n"
                    + "pass: " + report.optBoolean("pass", false) + "\n"
                    + "decoded frames: " + report.optInt("decoded_frame_count", 0) + "\n"
                    + "inspected frames: " + report.optInt("inspected_frame_count", 0) + "\n"
                    + "candidate fields: " + report.optInt("candidate_field_count", 0) + "\n"
                    + "counter deltas: " + report.optInt("counter_delta_candidate_count", 0) + "\n"
                    + "issues: " + report.optJSONArray("issues");
        } catch (Exception error) {
            return "Step discovery failed\n" + error;
        }
    }

    private String runRecoverySensors() {
        try {
            JSONObject args = new JSONObject()
                    .put("database_path", databasePath)
                    .put("start", "0000")
                    .put("end", "9999");
            JSONObject report = bridge.request("metrics.recovery_sensor_discovery", args);
            JSONObject hrv = report.optJSONObject("hrv_report");
            JSONObject vitals = report.optJSONObject("vital_event_report");
            return "Recovery sensors\n"
                    + "pass: " + report.optBoolean("pass", false) + "\n"
                    + "HRV RR intervals: " + (hrv != null ? hrv.optInt("rr_interval_count", 0) : 0) + "\n"
                    + "vital data packets: " + (vitals != null ? vitals.optInt("data_packet_frame_count", 0) : 0) + "\n"
                    + "respiratory candidates: " + (vitals != null ? vitals.optInt("respiratory_rate_input_count", 0) : 0) + "\n"
                    + "temperature candidates: " + (vitals != null ? vitals.optInt("skin_temperature_input_count", 0) : 0) + "\n"
                    + "issues: " + report.optJSONArray("issues");
        } catch (Exception error) {
            return "Recovery sensors failed\n" + error;
        }
    }
}
