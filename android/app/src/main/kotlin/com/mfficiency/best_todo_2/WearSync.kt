package com.mfficiency.best_todo_2

import android.content.Context
import android.util.Log
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable

/**
 * Hands Best Music's state to the Wear OS watch app (wear/ in this repo)
 * as Wearable Data Layer items: a `json` string plus `at` millis. The
 * paths and fields are the watch's wear/.../core/Sync.kt. Phones without
 * Play services or without a watch keep working: the request just fails
 * and is logged.
 */
object WearSync {
    private const val TAG = "WearSync"

    const val NOW_PLAYING_PATH = "/music/now_playing"
    const val VOLUME_PATH = "/music/volume"

    fun publish(context: Context, path: String, json: String) {
        try {
            val request = PutDataMapRequest.create(path).apply {
                dataMap.putString("json", json)
                dataMap.putLong("at", System.currentTimeMillis())
            }.asPutDataRequest().setUrgent()
            Wearable.getDataClient(context.applicationContext)
                .putDataItem(request)
                .addOnFailureListener { e -> Log.w(TAG, "publish $path failed: ${e.message}") }
        } catch (e: Throwable) {
            Log.w(TAG, "publish $path failed: ${e.message}")
        }
    }
}
