import 'dart:async' show unawaited;
import 'dart:convert' show utf8;
import 'dart:io';

import 'package:crypto/crypto.dart' show sha1;
import 'package:home_widget/home_widget.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../config.dart';
import '../models/track.dart';
import 'music_audio_handler.dart';
import 'music_playlist_service.dart';
import 'wear_now_playing.dart';

/// Bridges live playback state to the three Music home-screen widgets
/// (1×2, 1×3 and 2×3, styled after Obsidian Music's media card).
/// The widgets' own buttons don't come back through here — skip buttons
/// send real Android media-button broadcasts straight to `audio_service`'s
/// `MediaButtonReceiver` (see the native widget providers), the same path a
/// Bluetooth headset button uses; play/pause goes through the native
/// `MusicPlayGuardActivity`, which asks "Play out loud?" first when
/// nothing is connected. This service keeps their title, cover and play/pause
/// icon in sync with what's actually playing, and hands that activity the
/// "Ask before playing out loud" setting ([pushConfirmSetting]). The Wear OS
/// watch app gets the same now-playing state ([WearNowPlaying]).
class MusicWidgetService {
  MusicWidgetService._();

  static const String appGroupId = 'group.homeScreenApp';
  static const String miniWidgetName = 'MusicMiniWidgetProvider';
  static const String controlsWidgetName = 'MusicControlsWidgetProvider';
  static const String largeWidgetName = 'MusicLargeWidgetProvider';

  /// Where the widgets read the cover: an image file (a downloaded
  /// thumbnail) and/or a local song whose embedded picture the native side
  /// reads itself.
  static const String artFileKey = 'music_widget_art_file';
  static const String audioFileKey = 'music_widget_audio_file';

  /// Whether the playing song is in Favorites / Liked songs (the 2×3
  /// widget's heart and thumbs-up).
  static const String favoriteKey = 'music_widget_favorite';
  static const String likedKey = 'music_widget_liked';

  /// URI scheme/host the widgets use for taps that should open the app
  /// (their transport buttons instead send real media-button broadcasts —
  /// see the native widget providers — so they work without opening it).
  static const String scheme = 'besttodomusic';
  static const String hostOpen = 'open';

  static bool _attached = false;

  static Future<void> _ready() async {
    await HomeWidget.setAppGroupId(appGroupId).catchError((_) => false);
  }

  /// Starts pushing [handler]'s now-playing state to the widgets. Safe to
  /// call more than once — only the first call subscribes.
  static void attach(MusicAudioHandler handler) {
    if (_attached) return;
    _attached = true;
    unawaited(pushConfirmSetting());
    handler.mediaItem.listen((_) => _sync(handler));
    handler.playbackState.listen((_) => _sync(handler));
    // The 2×3 widget's heart and thumbs-up follow the playlists.
    MusicPlaylistService.instance.playlists.addListener(() => _sync(handler));
  }

  /// Where the native play guard reads "Ask before playing out loud".
  static const String confirmSpeakerKey = 'music_confirm_speaker';

  /// Hands the current "Ask before playing out loud" setting to the
  /// widgets' native play guard right away (Settings calls this when it's
  /// toggled; [_sync] also writes it with every playback change).
  static Future<void> pushConfirmSetting() async {
    try {
      await _ready();
      await HomeWidget.saveWidgetData<bool>(
          confirmSpeakerKey, Config.musicConfirmSpeakerPlay);
    } catch (_) {}
  }

  static Future<void> _sync(MusicAudioHandler handler) async {
    try {
      await _ready();
      final item = handler.mediaItem.valueOrNull;
      final state = handler.playbackState.valueOrNull;
      final playing = state?.playing ?? false;
      // The Wear OS watch app gets the same state (it never waits on this).
      WearNowPlaying.publish(WearNowPlayingState(
        hasTrack: item != null,
        title: item?.title ?? '',
        artist: item?.artist ?? '',
        playing: playing,
        positionMs: item == null ? 0 : (state?.position.inMilliseconds ?? 0),
        durationMs: item?.duration?.inMilliseconds ?? 0,
        at: DateTime.now().millisecondsSinceEpoch,
      ));
      await HomeWidget.saveWidgetData<String>(
          'music_widget_title', item?.title ?? '');
      await HomeWidget.saveWidgetData<String>(
          'music_widget_artist', item?.artist ?? '');
      await HomeWidget.saveWidgetData<bool>('music_widget_playing', playing);
      await HomeWidget.saveWidgetData<bool>(
          'music_widget_has_track', item != null);
      final trackId = handler.currentTrack?.id;
      await HomeWidget.saveWidgetData<bool>(favoriteKey,
          trackId != null && MusicPlaylistService.instance.isFavorite(trackId));
      await HomeWidget.saveWidgetData<bool>(likedKey,
          trackId != null && MusicPlaylistService.instance.isLiked(trackId));
      await HomeWidget.saveWidgetData<bool>(
          confirmSpeakerKey, Config.musicConfirmSpeakerPlay);
      final art = artSourceFor(handler.currentTrack, item?.artUri);
      await HomeWidget.saveWidgetData<String>(audioFileKey, art.audioFile ?? '');
      if (art.imageUrl != null && art.imageUrl != _artUrl) {
        // A new cover still has to be downloaded: show the new song now
        // (without the old cover) and the cover once it's here.
        await HomeWidget.saveWidgetData<String>(artFileKey, '');
        await _updateAll();
      }
      await HomeWidget.saveWidgetData<String>(
          artFileKey, await _artFile(art.imageUrl) ?? '');
      await _updateAll();
    } catch (_) {}
  }

  static Future<void> _updateAll() async {
    await HomeWidget.updateWidget(androidName: miniWidgetName);
    await HomeWidget.updateWidget(androidName: controlsWidgetName);
    await HomeWidget.updateWidget(androidName: largeWidgetName);
  }

  /// Where the playing song's cover comes from: a local file's embedded
  /// picture (`audioFile`) and/or a `file:`/`http(s):` art URI (`imageUrl`,
  /// e.g. a YouTube thumbnail), which wins when both are there.
  static ({String? audioFile, String? imageUrl}) artSourceFor(
      Track? track, Uri? artUri) {
    final path = track?.filePath;
    final audioFile = track != null &&
            track.source == TrackSource.local &&
            path != null &&
            path.isNotEmpty
        ? path
        : null;
    final scheme = artUri?.scheme ?? '';
    final imageUrl = (scheme == 'http' || scheme == 'https' || scheme == 'file')
        ? artUri.toString()
        : null;
    return (audioFile: audioFile, imageUrl: imageUrl);
  }

  static String? _artUrl;
  static Future<String?>? _artPath;

  /// A local copy of [url] for the native widgets to decode, downloaded
  /// once per cover into `widget_art/` (older covers are deleted). Playback
  /// events come in bursts, so the lookup is shared per cover; a failed
  /// download isn't retried until the song changes.
  static Future<String?> _artFile(String? url) {
    if (url == null) return Future.value(null);
    if (url != _artUrl || _artPath == null) {
      _artUrl = url;
      _artPath = _fetchArt(url).catchError((_) => null);
    }
    return _artPath!;
  }

  static Future<String?> _fetchArt(String url) async {
    final uri = Uri.parse(url);
    String? path;
    if (uri.scheme == 'file') {
      path = uri.toFilePath();
    } else {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/widget_art');
      final file = File(
          '${dir.path}/${sha1.convert(utf8.encode(url)).toString()}.img');
      if (!await file.exists()) {
        final response =
            await http.get(uri).timeout(const Duration(seconds: 15));
        if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
          return null;
        }
        if (await dir.exists()) {
          await for (final old in dir.list()) {
            try {
              await old.delete();
            } catch (_) {}
          }
        }
        await dir.create(recursive: true);
        await file.writeAsBytes(response.bodyBytes, flush: true);
      }
      path = file.path;
    }
    return path;
  }
}
