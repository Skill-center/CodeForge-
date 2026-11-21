package dev.codeforge.app

import android.app.backup.BackupManager
import android.content.Intent
import android.content.res.Configuration
import dev.codeforge.app.runtime.RuntimeApi
import dev.codeforge.app.runtime.RuntimeHost
import dev.codeforge.app.storage.StorageApi
import dev.codeforge.app.search.SearchApi
import dev.codeforge.app.search.SearchHost
import dev.codeforge.app.storage.StorageBroker
import dev.codeforge.app.storage.StorageEvents
import dev.codeforge.app.terminal.TerminalApi
import dev.codeforge.app.terminal.TerminalHost
import dev.codeforge.app.webview.PagePorts
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
 * backup_channel.dart). Those three are small plain MethodChannels and stay
 * so. Folders from shared storage go through the storage broker (Phase 3
 * W2, storage/StorageBroker.kt), behind the typed Pigeon API of
 * pigeons/storage_api.dart; the folder picker answers here, in
 * [onActivityResult]. The sealed runtime (Phase 4 W3, runtime/RuntimeHost.kt)
 * is behind the typed Pigeon API of pigeons/runtime_api.dart. The terminal
 * page's MessagePort (Phase 5 W6, webview/PagePorts.kt) is a plugin of the
 * app's own, added here: it needs a plugin binding to reach the WebView.
 */
class MainActivity : FlutterActivity() {
    private var keyboardChannel: MethodChannel? = null
    private var storage: StorageBroker? = null
    private var runtime: RuntimeHost? = null
    private var search: SearchHost? = null
    private var terminal: TerminalHost? = null

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
        storage = StorageBroker(this, StorageEvents(messenger)).also { StorageApi.setUp(messenger, it) }
        runtime = RuntimeHost(this, messenger).also { RuntimeApi.setUp(messenger, it) }
        val broker = storage
        if (broker != null) {
            search = SearchHost(this, messenger, broker::searchOps).also { SearchApi.setUp(messenger, it) }
        }
        terminal = TerminalHost(this, messenger).also { TerminalApi.setUp(messenger, it) }
        flutterEngine.plugins.add(PagePorts())
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        flutterEngine.plugins.remove(PagePorts::class.java)
        keyboardChannel?.setMethodCallHandler(null)
        keyboardChannel = null
        StorageApi.setUp(flutterEngine.dartExecutor.binaryMessenger, null)
        storage?.close()
        storage = null
        RuntimeApi.setUp(flutterEngine.dartExecutor.binaryMessenger, null)
        runtime?.close()
        runtime = null
        SearchApi.setUp(flutterEngine.dartExecutor.binaryMessenger, null)
        search?.close()
        search = null
        TerminalApi.setUp(flutterEngine.dartExecutor.binaryMessenger, null)
        terminal?.close()
        terminal = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    // The folder picker's answer (StorageBroker.pickTree). Activity's own
    // callback: FlutterActivity is not an androidx ComponentActivity, so
    // there is no activity-result API to register with.
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (storage?.onActivityResult(requestCode, resultCode, data) == true) {
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
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
