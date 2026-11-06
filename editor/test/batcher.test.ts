import { ChangeSet, EditorState } from '@codemirror/state';
import { describe, expect, it } from 'vitest';

import { ChangeBatcher } from '../src/editor/batcher';
import { applyChanges } from '../src/protocol/changes';
import type { ChangeSetJson } from '../src/protocol/types';
import { FakeScheduler } from './helpers';

function setup() {
  const scheduler = new FakeScheduler();
  const flushed: Array<{ docId: string; changes: ChangeSet }> = [];
  const batcher = new ChangeBatcher((docId, changes) => flushed.push({ docId, changes }), 150, scheduler);
  return { scheduler, flushed, batcher };
}

describe('ChangeBatcher', () => {
  it('groups edits inside one window into a single composed change set', () => {
    const { scheduler, flushed, batcher } = setup();
    let state = EditorState.create({ doc: 'ab' });
    for (const ch of ['x', 'y', 'z']) {
      const tr = state.update({ changes: { from: state.doc.length, insert: ch } });
      batcher.add('d1', tr.changes);
      state = tr.state;
    }
    expect(flushed).toHaveLength(0);
    expect(scheduler.tasks.size).toBe(1);
    scheduler.run();
    expect(flushed).toHaveLength(1);
    expect(applyChanges('ab', flushed[0]!.changes.toJSON() as ChangeSetJson)).toBe('abxyz');
  });

  it('flushes early on demand and cancels the idle timer', () => {
    const { scheduler, flushed, batcher } = setup();
    batcher.add('d1', ChangeSet.of({ from: 0, insert: 'q' }, 0));
    batcher.flush('d1');
    expect(flushed).toHaveLength(1);
    expect(scheduler.tasks.size).toBe(0);
    batcher.flush('d1');
    expect(flushed).toHaveLength(1);
  });

  it('skips batches whose edits cancel out', () => {
    const { flushed, batcher } = setup();
    const state = EditorState.create({ doc: 'ab' });
    const typed = state.update({ changes: { from: 2, insert: 'c' } });
    const deleted = typed.state.update({ changes: { from: 2, to: 3 } });
    batcher.add('d1', typed.changes);
    batcher.add('d1', deleted.changes);
    batcher.flush('d1');
    expect(flushed).toHaveLength(0);
  });

  it('keeps documents separate and discards on request', () => {
    const { scheduler, flushed, batcher } = setup();
    batcher.add('a', ChangeSet.of({ from: 0, insert: '1' }, 0));
    batcher.add('b', ChangeSet.of({ from: 0, insert: '2' }, 0));
    batcher.discard('b');
    expect(batcher.hasPending('b')).toBe(false);
    scheduler.run();
    expect(flushed.map((f) => f.docId)).toEqual(['a']);
  });
});
