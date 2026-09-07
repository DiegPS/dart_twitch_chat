import 'dart:async';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'emotes.dart';
import 'events.dart';
import 'models.dart';
import 'parser.dart';
import 'transport.dart';

const _ircUrl = 'wss://irc-ws.chat.twitch.tv/';

/// Anonymous Twitch IRC client with reconnect and global emote support.
class TwitchChatClient {
  TwitchChatClient({
    TwitchSocketFactory? socketFactory,
    http.Client? httpClient,
    Duration reconnectDelay = const Duration(seconds: 5),
    Duration connectionTimeout = const Duration(seconds: 10),
    Duration optionalApiTimeout = const Duration(seconds: 5),
  })  : _socketFactory = socketFactory ?? WebSocketChannelTwitchSocket.new,
        _httpClient = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null,
        _reconnectDelay = reconnectDelay,
        _connectionTimeout = connectionTimeout,
        _optionalApiTimeout = optionalApiTimeout;

  final TwitchSocketFactory _socketFactory;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final Duration _reconnectDelay;
  final Duration _connectionTimeout;
  final Duration _optionalApiTimeout;

  final _messages = StreamController<TwitchChatMessage>.broadcast();
  final _events = StreamController<TwitchEvent>.broadcast();
  final _connections = StreamController<TwitchConnectionUpdate>.broadcast();
  final _failures = StreamController<TwitchFailure>.broadcast();
  TwitchSocket? _socket;
  String _channel = '';
  bool _closed = false;
  int _generation = 0;
  Map<String, TwitchEmote> _emotes = const {};
  bool _reconnectRequested = false;
  String _ircBuffer = '';

  Stream<TwitchChatMessage> get messages => _messages.stream;
  Stream<TwitchEvent> get events => _events.stream;
  Stream<TwitchConnectionUpdate> get connections => _connections.stream;
  Stream<TwitchFailure> get failures => _failures.stream;
  String get channel => _channel;

  Future<void> connect(String channelName) async {
    await disconnect();
    final generation = ++_generation;
    _closed = false;
    _channel = normalizeChannel(channelName);
    if (_channel.isEmpty) {
      throw const FormatException('Twitch channel is empty.');
    }
    _emotes = const {};
    _ircBuffer = '';
    _emitConnection(TwitchConnectionState.connecting);
    try {
      await _dial(generation);
      if (!_isCurrent(generation)) return;
    } catch (error, stackTrace) {
      if (!_isCurrent(generation)) return;
      _report(TwitchFailureScope.connection, error, stackTrace);
      _emitConnection(TwitchConnectionState.error, error);
      rethrow;
    }
    unawaited(_loadEmotes(generation));
    unawaited(_readLoop(generation));
  }

  Future<void> disconnect() async {
    _generation++;
    _closed = true;
    await _socket?.close();
    _socket = null;
    _emitConnection(TwitchConnectionState.idle);
  }

  Future<void> dispose() async {
    await disconnect();
    if (_ownsHttpClient) _httpClient.close();
    await _messages.close();
    await _events.close();
    await _connections.close();
    await _failures.close();
  }

  static String normalizeChannel(String value) =>
      value.trim().toLowerCase().replaceAll('#', '');

  Future<void> _dial(int generation) async {
    // A partial frame belongs to the previous transport and must never be
    // prepended to the first frame received after a reconnect.
    _ircBuffer = '';
    final nick = 'justinfan${Random().nextInt(80000) + 1000}';
    final socket = _socketFactory(Uri.parse(_ircUrl));
    try {
      await socket.ready.timeout(_connectionTimeout);
    } catch (_) {
      await socket.close();
      rethrow;
    }
    if (!_isCurrent(generation)) {
      await socket.close();
      return;
    }
    _socket = socket;
    socket.add('CAP REQ :twitch.tv/tags twitch.tv/commands\r\n');
    socket.add('PASS oauth:anonymous\r\n');
    socket.add('NICK $nick\r\n');
    socket.add('JOIN #$_channel\r\n');
  }

  Future<void> _readLoop(int generation) async {
    while (_isCurrent(generation)) {
      final socket = _socket;
      if (socket == null) return;
      try {
        await for (final raw in socket.stream) {
          if (!_isCurrent(generation)) return;
          if (raw is String) _handleRaw(raw);
        }
        if (_isCurrent(generation)) {
          throw StateError('Twitch connection closed.');
        }
      } catch (error, stackTrace) {
        if (!_isCurrent(generation)) return;
        _report(TwitchFailureScope.connection, error, stackTrace);
        _emitConnection(TwitchConnectionState.error, error);
      }

      if (identical(_socket, socket)) {
        _socket = null;
        try {
          await socket.close();
        } catch (_) {
          // Remote closure already completed the only required cleanup.
        }
      }
      if (!_isCurrent(generation)) return;
      final delay = _reconnectRequested ? Duration.zero : _reconnectDelay;
      _reconnectRequested = false;
      await Future<void>.delayed(delay);
      if (!_isCurrent(generation)) return;
      _emitConnection(TwitchConnectionState.connecting);
      try {
        await _dial(generation);
      } catch (error, stackTrace) {
        if (!_isCurrent(generation)) return;
        _report(TwitchFailureScope.connection, error, stackTrace);
        _emitConnection(TwitchConnectionState.error, error);
      }
    }
  }

  void _handleRaw(String raw) {
    _ircBuffer += raw;
    while (true) {
      final delimiter = _ircBuffer.indexOf('\r\n');
      if (delimiter < 0) return;
      final line = _ircBuffer.substring(0, delimiter);
      _ircBuffer = _ircBuffer.substring(delimiter + 2);
      if (line.isEmpty) continue;
      if (line.startsWith('PING')) {
        _socket?.add('${line.replaceFirst('PING', 'PONG')}\r\n');
        continue;
      }
      final frame = TwitchIrcParser.parseFrame(line);
      if (frame == null) {
        _report(
          TwitchFailureScope.protocol,
          FormatException('Malformed Twitch IRC frame.', line),
          StackTrace.current,
        );
        continue;
      }
      late final TwitchEvent event;
      try {
        event = TwitchEventParser.parse(
          frame,
          thirdPartyEmotes: _emotes,
        );
      } catch (error, stackTrace) {
        _report(TwitchFailureScope.protocol, error, stackTrace);
        event = TwitchRawEvent(frame);
      }
      if (!_events.isClosed) _events.add(event);
      switch (event) {
        case TwitchMessageEvent(:final message):
          if (!_messages.isClosed) _messages.add(message);
        case TwitchUserNoticeEvent(:final notice):
          if (_isLegacyDisplayedNotice(notice.messageType) &&
              !_messages.isClosed) {
            _messages.add(notice.message);
          }
        case TwitchJoinEvent(:final channel) when channel == _channel:
          _emitConnection(TwitchConnectionState.connected);
        case TwitchRoomStateEvent(frame: final stateFrame)
            when stateFrame.channel == _channel:
          _emitConnection(TwitchConnectionState.connected);
        case TwitchCapabilityEvent(acknowledged: false):
          final error =
              StateError('Twitch rejected requested IRC capabilities.');
          _report(TwitchFailureScope.protocol, error, StackTrace.current);
          _emitConnection(TwitchConnectionState.error, error);
        case TwitchNoticeEvent(:final messageId, :final message)
            when _isFatalNotice(messageId, frame):
          final error = StateError(message);
          _report(TwitchFailureScope.connection, error, StackTrace.current);
          _emitConnection(TwitchConnectionState.error, error);
        case TwitchReconnectEvent():
          _reconnectRequested = true;
          final socket = _socket;
          if (socket != null) unawaited(socket.close());
        case TwitchPartEvent(:final channel) when channel == _channel:
          final error = StateError('Twitch left #$channel.');
          _report(TwitchFailureScope.connection, error, StackTrace.current);
          _emitConnection(TwitchConnectionState.error, error);
        default:
          break;
      }
    }
  }

  static bool _isLegacyDisplayedNotice(String type) =>
      const {'sub', 'resub', 'subgift', 'anonsubgift'}.contains(type);

  static bool _isFatalNotice(String? messageId, TwitchIrcFrame frame) {
    if (frame.parameters.contains('*')) return true;
    return const {
      'msg_banned',
      'msg_channel_blocked',
      'msg_channel_suspended',
    }.contains(messageId);
  }

  Future<void> _loadEmotes(int generation) async {
    try {
      final loaded = await TwitchGlobalEmoteLoader(
        httpClient: _httpClient,
        timeout: _optionalApiTimeout,
      ).load(
        onError: (error, stackTrace) {
          if (_isCurrent(generation)) {
            _report(TwitchFailureScope.emotes, error, stackTrace);
          }
        },
      );
      if (_isCurrent(generation)) _emotes = loaded;
    } catch (error, stackTrace) {
      if (_isCurrent(generation)) {
        _report(TwitchFailureScope.emotes, error, stackTrace);
      }
    }
  }

  bool _isCurrent(int generation) => !_closed && generation == _generation;

  void _emitConnection(TwitchConnectionState state, [Object? error]) {
    if (!_connections.isClosed) {
      _connections.add(TwitchConnectionUpdate(state, error));
    }
  }

  void _report(TwitchFailureScope scope, Object error, StackTrace stackTrace) {
    if (!_failures.isClosed) {
      _failures.add(
        TwitchFailure(scope: scope, error: error, stackTrace: stackTrace),
      );
    }
  }
}
