import 'models.dart';

/// A lossless IRC message received from Twitch.
class TwitchIrcFrame {
  const TwitchIrcFrame(
      {required this.raw,
      required this.tags,
      required this.prefix,
      required this.command,
      required this.parameters,
      required this.trailing});
  final String raw;
  final Map<String, String> tags;
  final String? prefix;
  final String command;
  final List<String> parameters;
  final String? trailing;

  String? get channel {
    for (final parameter in parameters) {
      if (parameter.startsWith('#')) return parameter.substring(1);
    }
    return null;
  }

  String? get username {
    final value = prefix;
    if (value == null || value.isEmpty || !value.contains('!')) return null;
    return value.split('!').first;
  }
}

/// Base type for every event emitted by [TwitchChatClient].
sealed class TwitchEvent {
  const TwitchEvent(this.frame);
  final TwitchIrcFrame frame;
}

final class TwitchMessageEvent extends TwitchEvent {
  const TwitchMessageEvent(super.frame, this.message);
  final TwitchChatMessage message;
}

final class TwitchUserNoticeEvent extends TwitchEvent {
  const TwitchUserNoticeEvent(super.frame, this.notice);
  final TwitchUserNotice notice;
}

final class TwitchClearMessageEvent extends TwitchEvent {
  const TwitchClearMessageEvent(super.frame,
      {required this.targetMessageId,
      required this.login,
      required this.message,
      required this.roomId,
      required this.timestamp});
  final String targetMessageId;
  final String? login;
  final String? message;
  final String? roomId;
  final DateTime? timestamp;
}

final class TwitchClearChatEvent extends TwitchEvent {
  const TwitchClearChatEvent(super.frame,
      {required this.login,
      required this.targetUserId,
      required this.roomId,
      required this.banDuration,
      required this.timestamp});
  final String? login;
  final String? targetUserId;
  final String? roomId;
  final Duration? banDuration;
  final DateTime? timestamp;
  bool get clearsEntireRoom => login == null || login!.isEmpty;
  bool get isTimeout => banDuration != null;
  bool get isPermanentBan => !clearsEntireRoom && banDuration == null;
}

final class TwitchRoomStateEvent extends TwitchEvent {
  const TwitchRoomStateEvent(super.frame,
      {required this.roomId,
      required this.emoteOnly,
      required this.followersOnlyMinutes,
      required this.uniqueChat,
      required this.slowModeSeconds,
      required this.subscribersOnly});
  final String? roomId;
  final bool? emoteOnly;
  final int? followersOnlyMinutes;
  final bool? uniqueChat;
  final int? slowModeSeconds;
  final bool? subscribersOnly;
}

final class TwitchNoticeEvent extends TwitchEvent {
  const TwitchNoticeEvent(super.frame,
      {required this.messageId,
      required this.targetUserId,
      required this.message});
  final String? messageId;
  final String? targetUserId;
  final String message;
}

final class TwitchReconnectEvent extends TwitchEvent {
  const TwitchReconnectEvent(super.frame);
}

final class TwitchCapabilityEvent extends TwitchEvent {
  const TwitchCapabilityEvent(super.frame,
      {required this.acknowledged, required this.capabilities});
  final bool acknowledged;
  final List<String> capabilities;
}

final class TwitchUserStateEvent extends TwitchEvent {
  const TwitchUserStateEvent(super.frame, {required this.global});
  final bool global;
}

final class TwitchJoinEvent extends TwitchEvent {
  const TwitchJoinEvent(super.frame, {required this.channel});
  final String channel;
}

final class TwitchPartEvent extends TwitchEvent {
  const TwitchPartEvent(super.frame, {required this.channel});
  final String channel;
}

final class TwitchNumericEvent extends TwitchEvent {
  const TwitchNumericEvent(super.frame, {required this.code});
  final int code;
}

/// A syntactically valid command not yet represented by a specialized event.
final class TwitchRawEvent extends TwitchEvent {
  const TwitchRawEvent(super.frame);
}
