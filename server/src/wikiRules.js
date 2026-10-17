import { ancestorChain, isInTrash, subtreeDepthOf } from './driveRules.js';

/**
 * 팀 위키의 규칙 — 제목·본문 한도, 페이지 나무(옮기기·휴지통·나무 목록), 권한, 찾기 미리보기(DB 없이 시험 — test/wikiRules.test.js).
 * 동시 편집(OT)은 otText.js, 메모리 문서·저장·판은 wikiDocs.js.
 */

export const WIKI_TITLE_MAX = 100;
/** 본문 한도(UTF-16 글자 수) — 동시 편집 문서를 메모리에 두므로 넉넉하되 끝없지는 않게. */
export const WIKI_BODY_MAX = 200_000;
export const WIKI_DEPTH_MAX = 10;
/** 연산 하나에 넣을 수 있는 글자 수(붙여넣기). */
export const WIKI_INSERT_MAX = 50_000;
/** 서버가 기억하는 최근 연산 수 — 늦게 온 연산·다시 붙은 앱이 이만큼 뒤까지 따라잡는다. */
export const WIKI_HISTORY_MAX = 1000;
/** 마지막 연산 뒤 이만큼 지나면 DB에 저장한다. */
export const WIKI_SAVE_DELAY_MS = 2000;
/** 편집하는 동안 판(스냅숏)을 남기는 간격. */
export const WIKI_SNAPSHOT_INTERVAL_MS = 10 * 60 * 1000;

const BAD = /[\u0000-\u001f\u007f]/g;

/** 제목 → `{ title }` | `{ error }`. */
export function parseWikiTitle(input) {
  const title = typeof input === 'string' ? input.replace(BAD, ' ').trim().replace(/\s+/g, ' ') : '';
  if (!title) return { error: '페이지 제목을 입력하세요.' };
  if ([...title].length > WIKI_TITLE_MAX) return { error: `제목은 ${WIKI_TITLE_MAX}자까지 쓸 수 있습니다.` };
  return { title };
}

/** 새 페이지의 첫 본문 → `{ body }` | `{ error }`. */
export function parseWikiBody(input) {
  if (input == null) return { body: '' };
  if (typeof input !== 'string') return { error: '본문이 올바르지 않습니다.' };
  if (input.length > WIKI_BODY_MAX) return { error: `본문은 ${WIKI_BODY_MAX.toLocaleString()}자까지 쓸 수 있습니다.` };
  return { body: input.replace(/\r\n/g, '\n') };
}

/** 페이지 [id]를 [parentId](null = 맨 위) 아래로 옮겨도 되는지 — `{ ok }` | `{ error }`. */
export function checkPageMove(pages, id, parentId) {
  if (parentId === id) return { error: '페이지를 자기 아래로 옮길 수 없습니다.' };
  const chain = ancestorChain(pages, parentId);
  if (chain.some((p) => p.id === id)) return { error: '페이지를 자기 아래 페이지로 옮길 수 없습니다.' };
  if (chain.length + subtreeDepthOf(pages, id) > WIKI_DEPTH_MAX) {
    return { error: `페이지는 ${WIKI_DEPTH_MAX}단계까지 둘 수 있습니다.` };
  }
  return { ok: true };
}

/** 휴지통(자기나 위 페이지가 지워짐)에 있는지. */
export const isPageInTrash = (pages, id) => isInTrash(pages, id);

/** 앱의 나무 목록 — 휴지통 아닌 페이지를 위 페이지별 순서(position, 같으면 제목)대로, 위에서 아래로 펼친 차례. */
export function wikiTree(pages) {
  const children = new Map();
  for (const p of pages.values()) {
    if (p.deletedAt) continue;
    const key = p.parentId ?? null;
    if (!children.has(key)) children.set(key, []);
    children.get(key).push(p);
  }
  const collator = new Intl.Collator('ko', { numeric: true });
  for (const list of children.values()) {
    list.sort((a, b) => a.position - b.position || collator.compare(a.title, b.title));
  }
  const out = [];
  const walk = (parentId, depth, seen) => {
    for (const p of children.get(parentId) ?? []) {
      if (seen.has(p.id)) continue;
      seen.add(p.id);
      out.push({ ...p, depth });
      walk(p.id, depth + 1, seen);
    }
  };
  walk(null, 0, new Set());
  return out;
}

/** 권한 — 팀 멤버는 읽고, 준회원이 아니면 만들고 고친다. 지우기·되살리기는 만든 사람이나 팀 관리자. */
export function wikiPermissions({ role, isOwner = false, isServerAdmin = false }) {
  const isManager = isServerAdmin || isOwner || role === 'admin';
  return { canEdit: role !== 'guest' || isManager, isManager };
}

export function canRemovePage(page, userId, perms) {
  return perms.isManager || (perms.canEdit && page.createdBy === userId);
}

/** 찾기 결과의 본문 미리보기 — 찾은 글자 앞뒤 40자. */
export function searchExcerpt(body, query) {
  const text = (body ?? '').replace(/\s+/g, ' ');
  const at = text.toLocaleLowerCase('ko').indexOf(query.toLocaleLowerCase('ko'));
  if (at < 0) return text.slice(0, 80);
  const start = Math.max(0, at - 40);
  const end = Math.min(text.length, at + query.length + 40);
  return `${start > 0 ? '…' : ''}${text.slice(start, end)}${end < text.length ? '…' : ''}`;
}

/** 편집 중인 사람 표시 색(사람 id로 늘 같은 색). */
const EDITOR_COLORS = ['#E8590C', '#1971C2', '#2F9E44', '#9C36B5', '#C2255C', '#0C8599', '#F08C00', '#5F3DC4'];
export function editorColor(userId) {
  let h = 0;
  for (const ch of String(userId)) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  return EDITOR_COLORS[h % EDITOR_COLORS.length];
}

/** 빵부스러기 — 맨 위부터 [pageId]까지 `[{ id, title }]`. */
export function pageBreadcrumb(pages, pageId) {
  return ancestorChain(pages, pageId)
    .reverse()
    .map((p) => ({ id: p.id, title: p.title }));
}
