import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';
import 'audio_trimmer.dart';
import 'log_service.dart';
import 'media_scanner_service.dart';
import 'music_library_service.dart';

/// What [TrackTrimmer.trim] did, for the result message and Undo.
class TrackTrimResult {
  const TrackTrimResult({
    required this.track,
    required this.newDuration,
    this.backupPath,
  });

  /// The shortened song (the same one, or the new copy).
  final Track track;
  final Duration newDuration;

  /// Where the original file was put aside (in-place trims only), so
  /// [TrackTrimmer.undo] can bring it back.
  final String? backupPath;
}

/// Shortens a phone song's file ([AudioTrimmer]) — "Shorten song" in a
/// song's ⋮ menu and on its info page. In place (the default), the
/// original file goes to `trim_backups/` in the app's documents folder
/// (kept for [backupDays] days, so Undo can restore it) and the shortened
/// file takes its place under the same name; or the result is saved as a
/// new song next to it ("<name> (short)"). Either way the library entry
/// gets the new length and Android's media index is told.
class TrackTrimmer {
  TrackTrimmer._();

  static const int backupDays = 7;

  /// Tests point the backups somewhere else.
  @visibleForTesting
  static Future<Directory> Function()? backupDirOverride;

  static bool canTrim(Track track) =>
      track.source == TrackSource.local &&
      track.filePath != null &&
      AudioTrimmer.supports(track.filePath!);

  static Future<Directory> _backupDir() async {
    final dir = backupDirOverride != null
        ? await backupDirOverride!()
        : Directory('${(await getApplicationDocumentsDirectory()).path}'
            '/trim_backups');
    await dir.create(recursive: true);
    return dir;
  }

  static String _ext(String path) {
    final dot = path.lastIndexOf('.');
    return dot < 0 ? '' : path.substring(dot);
  }

  static Future<TrackTrimResult> trim(
    Track track,
    Duration start,
    Duration end, {
    bool keepOriginal = false,
  }) async {
    final path = track.filePath;
    if (!canTrim(track) || path == null) {
      throw AudioTrimException("This song can't be shortened");
    }
    if (!await File(path).exists()) {
      throw AudioTrimException('The file is gone: $path');
    }
    final ext = _ext(path);
    final base = path.substring(0, path.length - ext.length);
    if (keepOriginal) {
      var target = '$base (short)$ext';
      for (var n = 2; await File(target).exists(); n++) {
        target = '$base (short $n)$ext';
      }
      final length = await AudioTrimmer.trimFile(path, target, start, end);
      final json = track.toJson()
        ..remove('playCount')
        ..remove('skipCount')
        ..remove('upSwipeCount')
        ..remove('downSwipeCount')
        ..['id'] = 'local:$target'
        ..['filePath'] = target
        ..['title'] =
            '${track.title.isEmpty ? track.fileBaseName : track.title} (short)'
        ..['durationMs'] = length.inMilliseconds
        ..['dateAdded'] = DateTime.now().millisecondsSinceEpoch
        ..['deviceDate'] = DateTime.now().millisecondsSinceEpoch;
      final copy = Track.fromJson(json);
      await MusicLibraryService.instance.replaceTrack(copy.id, copy);
      await MediaScannerService.scanFile(target);
      LogService.add('Trim', 'Saved $target (${length.inSeconds}s)');
      return TrackTrimResult(track: copy, newDuration: length);
    }
    // In place: build the short version next to the file, put the
    // original aside, then move the short one into its name.
    final temp = '$base.trimming$ext';
    final length = await AudioTrimmer.trimFile(path, temp, start, end);
    final backups = await _backupDir();
    await _purgeOldBackups(backups);
    final name = path.substring(path.lastIndexOf(RegExp(r'[\\/]')) + 1);
    final backup =
        '${backups.path}/${DateTime.now().millisecondsSinceEpoch}_$name';
    await _move(path, backup);
    try {
      await _move(temp, path);
    } catch (e) {
      await _move(backup, path); // put the original back
      rethrow;
    }
    final updated = track.copyWith(durationMs: length.inMilliseconds);
    await MusicLibraryService.instance.replaceTrack(track.id, updated);
    await MediaScannerService.scanFile(path);
    LogService.add('Trim', 'Shortened $path to ${length.inSeconds}s');
    return TrackTrimResult(
        track: updated, newDuration: length, backupPath: backup);
  }

  /// Takes a trim back: the original file returns (in place), or the new
  /// copy is deleted.
  static Future<void> undo(TrackTrimResult result, Track original) async {
    final backup = result.backupPath;
    final path = result.track.filePath;
    if (path == null) return;
    if (backup != null) {
      await _move(backup, path);
      await MusicLibraryService.instance.replaceTrack(original.id, original);
    } else {
      final file = File(path);
      if (await file.exists()) await file.delete();
      final library = MusicLibraryService.instance;
      library.tracks.value =
          library.tracks.value.where((t) => t.id != result.track.id).toList();
      await library.replaceTrack(original.id, original);
    }
    await MediaScannerService.scanFile(path);
  }

  /// Rename, or copy + delete across file systems (SD card ↔ app storage).
  static Future<void> _move(String from, String to) async {
    try {
      await File(from).rename(to);
    } on FileSystemException {
      await File(from).copy(to);
      await File(from).delete();
    }
  }

  static Future<void> _purgeOldBackups(Directory dir) async {
    final cutoff = DateTime.now().subtract(const Duration(days: backupDays));
    try {
      await for (final f in dir.list()) {
        if (f is File && (await f.lastModified()).isBefore(cutoff)) {
          await f.delete();
        }
      }
    } catch (_) {}
  }
}
