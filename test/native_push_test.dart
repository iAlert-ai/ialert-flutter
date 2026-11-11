import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ialert_flutter/ialert_flutter.dart';
import 'package:ialert_flutter/src/native_push.dart';

import 'helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late FakeApi api;
  late List<MethodCall> calls;

  IAlert make() => IAlert(
        publicKey: 'ia_pk_test_123456789012',
        apiUrl: 'https://api.test/api/v1',
        storage: MemoryStorage(),
        httpClient: api.client,
        platform: 'ios',
        autoConnect: false,
      );

  Future<void> fromNative(String method, Object? arguments) async {
    await messenger.handlePlatformMessage(
        NativePush.channel.name, NativePush.channel.codec.encodeMethodCall(MethodCall(method, arguments)), (_) {});
  }

  setUp(() {
    api = FakeApi();
    calls = [];
    messenger.setMockMethodCallHandler(NativePush.channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'requestPermission' => true,
        'getToken' => 'abcdef0123',
        _ => null,
      };
    });
  });

  test('init asks permission, registers with the native token and shares the registration', () async {
    final ialert = NativePush.start(make(), externalUserId: 'user-42');
    final device = await ialert.ready;

    expect(device?.id, 'dev_1');
    final body = api.where('POST', '/devices').single.body!;
    expect(body['push_token'], 'abcdef0123');
    expect(body['external_user_id'], 'user-42');
    expect(calls.map((c) => c.method), containsAllInOrder(['requestPermission', 'getToken', 'setRegistration']));
    final registration = calls.firstWhere((c) => c.method == 'setRegistration').arguments as Map;
    expect(registration['deviceToken'], 'ia_dt_test');
    expect(registration['apiUrl'], 'https://api.test/api/v1');
  });

  test('a new token re-registers; foreground pushes are emitted once and taps acked', () async {
    final ialert = NativePush.start(make());
    await ialert.ready;
    final received = <IAlertMessage>[];
    ialert.messages.listen(received.add);

    await fromNative('onToken', 'ffff');
    expect(api.where('POST', '/devices').last.body!['push_token'], 'ffff');

    final push = {
      'userInfo': {
        'ialert': {'id': 'ntf_1', 'data': {'url': 'app://orders'}},
      },
      'title': 'Hi',
      'body': 'There',
    };
    await fromNative('onPush', push);
    await fromNative('onPush', push);
    await fromNative('onOpen', push);
    await settle();

    expect(received, hasLength(1));
    expect(received.single.title, 'Hi');
    expect(received.single.data['url'], 'app://orders');
    final events = api.where('POST', '/inbox/ack').map((r) => r.body!['event']).toList();
    expect(events, containsAll(['delivered', 'clicked']));
  });
}
