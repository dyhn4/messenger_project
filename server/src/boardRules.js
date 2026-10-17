import { randomBytes } from 'node:crypto';

/**
 * 보드 보강 규칙 — 말머리(분류) 목록 검사, 게시글의 말머리 고르기, 읽음 확인 나누기(boardExtras.js·rooms.js·sendMessage.js·messages.js가
 * 쓴다 — DB 없이 시험한다).
 */

export const BOARD_CATEGORIES_MAX = 20;
export const BOARD_CATEGORY_NAME_MAX = 20;
/** 말머리 색 — 앱의 고르기 판과 같다(이 밖의 값은 첫 색으로). */
export const BOARD_CATEGORY_COLORS = Object.freeze([
  '#5B8DEF',
  '#2A9D8F',
  '#F4A261',
  '#E76F51',
  '#9B5DE5',
  '#E53935',
  '#00B4D8',
  '#6C757D',
]);

const ID_RE = /^k[a-z0-9]{6,16}$/;
const newCategoryId = () => `k${randomBytes(6).toString('hex')}`;

/**
 * 말머리 목록 입력 `[{ id?, name, color? }]` → `{ categories }` | `{ error }`. id가 없거나 모양이 틀리면 새로 만든다(이미 있던 id는 그대로 —
 * 게시글이 그 id를 가리킨다). 이름은 앞뒤 공백을 떼고 1~20자, 같은 이름은 안 된다.
 */
export function parseBoardCategories(input) {
  if (!Array.isArray(input)) return { error: '말머리 목록을 확인하세요.' };
  if (input.length > BOARD_CATEGORIES_MAX) return { error: `말머리는 ${BOARD_CATEGORIES_MAX}개까지입니다.` };
  const names = new Set();
  const ids = new Set();
  const categories = [];
  for (const item of input) {
    const name = typeof item?.name === 'string' ? item.name.trim() : '';
    if (!name) return { error: '말머리 이름을 넣으세요.' };
    if ([...name].length > BOARD_CATEGORY_NAME_MAX) return { error: `말머리 이름은 ${BOARD_CATEGORY_NAME_MAX}자 이내로 넣으세요.` };
    if (names.has(name)) return { error: `같은 이름의 말머리가 있습니다: ${name}` };
    names.add(name);
    let id = typeof item?.id === 'string' && ID_RE.test(item.id) ? item.id : newCategoryId();
    if (ids.has(id)) id = newCategoryId();
    ids.add(id);
    const color = BOARD_CATEGORY_COLORS.includes(item?.color) ? item.color : BOARD_CATEGORY_COLORS[0];
    categories.push({ id, name, color });
  }
  return { categories };
}

/** 방의 말머리 목록(보드가 아니거나 비었으면 []). */
export const boardCategoriesOf = (room) =>
  room?.type === 'topic' && room?.viewMode === 'board' && Array.isArray(room.boardCategories) ? room.boardCategories : [];

/**
 * 게시글의 말머리 입력 → `{ categoryId }`(null이면 말머리 없음) | `{ error }`. undefined면 `{ keep: true }`(고칠 때 그대로).
 */
export function parsePostCategory(value, room) {
  if (value === undefined) return { keep: true };
  if (value === null || value === '') return { categoryId: null };
  if (typeof value !== 'string' || !boardCategoriesOf(room).some((c) => c.id === value)) {
    return { error: '말머리를 확인하세요. 관리자가 지웠을 수 있습니다.' };
  }
  return { categoryId: value };
}

/**
 * 게시글 읽음 확인 — 지금 방 멤버([members] `[{ id, name }]`)를 읽은 사람(읽은 시각순)과 안 읽은 사람으로 나눈다. 쓴 사람은 늘 읽은 쪽
 * (게시글을 쓴 시각). [reads]는 `[{ userId, readAt }]`.
 */
export function splitReaders({ members, reads, authorId, postedAt }) {
  const readAt = new Map(reads.map((r) => [r.userId, new Date(r.readAt).getTime()]));
  if (authorId) readAt.set(authorId, Math.min(readAt.get(authorId) ?? Infinity, new Date(postedAt).getTime()));
  const read = [];
  const unread = [];
  for (const m of members) {
    const at = readAt.get(m.id);
    if (at != null && Number.isFinite(at)) read.push({ userId: m.id, name: m.name, readAt: at });
    else unread.push({ userId: m.id, name: m.name });
  }
  read.sort((a, b) => a.readAt - b.readAt);
  unread.sort((a, b) => a.name.localeCompare(b.name, 'ko'));
  return { read, unread };
}
