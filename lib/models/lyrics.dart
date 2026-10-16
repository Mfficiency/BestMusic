/// One timed line of synced lyrics: [text] starts being sung at [time].
class LyricLine {
  const LyricLine(this.time, this.text);

  final Duration time;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is LyricLine && other.time == time && other.text == text;

  @override
  int get hashCode => Object.hash(time, text);

  @override
  String toString() => 'LyricLine($time, $text)';
}

/// A song's lyrics: timed [lines] when they're synced (LRC), otherwise just
/// [plain] text, or nothing at all for an [instrumental]. [source] says
/// where they came from, for the line under the lyrics ("LRCLIB", "the
/// song's .lrc file", "the song's tags").
class Lyrics {
  const Lyrics({
    this.lines = const [],
    this.plain = '',
    this.instrumental = false,
    this.source = '',
  });

  final List<LyricLine> lines;
  final String plain;
  final bool instrumental;
  final String source;

  bool get isSynced => lines.isNotEmpty;

  bool get isEmpty => !instrumental && lines.isEmpty && plain.trim().isEmpty;

  /// The line being sung at [position]: the last one that has started, or
  /// -1 before the first.
  int indexAt(Duration position) {
    var lo = 0, hi = lines.length - 1, found = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].time <= position) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return found;
  }

  /// How far through line [index] the singing is at [position], 0..1 — what
  /// the highlight sweeps across. LRC only says when a line starts, so this
  /// guesses how long it is sung for: about [perChar] per character, at
  /// least [minLength], never past the next line's start (an instrumental
  /// gap after a line doesn't stretch it out).
  double progressAt(
    int index,
    Duration position, {
    Duration perChar = const Duration(milliseconds: 70),
    Duration minLength = const Duration(milliseconds: 1500),
  }) {
    if (index < 0 || index >= lines.length) return 0;
    final line = lines[index];
    var length = perChar * line.text.length;
    if (length < minLength) length = minLength;
    if (index + 1 < lines.length) {
      final gap = lines[index + 1].time - line.time;
      if (gap < length) length = gap;
    }
    if (length <= Duration.zero) return 1;
    final done = (position - line.time).inMilliseconds / length.inMilliseconds;
    return done.clamp(0.0, 1.0).toDouble();
  }

  Lyrics copyWith({String? source}) => Lyrics(
        lines: lines,
        plain: plain,
        instrumental: instrumental,
        source: source ?? this.source,
      );

  Map<String, dynamic> toJson() => {
        if (lines.isNotEmpty)
          'lines': [
            for (final l in lines) [l.time.inMilliseconds, l.text]
          ],
        if (plain.isNotEmpty) 'plain': plain,
        if (instrumental) 'instrumental': true,
        if (source.isNotEmpty) 'source': source,
      };

  static Lyrics fromJson(Map<String, dynamic> json) {
    final lines = <LyricLine>[];
    final raw = json['lines'];
    if (raw is List) {
      for (final l in raw) {
        if (l is List && l.length == 2 && l[0] is num && l[1] is String) {
          lines.add(LyricLine(
              Duration(milliseconds: (l[0] as num).round()), l[1] as String));
        }
      }
    }
    return Lyrics(
      lines: lines,
      plain: json['plain'] as String? ?? '',
      instrumental: json['instrumental'] as bool? ?? false,
      source: json['source'] as String? ?? '',
    );
  }

  /// Reads LRC text (what `.lrc` files, LRCLIB's `syncedLyrics` and many
  /// lyrics tags hold):
  ///
  /// ```text
  /// [ar:Artist]
  /// [offset:+250]
  /// [00:12.30]First line
  /// [00:15.80][01:02.00]A line sung twice
  /// [00:19.10]<00:19.10>Word <00:19.60>by <00:19.90>word
  /// ```
  ///
  /// Timestamps may be `mm:ss`, `mm:ss.x`, `mm:ss.xx`, `mm:ss.xxx` or
  /// `mm:ss:xx`; word timestamps (`<mm:ss.xx>`) are dropped; `[offset:]`
  /// (milliseconds, positive = lyrics come earlier) is applied; other
  /// `[tag:value]` lines are skipped. Text without any timestamps comes
  /// back as [plain] lyrics. The plain text of synced lyrics is kept too.
  static Lyrics parseLrc(String text, {String source = ''}) {
    final timed = <LyricLine>[];
    final plainLines = <String>[];
    var offsetMs = 0;
    final stamp = RegExp(r'^\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
    final tag = RegExp(r'^\[([a-zA-Z#]+):(.*)\]\s*$');
    final word = RegExp(r'<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>');
    for (final rawLine in text.replaceAll('\r\n', '\n').split('\n')) {
      var line = rawLine.trim();
      final tagMatch = tag.firstMatch(line);
      if (tagMatch != null && !stamp.hasMatch(line)) {
        if (tagMatch.group(1)!.toLowerCase() == 'offset') {
          offsetMs = int.tryParse(tagMatch.group(2)!.trim().replaceAll('+', '')) ??
              offsetMs;
        }
        continue;
      }
      final times = <Duration>[];
      for (var m = stamp.firstMatch(line); m != null; m = stamp.firstMatch(line)) {
        final minutes = int.parse(m.group(1)!);
        final seconds = int.parse(m.group(2)!);
        final frac = m.group(3);
        // ".5" is half a second, ".05" five hundredths, ".005" five ms.
        final ms = frac == null
            ? 0
            : (int.parse(frac) * const [1, 100, 10, 1][frac.length]);
        times.add(Duration(minutes: minutes, seconds: seconds, milliseconds: ms));
        line = line.substring(m.end).trimLeft();
      }
      line = line.replaceAll(word, '').replaceAll(RegExp(r'\s+'), ' ').trim();
      if (times.isEmpty) {
        plainLines.add(line);
        continue;
      }
      for (final t in times) {
        var at = t - Duration(milliseconds: offsetMs);
        if (at < Duration.zero) at = Duration.zero;
        timed.add(LyricLine(at, line));
      }
    }
    if (timed.isEmpty) {
      return Lyrics(plain: _trimBlankEnds(plainLines).join('\n'), source: source);
    }
    // Stable: lines with the same time keep their file order.
    final indexed = timed.indexed.toList()
      ..sort((a, b) {
        final c = a.$2.time.compareTo(b.$2.time);
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    final sorted = [for (final e in indexed) e.$2];
    // A trailing empty line only marks where singing stops; leading empty
    // lines are noise. Empty lines in between stay (they end a line early,
    // so the highlight doesn't hang over an instrumental break).
    while (sorted.isNotEmpty && sorted.first.text.isEmpty) {
      sorted.removeAt(0);
    }
    return Lyrics(
      lines: sorted,
      plain: _trimBlankEnds([for (final l in sorted) l.text]).join('\n'),
      source: source,
    );
  }

  static List<String> _trimBlankEnds(List<String> lines) {
    var start = 0, end = lines.length;
    while (start < end && lines[start].trim().isEmpty) {
      start++;
    }
    while (end > start && lines[end - 1].trim().isEmpty) {
      end--;
    }
    return lines.sublist(start, end);
  }
}
