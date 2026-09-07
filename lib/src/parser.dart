import 'models.dart';

/// Parses Twitch IRC framing without requiring a network connection.
class TwitchIrcParser {
  static const _membershipNoticeIds = {
    'sub',
    'resub',
    'subgift',
    'anonsubgift',
  };

  static TwitchIrcEvent? parse(String line) {
    var rest = line.trim();
    if (rest.isEmpty) return null;
    var tags = const <String, String>{};
    if (rest.startsWith('@')) {
      final end = rest.indexOf(' ');
      if (end < 0) return null;
      tags = parseTags(rest.substring(1, end));
      rest = rest.substring(end + 1);
    }

    var prefix = '';
    if (rest.startsWith(':')) {
      final end = rest.indexOf(' ');
      if (end < 0) return null;
      prefix = rest.substring(1, end);
      rest = rest.substring(end + 1);
    }

    final commandEnd = rest.indexOf(' ');
    final command = commandEnd < 0 ? rest : rest.substring(0, commandEnd);
    rest = commandEnd < 0 ? '' : rest.substring(commandEnd + 1);
    final trailingAt = rest.indexOf(' :');
    final text = trailingAt < 0 ? '' : rest.substring(trailingAt + 2);
    final username = prefix.split('!').first;

    if (command == 'PRIVMSG') {
      return TwitchIrcEvent(
        type: TwitchIrcEventType.message,
        tags: Map.unmodifiable(tags),
        username: username,
        text: text,
        raw: line,
      );
    }
    if (command == 'USERNOTICE' &&
        _membershipNoticeIds.contains(tags['msg-id'])) {
      return TwitchIrcEvent(
        type: TwitchIrcEventType.membership,
        tags: Map.unmodifiable(tags),
        username: tags['login']?.isNotEmpty == true ? tags['login']! : username,
        text: text,
        raw: line,
      );
    }
    return null;
  }

  static Map<String, String> parseTags(String source) {
    final tags = <String, String>{};
    for (final entry in source.split(';')) {
      final separator = entry.indexOf('=');
      if (separator < 0) continue;
      tags[entry.substring(0, separator)] =
          _unescape(entry.substring(separator + 1));
    }
    return tags;
  }

  static String _unescape(String value) {
    final result = StringBuffer();
    for (var index = 0; index < value.length; index++) {
      final char = value[index];
      if (char != '\\' || index + 1 >= value.length) {
        result.write(char);
        continue;
      }
      final escaped = value[++index];
      result.write(switch (escaped) {
        's' => ' ',
        ':' => ';',
        'r' => '\r',
        'n' => '\n',
        '\\' => '\\',
        _ => escaped,
      });
    }
    return result.toString();
  }
}

class _NativeEmoteRange {
  const _NativeEmoteRange(this.start, this.end, this.emote);

  final int start;
  final int end;
  final TwitchEmote emote;
}

/// Converts a parsed IRC event into a strongly typed Twitch message.
class TwitchMessageParser {
  static TwitchChatMessage fromEvent(
    TwitchIrcEvent event, {
    Map<String, TwitchEmote> thirdPartyEmotes = const {},
    DateTime? receivedAt,
  }) {
    final tags = event.tags;
    final roles = TwitchUserRoles.fromTags(
      tags,
      membershipEvent: event.type == TwitchIrcEventType.membership,
    );
    final noticeId = tags['msg-id'];
    final membershipKind = switch (noticeId) {
      'sub' => TwitchMembershipKind.subscription,
      'resub' => TwitchMembershipKind.resubscription,
      'subgift' || 'anonsubgift' => TwitchMembershipKind.gift,
      _ => null,
    };
    final username = event.username;
    final badges = roles.badges.entries
        .map(
          (entry) => TwitchBadge(
            kind: entry.key,
            version: entry.value,
            label: badgeLabel(entry.key, entry.value),
          ),
        )
        .toList(growable: false);

    return TwitchChatMessage(
      id: tags['id'] ??
          '${(receivedAt ?? DateTime.now()).millisecondsSinceEpoch}',
      author: TwitchAuthor(
        name: tags['display-name'] ?? username,
        login: username,
        color: tags['color']?.isNotEmpty == true ? tags['color'] : null,
        badges: List.unmodifiable(badges),
        isOwner: roles.isOwner,
        isModerator: roles.isModerator,
        isSubscriber: roles.isSubscriber,
        isVip: roles.isVip,
      ),
      parts: List.unmodifiable(
        parseContent(
          event.text,
          nativeEmotesTag: tags['emotes'] ?? '',
          thirdPartyEmotes: thirdPartyEmotes,
        ),
      ),
      timestamp: receivedAt ?? DateTime.now(),
      rawTags: Map.unmodifiable(tags),
      raw: event.raw,
      isMembershipEvent: event.type == TwitchIrcEventType.membership,
      membershipKind: membershipKind,
      membershipMonths: int.tryParse(tags['msg-param-cumulative-months'] ?? ''),
    );
  }

  static List<TwitchMessagePart> parseContent(
    String text, {
    String nativeEmotesTag = '',
    Map<String, TwitchEmote> thirdPartyEmotes = const {},
  }) {
    if (text.isEmpty) return const [];
    final ranges = _parseNativeEmotes(nativeEmotesTag)
      ..sort((a, b) => a.start.compareTo(b.start));
    final parts = <TwitchMessagePart>[];
    final codePoints = text.runes.toList(growable: false);
    var cursor = 0;

    for (final range in ranges) {
      if (range.start < cursor ||
          range.start >= codePoints.length ||
          range.end >= codePoints.length) {
        continue;
      }
      _appendThirdParty(
        parts,
        String.fromCharCodes(codePoints.sublist(cursor, range.start)),
        thirdPartyEmotes,
      );
      final code =
          String.fromCharCodes(codePoints.sublist(range.start, range.end + 1));
      parts.add(
        TwitchMessagePart.emote(
          TwitchEmote(
            code: code,
            url: range.emote.url,
            isAnimated: range.emote.isAnimated,
          ),
        ),
      );
      cursor = range.end + 1;
    }
    _appendThirdParty(
      parts,
      String.fromCharCodes(codePoints.sublist(cursor)),
      thirdPartyEmotes,
    );
    return parts.isEmpty ? [TwitchMessagePart.text(text)] : parts;
  }

  static List<_NativeEmoteRange> _parseNativeEmotes(String source) {
    final ranges = <_NativeEmoteRange>[];
    for (final entry in source.split('/')) {
      final separator = entry.indexOf(':');
      if (separator <= 0) continue;
      final id = entry.substring(0, separator);
      for (final sourceRange in entry.substring(separator + 1).split(',')) {
        final bounds = sourceRange.split('-');
        if (bounds.length != 2) continue;
        final start = int.tryParse(bounds[0]);
        final end = int.tryParse(bounds[1]);
        if (start != null && end != null && start >= 0 && end >= start) {
          ranges.add(
            _NativeEmoteRange(
              start,
              end,
              TwitchEmote(
                code: '',
                url:
                    'https://static-cdn.jtvnw.net/emoticons/v2/$id/default/dark/1.0',
              ),
            ),
          );
        }
      }
    }
    return ranges;
  }

  static void _appendThirdParty(
    List<TwitchMessagePart> parts,
    String text,
    Map<String, TwitchEmote> emotes,
  ) {
    if (text.isEmpty) return;
    var cursor = 0;
    for (final match in RegExp(r'\S+').allMatches(text)) {
      _appendText(parts, text.substring(cursor, match.start));
      final token = match.group(0)!;
      final emote = emotes[token];
      if (emote == null) {
        _appendText(parts, token);
      } else {
        parts.add(TwitchMessagePart.emote(emote));
      }
      cursor = match.end;
    }
    _appendText(parts, text.substring(cursor));
  }

  static void _appendText(List<TwitchMessagePart> parts, String text) {
    if (text.isEmpty) return;
    if (parts.isNotEmpty && !parts.last.isEmote) {
      parts[parts.length - 1] = TwitchMessagePart.text(parts.last.text + text);
    } else {
      parts.add(TwitchMessagePart.text(text));
    }
  }

  static String badgeLabel(String kind, String version) {
    final name = kind
        .split(RegExp('[-_]'))
        .where((part) => part.isNotEmpty)
        .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
        .join(' ');
    return kind == 'bits' && version.isNotEmpty ? '$name $version' : name;
  }
}
