package com.goose.android;

import android.app.Activity;
import android.graphics.Color;
import android.graphics.Typeface;
import android.os.Bundle;
import android.view.Gravity;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

public final class PermissionsRationaleActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(contentView());
    }

    private ScrollView contentView() {
        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(Color.rgb(248, 250, 252));

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(28), dp(28), dp(28), dp(28));
        scroll.addView(root);

        TextView title = text("Goose Health Connect permissions", 24, Color.rgb(15, 23, 42));
        title.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        root.addView(title);

        TextView body = text(
                "Goose only asks for Health Connect write permissions so it can sync metrics it decoded or derived locally from your connected WHOOP captures.\n\n"
                        + "Goose writes steps, heart rate, and active calories only after its local dry-run gate says the records are ready. It does not import Health Connect data back into Goose metrics, and it keeps raw WHOOP captures in app-local storage unless you export them.",
                16,
                Color.rgb(71, 85, 105)
        );
        body.setPadding(0, dp(18), 0, 0);
        root.addView(body);

        return scroll;
    }

    private TextView text(String value, int textSize, int color) {
        TextView view = new TextView(this);
        view.setText(value);
        view.setTextSize(textSize);
        view.setTextColor(color);
        view.setGravity(Gravity.START);
        return view;
    }

    private int dp(int value) {
        return (int) (value * getResources().getDisplayMetrics().density + 0.5f);
    }
}
