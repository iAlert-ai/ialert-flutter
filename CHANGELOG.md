# Changelog

## 0.5.0

- Now a Flutter plugin with its own native code: `IAlert.init()` sets everything up without `firebase_messaging` or AppDelegate code.
- iOS: permission, APNs token, foreground display, taps (opens `data.url`) and background Inbox sync as local notifications when `<bundle id>.ialert-sync` is permitted.
- Custom notification sounds in background-sync notifications on iOS (`none` is silent).
- Android, on the iAlert Android SDK 0.5.0: FCM token without Firebase setup (iAlert's shared project or the app's own), notifications with image and custom sound, taps (open `data.url`), background sync every 15 minutes for messages FCM could not deliver, and Live Activity broadcasts as ongoing notifications. `minSdk` 23.
- `IAlert.publicKey` and `IAlert.apiUrl` getters.

## 0.4.0

- Auth Push: `respondToAuthRequest` approves or denies a sign-in request on this device (with the typed number for number matching), and a helper reads the request a message carries.

## 0.3.0

- Native push: `didReceivePush(data, title:, body:)` and `didOpenPush(data)` take pushes from `firebase_messaging` (FCM data with `ialert_id`, or an APNs `ialert` payload), deduplicate them against the Gateway and Inbox, and ack delivered / clicked.

## 0.2.0

- Live Activity broadcasts on Android: `subscribeLiveActivity(channelId)` / `unsubscribeLiveActivity(channelId)` (iOS throws `platform_not_supported`; subscribe with ActivityKit there), and `LiveActivityUpdate.fromData(data)` reads the broadcast from an FCM data message.
- A 404 for an unknown channel no longer clears the device registration.
- `example/` test app (bundle and application id `io.iAlert.Test`).

## 0.1.0

- First release: device registration with a public key, tags and external user id, a live connection to the iAlert Gateway over WebSocket with reconnect, Inbox sync after each connect, delivered/read/clicked acknowledgements and message de-duplication.
- Licensed under Apache 2.0.
