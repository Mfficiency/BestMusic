import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import '../config.dart';

/// What the MP3 Downloader's "Top songs from the charts" asks for.
class ChartQuery {
  const ChartQuery({
    required this.year,
    required this.country,
    this.style = defaultStyle,
    this.count = 10,
  });

  final int year;
  final String country;
  final String style;
  final int count;

  static const String defaultStyle = 'Pop';
  static const String allStyles = 'All styles';

  static const List<String> styles = [
    'Pop',
    allStyles,
    'Dance / Electronic',
    'Hip-hop / Rap',
    'Rock',
    'R&B / Soul',
    'Latin',
    'Country',
    'Metal',
    'Jazz',
    'Classical',
  ];

  static const List<String> countries = [
    'Belgium',
    'Netherlands',
    'France',
    'Germany',
    'United Kingdom',
    'United States',
    'Spain',
    'Italy',
    'Sweden',
    'Canada',
    'Australia',
    'Brazil',
    'Japan',
    'Worldwide',
  ];

  static const List<int> counts = [5, 10, 20, 25, 40, 50, 100];

  /// "Top 10 Pop · Belgium · 2026".
  String get title =>
      'Top $count${style == allStyles ? '' : ' $style'} · $country · $year';

  /// The request Claude answers (with web search).
  String prompt({DateTime? now}) {
    final thisYear = (now ?? DateTime.now()).year;
    final which = style == allStyles ? 'songs' : '$style songs';
    final where = country == 'Worldwide' ? 'worldwide' : 'in $country';
    return [
      'The top $count $which of $year $where, in chart order.',
      if (year >= thisYear)
        'The year is not over yet: use the year-to-date ranking if there is '
            'one, otherwise the songs that charted highest and longest so far '
            'this year.'
      else
        "Use that year's official year-end singles chart.",
      if (country == 'Belgium')
        'For Belgium use the Ultratop (Flanders) charts.',
      if (country == 'Worldwide')
        'Worldwide: use global charts such as Billboard Global 200 or the '
            "year's most streamed songs.",
      if (style != allStyles)
        'Only $style: use a $style chart for that country and year if one '
            'exists, otherwise keep the $style songs from the main chart.',
    ].join(' ');
  }
}

/// One song of a chart.
class ChartSong {
  const ChartSong({required this.artist, required this.title, this.note = ''});

  final String artist;
  final String title;

  /// Chart position or other short context.
  final String note;

  /// What to search YouTube for.
  String get searchQuery => artist.isEmpty ? title : '$artist - $title';
}

class ChartLookupResult {
  const ChartLookupResult({required this.songs, this.summary = ''});

  final List<ChartSong> songs;

  /// Where the list comes from, in one sentence.
  final String summary;
}

/// User-facing failure of a chart lookup.
class ChartLookupException implements Exception {
  ChartLookupException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Looks up a chart ([ChartQuery]) with Claude and web search, so the list
/// comes from real charts (year-end charts, genre charts) rather than from
/// memory. Uses the Claude API key from Settings → Transcripts & summaries.
/// The answer arrives through a strict `submit_songs` tool.
class ChartLookupService {
  ChartLookupService._();

  static final ChartLookupService instance = ChartLookupService._();

  static const model = 'claude-opus-5-5';
  static final _endpoint = Uri.parse('https://api.anthropic.com/v1/messages');

  /// Tests stand in for the network here.
  @visibleForTesting
  http.Client? client;

  bool get hasApiKey => Config.claudeApiKey.trim().isNotEmpty;

  static const Map<String, Object> songsTool = {
    'name': 'submit_songs',
    'description': 'Hand over the final list of songs, in chart order.',
    'strict': true,
    'input_schema': {
      'type': 'object',
      'properties': {
        'songs': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'artist': {
                'type': 'string',
                'description': 'Main artist as credited',
              },
              'title': {
                'type': 'string',
                'description': 'Song title, without (Official Video) etc.',
              },
              'note': {
                'type': 'string',
                'description': 'Chart position or short context',
              },
            },
            'required': ['artist', 'title', 'note'],
            'additionalProperties': false,
          },
        },
        'summary': {
          'type': 'string',
          'description': 'One sentence on which chart the list comes from',
        },
      },
      'required': ['songs', 'summary'],
      'additionalProperties': false,
    },
  };

  static const String system =
      'You build song lists for a personal music library from music charts. '
      'Look the chart up with web search and prefer official chart sources '
      '(Ultratop for Belgium, the Official Charts Company for the UK, '
      'Billboard for the US, and so on). Then call submit_songs once with '
      'the songs in chart order, artist and title as credited, without video '
      'annotations. Give exactly as many songs as asked when that many exist.';

  Future<ChartLookupResult> lookup(ChartQuery query) async {
    final key = Config.claudeApiKey.trim();
    if (key.isEmpty) {
      throw ChartLookupException('Charts need a Claude API key: Settings → '
          'Transcripts & summaries → Claude API key');
    }
    final http.Client httpClient = client ?? http.Client();
    try {
      final first = {'role': 'user', 'content': query.prompt()};
      var messages = <Map<String, Object?>>[first];
      // pause_turn: the server-side search loop paused; send the turn back
      // so it carries on.
      for (var round = 0; round < 6; round++) {
        final reply = await _post(httpClient, key, messages);
        if (reply['stop_reason'] == 'refusal') {
          throw ChartLookupException('Claude declined this request');
        }
        final content = (reply['content'] as List?) ?? const [];
        for (final block in content) {
          if (block is Map &&
              block['type'] == 'tool_use' &&
              block['name'] == 'submit_songs') {
            return parseSubmittedSongs(block['input']);
          }
        }
        if (reply['stop_reason'] == 'pause_turn') {
          messages = [
            first,
            {'role': 'assistant', 'content': content}
          ];
          continue;
        }
        // Answered in text instead of with the tool: ask once more.
        messages = [
          first,
          {'role': 'assistant', 'content': content},
          {
            'role': 'user',
            'content': 'Please hand over the list with submit_songs.'
          },
        ];
      }
      throw ChartLookupException("Claude didn't come back with a list");
    } finally {
      if (client == null) httpClient.close();
    }
  }

  Future<Map<String, Object?>> _post(http.Client httpClient, String key,
      List<Map<String, Object?>> messages) async {
    final body = {
      'model': model,
      'max_tokens': 16000,
      // Re-run on Anthropic's recommended model if the request is declined.
      'fallbacks': 'default',
      'output_config': {'effort': 'medium'},
      'system': system,
      'tools': [
        {'type': 'web_search_20260209', 'name': 'web_search', 'max_uses': 6},
        songsTool,
      ],
      'messages': messages,
    };
    final http.Response response;
    try {
      response = await httpClient
          .post(
            _endpoint,
            headers: {
              'content-type': 'application/json',
              'x-api-key': key,
              'anthropic-version': '2023-06-01',
              'anthropic-beta': 'server-side-fallback-2026-07-01',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(minutes: 4));
    } catch (e) {
      throw ChartLookupException("Couldn't reach Claude: $e");
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {}
    if (response.statusCode != 200) {
      final error = decoded is Map ? decoded['error'] : null;
      final message = error is Map ? error['message'] : null;
      throw ChartLookupException('Claude API error ${response.statusCode}'
          '${message != null ? ': $message' : ''}');
    }
    if (decoded is! Map) {
      throw ChartLookupException('Unexpected reply from Claude');
    }
    return Map<String, Object?>.from(decoded);
  }

  /// Reads `submit_songs`' input.
  static ChartLookupResult parseSubmittedSongs(Object? input) {
    final songs = input is Map ? input['songs'] : null;
    if (songs is! List) {
      throw ChartLookupException("Claude's answer had no song list");
    }
    return ChartLookupResult(
      songs: [
        for (final s in songs)
          if (s is Map && (s['title'] ?? '').toString().trim().isNotEmpty)
            ChartSong(
              artist: (s['artist'] ?? '').toString().trim(),
              title: s['title'].toString().trim(),
              note: (s['note'] ?? '').toString().trim(),
            ),
      ],
      summary: input is Map ? (input['summary'] ?? '').toString() : '',
    );
  }
}
