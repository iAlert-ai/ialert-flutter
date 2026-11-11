# iAlert Flutter SDK

Flutter client for [iAlert](https://ialert.ir) push notifications (`ialert_flutter` 0.5.0).
Messages arrive over iAlert's own Gateway WebSocket and the per-device Inbox, so
delivery keeps working inside Iran when international internet is cut.

## Install

```yaml
dependencies:
  ialert_flutter: ^0.5.0
```

## Quick start

No Firebase or other packages, and no AppDelegate / MainActivity code:

```dart
import 'package:ialert_flutter/ialert_flutter.dart';

void main() {
  final ialert = IAlert.init(publicKey: 'ia_pk_...', externalUserId: 'user-42');
  ialert.messages.listen((m) => print('${m.title}: ${m.body}')); // optional
  runApp(const MyApp());
}
```

`init` asks for notification permission, gets the native push token through the plugin's own native code, registers the device, keeps the Gateway connected, shows iAlert notifications while the app is open, reports taps (and opens `data.url`) and syncs the Inbox.

**iOS** needs two things Apple does not let a package do: the **Push Notifications** capability in Xcode, and the app's APNs key (`.p8`) in the iAlert panel. For delivery during an internet shutdown, also enable **Background Modes → Background fetch** and add `<bundle id>.ialert-sync` under `BGTaskSchedulerPermittedIdentifiers` in Info.plist: the plugin then pulls missed Inbox messages in the background and shows them as local notifications (iOS decides when, so they may be delayed).

**Custom sound:** put the sound file in the app (iOS: add `order.caf` to the Runner target; Android: `res/raw/order.mp3`) and send with `"sound": "order.caf"`. `"sound": "none"` is silent.

**Android:** nothing to configure in the app. For Android's official push (FCM), upload your Firebase project's service account JSON and its `google-services.json` in the iAlert panel; the plugin (on the iAlert Android SDK) then gets the FCM token with no `google-services.json` or Firebase plugin in the app. Without them, devices get messages over the iAlert Gateway, the Inbox and the background sync. It also brings notifications with images and custom sounds; taps open `data.url`; and a background sync every 15 minutes shows messages that could not be pushed while FCM is unreachable. The app's `minSdk` must be 23 or later.

## Usage (manual)

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

**Android** joins through iAlert once `IAlert.init` has registered the device with its FCM token:

```dart
await ialert.ready;
await ialert.subscribeLiveActivity(channelId); // and unsubscribeLiveActivity(channelId)
```

The plugin shows each channel as one ongoing notification, updated in place and removed when the broadcast ends. (Using `firebase_messaging` yourself instead, `LiveActivityUpdate.fromData(message.data)` reads a broadcast.)

**iOS** subscribes the Live Activity itself with ActivityKit in native Swift code, using the channel's `channel_id`: `Activity.request(attributes:content:pushType: .channel(channelId))`. `subscribeLiveActivity` throws `platform_not_supported` on iOS.

## Testing / injection

`storage` (`KeyValueStorage`, default `shared_preferences`; `MemoryStorage` included),
`httpClient` (`package:http` `Client`) and `socketConnector` (returns an `IAlertSocket`)
are all constructor parameters. See `test/helpers.dart` for fakes.

```bash
flutter analyze && flutter test
```

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
