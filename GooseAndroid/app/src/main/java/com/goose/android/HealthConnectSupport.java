package com.goose.android;

import android.app.Activity;
import android.annotation.SuppressLint;
import android.health.connect.HealthConnectException;
import android.health.connect.HealthConnectManager;
import android.health.connect.InsertRecordsResponse;
import android.health.connect.datatypes.ActiveCaloriesBurnedRecord;
import android.health.connect.datatypes.HeartRateRecord;
import android.health.connect.datatypes.Metadata;
import android.health.connect.datatypes.Record;
import android.health.connect.datatypes.StepsRecord;
import android.health.connect.datatypes.units.Energy;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.OutcomeReceiver;

import java.io.File;
import java.io.FileWriter;
import java.util.ArrayList;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.Executor;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import org.json.JSONArray;
import org.json.JSONObject;

final class HealthConnectSupport {
    static final int REQUEST_HEALTH_CONNECT = 2001;
    private static final long MAX_SYNC_AUDIT_BYTES = 256L * 1024L;

    private static final String ACTION_MANAGE_HEALTH_PERMISSIONS =
            "android.health.connect.action.MANAGE_HEALTH_PERMISSIONS";

    private static final String[] WRITE_PERMISSIONS = {
            "android.permission.health.WRITE_ACTIVE_CALORIES_BURNED",
            "android.permission.health.WRITE_HEART_RATE",
            "android.permission.health.WRITE_STEPS",
    };

    private final Context context;
    private final ExecutorService healthExecutor = Executors.newSingleThreadExecutor();
    private final File syncAuditFile;

    HealthConnectSupport(Context context) {
        this.context = context.getApplicationContext();
        syncAuditFile = syncAuditFileFor(this.context);
    }

    interface WriteCallback {
        void onReport(String report);
    }

    List<String> grantedPermissions() {
        List<String> grants = new ArrayList<>();
        if (!platformAvailable()) {
            return grants;
        }
        for (String permission : WRITE_PERMISSIONS) {
            if (context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) {
                grants.add(permission);
            }
        }
        return grants;
    }

    List<String> healthSyncPermissionGrants() {
        List<String> grants = new ArrayList<>();
        if (!platformAvailable()) {
            return grants;
        }
        addDestinationGrant(grants, "android.permission.health.WRITE_ACTIVE_CALORIES_BURNED",
                "ActiveCaloriesBurnedRecord");
        addDestinationGrant(grants, "android.permission.health.WRITE_HEART_RATE",
                "HeartRateRecord");
        addDestinationGrant(grants, "android.permission.health.WRITE_STEPS",
                "StepsRecord");
        return grants;
    }

    String status() {
        if (!platformAvailable()) {
            return "Health Connect: unavailable on Android " + Build.VERSION.SDK_INT;
        }
        int granted = grantedPermissions().size();
        return "Health Connect: Android platform available\n"
                + "write permissions: " + granted + "/" + WRITE_PERMISSIONS.length + " granted";
    }

    void requestPermissions(Activity activity) {
        if (!platformAvailable()) {
            return;
        }
        activity.requestPermissions(WRITE_PERMISSIONS, REQUEST_HEALTH_CONNECT);
    }

    void openSettings(Activity activity) {
        if (!platformAvailable()) {
            return;
        }
        Intent intent = new Intent(ACTION_MANAGE_HEALTH_PERMISSIONS)
                .putExtra(Intent.EXTRA_PACKAGE_NAME, activity.getPackageName());
        if (intent.resolveActivity(activity.getPackageManager()) != null) {
            activity.startActivity(intent);
        }
    }

    void close() {
        healthExecutor.shutdownNow();
    }

    void writePlannedRecords(JSONObject dryRunReport, WriteCallback callback) {
        if (!platformAvailable()) {
            appendSyncAudit("blocked", auditDetails(
                    "reason", "platform_unavailable",
                    "sdk_int", Build.VERSION.SDK_INT));
            callback.onReport("Health Connect sync\nAndroid 14+ is required for the platform writer.");
            return;
        }
        if (dryRunReport == null) {
            appendSyncAudit("blocked", auditDetails("reason", "dry_run_report_missing"));
            callback.onReport("Health Connect sync\nNo dry-run report available.");
            return;
        }
        if (!dryRunReport.optBoolean("pass", false)
                || !dryRunReport.optBoolean("all_records_ready", false)
                || dryRunReport.optInt("blocked_count", 0) > 0) {
            appendSyncAudit("blocked", putAudit(dryRunAuditDetails(dryRunReport),
                    "reason", "dry_run_not_ready"));
            callback.onReport("Health Connect sync blocked\n"
                    + "pass: " + dryRunReport.optBoolean("pass", false) + "\n"
                    + "all records ready: " + dryRunReport.optBoolean("all_records_ready", false) + "\n"
                    + "blocked: " + dryRunReport.optInt("blocked_count", 0) + "\n"
                    + "issues: " + dryRunReport.optJSONArray("issues"));
            return;
        }
        JSONArray plannedWrites = dryRunReport.optJSONArray("planned_writes");
        if (plannedWrites == null || plannedWrites.length() == 0) {
            appendSyncAudit("blocked", putAudit(dryRunAuditDetails(dryRunReport),
                    "reason", "no_planned_writes"));
            callback.onReport("Health Connect sync\nNo planned writes. Capture and decode Goose-owned metrics first.");
            return;
        }
        List<Record> records = new ArrayList<>();
        List<String> attempted = new ArrayList<>();
        List<String> skipped = new ArrayList<>();
        for (int index = 0; index < plannedWrites.length(); index += 1) {
            JSONObject write = plannedWrites.optJSONObject(index);
            if (write == null) {
                skipped.add("write " + index + ": not an object");
                continue;
            }
            try {
                Record record = recordFromPlannedWrite(write);
                if (record != null) {
                    records.add(record);
                    attempted.add(plannedWriteSummary(write));
                } else {
                    skipped.add(write.optString("source_record_id", "write " + index)
                            + ": unsupported " + write.optString("destination_type"));
                }
            } catch (Exception error) {
                skipped.add(write.optString("source_record_id", "write " + index) + ": " + error.getMessage());
            }
        }
        if (records.isEmpty()) {
            appendSyncAudit("blocked", putAudit(putAudit(dryRunAuditDetails(dryRunReport),
                    "reason", "no_writeable_records"), "skipped", jsonArray(skipped)));
            callback.onReport("Health Connect sync blocked\n"
                    + "planned writes: " + plannedWrites.length() + "\n"
                    + "writeable records: 0\n"
                    + "skipped: " + skipped);
            return;
        }
        insertRecords(records, attempted, skipped, callback);
    }

    @SuppressLint("NewApi")
    private void insertRecords(
            List<Record> records,
            List<String> attempted,
            List<String> skipped,
            WriteCallback callback
    ) {
        HealthConnectManager manager = context.getSystemService(HealthConnectManager.class);
        if (manager == null) {
            appendSyncAudit("blocked", auditDetails(
                    "reason", "manager_unavailable",
                    "records_attempted", records.size(),
                    "attempted", jsonArray(attempted),
                    "skipped", jsonArray(skipped)));
            callback.onReport("Health Connect sync\nHealthConnectManager unavailable.");
            return;
        }
        appendSyncAudit("write_started", auditDetails(
                "records_attempted", records.size(),
                "attempted", jsonArray(attempted),
                "skipped", jsonArray(skipped)));
        manager.insertRecords(records, healthExecutor, new OutcomeReceiver<InsertRecordsResponse, HealthConnectException>() {
            @Override
            public void onResult(InsertRecordsResponse result) {
                appendSyncAudit("write_succeeded", auditDetails(
                        "records_inserted", records.size(),
                        "attempted", jsonArray(attempted),
                        "skipped", jsonArray(skipped)));
                callback.onReport("Health Connect sync\n"
                        + "inserted records: " + records.size() + "\n"
                        + "attempted detail: " + attempted + "\n"
                        + "skipped: " + skipped.size() + "\n"
                        + "skipped detail: " + skipped);
            }

            @Override
            public void onError(HealthConnectException error) {
                appendSyncAudit("write_failed", auditDetails(
                        "records_attempted", records.size(),
                        "attempted", jsonArray(attempted),
                        "skipped", jsonArray(skipped),
                        "error", String.valueOf(error)));
                callback.onReport("Health Connect sync failed\n"
                        + "records attempted: " + records.size() + "\n"
                        + "attempted detail: " + attempted + "\n"
                        + "skipped before write: " + skipped.size() + "\n"
                        + error);
            }
        });
    }

    @SuppressLint("NewApi")
    static Record recordFromPlannedWrite(JSONObject write) {
        String destinationType = write.optString("destination_type");
        Instant start = Instant.parse(write.optString("start_time"));
        Instant end = Instant.parse(write.optString("end_time"));
        if (!end.isAfter(start)) {
            throw new IllegalArgumentException("end_time must be after start_time");
        }
        Metadata metadata = metadataFor(write);
        switch (destinationType) {
            case "StepsRecord":
                long steps = Math.round(write.optDouble("value"));
                if (steps < 0) {
                    throw new IllegalArgumentException("steps must be non-negative");
                }
                return new StepsRecord.Builder(metadata, start, end, steps)
                        .setStartZoneOffset(ZoneOffset.UTC)
                        .setEndZoneOffset(ZoneOffset.UTC)
                        .build();
            case "HeartRateRecord":
                long bpm = Math.round(write.optDouble("value"));
                if (bpm <= 0) {
                    throw new IllegalArgumentException("heart rate must be positive");
                }
                HeartRateRecord.HeartRateSample sample =
                        new HeartRateRecord.HeartRateSample(bpm, start);
                return new HeartRateRecord.Builder(metadata, start, end, Collections.singletonList(sample))
                        .setStartZoneOffset(ZoneOffset.UTC)
                        .setEndZoneOffset(ZoneOffset.UTC)
                        .build();
            case "ActiveCaloriesBurnedRecord":
                double kcal = write.optDouble("value");
                if (kcal < 0.0) {
                    throw new IllegalArgumentException("active energy must be non-negative");
                }
                return new ActiveCaloriesBurnedRecord.Builder(metadata, start, end, Energy.fromCalories(kcal))
                        .setStartZoneOffset(ZoneOffset.UTC)
                        .setEndZoneOffset(ZoneOffset.UTC)
                        .build();
            default:
                return null;
        }
    }

    @SuppressLint("NewApi")
    private static Metadata metadataFor(JSONObject write) {
        return new Metadata.Builder()
                .setClientRecordId(write.optString("idempotency_key"))
                .setClientRecordVersion(0L)
                .setRecordingMethod(Metadata.RECORDING_METHOD_AUTOMATICALLY_RECORDED)
                .build();
    }

    private String plannedWriteSummary(JSONObject write) {
        return write.optString("source_record_id", "unknown")
                + " -> " + write.optString("destination_type", "unknown")
                + " (" + write.optString("start_time", "?")
                + " to " + write.optString("end_time", "?") + ")";
    }

    private boolean platformAvailable() {
        return Build.VERSION.SDK_INT >= 34;
    }

    private void addDestinationGrant(List<String> grants, String permission, String destinationType) {
        if (context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) {
            grants.add(destinationType);
        }
    }

    static File syncAuditFileFor(Context context) {
        return new File(new File(context.getFilesDir(), "goose"), "health-connect-sync-log.jsonl");
    }

    private JSONObject dryRunAuditDetails(JSONObject report) {
        return auditDetails(
                "pass", report.optBoolean("pass", false),
                "all_records_ready", report.optBoolean("all_records_ready", false),
                "permissions_ready", report.optBoolean("permissions_ready", false),
                "candidate_count", report.optInt("candidate_count", 0),
                "planned_write_count", report.optInt("planned_write_count", 0),
                "blocked_count", report.optInt("blocked_count", 0),
                "issues", report.optJSONArray("issues"));
    }

    private JSONArray jsonArray(List<String> values) {
        JSONArray array = new JSONArray();
        for (String value : values) {
            array.put(value);
        }
        return array;
    }

    private void appendSyncAudit(String event, JSONObject details) {
        try {
            File parent = syncAuditFile.getParentFile();
            if (parent != null && !parent.exists() && !parent.mkdirs()) {
                return;
            }
            rotateSyncAuditIfNeeded();
            JSONObject row = auditDetails(
                    "schema", "goose.android.health-connect-sync-audit.v1",
                    "generated_by", "goose-android",
                    "created_at_unix_ms", System.currentTimeMillis(),
                    "event", event,
                    "details", details);
            FileWriter writer = new FileWriter(syncAuditFile, true);
            try {
                writer.write(row.toString());
                writer.write('\n');
            } finally {
                writer.close();
            }
        } catch (Exception ignored) {
        }
    }

    private JSONObject auditDetails(Object... pairs) {
        JSONObject object = new JSONObject();
        for (int index = 0; index + 1 < pairs.length; index += 2) {
            putAudit(object, String.valueOf(pairs[index]), pairs[index + 1]);
        }
        return object;
    }

    private JSONObject putAudit(JSONObject object, String key, Object value) {
        try {
            object.put(key, value);
        } catch (Exception ignored) {
        }
        return object;
    }

    private void rotateSyncAuditIfNeeded() {
        if (!syncAuditFile.exists() || syncAuditFile.length() <= MAX_SYNC_AUDIT_BYTES) {
            return;
        }
        File rotated = new File(syncAuditFile.getParentFile(), syncAuditFile.getName() + ".old");
        if (rotated.exists() && !rotated.delete()) {
            return;
        }
        syncAuditFile.renameTo(rotated);
    }
}
