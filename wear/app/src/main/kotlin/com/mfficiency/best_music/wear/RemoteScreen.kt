package com.mfficiency.best_music.wear

import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.rotary.onRotaryScrollEvent
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.wear.compose.material.Button
import androidx.wear.compose.material.ButtonDefaults
import androidx.wear.compose.material.Colors
import androidx.wear.compose.material.CompactChip
import androidx.wear.compose.material.Icon
import androidx.wear.compose.material.MaterialTheme
import androidx.wear.compose.material.Scaffold
import androidx.wear.compose.material.Text
import androidx.wear.compose.material.TimeText
import androidx.wear.compose.material.Vignette
import androidx.wear.compose.material.VignettePosition
import androidx.wear.compose.material.dialog.Alert
import androidx.wear.compose.material.dialog.Dialog
import com.mfficiency.best_music.wear.core.NowPlaying
import com.mfficiency.best_music.wear.core.RotaryStepper
import com.mfficiency.best_music.wear.core.Status
import com.mfficiency.best_music.wear.core.formatClock
import com.mfficiency.best_music.wear.core.statusOf
import kotlinx.coroutines.delay

// Best Music's blue (lib/ui/music_theme.dart, musicSeedColor) on black.
private val MusicBlue = Color(0xFF005FDD)
private val MusicBlueLight = Color(0xFF9EC2FF)

private val WatchColors = Colors(
    primary = MusicBlue,
    primaryVariant = MusicBlue,
    secondary = MusicBlueLight,
    secondaryVariant = MusicBlueLight,
    background = Color.Black,
    surface = Color(0xFF202124),
    onPrimary = Color.White,
    onSecondary = Color.Black,
    onBackground = Color.White,
    onSurface = Color.White,
)

@Composable
fun RemoteApp(remote: MusicRemote) {
    MaterialTheme(colors = WatchColors) {
        RemoteScreen(remote)
        Dialog(
            showDialog = remote.askOutLoud,
            onDismissRequest = { remote.answerOutLoud(false) },
        ) {
            Alert(
                title = {
                    Text(
                        stringResource(R.string.out_loud_title),
                        textAlign = TextAlign.Center,
                    )
                },
                negativeButton = {
                    Button(
                        onClick = { remote.answerOutLoud(false) },
                        colors = ButtonDefaults.secondaryButtonColors(),
                    ) {
                        Icon(
                            painter = painterResource(R.drawable.ic_close),
                            contentDescription = stringResource(R.string.out_loud_cancel),
                        )
                    }
                },
                positiveButton = {
                    Button(onClick = { remote.answerOutLoud(true) }) {
                        Icon(
                            painter = painterResource(R.drawable.ic_check),
                            contentDescription = stringResource(R.string.out_loud_play),
                        )
                    }
                },
            ) {
                Text(
                    stringResource(R.string.out_loud_message),
                    textAlign = TextAlign.Center,
                    style = MaterialTheme.typography.body2,
                )
            }
        }
    }
}

/**
 * One screen that fits the round display without scrolling, so the
 * rotating bezel is free for the phone's volume (like the watch's own
 * media controls): status, song, progress, previous / play-pause / next,
 * and volume - / + for touch.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun RemoteScreen(remote: MusicRemote) {
    val focus = remember { FocusRequester() }
    val stepper = remember { RotaryStepper() }
    val np = remote.nowPlaying
    val status = statusOf(remote.link, np)

    var now by remember { mutableStateOf(System.currentTimeMillis()) }
    LaunchedEffect(np, remote.started) {
        now = System.currentTimeMillis()
        while (np != null && np.playing && remote.started) {
            delay(1_000L)
            now = System.currentTimeMillis()
        }
    }
    // The bezel needs focus; take it back after the dialog closes.
    LaunchedEffect(remote.askOutLoud) {
        if (!remote.askOutLoud) {
            try {
                focus.requestFocus()
            } catch (e: IllegalStateException) {
                // Not attached yet: the next composition asks again.
            }
        }
    }

    Scaffold(
        timeText = { TimeText() },
        vignette = { Vignette(vignettePosition = VignettePosition.TopAndBottom) },
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .background(MaterialTheme.colors.background)
                .onRotaryScrollEvent { event ->
                    val steps = stepper.add(event.verticalScrollPixels)
                    if (steps != 0) remote.changeVolume(steps)
                    true
                }
                .focusRequester(focus)
                .focusable()
                .padding(start = 22.dp, end = 22.dp, top = 30.dp, bottom = 18.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            StatusLine(status, np, onRetry = remote::retry)
            Spacer(Modifier.height(4.dp))
            SongText(np, status)
            Spacer(Modifier.height(6.dp))
            Progress(np, now)
            Spacer(Modifier.height(6.dp))
            Transport(
                playing = np?.playing == true,
                onPrevious = remote::previous,
                onPlayPause = remote::playPause,
                onNext = remote::next,
            )
            Spacer(Modifier.height(6.dp))
            VolumeRow(
                level = remote.shownVolume,
                max = remote.volume?.max,
                onDown = { remote.changeVolume(-1) },
                onUp = { remote.changeVolume(1) },
            )
        }
    }
}

@Composable
private fun StatusLine(status: Status, np: NowPlaying?, onRetry: () -> Unit) {
    val context = LocalContext.current
    val text = when (status) {
        Status.CHECKING -> stringResource(R.string.status_checking)
        Status.CONNECTED -> stringResource(R.string.status_connected)
        Status.NOTHING_PLAYING -> stringResource(R.string.status_nothing_playing)
        Status.NOT_REACHABLE -> stringResource(R.string.status_not_reachable)
        Status.NOT_REACHABLE_SAVED -> {
            val at = np?.at ?: 0L
            val time = try {
                android.text.format.DateFormat.getTimeFormat(context).format(java.util.Date(at))
            } catch (e: Exception) {
                ""
            }
            stringResource(R.string.status_not_reachable_saved, time)
        }
        Status.UPDATE_PHONE_APP -> stringResource(R.string.status_update_phone_app)
    }
    val offline = status == Status.NOT_REACHABLE ||
        status == Status.NOT_REACHABLE_SAVED ||
        status == Status.UPDATE_PHONE_APP
    Text(
        text,
        style = MaterialTheme.typography.caption3,
        color = if (offline) MaterialTheme.colors.onSurfaceVariant else MaterialTheme.colors.secondary,
        textAlign = TextAlign.Center,
        maxLines = 2,
        overflow = TextOverflow.Ellipsis,
    )
    if (offline) {
        Spacer(Modifier.height(2.dp))
        CompactChip(
            onClick = onRetry,
            label = { Text(stringResource(R.string.retry)) },
            colors = androidx.wear.compose.material.ChipDefaults.secondaryChipColors(),
        )
    }
}

@Composable
private fun SongText(np: NowPlaying?, status: Status) {
    val hasTrack = np != null && np.hasTrack
    val title = when {
        hasTrack && np!!.title.isNotEmpty() -> np.title
        hasTrack -> stringResource(R.string.no_title)
        else -> stringResource(R.string.status_nothing_playing)
    }
    // Faded while it is only what was saved.
    val alpha = if (status == Status.NOT_REACHABLE_SAVED) 0.6f else 1f
    Text(
        title,
        style = MaterialTheme.typography.title3,
        color = MaterialTheme.colors.onBackground.copy(alpha = alpha),
        textAlign = TextAlign.Center,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
    )
    val artist = if (hasTrack) np!!.artist else stringResource(R.string.press_play)
    if (artist.isNotEmpty()) {
        Text(
            artist,
            style = MaterialTheme.typography.caption2,
            color = MaterialTheme.colors.onSurfaceVariant.copy(alpha = alpha),
            textAlign = TextAlign.Center,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun Progress(np: NowPlaying?, now: Long) {
    if (np == null || !np.hasTrack || np.durationMs <= 0L) return
    val fraction = np.progressAt(now).coerceIn(0f, 1f)
    Box(
        modifier = Modifier
            .fillMaxWidth(0.8f)
            .height(3.dp)
            .background(MaterialTheme.colors.surface, RoundedCornerShape(2.dp)),
    ) {
        Box(
            modifier = Modifier
                .fillMaxHeight()
                .fillMaxWidth(fraction)
                .background(MaterialTheme.colors.secondary, RoundedCornerShape(2.dp)),
        )
    }
    Text(
        "${formatClock(np.positionAt(now))} / ${formatClock(np.durationMs)}",
        style = MaterialTheme.typography.caption3,
        color = MaterialTheme.colors.onSurfaceVariant,
    )
}

@Composable
private fun Transport(
    playing: Boolean,
    onPrevious: () -> Unit,
    onPlayPause: () -> Unit,
    onNext: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        Button(
            onClick = onPrevious,
            colors = ButtonDefaults.secondaryButtonColors(),
            modifier = Modifier.size(ButtonDefaults.SmallButtonSize),
        ) {
            Icon(
                painter = painterResource(R.drawable.ic_previous),
                contentDescription = stringResource(R.string.previous),
            )
        }
        Spacer(Modifier.width(8.dp))
        Button(
            onClick = onPlayPause,
            modifier = Modifier.size(ButtonDefaults.LargeButtonSize),
        ) {
            Icon(
                painter = painterResource(if (playing) R.drawable.ic_pause else R.drawable.ic_play),
                contentDescription = stringResource(if (playing) R.string.pause else R.string.play),
                modifier = Modifier.size(30.dp),
            )
        }
        Spacer(Modifier.width(8.dp))
        Button(
            onClick = onNext,
            colors = ButtonDefaults.secondaryButtonColors(),
            modifier = Modifier.size(ButtonDefaults.SmallButtonSize),
        ) {
            Icon(
                painter = painterResource(R.drawable.ic_next),
                contentDescription = stringResource(R.string.next),
            )
        }
    }
}

@Composable
private fun VolumeRow(level: Int?, max: Int?, onDown: () -> Unit, onUp: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        Button(
            onClick = onDown,
            colors = ButtonDefaults.secondaryButtonColors(),
            modifier = Modifier.size(ButtonDefaults.ExtraSmallButtonSize),
        ) {
            Icon(
                painter = painterResource(R.drawable.ic_remove),
                contentDescription = stringResource(R.string.volume_down),
                modifier = Modifier.size(16.dp),
            )
        }
        Text(
            if (level != null && max != null) {
                stringResource(R.string.volume_level, level, max)
            } else {
                stringResource(R.string.volume)
            },
            style = MaterialTheme.typography.caption2,
            color = MaterialTheme.colors.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.width(76.dp),
        )
        Button(
            onClick = onUp,
            colors = ButtonDefaults.secondaryButtonColors(),
            modifier = Modifier.size(ButtonDefaults.ExtraSmallButtonSize),
        ) {
            Icon(
                painter = painterResource(R.drawable.ic_add),
                contentDescription = stringResource(R.string.volume_up),
                modifier = Modifier.size(16.dp),
            )
        }
    }
}
