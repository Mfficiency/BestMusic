// The Kotlin package stays com.mfficiency.best_todo_2 (Best Music used to be a
// flavor of the BestToDo repo): placed home-screen widgets and the share
// target are stored by component name (package + class), so renaming it
// would silently break them on every phone that updates.
package com.mfficiency.best_todo_2

import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.media.MediaScannerConnection
import android.os.Bundle
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// AudioServiceFragmentActivity because the Music Player's background
// playback service (audio_service) needs the activity to hand it the shared
// FlutterEngine it manages.
class MainActivity : AudioServiceFragmentActivity() {

    // Content shared into the app (see ShareActivity), waiting for the Dart
    // side to collect it. On a cold start the queue fills before the Flutter
    // engine runs; ShareIntentService drains it once initialized. Each entry
    // is a map of {"text": String, "files": [{"path": String, "mimeType":
    // String}, ...]}.
    private val pendingSharedContent = ArrayDeque<Map<String, Any?>>()
    private var shareChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        queueSharedContent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        queueSharedContent(intent)
    }

    // Queues content forwarded by ShareActivity and pokes the Dart side. When
    // the poke arrives before ShareIntentService registered its handler
    // (cold start), it is simply lost — the service's own initial
    // takeSharedContent pull drains the queue instead, so nothing is dropped
    // and nothing is delivered twice (delivery is always pull-with-clear).
    private fun queueSharedContent(intent: Intent?) {
        if (intent?.action != ShareActivity.ACTION_SHARED_CONTENT) return
        val text = intent.getStringExtra(ShareActivity.EXTRA_SHARED_TEXT).orEmpty()
        val paths = intent.getStringArrayListExtra(ShareActivity.EXTRA_SHARED_FILE_PATHS)
            ?: arrayListOf()
        val mimeTypes = intent.getStringArrayListExtra(ShareActivity.EXTRA_SHARED_FILE_MIME_TYPES)
            ?: arrayListOf()
        if (text.isBlank() && paths.isEmpty()) return
        val files = paths.mapIndexed { i, path ->
            mapOf("path" to path, "mimeType" to (mimeTypes.getOrNull(i) ?: ""))
        }
        pendingSharedContent.add(mapOf("text" to text, "files" to files))
        shareChannel?.invokeMethod("sharedContentPending", null)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        AudioPcmDecoder.register(flutterEngine.dartExecutor.binaryMessenger)
        BackgroundWorkService.register(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        // The phone's own media volume (STREAM_MUSIC) as 0..1. Best Music
        // remembers one level for music and one for videos and switches the
        // phone between them (lib/services/media_volume.dart).
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "besttodo/media_volume",
        ).setMethodCallHandler { call, result ->
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            when (call.method) {
                "get" -> result.success(
                    if (max <= 0) null
                    else audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
                        .toDouble() / max
                )
                "set" -> {
                    val volume = (call.argument<Double>("volume") ?: 0.0)
                        .coerceIn(0.0, 1.0)
                    val showUi = call.argument<Boolean>("showUi") ?: false
                    try {
                        if (max > 0 && !audioManager.isVolumeFixed) {
                            audioManager.setStreamVolume(
                                AudioManager.STREAM_MUSIC,
                                Math.round(volume * max).toInt(),
                                if (showUi) AudioManager.FLAG_SHOW_UI else 0,
                            )
                        }
                    } catch (_: SecurityException) {
                        // Do Not Disturb can refuse volume changes.
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "besttodo/media_scanner",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                // Files this app writes with plain File I/O (the MP3
                // downloader saving straight into a user-picked folder)
                // never pass through MediaStore, so OEM media apps —
                // Samsung's Music/My Files/Gallery included — don't know
                // they exist until the next full device media scan, which
                // on some OEMs only happens on reboot. Scanning the file
                // right after it's written gets it indexed immediately.
                "scanFile" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("bad-args", "path missing", null)
                        return@setMethodCallHandler
                    }
                    MediaScannerConnection.scanFile(
                        applicationContext, arrayOf(path), null, null
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        // Music Player's "play out loud?" check (SpeakerPlayGuard): is any
        // audio output besides the phone's own speaker/earpiece connected —
        // Bluetooth, wired/USB headphones, a car, HDMI, ...?
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "besttodo/audio_output",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isExternalOutputConnected" -> result.success(AudioOutputs.isExternalConnected(this))
                else -> result.notImplemented()
            }
        }
        shareChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "besttodo/share",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    // Hands over every queued shared item and empties the
                    // queue in the same step, so one can never be delivered
                    // twice.
                    "takeSharedContent" -> {
                        val items = pendingSharedContent.toList()
                        pendingSharedContent.clear()
                        result.success(items)
                    }
                    // Backgrounds this app's task once the MP3 Downloader is
                    // done with a shared link, re-fronting whatever the
                    // share came from, since this activity was launched by
                    // that app's share sheet.
                    "returnToPreviousApp" -> {
                        moveTaskToBack(true)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }
}
