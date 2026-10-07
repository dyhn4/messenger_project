// 클라이언트가 보낸 파일 참조(메시지·댓글·문의·예약 메시지·앨범·북마크·할 일의 첨부·미리보기 경로, 팀·그룹 아이콘, 프로젝트 노트
// 본문 속 링크)를 저장해도 되는지 정하는 순수 규칙 — DB 없이 단위 테스트한다(test/fileRefRules.test.js, test/noteFileRefs.test.js).
// 올린 사람·볼 수 있는 방처럼 DB가 필요한 값은 fileRefs.js가 찾아서 넘긴다.
//
// 왜: 예전엔 미서명 저장 경로(/uploads/<이름>)를 보낸 그대로 저장했다. DTO는 저장된 경로를 볼 때마다 새로 서명해 주므로, 어디서든
// 한 번 알게 된 파일 이름(예전 JWT 링크는 base64만 풀면 이름이 보였다)을 내 메시지·댓글에 실으면 방에서 내보내진 뒤에도, 파일이
// 지워진 뒤에도 그 파일을 영영 받을 수 있었다. 이제는 "이 사람이 써도 되는 파일"만 받는다.
import { knownUploadPath, uploadFileNameOf } from './upload.js';

/** 받을 수 없는 참조가 있을 때의 문구 — 남의 파일·없는 파일·위조 링크를 구분하지 않는다(어떤 파일이 있는지 알려주지 않게). */
export const FILE_REF_ERROR = '첨부 파일을 확인할 수 없습니다. 파일을 다시 올린 뒤 보내 주세요.';
/** 비밀 대화(직접 올린 파일만 — ownedOnly)에서의 문구. */
export const SECRET_FILE_REF_ERROR = '비밀 대화에는 직접 올린 파일만 보낼 수 있습니다. 파일을 다시 첨부해 주세요.';

/**
 * 참조 하나를 저장 경로(/uploads/<이름>)로 — 서명 링크(/files/<토큰>)는 서명이 맞으면 만료됐어도 원본 경로로 되돌리고, 미서명 저장
 * 경로는 그대로. 그 밖(위조·옛 JWT 토큰·외부 주소·하위 경로·문자열 아님)은 null.
 *
 * 만료를 보지 않는 이유: 받을지는 decideFileRefs가 "누가 올렸나·지금 볼 수 있나·원래 있던 값인가"로 정한다. 링크가 아직 살아
 * 있다는 것만으로는 받지 않는다 — 남에게 받은 링크도 살아 있는 동안은 열리므로, 그것만으로 받으면 그 파일을 영구히 붙잡아 둘
 * 수 있다. 거꾸로 앱이 몇 시간 들고 있던(만료된) 링크라도 그 사람이 지금 볼 수 있는 파일이면 그대로 전달된다.
 */
export function fileRefPath(ref) {
  const raw = knownUploadPath(ref);
  return uploadFileNameOf(raw) ? raw : null;
}

/** 저장할 참조만 추린다 — 문자열이 아니거나 빈 값은 "첨부 없음"이라 검사 대상이 아니다. */
export function presentRefs(refs) {
  return (Array.isArray(refs) ? refs : []).filter((r) => typeof r === 'string' && r !== '');
}

/**
 * 서명 링크(/files/<토큰>)로 온 참조인지 — 앱은 DTO에서 받은 서명 링크로만 남의 파일을 가리킨다(메시지 전달). 미서명 저장 경로
 * (/uploads/<이름>)는 업로드 응답으로 받은 자기 파일에만 쓰므로, 그 모양으로 온 남의 파일은 "지금 볼 수 있는 방"까지 찾아보지도
 * 않는다(지어낸 이름을 잔뜩 실어 표를 훑게 만들지 못하게).
 */
export function isSignedRef(ref) {
  return typeof ref === 'string' && ref.startsWith('/files/');
}

/**
 * 참조들([refs])을 받을지 정한다. 하나라도 안 되면 전체를 거절한다(일부만 빼고 보내면 받는 사람은 파일이 빠진 줄 모른다).
 *  - existing: 이 기록(고치는 중인 예약 메시지·북마크 등)에 이미 저장돼 있던 경로들 — 화면이 들고 있던 값을 그대로 돌려보낸 것.
 *  - uploaders: 저장 이름 → 올린 사람 id(uploads 표 — db/queries/uploads.js findUploaders). 기록이 없으면(이 표가 생기기 전 파일)
 *    올린 사람으로 인정할 수 없다.
 *  - reachable: 보내는 사람이 지금 들어가 있는 방에서 볼 수 있는 경로들(findReachableUploadPaths) — 메시지 전달. 서명 링크로 온
 *    참조에만 쓴다(isSignedRef).
 *  - ownedOnly: 비밀 대화 — 자동 삭제(secretExpiry.js)가 그 파일을 실제로 지우므로 직접 올린 파일만 받는다(원래 있던 값도 예외 없음).
 *  - resolve: 참조 → 저장 경로(기본 fileRefPath). 서명 링크를 푸는 일(복호화)이 가볍지 않아서, 같은 참조를 여러 단계에서 보는 곳(노트
 *    본문 — 링크가 수천 개일 수 있다, fileRefs.js filterNoteFileLinks)은 한 번 푼 결과를 기억해 두는 함수를 넘긴다.
 * 통과하면 `{ ok: true, paths }`(참조 → 저장할 경로 Map), 아니면 `{ ok: false, rejected }`(받지 못한 참조들).
 */
export function decideFileRefs(
  refs,
  { senderId, existing = [], uploaders = new Map(), reachable = new Set(), ownedOnly = false, resolve = fileRefPath } = {},
) {
  const existingSet = new Set(existing.filter((p) => typeof p === 'string' && p));
  const paths = new Map();
  const rejected = [];
  for (const ref of presentRefs(refs)) {
    const path = resolve(ref);
    const owned = path != null && senderId != null && uploaders.get(uploadFileNameOf(path)) === senderId;
    const shared = !ownedOnly && (existingSet.has(path) || (isSignedRef(ref) && reachable.has(path)));
    if (path != null && (owned || shared)) paths.set(ref, path);
    else rejected.push(ref);
  }
  return rejected.length === 0 ? { ok: true, paths } : { ok: false, rejected };
}

/**
 * DB를 보기 전에 — 올린 사람을 찾아볼 경로들(원래 있던 경로는 빼고)과, 그 가운데 서명 링크로 온 경로(올린 사람이 아니면 방까지
 * 확인할 후보)를 고른다. 알아볼 수 없는 참조가 하나라도 있으면 null(어차피 거절이라 조회할 필요가 없다). [resolve]는
 * decideFileRefs와 같다.
 * 결과: `{ paths, signedPaths }` 또는 null.
 */
export function lookupPathsOf(refs, existing = [], resolve = fileRefPath) {
  const existingSet = new Set(existing);
  const list = presentRefs(refs);
  const resolved = list.map((ref) => resolve(ref));
  if (resolved.includes(null)) return null;
  const fresh = (p) => !existingSet.has(p);
  return {
    paths: [...new Set(resolved.filter(fresh))],
    signedPaths: [...new Set(resolved.filter((p, i) => fresh(p) && isSignedRef(list[i])))],
  };
}

/**
 * 서버가 저장해 둔 값으로 다시 보낼 때(예약 메시지 발송) — 저장 경로 모양이어야 하고, uploads 표에 기록이 있으면 보내는 사람이 올린
 * 파일이어야 한다. 기록이 없는 파일(이 표가 생기기 전에 올린 것)은 예전처럼 보낸다: 그런 예약은 이 검사가 생기기 전에 만들어졌고
 * 그때는 올린 사람을 알 길이 없었다. 새로 만들거나 고친 예약은 저장할 때 decideFileRefs를 거친다.
 * 통과하면 true.
 */
export function storedPathsAllowed(paths, { senderId, uploaders = new Map() }) {
  return paths.every((path) => {
    const name = uploadFileNameOf(path);
    if (!name) return false;
    return !uploaders.has(name) || (senderId != null && uploaders.get(name) === senderId);
  });
}

// ── 노트 본문 속 파일 링크 ──────────────────────────────────────────────
// 프로젝트 노트 본문은 마크다운 글이라 이 서버 파일이 그림·링크(`![이름](/uploads/…)`, `[글](/uploads/…)`)로 글 속에 들어 있다. 내려줄
// 때는 본문 속 `](/uploads/…)`를 앞의 대괄호와 상관없이 모두 그때그때 서명해 준다(projects.js signNoteBody — signNoteFileLinks).
// 그래서 예전엔 어디서 알게 된 파일 이름이나 남에게 받은 링크를 노트에 적어 두면, 그 노트를 보는 구성원 모두가 — 쓴 사람은 그
// 방·프로젝트에서 빠진 뒤에도 — 그 파일을 영영 받을 수 있었다(검토 S22). 이제 저장할 때(만들기·고치기·이력 되돌리기) 본문 속 이
// 서버 파일 링크를 하나씩 본다.
// 받는 것은 checkFileRefs와 같은 셋이다(쓴 사람이 올린 파일, 이 노트에 이미 있던 파일, 서명 링크로 온 지금 볼 수 있는 파일) — 다만
// "지금 볼 수 있는" 곳에 방 말고도 쓴 사람이 구성원인 프로젝트의 노트·수정 이력을 넣는다(앱의 노트 복제와 노트 사이 그림 복사는 받아
// 둔 서명 링크를 그대로 보낸다 — fileRefs.js filterNoteFileLinks). 받을 수 없는 링크가 있어도 저장을 통째로 거절하지 않고 그 링크만
// 글자로 바꾼다(그림은 이름, 링크는 글만 남긴다) — 긴 노트를 쓰다가 그림 하나 때문에 쓴 것을 잃지 않게, 그리고 예전 앱이 이유를 몰라
// 저장을 되풀이하지 않게.

// 정규식은 모두 본문 길이에 비례하는 시간에 끝나야 한다 — 노트 본문은 5만 자(새 노트는 서명 링크째 그 몇 배)까지 오고, 서버는 한
// 줄기로 돌아서 정규식이 도는 동안 채팅·소켓·다른 사람의 요청이 모두 멈춘다. 예전 모양은 '['·'!'만 잔뜩 늘어놓거나 닫히지 않은
// `](/uploads/a`를 수천 번 이은 본문에서 시작점마다 끝까지 다시 읽어, 5만 자 한 번 저장에 몇 초씩 걸렸다(검토 S22 후속).
// test/noteFileRefs.test.js가 그런 본문으로 시간을 재고, 찾는 링크가 예전 모양과 같은지도 맞춰 본다.

// 이 서버 파일을 가리킬 수 있는 링크 주소의 앞머리 — 저장 경로(/uploads/…)와 서명 링크(/files/…). 서명은 `](/uploads/…)`를 보면 하위
// 경로든 뭐든(마지막 마디만 떼어) 서명하므로, 검사도 정확한 모양이 아니라 이 앞머리로 시작하는 것 전부를 본다(알아볼 수 없는 것은
// 버린다). 주소 칸의 길이는 자르지 않는다 — 자르면 서명(signNoteFileLinks)과 SQL(db/queries/uploads.js NOTE_LINK_PATTERN)도 똑같이
// 잘라야 하고, 그보다 긴 주소는 검사를 비켜 간 채 서명될 수 있다.
const NOTE_FILE_PREFIX = String.raw`(?:\/uploads\/|\/files\/)`;
const NOTE_FILE_TARGET = String.raw`${NOTE_FILE_PREFIX}[^)\s]*`;
// 닫는 ')' 없이 공백·줄바꿈·본문 끝에서 끊긴 주소 칸 — 링크가 아니라서 바꾸지 않고 한 덩어리로 건너뛴다. 그 안에서 시작하는 `](…`도
// 같은 자리에서 끊기므로 링크가 될 수 없어, 건너뛰어도 찾는 링크는 같다. 건너뛰지 않으면 시작점마다 그 끝까지 다시 읽는다.
const NOTE_FILE_UNCLOSED = String.raw`\]\(${NOTE_FILE_PREFIX}[^)\s]*`;
// 링크 한 덩어리 — (1) 이름·글이 있는 그림·링크(`![이름](주소)`·`[글](주소)`), (2) 이름 칸을 알아볼 수 없는 맨 `](주소)`, (3) 닫히지
// 않은 주소 칸(위 — 건너뛰기). 어떤 모양으로 쓰였든 이 서버 파일 주소 칸은 (1)·(2) 가운데 하나로 다 잡힌다.
//  - 이름에는 '['·']'·줄바꿈이 없다: ']'가 없어서 한 덩어리가 다른 링크를 품지 못하고, '['가 없어서 '['마다 다음 '['까지만 읽는다.
//    이름에 '['가 든 링크는 ']'에서 가장 가까운 '['부터의 (1)이나 (2)로 잡힌다 — 주소 칸은 똑같이 잡히고, 받지 못했을 때 남는 글자만
//    다르다.
//  - 그림 표시 '!'는 바로 앞의 하나만 본다. 앞에 더 있던 '!'는 원래 글자라 어차피 그대로 남는다(rewriteNoteFileLinks).
const NOTE_FILE_LINK_PATTERN = new RegExp(
  String.raw`(!?)\[([^\[\]\n]*)\]\((${NOTE_FILE_TARGET})\)|\]\((${NOTE_FILE_TARGET})\)|${NOTE_FILE_UNCLOSED}`,
  'g',
);
// 다 바꾼 뒤에 다시 훑는 모양 — 서명(NOTE_SIGN_PATTERN)이 찾는 `](/uploads/…)`와 서명 링크 `](/files/…)`(닫히지 않은 주소 칸은
// 건너뛴다).
const NOTE_FILE_LINK_TARGET_PATTERN = new RegExp(String.raw`\]\((${NOTE_FILE_TARGET})\)|${NOTE_FILE_UNCLOSED}`, 'g');
// 내려줄 때 서명하는 모양 — 저장 경로 링크 `](/uploads/<무엇이든>)`, 앞의 대괄호와 상관없이(예전 projects.js signNoteBody와 같은
// 링크를 찾는다 — 닫히지 않은 주소 칸만 위와 같은 까닭으로 한 덩어리로 건너뛴다). 바로 위의 다시 훑는 모양이 이것을 모두 품어야
// 저장할 때 받은 파일만 서명된다. db/queries/uploads.js NOTE_LINK_PATTERN(SQL)도 같은 링크를 찾는다.
const NOTE_SIGN_PATTERN = /\]\((\/uploads\/[^)\s]+)\)|\]\(\/uploads\/[^)\s]*/g;
// 본문에 다시 써도 되는 저장 경로 — 한 마디이고 링크 문법을 흐트러뜨리는 글자(괄호·대괄호·공백)가 없을 것. 이름에 그런 글자가 든
// 파일(올릴 때 확장자에 들어갔던 것)은 링크로 쓰면 서명이 다른 이름을 잘라 읽으므로 받지 않는다.
const NOTE_SAFE_STORED_PATH = /^\/uploads\/[^/\\()[\]\s]+$/;

/** 노트 본문의 이 서버 파일 링크 주소들(본문 그대로의 글자, 중복 없이 나온 순서대로) — 서명 링크든 저장 경로든, 알아볼 수 없는 것도. */
export function noteFileTargets(body) {
  if (typeof body !== 'string' || body === '') return [];
  const targets = new Set();
  for (const m of body.matchAll(NOTE_FILE_LINK_PATTERN)) {
    const target = m[3] ?? m[4];
    if (target !== undefined) targets.add(target); // 닫히지 않은 주소 칸(건너뛴 덩어리)은 링크가 아니다.
  }
  return [...targets];
}

/**
 * 노트 본문에 이미 들어 있는 파일의 저장 경로들 — 고칠 때의 "원래 있던 파일"(서명이 맞는 예전 /files/ 링크도 그 파일로 본다).
 * [resolve]는 decideFileRefs와 같다.
 */
export function noteFilePaths(body, resolve = fileRefPath) {
  return [...new Set(noteFileTargets(body).map((target) => resolve(target)).filter(Boolean))];
}

/**
 * 노트 본문의 링크 주소들([targets] — noteFileTargets) 가운데 받을 수 있는 것 → 저장 경로의 Map. 판단은 decideFileRefs와 똑같다(쓴
 * 사람이 올린 파일·[existing]에 있던 파일·[reachable]에 든 서명 링크의 파일 — 보내는 사람 자리에 쓴 사람). 다만 하나가 안 된다고 전부
 * 버리지 않고 주소마다 따로 정한다. 저장 경로가 링크로 다시 쓰기에 안전한 모양이 아니면(NOTE_SAFE_STORED_PATH) 받지 않는다.
 * [resolve]는 decideFileRefs와 같다.
 */
export function decideNoteFileTargets(
  targets,
  { senderId, existing = [], uploaders = new Map(), reachable = new Set(), resolve = fileRefPath } = {},
) {
  const list = presentRefs(targets);
  const decision = decideFileRefs(list, { senderId, existing, uploaders, reachable, resolve });
  const rejected = new Set(decision.ok ? [] : decision.rejected);
  const accepted = new Map();
  for (const target of list) {
    if (rejected.has(target)) continue;
    const path = resolve(target);
    if (path && NOTE_SAFE_STORED_PATH.test(path)) accepted.set(target, path);
  }
  return accepted;
}

/**
 * 노트 본문([body] — '\r'을 이미 뺀 것)의 이 서버 파일 링크를 [accepted](decideNoteFileTargets) 대로 다시 쓴 본문. 받은 링크는 저장
 * 경로로 바꾸고, 받지 못한 링크는 글자만 남긴다 — 그림은 이름(없으면 '그림'), 링크는 글. 그림 표시('!')는 하나만 뗀다(앞에 더 있던
 * '!'는 원래 글자다). 이름 칸을 알아볼 수 없는 맨 `](주소)`는 주소만 지우고 ']'는 남긴다. 닫히지 않은 주소 칸은 링크가 아니라서
 * 그대로 둔다.
 *
 * 바꾼 자리가 앞뒤 글자와 이어져 새 링크(`](/uploads/…)`)가 생길 수 있어서(예: ']' 뒤에 남긴 글이 '('로 시작) 마지막에 한 번 더 훑어,
 * 받은 저장 경로가 아닌 주소 칸은 모두 지운다(']' 뒤에 빈칸을 둬 다시 이어지지 않게). 그래서 저장되는 본문에서 서명
 * (signNoteFileLinks)이 찾는 `](/uploads/…)`는 모두 받은 파일뿐이고, 서명 링크 `](/files/…)`는 남지 않는다.
 */
export function rewriteNoteFileLinks(body, accepted = new Map()) {
  if (typeof body !== 'string' || body === '') return body;
  const rewritten = body.replace(NOTE_FILE_LINK_PATTERN, (match, bang, name, target, bareTarget) => {
    if (target !== undefined) {
      const stored = accepted.get(target);
      if (stored) return `${bang}[${name}](${stored})`;
      return bang ? (name.trim() ? name : '그림') : name;
    }
    if (bareTarget === undefined) return match; // 닫히지 않은 주소 칸
    const stored = accepted.get(bareTarget);
    return stored ? `](${stored})` : ']';
  });
  const keep = new Set(accepted.values());
  return rewritten.replace(NOTE_FILE_LINK_TARGET_PATTERN, (match, target) =>
    target === undefined || keep.has(target) ? match : '] ',
  );
}

/**
 * 내려줄 때 — 노트 본문([body])의 저장 경로 링크(`](/uploads/…)`)마다 [sign](저장 경로 → 그때의 서명 링크 — projects.js는
 * upload.js signFileUrl)으로 바꾼 본문. 저장할 때 마지막에 다시 훑는 모양(rewriteNoteFileLinks)이 이 링크를 모두 품으므로, 이 규칙
 * 뒤에 저장된 본문에서 서명되는 것은 저장할 때 받은 파일뿐이다.
 */
export function signNoteFileLinks(body, sign) {
  if (typeof body !== 'string' || body === '') return body;
  return body.replace(NOTE_SIGN_PATTERN, (match, stored) => (stored === undefined ? match : `](${sign(stored)})`));
}
