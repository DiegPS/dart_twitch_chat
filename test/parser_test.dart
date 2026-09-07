import 'package:dart_twitch_chat/dart_twitch_chat.dart';
import 'package:test/test.dart';

void main() {
  group('TwitchIrcParser', () {
    test('parses PRIVMSG and unescapes tags', () {
      final event = TwitchIrcParser.parse(
        r'@badges=vip/1;display-name=Ana\sMaría;system-msg=hola\smundo\:x\\y\nfin :ana!ana@host PRIVMSG #canal :Hola chat',
      );

      expect(event?.type, TwitchIrcEventType.message);
      expect(event?.username, 'ana');
      expect(event?.text, 'Hola chat');
      expect(event?.tags['display-name'], 'Ana María');
      expect(event?.tags['system-msg'], 'hola mundo;x\\y\nfin');
      expect(event?.raw, contains('PRIVMSG'));
    });

    test('recognizes all supported membership notices', () {
      for (final notice in const ['sub', 'resub', 'subgift', 'anonsubgift']) {
        final event = TwitchIrcParser.parse(
          '@msg-id=$notice;login=member :tmi.twitch.tv USERNOTICE #c :text',
        );
        expect(event?.type, TwitchIrcEventType.membership, reason: notice);
        expect(event?.username, 'member', reason: notice);
      }
    });

    test('ignores unsupported and malformed frames', () {
      expect(TwitchIrcParser.parse(''), isNull);
      expect(TwitchIrcParser.parse('@broken'), isNull);
      expect(TwitchIrcParser.parse(':server NOTICE #c :text'), isNull);
      expect(
        TwitchIrcParser.parse(
          '@msg-id=raid :tmi.twitch.tv USERNOTICE #c :raid',
        ),
        isNull,
      );
    });
  });

  group('TwitchMessageParser', () {
    test('maps identity, roles, badges, membership and raw data', () {
      final event = TwitchIrcParser.parse(
        '@badges=broadcaster/1,subscriber/24,bits/1000;color=#00FF00;'
        'display-name=Streamer;id=message-1;login=streamer;mod=1;msg-id=resub;'
        'msg-param-cumulative-months=12;subscriber=1 '
        ':streamer!user@host USERNOTICE #channel :Un año',
      )!;
      final timestamp = DateTime.utc(2026, 1, 2, 3, 4, 5);

      final message = TwitchMessageParser.fromEvent(
        event,
        receivedAt: timestamp,
      );

      expect(message.id, 'message-1');
      expect(message.author.name, 'Streamer');
      expect(message.author.login, 'streamer');
      expect(message.author.color, '#00FF00');
      expect(message.author.isOwner, isTrue);
      expect(message.author.isModerator, isTrue);
      expect(message.author.isSubscriber, isTrue);
      expect(message.author.badges.map((badge) => badge.kind),
          ['broadcaster', 'subscriber', 'bits']);
      expect(message.author.badges.last.label, 'Bits 1000');
      expect(message.membershipKind, TwitchMembershipKind.resubscription);
      expect(message.membershipMonths, 12);
      expect(message.timestamp, timestamp);
      expect(message.rawTags['msg-id'], 'resub');
      expect(message.raw, contains('USERNOTICE'));
    });

    test('preserves Unicode ranges and full third-party tokens', () {
      final parts = TwitchMessageParser.parseContent(
        '😀 Kappa! OMEGALUL OMEGALULx',
        nativeEmotesTag: '25:2-6',
        thirdPartyEmotes: const {
          'OMEGALUL': TwitchEmote(
            code: 'OMEGALUL',
            url: 'https://cdn.example/omegalul.webp',
          ),
        },
      );

      expect(
        parts.map((part) => part.isEmote ? part.emote!.code : part.text).join(),
        '😀 Kappa! OMEGALUL OMEGALULx',
      );
      expect(
        parts.where((part) => part.isEmote).map((part) => part.emote!.code),
        ['Kappa', 'OMEGALUL'],
      );
    });

    test('skips malformed or overlapping native ranges safely', () {
      final parts = TwitchMessageParser.parseContent(
        'Kappa hello',
        nativeEmotesTag: 'bad/25:x-y/25:0-4,2-20',
      );
      expect(parts.where((part) => part.isEmote), hasLength(1));
      expect(parts.first.emote?.code, 'Kappa');
      expect(
          parts
              .map((part) => part.isEmote ? part.emote!.code : part.text)
              .join(),
          'Kappa hello');
    });
  });

  test('TwitchUserRoles supports legacy flags and founder badges', () {
    final roles = TwitchUserRoles.fromTags(const {
      'badges': 'moderator/1,vip/1,founder/0',
      'mod': '1',
      'subscriber': '0',
    });
    expect(roles.isModerator, isTrue);
    expect(roles.isVip, isTrue);
    expect(roles.isSubscriber, isTrue);
    expect(roles.badges['founder'], '0');
  });
}
