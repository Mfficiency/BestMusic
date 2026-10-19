package com.mfficiency.best_todo_2

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * The 1×2 Music widget: a light round play/pause button next to the title
 * and artist (see [MusicWidgetViews]). Play/pause goes through
 * [MusicPlayGuardActivity] and then a real media-button broadcast to
 * `audio_service` (see [MusicWidgetIntents]), so it works without opening
 * the app; tapping anywhere else opens it. The class name is kept from the
 * old play/pause-only widget so widgets already placed stay put.
 */
class MusicMiniWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences
    ) {
        appWidgetIds.forEach { widgetId ->
            val views = MusicWidgetViews.build(
                context, R.layout.music_mini_widget_layout, widgetData,
                hasArt = false, hasPrevious = false, hasNext = false
            )
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }
}
