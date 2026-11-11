import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:http/http.dart' as http;

import 'api.dart';
import 'errors.dart';
import 'gateway.dart';
import 'native_push.dart';
import 'socket.dart';
import 'storage.dart';
import 'types.dart';

const String sdkVersion = '0.5.0';

final RegExp _tagKey = RegExp(r'^[A-Za-z0-9_.:-]{1,64}$');
const int _seenLimit = 500;

/// iAlert Flutter SDK. Registers the device, keeps a Gateway socket open,
/// syncs the Inbox after every (re)connect and emits each notification once.
class IAlert {
  IAlert({
    required String publicKey,
    String apiUrl = 'https://api.ialert.ir/api/v1',
    String gatewayUrl = 'wss://gw.ialert.ir/v1/connect',
    KeyValueStorage? storage,
    http.Client? httpClient,
    SocketConnector? socketConnector,
    this.autoConnect = true,
    this.autoAckDelivered = true,
    String? platform,
    this.pingInterval = const Duration(seconds: 30),
    this.minReconnect = const Duration(seconds: 1),
    this.maxReconnect = const Duration(seconds: 60),
  })  : _apiUrl = apiUrl,
        _publicKey = publicKey,
        _gatewayUrl = Uri.parse(gatewayUrl),
        _connector = socketConnector ?? webSocketConnector,
        _platform = platform ?? (defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android') {
    if (!publicKey.startsWith('ia_pk_')) {
      throw IAlertException(0, 'invalid_public_key',
          "Use the app's public key (ia_pk_…); secret keys must never ship in apps.");
    }
    if (_platform != 'android' && _platform != 'ios') {
      throw IAlertException(0, 'invalid_platform', 'Platform must be android or ios.');
    }
    _api = ApiClient(apiUrl, publicKey, httpClient ?? http.Client());
    _store = Store(storage ?? SharedPreferencesStorage(),
        publicKey.length > 12 ? publicKey.substring(publicKey.length - 12) : publicKey);
  }

  /// One-line setup: asks for notification permission, gets the native push
  /// token, registers the device, connects to the Gateway, shows iAlert
  /// notifications in the foreground and reports taps. No Firebase or other
  /// packages and no AppDelegate code. Await [IAlert.ready] if you need the device.
  static IAlert init({
    required String publicKey,
    String? externalUserId,
    Map<String, Object?>? tags,
    bool requestPermission = true,
  }) =>
      NativePush.start(IAlert(publicKey: publicKey),
          externalUserId: externalUserId, tags: tags, requestPermission: requestPermission);

  /// Completes when [init] finished its first registration.
  Future<Device?> ready = Future.value(null);

  /// Connect to the Gateway right after [register].
  final bool autoConnect;

  /// Ack `delivered` for every message emitted.
  final bool autoAckDelivered;
  final Duration pingInterval;
  final Duration minReconnect;
  final Duration maxReconnect;

  final String _apiUrl;
  final String _publicKey;

  /// The app's public key (`ia_pk_…`).
  String get publicKey => _publicKey;

  /// Base URL of the iAlert API.
  String get apiUrl => _apiUrl;
  final Uri _gatewayUrl;

  /// Told about every registration, so native background sync can read the Inbox.
  void Function(Map<String, String> registration)? onRegistered;
  final SocketConnector _connector;
  final String _platform;
  late final ApiClient _api;
  late final Store _store;

  final StreamController<IAlertMessage> _messages = StreamController.broadcast();
  final StreamController<ConnectionState> _states = StreamController.broadcast();

  GatewayConnection? _gateway;
  Future<void>? _loading;
  List<String> _seen = [];
  ({String deviceId, String deviceToken})? _registration;
  Future<List<IAlertMessage>>? _syncing;
  Future<void> _queue = Future.value();
  ConnectionState _state = ConnectionState.idle;

  /// Notifications, each emitted once (deduplicated by id, across restarts).
  Stream<IAlertMessage> get messages => _messages.stream;

  /// Gateway connection state changes.
  Stream<ConnectionState> get connectionState => _states.stream;

  ConnectionState get currentState => _state;

  /// The platform sent on register (`android` or `ios`).
  String get platform => _platform;

  /// The registered device id, or null before [register].
  Future<String?> get deviceId async {
    await _load();
    return _registration?.deviceId;
  }

  /// Register (or re-register) this device. Safe to call on every launch.
  /// Pass the FCM/APNs token as [pushToken] once you have it; otherwise a stable
  /// `ia_flutter_<uuid>` installation id is used (Gateway + Inbox delivery only).
  Future<Device> register({
    String? pushToken,
    String? externalUserId,
    Map<String, Object?>? tags,
    String? locale,
    String? timezone,
    String? appVersion,
    String? osVersion,
    String? deviceModel,
  }) async {
    await _load();
    final fields = _deviceFields(
        externalUserId: externalUserId, tags: tags, locale: locale, timezone: timezone, appVersion: appVersion);
    final result = await _api.register({
      'platform': _platform,
      'push_token': pushToken ?? await _installationId(),
      'sdk_version': sdkVersion,
      'timezone': ?timezone ?? _detectTimezone(),
      'os_version': ?osVersion,
      'device_model': ?deviceModel,
      ...fields,
    });
    final changed = _registration?.deviceToken != result.deviceToken;
    _registration = (deviceId: result.device.id, deviceToken: result.deviceToken);
    await _store.set('registration', {'deviceId': result.device.id, 'deviceToken': result.deviceToken});
    onRegistered?.call({
      'apiUrl': _apiUrl,
      'publicKey': _publicKey,
      'deviceId': result.device.id,
      'deviceToken': result.deviceToken,
    });
    if (changed) disconnect();
    if (autoConnect) await connect();
    return result.device;
  }

  /// Update the external user id, tags (merged; null removes) or locale of this device.
  Future<Device> update({
    Object? externalUserId = _unset,
    Map<String, Object?>? tags,
    String? locale,
    String? timezone,
    String? appVersion,
  }) async {
    final r = await _requireRegistration();
    final fields = _deviceFields(
        externalUserId: externalUserId, tags: tags, locale: locale, timezone: timezone, appVersion: appVersion);
    return _withToken(() => _api.update(r.deviceId, r.deviceToken, fields));
  }

  Future<Device> setTags(Map<String, Object?> tags) => update(tags: tags);

  Future<Device> setExternalUserId(String? externalUserId) => update(externalUserId: externalUserId);

  /// Approve or deny an Auth Push sign-in request (see [AuthRequestInfo.of]).
  /// With number matching pass the number the user typed; a wrong one denies.
  /// Returns the request status: `approved`, `denied`, `pending` or `expired`.
  Future<String> respondToAuthRequest(String requestId, {required bool approve, String? code}) async {
    final r = await _requireRegistration();
    final result = await _withToken(() => _api.respondToAuthRequest(r.deviceId, r.deviceToken, requestId, approve, code),
        forgetOnNotFound: false);
    return '${result['status'] ?? 'pending'}';
  }

  /// Hand a native push to the SDK, e.g. from `FirebaseMessaging.onMessage`:
  /// `ialert.didReceivePush(m.data, title: m.notification?.title, body: m.notification?.body)`.
  /// Listeners get it once, deduplicated against the Gateway and Inbox, and it is
  /// acked as delivered. Returns `null` for pushes that are not from iAlert or already seen.
  Future<IAlertMessage?> didReceivePush(Map<String, dynamic> data, {String? title, String? body, String? image}) async {
    final message = IAlertMessage.fromPush(data, title: title, body: body, image: image);
    if (message == null) return null;
    return await _receive(message) ? message : null;
  }

  /// Report a tap on an iAlert notification, e.g. from `FirebaseMessaging.onMessageOpenedApp`.
  Future<void> didOpenPush(Map<String, dynamic> data) async {
    final message = IAlertMessage.fromPush(data);
    if (message == null) return;
    await _receive(message, ack: false);
    await ack([message.id], AckEvent.clicked);
  }

  /// Join a Live Activity channel so its broadcasts reach this Android device as
  /// FCM data messages (read them with [LiveActivityUpdate.fromData]). Register
  /// with the FCM token as `pushToken` first, and subscribe again after it changes.
  /// On iOS, subscribe the Live Activity itself with ActivityKit instead.
  Future<void> subscribeLiveActivity(String channelId) => _liveActivity(channelId, subscribe: true);

  /// Leave a Live Activity channel (Android).
  Future<void> unsubscribeLiveActivity(String channelId) => _liveActivity(channelId, subscribe: false);

  Future<void> _liveActivity(String channelId, {required bool subscribe}) async {
    if (_platform == 'ios') {
      throw IAlertException(0, 'platform_not_supported',
          'On iOS, subscribe the Live Activity with ActivityKit: Activity.request(..., pushType: .channel(channelId)).');
    }
    final r = await _requireRegistration();
    await _withToken(() => _api.liveActivity(r.deviceId, r.deviceToken, channelId, subscribe: subscribe),
        forgetOnNotFound: false);
  }

  /// Stop receiving notifications; call [register] to subscribe again.
  Future<Device> unsubscribe() async {
    final r = await _requireRegistration();
    disconnect();
    return _withToken(() => _api.unsubscribe(r.deviceId, r.deviceToken));
  }

  /// Open the Gateway socket (done by [register] unless `autoConnect: false`).
  Future<void> connect() async {
    final r = await _requireRegistration();
    if (_gateway != null) return;
    final gateway = GatewayConnection(
      url: _gatewayUrl,
      deviceToken: r.deviceToken,
      connector: _connector,
      pingInterval: pingInterval,
      minReconnect: minReconnect,
      maxReconnect: maxReconnect,
      handlers: GatewayHandlers(
        onReady: () => unawaited(syncInbox().catchError((Object _) => <IAlertMessage>[])),
        onMessage: (m) => _enqueue(() => _receive(IAlertMessage.fromGateway(m))),
        onUnauthorized: () {
          _gateway = null;
          unawaited(_forget());
          _emitState(ConnectionState.closed);
        },
        onStateChange: _emitState,
      ),
    );
    _gateway = gateway;
    gateway.start();
  }

  void disconnect() {
    final gateway = _gateway;
    _gateway = null;
    gateway?.stop();
  }

  /// Pull unread Inbox entries (missed while the app was closed) and emit the
  /// new ones, oldest first. Concurrent calls share one request.
  Future<List<IAlertMessage>> syncInbox() =>
      _syncing ??= _pullInbox().whenComplete(() => _syncing = null);

  /// Report that the user read or clicked notifications (by notification id).
  /// Goes over the Gateway when it is ready, otherwise over HTTP.
  Future<void> ack(List<String> ids, AckEvent event) async {
    if (ids.isEmpty) return;
    final r = await _requireRegistration();
    final gateway = _gateway;
    if (gateway != null && gateway.isReady) {
      gateway.ack(ids, event);
      return;
    }
    await _withToken(() => _api.ack(r.deviceId, r.deviceToken, ids, event));
  }

  /// Disconnect and close the streams.
  Future<void> dispose() async {
    disconnect();
    await _messages.close();
    await _states.close();
  }

  Future<List<IAlertMessage>> _pullInbox() async {
    final r = await _requireRegistration();
    final entries = await _withToken(() => _api.inbox(r.deviceId, r.deviceToken));
    final received = <IAlertMessage>[];
    await _enqueue(() async {
      for (final entry in entries.reversed) {
        final message = IAlertMessage.fromInbox(entry);
        if (await _receive(message, ack: false)) received.add(message);
      }
    });
    if (autoAckDelivered) {
      final undelivered = [for (final e in entries) if (e['delivered_at'] == null) '${e['id']}'];
      await ack(undelivered, AckEvent.delivered).catchError((Object _) {});
    }
    return received;
  }

  /// Runs [task] after every earlier one, so dedupe sees a consistent seen list.
  Future<T> _enqueue<T>(Future<T> Function() task) {
    final result = _queue.then((_) => task());
    _queue = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<bool> _receive(IAlertMessage message, {bool ack = true}) async {
    await _load();
    if (_seen.contains(message.id)) return false;
    _seen.add(message.id);
    if (_seen.length > _seenLimit) _seen = _seen.sublist(_seen.length - _seenLimit);
    await _store.set('seen', _seen);
    if (!_messages.isClosed) _messages.add(message);
    if (ack && autoAckDelivered) {
      unawaited(this.ack([message.id], AckEvent.delivered).catchError((Object _) {}));
    }
    return true;
  }

  Map<String, dynamic> _deviceFields({
    Object? externalUserId = _unset,
    Map<String, Object?>? tags,
    String? locale,
    String? timezone,
    String? appVersion,
  }) {
    final fields = <String, dynamic>{};
    if (!identical(externalUserId, _unset)) fields['external_user_id'] = externalUserId;
    if (tags != null) {
      final invalid = tags.keys.where((k) => !_tagKey.hasMatch(k)).toList();
      if (invalid.isNotEmpty) {
        throw IAlertException(
            0, 'invalid_tag_key', 'Tag keys must match [A-Za-z0-9_.:-]{1,64}: ${invalid.join(', ')}');
      }
      fields['tags'] = tags;
    }
    if (locale != null) fields['locale'] = locale;
    if (timezone != null) fields['timezone'] = timezone;
    if (appVersion != null) fields['app_version'] = appVersion;
    return fields;
  }

  String? _detectTimezone() {
    final name = DateTime.now().timeZoneName;
    return name.contains('/') ? name : null;
  }

  Future<String> _installationId() async {
    final existing = await _store.get('installation');
    if (existing is String) return existing;
    final id = 'ia_flutter_${_uuidV4()}';
    await _store.set('installation', id);
    return id;
  }

  Future<void> _load() => _loading ??= () async {
        final seen = await _store.get('seen');
        if (seen is List) _seen = [for (final s in seen) '$s'];
        final reg = await _store.get('registration');
        if (reg is Map && reg['deviceId'] is String && reg['deviceToken'] is String) {
          _registration = (deviceId: reg['deviceId'] as String, deviceToken: reg['deviceToken'] as String);
        }
      }();

  Future<({String deviceId, String deviceToken})> _requireRegistration() async {
    await _load();
    final r = _registration;
    if (r == null) throw IAlertException(0, 'not_registered', 'Call register() first.');
    return r;
  }

  Future<void> _forget() async {
    _registration = null;
    await _store.remove('registration');
  }

  /// A rejected device token means the device was deleted or unsubscribed elsewhere.
  /// A rejected device token means the device was deleted elsewhere; a 404 means the
  /// same unless the path also names another resource (a channel: [forgetOnNotFound] false).
  Future<T> _withToken<T>(Future<T> Function() call, {bool forgetOnNotFound = true}) async {
    try {
      return await call();
    } on IAlertException catch (e) {
      if (e.code == 'device_token_invalid' || (forgetOnNotFound && e.status == 404)) {
        disconnect();
        await _forget();
      }
      rethrow;
    }
  }

  void _emitState(ConnectionState state) {
    _state = state;
    if (!_states.isClosed) _states.add(state);
  }
}

const Object _unset = Object();

String _uuidV4() {
  final rnd = Random.secure();
  final b = List<int>.generate(16, (_) => rnd.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}
