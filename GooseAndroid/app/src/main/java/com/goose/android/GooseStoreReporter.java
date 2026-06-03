package com.goose.android;

import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.io.FileWriter;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

final class GooseStoreReporter {
    private static final long MAX_STEP_VALIDATION_AUDIT_BYTES = 256L * 1024L;

    interface Callback {
        void onReport(String report);
    }

    interface HealthConnectPlanCallback {
        void onReport(JSONObject report, String summary);
    }

    private final GooseRustBridge bridge = new GooseRustBridge();
    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final File exportDirectory;
    private final File healthSyncAuditFile;
    private final File stepValidationAuditFile;
    private final String databasePath;

    GooseStoreReporter(Context context, String databasePath) {
        this.databasePath = databasePath;
        File databaseDirectory = new File(databasePath).getParentFile();
        healthSyncAuditFile = new File(databaseDirectory != null ? databaseDirectory : context.getFilesDir(),
                "health-connect-sync-log.jsonl");
        stepValidationAuditFile = new File(databaseDirectory != null ? databaseDirectory : context.getFilesDir(),
                "step-validation-log.jsonl");
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

    void evidenceReadiness(Callback callback) {
        executor.execute(() -> callback.onReport(runEvidenceReadiness()));
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

    void stepValidation(
            String start,
            String end,
            long manualStepDelta,
            String captureSessionId,
            Callback callback
    ) {
        executor.execute(() -> callback.onReport(runStepValidation(
                start,
                end,
                manualStepDelta,
                captureSessionId)));
    }

    void recoverySensors(Callback callback) {
        executor.execute(() -> callback.onReport(runRecoverySensors()));
    }

    void unavailableStatuses(Callback callback) {
        executor.execute(() -> callback.onReport(runUnavailableStatuses()));
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
                .append("health sync audit: ").append(healthSyncAuditFile.getAbsolutePath()).append('\n')
                .append("health sync audit bytes: ").append(healthSyncAuditFile.length()).append('\n')
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

    private String runEvidenceReadiness() {
        SQLiteDatabase database = null;
        try {
            database = SQLiteDatabase.openDatabase(databasePath, null, SQLiteDatabase.OPEN_READONLY);
            int rawRows = countRows(database, "raw_evidence");
            int captureSessions = countRows(database, "capture_sessions");
            int decodedFrames = countRows(database, "decoded_frames");
            int stepSamples = countRows(database, "step_counter_samples");
            String latestCapture = latestValue(database, "raw_evidence", "captured_at");
            boolean strictReady = rawRows > 0 && captureSessions > 0;
            return "Android evidence readiness\n"
                    + "status: " + (strictReady ? "PASS" : "WAIT") + "\n"
                    + "database: " + databasePath + "\n"
                    + "raw evidence: " + rawRows + "\n"
                    + "capture sessions: " + captureSessions + "\n"
                    + "decoded frames: " + decodedFrames + "\n"
                    + "step samples: " + stepSamples + "\n"
                    + "latest capture: " + latestCapture + "\n"
                    + "health sync audit bytes: " + healthSyncAuditFile.length();
        } catch (Exception error) {
            return "Android evidence readiness\nstatus: FAIL\n" + error;
        } finally {
            if (database != null) {
                database.close();
            }
        }
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
        appendDailyActivityHealthConnectCandidates(candidates);
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

    private void appendDailyActivityHealthConnectCandidates(JSONArray candidates) throws Exception {
        JSONObject args = new JSONObject()
                .put("database_path", databasePath)
                .put("start_time_unix_ms", 0L)
                .put("end_time_unix_ms", System.currentTimeMillis() + 86400000L);
        JSONObject report = bridge.request("metrics.daily_activity_metrics", args);
        JSONArray metrics = report.optJSONArray("metrics");
        if (metrics == null) {
            return;
        }
        appendDailyActivityMetricCandidates(candidates, metrics);
    }

    static void appendDailyActivityMetricCandidates(JSONArray candidates, JSONArray metrics) throws Exception {
        for (int index = 0; index < metrics.length(); index += 1) {
            JSONObject metric = metrics.optJSONObject(index);
            if (metric == null) {
                continue;
            }
            String sourceKind = metric.optString("source_kind", "");
            long startTimeUnixMs = metric.optLong("start_time_unix_ms", -1L);
            long endTimeUnixMs = metric.optLong("end_time_unix_ms", -1L);
            if (startTimeUnixMs < 0L || endTimeUnixMs <= startTimeUnixMs) {
                continue;
            }
            String metricId = metric.optString("daily_metric_id", "");
            if (metricId.isEmpty()) {
                continue;
            }
            appendStepHealthConnectCandidate(candidates, metric, metricId, sourceKind,
                    startTimeUnixMs, endTimeUnixMs);
            appendActiveEnergyHealthConnectCandidate(candidates, metric, metricId, sourceKind,
                    startTimeUnixMs, endTimeUnixMs);
        }
    }

    private static void appendStepHealthConnectCandidate(
            JSONArray candidates,
            JSONObject metric,
            String metricId,
            String sourceKind,
            long startTimeUnixMs,
            long endTimeUnixMs
    ) throws Exception {
        if (metric.isNull("steps") || !"device_counter".equals(sourceKind)) {
            return;
        }
        long steps = metric.optLong("steps", 0L);
        if (steps <= 0L) {
            return;
        }
        candidates.put(dailyActivityCandidate(metric, metricId, sourceKind, startTimeUnixMs, endTimeUnixMs)
                .put("record_id", "android-steps-" + metricId)
                .put("semantic", "steps")
                .put("value", steps)
                .put("unit", "count")
                .put("algorithm_id", "goose.steps.device_counter.v0")
                .put("algorithm_version", "0.1.0"));
    }

    private static void appendActiveEnergyHealthConnectCandidate(
            JSONArray candidates,
            JSONObject metric,
            String metricId,
            String sourceKind,
            long startTimeUnixMs,
            long endTimeUnixMs
    ) throws Exception {
        if (metric.isNull("active_kcal") || !"local_estimate".equals(sourceKind)) {
            return;
        }
        double activeKcal = metric.optDouble("active_kcal", Double.NaN);
        if (!Double.isFinite(activeKcal) || activeKcal <= 0.0) {
            return;
        }
        candidates.put(dailyActivityCandidate(metric, metricId, sourceKind, startTimeUnixMs, endTimeUnixMs)
                .put("record_id", "android-active-energy-" + metricId)
                .put("semantic", "active_energy")
                .put("value", activeKcal)
                .put("unit", "kcal")
                .put("algorithm_id", "goose.energy.local_estimate.v0")
                .put("algorithm_version", "0.1.0"));
    }

    private static JSONObject dailyActivityCandidate(
            JSONObject metric,
            String metricId,
            String sourceKind,
            long startTimeUnixMs,
            long endTimeUnixMs
    ) throws Exception {
        return new JSONObject()
                .put("metric_family", "activity")
                .put("source_kind", "local_derived")
                .put("start_time", iso8601(startTimeUnixMs))
                .put("end_time", iso8601(endTimeUnixMs))
                .put("approved_by_user", true)
                .put("provenance", new JSONObject()
                        .put("input_source", "metrics.daily_activity_metrics")
                        .put("daily_metric_id", metricId)
                        .put("date_key", metric.optString("date_key", ""))
                        .put("timezone", metric.optString("timezone", ""))
                        .put("daily_metric_source_kind", sourceKind)
                        .put("confidence", metric.optDouble("confidence", 0.0)));
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
            Long parsedMillis = parseIso8601Millis(value);
            if (parsedMillis == null) {
                return value;
            }
            return iso8601(parsedMillis + (seconds * 1000L));
        } catch (Exception error) {
            return value;
        }
    }

    private Long parseIso8601Millis(String value) {
        String[] patterns = {
                "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
                "yyyy-MM-dd'T'HH:mm:ss'Z'"
        };
        for (String pattern : patterns) {
            try {
                java.text.SimpleDateFormat formatter = new java.text.SimpleDateFormat(
                        pattern,
                        java.util.Locale.US
                );
                formatter.setTimeZone(java.util.TimeZone.getTimeZone("UTC"));
                java.util.Date parsed = formatter.parse(value);
                if (parsed != null) {
                    return parsed.getTime();
                }
            } catch (Exception ignored) {
            }
        }
        return null;
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

    private static String iso8601(long millis) {
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

    private String runStepValidation(String start, String end, long manualStepDelta, String captureSessionId) {
        JSONObject report = null;
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
            if (captureSessionId != null && !captureSessionId.trim().isEmpty()) {
                args.put("capture_session_id", captureSessionId);
            }
            report = bridge.request("metrics.step_capture_validation", args);
            appendStepValidationAudit("completed", report, null);
            JSONObject selected = report.optJSONObject("selected_counter_delta");
            return "Step validation\n"
                    + "window: " + start + " -> " + end + "\n"
                    + "capture session: " + report.optString("capture_session_id", "not set") + "\n"
                    + "manual steps: " + manualStepDelta + "\n"
                    + "pass: " + report.optBoolean("pass", false) + "\n"
                    + "decoded frames: " + report.optInt("decoded_frame_count", 0) + "\n"
                    + "session decoded frames: " + report.optInt("capture_session_decoded_frame_count", 0) + "\n"
                    + "inspected frames: " + report.optInt("inspected_frame_count", 0) + "\n"
                    + "candidate fields: " + report.optInt("counter_candidate_count", 0) + "\n"
                    + "counter deltas: " + report.optInt("counter_delta_candidate_count", 0) + "\n"
                    + "selected delta: " + (selected != null ? selected.optLong("delta", 0) : "none") + "\n"
                    + "issues: " + report.optJSONArray("issues");
        } catch (Exception error) {
            appendStepValidationAudit("failed", report, String.valueOf(error));
            return "Step validation failed\n" + error;
        }
    }

    private void appendStepValidationAudit(String event, JSONObject report, String error) {
        try {
            File parent = stepValidationAuditFile.getParentFile();
            if (parent != null && !parent.exists() && !parent.mkdirs()) {
                return;
            }
            rotateStepValidationAuditIfNeeded();
            JSONObject row = new JSONObject()
                    .put("schema", "goose.android.step-validation-audit.v1")
                    .put("generated_by", "goose-android")
                    .put("created_at_unix_ms", System.currentTimeMillis())
                    .put("event", event);
            if (report != null) {
                JSONObject selected = report.optJSONObject("selected_counter_delta");
                row.put("capture_session_id", report.optString("capture_session_id", ""))
                        .put("start", report.optString("start", ""))
                        .put("end", report.optString("end", ""))
                        .put("manual_step_delta", report.opt("manual_step_delta"))
                        .put("pass", report.optBoolean("pass", false))
                        .put("decoded_frame_count", report.optInt("decoded_frame_count", 0))
                        .put("capture_session_decoded_frame_count",
                                report.optInt("capture_session_decoded_frame_count", 0))
                        .put("inspected_frame_count", report.optInt("inspected_frame_count", 0))
                        .put("counter_candidate_count", report.optInt("counter_candidate_count", 0))
                        .put("counter_delta_candidate_count", report.optInt("counter_delta_candidate_count", 0))
                        .put("selected_delta", selected != null ? selected.optLong("delta", 0) : JSONObject.NULL)
                        .put("issues", report.optJSONArray("issues"));
            }
            if (error != null) {
                row.put("error", error);
            }
            FileWriter writer = new FileWriter(stepValidationAuditFile, true);
            try {
                writer.write(row.toString());
                writer.write('\n');
            } finally {
                writer.close();
            }
        } catch (Exception ignored) {
        }
    }

    private void rotateStepValidationAuditIfNeeded() {
        if (!stepValidationAuditFile.exists() || stepValidationAuditFile.length() <= MAX_STEP_VALIDATION_AUDIT_BYTES) {
            return;
        }
        File rotated = new File(stepValidationAuditFile.getParentFile(), stepValidationAuditFile.getName() + ".old");
        if (rotated.exists() && !rotated.delete()) {
            return;
        }
        stepValidationAuditFile.renameTo(rotated);
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

    private String runUnavailableStatuses() {
        try {
            DailyWindow window = utcTodayWindow();
            JSONObject activity = bridge.request("metrics.activity_unavailable_daily_status",
                    new JSONObject()
                            .put("database_path", databasePath)
                            .put("date_key", window.dateKey)
                            .put("timezone", "UTC")
                            .put("start_time_unix_ms", window.startMillis)
                            .put("end_time_unix_ms", window.endMillis)
                            .put("write_metric", false));
            JSONObject energy = bridge.request("metrics.energy_unavailable_daily_status",
                    new JSONObject()
                            .put("database_path", databasePath)
                            .put("date_key", window.dateKey)
                            .put("timezone", "UTC")
                            .put("start", window.startIso)
                            .put("end", window.endIso)
                            .put("write_metric", false));
            JSONObject recovery = bridge.request("metrics.recovery_unavailable_daily_status",
                    new JSONObject()
                            .put("database_path", databasePath)
                            .put("date_key", window.dateKey)
                            .put("timezone", "UTC")
                            .put("start", window.startIso)
                            .put("end", window.endIso)
                            .put("write_metric", false));
            return "Blocked metric statuses\n"
                    + "date: " + window.dateKey + " UTC\n\n"
                    + unavailableSummary("activity", activity) + "\n\n"
                    + unavailableSummary("energy", energy) + "\n\n"
                    + unavailableSummary("recovery", recovery);
        } catch (Exception error) {
            return "Blocked metric statuses failed\n" + error;
        }
    }

    private String unavailableSummary(String label, JSONObject report) {
        return label + "\n"
                + "pass: " + report.optBoolean("pass", false) + "\n"
                + "unavailable: " + report.optInt("unavailable_metric_count", 0) + "\n"
                + "written: " + report.optInt("written_metric_count", 0) + "\n"
                + "issues: " + report.optJSONArray("issues") + "\n"
                + "next actions: " + report.optJSONArray("next_actions");
    }

    private static DailyWindow utcTodayWindow() {
        java.util.TimeZone utc = java.util.TimeZone.getTimeZone("UTC");
        java.util.Calendar calendar = java.util.Calendar.getInstance(utc, java.util.Locale.US);
        calendar.set(java.util.Calendar.HOUR_OF_DAY, 0);
        calendar.set(java.util.Calendar.MINUTE, 0);
        calendar.set(java.util.Calendar.SECOND, 0);
        calendar.set(java.util.Calendar.MILLISECOND, 0);
        long startMillis = calendar.getTimeInMillis();
        java.text.SimpleDateFormat dateFormatter = new java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US);
        dateFormatter.setTimeZone(utc);
        String dateKey = dateFormatter.format(calendar.getTime());
        calendar.add(java.util.Calendar.DAY_OF_MONTH, 1);
        long endMillis = calendar.getTimeInMillis();
        return new DailyWindow(
                dateKey,
                startMillis,
                endMillis,
                iso8601(startMillis),
                iso8601(endMillis)
        );
    }

    private static final class DailyWindow {
        final String dateKey;
        final long startMillis;
        final long endMillis;
        final String startIso;
        final String endIso;

        DailyWindow(String dateKey, long startMillis, long endMillis, String startIso, String endIso) {
            this.dateKey = dateKey;
            this.startMillis = startMillis;
            this.endMillis = endMillis;
            this.startIso = startIso;
            this.endIso = endIso;
        }
    }
}
