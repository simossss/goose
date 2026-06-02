package com.goose.android;

import android.content.Context;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
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
        final String error;

        Result(String frameHex, String parseSummary, String importSummary, String error) {
            this.frameHex = frameHex;
            this.parseSummary = parseSummary;
            this.importSummary = importSummary;
            this.error = error;
        }
    }

    private final GooseRustBridge bridge = new GooseRustBridge();
    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final File databaseFile;
    private int frameCounter;

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
        executor.execute(() -> callback.onIngested(ingestNow(value, serviceUuid, characteristicUuid, capturedAtMillis)));
    }

    void close() {
        executor.shutdownNow();
    }

    private Result ingestNow(byte[] value, String serviceUuid, String characteristicUuid, long capturedAtMillis) {
        String frameHex = Hex.encode(value);
        try {
            String parseSummary = parseFrame(frameHex);
            JSONObject importReport = importFrame(frameHex, serviceUuid, characteristicUuid, capturedAtMillis);
            String importSummary = "raw inserted "
                    + importReport.optInt("raw_inserted", 0)
                    + ", decoded inserted "
                    + importReport.optInt("frames_inserted", 0)
                    + ", existing "
                    + importReport.optInt("frames_existing", 0);
            return new Result(frameHex, parseSummary, importSummary, null);
        } catch (Exception error) {
            return new Result(frameHex, "", "", error.toString());
        }
    }

    private String parseFrame(String frameHex) throws Exception {
        JSONObject args = new JSONObject()
                .put("device_type", "Goose")
                .put("frame_hex", frameHex);
        JSONObject parsed = bridge.request("protocol.parse_frame_hex", args);
        String summary = parsed.optString("summary", "");
        if (!summary.isEmpty()) {
            return summary;
        }
        return parsed.toString(2);
    }

    private JSONObject importFrame(
            String frameHex,
            String serviceUuid,
            String characteristicUuid,
            long capturedAtMillis
    ) throws Exception {
        frameCounter += 1;
        String frameId = "android-live-" + capturedAtMillis + "-" + frameCounter;
        JSONObject row = new JSONObject()
                .put("evidence_id", UUID.randomUUID().toString())
                .put("frame_id", frameId)
                .put("source", "goose-android/live-notification/" + serviceUuid + "/" + characteristicUuid)
                .put("captured_at", iso8601(capturedAtMillis))
                .put("device_model", "WHOOP 5.0 Goose Android")
                .put("frame_hex", frameHex)
                .put("sensitivity", "raw_device_evidence")
                .put("capture_session_id", JSONObject.NULL)
                .put("device_type", "Goose");

        JSONObject args = new JSONObject()
                .put("database_path", databaseFile.getAbsolutePath())
                .put("parser_version", "goose-android/live-notification")
                .put("include_timeline_rows", false)
                .put("compact_raw_payloads", false)
                .put("include_results", false)
                .put("frames", new JSONArray().put(row));

        return bridge.request("capture.import_frame_batch", args);
    }

    private String iso8601(long millis) {
        SimpleDateFormat formatter = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US);
        formatter.setTimeZone(TimeZone.getTimeZone("UTC"));
        return formatter.format(new Date(millis));
    }
}
