package com.mfficiency.best_music.wear.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NowPlayingTest {

    private val json = """{"hasTrack":true,"title":"Song","artist":"Band","playing":true,""" +
        """"positionMs":10000,"durationMs":200000,"at":1000}"""

    @Test
    fun parsesWhatThePhoneSends() {
        val np = NowPlaying.parse(json)!!
        assertTrue(np.hasTrack)
        assertEquals("Song", np.title)
        assertEquals("Band", np.artist)
        assertTrue(np.playing)
        assertEquals(10000L, np.positionMs)
        assertEquals(200000L, np.durationMs)
        assertEquals(1000L, np.at)
    }

    @Test
    fun missingAndNullFieldsGetDefaults() {
        val np = NowPlaying.parse("""{"title":null}""")!!
        assertFalse(np.hasTrack)
        assertEquals("", np.title)
        assertEquals("", np.artist)
        assertFalse(np.playing)
        assertEquals(0L, np.durationMs)
    }

    @Test
    fun rejectsGarbage() {
        assertNull(NowPlaying.parse(null))
        assertNull(NowPlaying.parse(""))
        assertNull(NowPlaying.parse("not json"))
        assertNull(NowPlaying.parse("[1,2]"))
    }

    @Test
    fun positionRunsOnWhilePlayingAndStopsAtTheEnd() {
        val np = NowPlaying.parse(json)!!
        assertEquals(15000L, np.positionAt(6000L))
        assertEquals(10000L, np.positionAt(500L)) // clock behind: no going back
        assertEquals(200000L, np.positionAt(10_000_000L))
        assertEquals(0.075f, np.progressAt(6000L), 0.0001f)
    }

    @Test
    fun positionStandsStillWhilePaused() {
        val np = NowPlaying.parse(json)!!.copy(playing = false)
        assertEquals(10000L, np.positionAt(60_000L))
    }

    @Test
    fun noDurationNoPosition() {
        val np = NowPlaying.parse(json)!!.copy(durationMs = 0L)
        assertEquals(0L, np.positionAt(6000L))
        assertEquals(0f, np.progressAt(6000L), 0f)
    }

    @Test
    fun volumeParses() {
        assertEquals(VolumeLevel(7, 15), VolumeLevel.parse("""{"level":7,"max":15}"""))
        assertEquals(VolumeLevel(15, 15), VolumeLevel.parse("""{"level":40,"max":15}"""))
        assertNull(VolumeLevel.parse("""{"level":3,"max":0}"""))
        assertNull(VolumeLevel.parse("nope"))
        assertNull(VolumeLevel.parse(null))
    }

    @Test
    fun clockFormat() {
        assertEquals("0:00", formatClock(0L))
        assertEquals("0:00", formatClock(-5L))
        assertEquals("3:07", formatClock(187_400L))
        assertEquals("1:02:03", formatClock(3_723_000L))
    }
}
