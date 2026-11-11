package ir.ialert.flutter

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Android side of ialert_flutter. Native FCM (through iAlert's own Firebase
 * project), notification display and the background Inbox sync come with the
 * Android SDK work; until then the app receives messages over the Gateway and
 * Inbox, and `getToken` returns null.
 */
class IAlertFlutterPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "ir.ialert/push")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestPermission" -> result.success(false)
            "getToken", "takeInitialOpen" -> result.success(null)
            "setRegistration" -> result.success(null)
            else -> result.notImplemented()
        }
    }
}
