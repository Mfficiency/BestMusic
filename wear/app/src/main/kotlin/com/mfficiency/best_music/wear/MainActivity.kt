package com.mfficiency.best_music.wear

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel

/**
 * Best Music Watch: one screen, a remote for the phone's player (see
 * README.md in wear/). The phone link only runs while this activity is
 * started.
 */
class MainActivity : ComponentActivity() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var remote: MusicRemote

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        remote = MusicRemote(this, scope)
        setContent { RemoteApp(remote) }
    }

    override fun onStart() {
        super.onStart()
        remote.start()
    }

    override fun onStop() {
        remote.stop()
        super.onStop()
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }
}
