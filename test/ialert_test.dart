import 'package:flutter_test/flutter_test.dart';
import 'package:ialert_flutter/ialert_flutter.dart';

import 'helpers.dart';

void main() {
  late FakeApi api;
  late MemoryStorage storage;
  late List<FakeSocket> sockets;

  IAlert make({String? platform, bool autoConnect = true}) => IAlert(
        publicKey: 'ia_pk_test_123456789012',
        apiUrl: 'https://api.test/api/v1',
        storage: storage,
        httpClient: api.client,
        socketConnector: (uri) {
          final s = FakeSocket(uri);
          sockets.add(s);
          return s;
        },
        platform: platform,
        autoConnect: autoConnect,
        pingInterval: const Duration(milliseconds: 40),
        minReconnect: const Duration(milliseconds: 10),
        maxReconnect: const Duration(milliseconds: 20),
      );

  setUp(() {
    api = FakeApi();
    storage = MemoryStorage();
    sockets = [];
  });

  test('refuses non-public keys', () {
    expect(() => IAlert(publicKey: 'ia_sk_x', storage: storage), throwsA(isA<IAlertException>()));
  });

  test('register picks platform, stable installation token and auth headers', () async {
    final a = make(autoConnect: false);
    expect(a.platform, 'android');
    await a.register(externalUserId: 'u1', tags: {'plan': 'pro'});
    await make(autoConnect: false).register();

    final regs = api.where('POST', '/devices');
    expect(regs, hasLength(2));
    final body = regs.first.body!;
    expect(body['platform'], 'android');
    expect(body['sdk_version'], sdkVersion);
    expect(body['external_user_id'], 'u1');
    expect(body['push_token'], startsWith('ia_flutter_'));
    expect(regs[1].body!['push_token'], body['push_token']);
    expect(regs.first.headers['Authorization'], 'Bearer ia_pk_test_123456789012');
    expect(await a.deviceId, 'dev_1');
  });

  test('ios platform and explicit push token', () async {
    await make(platform: 'ios', autoConnect: false).register(pushToken: 'apns-token-abc');
    final body = api.where('POST', '/devices').single.body!;
    expect(body['platform'], 'ios');
    expect(body['push_token'], 'apns-token-abc');
  });

  test('update calls send X-Device-Token and validate tag keys', () async {
    final a = make(autoConnect: false);
    expect(() => a.setTags({'x': 1}), throwsA(isA<IAlertException>()));
    await a.register();
    await a.setTags({'plan': 'pro', 'old': null});
    await a.setExternalUserId(null);
    await a.unsubscribe();
    expect(() => a.setTags({'bad key!': 1}), throwsA(predicate((e) => e is IAlertException && e.code == 'invalid_tag_key')));

    final patches = api.where('PATCH', '/devices/dev_1');
    expect(patches, hasLength(2));
    expect(patches[0].body, {'tags': {'plan': 'pro', 'old': null}});
    expect(patches[1].body, {'external_user_id': null});
    expect(patches.every((r) => r.headers['X-Device-Token'] == 'ia_dt_test'), isTrue);
    expect(api.where('POST', '/unsubscribe').single.headers['X-Device-Token'], 'ia_dt_test');
  });

  test('gateway: auth, ready, pong, ping, inbox sync oldest first, dedupe, auto-ack', () async {
    api.inboxEntries.addAll([inboxEntry('n3'), inboxEntry('n2', deliveredAt: 'x'), inboxEntry('n1')]);
    final a = make();
    final received = <String>[];
    final states = <ConnectionState>[];
    a.messages.listen((m) => received.add(m.id));
    a.connectionState.listen(states.add);

    await a.register();
    await settle();
    final s = sockets.single;
    expect(s.sent.first, {'type': 'auth', 'device_token': 'ia_dt_test'});

    s.receive({'type': 'ready'});
    await settle();
    expect(states, contains(ConnectionState.ready));
    expect(received, ['n1', 'n2', 'n3']);
    final inboxReq = api.where('GET', '/inbox').single;
    expect(inboxReq.url.queryParameters['unread'], '1');
    // Undelivered inbox entries are acked over the ready socket.
    expect(s.sentOfType('ack').single, {'type': 'ack', 'ids': ['n3', 'n1'], 'event': 'delivered'});

    s.receive({'type': 'ping'});
    s.receive({'type': 'message', 'message': {'id': 'n2', 'title': 'dup'}});
    s.receive({'type': 'message', 'message': {'id': 'n4', 'title': 'new', 'data': {'a': 1}}});
    await settle(60);
    expect(received, ['n1', 'n2', 'n3', 'n4']);
    expect(s.sentOfType('pong'), hasLength(1));
    expect(s.sentOfType('ping'), isNotEmpty);
    expect(s.sentOfType('ack').last, {'type': 'ack', 'ids': ['n4'], 'event': 'delivered'});

    await a.ack(['n4'], AckEvent.clicked);
    expect(s.sentOfType('ack').last['event'], 'clicked');
    expect(api.where('POST', '/inbox/ack'), isEmpty);
    await a.dispose();
  });

  test('dedupe survives restarts via storage', () async {
    final a = make();
    final first = <String>[];
    a.messages.listen((m) => first.add(m.id));
    await a.register();
    await settle();
    sockets.last.receive({'type': 'ready'});
    sockets.last.receive({'type': 'message', 'message': {'id': 'n1'}});
    await settle();
    expect(first, ['n1']);
    await a.dispose();

    api.inboxEntries.add(inboxEntry('n1'));
    final b = make();
    final second = <String>[];
    b.messages.listen((m) => second.add(m.id));
    await b.connect();
    await settle();
    sockets.last.receive({'type': 'ready'});
    await settle();
    expect(second, isEmpty);
    await b.dispose();
  });

  test('inbox follows links.next', () async {
    api.override = (req) {
      if (!req.url.path.endsWith('/inbox')) return null;
      return req.url.queryParameters['page'] == '2'
          ? (status: 200, body: {'data': [inboxEntry('a')], 'links': {'next': null}})
          : (status: 200, body: {'data': [inboxEntry('b')], 'links': {'next': 'https://api.test/api/v1/devices/dev_1/inbox?unread=1&page=2'}});
    };
    final a = make(autoConnect: false);
    await a.register();
    final got = await a.syncInbox();
    expect(got.map((m) => m.id), ['a', 'b']);
    expect(api.where('GET', '/inbox'), hasLength(2));
  });

  test('ack goes over HTTP when the socket is not ready', () async {
    final a = make(autoConnect: false);
    await a.register();
    await a.ack(['n1'], AckEvent.read);
    final req = api.where('POST', '/inbox/ack').single;
    expect(req.body, {'ids': ['n1'], 'event': 'read'});
    expect(req.headers['X-Device-Token'], 'ia_dt_test');
  });

  test('reconnects after a drop and re-syncs', () async {
    final a = make();
    await a.register();
    await settle();
    sockets.single.receive({'type': 'ready'});
    await settle();
    await sockets.single.drop();
    await settle(60);
    expect(sockets, hasLength(2));
    expect(sockets[1].sent.first['type'], 'auth');
    sockets[1].receive({'type': 'ready'});
    await settle();
    expect(api.where('GET', '/inbox'), hasLength(2));
    await a.dispose();
  });

  test('device_token_invalid stops and forgets the registration', () async {
    final a = make();
    final states = <ConnectionState>[];
    a.connectionState.listen(states.add);
    await a.register();
    await settle();
    sockets.single.receive({'type': 'error', 'error': 'device_token_invalid'});
    await settle(60);
    expect(sockets, hasLength(1));
    expect(states.last, ConnectionState.closed);
    expect(await a.deviceId, isNull);
    expect(() => a.ack(['x'], AckEvent.read), throwsA(isA<IAlertException>()));
  });

  test('HTTP 401 device_token_invalid forgets the registration', () async {
    final a = make(autoConnect: false);
    await a.register();
    api.override = (req) => (status: 401, body: {'code': 'device_token_invalid', 'message': 'bad'});
    await expectLater(a.setTags({'a': 1}), throwsA(predicate((e) => e is IAlertException && e.status == 401)));
    expect(await a.deviceId, isNull);
  });
}
