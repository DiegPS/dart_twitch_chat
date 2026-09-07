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
    Duration maximumReconnectDelay = const Duration(seconds: 30),
    Duration connectionTimeout = const Duration(seconds: 10),
    Duration joinTimeout = const Duration(seconds: 15),
    Duration optionalApiTimeout = const Duration(seconds: 5),
    double Function()? randomDouble,
  })  : _socketFactory = socketFactory ?? WebSocketChannelTwitchSocket.new,
        _httpClient = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null,
        _reconnectDelay = reconnectDelay,
        _maximumReconnectDelay = maximumReconnectDelay,
        _connectionTimeout = connectionTimeout,
        _joinTimeout = joinTimeout,
        _randomDouble = randomDouble ?? Random().nextDouble,
        _optionalApiTimeout = optionalApiTimeout;

  final TwitchSocketFactory _socketFactory;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final Duration _reconnectDelay;
  final Duration _maximumReconnectDelay;
  final Duration _connectionTimeout;
  final Duration _joinTimeout;
  final Duration _optionalApiTimeout;
  final double Function() _randomDouble;

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
  Timer? _joinTimer;
  int _reconnectAttempts = 0;

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
    _reconnectAttempts = 0;
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
    _joinTimer?.cancel();
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
    _startJoinTimer(socket, generation);
  }

  Future<void> _readLoop(int generation) async {
    while (_isCurrent(generation)) {
      final socket = _socket;
      if (socket == null) {
        final delay = _nextReconnectDelay();
        if (delay > Duration.zero) await Future<void>.delayed(delay);
        if (!_isCurrent(generation)) return;
        _emitConnection(TwitchConnectionState.connecting);
        try {
          await _dial(generation);
        } catch (error, stackTrace) {
          if (!_isCurrent(generation)) return;
          _report(TwitchFailureScope.connection, error, stackTrace);
          _emitConnection(TwitchConnectionState.error, error);
        }
        continue;
      }
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
      final delay = _reconnectRequested ? Duration.zero : _nextReconnectDelay();
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
          _confirmJoined();
        case TwitchRoomStateEvent(frame: final stateFrame)
            when stateFrame.channel == _channel:
          _confirmJoined();
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

  void _startJoinTimer(TwitchSocket socket, int generation) {
    _joinTimer?.cancel();
    if (_joinTimeout <= Duration.zero) return;
    _joinTimer = Timer(_joinTimeout, () {
      if (!_isCurrent(generation) || !identical(_socket, socket)) return;
      final error = TimeoutException(
        'Twitch did not confirm JOIN #$_channel.',
        _joinTimeout,
      );
      _report(TwitchFailureScope.connection, error, StackTrace.current);
      _emitConnection(TwitchConnectionState.error, error);
      unawaited(socket.close());
    });
  }

  void _confirmJoined() {
    _joinTimer?.cancel();
    _reconnectAttempts = 0;
    _emitConnection(TwitchConnectionState.connected);
  }

  Duration _nextReconnectDelay() {
    _reconnectAttempts++;
    final exponential = _reconnectDelay.inMilliseconds *
        pow(2, min(_reconnectAttempts - 1, 10));
    final capped =
        min(exponential.round(), _maximumReconnectDelay.inMilliseconds);
    final jittered = (capped * (0.8 + _randomDouble() * 0.4)).round();
    return Duration(milliseconds: jittered);
  }

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
