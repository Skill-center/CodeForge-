package dev.codeforge.app

import io.flutter.embedding.android.FlutterActivity

/**
 * CodeForge Android host.
 *
 * Phase 1: pure Flutter embedding. Runtime/session/storage services and the
 * Pigeon boundary arrive in later phases (docs/ARCHITECTURE.md §3); this class
 * stays an orchestration-only entry point.
 */
class MainActivity : FlutterActivity()
