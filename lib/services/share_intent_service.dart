import 'dart:async';

import 'package:flutter/services.dart';

import '../models/shared_payload.dart';

/// Receives Android share-sheet text (see `ShareActivity.kt`) and hands it
/// to the app (`main.dart`), which opens the MP3 Downloader for it.
///
/// Native side: `ShareActivity` receives the ACTION_SEND intent and
/// forwards it to `MainActivity`, which queues it. Delivery to Dart is
/// always pull-with-clear (`takeSharedContent`), so a share is never pulled
/// twice: the initial pull in [init] covers a cold start, and a
/// `sharedContentPending` poke triggers another pull when a share arrives
/// while the app is already running. A short content-signature window (see
/// [dedupWindow]) drops a share that Android (or a fast double-tap on the
/// share target) redelivers.
///
/// [setOnSharedPayload] is how `main.dart` hooks up the downloader — every
/// payload from here on (including ones that arrived before the callback
/// was attached) is handed to it, one at a time.
class ShareIntentService {
  ShareIntentService._();

  static final ShareIntentService instance = ShareIntentService._();

  static const MethodChannel _channel = MethodChannel('besttodo/share');

  /// How long a content signature is remembered to reject a redelivered
  /// share. Overridable so tests don't sleep.
  static Duration dedupWindow = const Duration(seconds: 5);

  void Function(SharedPayload payload)? _onPayload;
  final List<SharedPayload> _pendingPayloads = [];
  final Map<String, DateTime> _recentSignatures = {};
  bool _initialized = false;

  /// Hooks up the platform channel and drains any content queued before the
  /// Flutter engine was ready. Android-only; elsewhere the channel has no
  /// implementation and the pull simply fails silently.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'sharedContentPending') await _pull();
    });
    await _pull();
  }

  Future<void> _pull() async {
    List<Object?>? items;
    try {
      items = await _channel.invokeListMethod<Object?>('takeSharedContent');
    } catch (_) {
      return;
    }
    for (final item in items ?? const <Object?>[]) {
      if (item is Map) {
        handleSharedPayload(SharedPayload.fromMap(item.cast<Object?, Object?>()));
      }
    }
  }

  /// Routes one shared payload to the registered callback, or queues it
  /// until [setOnSharedPayload] attaches one. Drops an empty payload and a
  /// redelivered duplicate (same content within [dedupWindow]). Exposed for
  /// tests.
  void handleSharedPayload(SharedPayload payload) {
    if (payload.isEmpty || _isDuplicate(payload)) return;
    final onPayload = _onPayload;
    if (onPayload != null) {
      onPayload(payload);
    } else {
      _pendingPayloads.add(payload);
    }
  }

  bool _isDuplicate(SharedPayload payload) {
    final now = DateTime.now();
    _recentSignatures.removeWhere(
        (_, seenAt) => now.difference(seenAt) > dedupWindow);
    final signature = payload.signature;
    if (_recentSignatures.containsKey(signature)) return true;
    _recentSignatures[signature] = now;
    return false;
  }

  /// Attaches the app-level handler that presents the downloader for every
  /// payload — queued ones are handed over immediately, later ones as
  /// they arrive. Passing null detaches it, so anything arriving afterwards
  /// queues again.
  void setOnSharedPayload(void Function(SharedPayload payload)? callback) {
    _onPayload = callback;
    if (callback == null || _pendingPayloads.isEmpty) return;
    final queued = List.of(_pendingPayloads);
    _pendingPayloads.clear();
    for (final payload in queued) {
      callback(payload);
    }
  }

  /// Tells the platform side to background the app (Android:
  /// `moveTaskToBack`), re-fronting whatever the share came from. Called
  /// once the downloader is done with a shared link. Best-effort:
  /// no-op off Android/web, where the channel has no implementation.
  Future<void> returnToPreviousApp() async {
    try {
      await _channel.invokeMethod<void>('returnToPreviousApp');
    } catch (_) {}
  }

  /// Clears all singleton state between tests.
  void resetForTest() {
    _onPayload = null;
    _pendingPayloads.clear();
    _recentSignatures.clear();
    _initialized = false;
    _channel.setMethodCallHandler(null);
    dedupWindow = const Duration(seconds: 5);
  }
}
