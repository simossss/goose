package com.goose.android;

import org.json.JSONException;
import org.json.JSONObject;

final class GooseRustBridge {
    static {
        System.loadLibrary("goose_core");
        System.loadLibrary("goose_android_bridge");
    }

    private int counter = 0;

    JSONObject request(String method) throws JSONException {
        return request(method, new JSONObject());
    }

    JSONObject request(String method, JSONObject args) throws JSONException {
        counter += 1;
        JSONObject payload = new JSONObject()
                .put("schema", "goose.bridge.request.v1")
                .put("request_id", "goose-android-" + System.currentTimeMillis() + "-" + counter)
                .put("method", method)
                .put("args", args);

        String rawResponse = nativeHandleJson(payload.toString());
        JSONObject response = new JSONObject(rawResponse);
        if (!response.optBoolean("ok", false)) {
            JSONObject error = response.optJSONObject("error");
            String message = error != null ? error.optString("message", "Rust bridge method failed") : "Rust bridge method failed";
            throw new JSONException(message);
        }
        JSONObject result = response.optJSONObject("result");
        return result != null ? result : new JSONObject();
    }

    String versionJson() {
        return nativeVersionJson();
    }

    private static native String nativeHandleJson(String requestJson);

    private static native String nativeVersionJson();
}
