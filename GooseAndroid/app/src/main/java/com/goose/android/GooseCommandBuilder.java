package com.goose.android;

import org.json.JSONObject;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

final class GooseCommandBuilder {
    interface Callback {
        void onBuilt(Result result);
    }

    static final class Result {
        final String command;
        final String frameHex;
        final byte[] frame;
        final String error;

        Result(String command, String frameHex, byte[] frame, String error) {
            this.command = command;
            this.frameHex = frameHex;
            this.frame = frame;
            this.error = error;
        }
    }

    private final GooseRustBridge bridge = new GooseRustBridge();
    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private int sequence = 2;

    void build(String command, Callback callback) {
        build(command, "", callback);
    }

    void build(String command, String payloadHex, Callback callback) {
        executor.execute(() -> callback.onBuilt(buildNow(command, payloadHex)));
    }

    void close() {
        executor.shutdownNow();
    }

    private synchronized int nextSequence() {
        int current = sequence;
        sequence += 1;
        if (sequence > 250) {
            sequence = 2;
        }
        return current;
    }

    private Result buildNow(String command, String payloadHex) {
        try {
            JSONObject args = new JSONObject()
                    .put("command", command)
                    .put("sequence", nextSequence())
                    .put("payload_hex", payloadHex);
            JSONObject frame = bridge.request("commands.build_frame", args);
            String frameHex = frame.getString("frame_hex");
            return new Result(command, frameHex, Hex.decode(frameHex), null);
        } catch (Exception error) {
            return new Result(command, "", new byte[0], error.toString());
        }
    }
}
