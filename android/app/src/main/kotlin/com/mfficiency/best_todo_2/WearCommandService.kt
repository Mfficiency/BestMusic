package com.mfficiency.best_todo_2

import android.content.Context
import android.media.AudioManager
import android.util.Log
import android.view.KeyEvent
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Wearable
import com.google.android.gms.wearable.WearableListenerService
import org.json.JSONObject

/**
 * The watch app's buttons (wear/ in this repo; paths in its core/Sync.kt):
 * `/music/command/<name>` messages from the watch do exactly what the
 * home-screen widgets' buttons do: a media-button broadcast to
 * audio_service's MediaButtonReceiver (MusicWidgetIntents). Play/pause
 * makes the same check as MusicPlayGuardActivity; where that would ask
 * "Play out loud?", the watch is asked instead (it answers with
 * play_out_loud), since a service can't put a dialog on the phone.
 * Volume = the phone's media volume (STREAM_MUSIC), sent back to the watch.
 * Nothing here touches the app's own files.
 */
class WearCommandService : WearableListenerService() {

    override fun onMessageReceived(messageEvent: MessageEvent) {
        try {
            handle(messageEvent)
        } catch (e: Throwable) {
            Log.w(TAG, "watch command ${messageEvent.path} failed", e)
        }
    }

    private fun handle(event: MessageEvent) {
        val path = event.path
        if (!path.startsWith(COMMAND_PREFIX)) return
        when (path.removePrefix(COMMAND_PREFIX)) {
            "play_pause" ->
                if (canPlayWithoutAsking()) {
                    sendMediaKey(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
                } else {
                    Wearable.getMessageClient(this)
                        .sendMessage(event.sourceNodeId, ASK_OUT_LOUD_PATH, ByteArray(0))
                        .addOnFailureListener { e -> Log.w(TAG, "ask watch failed: ${e.message}") }
                }
            // The watch's answer to "Play out loud?": play (unless
            // something started playing meanwhile, which it would pause).
            "play_out_loud" -> if (!isPlaying()) sendMediaKey(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
            "next" -> sendMediaKey(KeyEvent.KEYCODE_MEDIA_NEXT)
            "previous" -> sendMediaKey(KeyEvent.KEYCODE_MEDIA_PREVIOUS)
            "volume_up" -> adjustVolume(AudioManager.ADJUST_RAISE, steps(event))
            "volume_down" -> adjustVolume(AudioManager.ADJUST_LOWER, steps(event))
            "sync" -> publishVolume()
        }
    }

    // What the widgets' play/pause guard decides (MusicPlayGuardActivity),
    // from the same widget data the app writes.
    private fun canPlayWithoutAsking(): Boolean {
        val prefs = getSharedPreferences("HomeWidgetPreferences", Context.MODE_PRIVATE)
        val confirm = prefs.getBoolean("music_confirm_speaker", true)
        return isPlaying() || !confirm || AudioOutputs.isExternalConnected(this)
    }

    private fun isPlaying(): Boolean =
        getSharedPreferences("HomeWidgetPreferences", Context.MODE_PRIVATE)
            .getBoolean("music_widget_playing", false)

    private fun sendMediaKey(keyCode: Int) {
        sendBroadcast(MusicWidgetIntents.mediaButtonBroadcast(this, keyCode))
    }

    /** How many volume steps the watch sent (UTF-8 text, "3"); 1 by default. */
    private fun steps(event: MessageEvent): Int {
        val data = event.data ?: return 1
        return String(data, Charsets.UTF_8).trim().toIntOrNull()?.coerceIn(1, 30) ?: 1
    }

    private fun adjustVolume(direction: Int, steps: Int) {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        try {
            if (!audioManager.isVolumeFixed) {
                repeat(steps) {
                    audioManager.adjustStreamVolume(AudioManager.STREAM_MUSIC, direction, 0)
                }
            }
        } catch (e: SecurityException) {
            // Do Not Disturb can refuse volume changes.
        }
        publishVolume()
    }

    private fun publishVolume() {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        val level = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
        val json = JSONObject().put("level", level).put("max", max).toString()
        WearSync.publish(this, WearSync.VOLUME_PATH, json)
    }

    private companion object {
        const val TAG = "WearCommandService"
        const val COMMAND_PREFIX = "/music/command/"
        const val ASK_OUT_LOUD_PATH = "/music/ask_out_loud"
    }
}
