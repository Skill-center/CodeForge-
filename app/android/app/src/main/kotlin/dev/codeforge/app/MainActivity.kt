package dev.codeforge.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * CodeForge Android host.
 *
 * Orchestration only (docs/ARCHITECTURE.md §3). Its one channel tells Dart
 * where the app keeps its files (Phase 2 W4, lib/services/platform/
 * app_directories.dart); runtime and session services and the Pigeon boundary
 * arrive in later phases.
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PATHS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "filesDir" -> result.success(filesDir.absolutePath)
                    else -> result.notImplemented()
                }
            }
    }

    private companion object {
        const val PATHS_CHANNEL = "dev.codeforge/paths"
    }
}
