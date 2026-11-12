import BackgroundTasks
import Flutter
import UIKit
import UserNotifications

/// Native side of ialert_flutter on iOS: notification permission, the APNs token
/// (through Flutter's application-delegate forwarding, no AppDelegate code),
/// foreground display and taps of iAlert notifications, and the background Inbox
/// sync that shows messages as local notifications while APNs is unreachable.
public final class IAlertFlutterPlugin: NSObject, FlutterPlugin, UNUserNotificationCenterDelegate {
    private static let defaults = UserDefaults.standard
    private static let registrationKey = "ialert.native.registration"
    private static let shownKey = "ialert.native.shown"

    private let channel: FlutterMethodChannel
    private weak var previousDelegate: UNUserNotificationCenterDelegate?
    private var token: String?
    private var initialOpen: [String: Any]?

    init(channel: FlutterMethodChannel) {
        self.channel = channel
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "ir.ialert/push", binaryMessenger: registrar.messenger())
        let instance = IAlertFlutterPlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
        registrar.addApplicationDelegate(instance)

        let center = UNUserNotificationCenter.current()
        if let current = center.delegate, current !== instance {
            instance.previousDelegate = current
        }
        center.delegate = instance

        if backgroundSyncAllowed {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: syncIdentifier, using: nil) { task in
                scheduleBackgroundSync()
                let work = Task {
                    await backgroundSync()
                    task.setTaskCompleted(success: true)
                }
                task.expirationHandler = { work.cancel() }
            }
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                scheduleBackgroundSync()
            }
        }
    }

    // MARK: Method channel

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "requestPermission":
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                    result(granted)
                }
            }
        case "getToken":
            result(token)
        case "deviceInfo":
            result(Self.deviceInfo())
        case "takeInitialOpen":
            result(initialOpen)
            initialOpen = nil
        case "setRegistration":
            Self.defaults.set(call.arguments as? [String: Any], forKey: Self.registrationKey)
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: Application delegate (forwarded by Flutter)

    public func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        token = hex
        channel.invokeMethod("onToken", arguments: hex)
    }

    // MARK: Notification center (forwarded to the app's previous delegate)

    private static func isIAlert(_ notification: UNNotification) -> Bool {
        notification.request.content.userInfo["ialert"] != nil
    }

    private static func payload(_ notification: UNNotification) -> [String: Any] {
        let content = notification.request.content
        return [
            "userInfo": sanitize(content.userInfo),
            "title": content.title,
            "body": content.body,
        ]
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if Self.isIAlert(notification) {
            channel.invokeMethod("onPush", arguments: Self.payload(notification))
        }
        if let previousDelegate, previousDelegate.responds(to: #selector(userNotificationCenter(_:willPresent:withCompletionHandler:))) {
            previousDelegate.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler)
            return
        }
        completionHandler(Self.isIAlert(notification) ? [.banner, .list, .sound] : [])
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let notification = response.notification
        if Self.isIAlert(notification) {
            let payload = Self.payload(notification)
            initialOpen = payload // read by Dart after a cold start
            channel.invokeMethod("onOpen", arguments: payload)
            Self.openURL(notification.request.content.userInfo)
        }
        if let previousDelegate, previousDelegate.responds(to: #selector(userNotificationCenter(_:didReceive:withCompletionHandler:))) {
            previousDelegate.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler)
            return
        }
        completionHandler()
    }

    /// Opens the notification's `url` (`data.url` for older messages): a deep link with the
    /// app's scheme comes back to the app (handled by `Linking`), a web link opens Safari or a Universal Link.
    /// Hardware identifier (`iPhone16,2`; the simulated one on the Simulator) and iOS version.
    static func deviceInfo() -> [String: String] {
        var info = ["osVersion": UIDevice.current.systemVersion]
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            info["model"] = simulated
        } else {
            var size = 0
            sysctlbyname("hw.machine", nil, &size, nil, 0)
            if size > 0 {
                var machine = [CChar](repeating: 0, count: size)
                sysctlbyname("hw.machine", &machine, &size, nil, 0)
                info["model"] = String(cString: machine)
            }
        }
        return info
    }

    private static func openURL(_ userInfo: [AnyHashable: Any]) {
        let ialert = userInfo["ialert"] as? [String: Any]
        let data = ialert?["data"] as? [String: Any]
        let string = (ialert?["url"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? data?["url"] as? String
        guard let string, let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              !["javascript", "file", "data"].contains(scheme) else { return }
        DispatchQueue.main.async { UIApplication.shared.open(url) }
    }

    /// Keep only values the standard method codec can send.
    private static func sanitize(_ value: Any) -> Any {
        switch value {
        case let dict as [AnyHashable: Any]:
            var out: [String: Any] = [:]
            for (key, item) in dict { if let key = key as? String { out[key] = sanitize(item) } }
            return out
        case let array as [Any]:
            return array.map(sanitize)
        case is String, is NSNumber, is NSNull:
            return value
        default:
            return "\(value)"
        }
    }

    // MARK: Background Inbox sync (internet shutdown)

    static var syncIdentifier: String { "\(Bundle.main.bundleIdentifier ?? "app").ialert-sync" }

    /// `BGTaskScheduler.register` crashes for identifiers missing from Info.plist.
    static var backgroundSyncAllowed: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []).contains(syncIdentifier)
    }

    static func scheduleBackgroundSync() {
        let request = BGAppRefreshTaskRequest(identifier: syncIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Pull unread Inbox entries that no channel delivered and show them as local notifications.
    static func backgroundSync() async {
        guard let registration = defaults.dictionary(forKey: registrationKey),
              let apiUrl = registration["apiUrl"] as? String,
              let deviceId = registration["deviceId"] as? String,
              let deviceToken = registration["deviceToken"] as? String,
              let id = deviceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(apiUrl)/devices/\(id)/inbox?per_page=100&unread=1") else { return }

        let bearer = (registration["publicKey"] as? String).map { "Bearer \($0)" }
        var request = URLRequest(url: url)
        request.setValue(bearer, forHTTPHeaderField: "Authorization")
        request.setValue(deviceToken, forHTTPHeaderField: "X-Device-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (body, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let entries = json["data"] as? [[String: Any]] else { return }

        let center = UNUserNotificationCenter.current()
        let showing = Set(await center.deliveredNotifications().compactMap { ($0.request.content.userInfo["ialert"] as? [String: Any])?["id"] as? String })
        var shown = defaults.stringArray(forKey: shownKey) ?? []
        var delivered: [String] = []

        for entry in entries.reversed() {
            guard let entryId = entry["id"] as? String, entry["delivered_at"] is NSNull || entry["delivered_at"] == nil else { continue }
            // APNs already showed pushed entries; leave them unacknowledged so a sync after
            // the platform switched to the internal network still shows them.
            if entry["pushed"] as? Bool == true { continue }
            delivered.append(entryId)
            guard !showing.contains(entryId), !shown.contains(entryId) else { continue }

            let message = entry["content"] as? [String: Any] ?? [:]
            let title = message["title"] as? String
            let text = message["body"] as? String
            guard title != nil || text != nil else { continue }

            let content = UNMutableNotificationContent()
            content.title = title ?? ""
            content.body = text ?? ""
            switch message["sound"] as? String {
            case nil, "default": content.sound = .default
            case "none": content.sound = nil
            case let name?: content.sound = UNNotificationSound(named: UNNotificationSoundName(name))
            }
            var ialert: [String: Any] = ["id": entryId]
            ialert["data"] = message["data"] as? [String: Any]
            ialert["image"] = message["image"] as? String
            ialert["url"] = message["url"] as? String
            content.userInfo = ["ialert": ialert]
            try? await center.add(UNNotificationRequest(identifier: "ialert-\(entryId)", content: content, trigger: nil))
            shown.append(entryId)
        }

        defaults.set(Array(shown.suffix(500)), forKey: shownKey)

        if !delivered.isEmpty, let ackURL = URL(string: "\(apiUrl)/devices/\(id)/inbox/ack") {
            var ack = URLRequest(url: ackURL)
            ack.httpMethod = "POST"
            ack.setValue(bearer, forHTTPHeaderField: "Authorization")
            ack.setValue(deviceToken, forHTTPHeaderField: "X-Device-Token")
            ack.setValue("application/json", forHTTPHeaderField: "Content-Type")
            ack.setValue("application/json", forHTTPHeaderField: "Accept")
            ack.httpBody = try? JSONSerialization.data(withJSONObject: ["ids": Array(delivered.prefix(100)), "event": "delivered"])
            _ = try? await URLSession.shared.data(for: ack)
        }
    }
}
