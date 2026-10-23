package com.mfficiency.best_music.wear.core

import org.json.JSONObject

/**
 * What the phone's Best Music plays, as published by the phone
 * (lib/services/wear_now_playing.dart). [at] is the phone's clock when
 * [positionMs] was read.
 */
data class NowPlaying(
    val hasTrack: Boolean,
    val title: String,
    val artist: String,
    val playing: Boolean,
    val positionMs: Long,
    val durationMs: Long,
    val at: Long,
) {
    /** The position at [now], counted on from [at] while playing, within
     *  0..[durationMs]; 0 without a known duration. */
    fun positionAt(now: Long): Long {
        if (durationMs <= 0L) return 0L
        val moved = if (playing) (now - at).coerceAtLeast(0L) else 0L
        return (positionMs + moved).coerceIn(0L, durationMs)
    }

    /** 0..1 for a progress bar; 0 without a known duration. */
    fun progressAt(now: Long): Float =
        if (durationMs <= 0L) 0f else positionAt(now).toFloat() / durationMs.toFloat()

    companion object {
        /** null for anything that isn't a now-playing object. */
        fun parse(json: String?): NowPlaying? {
            if (json.isNullOrBlank()) return null
            return try {
                val o = JSONObject(json)
                NowPlaying(
                    hasTrack = o.optBoolean("hasTrack", false),
                    title = o.text("title"),
                    artist = o.text("artist"),
                    playing = o.optBoolean("playing", false),
                    positionMs = o.optLong("positionMs", 0L).coerceAtLeast(0L),
                    durationMs = o.optLong("durationMs", 0L).coerceAtLeast(0L),
                    at = o.optLong("at", 0L),
                )
            } catch (e: Exception) {
                null
            }
        }
    }
}

/** The phone's media volume: [level] of [max] steps. */
data class VolumeLevel(val level: Int, val max: Int) {
    companion object {
        fun parse(json: String?): VolumeLevel? {
            if (json.isNullOrBlank()) return null
            return try {
                val o = JSONObject(json)
                val max = o.optInt("max", 0)
                if (max <= 0) null else VolumeLevel(o.optInt("level", 0).coerceIn(0, max), max)
            } catch (e: Exception) {
                null
            }
        }
    }
}

/** A string field; "" when missing or JSON null (optString would give "null"). */
internal fun JSONObject.text(key: String): String =
    if (isNull(key)) "" else optString(key, "")

/** "3:07" / "1:02:03" for [ms]. */
fun formatClock(ms: Long): String {
    val total = (ms.coerceAtLeast(0L) / 1000L)
    val h = total / 3600L
    val m = (total % 3600L) / 60L
    val s = total % 60L
    return if (h > 0L) {
        "$h:${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}"
    } else {
        "$m:${s.toString().padStart(2, '0')}"
    }
}
