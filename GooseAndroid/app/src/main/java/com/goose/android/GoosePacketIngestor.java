package com.goose.android;

import android.content.Context;
import android.content.ContentValues;
import android.database.sqlite.SQLiteDatabase;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.security.MessageDigest;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.TimeZone;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

final class GoosePacketIngestor {
    interface Callback {
        void onIngested(Result result);
    }

    static final class Result {
        final String frameHex;
        final String parseSummary;
        final String importSummary;
        final String packetTypeName;
        final String payloadKind;
        final String bodyKind;
        final String eventName;
        final int sequence;
        final int rawInserted;
        final int directRawInserted;
        final int framesInserted;
        final int framesExisting;
        final String error;

        Result(
                String frameHex,
                String parseSummary,
                String importSummary,
                String packetTypeName,
                String payloadKind,
                String bodyKind,
                String eventName,
                int sequence,
                int rawInserted,
                int directRawInserted,
                int framesInserted,
                int framesExisting,
                String error
        ) {
            this.frameHex = frameHex;
            this.parseSummary = parseSummary;
            this.importSummary = importSummary;
            this.packetTypeName = packetTypeName;
            this.payloadKind = payloadKind;
            this.bodyKind = bodyKind;
            this.eventName = eventName;
            this.sequence = sequence;
            this.rawInserted = rawInserted;
            this.directRawInserted = directRawInserted;
            this.framesInserted = framesInserted;
            this.framesExisting = framesExisting;
            this.error = error;
        }
    }

    private final GooseRustBridge bridge = new GooseRustBridge();
    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final File databaseFile;
    private int frameCounter;
    private String activeCaptureSessionId;
    private int activeCaptureSessionFrameCount;

    GoosePacketIngestor(Context context) {
        File directory = new File(context.getFilesDir(), "goose");
        if (!directory.exists()) {
            directory.mkdirs();
        }
        databaseFile = new File(directory, "goose.sqlite");
    }

    String databasePath() {
        return databaseFile.getAbsolutePath();
    }

    void ingest(GooseBleClient.GooseNotification notification, Callback callback) {
        byte[] value = notification.value.clone();
        String serviceUuid = notification.serviceUuid;
        String characteristicUuid = notification.characteristicUuid;
        long capturedAtMillis = notification.capturedAtMillis;
        String captureSessionId = currentCaptureSessionIdForNotification();
        executor.execute(() -> callback.onIngested(ingestNow(
                value,
                serviceUuid,
                characteristicUuid,
                capturedAtMillis,
                captureSessionId
        )));
    }

    synchronized void startCaptureSession(String sessionId) {
        activeCaptureSessionId = sessionId;
        activeCaptureSessionFrameCount = 0;
    }

    synchronized int finishCaptureSession(String sessionId) {
        int frameCount = activeCaptureSessionFrameCount;
        if (sessionId.equals(activeCaptureSessionId)) {
            activeCaptureSessionId = null;
            activeCaptureSessionFrameCount = 0;
        }
        return frameCount;
    }

    synchronized String activeCaptureSessionId() {
        return activeCaptureSessionId;
    }

    synchronized void clearCaptureSession() {
        activeCaptureSessionId = null;
        activeCaptureSessionFrameCount = 0;
    }

    void close() {
        executor.shutdownNow();
    }

    private synchronized String currentCaptureSessionIdForNotification() {
        if (activeCaptureSessionId != null) {
            activeCaptureSessionFrameCount += 1;
        }
        return activeCaptureSessionId;
    }

    private Result ingestNow(
            byte[] value,
            String serviceUuid,
            String characteristicUuid,
            long capturedAtMillis,
            String captureSessionId
    ) {
        String frameHex = Hex.encode(value);
        try {
            JSONObject importReport = importFrame(
                    frameHex,
                    serviceUuid,
                    characteristicUuid,
                    capturedAtMillis,
                    captureSessionId
            );
            JSONArray issues = importReport.optJSONArray("issues");
            int rawInserted = importReport.optInt("raw_inserted", 0);
            int directRawInserted = importReport.optInt("direct_raw_inserted", 0);
            int framesInserted = importReport.optInt("frames_inserted", 0);
            int framesExisting = importReport.optInt("frames_existing", 0);
            String importSummary = "raw inserted "
                    + rawInserted
                    + ", direct raw inserted "
                    + directRawInserted
                    + ", decoded inserted "
                    + framesInserted
                    + ", existing "
                    + framesExisting
                    + ", issues "
                    + (issues != null ? issues.length() : 0);
            String parseSummary;
            JSONObject parsedFrame = null;
            if (isGooseFrame(frameHex)) {
                try {
                    parsedFrame = parseFrame(frameHex);
                    parseSummary = parsedFrameSummary(parsedFrame);
                } catch (Exception parseError) {
                    parseSummary = "parse failed after raw import: " + parseError;
                }
            } else {
                parseSummary = standardNotificationSummary(characteristicUuid, value);
            }
            return new Result(
                    frameHex,
                    parseSummary,
                    importSummary,
                    parsedFrame != null ? parsedFrame.optString("packet_type_name", "") : "",
                    parsedFrame != null ? parsedPayloadKind(parsedFrame) : standardPayloadKind(characteristicUuid, value),
                    parsedFrame != null ? bodyKind(parsedFrame) : "",
                    parsedFrame != null ? eventName(parsedFrame) : "",
                    parsedFrame != null ? parsedFrame.optInt("sequence", -1) : -1,
                    rawInserted,
                    directRawInserted,
                    framesInserted,
                    framesExisting,
                    null
            );
        } catch (Exception error) {
            return new Result(frameHex, "", "", "", "", "", "", -1, 0, 0, 0, 0, error.toString());
        }
    }

    private boolean isGooseFrame(String frameHex) {
        return frameHex.toLowerCase(Locale.US).startsWith("aa");
    }

    private String standardNotificationSummary(String characteristicUuid, byte[] value) {
        if ("00002a37-0000-1000-8000-00805f9b34fb".equalsIgnoreCase(characteristicUuid)
                && value.length >= 2
                && (value[0] & 0x01) == 0) {
            return "standard heart rate: " + (value[1] & 0xff) + " bpm";
        }
        return "non-Goose notification";
    }

    private String standardPayloadKind(String characteristicUuid, byte[] value) {
        if ("00002a37-0000-1000-8000-00805f9b34fb".equalsIgnoreCase(characteristicUuid)
                && value.length >= 2
                && (value[0] & 0x01) == 0) {
            return "standard_heart_rate";
        }
        return "standard_ble";
    }

    private JSONObject parseFrame(String frameHex) throws Exception {
        JSONObject args = new JSONObject()
                .put("device_type", "GOOSE")
                .put("frame_hex", frameHex);
        return bridge.request("protocol.parse_frame_hex", args);
    }

    private String parsedFrameSummary(JSONObject parsed) {
        String packetTypeName = parsed.optString("packet_type_name", "unknown");
        int sequence = parsed.optInt("sequence", -1);
        String payloadKind = parsedPayloadKind(parsed);
        String bodyKind = bodyKind(parsed);
        String eventName = eventName(parsed);
        StringBuilder builder = new StringBuilder("packet=")
                .append(packetTypeName)
                .append(" seq=")
                .append(sequence >= 0 ? sequence : "?")
                .append(" payload=")
                .append(payloadKind);
        if (!bodyKind.isEmpty()) {
            builder.append(" body=").append(bodyKind);
        }
        if (!eventName.isEmpty()) {
            builder.append(" event=").append(eventName);
        }
        JSONArray warnings = parsed.optJSONArray("warnings");
        builder.append(" warnings=").append(warnings != null ? warnings.length() : 0);
        return builder.toString();
    }

    private String parsedPayloadKind(JSONObject parsed) {
        JSONObject payload = parsed.optJSONObject("parsed_payload");
        return payload != null ? payload.optString("kind", "") : "";
    }

    private String bodyKind(JSONObject parsed) {
        JSONObject payload = parsed.optJSONObject("parsed_payload");
        if (payload == null) {
            return "";
        }
        JSONObject bodySummary = payload.optJSONObject("body_summary");
        return bodySummary != null ? bodySummary.optString("kind", "") : "";
    }

    private String eventName(JSONObject parsed) {
        JSONObject payload = parsed.optJSONObject("parsed_payload");
        return payload != null ? payload.optString("event_name", "") : "";
    }

    private JSONObject importFrame(
            String frameHex,
            String serviceUuid,
            String characteristicUuid,
            long capturedAtMillis,
            String captureSessionId
    ) throws Exception {
        frameCounter += 1;
        String evidenceId = UUID.randomUUID().toString();
        String frameId = "android-live-" + capturedAtMillis + "-" + frameCounter;
        String capturedAt = iso8601(capturedAtMillis);
        String source = "goose-android/live-notification/" + serviceUuid + "/" + characteristicUuid;
        JSONObject row = new JSONObject()
                .put("evidence_id", evidenceId)
                .put("frame_id", frameId)
                .put("source", source)
                .put("captured_at", capturedAt)
                .put("device_model", "WHOOP 5.0 Goose Android")
                .put("frame_hex", frameHex)
                .put("sensitivity", "raw_device_evidence")
                .put("device_type", "GOOSE");
        if (captureSessionId == null) {
            row.put("capture_session_id", JSONObject.NULL);
        } else {
            row.put("capture_session_id", captureSessionId);
        }

        JSONObject args = new JSONObject()
                .put("database_path", databaseFile.getAbsolutePath())
                .put("parser_version", "goose-android/live-notification")
                .put("include_timeline_rows", false)
                .put("compact_raw_payloads", false)
                .put("include_results", false)
                .put("frames", new JSONArray().put(row));

        JSONObject report;
        try {
            report = bridge.request("capture.import_frame_batch", args);
        } catch (Exception error) {
            report = new JSONObject()
                    .put("raw_inserted", 0)
                    .put("frames_inserted", 0)
                    .put("frames_existing", 0)
                    .put("issues", new JSONArray().put(error.toString()));
        }
        boolean directInserted = insertRawEvidenceDirect(
                evidenceId,
                source,
                capturedAt,
                frameHex,
                captureSessionId
        );
        report.put("direct_raw_inserted", directInserted ? 1 : 0);
        return report;
    }

    private boolean insertRawEvidenceDirect(
            String evidenceId,
            String source,
            String capturedAt,
            String payloadHex,
            String captureSessionId
    ) throws Exception {
        ContentValues values = new ContentValues();
        values.put("evidence_id", evidenceId);
        values.put("source", source);
        values.put("captured_at", capturedAt);
        values.put("device_model", "WHOOP 5.0 Goose Android");
        values.put("payload_hex", payloadHex);
        values.put("sha256", sha256Hex(Hex.decode(payloadHex)));
        values.put("sensitivity", "raw_device_evidence");
        if (captureSessionId != null) {
            values.put("capture_session_id", captureSessionId);
        }
        SQLiteDatabase database = SQLiteDatabase.openDatabase(databaseFile.getAbsolutePath(), null, SQLiteDatabase.OPEN_READWRITE);
        try {
            return database.insertWithOnConflict("raw_evidence", null, values, SQLiteDatabase.CONFLICT_IGNORE) != -1;
        } finally {
            database.close();
        }
    }

    private String sha256Hex(byte[] value) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        return Hex.encode(digest.digest(value));
    }

    private String iso8601(long millis) {
        SimpleDateFormat formatter = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US);
        formatter.setTimeZone(TimeZone.getTimeZone("UTC"));
        return formatter.format(new Date(millis));
    }
}
