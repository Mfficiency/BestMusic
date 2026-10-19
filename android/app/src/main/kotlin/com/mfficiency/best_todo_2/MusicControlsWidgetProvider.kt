package com.mfficiency.best_todo_2

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * The 1×3 Music widget: cover art, title and artist, then play/pause and
 * skip-next (see [MusicWidgetViews]). The class name is kept from the old
 * controls widget so widgets already placed stay put.
 */
class MusicControlsWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences
    ) {
        appWidgetIds.forEach { widgetId ->
            val views = MusicWidgetViews.build(
                context, R.layout.music_controls_widget_layout, widgetData,
                hasArt = true, hasPrevious = false, hasNext = true
            )
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }
}
