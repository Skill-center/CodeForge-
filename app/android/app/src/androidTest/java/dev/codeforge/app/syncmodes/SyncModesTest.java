package dev.codeforge.app.syncmodes;

import androidx.test.rule.ActivityTestRule;

import org.junit.Rule;
import org.junit.runner.RunWith;

import dev.codeforge.app.MainActivity;
import dev.flutter.plugins.integration_test.FlutterTestRunner;

/**
 * The session store's sync modes on a Test Lab phone (Phase 4 W5, ADR-0008):
 * starts the app, whose Dart entrypoint in that build is
 * {@code integration_test/sync_modes_test.dart}, and reports each of its Dart
 * tests as a JUnit test, through integration_test's FlutterTestRunner (the
 * setup Flutter documents for Firebase Test Lab).
 *
 * <p>Only the Test Lab job's build has that entrypoint. In any other build the
 * app starts its own UI and this runner waits for test results that never come,
 * so the gates name the classes they run ({@code -e class}, Test Lab's
 * {@code --test-targets}), and this one only where the app was built for it.
 * The package sorts after {@code dev.codeforge.app.runtime}: AndroidJUnitRunner
 * runs classes in name order, so the runtime's tests have run and reported
 * before this one starts the app.</p>
 */
@RunWith(FlutterTestRunner.class)
public class SyncModesTest {
    @Rule
    public ActivityTestRule<MainActivity> rule =
        new ActivityTestRule<>(MainActivity.class, true, false);
}
