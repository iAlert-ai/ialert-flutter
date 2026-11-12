/// Gateway connection state.
enum ConnectionState { idle, connecting, ready, closed }

/// What a user did with a notification.
enum AckEvent { delivered, read, clicked }

/// Where the SDK got a message first.
enum MessageSource { gateway, inbox, push }

/// A notification as received from the Gateway or the Inbox; [id] is the notification id.
class IAlertMessage {
  const IAlertMessage({
    required this.id,
    required this.source,
    this.title,
    this.body,
    this.image,
    this.data = const {},
    this.collapseId,
    this.createdAt,
    this.url,
    this.sender,
  });

  final String id;
  final String? title;
  final String? body;
  final String? image;
  final Map<String, dynamic> data;
  final String? collapseId;
  final String? createdAt;
  final MessageSource source;

  /// Opened on tap: a web link (`https://…`) or an app deep link (`myapp://orders/42`).
  /// Falls back to `data['url']` for messages sent before the `url` field.
  final String? url;

  /// Who the message is from: shown as a conversation (the sender's photo and name in place
  /// of the app icon) on Android, and on iOS through `IAlertNotificationService`.
  final IAlertSender? sender;

  static String? _clickUrl(Object? url, Map<String, dynamic> data) =>
      _str(url) ?? _str(data['url']);

  factory IAlertMessage.fromGateway(Map<String, dynamic> m) => IAlertMessage(
        id: '${m['id']}',
        title: _str(m['title']),
        body: _str(m['body']),
        image: _str(m['image']),
        data: _map(m['data']),
        collapseId: _str(m['collapse_id']),
        createdAt: _str(m['created_at']),
        source: MessageSource.gateway,
        url: _clickUrl(m['url'], _map(m['data'])),
        sender: IAlertSender.fromJson(m['sender']),
      );

  /// An iAlert push as `firebase_messaging` hands it over: FCM data carries
  /// `ialert_id`; an APNs payload carries an `ialert` object. `null` for other pushes.
  static IAlertMessage? fromPush(Map<String, dynamic> data, {String? title, String? body, String? image}) {
    final apns = data['ialert'];
    final id = data['ialert_id'] ?? (apns is Map ? apns['id'] : null);
    if (id is! String || id.isEmpty) return null;

    final Map<String, dynamic> payload = apns is Map
        ? _map(apns['data'])
        : (Map<String, dynamic>.from(data)..removeWhere((key, _) => _pushKeys.contains(key)));

    return IAlertMessage(
      id: id,
      // Messages with a sender come over FCM as data only, with the content in `ialert_*` keys.
      title: title ?? _str(data['ialert_title']),
      body: body ?? _str(data['ialert_body']),
      image: image ?? _str(data['ialert_image']) ?? (apns is Map ? _str(apns['image']) : null),
      data: payload,
      source: MessageSource.push,
      url: _clickUrl(data['ialert_url'] ?? (apns is Map ? apns['url'] : null), payload),
      sender: apns is Map
          ? IAlertSender.fromJson(apns['sender'])
          : IAlertSender.fromJson({
              'id': data['ialert_sender_id'],
              'name': data['ialert_sender_name'],
              'avatar': data['ialert_sender_avatar'],
            }),
    );
  }

  factory IAlertMessage.fromInbox(Map<String, dynamic> e) {
    final content = _map(e['content']);
    return IAlertMessage(
      id: '${e['id']}',
      title: _str(content['title']),
      body: _str(content['body']),
      image: _str(content['image']),
      data: _map(content['data']),
      collapseId: _str(e['collapse_id']),
      createdAt: _str(e['created_at']),
      source: MessageSource.inbox,
      url: _clickUrl(content['url'], _map(content['data'])),
      sender: IAlertSender.fromJson(content['sender']),
    );
  }

  @override
  String toString() => 'IAlertMessage($id, $title)';
}

/// The sender of a conversation notification; [id] keeps one sender's messages together and
/// [avatar] is an HTTPS image.
class IAlertSender {
  const IAlertSender({required this.name, this.id, this.avatar});

  final String? id;
  final String name;
  final String? avatar;

  static IAlertSender? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = _str(json['name']);
    if (name == null || name.isEmpty) return null;
    return IAlertSender(name: name, id: _str(json['id']), avatar: _str(json['avatar']));
  }

  @override
  bool operator ==(Object other) =>
      other is IAlertSender && other.id == id && other.name == name && other.avatar == avatar;

  @override
  int get hashCode => Object.hash(id, name, avatar);
}

/// Device as returned by the iAlert API (the push token itself is never returned).
class Device {
  const Device(this.json);

  /// The raw device object.
  final Map<String, dynamic> json;

  String get id => '${json['id']}';
  String? get platform => _str(json['platform']);
  String? get externalUserId => _str(json['external_user_id']);
  Map<String, dynamic> get tags => _map(json['tags']);
  bool get subscribed => json['subscribed'] == true;
  String? get locale => _str(json['locale']);
}

/// iAlert's own FCM data keys, not part of the message's custom data.
const _pushKeys = {'ialert_id', 'ialert_url', 'ialert_sound', 'ialert_title', 'ialert_body', 'ialert_image', 'ialert_sender_id', 'ialert_sender_name', 'ialert_sender_avatar'};

String? _str(Object? v) => v is String ? v : null;

Map<String, dynamic> _map(Object? v) =>
    v is Map ? v.map((k, val) => MapEntry('$k', val)) : <String, dynamic>{};

/// An Auth Push sign-in request carried by a message (`data['ialert_type'] == 'auth_request'`).
class AuthRequestInfo {
  const AuthRequestInfo({required this.id, required this.numberMatching, this.expiresAt, this.context = const {}});

  final String id;
  final bool numberMatching;
  final String? expiresAt;

  /// Your `context` values (IP, city, device…) to show the user.
  final Map<String, String> context;

  static const _reserved = {'ialert_type', 'auth_request_id', 'number_matching', 'expires_at'};

  /// The request a message carries, or `null` for other messages.
  static AuthRequestInfo? of(IAlertMessage message) {
    final data = message.data;
    final id = data['auth_request_id'];
    if (data['ialert_type'] != 'auth_request' || id is! String) return null;

    return AuthRequestInfo(
      id: id,
      numberMatching: data['number_matching'] == '1' || data['number_matching'] == true,
      expiresAt: data['expires_at'] is String ? data['expires_at'] as String : null,
      context: {
        for (final entry in data.entries)
          if (!_reserved.contains(entry.key) && entry.value is String) entry.key: entry.value as String,
      },
    );
  }
}
