import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

const _bttvGlobalUrl = 'https://api.betterttv.net/3/cached/emotes/global';
const _ffzGlobalUrl = 'https://api.frankerfacez.com/v1/set/global';
const _sevenTvGlobalUrl = 'https://7tv.io/v3/emote-sets/global';

/// Loads anonymous global emotes from BetterTTV, FrankerFaceZ, and 7TV.
class TwitchGlobalEmoteLoader {
  TwitchGlobalEmoteLoader({
    required http.Client httpClient,
    Duration timeout = const Duration(seconds: 5),
  })  : _httpClient = httpClient,
        _timeout = timeout;

  final http.Client _httpClient;
  final Duration _timeout;

  Future<Map<String, TwitchEmote>> load({
    void Function(Object error, StackTrace stackTrace)? onError,
  }) async {
    final results = await Future.wait([
      _safe(_loadBttv, onError),
      _safe(_loadFfz, onError),
      _safe(_loadSevenTv, onError),
    ]);
    return Map.unmodifiable({
      for (final result in results) ...result,
    });
  }

  Future<Map<String, TwitchEmote>> _safe(
    Future<Map<String, TwitchEmote>> Function() load,
    void Function(Object error, StackTrace stackTrace)? onError,
  ) async {
    try {
      return await load();
    } catch (error, stackTrace) {
      onError?.call(error, stackTrace);
      return const {};
    }
  }

  Future<Map<String, TwitchEmote>> _loadBttv() async {
    final response = await _get(_bttvGlobalUrl);
    final list = jsonDecode(response.body) as List<dynamic>;
    return {
      for (final value in list)
        if (value is Map<String, dynamic>)
          value['code'] as String: TwitchEmote(
            code: value['code'] as String,
            url: 'https://cdn.betterttv.net/emote/${value['id']}/1x',
            isAnimated: value['imageType'] == 'gif',
          ),
    };
  }

  Future<Map<String, TwitchEmote>> _loadFfz() async {
    final response = await _get(_ffzGlobalUrl);
    final document = jsonDecode(response.body) as Map<String, dynamic>;
    final sets = document['sets'] as Map<String, dynamic>? ?? const {};
    final result = <String, TwitchEmote>{};
    for (final value in sets.values) {
      if (value is! Map<String, dynamic>) continue;
      final emoticons = value['emoticons'] as List<dynamic>? ?? const [];
      for (final item in emoticons) {
        if (item is! Map<String, dynamic>) continue;
        final code = item['name'] as String? ?? '';
        final urls = item['urls'] as Map<String, dynamic>? ?? const {};
        final source = urls['1'] as String? ?? '';
        if (code.isNotEmpty && source.isNotEmpty) {
          result[code] = TwitchEmote(
            code: code,
            url: source.startsWith('//') ? 'https:$source' : source,
          );
        }
      }
    }
    return result;
  }

  Future<Map<String, TwitchEmote>> _loadSevenTv() async {
    final response = await _get(_sevenTvGlobalUrl);
    final document = jsonDecode(response.body) as Map<String, dynamic>;
    final emotes = document['emotes'] as List<dynamic>? ?? const [];
    final result = <String, TwitchEmote>{};
    for (final item in emotes) {
      if (item is! Map<String, dynamic>) continue;
      final code = item['name'] as String? ?? '';
      final data = item['data'] as Map<String, dynamic>? ?? const {};
      final host = data['host'] as Map<String, dynamic>? ?? const {};
      final baseUrl = host['url'] as String? ?? '';
      final files = host['files'] as List<dynamic>? ?? const [];
      if (code.isEmpty || baseUrl.isEmpty || files.isEmpty) continue;
      final selected = files.cast<Map<String, dynamic>>().firstWhere(
            (file) => file['name'].toString().startsWith('1x'),
            orElse: () => files.first as Map<String, dynamic>,
          );
      final fileName = selected['name'] as String? ?? '';
      if (fileName.isEmpty) continue;
      result[code] = TwitchEmote(
        code: code,
        url: '${baseUrl.startsWith('//') ? 'https:' : ''}$baseUrl/$fileName',
        isAnimated: fileName.contains('gif') || data['animated'] == true,
      );
    }
    return result;
  }

  Future<http.Response> _get(String url) async {
    final response = await _httpClient.get(Uri.parse(url)).timeout(_timeout);
    if (response.statusCode != 200) {
      throw TwitchEmoteHttpException(url, response.statusCode);
    }
    return response;
  }
}

class TwitchEmoteHttpException implements Exception {
  const TwitchEmoteHttpException(this.url, this.statusCode);

  final String url;
  final int statusCode;

  @override
  String toString() => 'Twitch emote request failed ($statusCode): $url';
}
