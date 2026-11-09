import 'dart:convert';

import 'package:http/http.dart' as http;

import 'errors.dart';
import 'types.dart';

/// Thin REST client for the public-key endpoints of API v1.
class ApiClient {
  ApiClient(String baseUrl, this._publicKey, this._http)
      : _baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), '');

  final String _baseUrl;
  final String _publicKey;
  final http.Client _http;

  Future<({Device device, String deviceToken})> register(Map<String, dynamic> body) async {
    final r = await _request('POST', '/devices', body: body);
    return (device: Device(_obj(r['data'])), deviceToken: '${r['device_token']}');
  }

  Future<Device> update(String id, String token, Map<String, dynamic> body) async =>
      Device(_obj((await _request('PATCH', '/devices/${Uri.encodeComponent(id)}', body: body, token: token))['data']));

  Future<Device> unsubscribe(String id, String token) async =>
      Device(_obj((await _request('POST', '/devices/${Uri.encodeComponent(id)}/unsubscribe', token: token))['data']));

  /// Every Inbox page (newest first), following `links.next`, up to [maxPages].
  Future<List<Map<String, dynamic>>> inbox(String id, String token, {bool unreadOnly = true, int maxPages = 5}) async {
    final entries = <Map<String, dynamic>>[];
    String? url = '$_baseUrl/devices/${Uri.encodeComponent(id)}/inbox?per_page=100${unreadOnly ? '&unread=1' : ''}';
    for (var page = 0; url != null && page < maxPages; page++) {
      final r = await _request('GET', url, token: token);
      final data = r['data'];
      if (data is List) entries.addAll(data.map(_obj));
      final links = r['links'];
      final next = links is Map ? links['next'] : null;
      url = next is String && next.isNotEmpty ? next : null;
    }
    return entries;
  }

  Future<int> ack(String id, String token, List<String> ids, AckEvent event) async {
    var acknowledged = 0;
    for (var start = 0; start < ids.length; start += 100) {
      final chunk = ids.sublist(start, (start + 100).clamp(0, ids.length));
      final r = await _request('POST', '/devices/${Uri.encodeComponent(id)}/inbox/ack',
          body: {'ids': chunk, 'event': event.name}, token: token);
      final n = r['acknowledged'];
      acknowledged += n is int ? n : 0;
    }
    return acknowledged;
  }

  Future<Map<String, dynamic>> _request(String method, String pathOrUrl,
      {Map<String, dynamic>? body, String? token}) async {
    final headers = {
      'Accept': 'application/json',
      'Authorization': 'Bearer $_publicKey',
      if (body != null) 'Content-Type': 'application/json',
      if (token != null) 'X-Device-Token': token,
    };
    final url = Uri.parse(pathOrUrl.startsWith('http') ? pathOrUrl : _baseUrl + pathOrUrl);
    final request = http.Request(method, url)..headers.addAll(headers);
    if (body != null) request.body = jsonEncode(body);

    http.Response response;
    try {
      response = await http.Response.fromStream(await _http.send(request));
    } catch (e) {
      throw IAlertException(0, 'network_error', '$e');
    }

    Map<String, dynamic> payload;
    try {
      payload = _obj(jsonDecode(response.body));
    } catch (_) {
      payload = {};
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final errors = payload['errors'];
      throw IAlertException(
        response.statusCode,
        payload['code'] is String ? payload['code'] as String : 'server_error',
        payload['message'] is String ? payload['message'] as String : 'HTTP ${response.statusCode}',
        errors is Map
            ? errors.map((k, v) => MapEntry('$k', v is List ? v.map((e) => '$e').toList() : ['$v']))
            : null,
      );
    }
    return payload;
  }
}

Map<String, dynamic> _obj(Object? v) =>
    v is Map ? v.map((k, val) => MapEntry('$k', val)) : <String, dynamic>{};
