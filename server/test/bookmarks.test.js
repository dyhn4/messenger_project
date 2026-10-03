// 북마크 규칙 단위 테스트 — `node --test test/*.test.js` (DB·서버 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  bookmarkPermissions,
  canCreateBookmark,
  normalizeHttpUrl,
  parseBookmarkBody,
  reorderIdsMatch,
} from '../src/bookmarkRules.js';

test('normalizeHttpUrl: http/https만, 공백은 자르고 2000자를 넘으면 거절', () => {
  assert.equal(normalizeHttpUrl('  https://example.com/a?b=1 '), 'https://example.com/a?b=1');
  assert.equal(normalizeHttpUrl('http://example.com'), 'http://example.com');
  assert.equal(normalizeHttpUrl('javascript:alert(1)'), null);
  assert.equal(normalizeHttpUrl('ftp://example.com'), null);
  assert.equal(normalizeHttpUrl('example.com'), null);
  assert.equal(normalizeHttpUrl(''), null);
  assert.equal(normalizeHttpUrl(null), null);
  assert.equal(normalizeHttpUrl(`https://example.com/${'a'.repeat(2000)}`), null);
});

test('parseBookmarkBody: 만들기는 제목(1~50자)과 http(s) 주소가 필수', () => {
  const ok = parseBookmarkBody({ title: ' 사내 위키 ', url: 'https://wiki.example.com' });
  assert.deepEqual(ok, { ok: true, fields: { title: '사내 위키', url: 'https://wiki.example.com', imageUrl: null } });
  assert.equal(parseBookmarkBody({ title: '', url: 'https://a.com' }).ok, false);
  assert.equal(parseBookmarkBody({ title: 'a'.repeat(51), url: 'https://a.com' }).ok, false);
  assert.equal(parseBookmarkBody({ title: 'a'.repeat(50), url: 'https://a.com' }).ok, true);
  assert.equal(parseBookmarkBody({ title: 'x', url: 'file:///etc/passwd' }).ok, false);
  assert.equal(parseBookmarkBody({ title: 'x' }).ok, false);
});

test('parseBookmarkBody: 이미지 — 외부 http(s) 주소나 업로드 경로만, 빈 값은 지우기', () => {
  const toUpload = (v) => (v === '/files/signed-token' ? '/uploads/abc.png' : null);
  const base = { title: 't', url: 'https://a.com' };
  assert.equal(parseBookmarkBody({ ...base, imageUrl: 'https://a.com/i.png' }, { toUpload }).fields.imageUrl, 'https://a.com/i.png');
  assert.equal(parseBookmarkBody({ ...base, imageUrl: '/files/signed-token' }, { toUpload }).fields.imageUrl, '/uploads/abc.png');
  assert.equal(parseBookmarkBody({ ...base, imageUrl: '' }, { toUpload }).fields.imageUrl, null);
  assert.equal(parseBookmarkBody({ ...base, imageUrl: 'javascript:1' }, { toUpload }).ok, false);
  assert.equal(parseBookmarkBody({ ...base, imageUrl: 5 }, { toUpload }).ok, false);
});

test('parseBookmarkBody: 고치기(partial)는 보낸 필드만 담는다', () => {
  assert.deepEqual(parseBookmarkBody({ title: '새 제목' }, { partial: true }), { ok: true, fields: { title: '새 제목' } });
  assert.deepEqual(parseBookmarkBody({}, { partial: true }), { ok: true, fields: {} });
  assert.equal(parseBookmarkBody({ url: 'nope' }, { partial: true }).ok, false);
  assert.deepEqual(parseBookmarkBody({ imageUrl: null }, { partial: true }), { ok: true, fields: { imageUrl: null } });
});

test('bookmarkPermissions: 팀 북마크는 만든 사람·관리자가 고치고 순서는 관리자만, 개인 북마크는 본인만', () => {
  const team = { kind: 'team', creatorId: 'u1', ownerId: null };
  assert.deepEqual(bookmarkPermissions({ bookmark: team, requesterId: 'u1', canManage: false }), { canEdit: true, canReorder: false });
  assert.deepEqual(bookmarkPermissions({ bookmark: team, requesterId: 'u2', canManage: false }), { canEdit: false, canReorder: false });
  assert.deepEqual(bookmarkPermissions({ bookmark: team, requesterId: 'u2', canManage: true }), { canEdit: true, canReorder: true });
  const mine = { kind: 'personal', creatorId: 'u1', ownerId: 'u1' };
  assert.deepEqual(bookmarkPermissions({ bookmark: mine, requesterId: 'u1', canManage: false }), { canEdit: true, canReorder: true });
  // 관리자라도 남의 개인 북마크는 못 건드린다.
  assert.deepEqual(bookmarkPermissions({ bookmark: mine, requesterId: 'u2', canManage: true }), { canEdit: false, canReorder: false });
});

test('canCreateBookmark: 준회원은 팀 북마크를 못 만들고 개인 북마크는 만든다', () => {
  assert.equal(canCreateBookmark({ kind: 'team', role: 'member', isMember: true }), true);
  assert.equal(canCreateBookmark({ kind: 'team', role: 'admin', isMember: true }), true);
  assert.equal(canCreateBookmark({ kind: 'team', role: 'guest', isMember: true }), false);
  assert.equal(canCreateBookmark({ kind: 'personal', role: 'guest', isMember: true }), true);
  assert.equal(canCreateBookmark({ kind: 'personal', role: 'member', isMember: false }), false);
});

test('reorderIdsMatch: 현재 전체 id 집합과 같아야 한다', () => {
  assert.equal(reorderIdsMatch(['b', 'a', 'c'], ['a', 'b', 'c']), true);
  assert.equal(reorderIdsMatch(['a', 'b'], ['a', 'b', 'c']), false);
  assert.equal(reorderIdsMatch(['a', 'a', 'b'], ['a', 'b', 'c']), false);
  assert.equal(reorderIdsMatch(['a', 'b', 'x'], ['a', 'b', 'c']), false);
  assert.equal(reorderIdsMatch('abc', ['a']), false);
  assert.equal(reorderIdsMatch([], []), true);
});
