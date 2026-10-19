package com.mfficiency.best_todo_2

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * The 2×3 Music widget, like Obsidian Music's media card: the cover fills
 * the card under a dark scrim, the title and artist sit on top, and
 * skip-previous / play-pause / skip-next run along the bottom (see
 * [MusicWidgetViews]).
 */
class MusicLargeWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences
    ) {
        appWidgetIds.forEach { widgetId ->
            val views = MusicWidgetViews.build(
                context, R.layout.music_large_widget_layout, widgetData,
                hasArt = true, hasPrevious = true, hasNext = true
            )
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }
}
