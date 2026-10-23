package com.mfficiency.best_music.wear.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class VolumeTest {

    @Test
    fun stepperCountsWholeStepsAndKeepsTheRest() {
        val s = RotaryStepper(60f)
        assertEquals(0, s.add(30f))
        assertEquals(1, s.add(40f)) // 70 -> 1 step, 10 left
        assertEquals(2, s.add(110f)) // 120 -> 2 steps
        assertEquals(-1, s.add(-60f))
        assertEquals(0, s.add(Float.NaN))
        s.reset()
        assertEquals(0, s.add(59f))
    }

    @Test
    fun draftShowsTheExpectedLevelUntilSettled() {
        val phone = VolumeLevel(7, 15)
        val d = VolumeDraft()
        assertEquals(7, d.shown(phone))
        d.turn(2, phone)
        d.turn(1, phone)
        assertEquals(10, d.shown(phone))
        assertEquals(3, d.takeUnsent())
        assertEquals(0, d.takeUnsent())
        d.settle()
        assertEquals(9, d.shown(VolumeLevel(9, 15)))
    }

    @Test
    fun draftStaysInRange() {
        val phone = VolumeLevel(14, 15)
        val d = VolumeDraft()
        d.turn(5, phone)
        assertEquals(15, d.shown(phone))
        d.turn(-40, phone)
        assertEquals(0, d.shown(phone))
        assertEquals(-35, d.unsent)
    }

    @Test
    fun draftWithoutAPhoneLevelStillCountsSteps() {
        val d = VolumeDraft()
        d.turn(2, null)
        assertNull(d.shown(null))
        assertEquals(2, d.takeUnsent())
    }

    @Test
    fun settleWaitsForUnsentSteps() {
        val phone = VolumeLevel(5, 15)
        val d = VolumeDraft()
        d.turn(1, phone)
        d.settle()
        assertEquals(6, d.shown(phone))
    }
}
