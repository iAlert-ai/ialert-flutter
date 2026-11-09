/// Gateway connection state.
enum ConnectionState { idle, connecting, ready, closed }

/// What a user did with a notification.
enum AckEvent { delivered, read, clicked }

/// Where the SDK got a message first.
enum MessageSource { gateway, inbox }

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
  });

  final String id;
  final String? title;
  final String? body;
  final String? image;
  final Map<String, dynamic> data;
  final String? collapseId;
  final String? createdAt;
  final MessageSource source;

  factory IAlertMessage.fromGateway(Map<String, dynamic> m) => IAlertMessage(
        id: '${m['id']}',
        title: _str(m['title']),
        body: _str(m['body']),
        image: _str(m['image']),
        data: _map(m['data']),
        collapseId: _str(m['collapse_id']),
        createdAt: _str(m['created_at']),
        source: MessageSource.gateway,
      );

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
    );
  }

  @override
  String toString() => 'IAlertMessage($id, $title)';
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

String? _str(Object? v) => v is String ? v : null;

Map<String, dynamic> _map(Object? v) =>
    v is Map ? v.map((k, val) => MapEntry('$k', val)) : <String, dynamic>{};
