import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ialert/ialert.dart';

class FakeSocket implements IAlertSocket {
  FakeSocket(this.uri);

  final Uri uri;
  final StreamController<dynamic> _incoming = StreamController();
  final List<Map<String, dynamic>> sent = [];
  bool closed = false;

  @override
  Future<void> get ready async {}

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  void send(String frame) => sent.add(jsonDecode(frame) as Map<String, dynamic>);

  @override
  Future<void> close([int? code]) async {
    closed = true;
    if (!_incoming.isClosed) await _incoming.close();
  }

  void receive(Map<String, dynamic> frame) => _incoming.add(jsonEncode(frame));

  /// Server-side drop.
  Future<void> drop() => _incoming.close();

  List<Map<String, dynamic>> sentOfType(String type) => sent.where((f) => f['type'] == type).toList();
}

class RecordedRequest {
  RecordedRequest(this.method, this.url, this.headers, this.body);
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final Map<String, dynamic>? body;
}

typedef Responder = ({int status, Object body})? Function(RecordedRequest req);

class FakeApi {
  final List<RecordedRequest> requests = [];
  final List<Map<String, dynamic>> inboxEntries = [];
  Responder? override;

  late final http.Client client = MockClient((req) async {
    final recorded = RecordedRequest(req.method, req.url, req.headers,
        req.body.isEmpty ? null : jsonDecode(req.body) as Map<String, dynamic>);
    requests.add(recorded);
    final r = override?.call(recorded) ?? _default(recorded);
    return http.Response(jsonEncode(r.body), r.status, headers: {'content-type': 'application/json'});
  });

  ({int status, Object body}) _default(RecordedRequest req) {
    final path = req.url.path;
    if (req.method == 'POST' && path.endsWith('/devices')) {
      return (status: 201, body: {'data': device(), 'device_token': 'ia_dt_test'});
    }
    if (path.endsWith('/inbox')) {
      return (status: 200, body: {'data': inboxEntries, 'links': {'next': null}});
    }
    if (path.endsWith('/inbox/ack')) {
      return (status: 200, body: {'acknowledged': (req.body!['ids'] as List).length});
    }
    return (status: 200, body: {'data': device()});
  }

  List<RecordedRequest> where(String method, String suffix) =>
      requests.where((r) => r.method == method && r.url.path.endsWith(suffix)).toList();
}

Map<String, dynamic> device() => {'id': 'dev_1', 'platform': 'android', 'tags': {}, 'subscribed': true};

Map<String, dynamic> inboxEntry(String id, {String? deliveredAt}) => {
      'id': id,
      'content': {'title': 'T $id', 'body': 'B', 'image': null, 'data': {'k': id}},
      'collapse_id': null,
      'delivered_at': deliveredAt,
      'read_at': null,
      'clicked_at': null,
      'created_at': '2026-11-01T00:00:00Z',
    };

Future<void> settle([int ms = 20]) => Future<void>.delayed(Duration(milliseconds: ms));
