import 'dart:convert';

/// Live Activity update kinds.
enum LiveActivityEvent { update, end }

/// One Live Activity broadcast as delivered to Android: an FCM data message with
/// `ialert_type = live_activity`. Show or update one ongoing notification per
/// [channelId] (use [notificationId]) and remove it when [isEnd].
class LiveActivityUpdate {
  const LiveActivityUpdate({
    required this.channelId,
    required this.event,
    required this.contentState,
    required this.timestamp,
    this.broadcastId,
    this.title,
    this.body,
    this.sound,
    this.staleDate,
    this.dismissalDate,
    this.relevanceScore,
  });

  final String channelId;
  final String? broadcastId;
  final LiveActivityEvent event;
  final Map<String, dynamic> contentState;
  final String? title;
  final String? body;
  final String? sound;

  /// When the update was sent (Unix seconds); drop updates older than one already shown.
  final int timestamp;
  final int? staleDate;
  final int? dismissalDate;
  final double? relevanceScore;

  bool get isEnd => event == LiveActivityEvent.end;

  /// A stable notification id: every update of the channel replaces the same notification.
  int get notificationId => channelId.hashCode & 0x7fffffff;

  /// Reads `RemoteMessage.data`; `null` when the message is not an iAlert Live Activity update.
  static LiveActivityUpdate? fromData(Map<String, dynamic> data) {
    if (data['ialert_type'] != 'live_activity') return null;
    final channelId = data['ialert_channel'];
    if (channelId is! String || channelId.isEmpty) return null;
    final event = switch (data['event']) {
      'update' => LiveActivityEvent.update,
      'end' => LiveActivityEvent.end,
      _ => null,
    };
    if (event == null) return null;

    Map<String, dynamic> state = {};
    final raw = data['content_state'];
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) state = decoded.map((k, v) => MapEntry('$k', v));
      } catch (_) {}
    }

    String? str(String key) => data[key] is String ? data[key] as String : null;

    return LiveActivityUpdate(
      channelId: channelId,
      broadcastId: str('ialert_broadcast'),
      event: event,
      contentState: state,
      title: str('title'),
      body: str('body'),
      sound: str('sound'),
      timestamp: int.tryParse(str('timestamp') ?? '') ?? 0,
      staleDate: int.tryParse(str('stale_date') ?? ''),
      dismissalDate: int.tryParse(str('dismissal_date') ?? ''),
      relevanceScore: double.tryParse(str('relevance_score') ?? ''),
    );
  }
}
