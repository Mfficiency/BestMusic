package com.mfficiency.best_todo_2

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.support.v4.media.MediaBrowserCompat
import android.support.v4.media.session.MediaControllerCompat

/**
 * The 2×3 widget's like / dislike / heart buttons. There's no media-button
 * key for these, so (unlike play/pause and skip, see [MusicWidgetIntents])
 * this connects to `audio_service`'s media session and sends a custom
 * action, which reaches `MusicAudioHandler.customAction` in the running
 * app. With no music session alive there's no song to act on, and the
 * action is dropped.
 */
class MusicWidgetActionReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.getStringExtra(EXTRA_CUSTOM_ACTION) ?: return
        val app = context.applicationContext
        val pending = goAsync()
        val main = Handler(Looper.getMainLooper())
        main.post {
            var done = false
            var browser: MediaBrowserCompat? = null
            fun finish() {
                if (done) return
                done = true
                try {
                    browser?.disconnect()
                } catch (e: Throwable) {
                }
                pending.finish()
            }
            browser = MediaBrowserCompat(
                app,
                ComponentName(app.packageName, SERVICE_CLASS),
                object : MediaBrowserCompat.ConnectionCallback() {
                    override fun onConnected() {
                        try {
                            val token = browser?.sessionToken
                            if (token != null) {
                                MediaControllerCompat(app, token)
                                    .transportControls
                                    .sendCustomAction(action, null)
                            }
                        } catch (e: Throwable) {
                        }
                        // Let the action reach the session before unbinding.
                        main.postDelayed({ finish() }, 500)
                    }

                    override fun onConnectionFailed() = finish()
                    override fun onConnectionSuspended() = finish()
                },
                null
            )
            try {
                browser?.connect()
            } catch (e: Throwable) {
                finish()
            }
            main.postDelayed({ finish() }, 8000)
        }
    }

    companion object {
        const val EXTRA_CUSTOM_ACTION = "custom_action"
        private const val SERVICE_CLASS = "com.ryanheise.audioservice.AudioService"
    }
}
