package com.mfficiency.best_music.wear.core

/** How the watch sees the phone right now. */
enum class Link {
    /** Not checked yet. */
    CHECKING,

    /** A reachable phone advertises Best Music's capability. */
    CONNECTED,

    /** A phone is connected, but its Best Music doesn't talk to watches
     *  yet (no capability: an older version). */
    APP_MISSING,

    /** No phone in reach (off, out of range, airplane mode, no Bluetooth). */
    UNREACHABLE,
}

/** The one status line at the top of the screen. */
enum class Status {
    CHECKING,
    CONNECTED,
    NOTHING_PLAYING,
    NOT_REACHABLE,

    /** Not reachable, showing what was saved (with its time). */
    NOT_REACHABLE_SAVED,
    UPDATE_PHONE_APP,
}

fun statusOf(link: Link, nowPlaying: NowPlaying?): Status = when (link) {
    Link.CHECKING -> Status.CHECKING
    Link.APP_MISSING -> Status.UPDATE_PHONE_APP
    Link.UNREACHABLE ->
        if (nowPlaying != null && nowPlaying.at > 0L) Status.NOT_REACHABLE_SAVED else Status.NOT_REACHABLE
    Link.CONNECTED ->
        if (nowPlaying == null || !nowPlaying.hasTrack) Status.NOTHING_PLAYING else Status.CONNECTED
}
