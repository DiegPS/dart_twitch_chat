import 'dart:async';

import 'package:dart_twitch_chat/dart_twitch_chat.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('connects anonymously and joins a normalized channel', () async {
    final socket = _FakeSocket();
    final client = _client((_) => socket);
    addTearDown(client.dispose);

    await client.connect('#MyChannel');

    expect(socket.sent[0], 'CAP REQ :twitch.tv/tags twitch.tv/commands\r\n');
    expect(socket.sent[1], 'PASS oauth:anonymous\r\n');
    expect(socket.sent[2], matches(RegExp(r'^NICK justinfan\d+\r\n$')));
    expect(socket.sent[3], 'JOIN #mychannel\r\n');
    expect(client.channel, 'mychannel');
  });

  test('answers PING and emits parsed messages', () async {
    final socket = _FakeSocket();
    final client = _client((_) => socket);
    addTearDown(client.dispose);
    await client.connect('channel');
    final messageFuture = client.messages.first;

    socket.receive('PING :tmi.twitch.tv\r\n');
    socket.receive(
      '@badges=vip/1;display-name=Ana;id=m1 :ana!u@h PRIVMSG #channel :Hola\r\n',
    );

    final message = await messageFuture.timeout(const Duration(seconds: 1));
    expect(socket.sent, contains('PONG :tmi.twitch.tv\r\n'));
    expect(message.id, 'm1');
    expect(message.author.isVip, isTrue);
    expect(message.plainText, 'Hola');
  });

  test('closes a socket that never becomes ready', () async {
    final socket = _FakeSocket(ready: Completer<void>().future);
    final client = _client(
      (_) => socket,
      connectionTimeout: const Duration(milliseconds: 5),
    );
    addTearDown(client.dispose);

    await expectLater(
        client.connect('channel'), throwsA(isA<TimeoutException>()));
    expect(socket.closed, isTrue);
  });

  test('reconnects once after remote close without duplicate joins', () async {
    final sockets = <_FakeSocket>[];
    final client = _client((_) {
      final socket = _FakeSocket();
      sockets.add(socket);
      return socket;
    });
    addTearDown(client.dispose);
    await client.connect('channel');

    await sockets.single.remoteClose();
    await _eventually(() => sockets.length == 2);

    expect(sockets.last.sent.where((line) => line.startsWith('JOIN ')),
        hasLength(1));
  });

  test('disconnect prevents reconnect and closes resources', () async {
    final sockets = <_FakeSocket>[];
    final client = _client((_) {
      final socket = _FakeSocket();
      sockets.add(socket);
      return socket;
    });
    addTearDown(client.dispose);
    await client.connect('channel');

    await client.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(sockets, hasLength(1));
    expect(sockets.single.closed, isTrue);
  });

  test('reports optional emote failures without failing chat connection',
      () async {
    final socket = _FakeSocket();
    final client = TwitchChatClient(
      socketFactory: (_) => socket,
      httpClient: MockClient((_) async => http.Response('bad', 503)),
      optionalApiTimeout: const Duration(milliseconds: 10),
    );
    addTearDown(client.dispose);
    final failures = <TwitchFailure>[];
    final sub = client.failures.listen(failures.add);
    addTearDown(sub.cancel);

    await client.connect('channel');
    await _eventually(() => failures.length == 3);

    expect(
        failures.every((failure) => failure.scope == TwitchFailureScope.emotes),
        isTrue);
  });
}

TwitchChatClient _client(
  TwitchSocketFactory factory, {
  Duration connectionTimeout = const Duration(seconds: 1),
}) =>
    TwitchChatClient(
      socketFactory: factory,
      httpClient: _emptyEmoteClient(),
      reconnectDelay: const Duration(milliseconds: 1),
      connectionTimeout: connectionTimeout,
    );

MockClient _emptyEmoteClient() => MockClient((request) async {
      if (request.url.host == 'api.frankerfacez.com') {
        return http.Response('{"sets":{}}', 200);
      }
      if (request.url.host == '7tv.io') {
        return http.Response('{"emotes":[]}', 200);
      }
      return http.Response('[]', 200);
    });

Future<void> _eventually(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('Condition was not reached.');
}

class _FakeSocket implements TwitchSocket {
  _FakeSocket({Future<void>? ready}) : _ready = ready ?? Future<void>.value();

  final Future<void> _ready;
  final controller = StreamController<dynamic>();
  final sent = <String>[];
  bool closed = false;

  @override
  Future<void> get ready => _ready;

  @override
  Stream<dynamic> get stream => controller.stream;

  @override
  void add(String data) => sent.add(data);

  void receive(String data) => controller.add(data);

  Future<void> remoteClose() => controller.close();

  @override
  Future<void> close() async {
    closed = true;
    if (!controller.isClosed) unawaited(controller.close());
  }
}
