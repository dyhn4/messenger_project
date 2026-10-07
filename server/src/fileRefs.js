// 클라이언트가 보낸 파일 참조를 저장하기 전에 확인하는 곳(규칙은 fileRefRules.js) — 메시지(sendMessage.js)·댓글·문의·예약 메시지·
// 앨범 항목·북마크 이미지·할 일 첨부(todos.js)·팀/그룹 아이콘(teams.js·rooms.js)·프로젝트 노트 본문(projects.js)이 모두 이 한 벌을 쓴다.
// 받는 것은 셋뿐이다:
//   (가) 보내는 사람이 직접 올린 파일(uploads 표) — 미서명 저장 경로로 오든 서명 링크로 오든,
//   (나) 서명 링크로 온, 보내는 사람이 지금 들어가 있는 방(비밀 대화 제외)에서 볼 수 있는 파일 — 메시지 전달(앱은 서명 링크만
//        들고 있다. 몇 시간 지나 만료됐어도 서명만 맞으면). 노트는 쓴 사람이 구성원인 프로젝트의 노트·이력에 있는 파일도 여기에 든다,
//   (다) 고치는 기록에 원래 있던 파일 — 화면이 들고 있던 값을 그대로 돌려보낸 것.
// 비밀 대화는 (가)만 받는다(자동 삭제가 그 파일을 실제로 지운다 — fileRefRules.js decideFileRefs).
import { findNoteReachableUploadPaths, findReachableUploadPaths, findUploaders } from './db/queries/uploads.js';
import {
  decideFileRefs,
  decideNoteFileTargets,
  FILE_REF_ERROR,
  fileRefPath,
  lookupPathsOf,
  noteFilePaths,
  noteFileTargets,
  presentRefs,
  rewriteNoteFileLinks,
  SECRET_FILE_REF_ERROR,
  storedPathsAllowed,
} from './fileRefRules.js';
import { uploadFileNameOf } from './upload.js';

const defaultLookups = { findUploaders, findReachableUploadPaths, findNoteReachableUploadPaths };

/**
 * [refs](문자열 — 빈 값·문자열 아님은 "첨부 없음"으로 건너뛴다)를 확인한다. 통과하면 `{ ok: true, paths }`(참조 → 저장할 미서명 경로
 * Map — 호출부는 받은 문자열 대신 이 값을 저장한다), 하나라도 안 되면 `{ ok: false, error }`([error] 문구 — 비밀 대화(ownedOnly)는
 * 따로 정하지 않으면 SECRET_FILE_REF_ERROR). [lookups]는 테스트가 DB 대신 넣는 조회 함수들.
 */
export async function checkFileRefs(
  refs,
  { senderId, existing = [], ownedOnly = false, error = ownedOnly ? SECRET_FILE_REF_ERROR : FILE_REF_ERROR } = {},
  lookups = defaultLookups,
) {
  const list = presentRefs(refs);
  if (list.length === 0) return { ok: true, paths: new Map() };
  const toLookUp = lookupPathsOf(list, ownedOnly ? [] : existing);
  if (toLookUp === null) return { ok: false, error };

  const uploaders =
    toLookUp.paths.length > 0 ? await lookups.findUploaders(toLookUp.paths.map(uploadFileNameOf)) : new Map();
  // 서명 링크로 온 남의 파일만 방까지 확인한다 — 보통 메시지(방금 올린 파일)는 여기서 끝나고, 전달할 때만 방을 본다.
  const notOwned = toLookUp.signedPaths.filter((p) => uploaders.get(uploadFileNameOf(p)) !== senderId);
  const reachable =
    !ownedOnly && notOwned.length > 0 ? await lookups.findReachableUploadPaths(senderId, notOwned) : new Set();

  const decision = decideFileRefs(list, { senderId, existing, uploaders, reachable, ownedOnly });
  return decision.ok ? decision : { ok: false, error };
}

/**
 * 아이콘 사진 하나(팀 아이콘 — teams.js, 그룹 아이콘 — rooms.js)를 저장할 미서명 경로로. 규칙은 checkFileRefs 그대로다: 이 사람이 올린
 * 사진, 지금 아이콘([currentIconUrl] — 설정 창이 들고 있던 서명 링크가 만료돼 돌아와도), 서명 링크로 온 지금 볼 수 있는 방의 사진.
 * 예전엔 알아낸 파일 이름(/uploads/<이름>)도 그대로 받아, 그 팀·그룹을 보는 사람 모두가 그 파일의 새 링크를 영영 받을 수 있었다.
 * 통과하면 `{ ok: true, path }`, 아니면 `{ ok: false, error }` — 문자열이 아니거나 빈 값도 거절이다(지우기는 호출부가 먼저 가른다).
 */
export async function checkIconRef(iconUrl, { senderId, currentIconUrl = null, error = FILE_REF_ERROR } = {}, lookups = defaultLookups) {
  if (typeof iconUrl !== 'string' || iconUrl === '') return { ok: false, error };
  const checked = await checkFileRefs(
    [iconUrl],
    { senderId, existing: currentIconUrl ? [currentIconUrl] : [], error },
    lookups,
  );
  return checked.ok ? { ok: true, path: checked.paths.get(iconUrl) } : { ok: false, error: checked.error };
}

/**
 * 프로젝트 노트 본문([body] — '\r'을 이미 뺀 것)의 이 서버 파일 링크를 거른 본문(fileRefRules.js rewriteNoteFileLinks — 받은 링크는 저장
 * 경로로, 받지 못한 링크는 글자만 남긴다. 저장을 거절하지는 않는다). 받는 것은:
 *   - 쓰는 사람([writerId])이 올린 파일,
 *   - [existingBodies]에 이미 있던 파일 — 고칠 때는 그 노트의 지금 본문, 이력을 되돌릴 때는 그 이력의 본문(편집 창이 몇 시간 들고
 *     있던 만료된 서명 링크도 그 파일로 알아본다),
 *   - 서명 링크로 온, 쓰는 사람이 지금 볼 수 있는 파일 — 구성원인 프로젝트의 노트·수정 이력에 있거나(노트 복제·노트 사이 그림 복사가
 *     이 모양이다 — 먼저 본다) 지금 들어가 있는 방에서 볼 수 있는 파일.
 * 미서명 저장 경로로 온 남의 파일은 어디에 있든 받지 않는다 — 앱은 그 모양을 방금 올린 자기 파일에만 쓴다(checkFileRefs와 같다).
 */
export async function filterNoteFileLinks(body, { writerId, existingBodies = [] } = {}, lookups = defaultLookups) {
  const targets = noteFileTargets(body);
  if (targets.length === 0) return body;
  // 주소마다 서명 링크는 한 번만 푼다 — 푸는 일(복호화)이 가볍지 않은데 아래 단계마다(원래 있던 본문 읽기 포함 — 이력을 되돌릴 때는
  // 같은 본문이다) 다시 풀면, 가짜 서명 링크를 수천 개 늘어놓은 본문에서 그 일이 몇 곱절이 된다.
  const resolvedPaths = new Map();
  const resolve = (ref) => {
    if (!resolvedPaths.has(ref)) resolvedPaths.set(ref, fileRefPath(ref));
    return resolvedPaths.get(ref);
  };
  const existing = [...new Set(existingBodies.flatMap((b) => noteFilePaths(b, resolve)))];
  // 알아볼 수 없는 주소(위조·예전 JWT 링크·하위 경로)는 어차피 버리므로 조회에 넣지 않는다.
  const toLookUp = lookupPathsOf(targets.filter(resolve), existing, resolve);
  const uploaders =
    toLookUp.paths.length > 0 ? await lookups.findUploaders(toLookUp.paths.map(uploadFileNameOf)) : new Map();
  const notOwned = toLookUp.signedPaths.filter((p) => uploaders.get(uploadFileNameOf(p)) !== writerId);
  const reachable = new Set();
  if (notOwned.length > 0) {
    for (const p of await lookups.findNoteReachableUploadPaths(writerId, notOwned)) reachable.add(p);
    const rest = notOwned.filter((p) => !reachable.has(p));
    if (rest.length > 0) for (const p of await lookups.findReachableUploadPaths(writerId, rest)) reachable.add(p);
  }
  const accepted = decideNoteFileTargets(targets, { senderId: writerId, existing, uploaders, reachable, resolve });
  return rewriteNoteFileLinks(body, accepted);
}

/**
 * 서버가 저장해 둔 경로로 다시 보낼 때(예약 메시지 발송) — fileRefRules.js storedPathsAllowed. 통과하면 true.
 */
export async function storedFilesAllowed(paths, { senderId }, lookups = defaultLookups) {
  const list = presentRefs(paths);
  if (list.length === 0) return true;
  if (list.some((p) => !uploadFileNameOf(p))) return false;
  const uploaders = await lookups.findUploaders(list.map(uploadFileNameOf));
  return storedPathsAllowed(list, { senderId, uploaders });
}
