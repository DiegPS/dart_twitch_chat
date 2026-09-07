import 'package:dart_twitch_chat/dart_twitch_chat.dart';
import 'package:test/test.dart';

void main() {
  group('lossless IRC framing', () {
    test('preserves prefix, parameters, trailing spaces and unknown tags', () {
      final frame = TwitchIrcParser.parseFrame(
        '@unknown=value;flag :server FUTURE #Channel parameter :  text  \r\n',
      )!;

      expect(frame.tags, {'unknown': 'value', 'flag': ''});
      expect(frame.prefix, 'server');
      expect(frame.command, 'FUTURE');
      expect(frame.parameters, ['#Channel', 'parameter']);
      expect(frame.channel, 'Channel');
      expect(frame.trailing, '  text  ');
      expect(TwitchEventParser.parse(frame), isA<TwitchRawEvent>());
    });

    test('retains numeric replies instead of dropping them', () {
      final event = _event(':tmi.twitch.tv 001 nick :Welcome, GLHF!');
      expect(event, isA<TwitchNumericEvent>());
      expect((event as TwitchNumericEvent).code, 1);
    });
  });

  group('rich PRIVMSG', () {
    test('models timestamps, author identity, bits and chatter state', () {
      final event = _event(
        '@badge-info=subscriber/30;badges=vip/1,subscriber/24;bits=100;'
        'client-nonce=nonce;color=#123456;display-name=Ana;first-msg=1;'
        'custom-reward-id=reward-42;flags=0-2:S.7;id=m1;mod=0;'
        'returning-chatter=1;room-id=r1;'
        'subscriber=1;tmi-sent-ts=1760000000123;turbo=0;user-id=u1;'
        'user-type=staff;vip=1 :ana!ana@host PRIVMSG #channel :cheer100',
      ) as TwitchMessageEvent;

      final message = event.message;
      expect(message.timestamp,
          DateTime.fromMillisecondsSinceEpoch(1760000000123, isUtc: true));
      expect(message.roomId, 'r1');
      expect(message.customRewardId, 'reward-42');
      expect(message.clientNonce, 'nonce');
      expect(message.flags, '0-2:S.7');
      expect(message.bits, 100);
      expect(message.isFirstMessage, isTrue);
      expect(message.isReturningChatter, isTrue);
      expect(message.author.id, 'u1');
      expect(message.author.userType, 'staff');
      expect(message.author.isVip, isTrue);
      expect(message.author.badges.last.info, '30');
    });

    test('models complete reply and Shared Chat origin', () {
      final message = (_event(
        '@id=duplicate;reply-parent-msg-id=parent;reply-parent-user-id=pu;'
        'reply-parent-user-login=parent_login;reply-parent-display-name=Parent;'
        'reply-parent-msg-body=Original;reply-thread-parent-msg-id=root;'
        'reply-thread-parent-user-login=root_login;source-id=source-message;'
        'source-room-id=source-room;source-badges=vip/1;'
        'source-badge-info=subscriber/5;source-only=1 '
        ':ana!ana@host PRIVMSG #target :Reply',
      ) as TwitchMessageEvent)
          .message;

      expect(message.reply?.parentMessageId, 'parent');
      expect(message.reply?.parentUserId, 'pu');
      expect(message.reply?.parentMessageBody, 'Original');
      expect(message.reply?.threadParentMessageId, 'root');
      expect(message.sharedChatSource?.messageId, 'source-message');
      expect(message.sharedChatSource?.roomId, 'source-room');
      expect(message.sharedChatSource?.badges['vip'], '1');
      expect(message.sharedChatSource?.badgeInfo['subscriber'], '5');
      expect(message.sharedChatSource?.sourceOnly, isTrue);
    });

    test('renders Twitch GIF using its exact provider URL', () {
      const url = 'https://media.example/giphy.gif?one=1&two=2';
      final message = (_event(
        '@gifs=0-4|gif-id|$url;id=gif-message '
        ':ana!ana@host PRIVMSG #channel :[GIF]',
      ) as TwitchMessageEvent)
          .message;

      expect(message.parts.single.isGif, isTrue);
      expect(message.parts.single.gif?.id, 'gif-id');
      expect(message.parts.single.gif?.url, url);
      expect(message.parts.single.gif?.alt, '[GIF]');
      expect(message.plainText, '[GIF]');
    });

    test('removes ACTION framing and keeps emote ranges aligned', () {
      final message = (_event(
        '@emotes=25:0-4;id=action '
        ':ana!ana@host PRIVMSG #channel :\u0001ACTION Kappa waves\u0001',
      ) as TwitchMessageEvent)
          .message;

      expect(message.isAction, isTrue);
      expect(message.plainText, 'Kappa waves');
      expect(message.parts.first.emote?.code, 'Kappa');
    });
  });

  group('USERNOTICE', () {
    const kinds = {
      'sub': TwitchUserNoticeKind.subscription,
      'resub': TwitchUserNoticeKind.resubscription,
      'subgift': TwitchUserNoticeKind.subscriptionGift,
      'anonsubgift': TwitchUserNoticeKind.subscriptionGift,
      'submysterygift': TwitchUserNoticeKind.communitySubscriptionGift,
      'giftpaidupgrade': TwitchUserNoticeKind.giftPaidUpgrade,
      'rewardgift': TwitchUserNoticeKind.rewardGift,
      'anongiftpaidupgrade': TwitchUserNoticeKind.anonymousGiftPaidUpgrade,
      'raid': TwitchUserNoticeKind.raid,
      'unraid': TwitchUserNoticeKind.unraid,
      'bitsbadgetier': TwitchUserNoticeKind.bitsBadgeTier,
      'sharedchatnotice': TwitchUserNoticeKind.sharedChatNotice,
      'modiversary': TwitchUserNoticeKind.modiversary,
      'viewermilestone': TwitchUserNoticeKind.viewerMilestone,
    };

    test('types every documented notice and preserves future parameters', () {
      for (final entry in kinds.entries) {
        final event = _event(
          '@id=${entry.key};login=ana;msg-id=${entry.key};'
          'msg-param-future=value;system-msg=System\\smessage '
          ':tmi.twitch.tv USERNOTICE #channel :Text',
        ) as TwitchUserNoticeEvent;
        expect(event.notice.kind, entry.value, reason: entry.key);
        expect(event.notice.parameters['future'], 'value', reason: entry.key);
        expect(event.notice.systemMessage, 'System message');
      }
    });

    test('models subscription, gift, raid and milestone parameters', () {
      final notice = (_event(
        '@id=n1;login=gifter;msg-id=subgift;msg-param-cumulative-months=12;'
        'msg-param-streak-months=4;msg-param-months=12;'
        'msg-param-gift-months=3;msg-param-sub-plan=2000;'
        'msg-param-sub-plan-name=Tier\\s2;'
        'msg-param-recipient-display-name=Receiver;'
        'msg-param-recipient-id=recipient-id;'
        'msg-param-recipient-user-name=receiver;'
        'msg-param-sender-login=sender;msg-param-sender-name=Sender;'
        'msg-param-viewerCount=42;msg-param-threshold=1000;'
        'msg-param-promo-name=Subtember;msg-param-promo-gift-total=8;'
        'msg-param-category=watch-streak;msg-param-id=milestone-id;'
        'msg-param-value=5;msg-param-should-share-streak=1;'
        'room-id=room;tmi-sent-ts=1760000000123 '
        ':tmi.twitch.tv USERNOTICE #channel :Gift',
      ) as TwitchUserNoticeEvent)
          .notice;

      expect(notice.cumulativeMonths, 12);
      expect(notice.streakMonths, 4);
      expect(notice.months, 12);
      expect(notice.giftMonths, 3);
      expect(notice.subscriptionPlan, '2000');
      expect(notice.subscriptionPlanName, 'Tier 2');
      expect(notice.recipientDisplayName, 'Receiver');
      expect(notice.recipientId, 'recipient-id');
      expect(notice.recipientLogin, 'receiver');
      expect(notice.senderLogin, 'sender');
      expect(notice.senderName, 'Sender');
      expect(notice.viewerCount, 42);
      expect(notice.bitsThreshold, 1000);
      expect(notice.promotionName, 'Subtember');
      expect(notice.promotionGiftTotal, 8);
      expect(notice.milestoneCategory, 'watch-streak');
      expect(notice.milestoneId, 'milestone-id');
      expect(notice.milestoneValue, 5);
      expect(notice.shouldShareStreak, isTrue);
    });

    test('uses unknown fallback instead of dropping a future notice', () {
      final notice = (_event(
        '@msg-id=future-event;msg-param-new-data=42 '
        ':tmi.twitch.tv USERNOTICE #channel :Future',
      ) as TwitchUserNoticeEvent)
          .notice;
      expect(notice.kind, TwitchUserNoticeKind.unknown);
      expect(notice.messageType, 'future-event');
      expect(notice.parameters['new-data'], '42');
    });
  });

  group('commands', () {
    test('models CLEARMSG', () {
      final event = _event(
        '@login=ana;room-id=room;target-msg-id=message;'
        'tmi-sent-ts=1760000000123 :tmi.twitch.tv CLEARMSG #channel :text',
      ) as TwitchClearMessageEvent;
      expect(event.targetMessageId, 'message');
      expect(event.login, 'ana');
      expect(event.message, 'text');
      expect(event.roomId, 'room');
      expect(event.timestamp, isNotNull);
    });

    test('distinguishes room clear, timeout and permanent ban', () {
      final clear = _event('@room-id=r :tmi.twitch.tv CLEARCHAT #channel')
          as TwitchClearChatEvent;
      final timeout = _event(
        '@ban-duration=350;target-user-id=u :tmi.twitch.tv CLEARCHAT #channel :ana',
      ) as TwitchClearChatEvent;
      final ban = _event(
        '@target-user-id=u :tmi.twitch.tv CLEARCHAT #channel :ana',
      ) as TwitchClearChatEvent;
      expect(clear.clearsEntireRoom, isTrue);
      expect(timeout.isTimeout, isTrue);
      expect(timeout.banDuration, const Duration(seconds: 350));
      expect(ban.isPermanentBan, isTrue);
    });

    test('models partial ROOMSTATE updates', () {
      final event = _event(
        '@emote-only=1;followers-only=10;r9k=0;room-id=r;slow=5;'
        'subs-only=1 :tmi.twitch.tv ROOMSTATE #channel',
      ) as TwitchRoomStateEvent;
      expect(event.emoteOnly, isTrue);
      expect(event.followersOnlyMinutes, 10);
      expect(event.uniqueChat, isFalse);
      expect(event.slowModeSeconds, 5);
      expect(event.subscribersOnly, isTrue);
    });

    test('models NOTICE, CAP, state, join, part and reconnect', () {
      expect(_event('@msg-id=x :tmi.twitch.tv NOTICE #c :problem'),
          isA<TwitchNoticeEvent>());
      final cap =
          _event(':tmi.twitch.tv CAP * ACK :twitch.tv/tags twitch.tv/commands')
              as TwitchCapabilityEvent;
      expect(cap.acknowledged, isTrue);
      expect(cap.capabilities, ['twitch.tv/tags', 'twitch.tv/commands']);
      expect(_event('@badges= :tmi.twitch.tv USERSTATE #c'),
          isA<TwitchUserStateEvent>());
      expect(_event(':nick!u@h JOIN #c'), isA<TwitchJoinEvent>());
      expect(_event(':nick!u@h PART #c'), isA<TwitchPartEvent>());
      expect(_event(':tmi.twitch.tv RECONNECT'), isA<TwitchReconnectEvent>());
    });
  });
}

TwitchEvent _event(String raw) =>
    TwitchEventParser.parse(TwitchIrcParser.parseFrame(raw)!);
