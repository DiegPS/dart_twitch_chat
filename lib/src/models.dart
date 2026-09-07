/// IRC event types currently converted into chat messages.
enum TwitchIrcEventType { message, membership }

/// Parsed Twitch IRC frame.
class TwitchIrcEvent {
  const TwitchIrcEvent({
    required this.type,
    required this.tags,
    required this.username,
    required this.text,
    required this.raw,
  });

  final TwitchIrcEventType type;
  final Map<String, String> tags;
  final String username;
  final String text;
  final String raw;
}

/// Roles derived from Twitch IRC badge and flag tags.
class TwitchUserRoles {
  const TwitchUserRoles({
    required this.badges,
    required this.isOwner,
    required this.isModerator,
    required this.isSubscriber,
    required this.isVip,
  });

  factory TwitchUserRoles.fromTags(
    Map<String, String> tags, {
    bool membershipEvent = false,
  }) {
    final badges = <String, String>{};
    for (final badge in (tags['badges'] ?? '').split(',')) {
      final separator = badge.indexOf('/');
      if (separator <= 0) continue;
      badges[badge.substring(0, separator).toLowerCase()] =
          badge.substring(separator + 1);
    }
    return TwitchUserRoles(
      badges: Map.unmodifiable(badges),
      isOwner: badges.containsKey('broadcaster'),
      isModerator: tags['mod'] == '1' || badges.containsKey('moderator'),
      isSubscriber: tags['subscriber'] == '1' ||
          badges.containsKey('subscriber') ||
          badges.containsKey('founder') ||
          membershipEvent,
      isVip: badges.containsKey('vip'),
    );
  }

  final Map<String, String> badges;
  final bool isOwner;
  final bool isModerator;
  final bool isSubscriber;
  final bool isVip;
}

/// Twitch author badge with its raw kind and version.
class TwitchBadge {
  const TwitchBadge({
    required this.kind,
    required this.version,
    required this.label,
  });

  final String kind;
  final String version;
  final String label;
}

/// Emote referenced by a Twitch message part.
class TwitchEmote {
  const TwitchEmote({
    required this.code,
    required this.url,
    this.isAnimated = false,
  });

  final String code;
  final String url;
  final bool isAnimated;
}

/// A text or emote segment in display order.
class TwitchMessagePart {
  const TwitchMessagePart.text(this.text) : emote = null;
  const TwitchMessagePart.emote(TwitchEmote this.emote) : text = '';

  final String text;
  final TwitchEmote? emote;
  bool get isEmote => emote != null;
}

/// Twitch author information available without authentication.
class TwitchAuthor {
  const TwitchAuthor({
    required this.name,
    required this.login,
    required this.badges,
    this.color,
    required this.isOwner,
    required this.isModerator,
    required this.isSubscriber,
    required this.isVip,
  });

  final String name;
  final String login;
  final String? color;
  final List<TwitchBadge> badges;
  final bool isOwner;
  final bool isModerator;
  final bool isSubscriber;
  final bool isVip;
}

enum TwitchMembershipKind { subscription, resubscription, gift }

/// Strongly typed anonymous Twitch chat message.
class TwitchChatMessage {
  const TwitchChatMessage({
    required this.id,
    required this.author,
    required this.parts,
    required this.timestamp,
    required this.rawTags,
    required this.raw,
    this.isMembershipEvent = false,
    this.membershipKind,
    this.membershipMonths,
  });

  final String id;
  final TwitchAuthor author;
  final List<TwitchMessagePart> parts;
  final DateTime timestamp;
  final Map<String, String> rawTags;
  final String raw;
  final bool isMembershipEvent;
  final TwitchMembershipKind? membershipKind;
  final int? membershipMonths;

  String get plainText =>
      parts.map((part) => part.isEmote ? part.emote!.code : part.text).join();
}

enum TwitchConnectionState { idle, connecting, connected, error }

class TwitchConnectionUpdate {
  const TwitchConnectionUpdate(this.state, [this.error]);

  final TwitchConnectionState state;
  final Object? error;
}

enum TwitchFailureScope { connection, emotes }

class TwitchFailure {
  const TwitchFailure({
    required this.scope,
    required this.error,
    required this.stackTrace,
  });

  final TwitchFailureScope scope;
  final Object error;
  final StackTrace stackTrace;
}
