package com.goose.android;

import android.app.Activity;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import org.json.JSONObject;

import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.List;
import java.util.Locale;

public final class MainActivity extends Activity implements GooseBleClient.Listener {
    private static final int PERMISSION_REQUEST_BLE = 1001;

    private final GooseRustBridge bridge = new GooseRustBridge();
    private GooseBleClient ble;
    private GooseCommandBuilder commandBuilder;
    private GoosePacketIngestor packetIngestor;
    private GooseStoreReporter storeReporter;
    private LinearLayout deviceList;
    private TextView bridgeStatus;
    private TextView bleStatus;
    private TextView storeStatus;
    private TextView metadataStatus;
    private TextView packetStatus;
    private TextView reportStatus;
    private TextView notificationLog;
    private int notificationCount;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        ble = new GooseBleClient(this, this);
        commandBuilder = new GooseCommandBuilder();
        packetIngestor = new GoosePacketIngestor(this);
        storeReporter = new GooseStoreReporter(this, packetIngestor.databasePath());
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
        super.onDestroy();
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == PERMISSION_REQUEST_BLE) {
            refreshPermissionState();
        }
    }

    @Override
    public void onStateChanged(String status) {
        runOnUiThread(() -> bleStatus.setText(status));
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
            notificationLog.setText(stamp + " " + notification.characteristicUuid + "\n" + result.frameHex + "\n\n" + notificationLog.getText());
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

        bridgeStatus = bodyText("Checking Rust bridge");
        bridgeStatus.setPadding(0, 24, 0, 0);
        root.addView(bridgeStatus);

        storeStatus = bodyText("Checking local store");
        storeStatus.setPadding(0, 18, 0, 0);
        root.addView(storeStatus);

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
        root.addView(actions);

        bleStatus = sectionText("Bluetooth: not started");
        root.addView(bleStatus);

        metadataStatus = bodyText("No device metadata read");
        metadataStatus.setPadding(0, 8, 0, 0);
        root.addView(metadataStatus);

        TextView devicesTitle = sectionText("Devices");
        root.addView(devicesTitle);
        deviceList = new LinearLayout(this);
        deviceList.setOrientation(LinearLayout.VERTICAL);
        deviceList.addView(bodyText("No WHOOP devices discovered"));
        root.addView(deviceList);

        packetStatus = sectionText("Packets: waiting");
        root.addView(packetStatus);

        TextView reportsTitle = sectionText("Health and debug reports");
        root.addView(reportsTitle);

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
        root.addView(reportActionsTop);

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
        root.addView(reportActionsBottom);

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
        root.addView(commandActions);

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
        root.addView(physicalCommandActions);

        reportStatus = bodyText("No report run");
        reportStatus.setPadding(0, 12, 0, 0);
        root.addView(reportStatus);

        notificationLog = bodyText("No notifications");
        notificationLog.setPadding(0, 16, 0, 0);
        root.addView(notificationLog);

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

    private void runReport(ReportRunner runner) {
        reportStatus.setText("Running report...");
        runner.run(report -> runOnUiThread(() -> reportStatus.setText(report)));
    }

    private void sendBuiltCommand(String command, String payloadHex) {
        packetStatus.setText("Building command: " + command);
        commandBuilder.build(command, payloadHex, result -> runOnUiThread(() -> {
            if (result.error != null) {
                packetStatus.setText("Command build failed: " + result.error);
                return;
            }
            packetStatus.setText("Sending " + result.command + "\n" + result.frameHex);
            ble.sendCommandFrame("command " + result.command, result.frame);
        }));
    }

    private interface ReportRunner {
        void run(GooseStoreReporter.Callback callback);
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
