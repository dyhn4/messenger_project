// 보드 보강 규칙 — 말머리 목록 검사(이름·개수·색·id 유지), 게시글 말머리 고르기, 읽음 확인 나누기. `node --test test/*.test.js`(DB 없이).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  BOARD_CATEGORIES_MAX,
  BOARD_CATEGORY_COLORS,
  boardCategoriesOf,
  parseBoardCategories,
  parsePostCategory,
  splitReaders,
} from '../src/boardRules.js';

test('말머리 목록 — 이름 다듬기·같은 이름 막기·개수·색, 있던 id는 그대로', () => {
  const r = parseBoardCategories([
    { id: 'kabc123', name: ' 공지 ', color: '#E53935' },
    { name: '질문', color: '#nope' },
  ]);
  assert.deepEqual(r.categories[0], { id: 'kabc123', name: '공지', color: '#E53935' });
  assert.equal(r.categories[1].name, '질문');
  assert.match(r.categories[1].id, /^k[a-z0-9]{6,16}$/);
  assert.equal(r.categories[1].color, BOARD_CATEGORY_COLORS[0]);
  assert.match(parseBoardCategories([{ name: '' }]).error, /이름/);
  assert.match(parseBoardCategories([{ name: '가' }, { name: '가' }]).error, /같은 이름/);
  assert.match(parseBoardCategories([{ name: 'x'.repeat(21) }]).error, /20자/);
  assert.match(parseBoardCategories(Array.from({ length: BOARD_CATEGORIES_MAX + 1 }, (_, i) => ({ name: `m${i}` }))).error, /20개/);
  assert.match(parseBoardCategories('x').error, /목록/);
  assert.deepEqual(parseBoardCategories([]).categories, []);
  // 같은 id가 두 번 오면 뒤의 것은 새 id.
  const dup = parseBoardCategories([
    { id: 'kdup0001', name: 'a' },
    { id: 'kdup0001', name: 'b' },
  ]).categories;
  assert.notEqual(dup[0].id, dup[1].id);
});

test('게시글 말머리 — 보드의 목록 안에서만, 안 보내면 그대로·null이면 빼기', () => {
  const room = { type: 'topic', viewMode: 'board', boardCategories: [{ id: 'k111111', name: '공지', color: '#5B8DEF' }] };
  assert.deepEqual(parsePostCategory('k111111', room), { categoryId: 'k111111' });
  assert.deepEqual(parsePostCategory(undefined, room), { keep: true });
  assert.deepEqual(parsePostCategory(null, room), { categoryId: null });
  assert.match(parsePostCategory('k999999', room).error, /말머리/);
  assert.deepEqual(boardCategoriesOf({ type: 'topic', viewMode: 'chat', boardCategories: [{ id: 'x' }] }), []);
  assert.match(parsePostCategory('k111111', { ...room, viewMode: 'chat' }).error, /말머리/);
});

test('읽음 확인 — 지금 멤버만, 쓴 사람은 늘 읽음(쓴 시각), 읽은 순·이름순', () => {
  const members = [
    { id: 'a', name: '김가' },
    { id: 'b', name: '이나' },
    { id: 'c', name: '박다' },
    { id: 'd', name: '최라' },
  ];
  const r = splitReaders({
    members,
    reads: [
      { userId: 'c', readAt: new Date(3000) },
      { userId: 'b', readAt: new Date(2000) },
      { userId: 'gone', readAt: new Date(1500) },
    ],
    authorId: 'a',
    postedAt: new Date(1000),
  });
  assert.deepEqual(r.read.map((x) => [x.userId, x.readAt]), [
    ['a', 1000],
    ['b', 2000],
    ['c', 3000],
  ]);
  assert.deepEqual(r.unread, [{ userId: 'd', name: '최라' }]);
});
