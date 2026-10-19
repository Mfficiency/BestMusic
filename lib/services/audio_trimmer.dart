import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// Why a song couldn't be shortened; [message] is user-facing.
class AudioTrimException implements Exception {
  AudioTrimException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Shortens audio files by cutting them, without re-encoding — so no
/// quality is lost and no native encoder is needed (the app ships without
/// ffmpeg, see [Mp3DownloaderService]):
///
/// - **MP3**: whole MPEG frames inside the range are kept (precision: one
///   frame, ~26 ms). The ID3v2/ID3v1 tags stay; a Xing/Info (VBR) header
///   gets the new frame count, byte count and seek table, so duration and
///   seeking stay right.
/// - **M4A/MP4 (AAC)**: the audio samples inside the range are copied into
///   a new `mdat`, and the sample tables (`stts`/`stsz`/`stsc`/`stco`) and
///   durations are rebuilt; `udta` (the tags) is kept. Only the simple
///   layout (one audio track, not fragmented) is handled.
/// - **WAV**: the PCM data is cut on whole sample frames.
///
/// Anything else throws [AudioTrimException]. The input is never touched:
/// [trimFile] writes a new file.
class AudioTrimmer {
  const AudioTrimmer._();

  static const List<String> supportedExtensions = ['mp3', 'm4a', 'mp4', 'wav'];

  static String _ext(String path) {
    final dot = path.lastIndexOf('.');
    return dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  }

  static bool supports(String path) => supportedExtensions.contains(_ext(path));

  /// The audio's exact length, read from the file itself.
  static Future<Duration> durationOf(String path) async {
    final bytes = await File(path).readAsBytes();
    final ext = _ext(path);
    return Isolate.run(() => durationOfBytes(bytes, ext));
  }

  static Duration durationOfBytes(Uint8List bytes, String ext) {
    switch (ext) {
      case 'mp3':
        return _Mp3.parse(bytes).duration;
      case 'm4a':
      case 'mp4':
        return _Mp4.parse(bytes).duration;
      case 'wav':
        return _Wav.parse(bytes).duration;
    }
    throw AudioTrimException("Shortening .$ext files isn't supported yet");
  }

  /// Writes the part of [inPath] from [start] to [end] to [outPath] (same
  /// format). Returns the new length.
  static Future<Duration> trimFile(
      String inPath, String outPath, Duration start, Duration end) async {
    final bytes = await File(inPath).readAsBytes();
    final ext = _ext(inPath);
    final out = await Isolate.run(() => trimBytes(bytes, ext, start, end));
    await File(outPath).writeAsBytes(out, flush: true);
    return durationOfBytes(out, ext);
  }

  static Uint8List trimBytes(
      Uint8List bytes, String ext, Duration start, Duration end) {
    if (end <= start) {
      throw AudioTrimException('The end has to come after the start');
    }
    switch (ext) {
      case 'mp3':
        return _Mp3.parse(bytes).trim(start, end);
      case 'm4a':
      case 'mp4':
        return _Mp4.parse(bytes).trim(start, end);
      case 'wav':
        return _Wav.parse(bytes).trim(start, end);
    }
    throw AudioTrimException("Shortening .$ext files isn't supported yet");
  }
}

int _u32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
int _u64(Uint8List b, int o) => (_u32(b, o) << 32) | _u32(b, o + 4);
int _le16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
int _le32(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

void _put32(Uint8List b, int o, int v) {
  b[o] = (v >> 24) & 0xff;
  b[o + 1] = (v >> 16) & 0xff;
  b[o + 2] = (v >> 8) & 0xff;
  b[o + 3] = v & 0xff;
}

void _putLe32(Uint8List b, int o, int v) {
  b[o] = v & 0xff;
  b[o + 1] = (v >> 8) & 0xff;
  b[o + 2] = (v >> 16) & 0xff;
  b[o + 3] = (v >> 24) & 0xff;
}

Uint8List _be32(int v) {
  final b = Uint8List(4);
  _put32(b, 0, v);
  return b;
}

// ---------------------------------------------------------------------- MP3

class _Mp3Frame {
  _Mp3Frame(this.offset, this.length, this.samples, this.sampleRate);
  final int offset;
  final int length;
  final int samples;
  final int sampleRate;
}

class _Mp3 {
  _Mp3(this.bytes, this.audioStart, this.audioEnd, this.frames, this.xing);

  final Uint8List bytes;

  /// Where the frames start (after ID3v2) and end (before ID3v1).
  final int audioStart;
  final int audioEnd;
  final List<_Mp3Frame> frames;

  /// The Xing/Info/VBRI header frame, if the first frame is one (not audio).
  final _Mp3Frame? xing;

  static const _bitratesV1 = [
    [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],
    [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],
    [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
  ];
  static const _bitratesV2 = [
    [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],
    [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
    [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
  ];
  static const _sampleRates = [
    [11025, 12000, 8000], // MPEG 2.5
    [0, 0, 0],
    [22050, 24000, 16000], // MPEG 2
    [44100, 48000, 32000], // MPEG 1
  ];

  /// The frame starting at [o], or null if there's no valid header there.
  static _Mp3Frame? _frameAt(Uint8List b, int o, int end) {
    if (o + 4 > end) return null;
    if (b[o] != 0xff || (b[o + 1] & 0xe0) != 0xe0) return null;
    final version = (b[o + 1] >> 3) & 3; // 3 = MPEG1, 2 = MPEG2, 0 = 2.5
    final layer = (b[o + 1] >> 1) & 3; // 1 = III, 2 = II, 3 = I
    if (version == 1 || layer == 0) return null;
    final bitrateIndex = (b[o + 2] >> 4) & 0xf;
    final rateIndex = (b[o + 2] >> 2) & 3;
    if (bitrateIndex == 0 || bitrateIndex == 15 || rateIndex == 3) return null;
    final padding = (b[o + 2] >> 1) & 1;
    final layerRow = 3 - layer; // 0 = I, 1 = II, 2 = III
    final kbps = version == 3
        ? _bitratesV1[layerRow][bitrateIndex]
        : _bitratesV2[layerRow][bitrateIndex];
    final rate = _sampleRates[version][rateIndex];
    final bps = kbps * 1000;
    int length;
    int samples;
    if (layer == 3) {
      length = (12 * bps ~/ rate + padding) * 4;
      samples = 384;
    } else if (layer == 2 || version == 3) {
      length = 144 * bps ~/ rate + padding;
      samples = 1152;
    } else {
      length = 72 * bps ~/ rate + padding; // MPEG2/2.5 layer III
      samples = 576;
    }
    if (length < 4 || o + length > end) return null;
    return _Mp3Frame(o, length, samples, rate);
  }

  static _Mp3 parse(Uint8List b) {
    var start = 0;
    if (b.length >= 10 && b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33) {
      final size = ((b[6] & 0x7f) << 21) |
          ((b[7] & 0x7f) << 14) |
          ((b[8] & 0x7f) << 7) |
          (b[9] & 0x7f);
      start = 10 + size + ((b[5] & 0x10) != 0 ? 10 : 0);
    }
    var end = b.length;
    if (end - start >= 128 &&
        b[end - 128] == 0x54 &&
        b[end - 127] == 0x41 &&
        b[end - 126] == 0x47) {
      end -= 128; // ID3v1 "TAG"
    }
    final frames = <_Mp3Frame>[];
    var o = start;
    while (o < end) {
      final f = _frameAt(b, o, end);
      // A real frame is followed by another one (or the end): that check
      // keeps a stray 0xFF in junk from being taken for a header.
      if (f != null &&
          (f.offset + f.length >= end - 3 ||
              _frameAt(b, f.offset + f.length, end) != null)) {
        frames.add(f);
        o += f.length;
      } else {
        o++;
      }
    }
    if (frames.isEmpty) throw AudioTrimException('No MP3 audio found');
    _Mp3Frame? xing;
    final first = frames.first;
    final head = String.fromCharCodes(
        b.sublist(first.offset, first.offset + first.length.clamp(0, 64)));
    if (head.contains('Xing') ||
        head.contains('Info') ||
        head.contains('VBRI')) {
      xing = frames.removeAt(0);
    }
    if (frames.isEmpty) throw AudioTrimException('No MP3 audio found');
    return _Mp3(b, start, end, frames, xing);
  }

  Duration get duration {
    var us = 0.0;
    for (final f in frames) {
      us += f.samples * 1e6 / f.sampleRate;
    }
    return Duration(microseconds: us.round());
  }

  Uint8List trim(Duration from, Duration to) {
    final kept = <_Mp3Frame>[];
    var t = 0.0;
    for (final f in frames) {
      final len = f.samples * 1e6 / f.sampleRate;
      if (t + len / 2 >= from.inMicroseconds && t < to.inMicroseconds) {
        kept.add(f);
      }
      t += len;
    }
    if (kept.isEmpty) throw AudioTrimException('Nothing left to keep');
    final out = BytesBuilder(copy: false);
    out.add(Uint8List.sublistView(bytes, 0, audioStart)); // ID3v2
    final x = xing;
    if (x != null) out.add(_rewriteXing(x, kept));
    for (final f in kept) {
      out.add(Uint8List.sublistView(bytes, f.offset, f.offset + f.length));
    }
    out.add(Uint8List.sublistView(bytes, audioEnd)); // ID3v1
    return out.takeBytes();
  }

  /// The VBR header frame with the new frame/byte counts and seek table.
  Uint8List _rewriteXing(_Mp3Frame x, List<_Mp3Frame> kept) {
    final frame =
        Uint8List.fromList(bytes.sublist(x.offset, x.offset + x.length));
    final text = String.fromCharCodes(frame);
    var at = text.indexOf('Xing');
    if (at < 0) at = text.indexOf('Info');
    if (at < 0) return frame; // VBRI: rarely used; left as it is
    final flags = _u32(frame, at + 4);
    var p = at + 8;
    final audioBytes =
        kept.fold<int>(0, (sum, f) => sum + f.length) + frame.length;
    if (flags & 1 != 0) {
      _put32(frame, p, kept.length);
      p += 4;
    }
    if (flags & 2 != 0) {
      _put32(frame, p, audioBytes);
      p += 4;
    }
    if (flags & 4 != 0) {
      // toc[i]: where (in 1/256 of the file) i% of the duration starts.
      final starts = <double>[];
      var t = 0.0;
      for (final f in kept) {
        starts.add(t);
        t += f.samples / f.sampleRate;
      }
      var fi = 0;
      var byteAt = frame.length;
      for (var i = 0; i < 100; i++) {
        final target = t * i / 100;
        while (fi < kept.length - 1 && starts[fi + 1] <= target) {
          byteAt += kept[fi].length;
          fi++;
        }
        frame[p + i] = (byteAt * 256 ~/ audioBytes).clamp(0, 255);
      }
      p += 100;
    }
    if (flags & 8 != 0) p += 4;
    // The LAME/Lavc tag after it holds the original's encoder delay and
    // padding (and a CRC): no longer true for the cut, so it's blanked.
    if (p + 4 <= frame.length) {
      final tag = String.fromCharCodes(frame.sublist(p, p + 4));
      if (tag == 'LAME' || tag == 'Lavf' || tag == 'Lavc' || tag == 'L3.9') {
        for (var i = p; i < frame.length; i++) {
          frame[i] = 0;
        }
      }
    }
    return frame;
  }
}

// ---------------------------------------------------------------------- MP4

class _Box {
  _Box(this.type, this.start, this.headerSize, this.size);
  final String type;
  final int start;
  final int headerSize;
  final int size;
  int get bodyStart => start + headerSize;
  int get end => start + size;
}

List<_Box> _boxes(Uint8List b, int from, int to) {
  final out = <_Box>[];
  var o = from;
  while (o + 8 <= to) {
    var size = _u32(b, o);
    final type = String.fromCharCodes(b.sublist(o + 4, o + 8));
    var header = 8;
    if (size == 1) {
      if (o + 16 > to) break;
      size = _u64(b, o + 8);
      header = 16;
    } else if (size == 0) {
      size = to - o;
    }
    if (size < header || o + size > to) {
      throw AudioTrimException('This M4A file looks damaged');
    }
    out.add(_Box(type, o, header, size));
    o += size;
  }
  return out;
}

_Box? _child(Uint8List b, _Box parent, String type, {int skip = 0}) {
  for (final c in _boxes(b, parent.bodyStart + skip, parent.end)) {
    if (c.type == type) return c;
  }
  return null;
}

Uint8List _box(String type, List<Uint8List> body) {
  final size = 8 + body.fold<int>(0, (s, p) => s + p.length);
  final out = BytesBuilder(copy: false);
  out.add(_be32(size));
  out.add(Uint8List.fromList(type.codeUnits));
  for (final p in body) {
    out.add(p);
  }
  return out.takeBytes();
}

class _Mp4 {
  _Mp4(this.b, this.ftyp, this.moov, this.trak, this.stbl, this.timescale,
      this.durations, this.sizes, this.offsets);

  final Uint8List b;
  final _Box? ftyp;
  final _Box moov;
  final _Box trak;
  final _Box stbl;
  final int timescale;
  final List<int> durations;
  final List<int> sizes;
  final List<int> offsets;

  static _Mp4 parse(Uint8List b) {
    final top = _boxes(b, 0, b.length);
    if (top.any((x) => x.type == 'moof')) {
      throw AudioTrimException("Fragmented M4A files can't be shortened yet");
    }
    final ftyp = top.where((x) => x.type == 'ftyp').firstOrNull;
    final moov = top.where((x) => x.type == 'moov').firstOrNull;
    if (moov == null) throw AudioTrimException('This M4A file has no index');
    final traks = _boxes(b, moov.bodyStart, moov.end)
        .where((x) => x.type == 'trak')
        .toList();
    if (traks.length != 1) {
      throw AudioTrimException(
          'Only M4A files with a single audio track can be shortened');
    }
    final trak = traks.single;
    final mdia = _child(b, trak, 'mdia');
    final mdhd = mdia == null ? null : _child(b, mdia, 'mdhd');
    final minf = mdia == null ? null : _child(b, mdia, 'minf');
    final stbl = minf == null ? null : _child(b, minf, 'stbl');
    if (mdhd == null || stbl == null) {
      throw AudioTrimException('This M4A file looks damaged');
    }
    final v = b[mdhd.bodyStart];
    final timescale = _u32(b, mdhd.bodyStart + (v == 1 ? 20 : 12));
    final stts = _child(b, stbl, 'stts');
    final stsz = _child(b, stbl, 'stsz');
    final stsc = _child(b, stbl, 'stsc');
    final stco = _child(b, stbl, 'stco') ?? _child(b, stbl, 'co64');
    if (stts == null || stsz == null || stsc == null || stco == null) {
      throw AudioTrimException('This M4A file looks damaged');
    }
    // Sample durations.
    final durations = <int>[];
    var p = stts.bodyStart + 4;
    final sttsCount = _u32(b, p);
    p += 4;
    for (var i = 0; i < sttsCount; i++) {
      final n = _u32(b, p);
      final d = _u32(b, p + 4);
      for (var k = 0; k < n; k++) {
        durations.add(d);
      }
      p += 8;
    }
    // Sample sizes.
    final uniform = _u32(b, stsz.bodyStart + 4);
    final count = _u32(b, stsz.bodyStart + 8);
    final sizes = [
      for (var i = 0; i < count; i++)
        uniform != 0 ? uniform : _u32(b, stsz.bodyStart + 12 + i * 4),
    ];
    // Chunk offsets.
    final wide = stco.type == 'co64';
    final chunkCount = _u32(b, stco.bodyStart + 4);
    final chunkOffsets = [
      for (var i = 0; i < chunkCount; i++)
        wide
            ? _u64(b, stco.bodyStart + 8 + i * 8)
            : _u32(b, stco.bodyStart + 8 + i * 4),
    ];
    // Samples per chunk, then each sample's offset.
    final runs = _u32(b, stsc.bodyStart + 4);
    final firstChunks = <int>[];
    final perChunk = <int>[];
    for (var i = 0; i < runs; i++) {
      firstChunks.add(_u32(b, stsc.bodyStart + 8 + i * 12));
      perChunk.add(_u32(b, stsc.bodyStart + 12 + i * 12));
    }
    final offsets = <int>[];
    var sample = 0;
    var run = 0;
    for (var c = 0; c < chunkCount && sample < count; c++) {
      while (run + 1 < runs && firstChunks[run + 1] <= c + 1) {
        run++;
      }
      var o = chunkOffsets[c];
      for (var k = 0; k < perChunk[run] && sample < count; k++) {
        offsets.add(o);
        o += sizes[sample];
        sample++;
      }
    }
    if (durations.length < count || offsets.length < count) {
      throw AudioTrimException('This M4A file looks damaged');
    }
    for (var i = 0; i < count; i++) {
      if (offsets[i] + sizes[i] > b.length) {
        throw AudioTrimException('This M4A file looks damaged');
      }
    }
    return _Mp4(b, ftyp, moov, trak, stbl, timescale,
        durations.sublist(0, count), sizes, offsets);
  }

  Duration get duration => Duration(
      microseconds:
          durations.fold<int>(0, (s, d) => s + d) * 1000000 ~/ timescale);

  Uint8List trim(Duration from, Duration to) {
    final startTs = from.inMicroseconds * timescale ~/ 1000000;
    final endTs = to.inMicroseconds * timescale ~/ 1000000;
    final keep = <int>[];
    var t = 0;
    for (var i = 0; i < durations.length; i++) {
      if (t + durations[i] ~/ 2 >= startTs && t < endTs) keep.add(i);
      t += durations[i];
    }
    if (keep.isEmpty) throw AudioTrimException('Nothing left to keep');
    final keptDurations = [for (final i in keep) durations[i]];
    final newDuration = keptDurations.fold<int>(0, (s, d) => s + d);

    Uint8List buildMoov(int mdatDataOffset) =>
        _rebuild(moov, keep, keptDurations, newDuration, mdatDataOffset);

    final ftypBytes = ftyp == null
        ? Uint8List(0)
        : Uint8List.sublistView(b, ftyp!.start, ftyp!.end);
    // The moov's size doesn't depend on the offset value: build it once to
    // learn where the audio will start, then again with that offset.
    final probe = buildMoov(0);
    final dataOffset = ftypBytes.length + probe.length + 8;
    final moovBytes = buildMoov(dataOffset);
    final payloadSize = keep.fold<int>(0, (s, i) => s + sizes[i]);
    final out = BytesBuilder(copy: false);
    out.add(ftypBytes);
    out.add(moovBytes);
    out.add(_be32(8 + payloadSize));
    out.add(Uint8List.fromList('mdat'.codeUnits));
    for (final i in keep) {
      out.add(Uint8List.sublistView(b, offsets[i], offsets[i] + sizes[i]));
    }
    return out.takeBytes();
  }

  /// [box] rebuilt for the kept samples: containers recurse, the sample
  /// tables and durations are replaced, `edts` and sample groups dropped,
  /// everything else copied.
  Uint8List _rebuild(_Box box, List<int> keep, List<int> keptDurations,
      int newDuration, int dataOffset) {
    const containers = {'moov', 'trak', 'mdia', 'minf'};
    if (box.type == 'stbl') {
      return _box('stbl', [
        for (final c in _boxes(b, box.bodyStart, box.end))
          if (c.type == 'stsd') Uint8List.sublistView(b, c.start, c.end),
        _stts(keptDurations),
        _stsc(keep.length),
        _stsz(keep),
        _box('stco', [_be32(0), _be32(1), _be32(dataOffset)]),
      ]);
    }
    if (containers.contains(box.type)) {
      return _box(box.type, [
        for (final c in _boxes(b, box.bodyStart, box.end))
          if (c.type != 'edts')
            _rebuild(c, keep, keptDurations, newDuration, dataOffset),
      ]);
    }
    final copy = Uint8List.fromList(b.sublist(box.start, box.end));
    final body = box.headerSize;
    final v = copy[body];
    if (box.type == 'mdhd') {
      _putDuration(copy, body + (v == 1 ? 24 : 16), v == 1, newDuration);
    } else if (box.type == 'mvhd' || box.type == 'tkhd') {
      final movieScale = _movieTimescale();
      final d = newDuration * movieScale ~/ timescale;
      final at = box.type == 'mvhd'
          ? body + (v == 1 ? 24 : 16)
          : body + (v == 1 ? 28 : 20);
      _putDuration(copy, at, v == 1, d);
    }
    return copy;
  }

  int _movieTimescale() {
    final mvhd = _child(b, moov, 'mvhd');
    if (mvhd == null) return timescale;
    final v = b[mvhd.bodyStart];
    return _u32(b, mvhd.bodyStart + (v == 1 ? 20 : 12));
  }

  static void _putDuration(Uint8List b, int at, bool wide, int value) {
    if (wide) {
      _put32(b, at, value >> 32);
      _put32(b, at + 4, value & 0xffffffff);
    } else {
      _put32(b, at, value & 0xffffffff);
    }
  }

  Uint8List _stts(List<int> d) {
    final entries = <List<int>>[];
    for (final x in d) {
      if (entries.isNotEmpty && entries.last[1] == x) {
        entries.last[0]++;
      } else {
        entries.add([1, x]);
      }
    }
    return _box('stts', [
      _be32(0),
      _be32(entries.length),
      for (final e in entries) ...[_be32(e[0]), _be32(e[1])],
    ]);
  }

  Uint8List _stsc(int samples) {
    // One chunk holding every sample, sample description 1.
    return _box(
        'stsc', [_be32(0), _be32(1), _be32(1), _be32(samples), _be32(1)]);
  }

  Uint8List _stsz(List<int> keep) => _box('stsz', [
        _be32(0),
        _be32(0),
        _be32(keep.length),
        for (final i in keep) _be32(sizes[i]),
      ]);
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

// ---------------------------------------------------------------------- WAV

class _Wav {
  _Wav(this.b, this.fmt, this.dataStart, this.dataSize, this.blockAlign,
      this.byteRate);

  final Uint8List b;
  final Uint8List fmt; // the whole fmt chunk
  final int dataStart;
  final int dataSize;
  final int blockAlign;
  final int byteRate;

  static _Wav parse(Uint8List b) {
    if (b.length < 12 ||
        String.fromCharCodes(b.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(b.sublist(8, 12)) != 'WAVE') {
      throw AudioTrimException('This WAV file looks damaged');
    }
    Uint8List? fmt;
    var o = 12;
    while (o + 8 <= b.length) {
      final id = String.fromCharCodes(b.sublist(o, o + 4));
      final size = _le32(b, o + 4);
      if (id == 'fmt ') {
        fmt = Uint8List.fromList(b.sublist(o, o + 8 + size));
      } else if (id == 'data' && fmt != null) {
        final dataSize = (o + 8 + size > b.length) ? b.length - o - 8 : size;
        final blockAlign = _le16(fmt, 8 + 12);
        final byteRate = _le32(fmt, 8 + 8);
        if (blockAlign == 0 || byteRate == 0) break;
        return _Wav(b, fmt, o + 8, dataSize, blockAlign, byteRate);
      }
      o += 8 + size + (size & 1);
    }
    throw AudioTrimException('This WAV file looks damaged');
  }

  Duration get duration =>
      Duration(microseconds: dataSize * 1000000 ~/ byteRate);

  Uint8List trim(Duration from, Duration to) {
    int at(Duration d) {
      final raw = d.inMicroseconds * byteRate ~/ 1000000;
      return (raw ~/ blockAlign * blockAlign).clamp(0, dataSize);
    }

    final s = at(from);
    final e = at(to);
    if (e <= s) throw AudioTrimException('Nothing left to keep');
    final size = e - s;
    final out = Uint8List(12 + fmt.length + 8 + size + (size & 1));
    out.setRange(0, 4, 'RIFF'.codeUnits);
    _putLe32(out, 4, out.length - 8);
    out.setRange(8, 12, 'WAVE'.codeUnits);
    out.setRange(12, 12 + fmt.length, fmt);
    var o = 12 + fmt.length;
    out.setRange(o, o + 4, 'data'.codeUnits);
    _putLe32(out, o + 4, size);
    o += 8;
    out.setRange(o, o + size, b, dataStart + s);
    return out;
  }
}
