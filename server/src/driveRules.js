/**
 * 팀 공유 드라이브의 규칙 — 이름 검사, 같은 폴더 안 이름 겹침, 폴더 옮기기(자기 아래로 못 옮김), 경로(빵부스러기), 권한을 DB 없이
 * 시험할 수 있게 모았다(drive.js가 쓴다, test/driveRules.test.js).
 *
 * 팀마다 하나의 드라이브 — 폴더(drive_folders, 위 폴더 parent_id)와 파일(drive_files, 지금 판 경로·크기·형식)과 파일의 판
 * (drive_file_versions — 같은 이름으로 다시 올리면 새 판). 지우면 휴지통(deleted_at)으로 가고, 거기서 되살리거나 영구 삭제한다.
 * 폴더를 휴지통에 넣으면 그 아래는 따로 표시하지 않아도 함께 안 보인다(위 폴더가 휴지통에 있으면 숨김).
 */

export const DRIVE_NAME_MAX = 120;
/** 폴더 깊이(맨 위 = 1). */
export const DRIVE_DEPTH_MAX = 10;
/** 한 폴더에 둘 수 있는 항목 수. */
export const DRIVE_ENTRIES_MAX = 1000;
/** 파일마다 남기는 판 수(넘으면 오래된 판의 기록부터 지운다 — 파일 자체는 업로드 보존 정책을 따름). */
export const DRIVE_VERSIONS_MAX = 50;
export const DRIVE_NOTE_MAX = 200;

// 윈도우 탐색기에서 못 쓰는 글자 + 제어 문자.
const BAD_CHARS = /[\\/:*?"<>|\u0000-\u001f\u007f]/;

/** 이름 → `{ name }` | `{ error }`. */
export function parseDriveName(input, what = '이름') {
  const name = typeof input === 'string' ? input.trim().replace(/\s+/g, ' ') : '';
  if (!name) return { error: `${what}을 입력하세요.` };
  if ([...name].length > DRIVE_NAME_MAX) return { error: `${what}은 ${DRIVE_NAME_MAX}자까지 쓸 수 있습니다.` };
  if (BAD_CHARS.test(name)) return { error: `${what}에는 \\ / : * ? " < > | 를 쓸 수 없습니다.` };
  if (name === '.' || name === '..') return { error: `${what}으로 쓸 수 없는 글자입니다.` };
  return { name };
}

/** 이름 겹침은 대소문자를 가리지 않는다(윈도우·맥 탐색기와 같게). */
export const nameKey = (name) => name.normalize('NFC').toLocaleLowerCase('ko');

/** [siblings]([{ id, name }] — 같은 폴더의 폴더·파일, 휴지통 제외) 중 [name]과 겹치는 것([exceptId]는 뺀다). */
export function findNameClash(siblings, name, exceptId = null) {
  const key = nameKey(name);
  return siblings.find((s) => s.id !== exceptId && nameKey(s.name) === key) ?? null;
}

/** 겹치지 않는 이름 — "보고서.pdf" → "보고서 (2).pdf"(되살리기·복사에서). */
export function uniqueName(name, siblings) {
  if (!findNameClash(siblings, name)) return name;
  const dot = name.lastIndexOf('.');
  const [base, ext] = dot > 0 ? [name.slice(0, dot), name.slice(dot)] : [name, ''];
  for (let i = 2; i < 1000; i += 1) {
    const candidate = `${base} (${i})${ext}`;
    if (!findNameClash(siblings, candidate)) return candidate;
  }
  return `${base} (${Date.now()})${ext}`;
}

/** [folderId]의 위 폴더들(가까운 것부터, 자기 포함) — [folders]는 id → { id, parentId, name }. 꼬여 있어도 멈춘다. */
export function ancestorChain(folders, folderId) {
  const chain = [];
  const seen = new Set();
  let cur = folderId ? folders.get(folderId) : null;
  while (cur && !seen.has(cur.id) && chain.length < 100) {
    seen.add(cur.id);
    chain.push(cur);
    cur = cur.parentId ? folders.get(cur.parentId) : null;
  }
  return chain;
}

/** 빵부스러기 — 맨 위부터 [folderId]까지 [{ id, name }]. */
export function breadcrumb(folders, folderId) {
  return ancestorChain(folders, folderId)
    .reverse()
    .map((f) => ({ id: f.id, name: f.name }));
}

/** 폴더가 (위 폴더를 따라) 휴지통에 들어가 있는지. */
export function isInTrash(folders, folderId) {
  return ancestorChain(folders, folderId).some((f) => f.deletedAt);
}

/**
 * 폴더 [folderId]를 [targetParentId](null = 맨 위) 아래로 옮겨도 되는지 — `{ ok: true }` | `{ error }`. 자기 자신이나 자기
 * 아래 폴더로는 못 옮기고, 옮긴 뒤 깊이가 [DRIVE_DEPTH_MAX]를 넘으면 안 된다([subtreeDepth]는 옮기는 폴더의 아래 깊이 — 자기 = 1).
 */
export function checkFolderMove(folders, folderId, targetParentId, subtreeDepth = 1) {
  if (targetParentId === folderId) return { error: '폴더를 자기 안으로 옮길 수 없습니다.' };
  const chain = ancestorChain(folders, targetParentId);
  if (chain.some((f) => f.id === folderId)) return { error: '폴더를 자기 아래 폴더로 옮길 수 없습니다.' };
  if (chain.length + subtreeDepth > DRIVE_DEPTH_MAX) return { error: `폴더는 ${DRIVE_DEPTH_MAX}단계까지 만들 수 있습니다.` };
  return { ok: true };
}

/** [folderId] 아래 깊이(자기 = 1) — [folders]는 id → { parentId }. */
export function subtreeDepthOf(folders, folderId) {
  const children = new Map();
  for (const f of folders.values()) {
    if (!f.parentId) continue;
    if (!children.has(f.parentId)) children.set(f.parentId, []);
    children.get(f.parentId).push(f.id);
  }
  const walk = (id, depth, seen) => {
    if (seen.has(id) || depth > 100) return depth;
    seen.add(id);
    let best = depth;
    for (const c of children.get(id) ?? []) best = Math.max(best, walk(c, depth + 1, seen));
    return best;
  };
  return walk(folderId, 1, new Set());
}

/** [folderId]와 그 아래 폴더 id 전부(영구 삭제·휴지통 비우기). */
export function descendantIds(folders, folderId) {
  const out = [];
  const stack = [folderId];
  const seen = new Set();
  while (stack.length > 0) {
    const id = stack.pop();
    if (seen.has(id)) continue;
    seen.add(id);
    out.push(id);
    for (const f of folders.values()) if (f.parentId === id) stack.push(f.id);
  }
  return out;
}

/**
 * 권한 — 팀 멤버는 보고 내려받는다. 준회원이 아니면 올리고·폴더를 만들고·새 판을 올리고·이름을 바꾸고·옮긴다. 휴지통에 넣기·되살리기·
 * 영구 삭제는 만든 사람이나 팀 관리자(소유자·계정 등급 관리자·서버 운영자).
 */
export function drivePermissions({ role, isOwner = false, isServerAdmin = false }) {
  const isManager = isServerAdmin || isOwner || role === 'admin';
  return { canWrite: role !== 'guest' || isManager, isManager };
}

export function canRemoveDriveItem(item, userId, perms) {
  return perms.isManager || (perms.canWrite && item.createdBy === userId);
}

/** 판 메모 → `{ note }`(null 가능) | `{ error }`. */
export function parseVersionNote(input) {
  if (input == null || input === '') return { note: null };
  if (typeof input !== 'string') return { error: '메모가 올바르지 않습니다.' };
  const note = input.trim();
  if ([...note].length > DRIVE_NOTE_MAX) return { error: `메모는 ${DRIVE_NOTE_MAX}자까지 쓸 수 있습니다.` };
  return { note: note || null };
}

/** 정렬 — 폴더 먼저, 그 안에서 이름순(숫자는 숫자대로). */
export function sortEntries(entries) {
  const collator = new Intl.Collator('ko', { numeric: true, sensitivity: 'base' });
  return [...entries].sort((a, b) => collator.compare(a.name, b.name));
}

/** "보고서.pdf" + 3 → "보고서 (판 3).pdf". */
export function versionedName(name, version) {
  const dot = name.lastIndexOf('.');
  return dot > 0 ? `${name.slice(0, dot)} (판 ${version})${name.slice(dot)}` : `${name} (판 ${version})`;
}
