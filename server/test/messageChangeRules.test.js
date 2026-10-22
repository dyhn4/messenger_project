// "이후 바뀐 것" 동기화 규칙 — 커서 모양, 페이지 크기, 바뀐 메시지와 지운 흔적 합치기. `node --test test/*.test.js`(DB 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  CHANGES_HORIZON_MS,
  CHANGES_PAGE_DEFAULT,
  CHANGES_PAGE_MAX,
  changesHorizon,
  changesPageSize,
  formatChangesCursor,
  mergeChangePage,
  parseChangesCursor,
} from '../src/messageChangeRules.js';

const A = '00000000-0000-4000-8000-00000000000a';
const B = '00000000-0000-4000-8000-00000000000b';
const C = '00000000-0000-4000-8000-00000000000c';

test('커서 — 없으면 처음, 시각만·시각:id, 그 밖은 오류', () => {
  assert.equal(parseChangesCursor(undefined), null);
  assert.equal(parseChangesCursor(''), null);
  assert.deepEqual(parseChangesCursor('1700000000000'), { since: new Date(1700000000000), afterId: null });
  assert.deepEqual(parseChangesCursor(`1700000000000:${A}`), { since: new Date(1700000000000), afterId: A });
  for (const bad of ['abc', '-5', '1.5', `1:${A}:x`, '1:not-a-uuid', "1:'); drop--", ['1']]) {
    assert.ok(parseChangesCursor(bad).error, String(bad));
  }
  assert.equal(formatChangesCursor(new Date(5)), '5');
  assert.equal(formatChangesCursor(5, A), `5:${A}`);
  // 만든 커서를 다시 읽으면 같은 자리.
  assert.deepEqual(parseChangesCursor(formatChangesCursor(42, B)), { since: new Date(42), afterId: B });
});

test('끝은 지금보다 조금 앞 — 늦게 커밋된 변화를 앞지르지 않게', () => {
  assert.equal(changesHorizon(1_000_000.7).getTime(), 1_000_000 - CHANGES_HORIZON_MS);
});

test('페이지 크기 — 기본·상한', () => {
  assert.equal(changesPageSize(undefined), CHANGES_PAGE_DEFAULT);
  assert.equal(changesPageSize('0'), CHANGES_PAGE_DEFAULT);
  assert.equal(changesPageSize('50'), 50);
  assert.equal(changesPageSize('100000'), CHANGES_PAGE_MAX);
});

test('합치기 — (시각, id) 순으로 limit개, 남으면 마지막 자리를 커서로', () => {
  const changed = [
    { id: A, changedAt: new Date(10) },
    { id: C, changedAt: new Date(20) },
    { id: B, changedAt: new Date(30) },
  ];
  const removed = [{ id: B, roomId: 'r1', removedAt: new Date(20) }];
  const page = mergeChangePage(changed, removed, 3);
  assert.deepEqual(page.changed.map((m) => m.id), [A, C]);
  assert.deepEqual(page.removed.map((r) => r.id), [B]);
  assert.equal(page.more, true);
  // 같은 시각(20)의 B(지움)와 C(바뀜) 중 id가 큰 C가 마지막.
  assert.equal(page.cursor, `20:${C}`);

  const all = mergeChangePage(changed, removed, 10);
  assert.equal(all.more, false);
  assert.equal(all.cursor, null);
  assert.equal(all.changed.length + all.removed.length, 4);
});
