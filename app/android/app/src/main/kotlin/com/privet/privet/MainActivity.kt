package com.privet.privet

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "privet/screen_capture",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    ScreenCaptureService.start(this)
                    result.success(null)
                }
                "stop" -> {
                    ScreenCaptureService.stop(this)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "privet/realtime",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    RealtimeConnectionService.start(this)
                    result.success(null)
                }
                "stop" -> {
                    RealtimeConnectionService.stop(this)
                    result.success(null)
                }
                "requestBatteryExemption" -> {
                    val ok = RealtimeConnectionService.requestIgnoreBatteryOptimizations(this)
                    result.success(ok)
                }
                else -> result.notImplemented()
            }
        }
    }
}
