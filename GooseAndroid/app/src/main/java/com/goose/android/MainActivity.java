package com.goose.android;

import android.app.Activity;
import android.os.Bundle;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import org.json.JSONObject;

import java.text.SimpleDateFormat;
import java.util.ArrayDeque;
import java.util.Date;
import java.util.Deque;
import java.util.List;
import java.util.Locale;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class MainActivity extends Activity implements GooseBleClient.Listener {
    private static final int PERMISSION_REQUEST_BLE = 1001;
    private static final int MAX_NOTIFICATION_LOG_ROWS = 40;
    private static final int MAX_NOTIFICATION_HEX_CHARS = 160;
    private static final int MAX_REPORT_CHARS = 12000;
    private static final long COMMAND_CONFIRM_WINDOW_MS = 15000L;

    private final GooseRustBridge bridge = new GooseRustBridge();
    private final Deque<String> notificationLogRows = new ArrayDeque<>();
    private final ExecutorService sessionExecutor = Executors.newSingleThreadExecutor();
    private GooseBleClient ble;
    private GooseCommandBuilder commandBuilder;
    private GoosePacketIngestor packetIngestor;
    private GooseStoreReporter storeReporter;
    private HealthConnectSupport healthConnectSupport;
    private LinearLayout deviceList;
    private TextView bridgeStatus;
    private TextView bleStatus;
    private TextView storeStatus;
    private TextView metadataStatus;
    private TextView packetStatus;
    private TextView sessionStatus;
    private TextView healthConnectStatus;
    private TextView reportStatus;
    private TextView notificationLog;
    private LinearLayout captureSection;
    private LinearLayout reportsSection;
    private LinearLayout opsSection;
    private LinearLayout logSection;
    private EditText manualStepsInput;
    private String validationStart = "0000";
    private String validationEnd = "9999";
    private String activeCaptureSessionId;
    private PendingCommand pendingCommand;
    private int notificationCount;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        ble = new GooseBleClient(this, this);
        commandBuilder = new GooseCommandBuilder();
        packetIngestor = new GoosePacketIngestor(this);
        storeReporter = new GooseStoreReporter(this, packetIngestor.databasePath());
        healthConnectSupport = new HealthConnectSupport(this);
        setContentView(buildContentView());
        refreshBridgeStatus();
        refreshPermissionState();
    }

    @Override
    protected void onDestroy() {
        ble.close();
        commandBuilder.close();
        packetIngestor.close();
        storeReporter.close();
        sessionExecutor.shutdownNow();
        super.onDestroy();
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == PERMISSION_REQUEST_BLE) {
            refreshPermissionState();
        } else if (requestCode == HealthConnectSupport.REQUEST_HEALTH_CONNECT) {
            refreshHealthConnectStatus();
        }
    }

    @Override
    public void onStateChanged(String status) {
        runOnUiThread(() -> {
            if (status.toLowerCase(Locale.US).contains("disconnect")) {
                pendingCommand = null;
            }
            bleStatus.setText(status);
        });
    }

    @Override
    public void onDevicesChanged(List<GooseBleClient.DeviceRow> devices) {
        runOnUiThread(() -> {
            deviceList.removeAllViews();
            if (devices.isEmpty()) {
                TextView empty = bodyText("No WHOOP devices discovered");
                deviceList.addView(empty);
                return;
            }
            for (GooseBleClient.DeviceRow device : devices) {
                Button button = new Button(this);
                button.setAllCaps(false);
                button.setGravity(Gravity.START | Gravity.CENTER_VERTICAL);
                button.setText(device.displayText());
                button.setOnClickListener(view -> ble.connect(device.address));
                deviceList.addView(button, matchWrap());
            }
        });
    }

    @Override
    public void onNotification(GooseBleClient.GooseNotification notification) {
        notificationCount += 1;
        String stamp = new SimpleDateFormat("HH:mm:ss", Locale.US).format(new Date(notification.capturedAtMillis));
        packetIngestor.ingest(notification, result -> runOnUiThread(() -> {
            String summary = result.error != null
                    ? result.error
                    : result.parseSummary + "\n" + result.importSummary;
            packetStatus.setText("Notifications: " + notificationCount + "\n" + summary);
            appendNotificationLog(stamp, notification.characteristicUuid, result.frameHex);
        }));
    }

    @Override
    public void onMetadataChanged(String metadata) {
        runOnUiThread(() -> metadataStatus.setText(metadata));
    }

    private void refreshStoreStatus() {
        try {
            JSONObject args = new JSONObject()
                    .put("database_path", packetIngestor.databasePath())
                    .put("self_test", true);
            JSONObject report = bridge.request("storage.check", args);
            storeStatus.setText("Store: " + packetIngestor.databasePath() + "\n" + report.toString(2));
        } catch (Exception error) {
            storeStatus.setText("Store check failed\n" + packetIngestor.databasePath() + "\n" + error);
        }
    }

    private void refreshAllStatus() {
        refreshBridgeStatus();
        refreshStoreStatus();
        refreshPermissionState();
    }

    private View buildContentView() {
        ScrollView scroll = new ScrollView(this);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(40, 40, 40, 40);
        scroll.addView(root);

        TextView title = new TextView(this);
        title.setText("Goose Android");
        title.setTextSize(28);
        title.setGravity(Gravity.START);
        root.addView(title);

        LinearLayout modeActions = new LinearLayout(this);
        modeActions.setOrientation(LinearLayout.HORIZONTAL);
        modeActions.setPadding(0, 18, 0, 0);
        Button captureModeButton = new Button(this);
        captureModeButton.setText("Capture");
        captureModeButton.setOnClickListener(view -> showMode(captureSection));
        modeActions.addView(captureModeButton, weightWrap());
        Button reportsModeButton = new Button(this);
        reportsModeButton.setText("Reports");
        reportsModeButton.setOnClickListener(view -> showMode(reportsSection));
        modeActions.addView(reportsModeButton, weightWrap());
        Button opsModeButton = new Button(this);
        opsModeButton.setText("Ops");
        opsModeButton.setOnClickListener(view -> showMode(opsSection));
        modeActions.addView(opsModeButton, weightWrap());
        Button logModeButton = new Button(this);
        logModeButton.setText("Log");
        logModeButton.setOnClickListener(view -> showMode(logSection));
        modeActions.addView(logModeButton, weightWrap());
        root.addView(modeActions);

        reportStatus = bodyText("No report run");
        reportStatus.setPadding(0, 12, 0, 0);
        root.addView(reportStatus);

        captureSection = sectionContainer();
        reportsSection = sectionContainer();
        opsSection = sectionContainer();
        logSection = sectionContainer();
        root.addView(captureSection);
        root.addView(reportsSection);
        root.addView(opsSection);
        root.addView(logSection);

        bridgeStatus = bodyText("Checking Rust bridge");
        bridgeStatus.setPadding(0, 24, 0, 0);
        captureSection.addView(bridgeStatus);

        storeStatus = bodyText("Checking local store");
        storeStatus.setPadding(0, 18, 0, 0);
        captureSection.addView(storeStatus);

        LinearLayout actions = new LinearLayout(this);
        actions.setOrientation(LinearLayout.HORIZONTAL);
        actions.setPadding(0, 24, 0, 0);
        Button refreshButton = new Button(this);
        refreshButton.setText("Refresh");
        refreshButton.setOnClickListener(view -> refreshAllStatus());
        actions.addView(refreshButton, weightWrap());
        Button permissionButton = new Button(this);
        permissionButton.setText("Permissions");
        permissionButton.setOnClickListener(view -> requestBlePermissions());
        actions.addView(permissionButton, weightWrap());
        Button scanButton = new Button(this);
        scanButton.setText("Scan");
        scanButton.setOnClickListener(view -> ble.startScan());
        actions.addView(scanButton, weightWrap());
        Button stopButton = new Button(this);
        stopButton.setText("Stop");
        stopButton.setOnClickListener(view -> ble.stopScan());
        actions.addView(stopButton, weightWrap());
        captureSection.addView(actions);

        bleStatus = sectionText("Bluetooth: not started");
        captureSection.addView(bleStatus);

        metadataStatus = bodyText("No device metadata read");
        metadataStatus.setPadding(0, 8, 0, 0);
        captureSection.addView(metadataStatus);

        TextView devicesTitle = sectionText("Devices");
        captureSection.addView(devicesTitle);
        deviceList = new LinearLayout(this);
        deviceList.setOrientation(LinearLayout.VERTICAL);
        deviceList.addView(bodyText("No WHOOP devices discovered"));
        captureSection.addView(deviceList);

        packetStatus = sectionText("Packets: waiting");
        captureSection.addView(packetStatus);

        sessionStatus = bodyText("Capture session: none");
        sessionStatus.setPadding(0, 8, 0, 0);
        captureSection.addView(sessionStatus);

        healthConnectStatus = bodyText("Health Connect: not checked");
        healthConnectStatus.setPadding(0, 8, 0, 0);
        opsSection.addView(healthConnectStatus);

        TextView reportsTitle = sectionText("Health and debug reports");
        reportsSection.addView(reportsTitle);

        LinearLayout reportActionsTop = new LinearLayout(this);
        reportActionsTop.setOrientation(LinearLayout.HORIZONTAL);
        Button readinessButton = new Button(this);
        readinessButton.setText("Readiness");
        readinessButton.setOnClickListener(view -> runReport(storeReporter::readiness));
        reportActionsTop.addView(readinessButton, weightWrap());
        Button timelineButton = new Button(this);
        timelineButton.setText("Timeline");
        timelineButton.setOnClickListener(view -> runReport(storeReporter::captureTimeline));
        reportActionsTop.addView(timelineButton, weightWrap());
        reportsSection.addView(reportActionsTop);

        LinearLayout reportActionsBottom = new LinearLayout(this);
        reportActionsBottom.setOrientation(LinearLayout.HORIZONTAL);
        Button commandsButton = new Button(this);
        commandsButton.setText("Commands");
        commandsButton.setOnClickListener(view -> runReport(storeReporter::commandDefinitions));
        reportActionsBottom.addView(commandsButton, weightWrap());
        Button exportButton = new Button(this);
        exportButton.setText("Export");
        exportButton.setOnClickListener(view -> runReport(storeReporter::rawExport));
        reportActionsBottom.addView(exportButton, weightWrap());
        Button backfillButton = new Button(this);
        backfillButton.setText("Backfill");
        backfillButton.setOnClickListener(view -> runReport(storeReporter::decodeBackfill));
        reportActionsBottom.addView(backfillButton, weightWrap());
        opsSection.addView(reportActionsBottom);

        LinearLayout commandActions = new LinearLayout(this);
        commandActions.setOrientation(LinearLayout.HORIZONTAL);
        Button gateButton = new Button(this);
        gateButton.setText("Gate");
        gateButton.setOnClickListener(view -> runReport(storeReporter::commandGate));
        commandActions.addView(gateButton, weightWrap());
        Button preflightButton = new Button(this);
        preflightButton.setText("Preflight");
        preflightButton.setOnClickListener(view -> runReport(storeReporter::commandPreflight));
        commandActions.addView(preflightButton, weightWrap());
        Button recordsButton = new Button(this);
        recordsButton.setText("Records");
        recordsButton.setOnClickListener(view -> runReport(storeReporter::commandValidationRecords));
        commandActions.addView(recordsButton, weightWrap());
        opsSection.addView(commandActions);

        LinearLayout physicalCommandActions = new LinearLayout(this);
        physicalCommandActions.setOrientation(LinearLayout.HORIZONTAL);
        Button rangeButton = new Button(this);
        rangeButton.setText("Range");
        rangeButton.setOnClickListener(view -> sendBuiltCommand("get_data_range", ""));
        physicalCommandActions.addView(rangeButton, weightWrap());
        Button historyButton = new Button(this);
        historyButton.setText("History");
        historyButton.setOnClickListener(view -> sendBuiltCommand("send_historical_data", ""));
        physicalCommandActions.addView(historyButton, weightWrap());
        Button abortHistoryButton = new Button(this);
        abortHistoryButton.setText("Abort");
        abortHistoryButton.setOnClickListener(view -> sendBuiltCommand("abort_historical_transmits", ""));
        physicalCommandActions.addView(abortHistoryButton, weightWrap());
        captureSection.addView(physicalCommandActions);

        LinearLayout captureActions = new LinearLayout(this);
        captureActions.setOrientation(LinearLayout.HORIZONTAL);
        Button captureStartButton = new Button(this);
        captureStartButton.setText("Cap Start");
        captureStartButton.setOnClickListener(view -> startCaptureSession());
        captureActions.addView(captureStartButton, weightWrap());
        Button captureEndButton = new Button(this);
        captureEndButton.setText("Cap End");
        captureEndButton.setOnClickListener(view -> finishCaptureSession());
        captureActions.addView(captureEndButton, weightWrap());
        Button captureListButton = new Button(this);
        captureListButton.setText("Sessions");
        captureListButton.setOnClickListener(view -> listCaptureSessions());
        captureActions.addView(captureListButton, weightWrap());
        captureSection.addView(captureActions);

        LinearLayout metricActions = new LinearLayout(this);
        metricActions.setOrientation(LinearLayout.HORIZONTAL);
        Button heartRateButton = new Button(this);
        heartRateButton.setText("HR");
        heartRateButton.setOnClickListener(view -> runReport(storeReporter::heartRateFeatures));
        metricActions.addView(heartRateButton, weightWrap());
        Button stepsButton = new Button(this);
        stepsButton.setText("Steps");
        stepsButton.setOnClickListener(view -> runReport(storeReporter::stepDiscovery));
        metricActions.addView(stepsButton, weightWrap());
        Button sensorsButton = new Button(this);
        sensorsButton.setText("Sensors");
        sensorsButton.setOnClickListener(view -> runReport(storeReporter::recoverySensors));
        metricActions.addView(sensorsButton, weightWrap());
        reportsSection.addView(metricActions);

        LinearLayout opsActions = new LinearLayout(this);
        opsActions.setOrientation(LinearLayout.HORIZONTAL);
        Button storageButton = new Button(this);
        storageButton.setText("Storage");
        storageButton.setOnClickListener(view -> runReport(storeReporter::storagePrivacy));
        opsActions.addView(storageButton, weightWrap());
        Button lintButton = new Button(this);
        lintButton.setText("Privacy");
        lintButton.setOnClickListener(view -> runReport(storeReporter::exportPrivacyLint));
        opsActions.addView(lintButton, weightWrap());
        Button healthConnectButton = new Button(this);
        healthConnectButton.setText("HC Dry");
        healthConnectButton.setOnClickListener(view -> runHealthConnectDryRun());
        opsActions.addView(healthConnectButton, weightWrap());
        opsSection.addView(opsActions);

        LinearLayout healthConnectActions = new LinearLayout(this);
        healthConnectActions.setOrientation(LinearLayout.HORIZONTAL);
        Button healthConnectPermsButton = new Button(this);
        healthConnectPermsButton.setText("HC Perms");
        healthConnectPermsButton.setOnClickListener(view -> {
            healthConnectSupport.requestPermissions(this);
            refreshHealthConnectStatus();
        });
        healthConnectActions.addView(healthConnectPermsButton, weightWrap());
        Button healthConnectSettingsButton = new Button(this);
        healthConnectSettingsButton.setText("HC Settings");
        healthConnectSettingsButton.setOnClickListener(view -> healthConnectSupport.openSettings(this));
        healthConnectActions.addView(healthConnectSettingsButton, weightWrap());
        opsSection.addView(healthConnectActions);

        LinearLayout validationActions = new LinearLayout(this);
        validationActions.setOrientation(LinearLayout.HORIZONTAL);
        manualStepsInput = new EditText(this);
        manualStepsInput.setSingleLine(true);
        manualStepsInput.setText("100");
        manualStepsInput.setInputType(InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_FLAG_SIGNED);
        validationActions.addView(manualStepsInput, weightWrap());
        Button validationStartButton = new Button(this);
        validationStartButton.setText("Start");
        validationStartButton.setOnClickListener(view -> markValidationStart());
        validationActions.addView(validationStartButton, weightWrap());
        Button validationEndButton = new Button(this);
        validationEndButton.setText("End");
        validationEndButton.setOnClickListener(view -> markValidationEnd());
        validationActions.addView(validationEndButton, weightWrap());
        Button validationRunButton = new Button(this);
        validationRunButton.setText("Validate");
        validationRunButton.setOnClickListener(view -> runStepValidation());
        validationActions.addView(validationRunButton, weightWrap());
        captureSection.addView(validationActions);

        notificationLog = bodyText("No notifications");
        notificationLog.setPadding(0, 16, 0, 0);
        logSection.addView(notificationLog);

        showMode(captureSection);
        refreshHealthConnectStatus();

        return scroll;
    }

    private void refreshBridgeStatus() {
        try {
            JSONObject version = bridge.request("core.version");
            bridgeStatus.setText("Rust bridge ready\n" + version.toString(2));
        } catch (Exception error) {
            bridgeStatus.setText("Rust bridge failed\n" + error);
        }
    }

    private void refreshPermissionState() {
        bleStatus.setText(ble.hasRuntimePermissions() ? "Bluetooth permissions granted" : "Bluetooth permissions required");
        refreshStoreStatus();
    }

    private void requestBlePermissions() {
        List<String> permissions = ble.requiredPermissions();
        requestPermissions(permissions.toArray(new String[0]), PERMISSION_REQUEST_BLE);
    }

    private void refreshHealthConnectStatus() {
        if (healthConnectStatus != null) {
            healthConnectStatus.setText(healthConnectSupport.status());
        }
    }

    private void runReport(ReportRunner runner) {
        reportStatus.setText("Running report...");
        runner.run(report -> runOnUiThread(() -> reportStatus.setText(truncateForDisplay(report))));
    }

    private void runHealthConnectDryRun() {
        reportStatus.setText("Running Health Connect dry run...");
        refreshHealthConnectStatus();
        storeReporter.healthConnectDryRun(
                healthConnectSupport.grantedPermissions(),
                report -> runOnUiThread(() -> reportStatus.setText(truncateForDisplay(report)))
        );
    }

    private void sendBuiltCommand(String command, String payloadHex) {
        long now = System.currentTimeMillis();
        if (pendingCommand != null
                && pendingCommand.matches(command, payloadHex)
                && pendingCommand.expiresAtMillis > now) {
            PendingCommand commandToSend = pendingCommand;
            pendingCommand = null;
            if (!ble.commandReady()) {
                packetStatus.setText("Command blocked: no connected WHOOP command characteristic"
                        + "\n" + commandToSend.frameHex
                        + "\n" + commandToSend.preflightSummary);
                return;
            }
            packetStatus.setText("Sending confirmed " + commandToSend.command
                    + "\n" + commandToSend.frameHex
                    + "\n" + commandToSend.preflightSummary);
            ble.sendCommandFrame("command " + commandToSend.command, commandToSend.frame);
            return;
        }
        pendingCommand = null;
        packetStatus.setText("Preparing command: " + command);
        commandBuilder.build(command, payloadHex, result -> runOnUiThread(() -> {
            if (result.error != null) {
                packetStatus.setText("Command build failed: " + result.error);
                return;
            }
            prepareCommandConfirmation(result, payloadHex);
        }));
    }

    private void prepareCommandConfirmation(GooseCommandBuilder.Result result, String payloadHex) {
        long now = System.currentTimeMillis();
        long expiresAt = now + COMMAND_CONFIRM_WINDOW_MS;
        packetStatus.setText("Checking command preflight: " + result.command + "\n" + result.frameHex);
        sessionExecutor.execute(() -> {
            String summary = commandPreflightSummary(result.command, result.frameHex, now, expiresAt);
            PendingCommand preparedCommand = new PendingCommand(
                    result.command,
                    payloadHex,
                    result.frameHex,
                    result.frame.clone(),
                    expiresAt,
                    summary
            );
            runOnUiThread(() -> {
                pendingCommand = preparedCommand;
                packetStatus.setText("Prepared " + result.command
                        + "\nTap " + displayCommandName(result.command) + " again within "
                        + (COMMAND_CONFIRM_WINDOW_MS / 1000) + "s to send."
                        + "\n" + result.frameHex
                        + "\n" + summary);
            });
        });
    }

    private String commandPreflightSummary(String command, String frameHex, long now, long expiresAt) {
        try {
            JSONObject args = new JSONObject()
                    .put("database_path", packetIngestor.databasePath())
                    .put("command", command)
                    .put("now_unix_ms", now)
                    .put("override_expires_at_unix_ms", expiresAt)
                    .put("visible_user_intent", true)
                    .put("dry_run_bytes_shown", true)
                    .put("dry_run_frame_hex", frameHex)
                    .put("dry_run_service_uuid", ble.commandServiceUuid())
                    .put("dry_run_characteristic_uuid", ble.commandCharacteristicUuid())
                    .put("dry_run_write_type", ble.commandWriteType())
                    .put("session_log_ready", true)
                    .put("connection_state", ble.commandReady() ? "connected" : "disconnected")
                    .put("active_device_id", ble.activeDeviceId() != null ? ble.activeDeviceId() : "")
                    .put("critical_visible_confirmation", true)
                    .put("critical_explicit_approval", true)
                    .put("critical_rollback_or_restore_acknowledged", true);
            JSONObject report = bridge.request("commands.direct_send_preflight", args);
            return "Preflight allowed: " + report.optBoolean("direct_send_allowed", false)
                    + "\nMissing: " + report.optJSONArray("missing_requirements")
                    + "\nWarnings: " + report.optJSONArray("warnings");
        } catch (Exception error) {
            return "Preflight failed: " + error;
        }
    }

    private String displayCommandName(String command) {
        if ("get_data_range".equals(command)) {
            return "Range";
        }
        if ("send_historical_data".equals(command)) {
            return "History";
        }
        if ("abort_historical_transmits".equals(command)) {
            return "Abort";
        }
        return command;
    }

    private void startCaptureSession() {
        if (activeCaptureSessionId != null) {
            sessionStatus.setText("Capture session active\n" + activeCaptureSessionId);
            return;
        }
        String sessionId = "android-" + iso8601(System.currentTimeMillis())
                .replace(":", "")
                .replace(".", "")
                .replace("-", "")
                + "-" + UUID.randomUUID().toString().substring(0, 8);
        long startedAt = System.currentTimeMillis();
        sessionStatus.setText("Starting capture session\n" + sessionId);
        sessionExecutor.execute(() -> {
            try {
                JSONObject args = new JSONObject()
                        .put("database_path", packetIngestor.databasePath())
                        .put("session_id", sessionId)
                        .put("source", "goose-android/manual-capture")
                        .put("started_at_unix_ms", startedAt)
                        .put("device_model", "WHOOP 5.0 Goose Android")
                        .put("provenance", new JSONObject()
                                .put("capture_app", "goose_android")
                                .put("capture_kind", "manual_android_session")
                                .put("step_decoding_status", "parked"));
                bridge.request("capture.start_session", args);
                packetIngestor.startCaptureSession(sessionId);
                activeCaptureSessionId = sessionId;
                runOnUiThread(() -> sessionStatus.setText("Capture session active\n" + sessionId));
            } catch (Exception error) {
                runOnUiThread(() -> sessionStatus.setText("Capture session start failed\n" + error));
            }
        });
    }

    private void finishCaptureSession() {
        String sessionId = activeCaptureSessionId != null
                ? activeCaptureSessionId
                : packetIngestor.activeCaptureSessionId();
        if (sessionId == null) {
            sessionStatus.setText("Capture session: none");
            return;
        }
        int frameCount = packetIngestor.finishCaptureSession(sessionId);
        activeCaptureSessionId = null;
        long endedAt = System.currentTimeMillis();
        sessionStatus.setText("Finishing capture session\n" + sessionId);
        sessionExecutor.execute(() -> {
            try {
                JSONObject args = new JSONObject()
                        .put("database_path", packetIngestor.databasePath())
                        .put("session_id", sessionId)
                        .put("ended_at_unix_ms", endedAt)
                        .put("frame_count", frameCount);
                JSONObject report = bridge.request("capture.finish_session", args);
                runOnUiThread(() -> sessionStatus.setText("Capture session finished\n"
                        + sessionId
                        + "\nframes: " + frameCount
                        + "\n" + summarizeSession(report.optJSONObject("session"))));
            } catch (Exception error) {
                runOnUiThread(() -> sessionStatus.setText("Capture session finish failed\n" + error));
            }
        });
    }

    private void listCaptureSessions() {
        reportStatus.setText("Loading capture sessions...");
        sessionExecutor.execute(() -> {
            try {
                JSONObject args = new JSONObject()
                        .put("database_path", packetIngestor.databasePath())
                        .put("start_unix_ms", 0)
                        .put("end_unix_ms", System.currentTimeMillis() + 86400000L);
                JSONObject report = bridge.request("capture.list_sessions", args);
                runOnUiThread(() -> reportStatus.setText(captureSessionListSummary(report)));
            } catch (Exception error) {
                runOnUiThread(() -> reportStatus.setText("Capture sessions failed\n" + error));
            }
        });
    }

    private void markValidationStart() {
        validationStart = iso8601(System.currentTimeMillis());
        reportStatus.setText("Step validation start\n" + validationStart);
    }

    private void markValidationEnd() {
        validationEnd = iso8601(System.currentTimeMillis());
        reportStatus.setText("Step validation end\n" + validationEnd);
    }

    private void runStepValidation() {
        long manualSteps;
        try {
            manualSteps = Long.parseLong(manualStepsInput.getText().toString().trim());
        } catch (NumberFormatException error) {
            reportStatus.setText("Manual steps must be a number");
            return;
        }
        reportStatus.setText("Running step validation...");
        storeReporter.stepValidation(validationStart, validationEnd, manualSteps,
                report -> runOnUiThread(() -> reportStatus.setText(truncateForDisplay(report))));
    }

    private void appendNotificationLog(String stamp, String characteristicUuid, String frameHex) {
        String displayHex = truncateHex(frameHex);
        notificationLogRows.addFirst(stamp + " " + characteristicUuid + "\n" + displayHex);
        while (notificationLogRows.size() > MAX_NOTIFICATION_LOG_ROWS) {
            notificationLogRows.removeLast();
        }
        StringBuilder log = new StringBuilder();
        for (String row : notificationLogRows) {
            if (log.length() > 0) {
                log.append("\n\n");
            }
            log.append(row);
        }
        notificationLog.setText(log.toString());
    }

    private String truncateHex(String frameHex) {
        if (frameHex.length() <= MAX_NOTIFICATION_HEX_CHARS) {
            return frameHex;
        }
        return frameHex.substring(0, MAX_NOTIFICATION_HEX_CHARS)
                + "... (" + (frameHex.length() / 2) + " bytes)";
    }

    private String truncateForDisplay(String value) {
        if (value.length() <= MAX_REPORT_CHARS) {
            return value;
        }
        return value.substring(0, MAX_REPORT_CHARS)
                + "\n\n[truncated " + (value.length() - MAX_REPORT_CHARS) + " chars for display]";
    }

    private String captureSessionListSummary(JSONObject report) {
        StringBuilder builder = new StringBuilder("Capture sessions\ncount: ")
                .append(report.optInt("session_count", 0));
        org.json.JSONArray sessions = report.optJSONArray("sessions");
        if (sessions == null) {
            return builder.toString();
        }
        int start = Math.max(0, sessions.length() - 8);
        for (int index = sessions.length() - 1; index >= start; index -= 1) {
            JSONObject session = sessions.optJSONObject(index);
            if (session != null) {
                builder.append("\n\n").append(summarizeSession(session));
            }
        }
        return builder.toString();
    }

    private String summarizeSession(JSONObject session) {
        if (session == null) {
            return "session: unavailable";
        }
        return session.optString("session_id", "unknown")
                + "\nstatus: " + session.optString("status", "unknown")
                + ", frames: " + session.optInt("frame_count", 0)
                + "\nstarted: " + session.optLong("started_at_unix_ms", 0)
                + ", ended: " + session.optLong("ended_at_unix_ms", 0);
    }

    private String iso8601(long millis) {
        SimpleDateFormat formatter = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US);
        formatter.setTimeZone(java.util.TimeZone.getTimeZone("UTC"));
        return formatter.format(new Date(millis));
    }

    private interface ReportRunner {
        void run(GooseStoreReporter.Callback callback);
    }

    private static final class PendingCommand {
        final String command;
        final String payloadHex;
        final String frameHex;
        final byte[] frame;
        final long expiresAtMillis;
        final String preflightSummary;

        PendingCommand(
                String command,
                String payloadHex,
                String frameHex,
                byte[] frame,
                long expiresAtMillis,
                String preflightSummary
        ) {
            this.command = command;
            this.payloadHex = payloadHex;
            this.frameHex = frameHex;
            this.frame = frame;
            this.expiresAtMillis = expiresAtMillis;
            this.preflightSummary = preflightSummary;
        }

        boolean matches(String command, String payloadHex) {
            return this.command.equals(command) && this.payloadHex.equals(payloadHex);
        }
    }

    private TextView sectionText(String value) {
        TextView view = bodyText(value);
        view.setTextSize(18);
        view.setPadding(0, 28, 0, 8);
        return view;
    }

    private TextView bodyText(String value) {
        TextView view = new TextView(this);
        view.setText(value);
        view.setTextSize(15);
        view.setGravity(Gravity.START);
        return view;
    }

    private LinearLayout sectionContainer() {
        LinearLayout section = new LinearLayout(this);
        section.setOrientation(LinearLayout.VERTICAL);
        return section;
    }

    private void showMode(LinearLayout visibleSection) {
        if (captureSection == null || reportsSection == null || opsSection == null || logSection == null) {
            return;
        }
        captureSection.setVisibility(visibleSection == captureSection ? View.VISIBLE : View.GONE);
        reportsSection.setVisibility(visibleSection == reportsSection ? View.VISIBLE : View.GONE);
        opsSection.setVisibility(visibleSection == opsSection ? View.VISIBLE : View.GONE);
        logSection.setVisibility(visibleSection == logSection ? View.VISIBLE : View.GONE);
    }

    private LinearLayout.LayoutParams matchWrap() {
        return new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
        );
    }

    private LinearLayout.LayoutParams weightWrap() {
        return new LinearLayout.LayoutParams(
                0,
                LinearLayout.LayoutParams.WRAP_CONTENT,
                1
        );
    }
}
