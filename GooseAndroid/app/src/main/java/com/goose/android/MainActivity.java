package com.goose.android;

import android.app.Activity;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import org.json.JSONArray;
import org.json.JSONObject;

import java.text.SimpleDateFormat;
import java.util.ArrayDeque;
import java.util.ArrayList;
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
    private static final int MAX_COMMAND_LOG_ROWS = 12;
    private static final int MAX_RENDERED_DEVICE_ROWS = 8;
    private static final int MAX_NOTIFICATION_HEX_CHARS = 160;
    private static final int MAX_REPORT_CHARS = 12000;
    private static final long COMMAND_CONFIRM_WINDOW_MS = 15000L;
    private static final int COLOR_BACKGROUND = Color.rgb(248, 250, 252);
    private static final int COLOR_PANEL = Color.WHITE;
    private static final int COLOR_TEXT = Color.rgb(15, 23, 42);
    private static final int COLOR_MUTED = Color.rgb(71, 85, 105);
    private static final int COLOR_BORDER = Color.rgb(203, 213, 225);
    private static final int COLOR_PRIMARY = Color.rgb(37, 99, 235);
    private static final int COLOR_DANGER = Color.rgb(185, 28, 28);

    private final GooseRustBridge bridge = new GooseRustBridge();
    private final Deque<String> notificationLogRows = new ArrayDeque<>();
    private final Deque<String> commandLogRows = new ArrayDeque<>();
    private final TransferProgress transferProgress = new TransferProgress();
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
    private TextView connectionStatus;
    private TextView packetStatus;
    private TextView transferStatus;
    private TextView commandStatus;
    private TextView sessionStatus;
    private TextView healthConnectStatus;
    private TextView reportStatus;
    private TextView notificationLog;
    private LinearLayout captureSection;
    private LinearLayout reportsSection;
    private LinearLayout opsSection;
    private LinearLayout logSection;
    private final List<Button> modeButtons = new ArrayList<>();
    private EditText manualStepsInput;
    private String validationStart = "0000";
    private String validationEnd = "9999";
    private volatile String activeCaptureSessionId;
    private volatile String lastFinishedCaptureSessionId;
    private PendingCommand pendingCommand;
    private long clearLocalDataConfirmUntilMillis;
    private int notificationCount;
    private boolean destroyed;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        destroyed = false;
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
        destroyed = true;
        ble.close();
        commandBuilder.close();
        packetIngestor.close();
        storeReporter.close();
        healthConnectSupport.close();
        sessionExecutor.shutdownNow();
        super.onDestroy();
    }

    private void runOnUiThreadIfAlive(Runnable action) {
        runOnUiThread(() -> {
            if (!destroyed && !isFinishing()) {
                action.run();
            }
        });
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
        runOnUiThreadIfAlive(() -> {
            if (status.toLowerCase(Locale.US).contains("disconnect")) {
                pendingCommand = null;
            }
            bleStatus.setText(status);
        });
    }

    @Override
    public void onDevicesChanged(List<GooseBleClient.DeviceRow> devices) {
        runOnUiThreadIfAlive(() -> {
            deviceList.removeAllViews();
            if (devices.isEmpty()) {
                TextView empty = bodyText("No WHOOP devices discovered");
                deviceList.addView(empty);
                return;
            }
            int rendered = Math.min(devices.size(), MAX_RENDERED_DEVICE_ROWS);
            for (int index = 0; index < rendered; index += 1) {
                GooseBleClient.DeviceRow device = devices.get(index);
                Button button = secondaryButton(device.displayText());
                button.setGravity(Gravity.START | Gravity.CENTER_VERTICAL);
                button.setOnClickListener(view -> connectToDevice(device));
                deviceList.addView(button, matchWrap());
            }
            if (devices.size() > rendered) {
                deviceList.addView(bodyText("Showing " + rendered + " of " + devices.size() + " devices"), matchWrap());
            }
        });
    }

    @Override
    public void onNotification(GooseBleClient.GooseNotification notification) {
        notificationCount += 1;
        String stamp = new SimpleDateFormat("HH:mm:ss", Locale.US).format(new Date(notification.capturedAtMillis));
        packetIngestor.ingest(notification, result -> runOnUiThreadIfAlive(() -> {
            String summary = result.error != null
                    ? result.error
                    : result.parseSummary + "\n" + result.importSummary;
            packetStatus.setText("Notifications: " + notificationCount + "\n" + summary);
            transferProgress.recordPacket(result, notification.capturedAtMillis);
            transferStatus.setText(transferProgress.summary());
            appendNotificationLog(stamp, notification.characteristicUuid, result.frameHex);
        }));
    }

    @Override
    public void onMetadataChanged(String metadata) {
        runOnUiThreadIfAlive(() -> metadataStatus.setText(metadata));
    }

    @Override
    public void onCommandEvent(GooseBleClient.CommandEvent event) {
        String stamp = new SimpleDateFormat("HH:mm:ss", Locale.US).format(new Date(event.occurredAtMillis));
        runOnUiThreadIfAlive(() -> {
            transferProgress.recordCommand(event);
            transferStatus.setText(transferProgress.summary());
            appendCommandRow(commandEventSummary(stamp, event));
        });
    }

    @Override
    public void onConnectionProgress(GooseBleClient.ConnectionProgress progress) {
        BleSessionAudit.appendProgress(this, progress);
        runOnUiThreadIfAlive(() -> {
            if (connectionStatus != null) {
                connectionStatus.setText(connectionProgressSummary(progress));
            }
        });
    }

    private void refreshStoreStatus() {
        storeStatus.setText("Checking local store...");
        sessionExecutor.execute(() -> {
            try {
                JSONObject args = new JSONObject()
                        .put("database_path", packetIngestor.databasePath())
                        .put("self_test", true);
                JSONObject report = bridge.request("storage.check", args);
                runOnUiThreadIfAlive(() -> storeStatus.setText(compactStoreSummary(report)));
            } catch (Exception error) {
                runOnUiThreadIfAlive(() -> storeStatus.setText(
                        "Store check failed\n" + packetIngestor.databasePath() + "\n" + error));
            }
        });
    }

    private void refreshAllStatus() {
        refreshBridgeStatus();
        refreshStoreStatus();
        refreshPermissionState();
    }

    private View buildContentView() {
        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(COLOR_BACKGROUND);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(40, 40, 40, 40);
        scroll.addView(root);

        TextView title = new TextView(this);
        title.setText("Goose");
        title.setTextSize(32);
        title.setTextColor(COLOR_TEXT);
        title.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        title.setGravity(Gravity.START);
        root.addView(title);

        LinearLayout modeActions = new LinearLayout(this);
        modeActions.setOrientation(LinearLayout.HORIZONTAL);
        modeActions.setPadding(0, 18, 0, 0);
        Button captureModeButton = modeButton("Capture");
        captureModeButton.setOnClickListener(view -> showMode(captureSection, captureModeButton));
        modeActions.addView(captureModeButton, weightWrap());
        Button reportsModeButton = modeButton("Insights");
        reportsModeButton.setOnClickListener(view -> showMode(reportsSection, reportsModeButton));
        modeActions.addView(reportsModeButton, weightWrap());
        Button opsModeButton = modeButton("More");
        opsModeButton.setOnClickListener(view -> showMode(opsSection, opsModeButton));
        modeActions.addView(opsModeButton, weightWrap());
        Button logModeButton = modeButton("Log");
        logModeButton.setOnClickListener(view -> showMode(logSection, logModeButton));
        modeActions.addView(logModeButton, weightWrap());
        root.addView(modeActions);

        reportStatus = statusText("No report run");
        LinearLayout.LayoutParams reportStatusParams = matchWrap();
        reportStatusParams.setMargins(0, 12, 0, 0);
        root.addView(reportStatus, reportStatusParams);

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
        captureSection.addView(sectionText("Connection"));

        Button refreshButton = secondaryButton("Refresh");
        refreshButton.setOnClickListener(view -> refreshAllStatus());
        actions.addView(refreshButton, weightWrap());
        Button permissionButton = secondaryButton("Permissions");
        permissionButton.setOnClickListener(view -> requestBlePermissions());
        actions.addView(permissionButton, weightWrap());
        Button scanButton = primaryButton("Scan");
        scanButton.setOnClickListener(view -> ble.startScan());
        actions.addView(scanButton, weightWrap());
        Button stopButton = secondaryButton("Stop");
        stopButton.setOnClickListener(view -> ble.stopScan());
        actions.addView(stopButton, weightWrap());
        captureSection.addView(actions);

        bleStatus = sectionText("Bluetooth: not started");
        captureSection.addView(bleStatus);

        metadataStatus = bodyText("No device metadata read");
        metadataStatus.setPadding(0, 8, 0, 0);
        captureSection.addView(metadataStatus);

        connectionStatus = bodyText("Connection progress\nphase: not started");
        connectionStatus.setPadding(0, 8, 0, 0);
        captureSection.addView(connectionStatus);

        TextView devicesTitle = sectionText("Devices");
        captureSection.addView(devicesTitle);
        deviceList = new LinearLayout(this);
        deviceList.setOrientation(LinearLayout.VERTICAL);
        deviceList.addView(bodyText("No WHOOP devices discovered"));
        captureSection.addView(deviceList);

        packetStatus = sectionText("Packets: waiting");
        captureSection.addView(packetStatus);

        transferStatus = bodyText(transferProgress.summary());
        transferStatus.setPadding(0, 8, 0, 0);
        captureSection.addView(transferStatus);

        sessionStatus = bodyText("Capture session: none");
        sessionStatus.setPadding(0, 8, 0, 0);
        captureSection.addView(sessionStatus);

        healthConnectStatus = bodyText("Health Connect: not checked");
        healthConnectStatus.setPadding(0, 8, 0, 0);
        opsSection.addView(healthConnectStatus);

        TextView reportsTitle = sectionText("Insights");
        reportsSection.addView(reportsTitle);

        LinearLayout reportActionsTop = new LinearLayout(this);
        reportActionsTop.setOrientation(LinearLayout.HORIZONTAL);
        Button readinessButton = secondaryButton("Readiness");
        readinessButton.setOnClickListener(view -> runReport(storeReporter::readiness));
        reportActionsTop.addView(readinessButton, weightWrap());
        Button timelineButton = secondaryButton("Timeline");
        timelineButton.setOnClickListener(view -> runReport(storeReporter::captureTimeline));
        reportActionsTop.addView(timelineButton, weightWrap());
        reportsSection.addView(reportActionsTop);

        LinearLayout reportActionsBottom = new LinearLayout(this);
        reportActionsBottom.setOrientation(LinearLayout.HORIZONTAL);
        Button commandsButton = secondaryButton("Commands");
        commandsButton.setOnClickListener(view -> runReport(storeReporter::commandDefinitions));
        reportActionsBottom.addView(commandsButton, weightWrap());
        Button exportButton = primaryButton("Export");
        exportButton.setOnClickListener(view -> runReport(storeReporter::rawExport));
        reportActionsBottom.addView(exportButton, weightWrap());
        Button backfillButton = secondaryButton("Backfill");
        backfillButton.setOnClickListener(view -> runReport(storeReporter::decodeBackfill));
        reportActionsBottom.addView(backfillButton, weightWrap());
        opsSection.addView(reportActionsBottom);

        LinearLayout commandActions = new LinearLayout(this);
        commandActions.setOrientation(LinearLayout.HORIZONTAL);
        Button gateButton = secondaryButton("Gate");
        gateButton.setOnClickListener(view -> runReport(storeReporter::commandGate));
        commandActions.addView(gateButton, weightWrap());
        Button preflightButton = secondaryButton("Preflight");
        preflightButton.setOnClickListener(view -> runReport(storeReporter::commandPreflight));
        commandActions.addView(preflightButton, weightWrap());
        Button recordsButton = secondaryButton("Records");
        recordsButton.setOnClickListener(view -> runReport(storeReporter::commandValidationRecords));
        commandActions.addView(recordsButton, weightWrap());
        opsSection.addView(commandActions);

        LinearLayout physicalCommandActions = new LinearLayout(this);
        physicalCommandActions.setOrientation(LinearLayout.HORIZONTAL);
        captureSection.addView(sectionText("Commands"));
        Button rangeButton = primaryButton("Range");
        rangeButton.setOnClickListener(view -> sendBuiltCommand("get_data_range", ""));
        physicalCommandActions.addView(rangeButton, weightWrap());
        Button historyButton = primaryButton("History");
        historyButton.setOnClickListener(view -> sendBuiltCommand("send_historical_data", ""));
        physicalCommandActions.addView(historyButton, weightWrap());
        Button abortHistoryButton = dangerButton("Abort");
        abortHistoryButton.setOnClickListener(view -> sendBuiltCommand("abort_historical_transmits", ""));
        physicalCommandActions.addView(abortHistoryButton, weightWrap());
        captureSection.addView(physicalCommandActions);

        commandStatus = bodyText("Command results: none");
        commandStatus.setPadding(0, 8, 0, 0);
        captureSection.addView(commandStatus);

        LinearLayout captureActions = new LinearLayout(this);
        captureActions.setOrientation(LinearLayout.HORIZONTAL);
        captureSection.addView(sectionText("Capture session"));
        Button captureStartButton = primaryButton("Start");
        captureStartButton.setOnClickListener(view -> startCaptureSession());
        captureActions.addView(captureStartButton, weightWrap());
        Button captureEndButton = secondaryButton("Finish");
        captureEndButton.setOnClickListener(view -> finishCaptureSession());
        captureActions.addView(captureEndButton, weightWrap());
        Button captureListButton = secondaryButton("Sessions");
        captureListButton.setText("Sessions");
        captureListButton.setOnClickListener(view -> listCaptureSessions());
        captureActions.addView(captureListButton, weightWrap());
        captureSection.addView(captureActions);

        LinearLayout metricActions = new LinearLayout(this);
        metricActions.setOrientation(LinearLayout.HORIZONTAL);
        Button heartRateButton = secondaryButton("Heart");
        heartRateButton.setOnClickListener(view -> runReport(storeReporter::heartRateFeatures));
        metricActions.addView(heartRateButton, weightWrap());
        Button stepsButton = secondaryButton("Steps");
        stepsButton.setOnClickListener(view -> runReport(storeReporter::stepDiscovery));
        metricActions.addView(stepsButton, weightWrap());
        Button sensorsButton = secondaryButton("Sensors");
        sensorsButton.setOnClickListener(view -> runReport(storeReporter::recoverySensors));
        metricActions.addView(sensorsButton, weightWrap());
        Button blockedButton = secondaryButton("Blocked");
        blockedButton.setOnClickListener(view -> runReport(storeReporter::unavailableStatuses));
        metricActions.addView(blockedButton, weightWrap());
        reportsSection.addView(metricActions);

        opsSection.addView(sectionText("More"));

        LinearLayout opsActions = new LinearLayout(this);
        opsActions.setOrientation(LinearLayout.HORIZONTAL);
        Button storageButton = secondaryButton("Storage");
        storageButton.setOnClickListener(view -> runReport(storeReporter::storagePrivacy));
        opsActions.addView(storageButton, weightWrap());
        Button lintButton = secondaryButton("Privacy");
        lintButton.setOnClickListener(view -> runReport(storeReporter::exportPrivacyLint));
        opsActions.addView(lintButton, weightWrap());
        Button healthConnectButton = secondaryButton("Health Gate");
        healthConnectButton.setOnClickListener(view -> runHealthConnectDryRun());
        opsActions.addView(healthConnectButton, weightWrap());
        Button healthConnectSyncButton = primaryButton("Sync");
        healthConnectSyncButton.setOnClickListener(view -> runHealthConnectSync());
        opsActions.addView(healthConnectSyncButton, weightWrap());
        opsSection.addView(opsActions);

        LinearLayout evidenceActions = new LinearLayout(this);
        evidenceActions.setOrientation(LinearLayout.HORIZONTAL);
        Button evidenceButton = secondaryButton("Evidence");
        evidenceButton.setOnClickListener(view -> runReport(storeReporter::evidenceReadiness));
        evidenceActions.addView(evidenceButton, weightWrap());
        opsSection.addView(evidenceActions);

        LinearLayout storageActions = new LinearLayout(this);
        storageActions.setOrientation(LinearLayout.HORIZONTAL);
        Button exportsButton = secondaryButton("Exports");
        exportsButton.setOnClickListener(view -> runReport(storeReporter::exportInventory));
        storageActions.addView(exportsButton, weightWrap());
        Button clearExportsButton = secondaryButton("Clear Exports");
        clearExportsButton.setOnClickListener(view -> runStorageMutation(storeReporter::clearExports));
        storageActions.addView(clearExportsButton, weightWrap());
        Button clearDataButton = dangerButton("Delete Data");
        clearDataButton.setOnClickListener(view -> confirmOrClearLocalData());
        storageActions.addView(clearDataButton, weightWrap());
        opsSection.addView(storageActions);

        LinearLayout healthConnectActions = new LinearLayout(this);
        healthConnectActions.setOrientation(LinearLayout.HORIZONTAL);
        Button healthConnectPermsButton = primaryButton("Permissions");
        healthConnectPermsButton.setOnClickListener(view -> {
            healthConnectSupport.requestPermissions(this);
            refreshHealthConnectStatus();
        });
        healthConnectActions.addView(healthConnectPermsButton, weightWrap());
        Button healthConnectSettingsButton = secondaryButton("Settings");
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
        Button validationStartButton = secondaryButton("Mark Start");
        validationStartButton.setOnClickListener(view -> markValidationStart());
        validationActions.addView(validationStartButton, weightWrap());
        Button validationEndButton = secondaryButton("Mark End");
        validationEndButton.setOnClickListener(view -> markValidationEnd());
        validationActions.addView(validationEndButton, weightWrap());
        Button validationRunButton = primaryButton("Validate");
        validationRunButton.setOnClickListener(view -> runStepValidation());
        validationActions.addView(validationRunButton, weightWrap());
        captureSection.addView(validationActions);

        notificationLog = bodyText("No notifications");
        notificationLog.setPadding(0, 16, 0, 0);
        logSection.addView(notificationLog);

        showMode(captureSection, captureModeButton);
        refreshHealthConnectStatus();

        return scroll;
    }

    private void refreshBridgeStatus() {
        bridgeStatus.setText("Checking Rust bridge...");
        sessionExecutor.execute(() -> {
            try {
                JSONObject version = bridge.request("core.version");
                String summary = "Rust bridge ready\n" + version.toString(2);
                runOnUiThreadIfAlive(() -> bridgeStatus.setText(summary));
            } catch (Exception error) {
                runOnUiThreadIfAlive(() -> bridgeStatus.setText("Rust bridge failed\n" + error));
            }
        });
    }

    private void refreshPermissionState() {
        bleStatus.setText(ble.hasRuntimePermissions() ? "Bluetooth permissions granted" : "Bluetooth permissions required");
        refreshStoreStatus();
    }

    private void requestBlePermissions() {
        List<String> permissions = ble.requiredPermissions();
        requestPermissions(permissions.toArray(new String[0]), PERMISSION_REQUEST_BLE);
    }

    private void connectToDevice(GooseBleClient.DeviceRow device) {
        bleStatus.setText("Connecting " + device.name);
        if (connectionStatus != null) {
            connectionStatus.setText("Connection progress\nphase: connecting\nselected: " + device.address);
        }
        deviceList.removeAllViews();
        TextView selected = bodyText(device.displayText());
        selected.setPadding(0, 8, 0, 8);
        deviceList.addView(selected, matchWrap());
        ble.connect(device.address);
    }

    private void refreshHealthConnectStatus() {
        if (healthConnectStatus != null) {
            healthConnectStatus.setText(healthConnectSupport.status());
        }
    }

    private void runReport(ReportRunner runner) {
        reportStatus.setText("Running report...");
        runner.run(report -> runOnUiThreadIfAlive(() -> reportStatus.setText(truncateForDisplay(report))));
    }

    private void runHealthConnectDryRun() {
        reportStatus.setText("Running Health Connect dry run...");
        refreshHealthConnectStatus();
        storeReporter.healthConnectDryRun(
                healthConnectSupport.healthSyncPermissionGrants(),
                report -> runOnUiThreadIfAlive(() -> reportStatus.setText(truncateForDisplay(report)))
        );
    }

    private void runHealthConnectSync() {
        reportStatus.setText("Planning Health Connect sync...");
        refreshHealthConnectStatus();
        storeReporter.healthConnectDryRunPlan(
                healthConnectSupport.healthSyncPermissionGrants(),
                (report, summary) -> runOnUiThreadIfAlive(() -> {
                    if (report == null) {
                        reportStatus.setText(truncateForDisplay(summary));
                        return;
                    }
                    if (report.optInt("planned_write_count", 0) == 0) {
                        reportStatus.setText(truncateForDisplay(summary
                                + "\n\nHealth Connect sync\nNo planned writes. Capture and decode Goose-owned metrics first."));
                        return;
                    }
                    reportStatus.setText(truncateForDisplay(summary + "\n\nWriting Health Connect records..."));
                    healthConnectSupport.writePlannedRecords(report,
                            writeReport -> runOnUiThreadIfAlive(() -> {
                                reportStatus.setText(truncateForDisplay(summary + "\n\n" + writeReport));
                                refreshHealthConnectStatus();
                            }));
                })
        );
    }

    private void runStorageMutation(ReportRunner runner) {
        reportStatus.setText("Running storage operation...");
        runner.run(report -> runOnUiThreadIfAlive(() -> {
            reportStatus.setText(truncateForDisplay(report));
            refreshStoreStatus();
        }));
    }

    private void confirmOrClearLocalData() {
        long now = System.currentTimeMillis();
        if (now > clearLocalDataConfirmUntilMillis) {
            clearLocalDataConfirmUntilMillis = now + 15000L;
            reportStatus.setText("Clear local data armed\nTap Clear Data again within 15s to delete local SQLite data.");
            return;
        }
        clearLocalDataConfirmUntilMillis = 0L;
        packetIngestor.clearCaptureSession();
        activeCaptureSessionId = null;
        sessionStatus.setText("Capture session: none");
        runStorageMutation(storeReporter::clearLocalData);
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
                transferProgress.recordBlockedCommand(commandToSend.command, System.currentTimeMillis());
                transferStatus.setText(transferProgress.summary());
                appendCommandRow(commandBlockedSummary(commandToSend));
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
        commandBuilder.build(command, payloadHex, result -> runOnUiThreadIfAlive(() -> {
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
        PendingCommand preparedCommand = new PendingCommand(
                result.command,
                payloadHex,
                result.frameHex,
                result.frame.clone(),
                expiresAt,
                "Preflight pending"
        );
        pendingCommand = preparedCommand;
        packetStatus.setText("Prepared " + result.command
                + "\nTap " + displayCommandName(result.command) + " again within "
                + (COMMAND_CONFIRM_WINDOW_MS / 1000) + "s to send."
                + "\n" + result.frameHex
                + "\nPreflight pending");
        sessionExecutor.execute(() -> {
            String summary = commandPreflightSummary(result.command, result.frameHex, now, expiresAt);
            PendingCommand updatedCommand = new PendingCommand(
                    result.command,
                    payloadHex,
                    result.frameHex,
                    result.frame.clone(),
                    expiresAt,
                    summary
            );
            runOnUiThreadIfAlive(() -> {
                if (pendingCommand == null
                        || !pendingCommand.matches(result.command, payloadHex)
                        || !pendingCommand.frameHex.equals(result.frameHex)) {
                    return;
                }
                pendingCommand = updatedCommand;
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
                runOnUiThreadIfAlive(() -> sessionStatus.setText("Capture session active\n" + sessionId));
            } catch (Exception error) {
                runOnUiThreadIfAlive(() -> sessionStatus.setText("Capture session start failed\n" + error));
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
                lastFinishedCaptureSessionId = sessionId;
                runOnUiThreadIfAlive(() -> sessionStatus.setText("Capture session finished\n"
                        + sessionId
                        + "\nframes: " + frameCount
                        + "\n" + summarizeSession(report.optJSONObject("session"))));
            } catch (Exception error) {
                runOnUiThreadIfAlive(() -> sessionStatus.setText("Capture session finish failed\n" + error));
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
                runOnUiThreadIfAlive(() -> reportStatus.setText(captureSessionListSummary(report)));
            } catch (Exception error) {
                runOnUiThreadIfAlive(() -> reportStatus.setText("Capture sessions failed\n" + error));
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
        String captureSessionId = activeCaptureSessionId != null
                ? activeCaptureSessionId
                : lastFinishedCaptureSessionId;
        if (captureSessionId == null) {
            reportStatus.setText("Running step validation...\n"
                    + "capture session: none\n"
                    + "Final phone evidence needs an active or recently finished capture session.");
        } else {
            reportStatus.setText("Running step validation...\n"
                    + "capture session: " + captureSessionId);
        }
        storeReporter.stepValidation(validationStart, validationEnd, manualSteps, captureSessionId,
                report -> runOnUiThreadIfAlive(() -> reportStatus.setText(truncateForDisplay(report))));
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

    private void appendCommandRow(String row) {
        commandLogRows.addFirst(row);
        while (commandLogRows.size() > MAX_COMMAND_LOG_ROWS) {
            commandLogRows.removeLast();
        }
        StringBuilder log = new StringBuilder("Command results");
        for (String commandRow : commandLogRows) {
            log.append("\n\n").append(commandRow);
        }
        if (commandStatus != null) {
            commandStatus.setText(log.toString());
        }
    }

    private String commandEventSummary(String stamp, GooseBleClient.CommandEvent event) {
        String endpoint = event.serviceUuid.isEmpty() || event.characteristicUuid.isEmpty()
                ? "endpoint: unavailable"
                : event.writeType + " " + event.serviceUuid + " / " + event.characteristicUuid;
        StringBuilder builder = new StringBuilder(stamp)
                .append(" ")
                .append(event.status)
                .append(" ")
                .append(event.label)
                .append('\n')
                .append(endpoint)
                .append('\n')
                .append(truncateHex(event.frameHex));
        if (event.error != null) {
            builder.append('\n').append(event.error);
        }
        return builder.toString();
    }

    private String commandBlockedSummary(PendingCommand command) {
        String stamp = new SimpleDateFormat("HH:mm:ss", Locale.US).format(new Date());
        return stamp
                + " blocked command " + command.command
                + "\nno connected WHOOP command characteristic"
                + "\n" + truncateHex(command.frameHex);
    }

    private String connectionProgressSummary(GooseBleClient.ConnectionProgress progress) {
        StringBuilder builder = new StringBuilder("Connection progress")
                .append("\nphase: ").append(progress.phase)
                .append(" at ").append(new SimpleDateFormat("HH:mm:ss", Locale.US).format(new Date(progress.occurredAtMillis)));
        if (!progress.deviceId.isEmpty()) {
            builder.append("\ndevice: ").append(progress.deviceId);
        }
        builder.append("\ndevices seen: ").append(progress.discoveredDeviceCount)
                .append("\nservices: ").append(progress.serviceCount)
                .append(", interesting: ").append(progress.interestingServiceCount)
                .append("\nnotify candidates: ").append(progress.notificationCandidateCount)
                .append(", reads: ").append(progress.readCandidateCount)
                .append("\nGATT queued: ").append(progress.queuedOperationCount)
                .append(", completed: ").append(progress.completedOperationCount)
                .append(", subscribed: ").append(progress.subscriptionCount)
                .append("\ncommand ready: ").append(progress.commandReady)
                .append(", hello sent: ").append(progress.helloSent);
        if (progress.error != null) {
            builder.append("\nerror: ").append(progress.error);
        }
        return builder.toString();
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

    private String compactStoreSummary(JSONObject report) {
        return "Store: " + packetIngestor.databasePath()
                + "\npass: " + report.optBoolean("pass", false)
                + ", storage ready: " + report.optBoolean("storage_ready", false)
                + "\nschema: " + report.optInt("actual_schema_version", -1)
                + " / expected " + report.optInt("expected_schema_version", -1)
                + "\nraw: " + tableRowCount(report, "raw_evidence")
                + ", decoded: " + tableRowCount(report, "decoded_frames")
                + ", sessions: " + tableRowCount(report, "capture_sessions")
                + ", steps: " + tableRowCount(report, "step_counter_samples")
                + "\nissues: " + report.optJSONArray("issues")
                + "\nFull storage/privacy details are in More.";
    }

    private int tableRowCount(JSONObject report, String tableName) {
        JSONArray tables = report.optJSONArray("tables");
        if (tables == null) {
            return 0;
        }
        for (int index = 0; index < tables.length(); index += 1) {
            JSONObject table = tables.optJSONObject(index);
            if (table != null && tableName.equals(table.optString("table"))) {
                return table.optInt("row_count", 0);
            }
        }
        return 0;
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

    private static final class TransferProgress {
        private String historyCommandStatus = "not requested";
        private String transferState = "idle";
        private String lastPacket = "none";
        private long requestedAtMillis;
        private long lastPacketAtMillis;
        private int notificationCount;
        private int gooseFrameCount;
        private int standardHeartRateCount;
        private int commandResponseCount;
        private int dataPacketCount;
        private int eventCount;
        private int normalHistoryCount;
        private int rawMotionCount;
        private int opticalCount;
        private int decodedInserted;
        private int rawInserted;
        private int existingDecoded;
        private boolean historyStartSeen;
        private boolean historyEndSeen;
        private boolean historyCompleteSeen;

        void recordCommand(GooseBleClient.CommandEvent event) {
            String label = event.label.toLowerCase(Locale.US);
            if (label.contains("send_historical_data")) {
                historyCommandStatus = event.status;
                requestedAtMillis = event.occurredAtMillis;
                if ("queued".equals(event.status) || "writing".equals(event.status) || "written".equals(event.status)) {
                    transferState = "history requested";
                } else if ("failed".equals(event.status) || "blocked".equals(event.status)) {
                    transferState = "history request " + event.status;
                }
            } else if (label.contains("abort_historical_transmits")) {
                historyCommandStatus = "abort " + event.status;
                transferState = "abort " + event.status;
            }
        }

        void recordBlockedCommand(String command, long occurredAtMillis) {
            if ("send_historical_data".equals(command)) {
                historyCommandStatus = "blocked";
                requestedAtMillis = occurredAtMillis;
                transferState = "history request blocked";
            } else if ("abort_historical_transmits".equals(command)) {
                historyCommandStatus = "abort blocked";
                requestedAtMillis = occurredAtMillis;
                transferState = "abort blocked";
            }
        }

        void recordPacket(GoosePacketIngestor.Result result, long capturedAtMillis) {
            notificationCount += 1;
            lastPacketAtMillis = capturedAtMillis;
            rawInserted += result.rawInserted + result.directRawInserted;
            decodedInserted += result.framesInserted;
            existingDecoded += result.framesExisting;
            if (result.error != null) {
                transferState = "ingest error";
                lastPacket = result.error;
                return;
            }

            String payloadKind = result.payloadKind;
            String bodyKind = result.bodyKind;
            if ("standard_heart_rate".equals(payloadKind)) {
                standardHeartRateCount += 1;
            } else if (!payloadKind.isEmpty()) {
                gooseFrameCount += 1;
            }
            if ("command_response".equals(payloadKind)) {
                commandResponseCount += 1;
            } else if ("data_packet".equals(payloadKind)) {
                dataPacketCount += 1;
            } else if ("event".equals(payloadKind)) {
                eventCount += 1;
            }

            if ("normal_history".equals(bodyKind)) {
                normalHistoryCount += 1;
            } else if ("raw_motion_k10".equals(bodyKind) || "raw_motion_k21".equals(bodyKind)) {
                rawMotionCount += 1;
            } else if ("r17_optical_or_labrador_filtered".equals(bodyKind)) {
                opticalCount += 1;
            }

            updateHistoryMarkers(result.eventName);
            if (historyCompleteSeen) {
                transferState = "history complete marker seen";
            } else if (historyEndSeen) {
                transferState = "history end marker seen";
            } else if (historyStartSeen || normalHistoryCount > 0 || dataPacketCount > 0) {
                transferState = "importing history packets";
            } else if (standardHeartRateCount > 0 && gooseFrameCount == 0) {
                transferState = "live heart-rate only";
            }

            lastPacket = compactPacketLabel(result);
        }

        String summary() {
            return "Transfer progress"
                    + "\nstate: " + transferState
                    + "\nhistory command: " + historyCommandStatus
                    + (requestedAtMillis > 0 ? " at " + time(requestedAtMillis) : "")
                    + "\nnotifications: " + notificationCount
                    + ", goose: " + gooseFrameCount
                    + ", HR: " + standardHeartRateCount
                    + "\ndata packets: " + dataPacketCount
                    + ", normal history: " + normalHistoryCount
                    + ", motion: " + rawMotionCount
                    + ", optical: " + opticalCount
                    + "\nresponses: " + commandResponseCount
                    + ", events: " + eventCount
                    + ", markers: start=" + historyStartSeen
                    + " end=" + historyEndSeen
                    + " complete=" + historyCompleteSeen
                    + "\ninserted raw: " + rawInserted
                    + ", decoded: " + decodedInserted
                    + ", existing decoded: " + existingDecoded
                    + "\nlast packet: " + lastPacket
                    + (lastPacketAtMillis > 0 ? " at " + time(lastPacketAtMillis) : "");
        }

        private void updateHistoryMarkers(String eventName) {
            String normalized = eventName.toLowerCase(Locale.US).replace("_", "").replace("-", "");
            if (normalized.contains("historystart")) {
                historyStartSeen = true;
            } else if (normalized.contains("historyend")) {
                historyEndSeen = true;
            } else if (normalized.contains("historycomplete")) {
                historyCompleteSeen = true;
            }
        }

        private String compactPacketLabel(GoosePacketIngestor.Result result) {
            StringBuilder builder = new StringBuilder();
            if (!result.packetTypeName.isEmpty()) {
                builder.append(result.packetTypeName);
            } else {
                builder.append(result.payloadKind.isEmpty() ? "unknown" : result.payloadKind);
            }
            if (result.sequence >= 0) {
                builder.append(" seq=").append(result.sequence);
            }
            if (!result.payloadKind.isEmpty()) {
                builder.append(" payload=").append(result.payloadKind);
            }
            if (!result.bodyKind.isEmpty()) {
                builder.append(" body=").append(result.bodyKind);
            }
            if (!result.eventName.isEmpty()) {
                builder.append(" event=").append(result.eventName);
            }
            return builder.toString();
        }

        private String time(long millis) {
            return new SimpleDateFormat("HH:mm:ss", Locale.US).format(new Date(millis));
        }
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
        view.setTextColor(COLOR_TEXT);
        view.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        view.setPadding(0, 28, 0, 8);
        return view;
    }

    private TextView bodyText(String value) {
        TextView view = new TextView(this);
        view.setText(value);
        view.setTextSize(15);
        view.setTextColor(COLOR_MUTED);
        view.setGravity(Gravity.START);
        return view;
    }

    private TextView statusText(String value) {
        TextView view = bodyText(value);
        view.setTextColor(COLOR_TEXT);
        view.setPadding(24, 20, 24, 20);
        view.setBackground(panelBackground(COLOR_PANEL, COLOR_BORDER, 18));
        return view;
    }

    private LinearLayout sectionContainer() {
        LinearLayout section = new LinearLayout(this);
        section.setOrientation(LinearLayout.VERTICAL);
        section.setPadding(0, 8, 0, 0);
        return section;
    }

    private Button modeButton(String label) {
        Button button = secondaryButton(label);
        modeButtons.add(button);
        return button;
    }

    private Button primaryButton(String label) {
        Button button = baseButton(label);
        button.setTextColor(Color.WHITE);
        button.setBackground(panelBackground(COLOR_PRIMARY, COLOR_PRIMARY, 14));
        return button;
    }

    private Button secondaryButton(String label) {
        Button button = baseButton(label);
        button.setTextColor(COLOR_TEXT);
        button.setBackground(panelBackground(COLOR_PANEL, COLOR_BORDER, 14));
        return button;
    }

    private Button dangerButton(String label) {
        Button button = baseButton(label);
        button.setTextColor(Color.WHITE);
        button.setBackground(panelBackground(COLOR_DANGER, COLOR_DANGER, 14));
        return button;
    }

    private Button baseButton(String label) {
        Button button = new Button(this);
        button.setAllCaps(false);
        button.setText(label);
        button.setTextSize(13);
        button.setGravity(Gravity.CENTER);
        button.setSingleLine(false);
        button.setMaxLines(2);
        button.setMinHeight(dp(44));
        return button;
    }

    private GradientDrawable panelBackground(int fillColor, int strokeColor, int radiusDp) {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setColor(fillColor);
        drawable.setCornerRadius(dp(radiusDp));
        drawable.setStroke(dp(1), strokeColor);
        return drawable;
    }

    private void showMode(LinearLayout visibleSection, Button activeButton) {
        if (captureSection == null || reportsSection == null || opsSection == null || logSection == null) {
            return;
        }
        captureSection.setVisibility(visibleSection == captureSection ? View.VISIBLE : View.GONE);
        reportsSection.setVisibility(visibleSection == reportsSection ? View.VISIBLE : View.GONE);
        opsSection.setVisibility(visibleSection == opsSection ? View.VISIBLE : View.GONE);
        logSection.setVisibility(visibleSection == logSection ? View.VISIBLE : View.GONE);
        for (Button button : modeButtons) {
            button.setTextColor(button == activeButton ? Color.WHITE : COLOR_TEXT);
            button.setBackground(button == activeButton
                    ? panelBackground(COLOR_PRIMARY, COLOR_PRIMARY, 14)
                    : panelBackground(COLOR_PANEL, COLOR_BORDER, 14));
        }
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

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
