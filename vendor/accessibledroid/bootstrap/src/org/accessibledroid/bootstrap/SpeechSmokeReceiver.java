package org.accessibledroid.bootstrap;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.speech.tts.TextToSpeech;
import android.speech.tts.UtteranceProgressListener;
import android.util.Log;

import java.util.Locale;

/** Runs a deterministic offline TTS smoke test for release validation. */
public final class SpeechSmokeReceiver extends BroadcastReceiver {
    private static final String TAG = "AccessibleTtsSmoke";
    private static final String ACTION = "org.accessibledroid.bootstrap.SPEECH_SMOKE";
    private static final String ESPEAK_PACKAGE = "com.reecedunn.espeak";
    private static final String EN_UTTERANCE = "accessible-tts-en-us";
    private static final String FR_UTTERANCE = "accessible-tts-fr-fr";

    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent == null || !ACTION.equals(intent.getAction())) {
            return;
        }

        final PendingResult pendingResult = goAsync();
        new Session(context.getApplicationContext(), pendingResult).start();
    }

    private static final class Session {
        private final Context context;
        private final PendingResult pendingResult;
        private TextToSpeech tts;
        private boolean finished;

        Session(Context context, PendingResult pendingResult) {
            this.context = context;
            this.pendingResult = pendingResult;
        }

        void start() {
            tts = new TextToSpeech(context, this::onInit, ESPEAK_PACKAGE);
        }

        private void onInit(int status) {
            if (status != TextToSpeech.SUCCESS) {
                fail("TTS_INIT", "status=" + status);
                return;
            }

            final int english = tts.isLanguageAvailable(Locale.US);
            final int french = tts.isLanguageAvailable(Locale.FRANCE);
            if (english < TextToSpeech.LANG_AVAILABLE) {
                fail("TTS_LANGUAGE_EN_US", "status=" + english);
                return;
            }
            if (french < TextToSpeech.LANG_AVAILABLE) {
                fail("TTS_LANGUAGE_FR_FR", "status=" + french);
                return;
            }
            if (tts.setSpeechRate(1.0f) != TextToSpeech.SUCCESS) {
                fail("TTS_RATE", "setSpeechRate failed");
                return;
            }
            if (tts.setPitch(1.0f) != TextToSpeech.SUCCESS) {
                fail("TTS_PITCH", "setPitch failed");
                return;
            }

            tts.setOnUtteranceProgressListener(new UtteranceProgressListener() {
                @Override
                public void onStart(String utteranceId) {
                    Log.i(TAG, "TTS_STARTED=" + utteranceId);
                }

                @Override
                public void onDone(String utteranceId) {
                    if (EN_UTTERANCE.equals(utteranceId)) {
                        Log.i(TAG, "TTS_SMOKE_EN_US=PASS");
                        speakFrench();
                    } else if (FR_UTTERANCE.equals(utteranceId)) {
                        Log.i(TAG, "TTS_SMOKE_FR_FR=PASS");
                        Log.i(TAG, "ACCESSIBLE_TTS_SMOKE=PASS");
                        finish();
                    }
                }

                @Override
                @SuppressWarnings("deprecation")
                public void onError(String utteranceId) {
                    fail("TTS_SYNTHESIS", "utterance=" + utteranceId);
                }

                @Override
                public void onError(String utteranceId, int errorCode) {
                    fail(
                            "TTS_SYNTHESIS",
                            "utterance=" + utteranceId + ", errorCode=" + errorCode);
                }
            });

            if (tts.setLanguage(Locale.US) < TextToSpeech.LANG_AVAILABLE) {
                fail("TTS_SET_LANGUAGE_EN_US", "unsupported");
                return;
            }
            final int queued = tts.speak(
                    "Accessible Android speech test",
                    TextToSpeech.QUEUE_FLUSH,
                    null,
                    EN_UTTERANCE);
            if (queued != TextToSpeech.SUCCESS) {
                fail("TTS_QUEUE_EN_US", "status=" + queued);
            }
        }

        private void speakFrench() {
            if (finished) {
                return;
            }
            if (tts.setLanguage(Locale.FRANCE) < TextToSpeech.LANG_AVAILABLE) {
                fail("TTS_SET_LANGUAGE_FR_FR", "unsupported");
                return;
            }
            final int queued = tts.speak(
                    "Test vocal Accessible Android",
                    TextToSpeech.QUEUE_FLUSH,
                    null,
                    FR_UTTERANCE);
            if (queued != TextToSpeech.SUCCESS) {
                fail("TTS_QUEUE_FR_FR", "status=" + queued);
            }
        }

        private synchronized void fail(String stage, String detail) {
            if (finished) {
                return;
            }
            Log.e(TAG, "ACCESSIBLE_TTS_SMOKE=FAIL stage=" + stage + " " + detail);
            finish();
        }

        private synchronized void finish() {
            if (finished) {
                return;
            }
            finished = true;
            if (tts != null) {
                tts.stop();
                tts.shutdown();
            }
            pendingResult.finish();
        }
    }
}
