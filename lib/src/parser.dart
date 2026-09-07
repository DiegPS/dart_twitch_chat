import 'events.dart';
import 'models.dart';

/// Parses Twitch IRC framing without requiring a network connection.
class TwitchIrcParser {
  static const _legacyMembershipNoticeIds = {
    'sub',
    'resub',
    'subgift',
    'anonsubgift'
  };

  /// Parses every syntactically valid IRC line without discarding unknown data.
  static TwitchIrcFrame? parseFrame(String line) {
    var raw = line;
    while (raw.endsWith('\r') || raw.endsWith('\n')) {
      raw = raw.substring(0, raw.length - 1);
    }
    if (raw.isEmpty) return null;
    var rest = raw;
    var tags = const <String, String>{};
    if (rest.startsWith('@')) {
      final end = rest.indexOf(' ');
      if (end < 0) return null;
      tags = parseTags(rest.substring(1, end));
      rest = rest.substring(end + 1);
    }
    String? prefix;
    if (rest.startsWith(':')) {
      final end = rest.indexOf(' ');
      if (end < 0) return null;
      prefix = rest.substring(1, end);
      rest = rest.substring(end + 1);
    }
    final commandEnd = rest.indexOf(' ');
    final command =
        (commandEnd < 0 ? rest : rest.substring(0, commandEnd)).toUpperCase();
    if (command.isEmpty) return null;
    rest = commandEnd < 0 ? '' : rest.substring(commandEnd + 1);
    String? trailing;
    final trailingAt = rest.startsWith(':') ? 0 : rest.indexOf(' :');
    if (trailingAt >= 0) {
      trailing = rest.substring(trailingAt + (trailingAt == 0 ? 1 : 2));
      rest = rest.substring(0, trailingAt);
    }
    final parameters = rest
        .split(' ')
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    return TwitchIrcFrame(
        raw: raw,
        tags: Map.unmodifiable(tags),
        prefix: prefix,
        command: command,
        parameters: List.unmodifiable(parameters),
        trailing: trailing);
  }

  /// Parses the original compatibility event surface.
  static TwitchIrcEvent? parse(String line) {
    final frame = parseFrame(line);
    if (frame == null) return null;
    if (frame.command == 'PRIVMSG') {
      return TwitchIrcEvent(
          type: TwitchIrcEventType.message,
          tags: frame.tags,
          username: frame.username ?? '',
          text: frame.trailing ?? '',
          raw: frame.raw);
    }
    if (frame.command == 'USERNOTICE' &&
        _legacyMembershipNoticeIds.contains(frame.tags['msg-id'])) {
      return TwitchIrcEvent(
          type: TwitchIrcEventType.membership,
          tags: frame.tags,
          username: _value(frame.tags, 'login') ?? frame.username ?? '',
          text: frame.trailing ?? '',
          raw: frame.raw);
    }
    return null;
  }

  static Map<String, String> parseTags(String source) {
    final tags = <String, String>{};
    for (final entry in source.split(';')) {
      final separator = entry.indexOf('=');
      if (separator < 0) {
        tags[entry] = '';
      } else {
        tags[entry.substring(0, separator)] =
            _unescape(entry.substring(separator + 1));
      }
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
        _ => escaped
      });
    }
    return result.toString();
  }
}

/// Converts lossless IRC frames into typed Twitch events.
class TwitchEventParser {
  static TwitchEvent parse(TwitchIrcFrame frame,
      {Map<String, TwitchEmote> thirdPartyEmotes = const {},
      DateTime? receivedAt}) {
    final received = receivedAt ?? DateTime.now().toUtc();
    return switch (frame.command) {
      'PRIVMSG' => TwitchMessageEvent(
          frame,
          TwitchMessageParser.fromFrame(frame,
              thirdPartyEmotes: thirdPartyEmotes, receivedAt: received)),
      'USERNOTICE' => TwitchUserNoticeEvent(
          frame,
          TwitchMessageParser.noticeFromFrame(frame,
              thirdPartyEmotes: thirdPartyEmotes, receivedAt: received)),
      'CLEARMSG' => TwitchClearMessageEvent(frame,
          targetMessageId: _value(frame.tags, 'target-msg-id') ?? '',
          login: _value(frame.tags, 'login'),
          message: frame.trailing,
          roomId: _value(frame.tags, 'room-id'),
          timestamp: _timestamp(frame.tags)),
      'CLEARCHAT' => TwitchClearChatEvent(frame,
          login: frame.trailing,
          targetUserId: _value(frame.tags, 'target-user-id'),
          roomId: _value(frame.tags, 'room-id'),
          banDuration: _seconds(frame.tags['ban-duration']),
          timestamp: _timestamp(frame.tags)),
      'ROOMSTATE' => TwitchRoomStateEvent(frame,
          roomId: _value(frame.tags, 'room-id'),
          emoteOnly: _boolean(frame.tags, 'emote-only'),
          followersOnlyMinutes: _integer(frame.tags, 'followers-only'),
          uniqueChat: _boolean(frame.tags, 'r9k'),
          slowModeSeconds: _integer(frame.tags, 'slow'),
          subscribersOnly: _boolean(frame.tags, 'subs-only')),
      'NOTICE' => TwitchNoticeEvent(frame,
          messageId: _value(frame.tags, 'msg-id'),
          targetUserId: _value(frame.tags, 'target-user-id'),
          message: frame.trailing ?? ''),
      'RECONNECT' => TwitchReconnectEvent(frame),
      'CAP' => TwitchCapabilityEvent(frame,
          acknowledged: frame.parameters.contains('ACK'),
          capabilities: List.unmodifiable((frame.trailing ?? '')
              .split(' ')
              .where((value) => value.isNotEmpty))),
      'GLOBALUSERSTATE' => TwitchUserStateEvent(frame, global: true),
      'USERSTATE' => TwitchUserStateEvent(frame, global: false),
      'JOIN' => TwitchJoinEvent(frame, channel: frame.channel ?? ''),
      'PART' => TwitchPartEvent(frame, channel: frame.channel ?? ''),
      _ when int.tryParse(frame.command) != null =>
        TwitchNumericEvent(frame, code: int.parse(frame.command)),
      _ => TwitchRawEvent(frame),
    };
  }
}

class _MediaRange {
  const _MediaRange(this.start, this.end, {this.emote, this.gif});
  final int start;
  final int end;
  final TwitchEmote? emote;
  final TwitchGif? gif;
}

/// Converts chat and user-notice frames into rich message models.
class TwitchMessageParser {
  static TwitchChatMessage fromEvent(TwitchIrcEvent event,
      {Map<String, TwitchEmote> thirdPartyEmotes = const {},
      DateTime? receivedAt}) {
    final frame = TwitchIrcParser.parseFrame(event.raw)!;
    return fromFrame(frame,
        thirdPartyEmotes: thirdPartyEmotes, receivedAt: receivedAt);
  }

  static TwitchChatMessage fromFrame(TwitchIrcFrame frame,
      {Map<String, TwitchEmote> thirdPartyEmotes = const {},
      DateTime? receivedAt}) {
    final tags = frame.tags;
    final isNotice = frame.command == 'USERNOTICE';
    final rawText = frame.trailing ?? '';
    final action =
        rawText.startsWith('\u0001ACTION ') && rawText.endsWith('\u0001');
    final text = action ? rawText.substring(8, rawText.length - 1) : rawText;
    final roles = TwitchUserRoles.fromTags(tags,
        membershipEvent: isNotice &&
            {
              'sub',
              'resub',
              'subgift',
              'anonsubgift',
              'submysterygift',
              'giftpaidupgrade',
              'anongiftpaidupgrade'
            }.contains(tags['msg-id']));
    final badgeInfo = parseBadgeMap(tags['badge-info']);
    final timestamp =
        _timestamp(tags) ?? receivedAt?.toUtc() ?? DateTime.now().toUtc();
    final username = _value(tags, 'login') ?? frame.username ?? '';
    final source = _sharedSource(tags);
    return TwitchChatMessage(
      id: _value(tags, 'id') ?? '${timestamp.microsecondsSinceEpoch}',
      author: TwitchAuthor(
          name: _value(tags, 'display-name') ?? username,
          login: username,
          id: _value(tags, 'user-id'),
          color: _value(tags, 'color'),
          userType: _value(tags, 'user-type'),
          badges: List.unmodifiable(roles.badges.entries.map((entry) =>
              TwitchBadge(
                  kind: entry.key,
                  version: entry.value,
                  label: badgeLabel(entry.key, entry.value),
                  info: badgeInfo[entry.key]))),
          isOwner: roles.isOwner,
          isModerator: roles.isModerator,
          isSubscriber: roles.isSubscriber,
          isVip: roles.isVip),
      parts: List.unmodifiable(parseContent(text,
          nativeEmotesTag: tags['emotes'] ?? '',
          gifsTag: tags['gifs'] ?? '',
          thirdPartyEmotes: thirdPartyEmotes)),
      timestamp: timestamp,
      rawTags: tags,
      raw: frame.raw,
      roomId: _value(tags, 'room-id'),
      clientNonce: _value(tags, 'client-nonce'),
      flags: _value(tags, 'flags'),
      bits: _integer(tags, 'bits'),
      isFirstMessage: _boolean(tags, 'first-msg') ?? false,
      isReturningChatter: _boolean(tags, 'returning-chatter') ?? false,
      isAction: action,
      reply: _reply(tags),
      sharedChatSource: source,
      isMembershipEvent: isNotice,
      membershipKind: switch (tags['msg-id']) {
        'sub' => TwitchMembershipKind.subscription,
        'resub' => TwitchMembershipKind.resubscription,
        'subgift' ||
        'anonsubgift' ||
        'submysterygift' =>
          TwitchMembershipKind.gift,
        _ => null
      },
      membershipMonths: _integer(tags, 'msg-param-cumulative-months') ??
          _integer(tags, 'msg-param-months'),
    );
  }

  static TwitchUserNotice noticeFromFrame(TwitchIrcFrame frame,
      {Map<String, TwitchEmote> thirdPartyEmotes = const {},
      DateTime? receivedAt}) {
    final message = fromFrame(frame,
        thirdPartyEmotes: thirdPartyEmotes, receivedAt: receivedAt);
    final tags = frame.tags;
    final type = tags['msg-id'] ?? '';
    final parameters = Map<String, String>.unmodifiable({
      for (final entry in tags.entries)
        if (entry.key.startsWith('msg-param-'))
          entry.key.substring(10): entry.value
    });
    return TwitchUserNotice(
      kind: _noticeKind(type),
      messageType: type,
      message: message,
      systemMessage: _value(tags, 'system-msg'),
      parameters: parameters,
      timestamp: message.timestamp,
      roomId: message.roomId,
      source: message.sharedChatSource,
      cumulativeMonths: _integer(tags, 'msg-param-cumulative-months'),
      streakMonths: _integer(tags, 'msg-param-streak-months'),
      months: _integer(tags, 'msg-param-months'),
      giftMonths: _integer(tags, 'msg-param-gift-months'),
      subscriptionPlan: _value(tags, 'msg-param-sub-plan'),
      subscriptionPlanName: _value(tags, 'msg-param-sub-plan-name'),
      recipientDisplayName: _value(tags, 'msg-param-recipient-display-name'),
      recipientId: _value(tags, 'msg-param-recipient-id'),
      recipientLogin: _value(tags, 'msg-param-recipient-user-name') ??
          _value(tags, 'msg-param-recipient-name'),
      senderLogin: _value(tags, 'msg-param-sender-login'),
      senderName: _value(tags, 'msg-param-sender-name'),
      viewerCount: _integer(tags, 'msg-param-viewerCount'),
      bitsThreshold: _integer(tags, 'msg-param-threshold'),
      promotionName: _value(tags, 'msg-param-promo-name'),
      promotionGiftTotal: _integer(tags, 'msg-param-promo-gift-total'),
      milestoneCategory: _value(tags, 'msg-param-category'),
      milestoneId: _value(tags, 'msg-param-id'),
      milestoneValue: _integer(tags, 'msg-param-value'),
      shouldShareStreak: _boolean(tags, 'msg-param-should-share-streak'),
    );
  }

  static List<TwitchMessagePart> parseContent(String text,
      {String nativeEmotesTag = '',
      String gifsTag = '',
      Map<String, TwitchEmote> thirdPartyEmotes = const {}}) {
    if (text.isEmpty) return const [];
    final ranges = <_MediaRange>[
      ..._nativeRanges(nativeEmotesTag),
      ..._gifRanges(gifsTag)
    ]..sort((a, b) => a.start.compareTo(b.start));
    final parts = <TwitchMessagePart>[];
    final codePoints = text.runes.toList(growable: false);
    var cursor = 0;
    for (final range in ranges) {
      if (range.start < cursor ||
          range.start < 0 ||
          range.end >= codePoints.length ||
          range.end < range.start) {
        continue;
      }
      _appendThirdParty(
          parts,
          String.fromCharCodes(codePoints.sublist(cursor, range.start)),
          thirdPartyEmotes);
      final alt =
          String.fromCharCodes(codePoints.sublist(range.start, range.end + 1));
      if (range.emote != null) {
        parts.add(TwitchMessagePart.emote(TwitchEmote(
            code: alt,
            url: range.emote!.url,
            isAnimated: range.emote!.isAnimated)));
      }
      if (range.gif != null) {
        parts.add(TwitchMessagePart.gif(
            TwitchGif(id: range.gif!.id, url: range.gif!.url, alt: alt)));
      }
      cursor = range.end + 1;
    }
    _appendThirdParty(parts, String.fromCharCodes(codePoints.sublist(cursor)),
        thirdPartyEmotes);
    return parts.isEmpty ? [TwitchMessagePart.text(text)] : parts;
  }

  static List<_MediaRange> _nativeRanges(String source) {
    final ranges = <_MediaRange>[];
    for (final entry in source.split('/')) {
      final separator = entry.indexOf(':');
      if (separator <= 0) continue;
      final id = entry.substring(0, separator);
      for (final rawRange in entry.substring(separator + 1).split(',')) {
        final bounds = rawRange.split('-');
        if (bounds.length != 2) continue;
        final start = int.tryParse(bounds[0]);
        final end = int.tryParse(bounds[1]);
        if (start != null && end != null) {
          ranges.add(_MediaRange(start, end,
              emote: TwitchEmote(
                  code: '',
                  url:
                      'https://static-cdn.jtvnw.net/emoticons/v2/$id/default/dark/1.0')));
        }
      }
    }
    return ranges;
  }

  static List<_MediaRange> _gifRanges(String source) {
    final ranges = <_MediaRange>[];
    for (final entry in source.split(',')) {
      final parts = entry.split('|');
      if (parts.length < 3) continue;
      final bounds = parts.first.split('-');
      if (bounds.length != 2) continue;
      final start = int.tryParse(bounds[0]);
      final end = int.tryParse(bounds[1]);
      if (start != null && end != null) {
        ranges.add(_MediaRange(start, end,
            gif: TwitchGif(
                id: parts[1], url: parts.sublist(2).join('|'), alt: '')));
      }
    }
    return ranges;
  }

  static void _appendThirdParty(List<TwitchMessagePart> parts, String text,
      Map<String, TwitchEmote> emotes) {
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
    if (parts.isNotEmpty && !parts.last.isEmote && !parts.last.isGif) {
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

TwitchUserNoticeKind _noticeKind(String value) => switch (value) {
      'sub' => TwitchUserNoticeKind.subscription,
      'resub' => TwitchUserNoticeKind.resubscription,
      'subgift' || 'anonsubgift' => TwitchUserNoticeKind.subscriptionGift,
      'submysterygift' => TwitchUserNoticeKind.communitySubscriptionGift,
      'giftpaidupgrade' => TwitchUserNoticeKind.giftPaidUpgrade,
      'rewardgift' => TwitchUserNoticeKind.rewardGift,
      'anongiftpaidupgrade' => TwitchUserNoticeKind.anonymousGiftPaidUpgrade,
      'raid' => TwitchUserNoticeKind.raid,
      'unraid' => TwitchUserNoticeKind.unraid,
      'bitsbadgetier' => TwitchUserNoticeKind.bitsBadgeTier,
      'sharedchatnotice' => TwitchUserNoticeKind.sharedChatNotice,
      'modiversary' => TwitchUserNoticeKind.modiversary,
      'viewermilestone' => TwitchUserNoticeKind.viewerMilestone,
      _ => TwitchUserNoticeKind.unknown
    };
TwitchReply? _reply(Map<String, String> tags) {
  final id = _value(tags, 'reply-parent-msg-id');
  return id == null
      ? null
      : TwitchReply(
          parentMessageId: id,
          parentUserId: _value(tags, 'reply-parent-user-id'),
          parentUserLogin: _value(tags, 'reply-parent-user-login'),
          parentDisplayName: _value(tags, 'reply-parent-display-name'),
          parentMessageBody: _value(tags, 'reply-parent-msg-body'),
          threadParentMessageId: _value(tags, 'reply-thread-parent-msg-id'),
          threadParentUserLogin:
              _value(tags, 'reply-thread-parent-user-login'));
}

TwitchSharedChatSource? _sharedSource(Map<String, String> tags) {
  if (!tags.keys.any((key) => key.startsWith('source-'))) return null;
  return TwitchSharedChatSource(
      messageId: _value(tags, 'source-id'),
      roomId: _value(tags, 'source-room-id'),
      badges: parseBadgeMap(tags['source-badges']),
      badgeInfo: parseBadgeMap(tags['source-badge-info']),
      messageType: _value(tags, 'source-msg-id'),
      sourceOnly: _boolean(tags, 'source-only') ?? false);
}

String? _value(Map<String, String> tags, String key) {
  final value = tags[key];
  return value == null || value.isEmpty ? null : value;
}

int? _integer(Map<String, String> tags, String key) =>
    int.tryParse(tags[key] ?? '');
bool? _boolean(Map<String, String> tags, String key) {
  final value = tags[key];
  return value == null ? null : value == '1';
}

DateTime? _timestamp(Map<String, String> tags) {
  final milliseconds = _integer(tags, 'tmi-sent-ts');
  return milliseconds == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
}

Duration? _seconds(String? value) {
  final seconds = int.tryParse(value ?? '');
  return seconds == null ? null : Duration(seconds: seconds);
}
