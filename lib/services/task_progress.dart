import 'package:flutter/foundation.dart';

/// How far a long piece of work is: [done] (0..1) since [startedAt]. What a
/// `RemainingTimeText` turns into "hh:mm:ss remaining".
class TaskProgress {
  const TaskProgress({required this.startedAt, required this.done});

  final DateTime startedAt;
  final double done;
}

/// Publishes a [TaskProgress] into [out] as the work goes, at most once per
/// 0.1% (a byte counter calls [set] for every chunk); [end] clears it.
class TaskProgressTracker {
  TaskProgressTracker(this.out, {DateTime? startedAt})
      : startedAt = startedAt ?? DateTime.now() {
    out.value = TaskProgress(startedAt: this.startedAt, done: 0);
  }

  final ValueNotifier<TaskProgress?> out;
  final DateTime startedAt;
  int _permille = 0;

  void set(double done) {
    final d = done.isNaN ? 0.0 : done.clamp(0.0, 1.0);
    final permille = (d * 1000).floor();
    if (permille == _permille && out.value != null) return;
    _permille = permille;
    out.value = TaskProgress(startedAt: startedAt, done: d);
  }

  void end() => out.value = null;
}
