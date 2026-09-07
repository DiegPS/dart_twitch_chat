enum TwitchIrcEventType { message, membership }

class TwitchIrcEvent {
  const TwitchIrcEvent(
      {required this.type,
      required this.tags,
      required this.username,
      required this.text,
      required this.raw});
  final TwitchIrcEventType type;
  final Map<String, String> tags;
  final String username;
  final String text;
  final String raw;
}

class TwitchUserRoles {
  const TwitchUserRoles(
      {required this.badges,
      required this.isOwner,
      required this.isModerator,
      required this.isSubscriber,
      required this.isVip});
  factory TwitchUserRoles.fromTags(Map<String, String> tags,
      {bool membershipEvent = false}) {
    final badges = parseBadgeMap(tags['badges']);
    return TwitchUserRoles(
      badges: badges,
      isOwner: badges.containsKey('broadcaster'),
      isModerator: tags['mod'] == '1' || badges.containsKey('moderator'),
      isSubscriber: tags['subscriber'] == '1' ||
          badges.containsKey('subscriber') ||
          badges.containsKey('founder') ||
          membershipEvent,
      isVip: tags['vip'] == '1' || badges.containsKey('vip'),
    );
  }
  final Map<String, String> badges;
  final bool isOwner;
  final bool isModerator;
  final bool isSubscriber;
  final bool isVip;
}

Map<String, String> parseBadgeMap(String? source) {
  final badges = <String, String>{};
  for (final badge in (source ?? '').split(',')) {
    final separator = badge.indexOf('/');
    if (separator <= 0) continue;
    badges[badge.substring(0, separator).toLowerCase()] =
        badge.substring(separator + 1);
  }
  return Map.unmodifiable(badges);
}

class TwitchBadge {
  const TwitchBadge(
      {required this.kind,
      required this.version,
      required this.label,
      this.info});
  final String kind;
  final String version;
  final String label;
  final String? info;
}

class TwitchEmote {
  const TwitchEmote(
      {required this.code, required this.url, this.isAnimated = false});
  final String code;
  final String url;
  final bool isAnimated;
}

class TwitchGif {
  const TwitchGif({required this.id, required this.url, required this.alt});
  final String id;
  final String url;
  final String alt;
}

class TwitchMessagePart {
  const TwitchMessagePart.text(this.text)
      : emote = null,
        gif = null;
  const TwitchMessagePart.emote(TwitchEmote this.emote)
      : text = '',
        gif = null;
  const TwitchMessagePart.gif(TwitchGif this.gif)
      : text = '',
        emote = null;
  final String text;
  final TwitchEmote? emote;
  final TwitchGif? gif;
  bool get isEmote => emote != null;
  bool get isGif => gif != null;
}

class TwitchAuthor {
  const TwitchAuthor(
      {required this.name,
      required this.login,
      required this.badges,
      this.id,
      this.color,
      this.userType,
      required this.isOwner,
      required this.isModerator,
      required this.isSubscriber,
      required this.isVip});
  final String name;
  final String login;
  final String? id;
  final String? color;
  final String? userType;
  final List<TwitchBadge> badges;
  final bool isOwner;
  final bool isModerator;
  final bool isSubscriber;
  final bool isVip;
}

class TwitchReply {
  const TwitchReply(
      {required this.parentMessageId,
      this.parentUserId,
      this.parentUserLogin,
      this.parentDisplayName,
      this.parentMessageBody,
      this.threadParentMessageId,
      this.threadParentUserLogin});
  final String parentMessageId;
  final String? parentUserId;
  final String? parentUserLogin;
  final String? parentDisplayName;
  final String? parentMessageBody;
  final String? threadParentMessageId;
  final String? threadParentUserLogin;
}

class TwitchSharedChatSource {
  const TwitchSharedChatSource(
      {this.messageId,
      this.roomId,
      this.badges = const {},
      this.badgeInfo = const {},
      this.messageType,
      this.sourceOnly = false});
  final String? messageId;
  final String? roomId;
  final Map<String, String> badges;
  final Map<String, String> badgeInfo;
  final String? messageType;
  final bool sourceOnly;
}

enum TwitchMembershipKind { subscription, resubscription, gift }

class TwitchChatMessage {
  const TwitchChatMessage(
      {required this.id,
      required this.author,
      required this.parts,
      required this.timestamp,
      required this.rawTags,
      required this.raw,
      this.roomId,
      this.clientNonce,
      this.flags,
      this.bits,
      this.isFirstMessage = false,
      this.isReturningChatter = false,
      this.isAction = false,
      this.reply,
      this.sharedChatSource,
      this.isMembershipEvent = false,
      this.membershipKind,
      this.membershipMonths});
  final String id;
  final TwitchAuthor author;
  final List<TwitchMessagePart> parts;
  final DateTime timestamp;
  final Map<String, String> rawTags;
  final String raw;
  final String? roomId;
  final String? clientNonce;
  final String? flags;
  final int? bits;
  final bool isFirstMessage;
  final bool isReturningChatter;
  final bool isAction;
  final TwitchReply? reply;
  final TwitchSharedChatSource? sharedChatSource;
  final bool isMembershipEvent;
  final TwitchMembershipKind? membershipKind;
  final int? membershipMonths;
  String get plainText => parts
      .map((part) => part.isEmote
          ? part.emote!.code
          : part.isGif
              ? part.gif!.alt
              : part.text)
      .join();
}

enum TwitchUserNoticeKind {
  subscription,
  resubscription,
  subscriptionGift,
  communitySubscriptionGift,
  giftPaidUpgrade,
  rewardGift,
  anonymousGiftPaidUpgrade,
  raid,
  unraid,
  bitsBadgeTier,
  sharedChatNotice,
  modiversary,
  viewerMilestone,
  unknown
}

class TwitchUserNotice {
  const TwitchUserNotice(
      {required this.kind,
      required this.messageType,
      required this.message,
      required this.systemMessage,
      required this.parameters,
      required this.timestamp,
      required this.roomId,
      required this.source,
      this.cumulativeMonths,
      this.streakMonths,
      this.months,
      this.giftMonths,
      this.subscriptionPlan,
      this.subscriptionPlanName,
      this.recipientDisplayName,
      this.recipientId,
      this.recipientLogin,
      this.senderLogin,
      this.senderName,
      this.viewerCount,
      this.bitsThreshold,
      this.promotionName,
      this.promotionGiftTotal,
      this.milestoneCategory,
      this.milestoneId,
      this.milestoneValue,
      this.shouldShareStreak});
  final TwitchUserNoticeKind kind;
  final String messageType;
  final TwitchChatMessage message;
  final String? systemMessage;
  final Map<String, String> parameters;
  final DateTime timestamp;
  final String? roomId;
  final TwitchSharedChatSource? source;
  final int? cumulativeMonths;
  final int? streakMonths;
  final int? months;
  final int? giftMonths;
  final String? subscriptionPlan;
  final String? subscriptionPlanName;
  final String? recipientDisplayName;
  final String? recipientId;
  final String? recipientLogin;
  final String? senderLogin;
  final String? senderName;
  final int? viewerCount;
  final int? bitsThreshold;
  final String? promotionName;
  final int? promotionGiftTotal;
  final String? milestoneCategory;
  final String? milestoneId;
  final int? milestoneValue;
  final bool? shouldShareStreak;
}

enum TwitchConnectionState { idle, connecting, connected, error }

class TwitchConnectionUpdate {
  const TwitchConnectionUpdate(this.state, [this.error]);
  final TwitchConnectionState state;
  final Object? error;
}

enum TwitchFailureScope { connection, protocol, emotes }

class TwitchFailure {
  const TwitchFailure(
      {required this.scope, required this.error, required this.stackTrace});
  final TwitchFailureScope scope;
  final Object error;
  final StackTrace stackTrace;
}
