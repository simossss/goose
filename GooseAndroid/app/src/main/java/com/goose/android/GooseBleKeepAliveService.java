package com.goose.android;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;

public final class GooseBleKeepAliveService extends Service {
    private static final String CHANNEL_ID = "goose_ble_capture";
    private static final int NOTIFICATION_ID = 7001;

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        startForeground(NOTIFICATION_ID, notification());
        return START_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private Notification notification() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationManager manager = getSystemService(NotificationManager.class);
            if (manager != null && manager.getNotificationChannel(CHANNEL_ID) == null) {
                manager.createNotificationChannel(new NotificationChannel(
                        CHANNEL_ID,
                        "Goose BLE capture",
                        NotificationManager.IMPORTANCE_LOW
                ));
            }
            return new Notification.Builder(this, CHANNEL_ID)
                    .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
                    .setContentTitle("Goose is monitoring WHOOP")
                    .setContentText("Keeping the BLE session available for capture and reconnect.")
                    .setOngoing(true)
                    .build();
        }
        return new Notification.Builder(this)
                .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
                .setContentTitle("Goose is monitoring WHOOP")
                .setContentText("Keeping the BLE session available for capture and reconnect.")
                .setOngoing(true)
                .build();
    }
}
