package com.mfficiency.best_music.wear.core

/**
 * The Data Layer contract between the phone (android/app: WearSync.kt,
 * WearCommandService.kt) and this watch app. Keep both sides in step.
 *
 * Phone -> watch, DataItems (a `json` string + `at` millis):
 * - [NOW_PLAYING]: what the phone's player plays ([NowPlaying]).
 * - [VOLUME]: the phone's media volume ([VolumeLevel]), sent after every
 *   volume command and on [Command.SYNC].
 *
 * Watch -> phone, messages to the node with [PHONE_CAPABILITY]:
 * `/music/command/<name>` ([Command]); volume commands carry the number of
 * steps as UTF-8 text ("3"), the others no data.
 *
 * Phone -> watch message [ASK_OUT_LOUD]: play/pause found nothing
 * connected to the phone and "Ask before playing out loud" on, so the watch
 * asks and answers with [Command.PLAY_OUT_LOUD].
 */
object Sync {
    const val NOW_PLAYING = "/music/now_playing"
    const val VOLUME = "/music/volume"
    const val ASK_OUT_LOUD = "/music/ask_out_loud"
    const val COMMAND_PREFIX = "/music/command/"

    const val PHONE_CAPABILITY = "best_music_phone"
    const val WEAR_CAPABILITY = "best_music_wear"

    fun commandPath(command: Command): String = COMMAND_PREFIX + command.wire

    /** The payload of a volume command: [steps] as text, at least 1. */
    fun stepsPayload(steps: Int): ByteArray = steps.coerceAtLeast(1).toString().toByteArray(Charsets.UTF_8)
}

enum class Command(val wire: String) {
    PLAY_PAUSE("play_pause"),
    PLAY_OUT_LOUD("play_out_loud"),
    NEXT("next"),
    PREVIOUS("previous"),
    VOLUME_UP("volume_up"),
    VOLUME_DOWN("volume_down"),
    SYNC("sync"),
}
