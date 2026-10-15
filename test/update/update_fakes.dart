/// Fakes for the updates package (`mfficiency_updates`) as Best Music uses
/// it: GitHub's releases list through [UpdateHttp.from], an
/// in-memory APK downloader, [MemoryUpdateStore] and the plugin's
/// `mfficiency_updates` method channel answered in Dart. Nothing touches
/// the network or the disk, so it all runs inside `testWidgets`.
library;

import 'dart:async';

import 'package:best_music/services/app_updates.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// One release of the app with [tag] as GitHub's releases list has it.
/// [body] is the release notes (a build footer such as
/// "- Built: 2026-10-15 14:02 in 3m 12s"); [size] the APK asset's bytes.
Map<String, Object?> release(String tag,
        {bool prerelease = false,
        bool draft = false,
        bool apk = true,
        String body = 'notes',
        int? size}) =>
    {
      'tag_name': tag,
      'name': tag,
      'draft': draft,
      'prerelease': prerelease,
      'html_url': 'https://github.com/Mfficiency/BestMusic/releases/tag/$tag',
      'body': body,
      'assets': [
        if (apk)
          {
            'name': '$tag.apk',
            if (size != null) 'size': size,
            'url': 'https://api.github.com/repos/Mfficiency/BestMusic/'
                'releases/assets/${tag.hashCode}',
            'browser_download_url':
                'https://github.com/Mfficiency/BestMusic/releases/download/'
                    '$tag/$tag.apk',
          },
      ],
    };

/// The releases list; [requests] records every URL asked for.
class FakeGithub {
  List<Map<String, Object?>> releases = [];

  /// Non-null: every request fails with this HTTP status.
  int? failStatus;
  final requests = <Uri>[];

  late final UpdateHttp http = UpdateHttp.from((url, headers, cacheFor) async {
    requests.add(url);
    final status = failStatus;
    if (status != null) throw UpdateHttpException(status);
    return releases;
  });
}

/// Downloads into memory, instantly unless [hold] is set.
class FakeDownloader extends ApkDownloader {
  final files = <String>{};
  final urls = <Uri>[];
  bool fail = false;

  /// While set, a download stops at 50 % until it is completed.
  Completer<void>? hold;

  @override
  Future<String?> download(
    Uri url,
    String fileName, {
    void Function(double? fraction)? onProgress,
  }) async {
    urls.add(url);
    await Future<void>.delayed(Duration.zero);
    onProgress?.call(0.5);
    await hold?.future;
    if (fail) return null;
    files
      ..clear()
      ..add('/cache/updates/$fileName');
    onProgress?.call(1);
    return '/cache/updates/$fileName';
  }

  @override
  bool exists(String path) => files.contains(path);

  @override
  Future<String?> downloaded(String fileName) async =>
      files.contains('/cache/updates/$fileName')
          ? '/cache/updates/$fileName'
          : null;

  @override
  Future<Uri?> signedAssetUrl(Uri assetApiUrl, String token) async => null;
}

/// The plugin's channel (`mfficiency_updates`), answered in Dart.
class FakeInstaller {
  FakeInstaller() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(UpdatePlatform.channelName),
      (call) async {
        calls.add(call);
        return switch (call.method) {
          'installApk' => installOutcome,
          'canInstallApks' => true,
          'installTime' => installTime?.millisecondsSinceEpoch,
          'openUrl' => true,
          _ => null,
        };
      },
    );
  }

  final calls = <MethodCall>[];
  String installOutcome = 'ok';
  DateTime? installTime;

  /// The APK paths handed to Android's installer, in order.
  List<String> get installs => [
        for (final c in calls)
          if (c.method == 'installApk') (c.arguments as Map)['path'] as String,
      ];

  void dispose() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel(UpdatePlatform.channelName), null);
}

/// A controller the way `AppUpdates.create` builds it
/// ([AppUpdates.controllerFor]), on the fakes; also set as the running
/// app's [AppUpdates.controller].
UpdateController fakeController({
  required FakeGithub github,
  required FakeDownloader downloader,
  UpdateStore? store,
  String version = '0.3.31',
  int build = 1000,
  DateTime Function()? clock,
}) {
  final c = AppUpdates.controllerFor(
    version: version,
    build: build,
    store: store ?? MemoryUpdateStore(),
    http: github.http,
    downloader: downloader,
    platform: UpdatePlatform(supported: true),
    clock: clock,
  );
  AppUpdates.controller = c;
  return c;
}
