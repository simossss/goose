package com.goose.android;

import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

final class GooseStoreReporter {
    interface Callback {
        void onReport(String report);
    }

    interface HealthConnectPlanCallback {
        void onReport(JSONObject report, String summary);
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

    void storagePrivacy(Callback callback) {
        executor.execute(() -> callback.onReport(runStoragePrivacy()));
    }

    void healthConnectDryRun(List<String> permissionGrants, Callback callback) {
        executor.execute(() -> callback.onReport(runHealthConnectDryRun(permissionGrants)));
    }

    void healthConnectDryRunPlan(List<String> permissionGrants, HealthConnectPlanCallback callback) {
        executor.execute(() -> {
            try {
                JSONObject report = healthConnectDryRunReport(permissionGrants);
                callback.onReport(report, healthConnectDryRunSummary(report, permissionGrants, false));
            } catch (Exception error) {
                callback.onReport(null, "Health Connect dry run failed\n" + error);
            }
        });
    }

    void exportPrivacyLint(Callback callback) {
        executor.execute(() -> callback.onReport(runExportPrivacyLint()));
    }

    void exportInventory(Callback callback) {
        executor.execute(() -> callback.onReport(runExportInventory()));
    }

    void clearExports(Callback callback) {
        executor.execute(() -> callback.onReport(runClearExports()));
    }

    void clearLocalData(Callback callback) {
        executor.execute(() -> callback.onReport(runClearLocalData()));
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

    void stepValidation(String start, String end, long manualStepDelta, Callback callback) {
        executor.execute(() -> callback.onReport(runStepValidation(start, end, manualStepDelta)));
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
            String validation = validateExport(zipOutput.exists() ? zipOutput : outputDir);
            String lint = lintPath(zipOutput.exists() ? zipOutput : outputDir);
            return "Raw export\n"
                    + exportSummary(report, outputDir, zipOutput)
                    + "\n\n" + validation
                    + "\n\n" + lint;
        } catch (Exception error) {
            return "Raw export failed\n" + error;
        }
    }

    private String runStoragePrivacy() {
        StringBuilder builder = new StringBuilder("Storage and privacy\n")
                .append("database: ").append(databasePath).append('\n')
                .append("database bytes: ").append(new File(databasePath).length()).append('\n')
                .append("export directory: ").append(exportDirectory.getAbsolutePath()).append('\n')
                .append("export files: ").append(exportFileCount()).append('\n');
        SQLiteDatabase database = null;
        try {
            database = SQLiteDatabase.openDatabase(databasePath, null, SQLiteDatabase.OPEN_READONLY);
            builder.append("raw evidence: ").append(countRows(database, "raw_evidence")).append('\n')
                    .append("decoded frames: ").append(countRows(database, "decoded_frames")).append('\n')
                    .append("capture sessions: ").append(countRows(database, "capture_sessions")).append('\n')
                    .append("step samples: ").append(countRows(database, "step_counter_samples")).append('\n')
                    .append("activity sessions: ").append(countRows(database, "activity_sessions")).append('\n')
                    .append("latest capture: ").append(latestValue(database, "raw_evidence", "captured_at")).append('\n')
                    .append("raw byte policy: local app storage; raw exports include bytes only after tapping Export\n")
                    .append("delete controls: Clear Exports removes generated bundles; Clear Data requires a second tap");
        } catch (Exception error) {
            builder.append("storage summary failed: ").append(error);
        } finally {
            if (database != null) {
                database.close();
            }
        }
        return builder.toString();
    }

    private String runHealthConnectDryRun(List<String> permissionGrants) {
        try {
            JSONObject report = healthConnectDryRunReport(permissionGrants);
            return healthConnectDryRunSummary(report, permissionGrants, true);
        } catch (Exception error) {
            return "Health Connect dry run failed\n" + error;
        }
    }

    private JSONObject healthConnectDryRunReport(List<String> permissionGrants) throws Exception {
        long now = System.currentTimeMillis();
        JSONArray grants = new JSONArray();
        for (String grant : permissionGrants) {
            grants.put(grant);
        }
        JSONArray candidates = healthConnectCandidates();
        String start = iso8601(now - 86400000L);
        String end = iso8601(now);
        if (candidates.length() > 0) {
            String[] window = candidateWindow(candidates);
            start = window[0];
            end = window[1];
        }
        JSONObject args = new JSONObject()
                .put("schema", "goose.health-sync-dry-run.v1")
                .put("platform", "health_connect")
                .put("permission_grants", grants)
                .put("backfill", new JSONObject()
                        .put("start", start)
                        .put("end", end))
                .put("candidates", candidates)
                .put("existing_records", new JSONArray())
                .put("partial_plan_policy", "require_all_records_ready")
                .put("delete_policy", "none");
        return bridge.request("health_sync.dry_run", args);
    }

    private JSONArray healthConnectCandidates() throws Exception {
        JSONArray candidates = new JSONArray();
        appendHeartRateHealthConnectCandidates(candidates);
        return candidates;
    }

    private void appendHeartRateHealthConnectCandidates(JSONArray candidates) throws Exception {
        JSONObject args = new JSONObject()
                .put("database_path", databasePath)
                .put("start", "0000")
                .put("end", "9999")
                .put("min_owned_captures", 1)
                .put("require_trusted_evidence", true);
        JSONObject report = bridge.request("metrics.heart_rate_features", args);
        JSONArray features = report.optJSONArray("features");
        if (features == null) {
            return;
        }
        for (int index = 0; index < features.length(); index += 1) {
            JSONObject feature = features.optJSONObject(index);
            if (feature == null || !feature.optBoolean("trusted_metric_input", false)) {
                continue;
            }
            String sampleTime = feature.optString("sample_time", "");
            if (sampleTime.isEmpty()) {
                sampleTime = feature.optString("captured_at", "");
            }
            if (sampleTime.isEmpty()) {
                continue;
            }
            double bpm = feature.optDouble("heart_rate_bpm", Double.NaN);
            if (!Double.isFinite(bpm) || bpm <= 0.0) {
                continue;
            }
            String endTime = addSecondsToIso8601(sampleTime, 5);
            candidates.put(new JSONObject()
                    .put("record_id", "android-heart-rate-" + feature.optString("metric_input_id"))
                    .put("metric_family", "heart_rate")
                    .put("semantic", "heart_rate")
                    .put("source_kind", "decoded_raw")
                    .put("start_time", sampleTime)
                    .put("end_time", endTime)
                    .put("value", bpm)
                    .put("unit", "count/min")
                    .put("approved_by_user", true)
                    .put("provenance", new JSONObject()
                            .put("input_source", "metrics.heart_rate_features")
                            .put("metric_input_id", feature.optString("metric_input_id"))
                            .put("frame_id", feature.optString("frame_id"))
                            .put("evidence_id", feature.optString("evidence_id"))
                            .put("sample_time_source", feature.optString("sample_time_source"))
                            .put("trusted_metric_input", true)));
        }
    }

    private String[] candidateWindow(JSONArray candidates) {
        String start = null;
        String end = null;
        for (int index = 0; index < candidates.length(); index += 1) {
            JSONObject candidate = candidates.optJSONObject(index);
            if (candidate == null) {
                continue;
            }
            String candidateStart = candidate.optString("start_time", "");
            String candidateEnd = candidate.optString("end_time", "");
            if (!candidateStart.isEmpty() && (start == null || candidateStart.compareTo(start) < 0)) {
                start = candidateStart;
            }
            if (!candidateEnd.isEmpty() && (end == null || candidateEnd.compareTo(end) > 0)) {
                end = candidateEnd;
            }
        }
        if (start == null || end == null) {
            long now = System.currentTimeMillis();
            return new String[]{iso8601(now - 86400000L), iso8601(now)};
        }
        return new String[]{start, end};
    }

    private String addSecondsToIso8601(String value, long seconds) {
        try {
            return iso8601(java.time.Instant.parse(value).toEpochMilli() + (seconds * 1000L));
        } catch (Exception error) {
            return value;
        }
    }

    private String healthConnectDryRunSummary(
            JSONObject report,
            List<String> permissionGrants,
            boolean includeAdapterStatus
    ) {
        StringBuilder builder = new StringBuilder("Health Connect dry run\n")
                .append("pass: ").append(report.optBoolean("pass", false)).append('\n')
                .append("all records ready: ").append(report.optBoolean("all_records_ready", false)).append('\n')
                .append("permissions ready: ").append(report.optBoolean("permissions_ready", false)).append('\n')
                .append("permission grants: ").append(permissionGrants.size()).append('\n')
                .append("candidate writes: ").append(report.optInt("candidate_count", 0)).append('\n')
                .append("planned writes: ").append(report.optInt("planned_write_count", 0)).append('\n')
                .append("blocked: ").append(report.optInt("blocked_count", 0)).append('\n')
                .append("issues: ").append(report.optJSONArray("issues"));
        if (includeAdapterStatus) {
            builder.append("\nstatus: Android Health Connect adapter is available through Sync when planned writes are ready");
        }
        return builder.toString();
    }

    private String runExportPrivacyLint() {
        return "Export/privacy lint\n"
                + lintPath(exportDirectory)
                + "\n\nRecent exports\n"
                + recentExportsSummary();
    }

    private String runExportInventory() {
        StringBuilder builder = new StringBuilder("Export inventory\n")
                .append("directory: ").append(exportDirectory.getAbsolutePath()).append('\n')
                .append("files: ").append(exportFileCount()).append('\n')
                .append("bytes: ").append(directoryBytes(exportDirectory)).append('\n')
                .append("recent exports\n")
                .append(recentExportsSummary());
        return builder.toString();
    }

    private String runClearExports() {
        DeleteStats stats = deleteChildren(exportDirectory);
        if (!exportDirectory.exists()) {
            exportDirectory.mkdirs();
        }
        return "Clear exports\n"
                + "directory: " + exportDirectory.getAbsolutePath() + "\n"
                + "deleted files: " + stats.deletedFiles + "\n"
                + "deleted directories: " + stats.deletedDirectories + "\n"
                + "freed bytes: " + stats.deletedBytes + "\n"
                + "failed deletes: " + stats.failedDeletes;
    }

    private String runClearLocalData() {
        File databaseFile = new File(databasePath);
        File parent = databaseFile.getParentFile();
        long beforeBytes = databaseFile.exists() ? databaseFile.length() : 0;
        DeleteStats stats = new DeleteStats();
        deleteFile(databaseFile, stats);
        deleteFile(new File(databasePath + "-wal"), stats);
        deleteFile(new File(databasePath + "-shm"), stats);
        deleteFile(new File(databasePath + "-journal"), stats);
        if (parent != null && !parent.exists()) {
            parent.mkdirs();
        }
        String storageCheck = runStorageCheckAfterClear();
        return "Clear local data\n"
                + "database: " + databasePath + "\n"
                + "database bytes before: " + beforeBytes + "\n"
                + "deleted files: " + stats.deletedFiles + "\n"
                + "freed bytes: " + stats.deletedBytes + "\n"
                + "failed deletes: " + stats.failedDeletes + "\n\n"
                + storageCheck;
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

    private String validateExport(File path) {
        try {
            JSONObject report = bridge.request("export.validate_bundle",
                    new JSONObject().put("path", path.getAbsolutePath()));
            return "Export validation\n"
                    + "path: " + path.getAbsolutePath() + "\n"
                    + "pass: " + report.optBoolean("pass", false) + "\n"
                    + "issues: " + report.optJSONArray("issues");
        } catch (Exception error) {
            return "Export validation failed\n" + error;
        }
    }

    private String lintPath(File path) {
        try {
            JSONObject report = bridge.request("privacy.lint",
                    new JSONObject().put("path", path.getAbsolutePath()));
            return "Privacy lint\n"
                    + "path: " + path.getAbsolutePath() + "\n"
                    + "pass: " + report.optBoolean("pass", false) + "\n"
                    + "findings: " + report.optInt("finding_count", 0) + "\n"
                    + "issues: " + report.optJSONArray("issues");
        } catch (Exception error) {
            return "Privacy lint failed\n" + error;
        }
    }

    private String exportSummary(JSONObject report, File outputDir, File zipOutput) {
        return "output dir: " + outputDir.getAbsolutePath() + "\n"
                + "zip: " + zipOutput.getAbsolutePath() + "\n"
                + "pass: " + report.optBoolean("pass", false) + "\n"
                + "manifest files: " + report.optInt("file_count", 0) + "\n"
                + "issues: " + report.optJSONArray("issues");
    }

    private int countRows(SQLiteDatabase database, String table) {
        try (Cursor cursor = database.rawQuery("SELECT COUNT(*) FROM " + table, null)) {
            return cursor.moveToFirst() ? cursor.getInt(0) : 0;
        }
    }

    private String latestValue(SQLiteDatabase database, String table, String column) {
        try (Cursor cursor = database.rawQuery(
                "SELECT " + column + " FROM " + table + " ORDER BY " + column + " DESC LIMIT 1",
                null
        )) {
            return cursor.moveToFirst() ? cursor.getString(0) : "none";
        }
    }

    private int exportFileCount() {
        File[] files = exportDirectory.listFiles();
        return files == null ? 0 : files.length;
    }

    private long directoryBytes(File path) {
        if (!path.exists()) {
            return 0L;
        }
        if (path.isFile()) {
            return path.length();
        }
        long total = 0L;
        File[] files = path.listFiles();
        if (files == null) {
            return total;
        }
        for (File file : files) {
            total += directoryBytes(file);
        }
        return total;
    }

    private String recentExportsSummary() {
        File[] files = exportDirectory.listFiles();
        if (files == null || files.length == 0) {
            return "No exports";
        }
        java.util.Arrays.sort(files, (left, right) -> Long.compare(right.lastModified(), left.lastModified()));
        StringBuilder builder = new StringBuilder();
        int count = Math.min(files.length, 8);
        for (int index = 0; index < count; index += 1) {
            File file = files[index];
            if (index > 0) {
                builder.append('\n');
            }
            builder.append(file.getName())
                    .append("  ")
                    .append(file.isDirectory() ? "dir" : file.length() + " bytes");
        }
        return builder.toString();
    }

    private String runStorageCheckAfterClear() {
        try {
            JSONObject args = new JSONObject()
                    .put("database_path", databasePath)
                    .put("self_test", true);
            JSONObject report = bridge.request("storage.check", args);
            return "Storage recheck\n"
                    + "pass: " + report.optBoolean("pass", false) + "\n"
                    + "schema: " + report.optInt("actual_schema_version", -1)
                    + " / expected " + report.optInt("expected_schema_version", -1)
                    + "\nissues: " + report.optJSONArray("issues");
        } catch (Exception error) {
            return "Storage recheck failed\n" + error;
        }
    }

    private DeleteStats deleteChildren(File directory) {
        DeleteStats stats = new DeleteStats();
        File[] files = directory.listFiles();
        if (files == null) {
            return stats;
        }
        for (File file : files) {
            deletePath(file, stats);
        }
        return stats;
    }

    private void deletePath(File path, DeleteStats stats) {
        if (path.isDirectory()) {
            File[] children = path.listFiles();
            if (children != null) {
                for (File child : children) {
                    deletePath(child, stats);
                }
            }
            if (path.delete()) {
                stats.deletedDirectories += 1;
            } else if (path.exists()) {
                stats.failedDeletes += 1;
            }
            return;
        }
        deleteFile(path, stats);
    }

    private void deleteFile(File file, DeleteStats stats) {
        if (!file.exists()) {
            return;
        }
        long bytes = file.length();
        if (file.delete()) {
            stats.deletedFiles += 1;
            stats.deletedBytes += bytes;
        } else {
            stats.failedDeletes += 1;
        }
    }

    private static final class DeleteStats {
        int deletedFiles;
        int deletedDirectories;
        int failedDeletes;
        long deletedBytes;
    }

    private String iso8601(long millis) {
        java.text.SimpleDateFormat formatter = new java.text.SimpleDateFormat(
                "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
                java.util.Locale.US
        );
        formatter.setTimeZone(java.util.TimeZone.getTimeZone("UTC"));
        return formatter.format(new java.util.Date(millis));
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

    private String runStepValidation(String start, String end, long manualStepDelta) {
        try {
            JSONObject args = new JSONObject()
                    .put("database_path", databasePath)
                    .put("start", start)
                    .put("end", end)
                    .put("max_candidate_fields", 5000)
                    .put("capture_kind", "android_counted_steps")
                    .put("manual_step_delta", manualStepDelta)
                    .put("tolerance_steps", 10)
                    .put("label_provenance", new JSONObject()
                            .put("label_source", "android_manual_count")
                            .put("capture_app", "goose_android")
                            .put("owner", "user"));
            JSONObject report = bridge.request("metrics.step_capture_validation", args);
            JSONObject selected = report.optJSONObject("selected_counter_delta");
            return "Step validation\n"
                    + "window: " + start + " -> " + end + "\n"
                    + "manual steps: " + manualStepDelta + "\n"
                    + "pass: " + report.optBoolean("pass", false) + "\n"
                    + "inspected frames: " + report.optInt("inspected_frame_count", 0) + "\n"
                    + "candidate fields: " + report.optInt("counter_candidate_count", 0) + "\n"
                    + "counter deltas: " + report.optInt("counter_delta_candidate_count", 0) + "\n"
                    + "selected delta: " + (selected != null ? selected.optLong("delta", 0) : "none") + "\n"
                    + "issues: " + report.optJSONArray("issues");
        } catch (Exception error) {
            return "Step validation failed\n" + error;
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
