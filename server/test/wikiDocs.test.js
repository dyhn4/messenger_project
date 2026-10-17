// 위키 동시 편집 문서(wikiDocs.js)와 위키 규칙(wikiRules.js) — 늦게 온 연산 맞추기, 같은 연산 두 번 막기, 다시 붙은 앱 따라잡기,
// 저장·판 남기기, 나무·옮기기·권한. `node --test test/wikiDocs.test.js`(DB 없이 — 저장은 가짜로).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { apply, transform } from '../src/otText.js';
import { createWikiDocs } from '../src/wikiDocs.js';
import {
  canRemovePage,
  checkPageMove,
  editorColor,
  pageBreadcrumb,
  parseWikiBody,
  parseWikiTitle,
  searchExcerpt,
  wikiPermissions,
  wikiTree,
} from '../src/wikiRules.js';

function fakeDocs({ body = 'hello', revision = 0, historyMax } = {}) {
  const saved = [];
  const snapshots = [];
  const timers = [];
  let clock = 1_000_000;
  const docs = createWikiDocs({
    load: async (id) => (id === 'p1' ? { id, teamId: 't1', title: '안내', body, revision } : null),
    save: async (id, v) => saved.push({ id, ...v }),
    snapshot: async (id, v) => snapshots.push({ id, ...v }),
    now: () => clock,
    saveDelayMs: 2000,
    snapshotIntervalMs: 600_000,
    ...(historyMax ? { historyMax } : {}),
    setTimer: (fn) => {
      timers.push(fn);
      return timers.length;
    },
    clearTimer: () => {},
  });
  return { docs, saved, snapshots, timers, tick: (ms) => (clock += ms) };
}

test('연산 — 늦게 온 연산은 적용된 것에 맞추고, 같은 연산(opId)은 한 번만', async () => {
  const { docs } = fakeDocs();
  const doc = await docs.open('p1');
  assert.equal(await docs.open('nope'), null);
  assert.equal(await docs.open('p1'), doc, '같은 문서');
  // A·B 둘 다 판 0의 "hello"에서 고친다.
  const a = [5, ' world'];
  const b = ['Oh, ', 5];
  const ra = docs.receive(doc, { baseRevision: 0, op: a, opId: 'a1', userId: 'A', userName: '김가' });
  assert.deepEqual(ra, { ok: true, revision: 1, op: [5, ' world'] });
  const rb = docs.receive(doc, { baseRevision: 0, op: b, opId: 'b1', userId: 'B', userName: '이나' });
  assert.equal(rb.revision, 2);
  assert.equal(doc.body, 'Oh, hello world');
  // 앱 A가 받은 b' 적용 결과도 같다.
  assert.equal(apply(apply('hello', a), rb.op), doc.body);
  // 앱 B: 확인 전 내 b가 있는 채로 a를 받아 맞춘다.
  assert.equal(apply(apply('hello', b), transform(b, a)[1]), doc.body);
  // 다시 보낸 같은 연산.
  const again = docs.receive(doc, { baseRevision: 0, op: b, opId: 'b1', userId: 'B' });
  assert.equal(again.duplicate, true);
  assert.equal(again.revision, 2);
  assert.equal(doc.revision, 2);
  // 잘못된 것들.
  assert.equal(docs.receive(doc, { baseRevision: 9, op: [1] }).error, 'resync');
  assert.equal(docs.receive(doc, { baseRevision: 2, op: [3] }).error, 'resync', '길이가 다르다');
  assert.equal(docs.receive(doc, { baseRevision: 2, op: [0] }).error, 'invalid');
  assert.equal(docs.receive(doc, { baseRevision: 2, op: [15, 'x'.repeat(50_001)] }).error, 'too_big');
});

test('따라잡기 — since는 기억하는 만큼, 넘으면 null', async () => {
  const { docs } = fakeDocs({ historyMax: 3 });
  const doc = await docs.open('p1');
  for (let i = 0; i < 5; i += 1) docs.receive(doc, { baseRevision: i, op: [doc.body.length, String(i)], opId: `o${i}`, userId: 'A' });
  assert.equal(doc.revision, 5);
  assert.deepEqual(docs.since(doc, 5), []);
  assert.deepEqual(docs.since(doc, 3).map((h) => h.opId), ['o3', 'o4']);
  assert.equal(docs.since(doc, 1), null, '기억 밖');
  assert.equal(docs.receive(doc, { baseRevision: 1, op: [doc.body.length, 'x'] }).error, 'resync');
});

test('저장·판 — 마지막 연산 뒤 저장, 10분마다·마지막 사람이 나가면 판, 나가면 메모리에서 내림', async () => {
  const { docs, saved, snapshots, timers, tick } = fakeDocs();
  const doc = await docs.open('p1');
  docs.join(doc, 's1', { userId: 'A', name: '김가', color: '#000', canEdit: true });
  docs.join(doc, 's2', { userId: 'A', name: '김가', color: '#000', canEdit: true });
  docs.join(doc, 's3', { userId: 'B', name: '이나', color: '#111', canEdit: true });
  assert.deepEqual(docs.editors(doc).map((e) => e.userId), ['A', 'B'], '같은 사람은 한 번');
  docs.receive(doc, { baseRevision: 0, op: [5, '!'], opId: 'x', userId: 'A', userName: '김가' });
  assert.equal(timers.length, 1);
  await timers[0]();
  assert.deepEqual(saved.at(-1), { id: 'p1', body: 'hello!', revision: 1, updatedByName: '김가' });
  assert.equal(snapshots.length, 0, '아직 10분 전');
  tick(600_000);
  docs.receive(doc, { baseRevision: 1, op: [6, '?'], opId: 'y', userId: 'B', userName: '이나' });
  await timers[1]();
  assert.equal(snapshots.length, 1);
  assert.deepEqual(snapshots[0], { id: 'p1', revision: 2, title: '안내', body: 'hello!?', editorNames: '김가, 이나' });
  // 나가기 — 마지막 사람이 나가면 바뀐 게 있을 때만 판을 남기고 내린다.
  await docs.leave(doc, 's1');
  await docs.leave(doc, 's3');
  assert.ok(docs.peek('p1'), 's2가 아직 있다');
  docs.receive(doc, { baseRevision: 2, op: [7, '.'], opId: 'z', userId: 'A', userName: '김가' });
  assert.deepEqual(await docs.leave(doc, 's2'), []);
  assert.equal(docs.peek('p1'), null);
  assert.equal(snapshots.length, 2);
  assert.equal(snapshots[1].body, 'hello!?.');
  assert.equal(saved.at(-1).revision, 3);
});

test('되돌리기 — 본문을 통째로 바꾸는 연산', async () => {
  const { docs } = fakeDocs({ body: 'abc def' });
  const doc = await docs.open('p1');
  const { revision, op } = docs.replaceBody(doc, 'abc xyz', { userName: '김가' });
  assert.equal(revision, 1);
  assert.equal(apply('abc def', op), 'abc xyz');
  assert.equal(doc.body, 'abc xyz');
  // 그 사이 판 0에서 보낸 연산도 맞춰진다.
  const late = docs.receive(doc, { baseRevision: 0, op: ['> ', 7], opId: 'q', userId: 'B' });
  assert.equal(late.ok, true);
  assert.equal(doc.body, '> abc xyz');
});

test('규칙 — 제목·본문, 나무 차례·옮기기·빵부스러기, 권한, 미리보기', () => {
  assert.deepEqual(parseWikiTitle('  회의   규칙 '), { title: '회의 규칙' });
  assert.match(parseWikiTitle('').error, /제목/);
  assert.match(parseWikiTitle('x'.repeat(101)).error, /100자/);
  assert.deepEqual(parseWikiBody(null), { body: '' });
  assert.deepEqual(parseWikiBody('a\r\nb'), { body: 'a\nb' });
  const pages = new Map(
    [
      { id: 'a', parentId: null, title: '안내', position: 1 },
      { id: 'b', parentId: null, title: '가이드', position: 0 },
      { id: 'c', parentId: 'b', title: '설치', position: 0 },
      { id: 'd', parentId: 'c', title: '윈도우', position: 0 },
      { id: 'x', parentId: null, title: '옛것', position: 2, deletedAt: new Date() },
      { id: 'y', parentId: 'x', title: '옛것 아래', position: 0 },
    ].map((p) => [p.id, { deletedAt: null, ...p }]),
  );
  assert.deepEqual(wikiTree(pages).map((p) => [p.title, p.depth]), [
    ['가이드', 0],
    ['설치', 1],
    ['윈도우', 2],
    ['안내', 0],
  ]);
  assert.deepEqual(pageBreadcrumb(pages, 'd').map((p) => p.title), ['가이드', '설치', '윈도우']);
  assert.match(checkPageMove(pages, 'b', 'd').error, /아래 페이지/);
  assert.match(checkPageMove(pages, 'b', 'b').error, /자기 아래/);
  assert.deepEqual(checkPageMove(pages, 'd', 'a'), { ok: true });
  const member = wikiPermissions({ role: 'member' });
  assert.deepEqual(member, { canEdit: true, isManager: false });
  assert.equal(wikiPermissions({ role: 'guest' }).canEdit, false);
  assert.equal(canRemovePage({ createdBy: 'me' }, 'me', member), true);
  assert.equal(canRemovePage({ createdBy: 'you' }, 'me', member), false);
  assert.equal(canRemovePage({ createdBy: 'you' }, 'me', wikiPermissions({ role: 'member', isOwner: true })), true);
  assert.equal(searchExcerpt('짧은 글', '글'), '짧은 글');
  assert.equal(searchExcerpt('a'.repeat(100) + '찾는말' + 'b'.repeat(100), '찾는말'), `…${'a'.repeat(40)}찾는말${'b'.repeat(40)}…`);
  assert.equal(editorColor('u1'), editorColor('u1'));
});
