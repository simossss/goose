package com.goose.android;

import android.content.Context;

import org.json.JSONObject;

import java.io.File;
import java.io.FileWriter;

final class BleSessionAudit {
    private static final long MAX_AUDIT_BYTES = 256L * 1024L;

    private BleSessionAudit() {
    }

    static File auditFileFor(Context context) {
        return new File(new File(context.getFilesDir(), "goose"), "ble-session-log.jsonl");
    }

    static void appendProgress(Context context, GooseBleClient.ConnectionProgress progress) {
        JSONObject details = new JSONObject();
        put(details, "phase", progress.phase);
        put(details, "device_id", progress.deviceId);
        put(details, "discovered_device_count", progress.discoveredDeviceCount);
        put(details, "service_count", progress.serviceCount);
        put(details, "interesting_service_count", progress.interestingServiceCount);
        put(details, "notification_candidate_count", progress.notificationCandidateCount);
        put(details, "read_candidate_count", progress.readCandidateCount);
        put(details, "queued_operation_count", progress.queuedOperationCount);
        put(details, "completed_operation_count", progress.completedOperationCount);
        put(details, "subscription_count", progress.subscriptionCount);
        put(details, "command_ready", progress.commandReady);
        put(details, "hello_sent", progress.helloSent);
        put(details, "error", progress.error);
        append(context, "connection_progress", progress.occurredAtMillis, details);
    }

    private static synchronized void append(Context context, String event, long occurredAtMillis, JSONObject details) {
        File auditFile = auditFileFor(context);
        try {
            File parent = auditFile.getParentFile();
            if (parent != null && !parent.exists() && !parent.mkdirs()) {
                return;
            }
            rotateIfNeeded(auditFile);
            JSONObject row = new JSONObject();
            put(row, "schema", "goose.android.ble-session-audit.v1");
            put(row, "generated_by", "goose-android");
            put(row, "created_at_unix_ms", System.currentTimeMillis());
            put(row, "occurred_at_unix_ms", occurredAtMillis);
            put(row, "event", event);
            put(row, "details", details);
            FileWriter writer = new FileWriter(auditFile, true);
            try {
                writer.write(row.toString());
                writer.write('\n');
            } finally {
                writer.close();
            }
        } catch (Exception ignored) {
        }
    }

    private static void rotateIfNeeded(File auditFile) {
        if (!auditFile.exists() || auditFile.length() <= MAX_AUDIT_BYTES) {
            return;
        }
        File rotated = new File(auditFile.getParentFile(), auditFile.getName() + ".old");
        if (rotated.exists() && !rotated.delete()) {
            return;
        }
        auditFile.renameTo(rotated);
    }

    private static void put(JSONObject object, String key, Object value) {
        try {
            object.put(key, value);
        } catch (Exception ignored) {
        }
    }
}
