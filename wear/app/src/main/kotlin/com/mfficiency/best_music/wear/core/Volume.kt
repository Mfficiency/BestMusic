package com.mfficiency.best_music.wear.core

/**
 * Turns the rotating bezel's scroll pixels into whole steps: one step per
 * [pxPerStep] pixels, the rest is kept for the next event. Clockwise
 * (positive pixels) = louder.
 */
class RotaryStepper(private val pxPerStep: Float = 60f) {
    private var rest = 0f

    fun add(px: Float): Int {
        if (px.isNaN()) return 0
        rest += px
        val steps = (rest / pxPerStep).toInt()
        rest -= steps * pxPerStep
        return steps
    }

    fun reset() {
        rest = 0f
    }
}

/**
 * Volume steps the user turned that the phone hasn't confirmed yet: the
 * watch shows the level it expects ([shown]) right away, sends the steps in
 * one message after a short pause ([takeUnsent]) and goes back to the
 * phone's own level once nothing is pending ([settle]).
 */
class VolumeDraft {
    var unsent: Int = 0
        private set
    private var local: Int? = null

    fun turn(steps: Int, phone: VolumeLevel?) {
        if (steps == 0) return
        unsent += steps
        if (phone != null) {
            local = ((local ?: phone.level) + steps).coerceIn(0, phone.max)
        }
    }

    /** The steps to send now (positive = up); 0 when none. */
    fun takeUnsent(): Int {
        val n = unsent
        unsent = 0
        return n
    }

    /** Drop the expected level once everything is sent: the phone's answer counts. */
    fun settle() {
        if (unsent == 0) local = null
    }

    fun shown(phone: VolumeLevel?): Int? = local ?: phone?.level
}
