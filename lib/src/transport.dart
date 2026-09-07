import 'package:web_socket_channel/web_socket_channel.dart';

abstract interface class TwitchSocket {
  Future<void> get ready;
  Stream<dynamic> get stream;
  void add(String data);
  Future<void> close();
}

typedef TwitchSocketFactory = TwitchSocket Function(Uri uri);

class WebSocketChannelTwitchSocket implements TwitchSocket {
  WebSocketChannelTwitchSocket(Uri uri)
      : _channel = WebSocketChannel.connect(uri);

  final WebSocketChannel _channel;

  @override
  Future<void> get ready => _channel.ready;

  @override
  Stream<dynamic> get stream => _channel.stream;

  @override
  void add(String data) => _channel.sink.add(data);

  @override
  Future<void> close() async => _channel.sink.close();
}
