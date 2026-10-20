package com.mfficiency.best_music.wear

import android.content.Context
import android.util.Log
import android.widget.Toast
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.google.android.gms.wearable.CapabilityClient
import com.google.android.gms.wearable.DataClient
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataItem
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.MessageClient
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Wearable
import com.mfficiency.best_music.wear.core.Command
import com.mfficiency.best_music.wear.core.Link
import com.mfficiency.best_music.wear.core.NowPlaying
import com.mfficiency.best_music.wear.core.Sync
import com.mfficiency.best_music.wear.core.VolumeDraft
import com.mfficiency.best_music.wear.core.VolumeLevel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await

/**
 * The phone's Best Music, seen from the watch (Wearable Data Layer; the
 * paths are in [Sync]). Listens only between [start] and [stop] (the
 * activity's onStart/onStop): no background service, nothing runs while
 * the screen is off. The last now-playing state and volume are kept in
 * SharedPreferences so the screen shows them without the phone too.
 *
 * Every Play services call is wrapped: a failure shows as the status line
 * or a short Toast, never a crash.
 */
class MusicRemote(context: Context, private val scope: CoroutineScope) {

    private val app = context.applicationContext
    private val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    var nowPlaying by mutableStateOf(NowPlaying.parse(prefs.getString(KEY_NOW_PLAYING, null)))
        private set
    var volume by mutableStateOf(VolumeLevel.parse(prefs.getString(KEY_VOLUME, null)))
        private set

    /** The volume level to show (the phone's, or the expected one while
     *  bezel steps are on their way). */
    var shownVolume by mutableStateOf(volume?.level)
        private set
    var link by mutableStateOf(Link.CHECKING)
        private set

    /** The phone asks "Play out loud?" (see [Sync.ASK_OUT_LOUD]). */
    var askOutLoud by mutableStateOf(false)
        private set

    /** True between [start] and [stop]: the progress clock only ticks then. */
    var started by mutableStateOf(false)
        private set

    private var phoneNode: String? = null
    private var linkJob: Job? = null
    private var volumeJob: Job? = null
    private var syncedThisStart = false
    private val draft = VolumeDraft()

    private val dataListener = object : DataClient.OnDataChangedListener {
        override fun onDataChanged(dataEvents: DataEventBuffer) {
            // The buffer is only valid inside this call: read it here.
            try {
                for (event in dataEvents) {
                    if (event.type == DataEvent.TYPE_CHANGED) accept(event.dataItem)
                }
            } catch (e: Throwable) {
                Log.w(TAG, "data change not read", e)
            }
        }
    }

    private val messageListener = object : MessageClient.OnMessageReceivedListener {
        override fun onMessageReceived(messageEvent: MessageEvent) {
            if (messageEvent.path == Sync.ASK_OUT_LOUD) askOutLoud = true
        }
    }

    fun start() {
        if (started) return
        started = true
        syncedThisStart = false
        try {
            Wearable.getDataClient(app).addListener(dataListener)
                .addOnFailureListener { e -> Log.w(TAG, "data listener", e) }
            Wearable.getMessageClient(app).addListener(messageListener)
                .addOnFailureListener { e -> Log.w(TAG, "message listener", e) }
        } catch (e: Throwable) {
            Log.w(TAG, "listeners not added", e)
        }
        scope.launch { readItems() }
        linkJob?.cancel()
        linkJob = scope.launch {
            while (isActive) {
                refreshLink()
                delay(LINK_CHECK_MS)
            }
        }
    }

    fun stop() {
        if (!started) return
        started = false
        linkJob?.cancel()
        linkJob = null
        try {
            Wearable.getDataClient(app).removeListener(dataListener)
            Wearable.getMessageClient(app).removeListener(messageListener)
        } catch (e: Throwable) {
            Log.w(TAG, "listeners not removed", e)
        }
    }

    /** The "Retry" chip. */
    fun retry() {
        scope.launch {
            link = Link.CHECKING
            refreshLink()
            readItems()
        }
    }

    fun playPause() = command(Command.PLAY_PAUSE)
    fun next() = command(Command.NEXT)
    fun previous() = command(Command.PREVIOUS)

    fun answerOutLoud(play: Boolean) {
        askOutLoud = false
        if (play) command(Command.PLAY_OUT_LOUD)
    }

    /** [steps] volume steps (positive = louder): shown at once, sent
     *  together after a short pause. */
    fun changeVolume(steps: Int) {
        if (steps == 0) return
        draft.turn(steps, volume)
        shownVolume = draft.shown(volume)
        volumeJob?.cancel()
        volumeJob = scope.launch {
            delay(VOLUME_DEBOUNCE_MS)
            val n = draft.takeUnsent()
            if (n != 0) {
                val cmd = if (n > 0) Command.VOLUME_UP else Command.VOLUME_DOWN
                send(cmd, Sync.stepsPayload(kotlin.math.abs(n)))
            }
            // Give the phone's answer (a new volume DataItem) a moment.
            delay(VOLUME_SETTLE_MS)
            draft.settle()
            shownVolume = draft.shown(volume)
        }
    }

    private fun command(command: Command) {
        scope.launch { send(command) }
    }

    private suspend fun send(command: Command, data: ByteArray = ByteArray(0)): Boolean {
        val node = phoneNode ?: run {
            refreshLink()
            phoneNode
        }
        if (node == null) {
            toast(R.string.error_not_reachable)
            return false
        }
        return try {
            Wearable.getMessageClient(app).sendMessage(node, Sync.commandPath(command), data).await()
            true
        } catch (e: Throwable) {
            Log.w(TAG, "send ${command.wire} failed", e)
            phoneNode = null
            toast(R.string.error_send_failed)
            refreshLink()
            false
        }
    }

    /** Which phone to talk to, and whether it has a Best Music that can. */
    private suspend fun refreshLink() {
        val next = try {
            val info = Wearable.getCapabilityClient(app)
                .getCapability(Sync.PHONE_CAPABILITY, CapabilityClient.FILTER_REACHABLE)
                .await()
            val nodes = info.nodes
            val node = nodes.firstOrNull { it.isNearby } ?: nodes.firstOrNull()
            phoneNode = node?.id
            if (node != null) {
                Link.CONNECTED
            } else {
                val connected = Wearable.getNodeClient(app).connectedNodes.await()
                if (connected.isNotEmpty()) Link.APP_MISSING else Link.UNREACHABLE
            }
        } catch (e: Throwable) {
            Log.w(TAG, "phone lookup failed", e)
            phoneNode = null
            Link.UNREACHABLE
        }
        link = next
        if (next == Link.CONNECTED && !syncedThisStart) {
            // Ask for the phone's current volume once per start.
            syncedThisStart = true
            send(Command.SYNC)
        }
    }

    /** What the phone published while this screen was closed. */
    private suspend fun readItems() {
        try {
            val buffer = Wearable.getDataClient(app).dataItems.await()
            try {
                for (item in buffer) accept(item)
            } finally {
                buffer.release()
            }
        } catch (e: Throwable) {
            Log.w(TAG, "data items not read", e)
        }
    }

    private fun accept(item: DataItem) {
        val path = item.uri.path ?: return
        if (path != Sync.NOW_PLAYING && path != Sync.VOLUME) return
        val json = try {
            DataMapItem.fromDataItem(item).dataMap.getString("json")
        } catch (e: Throwable) {
            null
        } ?: return
        when (path) {
            Sync.NOW_PLAYING -> NowPlaying.parse(json)?.let { np ->
                // Out of order (an older item read after a newer change): keep the newer.
                val current = nowPlaying
                if (current == null || np.at >= current.at) {
                    nowPlaying = np
                    prefs.edit().putString(KEY_NOW_PLAYING, json).apply()
                }
            }
            Sync.VOLUME -> VolumeLevel.parse(json)?.let { v ->
                volume = v
                prefs.edit().putString(KEY_VOLUME, json).apply()
                shownVolume = draft.shown(v)
            }
        }
    }

    private fun toast(text: Int) {
        try {
            Toast.makeText(app, text, Toast.LENGTH_SHORT).show()
        } catch (e: Throwable) {
            Log.w(TAG, "toast", e)
        }
    }

    private companion object {
        const val TAG = "MusicRemote"
        const val PREFS = "music_remote"
        const val KEY_NOW_PLAYING = "now_playing_json"
        const val KEY_VOLUME = "volume_json"
        const val LINK_CHECK_MS = 30_000L
        const val VOLUME_DEBOUNCE_MS = 250L
        const val VOLUME_SETTLE_MS = 1_500L
    }
}
