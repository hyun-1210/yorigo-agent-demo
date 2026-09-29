package com.yorigo.app

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "yorigo.app/share"
    private var sharedText: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "getInitialSharedText") {
                result.success(sharedText)
                sharedText = null // Clear after sending
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent == null) return

        val action = intent.action
        val type = intent.type

        if (Intent.ACTION_SEND == action && type != null) {
            if ("text/plain" == type) {
                val sharedTextValue = intent.getStringExtra(Intent.EXTRA_TEXT)
                if (sharedTextValue != null) {
                    sharedText = sharedTextValue
                    // Send to Flutter if engine is ready
                    flutterEngine?.let { engine ->
                        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
                            .invokeMethod("sharedText", sharedTextValue)
                    }
                }
            }
        }
    }
}
