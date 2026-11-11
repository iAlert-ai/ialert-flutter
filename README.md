# iAlert Flutter SDK

Flutter client for [iAlert](https://ialert.ir) push notifications (`ialert_flutter` 0.4.0).
Messages arrive over iAlert's own Gateway WebSocket and the per-device Inbox, so
delivery keeps working inside Iran when international internet is cut.

## Install

```yaml
dependencies:
  ialert_flutter: ^0.4.0
```

## Usage

```dart
import 'package:ialert_flutter/ialert_flutter.dart';

final ialert = IAlert(publicKey: 'ia_pk_...'); // public key only; secret keys are refused

ialert.messages.listen((m) => print('${m.title}: ${m.body}'));
ialert.connectionState.listen((s) => print('gateway: $s'));

await ialert.register(
  pushToken: fcmOrApnsToken, // optional; defaults to a stable ia_flutter_<uuid>
  externalUserId: 'user-42',
  tags: {'plan': 'pro'},
  locale: 'fa-IR',
);

await ialert.setTags({'city': 'tehran', 'old_tag': null}); // null removes a tag
await ialert.setExternalUserId('user-43');
await ialert.ack([message.id], AckEvent.clicked);           // read | clicked
await ialert.unsubscribe();
```

What it does:

- `register()` sends platform `android` or `ios` (from the running platform), then opens the Gateway (`autoConnect: false` to do it yourself with `connect()`).
- On every `ready` from the Gateway it syncs unread Inbox entries, oldest first.
- Each notification is emitted once: ids are deduplicated across Gateway, Inbox and restarts (last 500 kept in storage).
- `delivered` is acked automatically (`autoAckDelivered: false` to turn off). Acks go over the socket when it is ready, otherwise over HTTP.
- Answers Gateway pings, pings every 30 s, reconnects with jittered backoff (1–60 s). On `device_token_invalid` / `auth_required` it stops and forgets the registration; call `register()` again.

## Live Activity broadcasts

One push from your server updates a live notification on every subscribed device (scores, deliveries, flights). Your server creates the channel with `POST /v1/live-activity-channels` and gives its `id` to the app.

**Android** joins through iAlert, with the FCM token from `firebase_messaging`:

```dart
await ialert.register(pushToken: await FirebaseMessaging.instance.getToken());
await ialert.subscribeLiveActivity(channelId); // and unsubscribeLiveActivity(channelId)

FirebaseMessaging.onMessage.listen((message) {
  final update = LiveActivityUpdate.fromData(message.data);
  if (update == null) return; // not a Live Activity update
  // show or update one ongoing notification with id update.notificationId,
  // and remove it when update.isEnd (e.g. with flutter_local_notifications)
});
```

Subscribe again when FCM issues a new token (`onTokenRefresh`).

**iOS** subscribes the Live Activity itself with ActivityKit in native Swift code, using the channel's `channel_id`: `Activity.request(attributes:content:pushType: .channel(channelId))`. `subscribeLiveActivity` throws `platform_not_supported` on iOS.

## Testing / injection

`storage` (`KeyValueStorage`, default `shared_preferences`; `MemoryStorage` included),
`httpClient` (`package:http` `Client`) and `socketConnector` (returns an `IAlertSocket`)
are all constructor parameters. See `test/helpers.dart` for fakes.

```bash
flutter analyze && flutter test
```

## Native push (notifications while the app is closed)

Use `firebase_messaging` for the native side and give iAlert the token it needs: the **FCM token on Android** and the **APNs token on iOS** (iAlert sends to APNs directly with your `.p8`).

```dart
final messaging = FirebaseMessaging.instance;
await messaging.requestPermission();

final token = Platform.isIOS ? await messaging.getAPNSToken() : await messaging.getToken();
await ialert.register(pushToken: token, externalUserId: 'user-42');
messaging.onTokenRefresh.listen((_) async => ialert.register(
    pushToken: Platform.isIOS ? await messaging.getAPNSToken() : await messaging.getToken()));

// While the app is open: deduplicated against the Gateway and Inbox, acked as delivered.
FirebaseMessaging.onMessage.listen((m) => ialert.didReceivePush(m.data,
    title: m.notification?.title, body: m.notification?.body));

// A tap on a notification: acked as clicked.
FirebaseMessaging.onMessageOpenedApp.listen((m) => ialert.didOpenPush(m.data));
```

Without a native token the device still gets messages while the app runs (Gateway) and on the next launch (Inbox). Showing Inbox messages as local notifications in the background during an internet shutdown needs the native iOS/Android SDKs' background sync and is not part of this package yet.

## Auth Push (approve a sign-in on the phone)

When your server creates an Auth Push request (`POST /v1/auth-requests`), every device of that user gets a high-priority push. Show your own approve/deny screen and answer with the device's token:

```dart
ialert.messages.listen((message) async {
  final request = AuthRequestInfo.of(message); // null for other messages
  if (request == null) return;
  // show your approve/deny screen with request.context (ip, city, device…)
  await ialert.respondToAuthRequest(request.id,
      approve: userApproved, code: request.numberMatching ? typedNumber : null);
});
```

With number matching, the user types the two-digit number shown on your sign-in page; a wrong number denies the request. An unknown or expired request throws without clearing the device registration.

## License

Copyright 2026 iAlert.ir

Licensed under the [Apache License, Version 2.0](LICENSE). See [NOTICE](NOTICE).
