package com.goose.android;

import android.Manifest;
import android.annotation.SuppressLint;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCallback;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
import android.bluetooth.BluetoothStatusCodes;
import android.bluetooth.le.BluetoothLeScanner;
import android.bluetooth.le.ScanCallback;
import android.bluetooth.le.ScanFilter;
import android.bluetooth.le.ScanResult;
import android.bluetooth.le.ScanSettings;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Handler;
import android.os.ParcelUuid;
import android.os.Looper;

import java.util.ArrayList;
import java.util.ArrayDeque;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Queue;
import java.util.UUID;

final class GooseBleClient {
    interface Listener {
        void onStateChanged(String status);

        void onDevicesChanged(List<DeviceRow> devices);

        void onNotification(GooseNotification notification);

        void onMetadataChanged(String metadata);

        void onCommandEvent(CommandEvent event);

        void onConnectionProgress(ConnectionProgress progress);
    }

    static final class DeviceRow {
        final String address;
        final String name;
        final int rssi;
        final String advertisementSummary;
        final boolean likelyWhoop;

        DeviceRow(String address, String name, int rssi, String advertisementSummary, boolean likelyWhoop) {
            this.address = address;
            this.name = name;
            this.rssi = rssi;
            this.advertisementSummary = advertisementSummary;
            this.likelyWhoop = likelyWhoop;
        }

        String displayText() {
            String prefix = likelyWhoop ? "WHOOP candidate: " : "";
            return prefix + name + "  " + rssi + " dBm\n" + address + "\n" + compactAdvertisementSummary();
        }

        private String compactAdvertisementSummary() {
            String[] lines = advertisementSummary.split("\\R");
            StringBuilder builder = new StringBuilder();
            int lineLimit = Math.min(lines.length, MAX_ADVERTISEMENT_DISPLAY_LINES);
            for (int index = 0; index < lineLimit; index += 1) {
                if (index > 0) {
                    builder.append('\n');
                }
                builder.append(lines[index]);
            }
            if (lines.length > MAX_ADVERTISEMENT_DISPLAY_LINES) {
                builder.append('\n')
                        .append("...")
                        .append(lines.length - MAX_ADVERTISEMENT_DISPLAY_LINES)
                        .append(" more services");
            }
            if (builder.length() > MAX_ADVERTISEMENT_DISPLAY_CHARS) {
                return builder.substring(0, MAX_ADVERTISEMENT_DISPLAY_CHARS) + "...";
            }
            return builder.toString();
        }
    }

    static final class GooseNotification {
        final String serviceUuid;
        final String characteristicUuid;
        final byte[] value;
        final long capturedAtMillis;

        GooseNotification(String serviceUuid, String characteristicUuid, byte[] value, long capturedAtMillis) {
            this.serviceUuid = serviceUuid;
            this.characteristicUuid = characteristicUuid;
            this.value = value;
            this.capturedAtMillis = capturedAtMillis;
        }
    }

    static final class CommandEvent {
        final String label;
        final String status;
        final String serviceUuid;
        final String characteristicUuid;
        final String writeType;
        final String frameHex;
        final String error;
        final long occurredAtMillis;

        CommandEvent(
                String label,
                String status,
                String serviceUuid,
                String characteristicUuid,
                String writeType,
                String frameHex,
                String error,
                long occurredAtMillis
        ) {
            this.label = label;
            this.status = status;
            this.serviceUuid = serviceUuid;
            this.characteristicUuid = characteristicUuid;
            this.writeType = writeType;
            this.frameHex = frameHex;
            this.error = error;
            this.occurredAtMillis = occurredAtMillis;
        }
    }

    static final class ConnectionProgress {
        final String phase;
        final String deviceId;
        final int discoveredDeviceCount;
        final int serviceCount;
        final int interestingServiceCount;
        final int notificationCandidateCount;
        final int readCandidateCount;
        final int queuedOperationCount;
        final int completedOperationCount;
        final int subscriptionCount;
        final String activeOperationLabel;
        final boolean commandReady;
        final boolean helloSent;
        final String error;
        final long occurredAtMillis;

        ConnectionProgress(
                String phase,
                String deviceId,
                int discoveredDeviceCount,
                int serviceCount,
                int interestingServiceCount,
                int notificationCandidateCount,
                int readCandidateCount,
                int queuedOperationCount,
                int completedOperationCount,
                int subscriptionCount,
                String activeOperationLabel,
                boolean commandReady,
                boolean helloSent,
                String error,
                long occurredAtMillis
        ) {
            this.phase = phase;
            this.deviceId = deviceId;
            this.discoveredDeviceCount = discoveredDeviceCount;
            this.serviceCount = serviceCount;
            this.interestingServiceCount = interestingServiceCount;
            this.notificationCandidateCount = notificationCandidateCount;
            this.readCandidateCount = readCandidateCount;
            this.queuedOperationCount = queuedOperationCount;
            this.completedOperationCount = completedOperationCount;
            this.subscriptionCount = subscriptionCount;
            this.activeOperationLabel = activeOperationLabel;
            this.commandReady = commandReady;
            this.helloSent = helloSent;
            this.error = error;
            this.occurredAtMillis = occurredAtMillis;
        }
    }

    private static final UUID WHOOP_GEN5_SERVICE = UUID.fromString("fd4b0001-cce1-4033-93ce-002d5875f58a");
    private static final UUID WHOOP_GEN4_SERVICE = UUID.fromString("61080001-8d6d-82b8-614a-1c8cb0f8dcc6");
    private static final UUID STANDARD_HEART_RATE_SERVICE = UUID.fromString("0000180d-0000-1000-8000-00805f9b34fb");
    private static final UUID STANDARD_HEART_RATE_MEASUREMENT = UUID.fromString("00002a37-0000-1000-8000-00805f9b34fb");
    private static final UUID BATTERY_SERVICE = UUID.fromString("0000180f-0000-1000-8000-00805f9b34fb");
    private static final UUID BATTERY_LEVEL = UUID.fromString("00002a19-0000-1000-8000-00805f9b34fb");
    private static final UUID BATTERY_LEVEL_STATUS = UUID.fromString("00002bed-0000-1000-8000-00805f9b34fb");
    private static final UUID DEVICE_INFORMATION_SERVICE = UUID.fromString("0000180a-0000-1000-8000-00805f9b34fb");
    private static final UUID MODEL_NUMBER = UUID.fromString("00002a24-0000-1000-8000-00805f9b34fb");
    private static final UUID FIRMWARE_REVISION = UUID.fromString("00002a26-0000-1000-8000-00805f9b34fb");
    private static final UUID HARDWARE_REVISION = UUID.fromString("00002a27-0000-1000-8000-00805f9b34fb");
    private static final UUID SOFTWARE_REVISION = UUID.fromString("00002a28-0000-1000-8000-00805f9b34fb");
    private static final UUID MANUFACTURER_NAME = UUID.fromString("00002a29-0000-1000-8000-00805f9b34fb");
    private static final UUID CLIENT_CHARACTERISTIC_CONFIG = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb");
    private static final byte[] CLIENT_HELLO_FRAME = Hex.decode("aa0108000001e67123019101363e5c8d");
    private static final int MAX_TRACKED_SCAN_DEVICES = 32;
    private static final int MAX_PUBLISHED_DEVICES = 8;
    private static final int MAX_ADVERTISEMENT_DISPLAY_LINES = 4;
    private static final int MAX_ADVERTISEMENT_DISPLAY_CHARS = 220;
    private static final long DEVICE_PUBLISH_INTERVAL_MS = 750;

    private final Context context;
    private final Listener listener;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final Map<String, DeviceRow> devices = new LinkedHashMap<>();
    private BluetoothAdapter adapter;
    private BluetoothGatt gatt;
    private BluetoothGattCharacteristic commandCharacteristic;
    private String activeDeviceId;
    private final Queue<GattOperation> operationQueue = new ArrayDeque<>();
    private GattOperation activeOperation;
    private boolean scanning;
    private boolean filteredScan;
    private boolean publishQueued;
    private boolean closed;
    private long lastDevicePublishAtMillis;
    private boolean clientHelloSent;
    private int subscriptionCount;
    private int completedOperationCount;
    private int serviceCount;
    private int interestingServiceCount;
    private int notificationCandidateCount;
    private int readCandidateCount;
    private final Map<String, String> metadata = new LinkedHashMap<>();

    private interface GattOperation {
        boolean start(BluetoothGatt gatt);

        String label();

        default void onStarted() {
        }

        default void onComplete(String error) {
        }
    }

    GooseBleClient(Context context, Listener listener) {
        this.context = context.getApplicationContext();
        this.listener = listener;
        BluetoothManager manager = (BluetoothManager) this.context.getSystemService(Context.BLUETOOTH_SERVICE);
        if (manager != null) {
            adapter = manager.getAdapter();
        }
    }

    boolean hasRuntimePermissions() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return context.checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED
                    && context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED;
        }
        return context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED;
    }

    List<String> requiredPermissions() {
        List<String> permissions = new ArrayList<>();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            permissions.add(Manifest.permission.BLUETOOTH_SCAN);
            permissions.add(Manifest.permission.BLUETOOTH_CONNECT);
        } else {
            permissions.add(Manifest.permission.ACCESS_FINE_LOCATION);
        }
        return permissions;
    }

    void startScan() {
        closed = false;
        if (!hasRuntimePermissions()) {
            listener.onStateChanged("Bluetooth permissions required");
            return;
        }
        if (adapter == null || !adapter.isEnabled()) {
            listener.onStateChanged("Bluetooth is unavailable or off");
            return;
        }
        BluetoothLeScanner scanner = adapter.getBluetoothLeScanner();
        if (scanner == null) {
            listener.onStateChanged("BLE scanner unavailable");
            return;
        }
        if (scanning) {
            listener.onStateChanged("Scan already running; press Stop before starting again");
            return;
        }
        devices.clear();
        publishQueued = false;
        publishDevicesNow();
        startScanner(scanner, true);
    }

    @SuppressLint("MissingPermission")
    void stopScan() {
        if (!scanning || adapter == null || !hasRuntimePermissions()) {
            return;
        }
        BluetoothLeScanner scanner = adapter.getBluetoothLeScanner();
        if (scanner != null) {
            scanner.stopScan(scanCallback);
        }
        scanning = false;
        filteredScan = false;
        publishQueued = false;
        listener.onStateChanged("Scan stopped");
        emitConnectionProgress("scan_stopped", null);
    }

    @SuppressLint("MissingPermission")
    void connect(String address) {
        closed = false;
        if (!hasRuntimePermissions()) {
            listener.onStateChanged("Bluetooth permissions required");
            return;
        }
        if (adapter == null) {
            listener.onStateChanged("Bluetooth adapter unavailable");
            return;
        }
        stopScan();
        if (gatt != null) {
            gatt.close();
            gatt = null;
        }
        BluetoothDevice device = adapter.getRemoteDevice(address);
        listener.onStateChanged("Connecting " + displayName(device));
        activeDeviceId = address;
        clientHelloSent = false;
        commandCharacteristic = null;
        resetOperations();
        resetDiscoveryCounts();
        emitConnectionProgress("connecting", null);
        gatt = device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE);
    }

    String activeDeviceId() {
        return activeDeviceId;
    }

    boolean commandReady() {
        return gatt != null && commandCharacteristic != null;
    }

    String commandServiceUuid() {
        return commandCharacteristic != null && commandCharacteristic.getService() != null
                ? commandCharacteristic.getService().getUuid().toString()
                : "";
    }

    String commandCharacteristicUuid() {
        return commandCharacteristic != null ? commandCharacteristic.getUuid().toString() : "";
    }

    String commandWriteType() {
        if (commandCharacteristic == null) {
            return "";
        }
        int properties = commandCharacteristic.getProperties();
        if ((properties & BluetoothGattCharacteristic.PROPERTY_WRITE) != 0) {
            return "withResponse";
        }
        if ((properties & BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) != 0) {
            return "withoutResponse";
        }
        return "";
    }

    void sendCommandFrame(String label, byte[] frame) {
        if (!hasRuntimePermissions()) {
            listener.onStateChanged("Bluetooth permissions required");
            emitCommandEvent(label, "blocked", frame, "Bluetooth permissions required");
            return;
        }
        if (gatt == null || commandCharacteristic == null) {
            listener.onStateChanged(label + " blocked: no connected WHOOP command characteristic");
            emitCommandEvent(label, "blocked", frame, "no connected WHOOP command characteristic");
            return;
        }
        byte[] frameCopy = frame.clone();
        operationQueue.add(new GattOperation() {
            @Override
            public boolean start(BluetoothGatt gatt) {
                return writeCommandFrame(gatt, commandCharacteristic, frameCopy, label);
            }

            @Override
            public String label() {
                return label;
            }

            @Override
            public void onStarted() {
                emitCommandEvent(label, "writing", frameCopy, null);
            }

            @Override
            public void onComplete(String error) {
                emitCommandEvent(label, error == null ? "written" : "failed", frameCopy, error);
            }
        });
        listener.onStateChanged(label + " queued");
        emitCommandEvent(label, "queued", frameCopy, null);
        drainOperationQueue(gatt);
    }

    @SuppressLint("MissingPermission")
    void close() {
        closed = true;
        mainHandler.removeCallbacksAndMessages(null);
        stopScan();
        if (gatt != null && hasRuntimePermissions()) {
            gatt.close();
        }
        gatt = null;
        activeDeviceId = null;
        scanning = false;
        filteredScan = false;
        publishQueued = false;
        resetOperations();
        resetDiscoveryCounts();
        emitConnectionProgress("closed", null);
    }

    private final ScanCallback scanCallback = new ScanCallback() {
        @Override
        public void onScanResult(int callbackType, ScanResult result) {
            if (closed || !scanning) {
                return;
            }
            BluetoothDevice device = result.getDevice();
            String name = displayName(device);
            DeviceRow row = new DeviceRow(
                    device.getAddress(),
                    name,
                    result.getRssi(),
                    advertisementSummary(result),
                    looksLikeWhoop(result)
            );
            devices.put(row.address, row);
            trimStoredDevices();
            if (row.likelyWhoop) {
                stopScan();
                publishDevicesNow();
                listener.onStateChanged("WHOOP candidate found; scan stopped so you can tap it");
                emitConnectionProgress("candidate_found", null);
            } else {
                scheduleDevicePublish();
            }
        }

        @Override
        public void onScanFailed(int errorCode) {
            if (closed) {
                return;
            }
            scanning = false;
            filteredScan = false;
            listener.onStateChanged("Scan failed: " + scanFailureName(errorCode));
            emitConnectionProgress("scan_failed", scanFailureName(errorCode));
        }
    };

    @SuppressLint("MissingPermission")
    private void startScanner(BluetoothLeScanner scanner, boolean withWhoopFilters) {
        scanning = true;
        filteredScan = withWhoopFilters;
        listener.onStateChanged(withWhoopFilters
                ? "Scanning for WHOOP advertisements"
                : "Fallback scan: showing all BLE advertisers");
        emitConnectionProgress(withWhoopFilters ? "scan_filtered" : "scan_fallback", null);

        List<ScanFilter> filters = new ArrayList<>();
        if (withWhoopFilters) {
            filters.add(new ScanFilter.Builder().setServiceUuid(new ParcelUuid(WHOOP_GEN5_SERVICE)).build());
            filters.add(new ScanFilter.Builder().setServiceUuid(new ParcelUuid(WHOOP_GEN4_SERVICE)).build());
        }
        ScanSettings settings = new ScanSettings.Builder()
                .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                .build();
        scanner.startScan(filters, settings, scanCallback);

        if (withWhoopFilters) {
            mainHandler.postDelayed(() -> {
                if (closed || !scanning || !filteredScan || hasLikelyWhoopDevice() || adapter == null || !hasRuntimePermissions()) {
                    return;
                }
                BluetoothLeScanner fallbackScanner = adapter.getBluetoothLeScanner();
                if (fallbackScanner == null) {
                    return;
                }
                fallbackScanner.stopScan(scanCallback);
                startScanner(fallbackScanner, false);
            }, 8000);
        }
    }

    private boolean looksLikeWhoop(ScanResult result) {
        BluetoothDevice device = result.getDevice();
        String name = displayName(device).toLowerCase(Locale.US);
        if (name.contains("whoop")) {
            return true;
        }
        if (result.getScanRecord() == null || result.getScanRecord().getServiceUuids() == null) {
            return false;
        }
        for (ParcelUuid serviceUuid : result.getScanRecord().getServiceUuids()) {
            UUID uuid = serviceUuid.getUuid();
            if (WHOOP_GEN5_SERVICE.equals(uuid) || WHOOP_GEN4_SERVICE.equals(uuid)) {
                return true;
            }
        }
        return false;
    }

    private boolean hasLikelyWhoopDevice() {
        for (DeviceRow row : devices.values()) {
            if (row.likelyWhoop) {
                return true;
            }
        }
        return false;
    }

    private void scheduleDevicePublish() {
        if (closed) {
            return;
        }
        long now = System.currentTimeMillis();
        if (now - lastDevicePublishAtMillis >= DEVICE_PUBLISH_INTERVAL_MS) {
            publishDevicesNow();
            return;
        }
        if (publishQueued) {
            return;
        }
        publishQueued = true;
        mainHandler.postDelayed(() -> {
            publishQueued = false;
            if (closed || !scanning) {
                return;
            }
            publishDevicesNow();
        }, DEVICE_PUBLISH_INTERVAL_MS);
    }

    private void publishDevicesNow() {
        if (closed) {
            return;
        }
        lastDevicePublishAtMillis = System.currentTimeMillis();
        listener.onDevicesChanged(cappedPublishedRows(new ArrayList<>(devices.values())));
    }

    private void trimStoredDevices() {
        if (devices.size() <= MAX_TRACKED_SCAN_DEVICES) {
            return;
        }
        List<DeviceRow> rows = cappedScanRows(new ArrayList<>(devices.values()));
        devices.clear();
        for (DeviceRow row : rows) {
            devices.put(row.address, row);
        }
    }

    static List<DeviceRow> cappedPublishedRows(List<DeviceRow> rows) {
        sortDeviceRows(rows);
        if (hasLikelyWhoop(rows)) {
            List<DeviceRow> likelyRows = new ArrayList<>();
            for (DeviceRow row : rows) {
                if (row.likelyWhoop) {
                    likelyRows.add(row);
                }
            }
            rows = likelyRows;
        }
        if (rows.size() > MAX_PUBLISHED_DEVICES) {
            return new ArrayList<>(rows.subList(0, MAX_PUBLISHED_DEVICES));
        }
        return rows;
    }

    static List<DeviceRow> cappedScanRows(List<DeviceRow> rows) {
        sortDeviceRows(rows);
        if (rows.size() > MAX_TRACKED_SCAN_DEVICES) {
            return new ArrayList<>(rows.subList(0, MAX_TRACKED_SCAN_DEVICES));
        }
        return rows;
    }

    private static void sortDeviceRows(List<DeviceRow> rows) {
        Collections.sort(rows, (left, right) -> {
            if (left.likelyWhoop != right.likelyWhoop) {
                return left.likelyWhoop ? -1 : 1;
            }
            return Integer.compare(right.rssi, left.rssi);
        });
    }

    private static boolean hasLikelyWhoop(List<DeviceRow> rows) {
        for (DeviceRow row : rows) {
            if (row.likelyWhoop) {
                return true;
            }
        }
        return false;
    }

    private String advertisementSummary(ScanResult result) {
        if (result.getScanRecord() == null || result.getScanRecord().getServiceUuids() == null) {
            return "No advertised services";
        }
        List<ParcelUuid> services = result.getScanRecord().getServiceUuids();
        if (services.isEmpty()) {
            return "No advertised services";
        }
        StringBuilder builder = new StringBuilder("Services:");
        for (ParcelUuid serviceUuid : services) {
            builder.append('\n').append(serviceUuid.getUuid());
        }
        return builder.toString();
    }

    private String scanFailureName(int errorCode) {
        switch (errorCode) {
            case ScanCallback.SCAN_FAILED_ALREADY_STARTED:
                return "already started (press Stop, then Scan once)";
            case ScanCallback.SCAN_FAILED_APPLICATION_REGISTRATION_FAILED:
                return "app registration failed";
            case ScanCallback.SCAN_FAILED_FEATURE_UNSUPPORTED:
                return "feature unsupported";
            case ScanCallback.SCAN_FAILED_INTERNAL_ERROR:
                return "internal error";
            default:
                return "code " + errorCode;
        }
    }

    private final BluetoothGattCallback gattCallback = new BluetoothGattCallback() {
        @Override
        @SuppressLint("MissingPermission")
        public void onConnectionStateChange(BluetoothGatt gatt, int status, int newState) {
            if (!isCurrentGattCallback(gatt, GooseBleClient.this.gatt)) {
                return;
            }
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                listener.onStateChanged("Connected; discovering services");
                clientHelloSent = false;
                commandCharacteristic = null;
                resetOperations();
                resetDiscoveryCounts();
                emitConnectionProgress("connected", null);
                gatt.discoverServices();
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                clientHelloSent = false;
                commandCharacteristic = null;
                activeDeviceId = null;
                resetOperations();
                resetDiscoveryCounts();
                listener.onStateChanged("Disconnected");
                emitConnectionProgress("disconnected", null);
            }
        }

        @Override
        public void onServicesDiscovered(BluetoothGatt gatt, int status) {
            if (!isCurrentGattCallback(gatt, GooseBleClient.this.gatt)) {
                return;
            }
            if (status != BluetoothGatt.GATT_SUCCESS) {
                listener.onStateChanged("Service discovery failed: " + status);
                emitConnectionProgress("service_discovery_failed", "status " + status);
                return;
            }
            resetOperations();
            resetDiscoveryCounts();
            subscriptionCount = 0;
            serviceCount = gatt.getServices().size();
            for (BluetoothGattService service : gatt.getServices()) {
                UUID serviceUuid = service.getUuid();
                if (!interestingService(serviceUuid)) {
                    continue;
                }
                interestingServiceCount += 1;
                for (BluetoothGattCharacteristic characteristic : service.getCharacteristics()) {
                    if (notificationCandidate(characteristic)) {
                        notificationCandidateCount += 1;
                        enqueueSubscribe(characteristic);
                    }
                    if (readCandidate(characteristic)) {
                        readCandidateCount += 1;
                        enqueueRead(characteristic);
                    }
                }
            }
            enqueueClientHello(gatt);
            listener.onStateChanged("Discovered services; queued " + operationQueue.size() + " GATT operations");
            emitConnectionProgress("services_discovered", null);
            drainOperationQueue(gatt);
        }

        @Override
        public void onCharacteristicChanged(BluetoothGatt gatt, BluetoothGattCharacteristic characteristic, byte[] value) {
            if (!isCurrentGattCallback(gatt, GooseBleClient.this.gatt)) {
                return;
            }
            listener.onNotification(new GooseNotification(
                    characteristic.getService().getUuid().toString(),
                    characteristic.getUuid().toString(),
                    value.clone(),
                    System.currentTimeMillis()
            ));
        }

        @Override
        @SuppressWarnings("deprecation")
        public void onCharacteristicChanged(BluetoothGatt gatt, BluetoothGattCharacteristic characteristic) {
            if (!isCurrentGattCallback(gatt, GooseBleClient.this.gatt)) {
                return;
            }
            byte[] value = characteristic.getValue();
            if (value != null) {
                onCharacteristicChanged(gatt, characteristic, value);
            }
        }

        @Override
        public void onDescriptorWrite(BluetoothGatt gatt, BluetoothGattDescriptor descriptor, int status) {
            if (!isCurrentGattCallback(gatt, GooseBleClient.this.gatt)) {
                return;
            }
            finishActiveOperation(gatt, status == BluetoothGatt.GATT_SUCCESS ? null : "Descriptor write failed: " + status);
        }

        @Override
        public void onCharacteristicWrite(BluetoothGatt gatt, BluetoothGattCharacteristic characteristic, int status) {
            if (!isCurrentGattCallback(gatt, GooseBleClient.this.gatt)) {
                return;
            }
            finishActiveOperation(gatt, status == BluetoothGatt.GATT_SUCCESS ? null : "Characteristic write failed: " + status);
        }

        @Override
        public void onCharacteristicRead(BluetoothGatt gatt, BluetoothGattCharacteristic characteristic, byte[] value, int status) {
            if (!isCurrentGattCallback(gatt, GooseBleClient.this.gatt)) {
                return;
            }
            if (status == BluetoothGatt.GATT_SUCCESS) {
                handleReadValue(characteristic, value);
            }
            finishActiveOperation(gatt, status == BluetoothGatt.GATT_SUCCESS ? null : "Characteristic read failed: " + status);
        }

        @Override
        @SuppressWarnings("deprecation")
        public void onCharacteristicRead(BluetoothGatt gatt, BluetoothGattCharacteristic characteristic, int status) {
            if (!isCurrentGattCallback(gatt, GooseBleClient.this.gatt)) {
                return;
            }
            byte[] value = characteristic.getValue();
            onCharacteristicRead(gatt, characteristic, value != null ? value : new byte[0], status);
        }
    };

    static boolean isCurrentGattCallback(Object callbackGatt, Object currentGatt) {
        return callbackGatt != null && callbackGatt == currentGatt;
    }

    private void enqueueSubscribe(BluetoothGattCharacteristic characteristic) {
        int properties = characteristic.getProperties();
        boolean supportsNotify = (properties & BluetoothGattCharacteristic.PROPERTY_NOTIFY) != 0;
        boolean supportsIndicate = (properties & BluetoothGattCharacteristic.PROPERTY_INDICATE) != 0;
        if (!supportsNotify && !supportsIndicate) {
            return;
        }
        BluetoothGattDescriptor descriptor = characteristic.getDescriptor(CLIENT_CHARACTERISTIC_CONFIG);
        operationQueue.add(new GattOperation() {
            @Override
            @SuppressLint("MissingPermission")
            public boolean start(BluetoothGatt gatt) {
                if (!gatt.setCharacteristicNotification(characteristic, true)) {
                    return false;
                }
                subscriptionCount += 1;
                if (descriptor == null) {
                    listener.onStateChanged("Subscribed " + subscriptionCount + " characteristics");
                    return false;
                }
                byte[] value = supportsNotify
                        ? BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                        : BluetoothGattDescriptor.ENABLE_INDICATION_VALUE;
                if (Build.VERSION.SDK_INT >= 33) {
                    return gatt.writeDescriptor(descriptor, value) == BluetoothStatusCodes.SUCCESS;
                }
                descriptor.setValue(value);
                return gatt.writeDescriptor(descriptor);
            }

            @Override
            public String label() {
                return "subscribe " + characteristic.getUuid();
            }
        });
    }

    private void enqueueRead(BluetoothGattCharacteristic characteristic) {
        operationQueue.add(new GattOperation() {
            @Override
            @SuppressLint("MissingPermission")
            public boolean start(BluetoothGatt gatt) {
                return gatt.readCharacteristic(characteristic);
            }

            @Override
            public String label() {
                return "read " + characteristic.getUuid();
            }
        });
    }

    private void enqueueClientHello(BluetoothGatt gatt) {
        BluetoothGattCharacteristic command = findCommandCharacteristic(gatt);
        commandCharacteristic = command;
        operationQueue.add(new GattOperation() {
            @Override
            public boolean start(BluetoothGatt gatt) {
                return startClientHello(gatt, command);
            }

            @Override
            public String label() {
                return "client hello";
            }

            @Override
            public void onComplete(String error) {
                clientHelloSent = error == null;
            }
        });
    }

    private void drainOperationQueue(BluetoothGatt gatt) {
        if (activeOperation != null) {
            return;
        }
        while (!operationQueue.isEmpty()) {
            GattOperation next = operationQueue.poll();
            activeOperation = next;
            emitConnectionProgress("operation_start", null);
            boolean async = next.start(gatt);
            if (async) {
                next.onStarted();
                return;
            }
            next.onComplete("not started");
            activeOperation = null;
        }
        listener.onStateChanged("Ready; subscribed " + subscriptionCount + " characteristics; hello " + (clientHelloSent ? "sent" : "not sent"));
        emitConnectionProgress("ready", null);
    }

    private void finishActiveOperation(BluetoothGatt gatt, String error) {
        String label = activeOperation != null ? activeOperation.label() : "unknown";
        GattOperation completedOperation = activeOperation;
        activeOperation = null;
        completedOperationCount += 1;
        if (completedOperation != null) {
            completedOperation.onComplete(error);
        }
        if (error != null) {
            listener.onStateChanged(label + ": " + error);
        }
        emitConnectionProgress(error == null ? "operation_complete" : "operation_failed", error, label);
        drainOperationQueue(gatt);
    }

    private void resetOperations() {
        operationQueue.clear();
        activeOperation = null;
        subscriptionCount = 0;
        completedOperationCount = 0;
    }

    private void resetDiscoveryCounts() {
        serviceCount = 0;
        interestingServiceCount = 0;
        notificationCandidateCount = 0;
        readCandidateCount = 0;
    }

    @SuppressLint("MissingPermission")
    private boolean startClientHello(BluetoothGatt gatt, BluetoothGattCharacteristic command) {
        if (command == null) {
            listener.onStateChanged("hello blocked: no command characteristic");
            return false;
        }
        if (clientHelloSent) {
            return false;
        }
        int properties = command.getProperties();
        int writeType;
        if ((properties & BluetoothGattCharacteristic.PROPERTY_WRITE) != 0) {
            writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT;
        } else if ((properties & BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) != 0) {
            writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE;
        } else {
            listener.onStateChanged("hello blocked: command not writable");
            return false;
        }

        boolean started;
        if (Build.VERSION.SDK_INT >= 33) {
            started = gatt.writeCharacteristic(command, CLIENT_HELLO_FRAME, writeType) == BluetoothStatusCodes.SUCCESS;
        } else {
            command.setWriteType(writeType);
            command.setValue(CLIENT_HELLO_FRAME);
            started = gatt.writeCharacteristic(command);
        }
        return started;
    }

    @SuppressLint("MissingPermission")
    private boolean writeCommandFrame(
            BluetoothGatt gatt,
            BluetoothGattCharacteristic command,
            byte[] frame,
            String label
    ) {
        if (command == null) {
            listener.onStateChanged(label + " blocked: no command characteristic");
            return false;
        }
        int properties = command.getProperties();
        int writeType;
        if ((properties & BluetoothGattCharacteristic.PROPERTY_WRITE) != 0) {
            writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT;
        } else if ((properties & BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) != 0) {
            writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE;
        } else {
            listener.onStateChanged(label + " blocked: command not writable");
            return false;
        }
        if (Build.VERSION.SDK_INT >= 33) {
            return gatt.writeCharacteristic(command, frame, writeType) == BluetoothStatusCodes.SUCCESS;
        }
        command.setWriteType(writeType);
        command.setValue(frame);
        return gatt.writeCharacteristic(command);
    }

    private void emitCommandEvent(String label, String status, byte[] frame, String error) {
        listener.onCommandEvent(new CommandEvent(
                label,
                status,
                commandServiceUuid(),
                commandCharacteristicUuid(),
                commandWriteType(),
                Hex.encode(frame),
                error,
                System.currentTimeMillis()
        ));
    }

    private void emitConnectionProgress(String phase, String error) {
        emitConnectionProgress(phase, error, activeOperation != null ? activeOperation.label() : "");
    }

    private void emitConnectionProgress(String phase, String error, String activeOperationLabel) {
        listener.onConnectionProgress(new ConnectionProgress(
                phase,
                activeDeviceId != null ? activeDeviceId : "",
                devices.size(),
                serviceCount,
                interestingServiceCount,
                notificationCandidateCount,
                readCandidateCount,
                operationQueue.size() + (activeOperation != null ? 1 : 0),
                completedOperationCount,
                subscriptionCount,
                activeOperationLabel,
                commandReady(),
                clientHelloSent,
                error,
                System.currentTimeMillis()
        ));
    }

    private BluetoothGattCharacteristic findCommandCharacteristic(BluetoothGatt gatt) {
        BluetoothGattCharacteristic fallback = null;
        for (BluetoothGattService service : gatt.getServices()) {
            for (BluetoothGattCharacteristic characteristic : service.getCharacteristics()) {
                String uuid = characteristic.getUuid().toString().toLowerCase(Locale.US);
                if (uuid.startsWith("fd4b0002")) {
                    return characteristic;
                }
                if (uuid.startsWith("61080002")) {
                    fallback = characteristic;
                }
            }
        }
        return fallback;
    }

    private boolean interestingService(UUID serviceUuid) {
        return WHOOP_GEN5_SERVICE.equals(serviceUuid)
                || WHOOP_GEN4_SERVICE.equals(serviceUuid)
                || STANDARD_HEART_RATE_SERVICE.equals(serviceUuid)
                || BATTERY_SERVICE.equals(serviceUuid)
                || DEVICE_INFORMATION_SERVICE.equals(serviceUuid);
    }

    private boolean notificationCandidate(BluetoothGattCharacteristic characteristic) {
        String uuid = characteristic.getUuid().toString().toLowerCase(Locale.US);
        return uuid.startsWith("fd4b0003")
                || uuid.startsWith("fd4b0004")
                || uuid.startsWith("fd4b0005")
                || uuid.startsWith("fd4b0007")
                || uuid.startsWith("61080003")
                || uuid.startsWith("61080004")
                || uuid.startsWith("61080005")
                || uuid.startsWith("61080007")
                || uuid.equals("00002a37-0000-1000-8000-00805f9b34fb")
                || uuid.equals("00002a19-0000-1000-8000-00805f9b34fb")
                || uuid.equals("00002bed-0000-1000-8000-00805f9b34fb");
    }

    private boolean readCandidate(BluetoothGattCharacteristic characteristic) {
        int properties = characteristic.getProperties();
        if ((properties & BluetoothGattCharacteristic.PROPERTY_READ) == 0) {
            return false;
        }
        UUID uuid = characteristic.getUuid();
        return BATTERY_LEVEL.equals(uuid)
                || BATTERY_LEVEL_STATUS.equals(uuid)
                || MODEL_NUMBER.equals(uuid)
                || FIRMWARE_REVISION.equals(uuid)
                || HARDWARE_REVISION.equals(uuid)
                || SOFTWARE_REVISION.equals(uuid)
                || MANUFACTURER_NAME.equals(uuid);
    }

    private void handleReadValue(BluetoothGattCharacteristic characteristic, byte[] value) {
        UUID uuid = characteristic.getUuid();
        String label;
        String text;
        if (BATTERY_LEVEL.equals(uuid) && value.length > 0) {
            label = "Battery";
            text = (value[0] & 0xff) + "%";
        } else if (BATTERY_LEVEL_STATUS.equals(uuid)) {
            label = "Battery status";
            text = Hex.encode(value);
        } else if (MODEL_NUMBER.equals(uuid)) {
            label = "Model";
            text = utf8(value);
        } else if (FIRMWARE_REVISION.equals(uuid)) {
            label = "Firmware";
            text = utf8(value);
        } else if (HARDWARE_REVISION.equals(uuid)) {
            label = "Hardware";
            text = utf8(value);
        } else if (SOFTWARE_REVISION.equals(uuid)) {
            label = "Software";
            text = utf8(value);
        } else if (MANUFACTURER_NAME.equals(uuid)) {
            label = "Manufacturer";
            text = utf8(value);
        } else {
            label = uuid.toString();
            text = Hex.encode(value);
        }
        metadata.put(label, text);
        listener.onMetadataChanged(metadataSummary());
    }

    private String metadataSummary() {
        if (metadata.isEmpty()) {
            return "No device metadata read";
        }
        StringBuilder builder = new StringBuilder();
        for (Map.Entry<String, String> entry : metadata.entrySet()) {
            if (builder.length() > 0) {
                builder.append('\n');
            }
            builder.append(entry.getKey()).append(": ").append(entry.getValue());
        }
        return builder.toString();
    }

    private String utf8(byte[] value) {
        return new String(value).trim();
    }

    @SuppressLint("MissingPermission")
    private String displayName(BluetoothDevice device) {
        String name = null;
        if (hasRuntimePermissions()) {
            name = device.getName();
        }
        if (name == null || name.trim().isEmpty()) {
            return "Unknown BLE device";
        }
        return name;
    }
}
