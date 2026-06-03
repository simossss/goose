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

import java.io.File;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

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

        Log.i(TAG, "checking declared Health Connect permissions");
        assertHealthConnectManifestScope(context);
        Log.i(TAG, "checking Health Connect rationale manifest entries");
        assertHealthConnectRationaleManifestScope(context);
        Log.i(TAG, "checking declared Bluetooth permissions");
        assertBluetoothManifestScope(context);
        Log.i(TAG, "checking runtime Bluetooth permission request set");
        assertBluetoothRuntimePermissionScope(context);
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
