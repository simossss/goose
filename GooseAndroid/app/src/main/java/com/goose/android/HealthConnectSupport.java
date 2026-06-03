package com.goose.android;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;

import java.util.ArrayList;
import java.util.List;

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

    HealthConnectSupport(Context context) {
        this.context = context.getApplicationContext();
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

    private boolean platformAvailable() {
        return Build.VERSION.SDK_INT >= 34;
    }
}
