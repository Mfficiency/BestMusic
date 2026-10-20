package com.mfficiency.best_music.wear.core

import org.junit.Assert.assertEquals
import org.junit.Test

class StatusTest {

    private val song = NowPlaying(true, "Song", "Band", true, 0L, 1000L, 5L)

    @Test
    fun connected() {
        assertEquals(Status.CONNECTED, statusOf(Link.CONNECTED, song))
        assertEquals(Status.NOTHING_PLAYING, statusOf(Link.CONNECTED, null))
        assertEquals(Status.NOTHING_PLAYING, statusOf(Link.CONNECTED, song.copy(hasTrack = false)))
    }

    @Test
    fun unreachableShowsWhatWasSaved() {
        assertEquals(Status.NOT_REACHABLE_SAVED, statusOf(Link.UNREACHABLE, song))
        assertEquals(Status.NOT_REACHABLE, statusOf(Link.UNREACHABLE, null))
        assertEquals(Status.NOT_REACHABLE, statusOf(Link.UNREACHABLE, song.copy(at = 0L)))
    }

    @Test
    fun otherStates() {
        assertEquals(Status.CHECKING, statusOf(Link.CHECKING, song))
        assertEquals(Status.UPDATE_PHONE_APP, statusOf(Link.APP_MISSING, song))
    }

    @Test
    fun commandPaths() {
        assertEquals("/music/command/play_pause", Sync.commandPath(Command.PLAY_PAUSE))
        assertEquals("/music/command/volume_down", Sync.commandPath(Command.VOLUME_DOWN))
        assertEquals("3", String(Sync.stepsPayload(3), Charsets.UTF_8))
        assertEquals("1", String(Sync.stepsPayload(0), Charsets.UTF_8))
    }
}
