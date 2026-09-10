package org.accessibledroid.bootstrap;

import android.content.BroadcastReceiver;
import android.content.ComponentName;
import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.provider.Settings;
import android.util.Log;

import java.util.LinkedHashSet;
import java.util.Set;

/** Ensures that speech accessibility is usable from the first boot and after updates. */
public final class BootReceiver extends BroadcastReceiver {
    private static final String TAG = "AccessibleBootstrap";

    private static final String TALKBACK_PACKAGE = "com.google.android.accessibility.talkback";
    private static final String TALKBACK_CLASS = "com.google.android.marvin.talkback.TalkBackService";
    private static final String ESPEAK_PACKAGE = "com.reecedunn.espeak";

    private static final String TTS_DEFAULT_SYNTH = "tts_default_synth";
    private static final int MAX_ATTEMPTS = 30;
    private static final long RETRY_DELAY_MS = 1000L;

    @Override
    public void onReceive(Context context, Intent intent) {
        final PendingResult pendingResult = goAsync();
        final Context appContext = context.getApplicationContext();

        new Thread(() -> {
            try {
                ensureAccessibleBoot(appContext);
            } finally {
                pendingResult.finish();
            }
        }, "AccessibleAndroidBootstrap").start();
    }

    private static void ensureAccessibleBoot(Context context) {
        for (int attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
            if (isInstalled(context, TALKBACK_PACKAGE) && isInstalled(context, ESPEAK_PACKAGE)) {
                configure(context);
                return;
            }

            Log.w(TAG, "Accessibility packages not ready, attempt " + attempt + "/" + MAX_ATTEMPTS);
            try {
                Thread.sleep(RETRY_DELAY_MS);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return;
            }
        }

        Log.e(TAG, "Required accessibility packages were not available after boot");
    }

    private static boolean isInstalled(Context context, String packageName) {
        try {
            context.getPackageManager().getPackageInfo(packageName, 0);
            return true;
        } catch (PackageManager.NameNotFoundException e) {
            return false;
        }
    }

    private static void configure(Context context) {
        final ContentResolver resolver = context.getContentResolver();
        final String talkBackComponent = new ComponentName(TALKBACK_PACKAGE, TALKBACK_CLASS).flattenToString();
        final Set<String> services = new LinkedHashSet<>();

        final String current = Settings.Secure.getString(
                resolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES);
        if (current != null && !current.isBlank()) {
            for (String service : current.split(":")) {
                if (!service.isBlank()) {
                    services.add(service);
                }
            }
        }
        services.add(talkBackComponent);

        Settings.Secure.putString(
                resolver,
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
                String.join(":", services));
        Settings.Secure.putInt(resolver, Settings.Secure.ACCESSIBILITY_ENABLED, 1);
        Settings.Secure.putString(resolver, TTS_DEFAULT_SYNTH, ESPEAK_PACKAGE);

        Log.i(TAG, "TalkBack and offline eSpeak TTS configured for accessible boot");
    }
}
