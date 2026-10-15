import 'package:best_music/services/mp3_download_manager.dart';
import 'package:best_music/ui/estimated_progress_bar.dart';
import 'package:best_music/ui/mp3_downloads_page.dart';
import 'package:best_music/ui/remaining_time_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 10, 15, 12);
  late DateTime now;
  DateTime clock() => now;

  setUp(() => now = t0);

  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  Finder remaining() => find.byKey(const ValueKey('remainingTime'));

  testWidgets('a long job shows hh:mm:ss remaining after 3 s, refreshed',
      (tester) async {
    var done = 0.0;
    late StateSetter set;
    await tester.pumpWidget(host(StatefulBuilder(builder: (context, setter) {
      set = setter;
      return RemainingTimeText(done: done, clock: clock);
    })));
    expect(remaining(), findsNothing);

    // 2 s in, 2% done: too early for an estimate.
    now = t0.add(const Duration(seconds: 2));
    set(() => done = 0.02);
    await tester.pump();
    expect(remaining(), findsNothing);

    // 10 s in, 10% done: ~90 s to go, the whole job ~100 s.
    now = t0.add(const Duration(seconds: 10));
    set(() => done = 0.1);
    await tester.pump();
    expect(find.text('00:01:30 remaining'), findsOneWidget);

    // The once-a-second tick counts on without a progress change.
    now = t0.add(const Duration(seconds: 20));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('00:03:00 remaining'), findsOneWidget);
  });

  testWidgets('a job that looks shorter than 30 s shows nothing',
      (tester) async {
    now = t0.add(const Duration(seconds: 5));
    await tester.pumpWidget(host(RemainingTimeText(
      done: 0.5,
      startedAt: t0,
      clock: clock,
    )));
    expect(remaining(), findsNothing);
  });

  testWidgets('startedAt counts from when the work began', (tester) async {
    now = t0.add(const Duration(seconds: 60));
    await tester.pumpWidget(host(RemainingTimeText(
      done: 0.5,
      startedAt: t0,
      clock: clock,
    )));
    expect(find.text('00:01:00 remaining'), findsOneWidget);
  });

  testWidgets('without progress, typical counts down; gone when over',
      (tester) async {
    late StateSetter set;
    var active = true;
    await tester.pumpWidget(host(StatefulBuilder(builder: (context, setter) {
      set = setter;
      return RemainingTimeText(
        active: active,
        typical: const Duration(minutes: 2),
        clock: clock,
      );
    })));
    now = t0.add(const Duration(seconds: 30));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('00:01:30 remaining'), findsOneWidget);

    now = t0.add(const Duration(minutes: 3));
    await tester.pump(const Duration(seconds: 1));
    expect(remaining(), findsNothing, reason: 'no 00:00:00 while still busy');

    set(() => active = false);
    await tester.pump();
    expect(remaining(), findsNothing);
  });

  testWidgets('nothing to go on: no line', (tester) async {
    now = t0.add(const Duration(minutes: 5));
    await tester.pumpWidget(
        host(RemainingTimeText(startedAt: t0, clock: clock)));
    expect(remaining(), findsNothing);
  });

  testWidgets('EstimatedProgressBar shows the line only with showRemaining',
      (tester) async {
    final started = DateTime.now().subtract(const Duration(seconds: 60));
    await tester.pumpWidget(host(Column(children: [
      EstimatedProgressBar(active: true, value: 0.5, startedAt: started),
    ])));
    expect(remaining(), findsNothing);
    await tester.pumpWidget(host(Column(children: [
      EstimatedProgressBar(
          active: true, value: 0.5, startedAt: started, showRemaining: true),
    ])));
    expect(remaining(), findsOneWidget);
    expect(find.textContaining(RegExp(r'^00:0[01]:\d\d remaining$')),
        findsOneWidget);
  });

  testWidgets('an MP3 download shows the time left below its progress',
      (tester) async {
    final manager = Mp3DownloadManager.instance;
    addTearDown(manager.resetForTest);
    manager.jobs.value = [
      Mp3DownloadJob(
        id: 'big',
        videoId: 'v',
        title: 'Long mix',
        channel: '',
        destinationDir: '/m',
        status: Mp3DownloadStatus.running,
        receivedBytes: 25,
        totalBytes: 100,
      )..startedAt = DateTime.now().subtract(const Duration(seconds: 40)),
    ];
    await tester.pumpWidget(MaterialApp(home: Mp3DownloadsPage(manager: manager)));
    await tester.pump();
    // 40 s for 25% → about 2 minutes to go.
    expect(find.textContaining(RegExp(r'^00:0[12]:\d\d remaining$')),
        findsOneWidget);
  });
}
