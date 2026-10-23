package com.mfficiency.best_todo_2

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * The 2×3 Music widget, like Obsidian Music's media card: the cover fills
 * the card under a dark scrim, the title and artist sit on top, and
 * skip-previous / play-pause / skip-next run along the bottom (see
 * [MusicWidgetViews]). Dislike, like and the heart sit top right; they
 * go through [MusicWidgetActionReceiver] (dislike also skips, like works
 * once, the heart toggles Favorites).
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
            val favorite = widgetData.getBoolean("music_widget_favorite", false)
            val liked = widgetData.getBoolean("music_widget_liked", false)
            views.setImageViewResource(
                R.id.music_widget_favorite,
                if (favorite) R.drawable.ic_widget_favorite_on else R.drawable.ic_widget_favorite
            )
            views.setContentDescription(
                R.id.music_widget_favorite,
                if (favorite) "Remove from Favorites" else "Add to Favorites"
            )
            views.setImageViewResource(
                R.id.music_widget_like,
                if (liked) R.drawable.ic_widget_thumb_up_on else R.drawable.ic_widget_thumb_up
            )
            views.setOnClickPendingIntent(
                R.id.music_widget_like,
                MusicWidgetIntents.customAction(context, "widget_like", 9101)
            )
            views.setOnClickPendingIntent(
                R.id.music_widget_dislike,
                MusicWidgetIntents.customAction(context, "widget_dislike", 9102)
            )
            views.setOnClickPendingIntent(
                R.id.music_widget_favorite,
                MusicWidgetIntents.customAction(context, "widget_favorite", 9103)
            )
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }
}
