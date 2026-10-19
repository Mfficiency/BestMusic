package com.mfficiency.best_todo_2

import android.content.Context
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import java.io.File

/**
 * Fills the three Music widgets (1×2, 1×3, 2×3), styled after the Obsidian
 * Music player: a dark rounded card, bold title over a dimmer artist, a
 * light round play/pause button and dark round skip buttons, and (when the
 * song has one) its cover art. Every layout uses the same view ids; a view
 * a layout doesn't have is simply skipped by [RemoteViews].
 */
object MusicWidgetViews {

    private const val MAX_ART_PX = 360

    private var cachedArtKey: String? = null
    private var cachedArt: Bitmap? = null

    fun build(context: Context, layout: Int, data: SharedPreferences, hasArt: Boolean, hasPrevious: Boolean, hasNext: Boolean): RemoteViews {
        val views = RemoteViews(context.packageName, layout)

        val hasTrack = data.getBoolean("music_widget_has_track", false)
        val playing = data.getBoolean("music_widget_playing", false)
        val title = data.getString("music_widget_title", "") ?: ""
        val artist = data.getString("music_widget_artist", "") ?: ""

        views.setTextViewText(
            R.id.music_widget_title,
            if (hasTrack && title.isNotEmpty()) title else "Nothing playing"
        )
        views.setTextViewText(
            R.id.music_widget_artist,
            if (hasTrack) artist else "Tap to open Best Music"
        )
        views.setViewVisibility(
            R.id.music_widget_artist,
            if (!hasTrack || artist.isNotEmpty()) View.VISIBLE else View.GONE
        )
        views.setImageViewResource(
            R.id.music_widget_play_pause,
            if (playing) R.drawable.ic_widget_pause_dark else R.drawable.ic_widget_play_dark
        )
        views.setContentDescription(
            R.id.music_widget_play_pause,
            if (playing) "Pause" else "Play"
        )

        views.setOnClickPendingIntent(
            R.id.music_widget_play_pause,
            MusicWidgetIntents.playPause(context)
        )
        if (hasPrevious) {
            views.setOnClickPendingIntent(
                R.id.music_widget_previous,
                MusicWidgetIntents.previous(context)
            )
        }
        if (hasNext) {
            views.setOnClickPendingIntent(
                R.id.music_widget_next,
                MusicWidgetIntents.next(context)
            )
        }

        val openIntent = HomeWidgetLaunchIntent.getActivity(
            context,
            MainActivity::class.java,
            Uri.parse("besttodomusic://open")
        )
        views.setOnClickPendingIntent(R.id.music_widget_container, openIntent)

        if (hasArt) {
            val art = if (hasTrack) loadArt(data) else null
            if (art != null) {
                views.setImageViewBitmap(R.id.music_widget_art, art)
                views.setViewVisibility(R.id.music_widget_art, View.VISIBLE)
                views.setViewVisibility(R.id.music_widget_art_placeholder, View.GONE)
                views.setViewVisibility(R.id.music_widget_scrim, View.VISIBLE)
            } else {
                views.setViewVisibility(R.id.music_widget_art, View.GONE)
                views.setViewVisibility(R.id.music_widget_art_placeholder, View.VISIBLE)
                views.setViewVisibility(R.id.music_widget_scrim, View.GONE)
            }
        }
        return views
    }

    /** The cover: a downloaded image (`music_widget_art_file`, e.g. a video
     *  thumbnail) or else the picture embedded in the local song
     *  (`music_widget_audio_file`). Decoded once per song, scaled down so
     *  the RemoteViews stay small. */
    private fun loadArt(data: SharedPreferences): Bitmap? {
        val image = data.getString("music_widget_art_file", "") ?: ""
        val audio = data.getString("music_widget_audio_file", "") ?: ""
        val key = "$image|$audio"
        if (key == cachedArtKey) return cachedArt
        val bitmap = try {
            when {
                image.isNotEmpty() && File(image).isFile -> decodeFile(image)
                audio.isNotEmpty() && File(audio).isFile -> decodeEmbedded(audio)
                else -> null
            }
        } catch (e: Throwable) {
            null
        }
        cachedArtKey = key
        cachedArt = bitmap
        return bitmap
    }

    private fun decodeFile(path: String): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        val opts = BitmapFactory.Options().apply {
            inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight)
        }
        return BitmapFactory.decodeFile(path, opts)?.let(::scaleDown)
    }

    private fun decodeEmbedded(path: String): Bitmap? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(path)
            val bytes = retriever.embeddedPicture ?: return null
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            val opts = BitmapFactory.Options().apply {
                inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight)
            }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)?.let(::scaleDown)
        } finally {
            try {
                retriever.release()
            } catch (e: Throwable) {
            }
        }
    }

    private fun sampleSize(width: Int, height: Int): Int {
        var sample = 1
        while (width / (sample * 2) >= MAX_ART_PX && height / (sample * 2) >= MAX_ART_PX) {
            sample *= 2
        }
        return sample
    }

    private fun scaleDown(bitmap: Bitmap): Bitmap {
        val longest = maxOf(bitmap.width, bitmap.height)
        if (longest <= MAX_ART_PX) return bitmap
        val scale = MAX_ART_PX.toFloat() / longest
        return Bitmap.createScaledBitmap(
            bitmap,
            (bitmap.width * scale).toInt().coerceAtLeast(1),
            (bitmap.height * scale).toInt().coerceAtLeast(1),
            true
        )
    }
}
