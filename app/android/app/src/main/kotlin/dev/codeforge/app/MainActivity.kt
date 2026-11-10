package dev.codeforge.app

import android.app.backup.BackupManager
import android.content.res.Configuration
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * CodeForge Android host.
 *
 * Orchestration only (docs/ARCHITECTURE.md §3). Its channels tell Dart where
 * the app keeps its files (Phase 2 W4, lib/services/platform/
 * app_directories.dart; the folder Android never backs up, for the logs,
 * since Phase 3 W1), whether a hardware keyboard is attached (W6,
 * lib/services/platform/hardware_keyboard.dart), and read and set the
 * backup switch (Phase 3 W1, ADR-0012, lib/services/platform/
 * backup_channel.dart). The Pigeon boundary arrives with the storage broker
 * (Phase 3 W2), which folds the backup channel in.
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
                    "noBackupFilesDir" -> result.success(noBackupFilesDir.absolutePath)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(messenger, BACKUP_CHANNEL)
            .setMethodCallHandler { call, result ->
                val backup = BackupSwitch(this)
                when (call.method) {
                    "status" -> result.success(backup.status())
                    "setEnabled" -> {
                        val enabled = call.argument<Boolean>("enabled")
                        when {
                            enabled == null ->
                                result.error("bad_arguments", "setEnabled needs enabled", null)
                            !backup.setEnabled(enabled) ->
                                result.error("not_saved", "The backup switch was not saved.", null)
                            else -> {
                                // A hint that a backup is due; Android still
                                // decides when (about daily, idle, on Wi-Fi).
                                BackupManager(this).dataChanged()
                                result.success(backup.status())
                            }
                        }
                    }
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
        const val BACKUP_CHANNEL = "dev.codeforge/backup"
        const val KEYBOARD_CHANNEL = "dev.codeforge/keyboard"

        /** A typing keyboard is attached and not folded or slid away. */
        fun hasHardwareKeyboard(config: Configuration): Boolean =
            config.keyboard == Configuration.KEYBOARD_QWERTY &&
                config.hardKeyboardHidden == Configuration.HARDKEYBOARDHIDDEN_NO
    }
}
