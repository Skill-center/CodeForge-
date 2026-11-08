package dev.codeforge.app

import android.content.res.Configuration
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * CodeForge Android host.
 *
 * Orchestration only (docs/ARCHITECTURE.md §3). Its channels tell Dart where
 * the app keeps its files (Phase 2 W4, lib/services/platform/
 * app_directories.dart) and whether a hardware keyboard is attached (W6,
 * lib/services/platform/hardware_keyboard.dart); runtime and session
 * services and the Pigeon boundary arrive in later phases.
 */
class MainActivity : FlutterActivity() {
    private var keyboardChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, PATHS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "filesDir" -> result.success(filesDir.absolutePath)
                    else -> result.notImplemented()
                }
            }
        keyboardChannel = MethodChannel(messenger, KEYBOARD_CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "attached" -> result.success(hasHardwareKeyboard(resources.configuration))
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        keyboardChannel?.setMethodCallHandler(null)
        keyboardChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    // The manifest keeps keyboard changes from recreating the activity (and
    // with it the editor's WebView), so they arrive here instead.
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        keyboardChannel?.invokeMethod("changed", hasHardwareKeyboard(newConfig))
    }

    private companion object {
        const val PATHS_CHANNEL = "dev.codeforge/paths"
        const val KEYBOARD_CHANNEL = "dev.codeforge/keyboard"

        /** A typing keyboard is attached and not folded or slid away. */
        fun hasHardwareKeyboard(config: Configuration): Boolean =
            config.keyboard == Configuration.KEYBOARD_QWERTY &&
                config.hardKeyboardHidden == Configuration.HARDKEYBOARDHIDDEN_NO
    }
}
