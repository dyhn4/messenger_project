// 내가 쓴 글(GET /api/my-posts) 순수 규칙 단위 테스트 — `node --test test/*.test.js` (DB·서버 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  MY_POSTS_DEFAULT_LIMIT,
  MY_POSTS_MAX_LIMIT,
  MY_POSTS_QUERY_MAX,
  isMyPostComment,
  isMyPostMessage,
  mergeMyPosts,
  parentPreview,
  parseMyPostsQuery,
  previewText,
} from '../src/myPostsRules.js';

const TEAM = '11111111-1111-4111-8111-111111111111';

test('parseMyPostsQuery: teamId는 UUID여야 하고 나머지는 기본값이 있다', () => {
  const ok = parseMyPostsQuery({ teamId: TEAM });
  assert.equal(ok.order, 'desc');
  assert.equal(ok.limit, MY_POSTS_DEFAULT_LIMIT);
  assert.equal(ok.kind, 'all');
  assert.equal(ok.roomId, null);
  assert.equal(ok.since, null);
  assert.equal(ok.until, null);
  assert.equal(ok.cursor, null);
  assert.ok(parseMyPostsQuery({}).error);
  assert.ok(parseMyPostsQuery({ teamId: 'x' }).error);
});

test('parseMyPostsQuery: 기간·방·정렬·limit·커서', () => {
  const q = parseMyPostsQuery({
    teamId: TEAM,
    roomId: 'room-1',
    since: '1700000000000',
    until: '1800000000000',
    order: 'asc',
    limit: '9999',
    before: '1750000000000:33333333-3333-4333-8333-333333333333',
  });
  assert.equal(q.roomId, 'room-1');
  assert.equal(q.since.getTime(), 1700000000000);
  assert.equal(q.until.getTime(), 1800000000000);
  assert.equal(q.order, 'asc');
  assert.equal(q.limit, MY_POSTS_MAX_LIMIT);
  assert.equal(q.cursor.ms, 1750000000000);
  assert.equal(parseMyPostsQuery({ teamId: TEAM, kind: 'comment' }).kind, 'comment');
  assert.equal(parseMyPostsQuery({ teamId: TEAM, kind: 'message' }).kind, 'message');
  assert.ok(parseMyPostsQuery({ teamId: TEAM, kind: 'file' }).error);
  assert.ok(parseMyPostsQuery({ teamId: TEAM, order: 'up' }).error);
  assert.ok(parseMyPostsQuery({ teamId: TEAM, since: 'x' }).error);
  assert.ok(parseMyPostsQuery({ teamId: TEAM, limit: '0' }).error);
  assert.ok(parseMyPostsQuery({ teamId: TEAM, before: 'zzz' }).error);
});

test('parseMyPostsQuery: 검색어(q)와 팀 범위(scope)', () => {
  const base = parseMyPostsQuery({ teamId: TEAM });
  assert.equal(base.allTeams, false);
  assert.equal(base.teamId, TEAM);
  assert.equal(base.text, '');

  // 검색어는 앞뒤 공백을 떼고 소문자로, 공백뿐이면 검색하지 않는다.
  assert.equal(parseMyPostsQuery({ teamId: TEAM, q: '  Hello 회의 ' }).text, 'hello 회의');
  assert.equal(parseMyPostsQuery({ teamId: TEAM, q: '   ' }).text, '');
  assert.ok(parseMyPostsQuery({ teamId: TEAM, q: ['a', 'b'] }).error);
  assert.equal(parseMyPostsQuery({ teamId: TEAM, q: '가'.repeat(MY_POSTS_QUERY_MAX) }).error, undefined);
  assert.ok(parseMyPostsQuery({ teamId: TEAM, q: '가'.repeat(MY_POSTS_QUERY_MAX + 1) }).error);

  // 모든 팀은 teamId가 없어도 되고, 있어도 보지 않는다. 한 팀(기본·team)은 teamId가 필수다.
  const all = parseMyPostsQuery({ scope: 'all' });
  assert.equal(all.error, undefined);
  assert.equal(all.allTeams, true);
  assert.equal(all.teamId, null);
  assert.equal(parseMyPostsQuery({ scope: 'all', teamId: TEAM }).teamId, null);
  assert.equal(parseMyPostsQuery({ scope: 'team', teamId: TEAM }).allTeams, false);
  assert.ok(parseMyPostsQuery({ scope: 'team' }).error);
  assert.ok(parseMyPostsQuery({ scope: 'everyone', teamId: TEAM }).error);
});

test('isMyPostMessage: 본문이나 제목이 있는 text·post만, 파일·이미지·이모티콘·시스템·투표·삭제는 제외', () => {
  assert.equal(isMyPostMessage({ type: 'text', text: '안녕' }), true);
  assert.equal(isMyPostMessage({ type: 'post', title: '제목만', text: null }), true);
  assert.equal(isMyPostMessage({ type: 'post', title: null, text: '본문만' }), true);
  assert.equal(isMyPostMessage({ type: 'text', text: '   ' }), false);
  assert.equal(isMyPostMessage({ type: 'text', text: null }), false);
  assert.equal(isMyPostMessage({ type: 'post', title: '', text: '' }), false);
  for (const type of ['image', 'file', 'sticker', 'system', 'poll']) {
    assert.equal(isMyPostMessage({ type, text: '캡션이 있어도' }), false, type);
  }
  assert.equal(isMyPostMessage({ type: 'text', text: '지움', deletedAt: new Date() }), false);
});

test('isMyPostComment: 본문이 있고 지워지지 않은 댓글만', () => {
  assert.equal(isMyPostComment({ text: '댓글' }), true);
  assert.equal(isMyPostComment({ text: '' }), false);
  assert.equal(isMyPostComment({ text: null, type: 'image' }), false);
  assert.equal(isMyPostComment({ text: '댓글', deletedAt: new Date() }), false);
});

test('previewText: 앞 N글자(이모지는 쪼개지 않음), 빈 값은 null', () => {
  assert.equal(previewText('  hello  ', 200), 'hello');
  assert.equal(previewText('가나다라마', 3), '가나다');
  assert.equal(previewText('😀😀😀', 2), '😀😀');
  assert.equal(previewText('x'.repeat(250), 200).length, 200);
  assert.equal(previewText('   ', 10), null);
  assert.equal(previewText(null, 10), null);
});

test('parentPreview: 제목 > 본문 > 종류 이름, 80자', () => {
  assert.equal(parentPreview({ type: 'post', title: '제목', text: '본문' }), '제목');
  assert.equal(parentPreview({ type: 'text', title: null, text: '본문' }), '본문');
  assert.equal(parentPreview({ type: 'image', title: null, text: null }), '사진');
  assert.equal(parentPreview({ type: 'poll', title: null, text: null }), '투표');
  assert.equal(parentPreview({ type: 'text', title: null, text: 'a'.repeat(100) }).length, 80);
});

test('mergeMyPosts: 시간순으로 섞어 limit개만, 남으면 hasMore와 nextBefore', () => {
  const m = (createdAt, id) => ({ kind: 'message', createdAt, id });
  const c = (createdAt, id) => ({ kind: 'comment', createdAt, id });
  const r = mergeMyPosts([[m(300, 'a'), m(100, 'b')], [c(200, 'c')]], { limit: 2 });
  assert.deepEqual(
    r.items.map((i) => i.id),
    ['a', 'c'],
  );
  assert.equal(r.hasMore, true);
  assert.equal(r.nextBefore, '200:c');

  const asc = mergeMyPosts([[m(100, 'b'), m(300, 'a')], [c(200, 'c')]], { limit: 5, order: 'asc' });
  assert.deepEqual(
    asc.items.map((i) => i.id),
    ['b', 'c', 'a'],
  );
  assert.equal(asc.hasMore, false);
  assert.equal(asc.nextBefore, null);

  // 같은 시각이면 id로 가른다.
  const tie = mergeMyPosts([[m(100, 'x')], [c(100, 'y')]], { limit: 5 });
  assert.deepEqual(
    tie.items.map((i) => i.id),
    ['y', 'x'],
  );
});
