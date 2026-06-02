package com.goose.android;

import android.Manifest;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCallback;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
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
import java.util.Comparator;
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
            return prefix + name + "  " + rssi + " dBm\n" + address + "\n" + advertisementSummary;
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
    private static final int MAX_PUBLISHED_DEVICES = 20;
    private static final long DEVICE_PUBLISH_INTERVAL_MS = 750;

    private final Context context;
    private final Listener listener;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final Map<String, DeviceRow> devices = new LinkedHashMap<>();
    private BluetoothAdapter adapter;
    private BluetoothGatt gatt;
    private BluetoothGattCharacteristic commandCharacteristic;
    private final Queue<GattOperation> operationQueue = new ArrayDeque<>();
    private GattOperation activeOperation;
    private boolean scanning;
    private boolean filteredScan;
    private boolean publishQueued;
    private long lastDevicePublishAtMillis;
    private boolean clientHelloSent;
    private int subscriptionCount;
    private final Map<String, String> metadata = new LinkedHashMap<>();

    private interface GattOperation {
        boolean start(BluetoothGatt gatt);

        String label();
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
                    && context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
                    && context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED;
        }
        return context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED;
    }

    List<String> requiredPermissions() {
        List<String> permissions = new ArrayList<>();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            permissions.add(Manifest.permission.BLUETOOTH_SCAN);
            permissions.add(Manifest.permission.BLUETOOTH_CONNECT);
            permissions.add(Manifest.permission.ACCESS_FINE_LOCATION);
        } else {
            permissions.add(Manifest.permission.ACCESS_FINE_LOCATION);
        }
        return permissions;
    }

    void startScan() {
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
        publishDevicesNow();
        startScanner(scanner, true);
    }

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
        listener.onStateChanged("Scan stopped");
    }

    void connect(String address) {
        if (!hasRuntimePermissions()) {
            listener.onStateChanged("Bluetooth permissions required");
            return;
        }
        if (adapter == null) {
            listener.onStateChanged("Bluetooth adapter unavailable");
            return;
        }
        stopScan();
        BluetoothDevice device = adapter.getRemoteDevice(address);
        listener.onStateChanged("Connecting " + displayName(device));
        clientHelloSent = false;
        commandCharacteristic = null;
        resetOperations();
        gatt = device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE);
    }

    void sendCommandFrame(String label, byte[] frame) {
        if (!hasRuntimePermissions()) {
            listener.onStateChanged("Bluetooth permissions required");
            return;
        }
        if (gatt == null || commandCharacteristic == null) {
            listener.onStateChanged(label + " blocked: no connected WHOOP command characteristic");
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
        });
        listener.onStateChanged(label + " queued");
        drainOperationQueue(gatt);
    }

    void close() {
        stopScan();
        if (gatt != null && hasRuntimePermissions()) {
            gatt.close();
        }
        gatt = null;
        resetOperations();
    }

    private final ScanCallback scanCallback = new ScanCallback() {
        @Override
        public void onScanResult(int callbackType, ScanResult result) {
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
            if (row.likelyWhoop) {
                stopScan();
                publishDevicesNow();
                listener.onStateChanged("WHOOP candidate found; scan stopped so you can tap it");
            } else {
                scheduleDevicePublish();
            }
        }

        @Override
        public void onScanFailed(int errorCode) {
            scanning = false;
            filteredScan = false;
            listener.onStateChanged("Scan failed: " + scanFailureName(errorCode));
        }
    };

    private void startScanner(BluetoothLeScanner scanner, boolean withWhoopFilters) {
        scanning = true;
        filteredScan = withWhoopFilters;
        listener.onStateChanged(withWhoopFilters
                ? "Scanning for WHOOP advertisements"
                : "Fallback scan: showing all BLE advertisers");

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
                if (!scanning || !filteredScan || hasLikelyWhoopDevice() || adapter == null || !hasRuntimePermissions()) {
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
            publishDevicesNow();
        }, DEVICE_PUBLISH_INTERVAL_MS);
    }

    private void publishDevicesNow() {
        lastDevicePublishAtMillis = System.currentTimeMillis();
        List<DeviceRow> rows = new ArrayList<>(devices.values());
        rows.sort(Comparator
                .comparing((DeviceRow row) -> row.likelyWhoop).reversed()
                .thenComparing((DeviceRow row) -> row.rssi, Comparator.reverseOrder()));
        if (rows.size() > MAX_PUBLISHED_DEVICES) {
            rows = new ArrayList<>(rows.subList(0, MAX_PUBLISHED_DEVICES));
        }
        listener.onDevicesChanged(rows);
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
        public void onConnectionStateChange(BluetoothGatt gatt, int status, int newState) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                listener.onStateChanged("Connected; discovering services");
                clientHelloSent = false;
                commandCharacteristic = null;
                resetOperations();
                gatt.discoverServices();
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                clientHelloSent = false;
                commandCharacteristic = null;
                resetOperations();
                listener.onStateChanged("Disconnected");
            }
        }

        @Override
        public void onServicesDiscovered(BluetoothGatt gatt, int status) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                listener.onStateChanged("Service discovery failed: " + status);
                return;
            }
            resetOperations();
            subscriptionCount = 0;
            for (BluetoothGattService service : gatt.getServices()) {
                UUID serviceUuid = service.getUuid();
                if (!interestingService(serviceUuid)) {
                    continue;
                }
                for (BluetoothGattCharacteristic characteristic : service.getCharacteristics()) {
                    if (notificationCandidate(characteristic)) {
                        enqueueSubscribe(characteristic);
                    }
                    if (readCandidate(characteristic)) {
                        enqueueRead(characteristic);
                    }
                }
            }
            enqueueClientHello(gatt);
            listener.onStateChanged("Discovered services; queued " + operationQueue.size() + " GATT operations");
            drainOperationQueue(gatt);
        }

        @Override
        public void onCharacteristicChanged(BluetoothGatt gatt, BluetoothGattCharacteristic characteristic, byte[] value) {
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
            byte[] value = characteristic.getValue();
            if (value != null) {
                onCharacteristicChanged(gatt, characteristic, value);
            }
        }

        @Override
        public void onDescriptorWrite(BluetoothGatt gatt, BluetoothGattDescriptor descriptor, int status) {
            finishActiveOperation(gatt, status == BluetoothGatt.GATT_SUCCESS ? null : "Descriptor write failed: " + status);
        }

        @Override
        public void onCharacteristicWrite(BluetoothGatt gatt, BluetoothGattCharacteristic characteristic, int status) {
            finishActiveOperation(gatt, status == BluetoothGatt.GATT_SUCCESS ? null : "Characteristic write failed: " + status);
        }

        @Override
        public void onCharacteristicRead(BluetoothGatt gatt, BluetoothGattCharacteristic characteristic, byte[] value, int status) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                handleReadValue(characteristic, value);
            }
            finishActiveOperation(gatt, status == BluetoothGatt.GATT_SUCCESS ? null : "Characteristic read failed: " + status);
        }

        @Override
        @SuppressWarnings("deprecation")
        public void onCharacteristicRead(BluetoothGatt gatt, BluetoothGattCharacteristic characteristic, int status) {
            byte[] value = characteristic.getValue();
            onCharacteristicRead(gatt, characteristic, value != null ? value : new byte[0], status);
        }
    };

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
                    return gatt.writeDescriptor(descriptor, value) == BluetoothGatt.GATT_SUCCESS;
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
        });
    }

    private void drainOperationQueue(BluetoothGatt gatt) {
        if (activeOperation != null) {
            return;
        }
        while (!operationQueue.isEmpty()) {
            GattOperation next = operationQueue.poll();
            activeOperation = next;
            boolean async = next.start(gatt);
            if (async) {
                return;
            }
            activeOperation = null;
        }
        listener.onStateChanged("Ready; subscribed " + subscriptionCount + " characteristics; hello " + (clientHelloSent ? "sent" : "not sent"));
    }

    private void finishActiveOperation(BluetoothGatt gatt, String error) {
        String label = activeOperation != null ? activeOperation.label() : "unknown";
        activeOperation = null;
        if (error != null) {
            listener.onStateChanged(label + ": " + error);
        }
        drainOperationQueue(gatt);
    }

    private void resetOperations() {
        operationQueue.clear();
        activeOperation = null;
        subscriptionCount = 0;
    }

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
            started = gatt.writeCharacteristic(command, CLIENT_HELLO_FRAME, writeType) == BluetoothGatt.GATT_SUCCESS;
        } else {
            command.setWriteType(writeType);
            command.setValue(CLIENT_HELLO_FRAME);
            started = gatt.writeCharacteristic(command);
        }
        if (started) {
            clientHelloSent = true;
        }
        return started;
    }

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
            return gatt.writeCharacteristic(command, frame, writeType) == BluetoothGatt.GATT_SUCCESS;
        }
        command.setWriteType(writeType);
        command.setValue(frame);
        return gatt.writeCharacteristic(command);
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
