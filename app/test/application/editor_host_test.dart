/// EditorHost against a scripted page (test/support/fake_editor_surface.dart).
/// testWidgets supplies fake time, so timeouts run exactly and every test
/// proves no timer outlives the host.
library;

import 'dart:async';

import 'package:codeforge/application/editor/editor_host.dart';
import 'package:codeforge/core/editor/rate_limiter.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/services/editor/editor_page.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_editor_surface.dart';

const Map<String, Object?> _configuration = {'fontSize': 15, 'tabSize': 4};

void main() {
  late FakeEditorSurface page;
  late EditorHost host;
  late List<EditorHostEvent> events;

  /// Microtasks and stream deliveries only; no time passes.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
  }

  Future<void> createHost(
    WidgetTester tester, {
    bool start = true,
    EditorPageLoader? loadPage,
    MessageRateLimiter? rateLimiter,
  }) async {
    page = FakeEditorSurface();
    host = EditorHost(
      surface: page,
      loadPage: loadPage ?? () async => const Ok(fakeEditorPage),
      rateLimiter: rateLimiter,
    );
    events = [];
    final subscription = host.events.listen(events.add);
    addTearDown(subscription.cancel);
    if (start) {
      await host.start();
      await settle(tester);
    }
  }

  Object? causeOf(Result<Object?>? result) => result?.failureOrNull?.cause;

  testWidgets('documents wait in their shadows until the page starts', (
    tester,
  ) async {
    await createHost(tester, start: false);
    expect((await host.configure(_configuration)).isOk, isTrue);
    await host.openDocument(
      docId: 'd1',
      text: 'one\ntwo',
      language: 'javascript',
    );
    await host.openDocument(
      docId: 'd2',
      text: 'print(1)',
      language: 'python',
      activate: false,
    );
    expect(page.received, isEmpty);
    expect(host.status.phase, EditorHostPhase.idle);

    await host.start();
    await settle(tester);

    expect(host.status.phase, EditorHostPhase.ready);
    expect(host.status.engineVersion, '0.0.0');
    expect(page.loads, 1);
    expect(page.loadedHtml, fakeEditorPage.html);
    expect(page.receivedTypes, [
      'editor.configure',
      'doc.open',
      'doc.open',
      'doc.activate',
    ]);
    expect(page.configuration, _configuration);
    expect(page.documents['d1']!.text, 'one\ntwo');
    expect(page.documents['d2']!.language, 'python');
    expect(page.activeDocId, 'd1');
    expect(host.pageStarts, 1);
    expect(host.syncs, 1);
    expect(page.rejected, isEmpty, reason: 'every host message validates');
    await host.dispose();
  });

  testWidgets('edits from the page keep the shadow in step', (tester) async {
    await createHost(tester);
    await host.openDocument(docId: 'd1', text: 'a', language: 'plaintext');
    await settle(tester);

    page
      ..typeText('b')
      ..typeText('\nc');
    await settle(tester);

    expect(host.textOf('d1'), 'ab\nc');
    expect(host.versionOf('d1'), 2);
    expect(
      [for (final e in events.whereType<DocumentEdited>()) e.version],
      [1, 2],
    );
    final snapshot = (await host.snapshot('d1')).orThrow;
    expect(snapshot.text, 'ab\nc');
    expect(snapshot.version, 2);
    expect(host.resyncs, 0);
    await host.dispose();
  });

  testWidgets('a change that does not fit is refused, then resynced', (
    tester,
  ) async {
    await createHost(tester);
    await host.openDocument(docId: 'd1', text: 'abc', language: 'plaintext');
    await settle(tester);

    // The page's document diverged, and a change arrives that does not fit
    // the shadow: the editor's text wins, never a half-applied change.
    page.documents['d1']!
      ..text = 'diverged'
      ..version = 7;
    page.emit('doc.changed', {
      'docId': 'd1',
      'baseVersion': 5,
      'version': 6,
      'lengthBefore': 8,
      'lengthAfter': 9,
      'changes': [
        8,
        [0, '!'],
      ],
    });
    await settle(tester);

    expect(host.textOf('d1'), 'diverged');
    expect(host.versionOf('d1'), 7);
    expect(host.resyncs, 1);
    expect(events.whereType<DocumentEdited>().last.version, 7);
    await host.dispose();
  });

  testWidgets('malformed, unknown and misdirected messages are dropped', (
    tester,
  ) async {
    await createHost(tester);
    await host.openDocument(docId: 'd1', text: 'abc', language: 'plaintext');
    await settle(tester);

    page
      ..emitRaw('not json')
      ..emitRaw(
        '{"v":2,"id":"e90","type":"editor.focus","payload":{"focused":true}}',
      )
      ..emit('doc.open', {
        'docId': 'd1',
        'text': 'hijacked',
        'language': 'plaintext',
        'version': 0,
      })
      ..emit('doc.changed', {
        'docId': 'd1',
        'baseVersion': 0,
        'version': 1,
        'lengthBefore': -1,
        'lengthAfter': 0,
        'changes': [3],
      });
    await settle(tester);

    expect(host.textOf('d1'), 'abc');
    expect(host.versionOf('d1'), 0);
    expect(events, isEmpty);
    expect(host.status.phase, EditorHostPhase.ready);
    await host.dispose();
  });

  testWidgets('page events reach the host as typed events', (tester) async {
    await createHost(tester);
    await host.openDocument(docId: 'd1', text: 'abc', language: 'plaintext');
    await settle(tester);

    page
      ..emit('editor.history', {
        'docId': 'd1',
        'canUndo': true,
        'canRedo': false,
      })
      ..emit('editor.focus', {'focused': true})
      ..emit('ime.composition', {'docId': 'd1', 'composing': true})
      ..emit('app.shortcut', {'shortcut': 'save'})
      ..emit('editor.log', {'level': 'warn', 'message': 'from the page'})
      ..emit('doc.viewState', {
        'docId': 'd1',
        'selection': {'anchor': 1, 'head': 2},
        'scrollTop': 0,
      });
    await settle(tester);

    expect(events, hasLength(5));
    final history = events[0] as HistoryChanged;
    expect(
      [history.docId, history.canUndo, history.canRedo],
      ['d1', true, false],
    );
    expect((events[1] as FocusChanged).focused, isTrue);
    expect((events[2] as CompositionChanged).composing, isTrue);
    expect((events[3] as ShortcutPressed).shortcut, 'save');
    expect((events[4] as ViewStateChanged).docId, 'd1');
    expect(host.viewStateOf('d1')?.selection?.head, 2);
    await host.dispose();
  });

  testWidgets('requests time out when the page does not answer', (
    tester,
  ) async {
    await createHost(tester);
    await host.openDocument(docId: 'd1', text: 'abc', language: 'plaintext');
    await settle(tester);

    page.respond = false;
    Result<void>? outcome;
    unawaited(host.activate('d1').then((result) => outcome = result));
    await tester.pump(const Duration(seconds: 4));
    expect(outcome, isNull);
    await tester.pump(const Duration(seconds: 2));
    expect(causeOf(outcome), 'timeout');
    await host.dispose();
  });

  testWidgets('page errors carry the protocol error code', (tester) async {
    await createHost(tester);
    await host.openDocument(docId: 'd1', text: 'abc', language: 'plaintext');
    await settle(tester);

    page.documents.remove('d1'); // the page lost it
    expect(causeOf(await host.activate('d1')), 'unknown_doc');
    expect(causeOf(await host.closeDocument('nope')), isNull);
    expect((await host.closeDocument('nope')).isOk, isFalse);
    await host.dispose();
  });

  testWidgets('a page restart reopens every document from its shadow', (
    tester,
  ) async {
    await createHost(tester);
    await host.configure(_configuration);
    await host.openDocument(docId: 'd1', text: 'one', language: 'plaintext');
    await host.openDocument(docId: 'd2', text: 'two', language: 'plaintext');
    await settle(tester);
    page.typeText(' more', docId: 'd1');
    await settle(tester);
    await host.activate('d1');

    page.restartPage();
    await settle(tester);

    expect(host.pageStarts, 2);
    expect(host.syncs, 2);
    expect(page.configuration, _configuration);
    expect(page.documents['d1']!.text, 'one more');
    expect(page.documents['d1']!.version, 1);
    expect(page.documents['d2']!.text, 'two');
    expect(page.activeDocId, 'd1');
    // Editing carries on from the restored versions.
    page.typeText('!', docId: 'd2');
    await settle(tester);
    expect(host.textOf('d2'), 'two!');
    expect(host.resyncs, 0);
    expect(page.rejected, isEmpty);
    await host.dispose();
  });

  testWidgets('reloadPage recovers the same way', (tester) async {
    await createHost(tester);
    await host.openDocument(docId: 'd1', text: 'kept', language: 'plaintext');
    await settle(tester);

    await host.reloadPage();
    await settle(tester);

    expect(page.reloads, 1);
    expect(page.documents.keys.toList(), ['d1']);
    expect(page.documents['d1']!.text, 'kept');
    expect(host.syncs, 2);
    await host.dispose();
  });

  testWidgets('a page that never starts times out; trying again recovers', (
    tester,
  ) async {
    await createHost(tester, start: false);
    page.announceReady = false;
    await host.start();
    await tester.pump(const Duration(seconds: 19));
    expect(host.status.phase, EditorHostPhase.loading);
    await tester.pump(const Duration(seconds: 2));
    expect(host.status.phase, EditorHostPhase.failed);
    expect(host.status.message, contains('did not start'));

    page.announceReady = true;
    await host.reloadPage();
    await settle(tester);
    expect(host.status.phase, EditorHostPhase.ready);
    expect(page.loads, 2);
    await host.dispose();
  });

  testWidgets('a rejected or incompatible page is never loaded', (
    tester,
  ) async {
    await createHost(
      tester,
      start: false,
      loadPage: () async => const Err(BridgeFailure('tampered')),
    );
    await host.start();
    await settle(tester);
    expect(host.status.phase, EditorHostPhase.failed);
    expect(host.status.message, 'tampered');
    expect(page.loads, 0);
    await host.dispose();

    await createHost(
      tester,
      start: false,
      loadPage: () async => const Ok(
        EditorPage(
          html: '<p></p>',
          sha256: 'x',
          engineVersion: '9',
          protocol: 2,
        ),
      ),
    );
    await host.start();
    await settle(tester);
    expect(host.status.phase, EditorHostPhase.failed);
    expect(host.status.message, contains('protocol 2'));
    expect(page.loads, 0);
    await host.dispose();
  });

  testWidgets('a message flood beyond the rate limit is dropped', (
    tester,
  ) async {
    await createHost(
      tester,
      rateLimiter: MessageRateLimiter(
        capacity: 5,
        refillPerSecond: 0,
        nowMicros: () => 0,
      ),
    );
    // editor.ready took one token; four remain.
    for (var i = 0; i < 10; i++) {
      page.emit('editor.focus', {'focused': i.isEven});
    }
    await settle(tester);
    expect(events.whereType<FocusChanged>(), hasLength(4));
    expect(host.droppedMessages, 6);
    await host.dispose();
  });

  testWidgets('the host refuses what the protocol cannot carry', (
    tester,
  ) async {
    await createHost(tester);
    final crlf = await host.openDocument(
      docId: 'd1',
      text: 'a\r\nb',
      language: 'plaintext',
    );
    expect(crlf.isOk, isFalse);
    await host.openDocument(docId: 'd1', text: 'a\nb', language: 'plaintext');
    final duplicate = await host.openDocument(
      docId: 'd1',
      text: 'again',
      language: 'plaintext',
    );
    expect(duplicate.isOk, isFalse);
    await settle(tester);
    expect(page.receivedTypes, ['doc.open']);
    expect(page.documents['d1']!.text, 'a\nb');
    await host.dispose();
  });

  testWidgets('dispose fails what is in flight and stops every timer', (
    tester,
  ) async {
    await createHost(tester);
    await host.openDocument(docId: 'd1', text: 'abc', language: 'plaintext');
    await settle(tester);

    page.respond = false;
    Result<void>? outcome;
    unawaited(host.activate('d1').then((result) => outcome = result));
    await tester.pump();
    await host.dispose();
    await tester.pump();

    expect(outcome?.failureOrNull?.message, 'The editor is closed.');
    expect(page.disposed, isTrue);
    // A disposed host ignores everything.
    expect((await host.activate('d1')).isOk, isFalse);
  });

  testWidgets('document commands wait for the page sync in flight', (
    tester,
  ) async {
    // The host reports ready the moment the page announces itself, and
    // reopens its documents after that. A command sent in between reached a
    // page with no active document (phase gate 42379885027, edit_a).
    await createHost(tester, start: false);
    await host.openDocument(docId: 'd1', text: 'abc', language: 'javascript');
    page.hold = true;
    await host.start();
    await settle(tester);
    expect(host.status.phase, EditorHostPhase.ready);
    expect(host.syncs, 0);
    expect(page.receivedTypes, ['doc.open']);

    Result<void>? inserted;
    Result<void>? flushed;
    Result<EditorSnapshot>? snapshot;
    unawaited(host.insert('x').then((result) => inserted = result));
    unawaited(host.flush('d1').then((result) => flushed = result));
    unawaited(host.snapshot('d1').then((result) => snapshot = result));
    await settle(tester);
    expect(page.receivedTypes, ['doc.open'], reason: 'nothing overtakes it');
    expect(inserted, isNull);

    page.release();
    await settle(tester);
    expect(host.syncs, 1);
    expect(page.receivedTypes, [
      'doc.open',
      'doc.activate',
      'cmd.insert',
      'doc.flush',
      'doc.snapshot',
    ]);
    expect(inserted?.isOk, isTrue);
    expect(flushed?.isOk, isTrue);
    expect(snapshot?.valueOrNull?.text, 'xabc');
    expect(page.documents['d1']!.text, 'xabc');
    expect(host.textOf('d1'), 'xabc');
    expect(page.rejected, isEmpty);
    await host.dispose();
  });
}
