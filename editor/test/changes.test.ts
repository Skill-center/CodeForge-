import { ChangeSet, EditorSelection, EditorState, Text } from '@codemirror/state';
import { describe, expect, it } from 'vitest';

import { applyChanges, ChangeApplyError, changeLengths } from '../src/protocol/changes';
import type { ChangeSetJson } from '../src/protocol/types';
import { prng, readFixtures } from './helpers';

interface ChangeFixture {
  description: string;
  before: string;
  changes: ChangeSetJson;
  after: string;
}

const fixtures = readFixtures<ChangeFixture>('changes');

describe('change fixtures (shared with the Dart shadow buffer)', () => {
  for (const { name, data } of fixtures) {
    it(`${name}: ${data.description}`, () => {
      // The fixture must be real CodeMirror JSON, not just self-consistent.
      const cm = ChangeSet.fromJSON(data.changes);
      expect(cm.apply(Text.of(data.before.split('\n'))).toString()).toBe(data.after);
      expect(applyChanges(data.before, data.changes)).toBe(data.after);
      expect(changeLengths(data.changes)).toEqual({ before: data.before.length, after: data.after.length });
      expect({ before: cm.length, after: cm.newLength }).toEqual(changeLengths(data.changes));
    });
  }

  it('refuses a change set that does not fit the document', () => {
    expect(() => applyChanges('abc', [5])).toThrow(ChangeApplyError);
    expect(() => applyChanges('abc', [2])).toThrow(ChangeApplyError);
    expect(() => applyChanges('abc', [[4]])).toThrow(ChangeApplyError);
  });
});

const ALPHABET = ['a', 'b', ' ', '\n', '{', '}', '😀', '你', '\t', 'é'];

function randomText(rand: () => number, max: number): string {
  let s = '';
  const n = Math.floor(rand() * max);
  for (let i = 0; i < n; i++) s += ALPHABET[Math.floor(rand() * ALPHABET.length)];
  return s;
}

describe('randomized: batched CodeMirror edits replay exactly', () => {
  it('reproduces the live document from the composed change sets (300 sessions)', () => {
    const rand = prng(20261106);
    for (let session = 0; session < 300; session++) {
      let state = EditorState.create({
        doc: randomText(rand, 40),
        extensions: EditorState.allowMultipleSelections.of(true),
      });
      let shadow = state.doc.toString();
      let pending: ChangeSet | null = null;
      const steps = 1 + Math.floor(rand() * 25);
      for (let step = 0; step < steps; step++) {
        const len = state.doc.length;
        const a = Math.floor(rand() * (len + 1));
        const b = Math.min(len, a + Math.floor(rand() * 6));
        let tr;
        if (rand() < 0.15 && len > 0) {
          // Multi-cursor: place cursors at both ends, then insert at each.
          state = state.update({
            selection: EditorSelection.create([EditorSelection.cursor(0), EditorSelection.cursor(len)]),
          }).state;
          const insert = randomText(rand, 3) || 'x';
          tr = state.update(
            state.changeByRange((range) => ({
              changes: { from: range.from, insert },
              range: EditorSelection.cursor(range.from + insert.length),
            })),
          );
          expect((tr.changes.toJSON() as ChangeSetJson).filter((part) => Array.isArray(part)).length).toBe(2);
        } else {
          tr = state.update({ changes: { from: a, to: b, insert: randomText(rand, 8) } });
        }
        state = tr.state;
        pending = pending ? pending.compose(tr.changes) : tr.changes;
        // Flush at random points, as the 150 ms batcher would.
        if (rand() < 0.3 || step === steps - 1) {
          const json = pending.toJSON() as ChangeSetJson;
          expect(changeLengths(json).before).toBe(shadow.length);
          shadow = applyChanges(shadow, json);
          expect(shadow).toBe(state.doc.toString());
          pending = null;
        }
      }
    }
  });
});
