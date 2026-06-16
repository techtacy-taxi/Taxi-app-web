package com.example.my_taxi_app

import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.InputStreamReader

// MainActivity με γέφυρα για άνοιγμα αρχείων .ics (κρατήσεις ταξί).
// Διαβάζει το περιεχόμενο του .ics από το intent (άνοιγμα ή κοινοποίηση)
// και το στέλνει στο Flutter (ics_intent.dart) μέσω MethodChannel.
class MainActivity : FlutterActivity() {

    private val channelName = "athens_taxi/ics"
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                // Το Flutter ζητά το αρχείο που άνοιξε την εφαρμογή (cold start)
                "getInitialIcs" -> result.success(readIcsFromIntent(intent))
                else -> result.notImplemented()
            }
        }
    }

    // Όταν η εφαρμογή τρέχει ήδη και ανοίξει νέο .ics (singleTop)
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val content = readIcsFromIntent(intent)
        if (content != null) {
            channel?.invokeMethod("onIcs", content)
        }
    }

    private fun readIcsFromIntent(intent: Intent?): String? {
        if (intent == null) return null
        val action = intent.action

        val uri: Uri? = when (action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND -> {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
            }
            else -> intent.data
        }

        if (uri == null) {
            // Κοινοποίηση ως απλό κείμενο
            if (action == Intent.ACTION_SEND) {
                val txt = intent.getStringExtra(Intent.EXTRA_TEXT)
                if (txt != null && txt.contains("VCALENDAR")) return txt
            }
            return null
        }

        return try {
            contentResolver.openInputStream(uri)?.use { stream ->
                BufferedReader(InputStreamReader(stream, Charsets.UTF_8)).readText()
            }
        } catch (e: Exception) {
            null
        }
    }
}
