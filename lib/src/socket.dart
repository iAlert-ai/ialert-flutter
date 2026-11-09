import 'package:web_socket_channel/web_socket_channel.dart';

/// The bit of a WebSocket the SDK needs; inject your own for tests or other transports.
abstract class IAlertSocket {
  /// Completes when the socket is open; throws if it cannot connect.
  Future<void> get ready;

  /// Incoming text frames. Done when the socket closes.
  Stream<dynamic> get stream;

  void send(String frame);

  Future<void> close([int? code]);
}

/// Opens a socket to [uri].
typedef SocketConnector = IAlertSocket Function(Uri uri);

/// Default connector backed by `web_socket_channel`.
IAlertSocket webSocketConnector(Uri uri) => _ChannelSocket(WebSocketChannel.connect(uri));

class _ChannelSocket implements IAlertSocket {
  _ChannelSocket(this._channel);

  final WebSocketChannel _channel;

  @override
  Future<void> get ready => _channel.ready;

  @override
  Stream<dynamic> get stream => _channel.stream;

  @override
  void send(String frame) => _channel.sink.add(frame);

  @override
  Future<void> close([int? code]) async => _channel.sink.close(code);
}
