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

    private static final String ACTION_MANAGE_HEALTH_PERMISSIONS =
            "android.health.connect.action.MANAGE_HEALTH_PERMISSIONS";

    private static final String[] REQUIRED_PERMISSIONS = {
            "android.permission.health.READ_ACTIVE_CALORIES_BURNED",
            "android.permission.health.WRITE_ACTIVE_CALORIES_BURNED",
            "android.permission.health.READ_HEART_RATE",
            "android.permission.health.WRITE_HEART_RATE",
            "android.permission.health.READ_HEART_RATE_VARIABILITY",
            "android.permission.health.WRITE_HEART_RATE_VARIABILITY",
            "android.permission.health.READ_OXYGEN_SATURATION",
            "android.permission.health.WRITE_OXYGEN_SATURATION",
            "android.permission.health.READ_RESPIRATORY_RATE",
            "android.permission.health.WRITE_RESPIRATORY_RATE",
            "android.permission.health.READ_RESTING_HEART_RATE",
            "android.permission.health.WRITE_RESTING_HEART_RATE",
            "android.permission.health.READ_SKIN_TEMPERATURE",
            "android.permission.health.WRITE_SKIN_TEMPERATURE",
            "android.permission.health.READ_SLEEP",
            "android.permission.health.WRITE_SLEEP",
            "android.permission.health.READ_STEPS",
            "android.permission.health.WRITE_STEPS",
    };

    private final Context context;
    private final ExecutorService healthExecutor = Executors.newSingleThreadExecutor();

    HealthConnectSupport(Context context) {
        this.context = context.getApplicationContext();
    }

    interface WriteCallback {
        void onReport(String report);
    }

    List<String> grantedPermissions() {
        List<String> grants = new ArrayList<>();
        if (!platformAvailable()) {
            return grants;
        }
        for (String permission : REQUIRED_PERMISSIONS) {
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
                + "permissions: " + granted + "/" + REQUIRED_PERMISSIONS.length + " granted";
    }

    void requestPermissions(Activity activity) {
        if (!platformAvailable()) {
            return;
        }
        activity.requestPermissions(REQUIRED_PERMISSIONS, REQUEST_HEALTH_CONNECT);
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
            callback.onReport("Health Connect sync\nAndroid 14+ is required for the platform writer.");
            return;
        }
        if (dryRunReport == null) {
            callback.onReport("Health Connect sync\nNo dry-run report available.");
            return;
        }
        if (!dryRunReport.optBoolean("pass", false)
                || !dryRunReport.optBoolean("all_records_ready", false)
                || dryRunReport.optInt("blocked_count", 0) > 0) {
            callback.onReport("Health Connect sync blocked\n"
                    + "pass: " + dryRunReport.optBoolean("pass", false) + "\n"
                    + "all records ready: " + dryRunReport.optBoolean("all_records_ready", false) + "\n"
                    + "blocked: " + dryRunReport.optInt("blocked_count", 0) + "\n"
                    + "issues: " + dryRunReport.optJSONArray("issues"));
            return;
        }
        JSONArray plannedWrites = dryRunReport.optJSONArray("planned_writes");
        if (plannedWrites == null || plannedWrites.length() == 0) {
            callback.onReport("Health Connect sync\nNo planned writes. Capture and decode Goose-owned metrics first.");
            return;
        }
        List<Record> records = new ArrayList<>();
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
                } else {
                    skipped.add(write.optString("source_record_id", "write " + index)
                            + ": unsupported " + write.optString("destination_type"));
                }
            } catch (Exception error) {
                skipped.add(write.optString("source_record_id", "write " + index) + ": " + error.getMessage());
            }
        }
        if (records.isEmpty()) {
            callback.onReport("Health Connect sync blocked\n"
                    + "planned writes: " + plannedWrites.length() + "\n"
                    + "writeable records: 0\n"
                    + "skipped: " + skipped);
            return;
        }
        insertRecords(records, skipped, callback);
    }

    @SuppressLint("NewApi")
    private void insertRecords(List<Record> records, List<String> skipped, WriteCallback callback) {
        HealthConnectManager manager = context.getSystemService(HealthConnectManager.class);
        if (manager == null) {
            callback.onReport("Health Connect sync\nHealthConnectManager unavailable.");
            return;
        }
        manager.insertRecords(records, healthExecutor, new OutcomeReceiver<InsertRecordsResponse, HealthConnectException>() {
            @Override
            public void onResult(InsertRecordsResponse result) {
                callback.onReport("Health Connect sync\n"
                        + "inserted records: " + records.size() + "\n"
                        + "skipped: " + skipped.size() + "\n"
                        + "skipped detail: " + skipped);
            }

            @Override
            public void onError(HealthConnectException error) {
                callback.onReport("Health Connect sync failed\n"
                        + "records attempted: " + records.size() + "\n"
                        + "skipped before write: " + skipped.size() + "\n"
                        + error);
            }
        });
    }

    @SuppressLint("NewApi")
    private Record recordFromPlannedWrite(JSONObject write) {
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
    private Metadata metadataFor(JSONObject write) {
        return new Metadata.Builder()
                .setClientRecordId(write.optString("idempotency_key"))
                .setClientRecordVersion(0L)
                .setRecordingMethod(Metadata.RECORDING_METHOD_AUTOMATICALLY_RECORDED)
                .build();
    }

    private boolean platformAvailable() {
        return Build.VERSION.SDK_INT >= 34;
    }

    private void addDestinationGrant(List<String> grants, String permission, String destinationType) {
        if (context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) {
            grants.add(destinationType);
        }
    }
}
