package ir.ialert.flutter

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import ir.ialert.sdk.IAlertBridge

/**
 * Android side of ialert_flutter, on the iAlert Android SDK: the FCM token of the app's own
 * Firebase project (its service account and google-services.json are in the iAlert panel, so
 * no Firebase setup in the app),
 * notification channels and display, taps (opening `data.url`), and the WorkManager sync that
 * shows Inbox messages while FCM is unreachable. The Dart client registers the device and
 * runs the Gateway.
 */
class IAlertFlutterPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, IAlertBridge.Events {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "ir.ialert/push")
        channel.setMethodCallHandler(this)
        IAlertBridge.attach(context, this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        IAlertBridge.detach()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestPermission" -> result.success(IAlertBridge.requestPermission())
            "getToken" -> {
                val publicKey = call.argument<String>("publicKey")
                val apiUrl = call.argument<String>("apiUrl")
                if (publicKey == null || apiUrl == null) {
                    result.success(null)
                } else {
                    IAlertBridge.token(context, publicKey, apiUrl) { result.success(it) }
                }
            }
            "takeInitialOpen" -> result.success(IAlertBridge.takeInitialOpen()?.let { mapOf("userInfo" to it) })
            "setRegistration" -> {
                val publicKey = call.argument<String>("publicKey")
                val apiUrl = call.argument<String>("apiUrl")
                val deviceId = call.argument<String>("deviceId")
                val deviceToken = call.argument<String>("deviceToken")
                if (publicKey != null && apiUrl != null && deviceId != null && deviceToken != null) {
                    IAlertBridge.setRegistration(context, publicKey, apiUrl, deviceId, deviceToken)
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onToken(token: String) {
        channel.invokeMethod("onToken", token)
    }

    override fun onPush(data: Map<String, String>, title: String?, body: String?) {
        channel.invokeMethod("onPush", mapOf("userInfo" to data, "title" to title, "body" to body))
    }

    override fun onOpen(data: Map<String, String>) {
        channel.invokeMethod("onOpen", mapOf("userInfo" to data))
    }
}
