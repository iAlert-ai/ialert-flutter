import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'client.dart';
import 'types.dart';

/// Bridge to the plugin's native side (`ir.ialert/push`): permission, the APNs
/// (iOS) or FCM (Android) token, pushes shown while the app is open, taps, and
/// the registration the native background sync needs.
class NativePush {
  static const MethodChannel channel = MethodChannel('ir.ialert/push');

  static IAlert start(IAlert ialert,
      {String? externalUserId, Map<String, Object?>? tags, bool requestPermission = true}) {
    WidgetsFlutterBinding.ensureInitialized();
    String? token;

    Map<Object?, Object?>? info;

    Future<Device> register() => ialert.register(
          pushToken: token,
          externalUserId: externalUserId,
          tags: tags,
          deviceModel: info?['model'] as String?,
          osVersion: info?['osVersion'] as String?,
        );

    ialert.onRegistered = (registration) {
      unawaited(channel.invokeMethod<void>('setRegistration', registration).catchError((_) {}));
    };

    channel.setMethodCallHandler((call) async {
      final args = call.arguments;
      switch (call.method) {
        case 'onToken':
          if (args is String && args != token) {
            token = args;
            try {
              await register();
            } catch (_) {
              // retried on the next launch
            }
          }
        case 'onPush':
          final push = _payload(args);
          if (push != null) {
            await ialert.didReceivePush(push.data, title: push.title, body: push.body);
          }
        case 'onOpen':
          final push = _payload(args);
          if (push != null) await ialert.didOpenPush(push.data);
      }
      return null;
    });

    ialert.ready = () async {
      try {
        info = await channel.invokeMethod<Map<Object?, Object?>>('deviceInfo');
      } on MissingPluginException {
        // tests or an unsupported platform
      } on PlatformException {
        // older native side
      }
      try {
        if (requestPermission) await channel.invokeMethod<bool>('requestPermission');
        token = await channel.invokeMethod<String>(
            'getToken', {'publicKey': ialert.publicKey, 'apiUrl': ialert.apiUrl});
      } on MissingPluginException {
        // tests or an unsupported platform: Gateway and Inbox only
      } on PlatformException {
        // no permission or no native push: Gateway and Inbox only
      }
      final device = await register();
      try {
        final open = _payload(await channel.invokeMethod<Object?>('takeInitialOpen'));
        if (open != null) await ialert.didOpenPush(open.data);
      } on MissingPluginException {
        // ignore
      }
      return device;
    }();

    return ialert;
  }

  static ({Map<String, dynamic> data, String? title, String? body})? _payload(Object? args) {
    if (args is! Map) return null;
    final userInfo = args['userInfo'];
    if (userInfo is! Map) return null;
    String? text(Object? v) => v is String && v.isNotEmpty ? v : null;
    return (
      data: _deep(userInfo),
      title: text(args['title']),
      body: text(args['body']),
    );
  }

  static Map<String, dynamic> _deep(Map<Object?, Object?> map) => map.map((key, value) =>
      MapEntry('$key', value is Map ? _deep(value.cast<Object?, Object?>()) : value));
}
