/// Settings → Developer → Log viewer (Phase 3 W6, a Phase 1 item the owner
/// placed in W6): this session's records, newest first, by level and tag.
library;

import 'package:codeforge/core/logging/logger.dart';
import 'package:codeforge/design_system/components/buttons.dart';
import 'package:codeforge/features/settings/developer/log_viewer_screen.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'test_harness.dart';

/// Records clipboard writes instead of reaching the platform.
List<String> _clipboard(WidgetTester tester) {
  final copied = <String>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      final arguments = call.arguments as Map<Object?, Object?>;
      copied.add(arguments['text']! as String);
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return copied;
}

/// A logger with one record of each level, over three tags.
CfLogger _logger() => CfLogger()
  ..debug('editor', 'page_ready')
  ..info('documents', 'opened', fields: {'path': 'src/main.js'})
  ..warn('files', 'listing_slow', fields: {'ms': 900})
  ..error(
    'provider',
    'failed',
    fields: {
      'error':
          'no folder at content://com.android.externalstorage.documents/'
          'tree/primary%3ADocuments',
    },
  );

/// The text of every record line shown, top to bottom.
List<String> _shown(WidgetTester tester) => [
  for (final text in tester.widgetList<Text>(
    find.descendant(
      of: find.byKey(const ValueKey('log_viewer_list')),
      matching: find.byType(Text),
    ),
  ))
    text.data!,
];

String _count(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('log_viewer_count'))).data!;

String _tagsLabel(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('log_viewer_tags_label')))
    .data!;

/// Chooses [tag] in the tag menu, or "All tags" for null.
Future<void> _chooseTag(WidgetTester tester, String? tag) async {
  await tester.tap(find.byKey(const ValueKey('log_viewer_tags')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('log_tag_${tag ?? 'all'}')));
  await tester.pumpAndSettle();
}

Future<void> _pumpViewer(WidgetTester tester, CfLogger logger) async {
  setSurface(tester, 412, 915);
  await tester.pumpWidget(TestHarness().wrap(LogViewerScreen(logger: logger)));
  await tester.pumpAndSettle();
}

void main() {
  group('filterLogRecords', () {
    final records = _logger().records;

    test('keeps every record by default, newest first', () {
      expect(filterLogRecords(records).map((r) => r.event), [
        'failed',
        'listing_slow',
        'opened',
        'page_ready',
      ]);
    });

    test('keeps the level chosen and the levels above it', () {
      expect(
        filterLogRecords(records, minimum: LogLevel.warn).map((r) => r.level),
        [LogLevel.error, LogLevel.warn],
      );
      expect(
        filterLogRecords(records, minimum: LogLevel.error).map((r) => r.tag),
        ['provider'],
      );
    });

    test('keeps the tags chosen, any of them', () {
      expect(
        filterLogRecords(records, tags: {'files', 'editor'}).map((r) => r.tag),
        ['files', 'editor'],
      );
      expect(
        filterLogRecords(records, minimum: LogLevel.info, tags: {'editor'}),
        isEmpty,
      );
    });

    test('lists the tags in order', () {
      expect(logTagsOf(records), ['documents', 'editor', 'files', 'provider']);
      expect(logTagsOf(const []), isEmpty);
    });
  });

  testWidgets('settings opens the log viewer from Developer', (tester) async {
    setSurface(tester, 412, 1400);
    await tester.pumpWidget(
      TestHarness(shell: const ShellState(lastRoute: '/settings')).app(),
    );
    await tester.pumpAndSettle();
    final tile = find.byKey(const ValueKey('settings_log_viewer'));
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.byType(LogViewerScreen), findsOneWidget);
    expect(find.text('Log viewer'), findsOneWidget);

    // Let the shell's debounced route persistence fire before teardown.
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('shows every record, newest first, redacted', (tester) async {
    await _pumpViewer(tester, _logger());

    final shown = _shown(tester);
    expect(shown, hasLength(4));
    expect(shown.first, contains('[error] provider/failed'));
    expect(shown.last, contains('[debug] editor/page_ready'));
    // The logger redacted the URI before the viewer saw it.
    expect(
      shown.first,
      contains('content://com.android.externalstorage.documents/…'),
    );
    expect(shown.first, isNot(contains('primary%3A')));
    expect(_count(tester), 'Showing 4 of 4 entries');
  });

  testWidgets('narrows by level, then by tag, and back', (tester) async {
    await _pumpViewer(tester, _logger());

    await tester.tap(find.byKey(const ValueKey('log_level_warn')));
    await tester.pumpAndSettle();
    expect(_shown(tester), [
      contains('[error] provider/failed'),
      contains('[warn] files/listing_slow'),
    ]);
    expect(_count(tester), 'Showing 2 of 4 entries');

    expect(_tagsLabel(tester), 'Tags: all');
    await _chooseTag(tester, 'files');
    expect(_shown(tester), [contains('[warn] files/listing_slow')]);
    expect(_count(tester), 'Showing 1 of 4 entries');
    expect(_tagsLabel(tester), 'Tags: files');

    await _chooseTag(tester, 'provider');
    expect(_shown(tester), hasLength(2));
    expect(_tagsLabel(tester), 'Tags: files, provider');

    await tester.tap(find.byKey(const ValueKey('log_level_error')));
    await tester.pumpAndSettle();
    expect(_shown(tester), [contains('[error] provider/failed')]);

    // Choosing a chosen tag again lets it go.
    await _chooseTag(tester, 'provider');
    expect(find.byKey(const ValueKey('log_viewer_list')), findsNothing);
    expect(find.text('No entries at this level and tag'), findsOneWidget);

    await _chooseTag(tester, null);
    await tester.tap(find.byKey(const ValueKey('log_level_debug')));
    await tester.pumpAndSettle();
    expect(_shown(tester), hasLength(4));
    expect(_tagsLabel(tester), 'Tags: all');
  });

  testWidgets('follows records logged while it is open', (tester) async {
    final logger = _logger();
    await _pumpViewer(tester, logger);

    logger.info('watch', 'folder_changed', fields: {'folder': 'src'});
    await tester.pumpAndSettle();

    expect(_shown(tester).first, contains('[info] watch/folder_changed'));
    expect(_count(tester), 'Showing 5 of 5 entries');
    // Its tag joins the menu.
    await _chooseTag(tester, 'watch');
    expect(_shown(tester), [contains('[info] watch/folder_changed')]);
  });

  testWidgets('copies what it shows, oldest first', (tester) async {
    final copied = _clipboard(tester);
    final logger = _logger();
    await _pumpViewer(tester, logger);

    await tester.tap(find.byKey(const ValueKey('log_level_info')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('log_viewer_copy')));
    await tester.pumpAndSettle();

    expect(copied, hasLength(1));
    final lines = copied.single.split('\n');
    expect(lines, hasLength(3));
    expect(lines.first, contains('[info] documents/opened path=src/main.js'));
    expect(lines.last, contains('[error] provider/failed'));
    expect(find.text('Copied 3 entries'), findsOneWidget);
  });

  testWidgets('says so when the log is empty, and copies nothing', (
    tester,
  ) async {
    await _pumpViewer(tester, CfLogger());

    expect(find.text('No log entries yet'), findsOneWidget);
    expect(find.byKey(const ValueKey('log_viewer_tags')), findsNothing);
    expect(_count(tester), 'Showing 0 of 0 entries');
    final copy = tester.widget<CfIconButton>(
      find.byKey(const ValueKey('log_viewer_copy')),
    );
    expect(copy.onPressed, isNull);
  });

  testWidgets('stops following the logger once closed', (tester) async {
    final logger = _logger();
    await _pumpViewer(tester, logger);
    await tester.pumpWidget(const SizedBox.shrink());

    // A record after the screen left reaches no disposed state.
    logger.info('watch', 'folder_changed');
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
