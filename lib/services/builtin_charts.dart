import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import 'chart_lookup_service.dart';

/// The year-end hits that ship inside the app
/// (`assets/charts/year_end_charts.json`), so "Top songs from the charts"
/// works without a Claude API key: [countries] from [firstYear] to
/// [lastYear], up to 25 songs a year, each tagged with one of
/// [ChartQuery.styles] so the style filter works offline too.
///
/// The asset is `{"<country>": {"<year>": [["Artist", "Title", "Style"],
/// ...]}}`, in chart order.
class BuiltInCharts {
  BuiltInCharts._();

  static final BuiltInCharts instance = BuiltInCharts._();

  static const String assetPath = 'assets/charts/year_end_charts.json';

  static const List<String> countries = [
    'Belgium',
    'United Kingdom',
    'United States',
    'France',
    'Germany',
    'Spain',
    'Switzerland',
  ];
  static const int firstYear = 2000;
  static const int lastYear = 2025;

  /// Tests hand in the JSON instead of the app bundle.
  @visibleForTesting
  Future<String> Function()? loadOverride;

  Map<String, Map<String, List<ChartSong>>>? _data;

  bool covers(String country, int year) =>
      countries.contains(country) && year >= firstYear && year <= lastYear;

  Future<Map<String, Map<String, List<ChartSong>>>> _load() async {
    final cached = _data;
    if (cached != null) return cached;
    final raw =
        await (loadOverride ?? () => rootBundle.loadString(assetPath))();
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final data = <String, Map<String, List<ChartSong>>>{
      for (final country in decoded.entries)
        country.key: {
          for (final year in (country.value as Map<String, dynamic>).entries)
            year.key: [
              for (final s in year.value as List)
                if (s is List && s.length >= 2)
                  ChartSong(
                    artist: s[0].toString(),
                    title: s[1].toString(),
                    style: s.length > 2 ? s[2].toString() : '',
                  ),
            ],
        },
    };
    return _data = data;
  }

  /// The built-in list for [query] (filtered to its style, cut to its
  /// count), or null when the country/year isn't built in.
  Future<ChartLookupResult?> lookup(ChartQuery query) async {
    if (!covers(query.country, query.year)) return null;
    final songs = (await _load())[query.country]?['${query.year}'];
    if (songs == null || songs.isEmpty) return null;
    final allStyles = query.style == ChartQuery.allStyles;
    final matching = [
      for (final s in songs)
        if (allStyles || s.style == query.style) s,
    ].take(query.count).toList();
    final what = allStyles ? 'hits' : '${query.style} hits';
    return ChartLookupResult(
      songs: matching,
      source: ChartSource.builtIn,
      summary: 'Built-in list: the biggest $what of ${query.year} in '
          '${query.country}'
          '${matching.length < query.count ? ' (${matching.length} in the built-in top ${songs.length})' : ''}.',
    );
  }

  @visibleForTesting
  void resetForTest() {
    _data = null;
    loadOverride = null;
  }
}

/// A country's chart right now from Deezer's free public API (no key): the
/// "Top <country>" playlist that the "Deezer Charts" account keeps up to
/// date. Used for the current year when there's no Claude API key.
class DeezerCharts {
  DeezerCharts._();

  static final DeezerCharts instance = DeezerCharts._();

  /// Tests stand in for the network here.
  @visibleForTesting
  http.Client? client;

  /// The words Deezer's chart playlists use for each country.
  static const Map<String, List<String>> aliases = {
    'Belgium': ['Belgium', 'Belgique', 'België'],
    'Netherlands': ['Netherlands', 'Nederland'],
    'France': ['France'],
    'Germany': ['Germany', 'Deutschland'],
    'United Kingdom': ['UK', 'United Kingdom'],
    'United States': ['USA', 'United States'],
    'Spain': ['Spain', 'España', 'Espana'],
    'Switzerland': ['Switzerland', 'Schweiz', 'Suisse'],
    'Italy': ['Italy', 'Italia'],
    'Sweden': ['Sweden', 'Sverige'],
    'Canada': ['Canada'],
    'Australia': ['Australia'],
    'Brazil': ['Brazil', 'Brasil'],
    'Japan': ['Japan'],
    'Worldwide': ['Worldwide', 'Global'],
  };

  Future<List<ChartSong>> currentChart(String country, int count) async {
    final httpClient = client ?? http.Client();
    try {
      final words = aliases[country] ?? [country];
      for (final word in words) {
        final found = await _get(httpClient,
            'https://api.deezer.com/search/playlist?q=${Uri.encodeQueryComponent('Top $word')}&limit=25');
        for (final p in (found['data'] as List? ?? const [])) {
          if (p is! Map) continue;
          final user = (p['user'] is Map ? p['user']['name'] : '') ?? '';
          final title = (p['title'] ?? '').toString().toLowerCase();
          if (user.toString().toLowerCase() != 'deezer charts') continue;
          if (!title.startsWith('top') ||
              !words.any((w) => title.contains(w.toLowerCase()))) {
            continue;
          }
          final tracks = await _get(httpClient,
              'https://api.deezer.com/playlist/${p['id']}/tracks?limit=$count');
          return [
            for (final t in (tracks['data'] as List? ?? const []))
              if (t is Map)
                ChartSong(
                  artist: (t['artist'] is Map ? t['artist']['name'] : '')
                          ?.toString() ??
                      '',
                  title: (t['title_short'] ?? t['title'] ?? '').toString(),
                ),
          ].where((s) => s.title.isNotEmpty).take(count).toList();
        }
      }
      throw ChartLookupException('No Deezer chart found for $country');
    } finally {
      if (client == null) httpClient.close();
    }
  }

  Future<Map<String, dynamic>> _get(http.Client httpClient, String url) async {
    final http.Response response;
    try {
      response = await httpClient
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 20));
    } catch (e) {
      throw ChartLookupException("Couldn't reach Deezer: $e");
    }
    if (response.statusCode != 200) {
      throw ChartLookupException('Deezer error ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw ChartLookupException('Unexpected reply from Deezer');
    }
    return decoded;
  }
}
