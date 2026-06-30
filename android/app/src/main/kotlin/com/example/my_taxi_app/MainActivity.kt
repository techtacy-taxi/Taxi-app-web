package com.example.my_taxi_app

import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.File
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
                // Το Flutter ζητά να ΑΝΟΙΞΕΙ ένα .ics (εξαγωγή δουλειών → ημερολόγιο)
                "openIcs" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.success(false)
                    } else {
                        result.success(openIcsFile(path))
                    }
                }
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

    // Ανοίγει ένα τοπικό .ics αρχείο μέσω FileProvider με ACTION_VIEW
    // (mime text/calendar) → εμφανίζεται το Ημερολόγιο για προσθήκη event(s).
    private fun openIcsFile(path: String): Boolean {
        return try {
            val file = File(path)
            if (!file.exists()) return false
            val uri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                file
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "text/calendar")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
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
