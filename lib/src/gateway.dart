import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'socket.dart';
import 'types.dart';

/// Callbacks from a [GatewayConnection].
class GatewayHandlers {
  const GatewayHandlers({
    required this.onReady,
    required this.onMessage,
    required this.onUnauthorized,
    required this.onStateChange,
  });

  final void Function() onReady;
  final void Function(Map<String, dynamic> message) onMessage;

  /// The token was rejected: reconnecting would not help.
  final void Function() onUnauthorized;
  final void Function(ConnectionState state) onStateChange;
}

/// One WebSocket to the iAlert Gateway: authenticates with the device token,
/// answers pings, sends acks and reconnects with jittered exponential backoff.
class GatewayConnection {
  GatewayConnection({
    required this.url,
    required this.deviceToken,
    required this.connector,
    required this.handlers,
    this.pingInterval = const Duration(seconds: 30),
    this.minReconnect = const Duration(seconds: 1),
    this.maxReconnect = const Duration(seconds: 60),
    Random? random,
  }) : _random = random ?? Random();

  final Uri url;
  final String deviceToken;
  final SocketConnector connector;
  final GatewayHandlers handlers;

  /// Client ping interval; the Gateway drops a socket after about 75 s of silence.
  final Duration pingInterval;
  final Duration minReconnect;
  final Duration maxReconnect;
  final Random _random;

  IAlertSocket? _socket;
  StreamSubscription<dynamic>? _sub;
  bool _stopped = true;
  bool _ready = false;
  bool _open = false;
  int _attempt = 0;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  final List<({List<String> ids, AckEvent event})> _pendingAcks = [];

  bool get isReady => _ready;

  void start() {
    if (!_stopped) return;
    _stopped = false;
    _connect();
  }

  void stop() {
    _stopped = true;
    _clearTimers();
    _ready = false;
    _open = false;
    final socket = _socket;
    _socket = null;
    unawaited(_sub?.cancel());
    _sub = null;
    unawaited(socket?.close(1000).catchError((_) {}));
    handlers.onStateChange(ConnectionState.closed);
  }

  /// Sends an ack now, or once the socket is ready again.
  void ack(List<String> ids, AckEvent event) {
    for (var start = 0; start < ids.length; start += 100) {
      final chunk = (ids: ids.sublist(start, min(start + 100, ids.length)), event: event);
      if (!_ready || !_sendAck(chunk)) _pendingAcks.add(chunk);
    }
  }

  void _connect() {
    handlers.onStateChange(ConnectionState.connecting);
    final IAlertSocket socket;
    try {
      socket = connector(url);
    } catch (_) {
      _scheduleReconnect();
      return;
    }
    _socket = socket;
    _sub = socket.stream.listen(
      (data) => _handleFrame(data is String ? data : ''),
      onDone: () => _handleClosed(socket),
      onError: (Object _) => _handleClosed(socket),
      cancelOnError: true,
    );
    socket.ready.then((_) {
      if (_socket != socket) return;
      _open = true;
      _send({'type': 'auth', 'device_token': deviceToken});
    }, onError: (Object _) => _handleClosed(socket));
  }

  void _handleClosed(IAlertSocket socket) {
    if (_socket != socket) return;
    _socket = null;
    _sub = null;
    _ready = false;
    _open = false;
    _clearTimers();
    if (!_stopped) _scheduleReconnect();
  }

  void _handleFrame(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final frame = decoded;

    switch (frame['type']) {
      case 'ready':
        _ready = true;
        _attempt = 0;
        _startPinging();
        _flushAcks();
        handlers.onStateChange(ConnectionState.ready);
        handlers.onReady();
      case 'message':
        final message = frame['message'];
        if (message is Map) handlers.onMessage(message.map((k, v) => MapEntry('$k', v)));
      case 'ping':
        _send({'type': 'pong'});
      case 'error':
        final error = frame['error'];
        if (error == 'device_token_invalid' || error == 'auth_required') {
          _stopped = true;
          _clearTimers();
          _ready = false;
          final socket = _socket;
          _socket = null;
          unawaited(_sub?.cancel());
          _sub = null;
          unawaited(socket?.close(1000).catchError((_) {}));
          handlers.onUnauthorized();
        }
    }
  }

  bool _send(Map<String, dynamic> frame) {
    final socket = _socket;
    if (socket == null || !_open) return false;
    try {
      socket.send(jsonEncode(frame));
      return true;
    } catch (_) {
      return false;
    }
  }

  bool _sendAck(({List<String> ids, AckEvent event}) chunk) =>
      _send({'type': 'ack', 'ids': chunk.ids, 'event': chunk.event.name});

  void _flushAcks() {
    final pending = List.of(_pendingAcks);
    _pendingAcks.clear();
    for (final chunk in pending) {
      if (!_sendAck(chunk)) _pendingAcks.add(chunk);
    }
  }

  void _startPinging() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(pingInterval, (_) => _send({'type': 'ping'}));
  }

  void _scheduleReconnect() {
    handlers.onStateChange(ConnectionState.connecting);
    final ceiling = min(maxReconnect.inMicroseconds, minReconnect.inMicroseconds * pow(2, min(_attempt, 30)).toInt());
    final delay = Duration(microseconds: ceiling ~/ 2 + (_random.nextDouble() * (ceiling / 2)).round());
    _attempt++;
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (!_stopped) _connect();
    });
  }

  void _clearTimers() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _pingTimer?.cancel();
    _pingTimer = null;
  }
}
