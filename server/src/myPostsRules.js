// "내가 쓴 글"(`GET /api/my-posts`)의 순수 규칙 — 쿼리 검사·미리보기·섞기. DB·서버 없이 단위 테스트한다
// (test/myPosts.test.js). 저장소 조회는 db/queries/myPosts.js, 요청 처리는 myPosts.js.
import { compareByCursor, formatCursor, isUuid, parseCursor, parseLimit, parseTimeBound } from './pageCursor.js';

export const MY_POST_KINDS = ['all', 'message', 'comment'];
export const MY_POSTS_DEFAULT_LIMIT = 30;
export const MY_POSTS_MAX_LIMIT = 100;
export const MY_POST_TEXT_PREVIEW = 200;
export const MY_POST_PARENT_PREVIEW = 80;
export const MY_POSTS_QUERY_MAX = 200;

/**
 * 쿼리 검사 — 통과하면 `{ teamId|null, allTeams, text, roomId|null, kind, since|null, until|null, order, cursor|null, limit }`,
 * 아니면 `{ error }`. kind는 all|message|comment(기본 all — 화면의 전체/메시지/댓글 탭), since/until은 글을 쓴 시각(밀리초),
 * order는 desc|asc(기본 desc), limit은 1..100(기본 30).
 * scope는 team(기본 — teamId 한 팀, teamId 필수)|all(내가 속한 모든 팀 — teamId는 보지 않는다), q는 본문·제목 부분 일치 검색어
 * (앞뒤 공백을 떼고 소문자로 — 비면 검색하지 않는다, 최대 200자).
 */
export function parseMyPostsQuery(query) {
  const q = query ?? {};
  if (q.scope !== undefined && q.scope !== '' && q.scope !== 'team' && q.scope !== 'all') {
    return { error: 'scope는 team|all 중 하나여야 합니다.' };
  }
  const allTeams = q.scope === 'all';
  let teamId = null;
  if (!allTeams) {
    teamId = typeof q.teamId === 'string' ? q.teamId : '';
    if (!isUuid(teamId)) return { error: 'teamId가 필요합니다.' };
  }
  if (q.q !== undefined && typeof q.q !== 'string') return { error: 'q가 올바르지 않습니다.' };
  const text = (q.q ?? '').trim().toLowerCase();
  if ([...text].length > MY_POSTS_QUERY_MAX) return { error: `검색어는 ${MY_POSTS_QUERY_MAX}자까지입니다.` };
  const kind = typeof q.kind === 'string' && q.kind ? q.kind : 'all';
  if (!MY_POST_KINDS.includes(kind)) return { error: `kind는 ${MY_POST_KINDS.join('|')} 중 하나여야 합니다.` };
  if (q.order !== undefined && q.order !== '' && q.order !== 'asc' && q.order !== 'desc') {
    return { error: 'order는 asc|desc 중 하나여야 합니다.' };
  }
  const order = q.order === 'asc' ? 'asc' : 'desc';

  let roomId = null;
  if (q.roomId !== undefined && q.roomId !== '') {
    if (typeof q.roomId !== 'string') return { error: 'roomId가 올바르지 않습니다.' };
    roomId = q.roomId;
  }
  const since = parseTimeBound(q.since);
  if (since === undefined) return { error: 'since는 밀리초 시각이어야 합니다.' };
  const until = parseTimeBound(q.until);
  if (until === undefined) return { error: 'until은 밀리초 시각이어야 합니다.' };
  const cursor = parseCursor(q.before);
  if (cursor?.error) return { error: cursor.error };
  const limit = parseLimit(q.limit, { fallback: MY_POSTS_DEFAULT_LIMIT, max: MY_POSTS_MAX_LIMIT });
  if (limit === null) return { error: 'limit은 1 이상의 숫자여야 합니다.' };
  return { teamId, allTeams, text, roomId, kind, since, until, order, cursor, limit };
}

const hasText = (v) => typeof v === 'string' && v.trim() !== '';

/**
 * 메시지가 "내가 쓴 글"에 들어가는지 — 본문이나 제목이 있는 일반 메시지(text)·게시글(post)만. 파일·이미지·이모티콘만 보낸 것,
 * 시스템 메시지, 투표, 지워진 것은 뺀다(DB 조건과 같은 규칙).
 */
export function isMyPostMessage(m) {
  if (m.deletedAt) return false;
  if (m.type !== 'text' && m.type !== 'post') return false;
  return hasText(m.text) || hasText(m.title);
}

/** 댓글이 들어가는지 — 본문이 있고 지워지지 않은 것(첨부만 있는 댓글은 뺀다). */
export function isMyPostComment(c) {
  return !c.deletedAt && hasText(c.text);
}

/** 앞에서 [max]글자(이모지 같은 한 덩어리는 쪼개지 않는다)만, 넘치면 …을 붙이지 않고 그대로 자른다. 비면 null. */
export function previewText(text, max) {
  if (!hasText(text)) return null;
  const chars = [...text.trim()];
  return chars.length > max ? chars.slice(0, max).join('') : chars.join('');
}

const PARENT_TYPE_LABEL = { image: '사진', file: '파일', sticker: '이모티콘', poll: '투표' };

/** 댓글의 원본 메시지 한 줄 — 제목(게시글) > 본문 > 첨부·투표 종류 이름. */
export function parentPreview(parent) {
  return (
    previewText(parent.title, MY_POST_PARENT_PREVIEW) ??
    previewText(parent.text, MY_POST_PARENT_PREVIEW) ??
    PARENT_TYPE_LABEL[parent.type] ??
    null
  );
}

/**
 * 메시지 목록과 댓글 목록(각각 이미 [order] 순)을 한 줄로 섞어 앞에서 [limit]개만 남긴다. 각 항목은 `{ createdAt(ms), id, ... }`.
 * 각 목록은 [limit]+1개까지 받아 오므로, 섞은 뒤 [limit]보다 많으면 [hasMore]다.
 * [nextBefore]는 마지막 항목의 커서(`"<ms>:<id>"`) — 더 없으면 null.
 */
export function mergeMyPosts(lists, { limit, order = 'desc' }) {
  const all = lists.flat().sort(compareByCursor(order));
  const items = all.slice(0, limit);
  const hasMore = all.length > limit;
  const last = items[items.length - 1];
  return { items, hasMore, nextBefore: hasMore && last ? formatCursor(last.createdAt, last.id) : null };
}
