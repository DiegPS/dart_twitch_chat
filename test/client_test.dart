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

  test('echoes the exact PING payload', () async {
    final socket = _FakeSocket();
    final client = _client((_) => socket);
    addTearDown(client.dispose);
    await client.connect('channel');

    socket.receive('PING :provider-specific-value\r\n');
    await _eventually(
      () => socket.sent.contains('PONG :provider-specific-value\r\n'),
    );
  });

  test('reports connected only after Twitch confirms the joined room',
      () async {
    final socket = _FakeSocket();
    final client = _client((_) => socket);
    addTearDown(client.dispose);
    final states = <TwitchConnectionState>[];
    final subscription = client.connections.listen((event) {
      states.add(event.state);
    });
    addTearDown(subscription.cancel);

    await client.connect('channel');
    await _eventually(() => states.contains(TwitchConnectionState.connecting));
    expect(states, isNot(contains(TwitchConnectionState.connected)));

    socket.receive(
      '@room-id=1 :tmi.twitch.tv ROOMSTATE #channel\r\n',
    );
    await _eventually(() => states.contains(TwitchConnectionState.connected));
  });

  test('emits typed and raw events without duplicating chat messages',
      () async {
    final socket = _FakeSocket();
    final client = _client((_) => socket);
    addTearDown(client.dispose);
    final events = <TwitchEvent>[];
    final messages = <TwitchChatMessage>[];
    final eventSubscription = client.events.listen(events.add);
    final messageSubscription = client.messages.listen(messages.add);
    addTearDown(eventSubscription.cancel);
    addTearDown(messageSubscription.cancel);
    await client.connect('channel');

    socket.receive(
      '@id=m1 :ana!u@h PRIVMSG #channel :Hola\r\n'
      ':server FUTURE #channel :payload\r\n',
    );
    await _eventually(() => events.length == 2 && messages.length == 1);

    expect(events.first, isA<TwitchMessageEvent>());
    expect(events.last, isA<TwitchRawEvent>());
    expect(events.last.frame.trailing, 'payload');
  });

  test('buffers IRC lines split across WebSocket frames', () async {
    final socket = _FakeSocket();
    final client = _client((_) => socket);
    addTearDown(client.dispose);
    final messageFuture = client.messages.first;
    await client.connect('channel');

    socket.receive('@id=split :ana!u@h PRIVMSG #channel :Hel');
    await Future<void>.delayed(const Duration(milliseconds: 2));
    socket.receive('lo\r\n');

    expect((await messageFuture).plainText, 'Hello');
  });

  test('reports malformed frames as protocol failures', () async {
    final socket = _FakeSocket();
    final client = _client((_) => socket);
    addTearDown(client.dispose);
    final failures = <TwitchFailure>[];
    final subscription = client.failures.listen(failures.add);
    addTearDown(subscription.cancel);
    await client.connect('channel');

    socket.receive('@malformed\r\n');
    await _eventually(() => failures.isNotEmpty);

    expect(failures.single.scope, TwitchFailureScope.protocol);
    expect(failures.single.error, isA<FormatException>());
  });

  test('CAP rejection and fatal NOTICE produce actionable error state',
      () async {
    final socket = _FakeSocket();
    final client = _client((_) => socket);
    addTearDown(client.dispose);
    final updates = <TwitchConnectionUpdate>[];
    final subscription = client.connections.listen(updates.add);
    addTearDown(subscription.cancel);
    await client.connect('channel');

    socket.receive(':tmi.twitch.tv CAP * NAK :twitch.tv/tags\r\n');
    socket.receive(
      '@msg-id=msg_channel_suspended :tmi.twitch.tv NOTICE #channel '
      ':This channel is suspended.\r\n',
    );
    await _eventually(
      () =>
          updates
              .where((event) => event.state == TwitchConnectionState.error)
              .length ==
          2,
    );
    expect(updates.last.error.toString(), contains('suspended'));
  });

  test('RECONNECT bypasses the normal reconnect delay', () async {
    final sockets = <_FakeSocket>[];
    final client = _client(
      (_) {
        final socket = _FakeSocket();
        sockets.add(socket);
        return socket;
      },
      reconnectDelay: const Duration(days: 1),
    );
    addTearDown(client.dispose);
    await client.connect('channel');

    sockets.single.receive(':tmi.twitch.tv RECONNECT\r\n');
    await _eventually(() => sockets.length == 2);

    expect(sockets.last.sent, contains('JOIN #channel\r\n'));
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

  test('times out an unconfirmed JOIN and reconnects', () async {
    final sockets = <_FakeSocket>[];
    final client = TwitchChatClient(
      socketFactory: (_) {
        final socket = _FakeSocket();
        sockets.add(socket);
        return socket;
      },
      httpClient: _emptyEmoteClient(),
      joinTimeout: const Duration(milliseconds: 5),
      reconnectDelay: Duration.zero,
      randomDouble: () => 0.5,
    );
    addTearDown(client.dispose);
    final failures = <TwitchFailure>[];
    client.failures.listen(failures.add);

    await client.connect('channel');
    await _eventually(() => sockets.length >= 2);

    expect(sockets.first.closed, isTrue);
    expect(
        failures.any((failure) => failure.error is TimeoutException), isTrue);
  });

  test('a confirmed room cancels the JOIN timeout', () async {
    final socket = _FakeSocket();
    final client = TwitchChatClient(
      socketFactory: (_) => socket,
      httpClient: _emptyEmoteClient(),
      joinTimeout: const Duration(milliseconds: 5),
      reconnectDelay: Duration.zero,
    );
    addTearDown(client.dispose);
    final failures = <TwitchFailure>[];
    client.failures.listen(failures.add);

    await client.connect('channel');
    socket.receive('@room-id=1 :tmi.twitch.tv ROOMSTATE #channel\r\n');
    await Future<void>.delayed(const Duration(milliseconds: 15));

    expect(failures.where((failure) => failure.error is TimeoutException),
        isEmpty);
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

  test('discards a partial IRC frame when reconnecting transports', () async {
    final sockets = <_FakeSocket>[];
    final client = _client((_) {
      final socket = _FakeSocket();
      sockets.add(socket);
      return socket;
    });
    addTearDown(client.dispose);
    await client.connect('channel');

    sockets.single.receive('@display-name=Old');
    await sockets.single.remoteClose();
    await _eventually(() => sockets.length == 2);
    final messageFuture = client.messages.first;
    sockets.last.receive(
      '@display-name=New;id=new-1 :new!new@new.tmi.twitch.tv '
      'PRIVMSG #channel :Fresh\r\n',
    );

    final message = await messageFuture.timeout(const Duration(seconds: 1));
    expect(message.id, 'new-1');
    expect(message.author.name, 'New');
    expect(message.plainText, 'Fresh');
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
  Duration reconnectDelay = const Duration(milliseconds: 1),
}) =>
    TwitchChatClient(
      socketFactory: factory,
      httpClient: _emptyEmoteClient(),
      reconnectDelay: reconnectDelay,
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
