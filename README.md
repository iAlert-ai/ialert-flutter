# iAlert Flutter SDK

Flutter client for [iAlert](https://ialert.ir) push notifications (`ialert` 0.1.0).
Messages arrive over iAlert's own Gateway WebSocket and the per-device Inbox, so
delivery keeps working inside Iran when international internet is cut.

## Install

```yaml
dependencies:
  ialert: ^0.1.0
```

## Usage

```dart
import 'package:ialert/ialert.dart';

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

## Testing / injection

`storage` (`KeyValueStorage`, default `shared_preferences`; `MemoryStorage` included),
`httpClient` (`package:http` `Client`) and `socketConnector` (returns an `IAlertSocket`)
are all constructor parameters. See `test/helpers.dart` for fakes.

```bash
flutter analyze && flutter test
```

## Next

Native FCM (Android) and APNs (iOS) integration is not in 0.1.0: get the token with
your own plugin (e.g. `firebase_messaging`) and pass it as `pushToken`. Without it the
device only receives messages while the app runs (Gateway) or on next launch (Inbox).
