import 'dart:async';

import 'package:dart_twitch_chat/dart_twitch_chat.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('loads and normalizes BTTV, FFZ and 7TV global emotes', () async {
    final loader = TwitchGlobalEmoteLoader(
      httpClient: MockClient((request) async {
        return switch (request.url.host) {
          'api.betterttv.net' => http.Response(
              '[{"id":"b1","code":"OMEGALUL","imageType":"gif"}]',
              200,
            ),
          'api.frankerfacez.com' => http.Response(
              '{"sets":{"1":{"emoticons":[{"name":"Pog","urls":{"1":"//ffz/pog.png"}}]}}}',
              200,
            ),
          '7tv.io' => http.Response(
              '{"emotes":[{"name":"AYAYA","data":{"animated":true,"host":{"url":"//7tv/host","files":[{"name":"1x.webp"}]}}}]}',
              200,
            ),
          _ => http.Response('', 404),
        };
      }),
    );

    final emotes = await loader.load();

    expect(emotes.keys, containsAll(['OMEGALUL', 'Pog', 'AYAYA']));
    expect(emotes['OMEGALUL']?.url, 'https://cdn.betterttv.net/emote/b1/1x');
    expect(emotes['OMEGALUL']?.isAnimated, isTrue);
    expect(emotes['Pog']?.url, 'https://ffz/pog.png');
    expect(emotes['AYAYA']?.url, 'https://7tv/host/1x.webp');
    expect(emotes['AYAYA']?.isAnimated, isTrue);
  });

  test('one failed optional provider does not discard other emotes', () async {
    final errors = <Object>[];
    final loader = TwitchGlobalEmoteLoader(
      httpClient: MockClient((request) async {
        if (request.url.host == 'api.betterttv.net') {
          return http.Response('unavailable', 503);
        }
        if (request.url.host == 'api.frankerfacez.com') {
          return http.Response('{"sets":{}}', 200);
        }
        return http.Response(
          '{"emotes":[{"name":"Okay","data":{"host":{"url":"//7tv/h","files":[{"name":"1x.webp"}]}}}]}',
          200,
        );
      }),
    );

    final emotes = await loader.load(onError: (error, _) => errors.add(error));

    expect(errors.single, isA<TwitchEmoteHttpException>());
    expect(emotes, contains('Okay'));
  });

  test('loads BTTV, FFZ and 7TV channel emotes anonymously', () async {
    final requested = <Uri>[];
    final loader = TwitchGlobalEmoteLoader(
      httpClient: MockClient((request) async {
        requested.add(request.url);
        if (request.url.host == 'api.betterttv.net') {
          return http.Response(
            '{"channelEmotes":[{"id":"b1","code":"ChannelBTTV","imageType":"png"}],'
            '"sharedEmotes":[{"id":"b2","code":"SharedBTTV","imageType":"gif"}]}',
            200,
          );
        }
        if (request.url.host == 'api.frankerfacez.com') {
          return http.Response(
            '{"sets":{"1":{"emoticons":[{"name":"ChannelFFZ",'
            '"urls":{"1":"//cdn.ffz/one"},"animated":{"1":"//cdn.ffz/a"}}]}}}',
            200,
          );
        }
        return http.Response(
          '{"emote_set":{"emotes":[{"id":"s1","name":"Channel7TV",'
          '"data":{"host":{"url":"//cdn.7tv/set",'
          '"files":[{"name":"1x.webp"}]}}}]}}',
          200,
        );
      }),
    );

    final emotes = await loader.loadChannel(
      channelName: 'SomeStreamer',
      channelId: '1234',
    );

    expect(
        emotes.keys,
        containsAll(
          ['ChannelBTTV', 'SharedBTTV', 'ChannelFFZ', 'Channel7TV'],
        ));
    expect(emotes['SharedBTTV']?.isAnimated, isTrue);
    expect(emotes['ChannelFFZ']?.url, 'https://cdn.ffz/a');
    expect(
      requested.map((uri) => uri.toString()),
      containsAll([
        'https://api.betterttv.net/3/cached/users/twitch/1234',
        'https://api.frankerfacez.com/v1/room/SomeStreamer',
        'https://7tv.io/v3/users/twitch/1234',
      ]),
    );
  });

  test('times out an unresponsive provider without hanging all results',
      () async {
    final errors = <Object>[];
    final loader = TwitchGlobalEmoteLoader(
      httpClient: MockClient((request) async {
        if (request.url.host == 'api.betterttv.net') {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        return request.url.host == 'api.frankerfacez.com'
            ? http.Response('{"sets":{}}', 200)
            : http.Response('{"emotes":[]}', 200);
      }),
      timeout: const Duration(milliseconds: 5),
    );

    await loader.load(onError: (error, _) => errors.add(error));

    expect(errors.single, isA<TimeoutException>());
  });
}
