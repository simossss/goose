package com.goose.android;

import android.app.Instrumentation;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.content.pm.ApplicationInfo;
import android.content.pm.FeatureInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.health.connect.datatypes.ActiveCaloriesBurnedRecord;
import android.health.connect.datatypes.HeartRateRecord;
import android.health.connect.datatypes.Record;
import android.health.connect.datatypes.StepsRecord;
import android.os.Build;
import android.os.Bundle;
import android.os.Process;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.FileWriter;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

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
        JSONObject directVersion = new JSONObject(bridge.versionJson());
        if (!version.optString("schema").equals(directVersion.optString("schema"))
                || !version.optString("version").equals(directVersion.optString("version"))) {
            throw new AssertionError("nativeVersionJson disagrees with core.version: " + directVersion);
        }

        Log.i(TAG, "checking structured bridge errors");
        try {
            bridge.request("android.smoke.unknown_method");
            throw new AssertionError("unknown bridge method unexpectedly succeeded");
        } catch (Exception error) {
            if (error.getMessage() == null || !error.getMessage().contains("unsupported bridge method")) {
                throw new AssertionError("unknown method did not surface structured bridge error", error);
            }
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
        Log.i(TAG, "checking Android capture session raw evidence tagging");
        assertAndroidCaptureSessionTagging(context);

        Log.i(TAG, "calling unavailable metric status reports");
        assertUnavailableStatusReports(bridge, databaseFile);

        Log.i(TAG, "calling protocol.parse_frame_hex");
        JSONObject parseArgs = new JSONObject()
                .put("device_type", "Goose")
                .put("frame_hex", "aa0108000001e67123019101363e5c8d");
        bridge.request("protocol.parse_frame_hex", parseArgs);

        Log.i(TAG, "calling health_sync.dry_run");
        JSONObject healthSyncArgs = new JSONObject()
                .put("schema", "goose.health-sync-dry-run.v1")
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
        JSONArray healthSyncIssues = healthSync.optJSONArray("issues");
        if (!healthSync.optBoolean("pass", false)
                || healthSyncIssues == null
                || healthSyncIssues.length() != 0) {
            throw new AssertionError("health_sync.dry_run did not pass cleanly: " + healthSync);
        }

        Log.i(TAG, "calling Android Health Connect candidate mapper");
        JSONArray dailyActivityMetrics = new JSONArray()
                .put(new JSONObject()
                        .put("daily_metric_id", "daily-activity-steps-2026-01-01-utc-device-counter-v0")
                        .put("date_key", "2026-01-01")
                        .put("timezone", "UTC")
                        .put("start_time_unix_ms", 1767225600000L)
                        .put("end_time_unix_ms", 1767312000000L)
                        .put("steps", 1234)
                        .put("active_kcal", JSONObject.NULL)
                        .put("source_kind", "device_counter")
                        .put("confidence", 0.91))
                .put(new JSONObject()
                        .put("daily_metric_id", "daily-activity-energy-2026-01-01-utc-local-estimate-v0")
                        .put("date_key", "2026-01-01")
                        .put("timezone", "UTC")
                        .put("start_time_unix_ms", 1767225600000L)
                        .put("end_time_unix_ms", 1767312000000L)
                        .put("steps", JSONObject.NULL)
                        .put("active_kcal", 321.5)
                        .put("source_kind", "local_estimate")
                        .put("confidence", 0.74))
                .put(new JSONObject()
                        .put("daily_metric_id", "imported-steps")
                        .put("date_key", "2026-01-01")
                        .put("timezone", "UTC")
                        .put("start_time_unix_ms", 1767225600000L)
                        .put("end_time_unix_ms", 1767312000000L)
                        .put("steps", 999)
                        .put("source_kind", "platform_import")
                        .put("confidence", 1.0));
        JSONArray candidates = new JSONArray();
        GooseStoreReporter.appendDailyActivityMetricCandidates(candidates, dailyActivityMetrics);
        if (candidates.length() != 2) {
            throw new AssertionError("daily activity mapper produced unexpected candidates: " + candidates);
        }
        JSONObject plannedDailyActivity = bridge.request("health_sync.dry_run", new JSONObject()
                .put("schema", "goose.health-sync-dry-run.v1")
                .put("platform", "health_connect")
                .put("permission_grants", new JSONArray()
                        .put("StepsRecord")
                        .put("ActiveCaloriesBurnedRecord"))
                .put("backfill", new JSONObject()
                        .put("start", "2026-01-01T00:00:00.000Z")
                        .put("end", "2026-01-02T00:00:00.000Z"))
                .put("candidates", candidates)
                .put("existing_records", new JSONArray())
                .put("partial_plan_policy", "require_all_records_ready")
                .put("delete_policy", "none"));
        if (!plannedDailyActivity.optBoolean("pass", false)
                || plannedDailyActivity.optInt("planned_write_count", 0) != 2) {
            throw new AssertionError("daily activity candidates did not plan cleanly: " + plannedDailyActivity);
        }
        Log.i(TAG, "checking Android Health Connect record conversion");
        assertHealthConnectRecordConversion();
        Log.i(TAG, "checking Android Health Connect sync audit log");
        assertHealthConnectSyncAudit(context);
        Log.i(TAG, "checking Android BLE session audit log");
        assertBleSessionAudit(context);
        Log.i(TAG, "checking local data clear removes Android audit logs");
        assertClearLocalDataRemovesAuditLogs(context);
        Log.i(TAG, "checking Android Health Connect ready-plan audit path");
        assertHealthConnectReadyPlanAudit(context);

        Log.i(TAG, "checking declared Health Connect permissions");
        assertHealthConnectManifestScope(context);
        Log.i(TAG, "checking Health Connect rationale manifest entries");
        assertHealthConnectRationaleManifestScope(context);
        Log.i(TAG, "checking declared Bluetooth permissions");
        assertBluetoothManifestScope(context);
        Log.i(TAG, "checking runtime Bluetooth permission request set");
        assertBluetoothRuntimePermissionScope(context);
        Log.i(TAG, "checking BLE device row display contract");
        assertBleDeviceRowDisplayContract();
        Log.i(TAG, "checking step validation UI guardrails");
        assertStepValidationUiGuardrails();
        Log.i(TAG, "checking capture session start UI guardrails");
        assertCaptureSessionStartGuardrails();
        Log.i(TAG, "checking capture session finish UI guardrails");
        assertCaptureSessionFinishGuardrails();
        Log.i(TAG, "checking command build generation guardrail");
        assertCommandBuildGenerationGuardrail();
        Log.i(TAG, "checking Health Connect sync UI guardrails");
        assertHealthConnectSyncUiGuardrails();
        Log.i(TAG, "checking Health Connect writer dry-run guardrails");
        assertHealthConnectWriterDryRunGuardrails();
        Log.i(TAG, "checking Health Connect sync duplicate-tap guardrail");
        assertHealthConnectSyncInProgressGuardrail();
        Log.i(TAG, "checking installed app privacy flags");
        assertApplicationPrivacyFlags(context);
        Log.i(TAG, "checking installed app launch and hardware manifest");
        assertApplicationInstallScope(context);

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

    private void assertHealthConnectRecordConversion() throws Exception {
        if (Build.VERSION.SDK_INT < 34) {
            return;
        }
        Record steps = HealthConnectSupport.recordFromPlannedWrite(plannedWrite(
                "StepsRecord",
                "android-smoke-steps",
                "2026-01-01T00:00:00.000Z",
                "2026-01-01T01:00:00.000Z",
                1200.0
        ));
        if (!(steps instanceof StepsRecord)) {
            throw new AssertionError("planned steps did not build StepsRecord: " + steps);
        }
        Record heartRate = HealthConnectSupport.recordFromPlannedWrite(plannedWrite(
                "HeartRateRecord",
                "android-smoke-heart-rate",
                "2026-01-01T00:00:00.000Z",
                "2026-01-01T00:00:05.000Z",
                64.0
        ));
        if (!(heartRate instanceof HeartRateRecord)) {
            throw new AssertionError("planned heart rate did not build HeartRateRecord: " + heartRate);
        }
        Record activeEnergy = HealthConnectSupport.recordFromPlannedWrite(plannedWrite(
                "ActiveCaloriesBurnedRecord",
                "android-smoke-active-energy",
                "2026-01-01T00:00:00.000Z",
                "2026-01-01T01:00:00.000Z",
                42.5
        ));
        if (!(activeEnergy instanceof ActiveCaloriesBurnedRecord)) {
            throw new AssertionError("planned active energy did not build ActiveCaloriesBurnedRecord: " + activeEnergy);
        }
        Record unsupported = HealthConnectSupport.recordFromPlannedWrite(plannedWrite(
                "DistanceRecord",
                "android-smoke-distance",
                "2026-01-01T00:00:00.000Z",
                "2026-01-01T01:00:00.000Z",
                10.0
        ));
        if (unsupported != null) {
            throw new AssertionError("unsupported Health Connect record should return null: " + unsupported);
        }
        assertPlannedWriteRejected("bad time range", plannedWrite(
                "StepsRecord",
                "android-smoke-bad-range",
                "2026-01-01T01:00:00.000Z",
                "2026-01-01T00:00:00.000Z",
                10.0
        ));
        assertPlannedWriteRejected("negative steps", plannedWrite(
                "StepsRecord",
                "android-smoke-negative-steps",
                "2026-01-01T00:00:00.000Z",
                "2026-01-01T01:00:00.000Z",
                -1.0
        ));
        assertPlannedWriteRejected("zero heart rate", plannedWrite(
                "HeartRateRecord",
                "android-smoke-zero-heart-rate",
                "2026-01-01T00:00:00.000Z",
                "2026-01-01T00:00:05.000Z",
                0.0
        ));
    }

    private void assertPlannedWriteRejected(String label, JSONObject write) {
        try {
            HealthConnectSupport.recordFromPlannedWrite(write);
            throw new AssertionError("planned write should have been rejected: " + label);
        } catch (IllegalArgumentException expected) {
        }
    }

    private void assertUnavailableStatusReports(GooseRustBridge bridge, File databaseFile) throws Exception {
        JSONObject activity = bridge.request("metrics.activity_unavailable_daily_status", new JSONObject()
                .put("database_path", databaseFile.getAbsolutePath())
                .put("date_key", "2026-01-01")
                .put("timezone", "UTC")
                .put("start_time_unix_ms", 1767225600000L)
                .put("end_time_unix_ms", 1767312000000L)
                .put("write_metric", false));
        if (!"goose.activity-unavailable-daily-status-report.v1".equals(activity.optString("schema"))) {
            throw new AssertionError("unexpected activity unavailable schema: " + activity);
        }

        JSONObject energy = bridge.request("metrics.energy_unavailable_daily_status", new JSONObject()
                .put("database_path", databaseFile.getAbsolutePath())
                .put("date_key", "2026-01-01")
                .put("timezone", "UTC")
                .put("start", "2026-01-01T00:00:00.000Z")
                .put("end", "2026-01-02T00:00:00.000Z")
                .put("write_metric", false));
        if (!"goose.energy-unavailable-daily-status-report.v1".equals(energy.optString("schema"))) {
            throw new AssertionError("unexpected energy unavailable schema: " + energy);
        }

        JSONObject recovery = bridge.request("metrics.recovery_unavailable_daily_status", new JSONObject()
                .put("database_path", databaseFile.getAbsolutePath())
                .put("date_key", "2026-01-01")
                .put("timezone", "UTC")
                .put("start", "2026-01-01T00:00:00.000Z")
                .put("end", "2026-01-02T00:00:00.000Z")
                .put("write_metric", false));
        if (!"goose.recovery-unavailable-daily-status-report.v1".equals(recovery.optString("schema"))) {
            throw new AssertionError("unexpected recovery unavailable schema: " + recovery);
        }
    }

    private void assertAndroidCaptureSessionTagging(Context context) throws Exception {
        GoosePacketIngestor ingestor = new GoosePacketIngestor(context);
        GooseRustBridge bridge = new GooseRustBridge();
        File databaseFile = new File(ingestor.databasePath());
        deleteDatabaseFiles(databaseFile);
        String sessionId = "android-smoke-session-" + System.currentTimeMillis();
        long startedAt = 1767225600000L;
        bridge.request("capture.start_session", new JSONObject()
                .put("database_path", databaseFile.getAbsolutePath())
                .put("session_id", sessionId)
                .put("source", "goose-android/instrumentation")
                .put("started_at_unix_ms", startedAt)
                .put("device_model", "WHOOP 5.0 Goose Android")
                .put("provenance", new JSONObject()
                        .put("capture_app", "goose_android")
                        .put("capture_kind", "instrumentation_smoke")));
        ingestor.startCaptureSession(sessionId);

        CountDownLatch latch = new CountDownLatch(1);
        List<GoosePacketIngestor.Result> results = new ArrayList<>();
        ingestor.ingest(new GooseBleClient.GooseNotification(
                "0000180d-0000-1000-8000-00805f9b34fb",
                "00002a37-0000-1000-8000-00805f9b34fb",
                new byte[]{0x00, 0x44},
                startedAt + 1000L
        ), result -> {
            results.add(result);
            latch.countDown();
        });
        if (!latch.await(5, TimeUnit.SECONDS)) {
            throw new AssertionError("Android packet ingestor did not callback");
        }
        GoosePacketIngestor.Result result = results.get(0);
        if (result.error != null) {
            throw new AssertionError("Android packet ingest failed: " + result.error);
        }
        if (!"standard_heart_rate".equals(result.payloadKind)) {
            throw new AssertionError("standard heart-rate notification not classified: " + result.payloadKind);
        }
        int frameCount = ingestor.finishCaptureSession(sessionId);
        ingestor.close();
        if (frameCount != 1) {
            throw new AssertionError("capture session frame count should be 1, got " + frameCount);
        }
        JSONObject finish = bridge.request("capture.finish_session", new JSONObject()
                .put("database_path", databaseFile.getAbsolutePath())
                .put("session_id", sessionId)
                .put("ended_at_unix_ms", startedAt + 2000L)
                .put("frame_count", frameCount));
        JSONObject session = finish.optJSONObject("session");
        if (session == null
                || !"finished".equals(session.optString("status"))
                || session.optInt("frame_count", 0) != 1) {
            throw new AssertionError("capture session did not finish with frame count: " + finish);
        }
        assertRawEvidenceTagged(databaseFile, sessionId);
        assertEvidenceReadinessReportPasses(context, databaseFile);
        assertStepValidationAuditCapturesSession(context, databaseFile, sessionId);
    }

    private void assertRawEvidenceTagged(File databaseFile, String sessionId) {
        SQLiteDatabase database = SQLiteDatabase.openDatabase(databaseFile.getAbsolutePath(), null, SQLiteDatabase.OPEN_READONLY);
        Cursor cursor = null;
        try {
            cursor = database.rawQuery(
                    "SELECT COUNT(*), COALESCE(MAX(payload_hex), ''), COALESCE(MAX(source), '') "
                            + "FROM raw_evidence WHERE capture_session_id = ?",
                    new String[]{sessionId});
            if (!cursor.moveToFirst()) {
                throw new AssertionError("raw evidence query returned no rows");
            }
            int rows = cursor.getInt(0);
            String payloadHex = cursor.getString(1);
            String source = cursor.getString(2);
            if (rows != 1) {
                throw new AssertionError("expected 1 session-tagged raw_evidence row, got " + rows);
            }
            if (!"0044".equals(payloadHex)) {
                throw new AssertionError("session-tagged raw_evidence payload mismatch: " + payloadHex);
            }
            if (!source.contains("goose-android/live-notification/0000180d-0000-1000-8000-00805f9b34fb/00002a37-0000-1000-8000-00805f9b34fb")) {
                throw new AssertionError("session-tagged raw_evidence source mismatch: " + source);
            }
        } finally {
            if (cursor != null) {
                cursor.close();
            }
            database.close();
        }
    }

    private void assertEvidenceReadinessReportPasses(Context context, File databaseFile) throws Exception {
        GooseStoreReporter reporter = new GooseStoreReporter(context, databaseFile.getAbsolutePath());
        CountDownLatch latch = new CountDownLatch(1);
        List<String> reports = new ArrayList<>();
        try {
            reporter.evidenceReadiness(report -> {
                reports.add(report);
                latch.countDown();
            });
            if (!latch.await(5, TimeUnit.SECONDS)) {
                throw new AssertionError("evidence readiness report did not callback");
            }
        } finally {
            reporter.close();
        }
        String report = reports.isEmpty() ? "" : reports.get(0);
        if (!report.contains("status: PASS")
                || !report.contains("raw evidence: 1")
                || !report.contains("capture sessions: 1")
                || !report.contains("session raw evidence: 1")
                || !report.contains("session live notification raw evidence: 1")
                || !report.contains("finished nonempty capture sessions: 1")
                || !report.contains("ble session ready events:")
                || !report.contains("ble session hello sent events:")
                || !report.contains("ble session client hello completed events:")
                || !report.contains("ble session command ready events:")
                || !report.contains("health sync audit bytes:")
                || !report.contains("health sync ready write started events:")
                || !report.contains("health sync records attempted events:")
                || !report.contains("step validation audit bytes:")
                || !report.contains("step validation session-bound events:")
                || !report.contains("step validation session decoded events:")
                || !report.contains("step validation selected delta events:")
                || !report.contains("step validation passing session selected-delta events:")) {
            throw new AssertionError("evidence readiness report did not pass after capture smoke: " + report);
        }
    }

    private void assertStepValidationAuditCapturesSession(
            Context context,
            File databaseFile,
            String sessionId
    ) throws Exception {
        File auditFile = new File(databaseFile.getParentFile(), "step-validation-log.jsonl");
        if (auditFile.exists() && !auditFile.delete()) {
            throw new AssertionError("could not clear stale step validation audit log: " + auditFile);
        }
        GooseStoreReporter reporter = new GooseStoreReporter(context, databaseFile.getAbsolutePath());
        CountDownLatch latch = new CountDownLatch(1);
        try {
            reporter.stepValidation(
                    "2026-01-01T00:00:00.000Z",
                    "2026-01-01T00:00:03.000Z",
                    40L,
                    sessionId,
                    report -> latch.countDown());
            if (!latch.await(5, TimeUnit.SECONDS)) {
                throw new AssertionError("step validation report did not callback");
            }
        } finally {
            reporter.close();
        }
        String audit = readFile(auditFile);
        if (!audit.contains("goose.android.step-validation-audit.v1")) {
            throw new AssertionError("step validation audit missing schema: " + audit);
        }
        if (!audit.contains("\"event\":\"completed\"")) {
            throw new AssertionError("step validation audit missing completed event: " + audit);
        }
        if (!audit.contains("\"capture_session_id\":\"" + sessionId + "\"")) {
            throw new AssertionError("step validation audit missing capture session: " + audit);
        }
    }

    private void deleteDatabaseFiles(File databaseFile) {
        deleteIfExists(databaseFile);
        deleteIfExists(new File(databaseFile.getAbsolutePath() + "-wal"));
        deleteIfExists(new File(databaseFile.getAbsolutePath() + "-shm"));
    }

    private void deleteIfExists(File file) {
        if (file.exists() && !file.delete()) {
            throw new AssertionError("could not delete stale database file: " + file);
        }
    }

    private void assertHealthConnectSyncAudit(Context context) throws Exception {
        File auditFile = HealthConnectSupport.syncAuditFileFor(context);
        if (auditFile.exists() && !auditFile.delete()) {
            throw new AssertionError("could not clear stale Health Connect sync audit log: " + auditFile);
        }
        HealthConnectSupport support = new HealthConnectSupport(context);
        try {
            support.writePlannedRecords(null, report -> {
            });
        } finally {
            support.close();
        }
        if (!auditFile.isFile()) {
            throw new AssertionError("Health Connect sync audit log was not created: " + auditFile);
        }
        BufferedReader reader = new BufferedReader(new FileReader(auditFile));
        try {
            String line = reader.readLine();
            if (line == null || !line.contains("goose.android.health-connect-sync-audit.v1")) {
                throw new AssertionError("Health Connect sync audit log missing schema: " + line);
            }
            if (!line.contains("\"event\":\"blocked\"")) {
                throw new AssertionError("Health Connect sync audit log missing blocked event: " + line);
            }
        } finally {
            reader.close();
        }
    }

    private void assertBleSessionAudit(Context context) throws Exception {
        File auditFile = BleSessionAudit.auditFileFor(context);
        if (auditFile.exists() && !auditFile.delete()) {
            throw new AssertionError("could not clear stale BLE session audit log: " + auditFile);
        }
        BleSessionAudit.appendProgress(context, new GooseBleClient.ConnectionProgress(
                "ready",
                "android-smoke-device",
                1,
                5,
                3,
                6,
                4,
                0,
                11,
                6,
                "client hello",
                true,
                true,
                null,
                1_767_225_600_000L
        ));
        if (!auditFile.isFile()) {
            throw new AssertionError("BLE session audit log was not created: " + auditFile);
        }
        String audit = readFile(auditFile);
        if (!audit.contains("goose.android.ble-session-audit.v1")) {
            throw new AssertionError("BLE session audit missing schema: " + audit);
        }
        if (!audit.contains("\"phase\":\"ready\"")) {
            throw new AssertionError("BLE session audit missing ready phase: " + audit);
        }
        if (!audit.contains("\"hello_sent\":true")) {
            throw new AssertionError("BLE session audit missing hello_sent=true: " + audit);
        }
        if (!audit.contains("\"command_ready\":true")) {
            throw new AssertionError("BLE session audit missing command_ready=true: " + audit);
        }
        if (!audit.contains("\"active_operation_label\":\"client hello\"")) {
            throw new AssertionError("BLE session audit missing active operation label: " + audit);
        }
    }

    private void assertHealthConnectReadyPlanAudit(Context context) throws Exception {
        File auditFile = HealthConnectSupport.syncAuditFileFor(context);
        if (auditFile.exists() && !auditFile.delete()) {
            throw new AssertionError("could not clear stale Health Connect ready-plan audit log: " + auditFile);
        }
        JSONObject readyReport = new JSONObject()
                .put("pass", true)
                .put("all_records_ready", true)
                .put("permissions_ready", true)
                .put("candidate_count", 1)
                .put("planned_write_count", 1)
                .put("blocked_count", 0)
                .put("issues", new JSONArray())
                .put("planned_writes", new JSONArray().put(plannedWrite(
                        "StepsRecord",
                        "android-ready-plan-steps",
                        "2026-01-01T00:00:00.000Z",
                        "2026-01-01T01:00:00.000Z",
                        42.0
                )));
        List<String> reports = new ArrayList<>();
        HealthConnectSupport support = new HealthConnectSupport(context);
        try {
            support.writePlannedRecords(readyReport, reports::add);
        } finally {
            support.close();
        }
        String audit = readFile(auditFile);
        if (Build.VERSION.SDK_INT < 34) {
            if (!audit.contains("\"reason\":\"platform_unavailable\"")) {
                throw new AssertionError("ready-plan audit did not record platform_unavailable: " + audit);
            }
            return;
        }
        if (!(audit.contains("\"event\":\"write_started\"")
                || audit.contains("\"reason\":\"manager_unavailable\"")
                || audit.contains("\"event\":\"write_failed\"")
                || audit.contains("\"event\":\"write_succeeded\""))) {
            throw new AssertionError("ready-plan audit did not record a write attempt outcome: " + audit);
        }
        if (!audit.contains("android-ready-plan-steps")) {
            throw new AssertionError("ready-plan audit missing source record id: " + audit);
        }
        if (!audit.contains("records_attempted")) {
            throw new AssertionError("ready-plan audit missing records_attempted: " + audit);
        }
        if (!audit.contains("\"permissions_ready\":true")) {
            throw new AssertionError("ready-plan audit missing permissions_ready=true: " + audit);
        }
        if (!audit.contains("\"planned_write_count\":1")) {
            throw new AssertionError("ready-plan audit missing planned_write_count: " + audit);
        }
        if (!audit.contains("\"candidate_count\":1")) {
            throw new AssertionError("ready-plan audit missing candidate_count: " + audit);
        }
    }

    private void assertClearLocalDataRemovesAuditLogs(Context context) throws Exception {
        File databaseFile = new File(context.getCacheDir(), "goose-clear-local-data-smoke.sqlite");
        deleteDatabaseFiles(databaseFile);
        File bleAudit = BleSessionAudit.auditFileFor(context);
        File healthAudit = HealthConnectSupport.syncAuditFileFor(context);
        File healthDatabaseAudit = new File(databaseFile.getParentFile(), "health-connect-sync-log.jsonl");
        File stepAudit = new File(databaseFile.getParentFile(), "step-validation-log.jsonl");
        File[] auditFiles = new File[] {
                bleAudit,
                new File(bleAudit.getAbsolutePath() + ".old"),
                healthAudit,
                new File(healthAudit.getAbsolutePath() + ".old"),
                healthDatabaseAudit,
                new File(healthDatabaseAudit.getAbsolutePath() + ".old"),
                stepAudit,
                new File(stepAudit.getAbsolutePath() + ".old")
        };
        for (File auditFile : auditFiles) {
            writeFile(auditFile, "stale audit row\n");
        }
        File exportDir = new File(context.getFilesDir(), "exports");
        File exportFile = new File(exportDir, "stale-export.zip");
        File exportNestedFile = new File(new File(exportDir, "stale-export-dir"), "payload.jsonl");
        writeFile(exportFile, "stale export bytes\n");
        writeFile(exportNestedFile, "stale nested export bytes\n");

        GooseStoreReporter reporter = new GooseStoreReporter(context, databaseFile.getAbsolutePath());
        CountDownLatch latch = new CountDownLatch(1);
        List<String> reports = new ArrayList<>();
        try {
            reporter.clearLocalData(report -> {
                reports.add(report);
                latch.countDown();
            });
            if (!latch.await(5, TimeUnit.SECONDS)) {
                throw new AssertionError("clear local data report did not callback");
            }
        } finally {
            reporter.close();
        }
        String report = reports.isEmpty() ? "" : reports.get(0);
        if (!report.contains("Clear local data")) {
            throw new AssertionError("clear local data report missing header: " + report);
        }
        for (File auditFile : auditFiles) {
            if (auditFile.exists()) {
                throw new AssertionError("clear local data left stale audit file: " + auditFile);
            }
        }
        if (exportFile.exists() || exportNestedFile.exists()) {
            throw new AssertionError("clear local data left stale export artifacts");
        }
        if (!exportDir.isDirectory()) {
            throw new AssertionError("clear local data did not recreate export directory: " + exportDir);
        }
        File[] remainingExports = exportDir.listFiles();
        if (remainingExports != null && remainingExports.length != 0) {
            throw new AssertionError("clear local data left export entries: " + remainingExports.length);
        }
    }

    private String readFile(File file) throws Exception {
        if (!file.isFile()) {
            throw new AssertionError("expected file missing: " + file);
        }
        StringBuilder builder = new StringBuilder();
        BufferedReader reader = new BufferedReader(new FileReader(file));
        try {
            String line;
            while ((line = reader.readLine()) != null) {
                builder.append(line).append('\n');
            }
        } finally {
            reader.close();
        }
        return builder.toString();
    }

    private void writeFile(File file, String contents) throws Exception {
        File parent = file.getParentFile();
        if (parent != null && !parent.exists() && !parent.mkdirs()) {
            throw new AssertionError("could not create parent directory for " + file);
        }
        FileWriter writer = new FileWriter(file);
        try {
            writer.write(contents);
        } finally {
            writer.close();
        }
    }

    private JSONObject plannedWrite(
            String destinationType,
            String id,
            String start,
            String end,
            double value
    ) throws Exception {
        return new JSONObject()
                .put("destination_type", destinationType)
                .put("source_record_id", id)
                .put("idempotency_key", id + "-key")
                .put("start_time", start)
                .put("end_time", end)
                .put("value", value);
    }

    private void assertApplicationInstallScope(Context context) throws Exception {
        if (!"com.goose.android".equals(context.getPackageName())) {
            throw new AssertionError("unexpected application id: " + context.getPackageName());
        }
        PackageInfo info = context.getPackageManager().getPackageInfo(
                context.getPackageName(),
                PackageManager.GET_ACTIVITIES | PackageManager.GET_CONFIGURATIONS
        );
        assertMainActivityExported(info);
        assertRequiredBleFeature(info);
    }

    private void assertMainActivityExported(PackageInfo info) {
        if (info.activities == null) {
            throw new AssertionError("package activities metadata missing");
        }
        for (ActivityInfo activity : info.activities) {
            if ("com.goose.android.MainActivity".equals(activity.name)) {
                if (!activity.exported) {
                    throw new AssertionError("MainActivity must remain exported for launcher access");
                }
                int expectedConfigChanges = ActivityInfo.CONFIG_KEYBOARD_HIDDEN
                        | ActivityInfo.CONFIG_ORIENTATION
                        | ActivityInfo.CONFIG_SCREEN_SIZE;
                if ((activity.configChanges & expectedConfigChanges) != expectedConfigChanges) {
                    throw new AssertionError("MainActivity must handle orientation/screen changes during captures: "
                            + activity.configChanges);
                }
                return;
            }
        }
        throw new AssertionError("MainActivity not found in installed package");
    }

    private void assertRequiredBleFeature(PackageInfo info) {
        if (info.reqFeatures == null) {
            throw new AssertionError("required feature metadata missing");
        }
        for (FeatureInfo feature : info.reqFeatures) {
            if (PackageManager.FEATURE_BLUETOOTH_LE.equals(feature.name)) {
                if ((feature.flags & FeatureInfo.FLAG_REQUIRED) == 0) {
                    throw new AssertionError("BLE hardware feature must remain required");
                }
                return;
            }
        }
        throw new AssertionError("BLE hardware feature not declared");
    }

    private void assertApplicationPrivacyFlags(Context context) throws Exception {
        ApplicationInfo info = context.getPackageManager().getApplicationInfo(
                context.getPackageName(),
                0
        );
        if ((info.flags & ApplicationInfo.FLAG_ALLOW_BACKUP) != 0) {
            throw new AssertionError("android:allowBackup must remain false for local health data");
        }
        if ((info.flags & ApplicationInfo.FLAG_USES_CLEARTEXT_TRAFFIC) != 0) {
            throw new AssertionError("android:usesCleartextTraffic must remain false");
        }
        if (info.icon == 0) {
            throw new AssertionError("application icon must be set");
        }
    }

    private void assertBluetoothManifestScope(Context context) throws Exception {
        PackageInfo info = context.getPackageManager().getPackageInfo(
                context.getPackageName(),
                PackageManager.GET_PERMISSIONS
        );
        Set<String> declaredPermissions = requestedPermissionSet(info);
        Set<String> expectedPermissions = expectedBluetoothPermissionsForSdk();
        Set<String> declaredBluetoothPermissions = new HashSet<>();
        for (String permission : declaredPermissions) {
            if (permission.startsWith("android.permission.BLUETOOTH")
                    || "android.permission.ACCESS_FINE_LOCATION".equals(permission)) {
                declaredBluetoothPermissions.add(permission);
            }
        }
        if (!declaredBluetoothPermissions.equals(expectedPermissions)) {
            throw new AssertionError("unexpected Bluetooth/location manifest permissions: "
                    + declaredBluetoothPermissions);
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            assertPermissionHasFlag(info,
                    "android.permission.BLUETOOTH_SCAN",
                    PackageInfo.REQUESTED_PERMISSION_NEVER_FOR_LOCATION);
        }
    }

    private void assertBluetoothRuntimePermissionScope(Context context) {
        GooseBleClient client = new GooseBleClient(context, new NoOpBleListener());
        try {
            Set<String> runtimePermissions = new HashSet<>(client.requiredPermissions());
            if (!runtimePermissions.equals(expectedBluetoothRuntimePermissionsForSdk())) {
                throw new AssertionError("unexpected runtime Bluetooth permissions: "
                        + runtimePermissions);
            }
        } finally {
            client.close();
        }
    }

    private void assertBleDeviceRowDisplayContract() {
        StringBuilder services = new StringBuilder("Services:");
        for (int index = 0; index < 12; index += 1) {
            services.append('\n')
                    .append("fd4b")
                    .append(String.format(Locale.US, "%04d", index))
                    .append("-cce1-4033-93ce-002d5875f58a");
        }
        GooseBleClient.DeviceRow row = new GooseBleClient.DeviceRow(
                "E4:B9:C9:42:F9:A8",
                "WHOOP 5AM0298379",
                -45,
                services.toString(),
                true);
        String display = row.displayText();
        if (!display.startsWith("WHOOP candidate: WHOOP 5AM0298379")) {
            throw new AssertionError("WHOOP candidate display prefix missing: " + display);
        }
        if (!display.contains("...9 more services")) {
            throw new AssertionError("BLE service list was not compacted: " + display);
        }
        if (display.contains("fd4b0004")) {
            throw new AssertionError("BLE display leaked too many service rows: " + display);
        }

        StringBuilder longSummary = new StringBuilder("Services:\n");
        for (int index = 0; index < 500; index += 1) {
            longSummary.append('a');
        }
        GooseBleClient.DeviceRow longRow = new GooseBleClient.DeviceRow(
                "00:11:22:33:44:55",
                "Unknown BLE device",
                -31,
                longSummary.toString(),
                false);
        String longDisplay = longRow.displayText();
        if (longDisplay.length() > 300 || !longDisplay.endsWith("...")) {
            throw new AssertionError("BLE display was not character-capped: " + longDisplay.length());
        }

        List<GooseBleClient.DeviceRow> noisyScan = new ArrayList<>();
        for (int index = 0; index < 40; index += 1) {
            noisyScan.add(new GooseBleClient.DeviceRow(
                    String.format(Locale.US, "00:11:22:33:44:%02X", index),
                    "Unknown BLE device",
                    -90 + index,
                    "No advertised services",
                    false));
        }
        GooseBleClient.DeviceRow weakWhoop = new GooseBleClient.DeviceRow(
                "E4:B9:C9:42:F9:A8",
                "WHOOP 5AM0298379",
                -92,
                "Services:\nfd4b0001-cce1-4033-93ce-002d5875f58a",
                true);
        noisyScan.add(weakWhoop);
        List<GooseBleClient.DeviceRow> trackedRows = GooseBleClient.cappedScanRows(noisyScan);
        if (trackedRows.size() != 32) {
            throw new AssertionError("tracked BLE scan rows were not capped: " + trackedRows.size());
        }
        if (trackedRows.get(0) != weakWhoop) {
            throw new AssertionError("likely WHOOP row was not kept first in capped scan rows");
        }
        List<GooseBleClient.DeviceRow> publishedRows = GooseBleClient.cappedPublishedRows(new ArrayList<>(trackedRows));
        if (publishedRows.size() != 1) {
            throw new AssertionError("published BLE scan rows should suppress generic devices after WHOOP is found: "
                    + publishedRows.size());
        }
        if (publishedRows.get(0) != weakWhoop) {
            throw new AssertionError("likely WHOOP row was not kept first in published scan rows");
        }

        List<GooseBleClient.DeviceRow> genericPublishedRows = GooseBleClient.cappedPublishedRows(noisyGenericRows());
        if (genericPublishedRows.size() != 8) {
            throw new AssertionError("generic BLE scan rows were not capped before WHOOP discovery: "
                    + genericPublishedRows.size());
        }
    }

    private List<GooseBleClient.DeviceRow> noisyGenericRows() {
        List<GooseBleClient.DeviceRow> rows = new ArrayList<>();
        for (int index = 0; index < 40; index += 1) {
            rows.add(new GooseBleClient.DeviceRow(
                    String.format(Locale.US, "00:AA:BB:CC:DD:%02X", index),
                    "Unknown BLE device",
                    -90 + index,
                    "No advertised services",
                    false));
        }
        return rows;
    }

    private void assertStepValidationUiGuardrails() {
        String validStart = "2026-01-01T00:00:00.000Z";
        String validEnd = "2026-01-01T00:01:00.000Z";
        String sessionId = "android-smoke-session";
        if (MainActivity.stepValidationBlockReason(40L, validStart, validEnd, sessionId, 1) != null) {
            throw new AssertionError("valid step validation inputs should not be blocked");
        }
        assertStepValidationBlocked(0L, validStart, validEnd, sessionId, "greater than zero");
        assertStepValidationBlocked(40L, "0000", validEnd, sessionId, "Tap Step validation Start");
        assertStepValidationBlocked(40L, validStart, "9999", sessionId, "Tap Step validation End");
        assertStepValidationBlocked(40L, validEnd, validStart, sessionId, "End must be after Start");
        assertStepValidationBlocked(40L, validStart, validEnd, "", "capture session");
        assertStepValidationBlocked(40L, validStart, validEnd, sessionId, 0, "at least one notification");
    }

    private void assertStepValidationBlocked(
            long manualSteps,
            String start,
            String end,
            String captureSessionId,
            String expected
    ) {
        assertStepValidationBlocked(manualSteps, start, end, captureSessionId, 1, expected);
    }

    private void assertStepValidationBlocked(
            long manualSteps,
            String start,
            String end,
            String captureSessionId,
            int captureSessionFrameCount,
            String expected
    ) {
        String reason = MainActivity.stepValidationBlockReason(
                manualSteps,
                start,
                end,
                captureSessionId,
                captureSessionFrameCount);
        if (reason == null || !reason.contains(expected)) {
            throw new AssertionError("unexpected step validation guardrail reason: " + reason);
        }
    }

    private void assertCaptureSessionStartGuardrails() {
        if (MainActivity.captureSessionStartBlockReason(false, null) != null) {
            throw new AssertionError("idle capture session start should not be blocked");
        }
        assertCaptureSessionStartBlocked(true, null, "already running");
        assertCaptureSessionStartBlocked(false, "android-smoke-session", "Capture session active");
        assertCaptureSessionStartBlocked(false, true, null, null, "finish already running");
        assertCaptureSessionStartBlocked(false, false, null, "android-pending-finish", "Finish pending");
    }

    private void assertCaptureSessionStartBlocked(boolean startInProgress, String activeSessionId, String expected) {
        String reason = MainActivity.captureSessionStartBlockReason(startInProgress, activeSessionId);
        if (reason == null || !reason.contains(expected)) {
            throw new AssertionError("unexpected capture session start guardrail reason: " + reason);
        }
    }

    private void assertCaptureSessionStartBlocked(
            boolean startInProgress,
            boolean finishInProgress,
            String activeSessionId,
            String pendingFinishSessionId,
            String expected
    ) {
        String reason = MainActivity.captureSessionStartBlockReason(
                startInProgress,
                finishInProgress,
                activeSessionId,
                pendingFinishSessionId);
        if (reason == null || !reason.contains(expected)) {
            throw new AssertionError("unexpected capture session start guardrail reason: " + reason);
        }
    }

    private void assertCaptureSessionFinishGuardrails() {
        if (MainActivity.captureSessionFinishBlockReason(false) != null) {
            throw new AssertionError("idle capture session finish should not be blocked");
        }
        String reason = MainActivity.captureSessionFinishBlockReason(true);
        if (reason == null || !reason.contains("already running")) {
            throw new AssertionError("unexpected capture session finish guardrail reason: " + reason);
        }
    }

    private void assertCommandBuildGenerationGuardrail() {
        if (!MainActivity.isCurrentCommandBuild(3, 3)) {
            throw new AssertionError("matching command build generation should be current");
        }
        if (MainActivity.isCurrentCommandBuild(2, 3)) {
            throw new AssertionError("stale command build generation should not be current");
        }
    }

    private void assertHealthConnectSyncUiGuardrails() throws Exception {
        if (MainActivity.healthConnectSyncBlockReason(healthSyncUiReport(
                true,
                true,
                true,
                1,
                1,
                0
        )) != null) {
            throw new AssertionError("valid Health Connect sync dry-run should not be blocked");
        }
        assertHealthConnectSyncBlocked(healthSyncUiReport(true, true, true, 1, 0, 0), "No planned writes");
        assertHealthConnectSyncBlocked(healthSyncUiReport(true, true, false, 1, 1, 0), "Grant Health Connect");
        assertHealthConnectSyncBlocked(healthSyncUiReport(false, true, true, 1, 1, 0), "Dry run is not ready");
        assertHealthConnectSyncBlocked(healthSyncUiReport(true, false, true, 1, 1, 0), "Dry run is not ready");
        assertHealthConnectSyncBlocked(healthSyncUiReport(true, true, true, 1, 1, 1), "Dry run is not ready");
    }

    private void assertHealthConnectWriterDryRunGuardrails() throws Exception {
        if (HealthConnectSupport.dryRunWriteBlockReason(healthSyncUiReport(
                true,
                true,
                true,
                1,
                1,
                0
        )) != null) {
            throw new AssertionError("valid Health Connect writer dry-run should not be blocked");
        }
        assertHealthConnectWriterBlocked(healthSyncUiReport(true, true, false, 1, 1, 0),
                "permissions_not_ready");
        assertHealthConnectWriterBlocked(healthSyncUiReport(false, true, true, 1, 1, 0),
                "dry_run_not_ready");
        assertHealthConnectWriterBlocked(healthSyncUiReport(true, false, true, 1, 1, 0),
                "dry_run_not_ready");
        assertHealthConnectWriterBlocked(healthSyncUiReport(true, true, true, 1, 1, 1),
                "dry_run_not_ready");
    }

    private void assertHealthConnectSyncInProgressGuardrail() {
        String reason = MainActivity.healthConnectSyncInProgressBlockReason(true);
        if (reason == null || !reason.contains("already running")) {
            throw new AssertionError("unexpected Health Connect in-progress guardrail reason: " + reason);
        }
        if (MainActivity.healthConnectSyncInProgressBlockReason(false) != null) {
            throw new AssertionError("idle Health Connect sync should not be blocked");
        }
    }

    private void assertHealthConnectWriterBlocked(JSONObject report, String expected) {
        String reason = HealthConnectSupport.dryRunWriteBlockReason(report);
        if (!expected.equals(reason)) {
            throw new AssertionError("unexpected Health Connect writer guardrail reason: " + reason);
        }
    }

    private JSONObject healthSyncUiReport(
            boolean pass,
            boolean allRecordsReady,
            boolean permissionsReady,
            int candidateCount,
            int plannedWriteCount,
            int blockedCount
    ) throws Exception {
        return new JSONObject()
                .put("pass", pass)
                .put("all_records_ready", allRecordsReady)
                .put("permissions_ready", permissionsReady)
                .put("candidate_count", candidateCount)
                .put("planned_write_count", plannedWriteCount)
                .put("blocked_count", blockedCount);
    }

    private void assertHealthConnectSyncBlocked(JSONObject report, String expected) {
        String reason = MainActivity.healthConnectSyncBlockReason(report);
        if (reason == null || !reason.contains(expected)) {
            throw new AssertionError("unexpected Health Connect sync guardrail reason: " + reason);
        }
    }

    private Set<String> expectedBluetoothPermissionsForSdk() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return new HashSet<>(Arrays.asList(
                    "android.permission.BLUETOOTH_CONNECT",
                    "android.permission.BLUETOOTH_SCAN"
            ));
        }
        return new HashSet<>(Arrays.asList(
                "android.permission.BLUETOOTH",
                "android.permission.BLUETOOTH_ADMIN",
                "android.permission.ACCESS_FINE_LOCATION"
        ));
    }

    private Set<String> expectedBluetoothRuntimePermissionsForSdk() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return new HashSet<>(Arrays.asList(
                    "android.permission.BLUETOOTH_CONNECT",
                    "android.permission.BLUETOOTH_SCAN"
            ));
        }
        return new HashSet<>(Arrays.asList(
                "android.permission.ACCESS_FINE_LOCATION"
        ));
    }

    private void assertHealthConnectManifestScope(Context context) throws Exception {
        PackageInfo info = context.getPackageManager().getPackageInfo(
                context.getPackageName(),
                PackageManager.GET_PERMISSIONS
        );
        Set<String> declaredHealthPermissions = new HashSet<>();
        Set<String> declaredPermissions = requestedPermissionSet(info);
        for (String permission : declaredPermissions) {
            if (permission.startsWith("android.permission.health.")) {
                declaredHealthPermissions.add(permission);
            }
        }
        Set<String> expectedHealthPermissions = new HashSet<>(Arrays.asList(
                "android.permission.health.WRITE_ACTIVE_CALORIES_BURNED",
                "android.permission.health.WRITE_HEART_RATE",
                "android.permission.health.WRITE_STEPS"
        ));
        if (!declaredHealthPermissions.equals(expectedHealthPermissions)) {
            throw new AssertionError("unexpected Health Connect manifest permissions: "
                    + declaredHealthPermissions);
        }
    }

    private void assertHealthConnectRationaleManifestScope(Context context) throws Exception {
        PackageManager packageManager = context.getPackageManager();
        Intent rationaleIntent = new Intent("androidx.health.ACTION_SHOW_PERMISSIONS_RATIONALE")
                .setPackage(context.getPackageName());
        ActivityInfo rationaleActivity = resolveRequiredActivity(packageManager, rationaleIntent,
                "Health Connect permissions rationale");
        if (!"com.goose.android.PermissionsRationaleActivity".equals(rationaleActivity.name)) {
            throw new AssertionError("unexpected Health Connect rationale activity: "
                    + rationaleActivity.name);
        }
        if (!rationaleActivity.exported) {
            throw new AssertionError("Health Connect rationale activity must be exported");
        }

        Intent permissionUsageIntent = new Intent("android.intent.action.VIEW_PERMISSION_USAGE")
                .addCategory("android.intent.category.HEALTH_PERMISSIONS")
                .setPackage(context.getPackageName());
        ActivityInfo permissionUsageActivity = resolveRequiredActivity(packageManager, permissionUsageIntent,
                "Health Connect permission usage alias");
        if (!"com.goose.android.ViewPermissionUsageActivity".equals(permissionUsageActivity.name)) {
            throw new AssertionError("unexpected Health Connect permission usage alias: "
                    + permissionUsageActivity.name);
        }
        if (!"com.goose.android.PermissionsRationaleActivity".equals(permissionUsageActivity.targetActivity)) {
            throw new AssertionError("Health Connect permission usage alias must target rationale activity");
        }
        if (!permissionUsageActivity.exported) {
            throw new AssertionError("Health Connect permission usage alias must be exported");
        }
        if (!"android.permission.START_VIEW_PERMISSION_USAGE".equals(permissionUsageActivity.permission)) {
            throw new AssertionError("Health Connect permission usage alias missing START_VIEW_PERMISSION_USAGE");
        }
    }

    private ActivityInfo resolveRequiredActivity(
            PackageManager packageManager,
            Intent intent,
            String label
    ) {
        List<ResolveInfo> matches = packageManager.queryIntentActivities(intent, 0);
        if (matches.size() != 1) {
            throw new AssertionError(label + " should resolve exactly one activity, got " + matches.size());
        }
        ActivityInfo activityInfo = matches.get(0).activityInfo;
        if (activityInfo == null) {
            throw new AssertionError(label + " resolved without activity info");
        }
        return activityInfo;
    }

    private Set<String> requestedPermissionSet(PackageInfo info) {
        Set<String> permissions = new HashSet<>();
        if (info.requestedPermissions != null) {
            for (String permission : info.requestedPermissions) {
                permissions.add(permission);
            }
        }
        return permissions;
    }

    private void assertPermissionHasFlag(PackageInfo info, String permission, int requiredFlag) {
        if (info.requestedPermissions == null || info.requestedPermissionsFlags == null) {
            throw new AssertionError("requested permission metadata missing");
        }
        for (int index = 0; index < info.requestedPermissions.length; index += 1) {
            if (permission.equals(info.requestedPermissions[index])) {
                if ((info.requestedPermissionsFlags[index] & requiredFlag) == 0) {
                    throw new AssertionError(permission + " missing requested flag " + requiredFlag);
                }
                return;
            }
        }
        throw new AssertionError(permission + " not declared");
    }

    private static final class NoOpBleListener implements GooseBleClient.Listener {
        @Override
        public void onStateChanged(String status) {
        }

        @Override
        public void onDevicesChanged(List<GooseBleClient.DeviceRow> devices) {
        }

        @Override
        public void onNotification(GooseBleClient.GooseNotification notification) {
        }

        @Override
        public void onMetadataChanged(String metadata) {
        }

        @Override
        public void onCommandEvent(GooseBleClient.CommandEvent event) {
        }

        @Override
        public void onConnectionProgress(GooseBleClient.ConnectionProgress progress) {
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
