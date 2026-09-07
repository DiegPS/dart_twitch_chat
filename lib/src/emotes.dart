import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

const _bttvGlobalUrl = 'https://api.betterttv.net/3/cached/emotes/global';
const _ffzGlobalUrl = 'https://api.frankerfacez.com/v1/set/global';
const _sevenTvGlobalUrl = 'https://7tv.io/v3/emote-sets/global';

const _bttvChannelUrl = 'https://api.betterttv.net/3/cached/users/twitch/';
const _ffzChannelUrl = 'https://api.frankerfacez.com/v1/room/';
const _sevenTvChannelUrl = 'https://7tv.io/v3/users/twitch/';

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

  /// Loads channel-specific emotes without authentication.
  ///
  /// [channelId] is Twitch's numeric room ID, exposed by anonymous IRC in
  /// `ROOMSTATE`. FFZ resolves rooms by login while BTTV and 7TV use the ID.
  Future<Map<String, TwitchEmote>> loadChannel({
    required String channelName,
    required String channelId,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) async {
    if (channelName.trim().isEmpty || channelId.trim().isEmpty) return const {};
    final results = await Future.wait([
      _safe(() => _loadBttvChannel(channelId), onError),
      _safe(() => _loadFfzChannel(channelName), onError),
      _safe(() => _loadSevenTvChannel(channelId), onError),
    ]);
    return Map.unmodifiable({for (final result in results) ...result});
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
    final decoded = jsonDecode(response.body);
    if (decoded is! List<dynamic>) return const {};
    final list = decoded;
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
    return _parseFfz(response.body);
  }

  Future<Map<String, TwitchEmote>> _loadSevenTv() async {
    final response = await _get(_sevenTvGlobalUrl);
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return const {};
    final document = decoded;
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

  Future<Map<String, TwitchEmote>> _loadBttvChannel(String channelId) async {
    final response = await _get('$_bttvChannelUrl$channelId');
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return const {};
    final document = decoded;
    final values = <dynamic>[
      ...(document['channelEmotes'] as List<dynamic>? ?? const []),
      ...(document['sharedEmotes'] as List<dynamic>? ?? const []),
    ];
    return {
      for (final value in values)
        if (value is Map<String, dynamic> &&
            value['code'] is String &&
            value['id'] != null)
          value['code'] as String: TwitchEmote(
            code: value['code'] as String,
            url: 'https://cdn.betterttv.net/emote/${value['id']}/1x',
            isAnimated: value['imageType'] == 'gif',
          ),
    };
  }

  Future<Map<String, TwitchEmote>> _loadFfzChannel(String channelName) async {
    final response =
        await _get('$_ffzChannelUrl${Uri.encodeComponent(channelName)}');
    return _parseFfz(response.body);
  }

  Future<Map<String, TwitchEmote>> _loadSevenTvChannel(String channelId) async {
    final response = await _get('$_sevenTvChannelUrl$channelId');
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return const {};
    final document = decoded;
    final set = document['emote_set'] as Map<String, dynamic>? ?? const {};
    return _parseSevenTvEmotes(set['emotes']);
  }

  Map<String, TwitchEmote> _parseFfz(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return const {};
    final document = decoded;
    final sets = document['sets'] as Map<String, dynamic>? ?? const {};
    final result = <String, TwitchEmote>{};
    for (final value in sets.values) {
      if (value is! Map<String, dynamic>) continue;
      for (final item in value['emoticons'] as List<dynamic>? ?? const []) {
        if (item is! Map<String, dynamic>) continue;
        final code = item['name'] as String? ?? '';
        final urls = item['urls'] as Map<String, dynamic>? ?? const {};
        final animated = item['animated'] as Map<String, dynamic>?;
        final source = (animated?['1'] ?? urls['1']) as String? ?? '';
        if (code.isNotEmpty && source.isNotEmpty) {
          result[code] = TwitchEmote(
            code: code,
            url: source.startsWith('//') ? 'https:$source' : source,
            isAnimated: animated != null,
          );
        }
      }
    }
    return result;
  }

  Map<String, TwitchEmote> _parseSevenTvEmotes(Object? value) {
    final result = <String, TwitchEmote>{};
    for (final item in value as List<dynamic>? ?? const []) {
      if (item is! Map<String, dynamic>) continue;
      final code = item['name'] as String? ?? '';
      final data = item['data'] as Map<String, dynamic>? ?? const {};
      final id = item['id']?.toString() ?? '';
      final host = data['host'] as Map<String, dynamic>? ?? const {};
      final baseUrl = host['url'] as String? ?? '';
      final files = host['files'] as List<dynamic>? ?? const [];
      String url = '';
      var animated = data['animated'] == true;
      if (baseUrl.isNotEmpty && files.isNotEmpty) {
        final maps =
            files.whereType<Map>().map(Map<String, dynamic>.from).toList();
        if (maps.isNotEmpty) {
          final selected = maps.firstWhere(
            (file) => file['name'].toString().startsWith('1x'),
            orElse: () => maps.first,
          );
          final fileName = selected['name']?.toString() ?? '';
          url = '${baseUrl.startsWith('//') ? 'https:' : ''}$baseUrl/$fileName';
          animated = animated || fileName.endsWith('.gif');
        }
      } else if (id.isNotEmpty) {
        url = 'https://cdn.7tv.app/emote/$id/1x.webp';
      }
      if (code.isNotEmpty && url.isNotEmpty) {
        result[code] = TwitchEmote(code: code, url: url, isAnimated: animated);
      }
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
