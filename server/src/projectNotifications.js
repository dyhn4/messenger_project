import { RateLimiter } from './authGuard.js';
import { accountRole } from './permissions.js';

/**
 * 프로젝트의 알림·자동화·구성원 판단 중 DB 없이 할 수 있는 부분 — 누가 프로젝트 내용과 알림을 받을 수 있는지, 공개
 * 프로젝트 생성 알림을 언제·몇 번 보내는지, 자동화 "채팅방 알림"을 누구 권한으로·얼마나 자주 올리는지, 알림과 채팅방에
 * 그대로 실리는 업무 제목·설명의 길이, 프로젝트 라우터 입구(준회원 막기)가 걸리는 주소, 노트 본문의 그림 주소와 목록 미리보기.
 * DB를 읽는 쪽(projects.js·projectNotify.js·projectAutomation.js)이 사용자 행이나 구성원 여부 같은 사실만 넘기고 여기서
 * 결정한다 — 그래서 test/projectMembership·projectCreateThrottle·automationAuth·projectGuard·noteImages·notePreview
 * 테스트가 DB 없이 이 규칙을 그대로 확인한다.
 */

const MIN = 60 * 1000;

// ── 프로젝트 라우터 입구 ────────────────────────────────────────────────
// 프로젝트는 정회원 이상만 쓴다(준회원은 목록·조회·수정 모두 불가, 서버 운영자는 예외). projects.js가 아래 주소 전부에 입구 검사를
// 걸고, 프로젝트를 여는 라우트는 requireProjectMember에서 같은 검사를 한 번 더 한다. 예전에는 입구 목록을 손으로 적다가 체크리스트
// 항목(/checklist-items)이 빠져서, 준회원으로 내려간 사람이 남은 구성원 행과 예전에 본 항목 id로 체크리스트를 고치고 지울 수
// 있었다(체크리스트 완료 자동화까지 돌았다). 라우트를 새로 만들면 그 첫 마디를 여기 넣어야 한다 — test/projectGuardRoutes.test.js가
// projects.js의 라우트를 모두 읽어 빠진 것이 없는지 본다.

export const PROJECT_ROUTE_PREFIXES = [
  '/projects',
  '/project-templates',
  '/project-folders',
  '/project-notifications',
  '/tasks',
  '/task-types',
  '/task-statuses',
  '/task-priorities',
  '/task-fields',
  '/task-templates',
  '/task-comments',
  '/checklist-items',
  '/automations',
  '/notes',
  '/note-comments',
  '/note-versions',
];

export const PROJECT_GUEST_DENIAL = '프로젝트는 정회원 이상만 이용할 수 있습니다.';

/**
 * 이 계정이 프로젝트 기능을 아예 쓸 수 없는 이유(쓸 수 있으면 null) — 준회원은 막고 서버 운영자는 등급과 무관하게 들인다. 정지·
 * 탈퇴는 여기서 보지 않는다(로그인 단계에서 막히고, 구성원 확인 isProjectMember가 그런 계정의 행을 없는 것으로 본다).
 */
export function projectUseDenial(user) {
  return accountRole(user) === 'guest' && !user?.isServerAdmin ? PROJECT_GUEST_DENIAL : null;
}

// ── 프로젝트 구성원 자격 ────────────────────────────────────────────────

/**
 * 프로젝트 구성원으로 인정되는 계정인지 — 탈퇴·정지되지 않았고, 계정 등급이 정회원 이상이거나 서버 운영자다(projects.js
 * 라우터 입구의 "프로젝트는 정회원 이상만, 서버 운영자는 예외"와 같은 규칙). project_members 행이 남아 있어도 이 자격을
 * 잃으면 구성원이 아니다 — 정지·탈퇴·준회원 강등은 프로젝트 행을 건드리지 않으므로, 행만 보면 그 사람의 기기로 업무 제목·
 * 댓글 미리보기·마감 알림이 계속 가고 담당자·참조자로도 계속 고를 수 있었다. 같은 규칙의 SQL은 db/queries/projects.js의
 * projectAccountEligibleSql이다(둘이 어긋나지 않게 test/projectMembership.test.js가 함께 본다).
 */
export function isEligibleProjectAccount(user) {
  if (!user || user.deletedAt || user.suspendedAt) return false;
  return accountRole(user) !== 'guest' || !!user.isServerAdmin;
}

/**
 * 이 사람을 남이 프로젝트에 넣을 수 없는 이유(넣을 수 있으면 null) — 프로젝트를 만들며 고른 구성원(POST /projects의
 * memberIds)과 구성원 초대(POST /projects/:id/members)가 같은 규칙을 쓴다. 준회원은 서버 운영자여도 남이 넣지 못한다(예전
 * 초대 규칙 그대로 — 운영자는 공개 프로젝트에 스스로 참여하거나 직접 만든다). 탈퇴·정지한 계정은 넣어도 구성원으로 치지 않으니
 * 조용히 넣지 않고 알려 준다.
 */
export function projectInviteDenial(user) {
  if (!user || user.deletedAt || user.suspendedAt) return '탈퇴했거나 정지된 사용자는 프로젝트에 추가할 수 없습니다.';
  if (accountRole(user) === 'guest') return '프로젝트는 정회원 이상만 참여할 수 있습니다.';
  return null;
}

// ── 업무 제목·설명 길이 ─────────────────────────────────────────────────
// 업무 제목은 알림 제목·본문, 자동화 채팅방 알림에 그대로 실린다 — 만들 때(POST)만 막고 고칠 때(PATCH)는 길이를 안 봐서,
// 제목을 길게 바꿔 다른 사람의 알림·채팅방에 긴 글을 밀어 넣을 수 있었다. 만들기·고치기가 같은 함수를 쓴다.

export const TASK_TITLE_MAX = 200;
// 설명은 업무 상세에서 읽는 글이라 넉넉하게 — 노트 본문(5만 자)보다는 짧고 댓글(2천 자)보다는 길다.
export const TASK_DESCRIPTION_MAX = 10000;

/** 업무 제목 — 앞뒤 공백을 빼고 1~200자. 통과하면 { value }, 아니면 { error }. */
export function parseTaskTitle(raw) {
  const title = typeof raw === 'string' ? raw.trim() : '';
  if (!title) return { error: '업무 제목을 입력하세요.' };
  if (title.length > TASK_TITLE_MAX) return { error: `업무 제목은 ${TASK_TITLE_MAX}자 이내로 입력하세요.` };
  return { value: title };
}

/** 업무 설명 — 앞뒤 공백을 빼고 비었으면 null(글자가 아닌 값도 예전처럼 비운다). 너무 길면 { error }. */
export function parseTaskDescription(raw) {
  const description = typeof raw === 'string' ? raw.trim() : '';
  if (description.length > TASK_DESCRIPTION_MAX) {
    return { error: `업무 설명은 ${TASK_DESCRIPTION_MAX.toLocaleString('ko-KR')}자 이내로 입력하세요.` };
  }
  return { value: description || null };
}

// ── 노트 본문: 그림 주소 ────────────────────────────────────────────────
// 노트 본문은 마크다운 글이고, 그림 줄(`![이름](주소)`)은 노트를 연 사람의 앱이 그 주소를 직접 내려받아 그린다. 주소가 이 서버의
// 파일이 아니면 노트를 연 모든 사람의 기기가 바깥 서버(누가 언제 읽었는지와 IP가 샌다)나 사내의 다른 기기로 요청을 보낸다. 그래서
// 저장할 때와 내려줄 때 모두 그런 그림을 그냥 링크(`[이름](주소)`)로 바꾼다 — 거절하는 것보다 덜 불편하고(눌러서 열 수는 있다),
// 예전에 저장된 노트를 예전 앱이 열어도 바깥 그림을 받지 않는다. 앱(note_markdown.dart noteImageIsLocal)도 같은 규칙으로 이 서버
// 파일만 그림으로 그린다.

/**
 * 노트 그림으로 그려도 되는 주소 — 이 서버의 파일 경로 한 마디뿐이다: 저장 경로(/uploads/<이름>)와 서명 링크(/files/<토큰>).
 * 앱은 이 경로 앞에 서버 주소를 붙여 받으므로 꼭 '/'로 시작하는 이 모양이어야 한다 — ".x.com/a.png"·"@x.com/a.png"처럼 붙이면 다른
 * 서버 주소가 되는 글, "//x.com/a.png"(웹 앱에서는 다른 서버) 같은 것은 모두 바깥 주소로 본다.
 */
export function isNoteImageTarget(url) {
  return typeof url === 'string' && /^\/(?:uploads|files)\/[^/\\]+$/.test(url);
}

// 그림 문법 — 앱의 그림 줄 모양(note_markdown.dart _imageLine: `![이름](주소)`)과 같은 이름·주소 규칙으로 본문 어디서든 찾는다(앱보다
// 넓게 잡아야 빠뜨리지 않는다): 한 줄 이상의 '!', '[', 이름(']'·줄바꿈이 아닌 글자 0개 이상), ']', '(', 주소(')'·공백이 아닌 글자 1개
// 이상), ')'. 예전 정규식 /(!+)\[([^\]\n]*)\]\(([^)\s]+)\)/g 이 찾던 것과 똑같은 자리를 찾는다. 이름은 한 줄 안에서만 본다: 앱은 줄마다
// 읽는데, 여러 줄에 걸쳐 잡으면 바꾼 결과 안에 다음 줄의 그림이 그대로 남는다. 바로 앞의 '!'들도 함께 잡는다(아래 바꾸기에서 '!'를 하나
// 뗐을 때 앞의 '!'가 '['에 붙어 그림이 되살아나지 않게).
//
// 정규식이 아니라 직접 한 번 훑는 까닭: 노트를 저장할 때와 열 때마다 돌고, 서버는 한 줄기로 돌아서 이게 도는 동안 다른 요청이 모두
// 멈춘다. 그 정규식은 '!['만 늘어놓거나 닫히지 않은 주소(`![a](x`)를 이은 5만 자 본문에서 시작점마다 줄·주소 끝까지 다시 읽어 한 번에
// 1초 가까이 걸렸다. 이름 칸은 ']'·줄바꿈에서, 주소 칸은 ')'·공백에서 끝나므로 자리마다 "다음 ']'·줄바꿈"과 "다음 ')'·공백"을 뒤에서부터
// 한 번 채워 두면 시작점마다 바로 판단할 수 있다(이름 칸에는 공백이 들 수 있어서, 끝나지 않은 주소 칸을 통째로 건너뛰는 식의 정규식
// 지름길은 그 안에서 시작해 공백 너머로 이어지는 그림을 놓친다). test/noteImageRewriteLinear.test.js가 예전 정규식과 결과를 맞춰 보고
// 시간을 잰다.
const isUrlStop = (c) => c === ')' || /\s/.test(c); // 정규식 [^)\s]의 반대 — 주소 칸이 끝나는 글자(UTF-16 한 칸씩, 정규식과 같다).

/**
 * [body]에서 이 서버 파일이 아닌 그림을 링크로 바꾼 본문. 앱은 '\r'을 모두 지운 뒤 읽으므로 먼저 지운다(주소 끝에 '\r'을 붙여 이
 * 검사만 비켜 가지 못하게). 한 번만 훑는다 — 바꾼 자리는 '!' 바로 뒤에 '['가 오지 않아서, 바꾼 결과가 새 그림을 만들지 않는다.
 */
export function noteBodyWithoutExternalImages(body) {
  if (typeof body !== 'string') return body;
  const text = body.includes('\r') ? body.replace(/\r/g, '') : body;
  if (!text.includes('![')) return text;
  const n = text.length;
  // nameEnd[i]: i부터 처음 나오는 ']'나 줄바꿈의 자리, urlEnd[i]: i부터 처음 나오는 ')'나 공백의 자리(없으면 n).
  const nameEnd = new Int32Array(n + 1);
  const urlEnd = new Int32Array(n + 1);
  nameEnd[n] = n;
  urlEnd[n] = n;
  for (let i = n - 1; i >= 0; i--) {
    const c = text[i];
    nameEnd[i] = c === ']' || c === '\n' ? i : nameEnd[i + 1];
    urlEnd[i] = isUrlStop(c) ? i : urlEnd[i + 1];
  }
  let out = '';
  let copied = 0;
  let i = 0;
  while (i < n) {
    if (text[i] !== '!') {
      i++;
      continue;
    }
    // '!' 줄의 끝 — 줄 가운데서 시작해도 뒤의 이름·주소가 같아 결과가 같으므로(정규식도 첫 '!'에서 잡거나 모두 실패) 첫 '!'만 본다.
    let j = i;
    while (j < n && text[j] === '!') j++;
    if (j < n && text[j] === '[') {
      const close = nameEnd[j + 1];
      if (close + 1 < n && text[close] === ']' && text[close + 1] === '(') {
        const urlStart = close + 2;
        const urlStop = urlEnd[urlStart];
        if (urlStop > urlStart && urlStop < n && text[urlStop] === ')') {
          const url = text.slice(urlStart, urlStop);
          if (!isNoteImageTarget(url)) {
            const bangs = text.slice(i, j);
            const name = text.slice(j + 1, close);
            // '!'를 하나 떼면 링크다. 앞에 '!'가 더 있었으면 띄어 써서 그 '!'가 '['에 붙지 않게 한다.
            const before = bangs.length > 1 ? `${bangs.slice(1)} ` : '';
            // 이름이 비면 앱이 링크로 읽지 못하므로(빈 링크 글) 그림 줄의 기본 이름을 쓴다.
            out += text.slice(copied, i) + `${before}[${name.trim() ? name : '그림'}](${url})`;
            copied = urlStop + 1;
          }
          i = urlStop + 1;
          continue;
        }
      }
    }
    i = j;
  }
  return copied === 0 ? text : out + text.slice(copied);
}

// ── 노트 목록 미리보기 ──────────────────────────────────────────────────
// 목록의 한 줄 미리보기를 본문 앞부분 그대로 잘라 주면, 첫머리의 그림·파일 링크 주소(`](/uploads/<이름>)`)가 서명 없이 나가서 열람
// 링크를 감추는 설계(내려줄 때마다 서명하는 /files/<토큰>)가 목록에서 무너진다 — 그 저장 이름은 이 서버에서 계속 쓸 수 있는 파일
// 이름이다. 그래서 링크·그림의 주소 칸을 모두 '#'로 바꾼 뒤에 자른다(주소 칸이 남아 있어야 앱의 미리보기가 그림 줄은 "🖼 이름",
// 링크는 글자만 보여 준다). 자르기 전에 바꿔야 끝에서 잘린 주소가 남지 않는다.

export const NOTE_PREVIEW_MAX = 140;
// 목록 질의가 본문에서 읽어 오는 앞부분 — 그림 주소(하나에 50자 남짓)를 걷어 내고도 미리보기를 채울 만큼. 본문(최대 5만 자)을
// 다 읽지 않아 노트가 많은 팀 목록도 가볍다.
export const NOTE_PREVIEW_SOURCE_MAX = 1000;

/**
 * 본문 앞부분([source] — 본문 그대로이거나 NOTE_PREVIEW_SOURCE_MAX에서 잘린 것)으로 만든 미리보기(최대 NOTE_PREVIEW_MAX자). 주소 칸은
 * 앱이 링크·그림으로 읽는 모양(공백 없는 주소 — 서버가 서명하는 것도 이 모양뿐이다)을 모두 지우고, 읽어 온 앞부분이 주소 중간에서
 * 끝났으면 그 조각도 지운다.
 */
export function notePreview(source) {
  if (typeof source !== 'string' || source === '') return '';
  const text = source
    .replace(/\r/g, '')
    .replace(/\]\([^)\s]*\)/g, '](#)')
    .replace(/\]\([^)\s]*$/, ']');
  // 글자 단위로 자른다(DB의 left()처럼) — 이모지 반쪽이 남지 않게.
  const chars = Array.from(text);
  return chars.length > NOTE_PREVIEW_MAX ? chars.slice(0, NOTE_PREVIEW_MAX).join('') : text;
}

// ── 프로젝트 만들기 횟수 ────────────────────────────────────────────────

// 사람마다 10분에 15개까지 — 이름·식별자를 채워야 해서 사람이 이보다 빨리 만들기는 어렵고, 처음 설정하며 여러 개를 연달아
// 만들어도 걸리지 않을 만큼 넉넉하다. 공개 프로젝트는 만들 때마다 팀원 전체의 구성원 행과 기본 상태·유형·우선순위가 생기므로
// 만들고 지우기를 끝없이 되풀이하지 못하게 한다(검사를 통과해 실제로 만드는 요청만 센다 — projects.js allowProjectCreate).
export const PROJECT_CREATE_MAX = 15;
export const PROJECT_CREATE_WINDOW_MS = 10 * MIN;

export function createProjectCreateLimiter({ now } = {}) {
  return new RateLimiter({ max: PROJECT_CREATE_MAX, windowMs: PROJECT_CREATE_WINDOW_MS, now });
}

// ── 공개 프로젝트 생성 알림 ─────────────────────────────────────────────
// 공개 프로젝트를 만들면 정회원 이상 팀원 모두에게 "OOO님이 공개 프로젝트를 만들었습니다: <이름>" 푸시가 간다. 이 알림은
// 프로젝트 정책으로도(그 종류 칸이 없다), 개인 끄기로도(프로젝트마다 끄는데 새 프로젝트는 아직 끌 수 없다) 막을 수 없어서,
// 만들고 바로 지우기를 되풀이하면 팀 전체에 원하는 글(피싱 문구 등)을 끝없이 보낼 수 있었다. 그래서
//  1) 바로 보내지 않고 몇 분 뒤에 보낸다 — 그때 프로젝트가 아직 있고, 아직 공개이며, 종료되지 않았을 때만, 그 시점의
//     이름으로(만들고 곧 지우거나 비공개로 돌리면 아무에게도 안 간다),
//  2) 만든 사람·팀마다 시간당 몇 번까지만 보낸다(넘친 알림은 건너뛴다 — 프로젝트는 사이드바·공개 프로젝트 둘러보기에
//     그대로 나타나므로 알림 하나를 빼도 잃는 것은 없다). 팀 전체 상한도 따로 둬서 여러 계정으로 나눠도 묶인다.
// 미뤄 둔 알림은 메모리 타이머에만 있다 — 그 몇 분 사이에 서버가 다시 시작되면 그 알림은 보내지 않는다(알림 하나를 놓칠
// 뿐이라 따로 저장하지 않는다).

export const PROJECT_CREATED_NOTIFY_DELAY_MS = 3 * MIN;
export const PROJECT_CREATED_NOTIFY_WINDOW_MS = 60 * MIN;
export const PROJECT_CREATED_NOTIFY_PER_CREATOR = 3;
export const PROJECT_CREATED_NOTIFY_PER_TEAM = 10;
// 미뤄 둘 수 있는 알림 수 — 만들기 횟수 제한(사람마다 10분에 15개)이 있어 닿을 일이 없지만, 메모리가 끝없이 늘지 않게.
const PROJECT_CREATED_PENDING_MAX = 1000;

function unrefTimer(fn, ms) {
  const timer = setTimeout(fn, ms);
  timer.unref?.();
  return timer;
}

/**
 * 공개 프로젝트 생성 알림을 [delayMs] 뒤로 미뤘다가 보낸다. 시각이 되면 [prepare](job)으로 프로젝트를 다시 읽어 아직 보낼
 * 만한지 보고(아니면 null — 보내지 않는다), 시간당 상한(allow)을 통과하면 [send](prepare의 결과)로 보낸다. job은
 * { projectId, teamId, creatorId }. 실패해도 던지지 않는다(타이머에서 돈다). [now]·[setTimer]·[clearTimer]는 테스트용.
 */
export class ProjectCreatedAnnouncer {
  constructor({
    prepare,
    send,
    delayMs = PROJECT_CREATED_NOTIFY_DELAY_MS,
    windowMs = PROJECT_CREATED_NOTIFY_WINDOW_MS,
    perCreator = PROJECT_CREATED_NOTIFY_PER_CREATOR,
    perTeam = PROJECT_CREATED_NOTIFY_PER_TEAM,
    now = () => Date.now(),
    setTimer = unrefTimer,
    clearTimer = clearTimeout,
    log = console,
  }) {
    Object.assign(this, { prepare, send, delayMs, setTimer, clearTimer, log });
    this.creatorLimiter = new RateLimiter({ max: perCreator, windowMs, now });
    this.teamLimiter = new RateLimiter({ max: perTeam, windowMs, now });
    this.pending = new Map(); // projectId → timer
  }

  /** 알림 하나를 미뤄 둔다. 같은 프로젝트를 다시 걸면 앞의 것은 취소된다. 너무 많이 쌓였으면 false(보내지 않는다). */
  schedule(job) {
    this.cancel(job.projectId);
    if (this.pending.size >= PROJECT_CREATED_PENDING_MAX) {
      this.log.warn?.('[projects] 미뤄 둔 공개 프로젝트 생성 알림이 너무 많아 이번 알림은 보내지 않습니다.');
      return false;
    }
    const timer = this.setTimer(() => {
      this.pending.delete(job.projectId);
      void this.fire(job);
    }, this.delayMs);
    this.pending.set(job.projectId, timer);
    return true;
  }

  /** 프로젝트를 지웠을 때 — 어차피 시각이 되면 건너뛰지만 타이머를 바로 치운다. */
  cancel(projectId) {
    const timer = this.pending.get(projectId);
    if (timer === undefined) return;
    this.clearTimer(timer);
    this.pending.delete(projectId);
  }

  /** 미뤄 둔 알림 하나를 지금 처리한다 — 'sent' | 'gone'(지웠거나 비공개·종료) | 'throttled' | 'failed'. */
  async fire(job) {
    try {
      const prepared = await this.prepare(job);
      if (!prepared) return 'gone';
      if (!this.allow(job)) {
        this.log.warn?.(
          `[projects] 공개 프로젝트 생성 알림이 시간당 상한을 넘어 건너뜀 (팀 ${job.teamId}, 만든 사람 ${job.creatorId})`,
        );
        return 'throttled';
      }
      await this.send(prepared);
      return 'sent';
    } catch (e) {
      this.log.error?.('[projects] 공개 프로젝트 생성 알림 실패:', e?.message ?? e);
      return 'failed';
    }
  }

  /**
   * 시간당 상한 — 만든 사람·팀 단위를 먼저 보고, 그걸 넘긴 사람은 팀 전체 몫을 쓰지 않게 한다(한 사람이 넘친 만큼 다른
   * 사람의 정상 알림이 막히지 않도록). 통과하면 두 곳 모두에 한 번으로 센다(팀 상한에 걸린 알림도 그 사람 몫은 하나 쓴다).
   */
  allow({ teamId, creatorId }) {
    if (this.creatorLimiter.hit(`${teamId}:${creatorId}`) > 0) return false;
    return this.teamLimiter.hit(teamId) === 0;
  }

  prune() {
    this.creatorLimiter.prune();
    this.teamLimiter.prune();
  }
}

// ── 자동화 "채팅방 알림" ────────────────────────────────────────────────
// 자동화의 채팅방 알림은 사람이 쓴 것처럼 안 읽음·푸시가 가는 일반 메시지로 올라간다. 규칙 하나에 액션 노드를 여러 개 둘 수
// 있고 구성원 누구의 변경으로도 돌기 때문에, 업무를 빠르게 바꾸기만 해도 한 방에 메시지를 쏟아낼 수 있었다 — 규칙마다,
// 채팅방마다 10분 상한을 둔다(칸반에서 카드를 여럿 옮기는 정도는 넉넉히 들어간다). 넘친 알림은 건너뛰고 실행 기록에 남긴다.

export const AUTOMATION_CHAT_WINDOW_MS = 10 * MIN;
export const AUTOMATION_CHAT_PER_RULE = 20;
export const AUTOMATION_CHAT_PER_ROOM = 30;
export const AUTOMATION_CHAT_THROTTLED = `채팅방 알림이 너무 많아 이번에는 보내지 않았습니다(10분에 규칙마다 ${AUTOMATION_CHAT_PER_RULE}번, 채팅방마다 ${AUTOMATION_CHAT_PER_ROOM}번까지).`;

export class AutomationChatThrottle {
  constructor({
    perRule = AUTOMATION_CHAT_PER_RULE,
    perRoom = AUTOMATION_CHAT_PER_ROOM,
    windowMs = AUTOMATION_CHAT_WINDOW_MS,
    now,
  } = {}) {
    this.rule = new RateLimiter({ max: perRule, windowMs, now });
    this.room = new RateLimiter({ max: perRoom, windowMs, now });
  }

  /**
   * 이번 채팅방 알림을 올려도 되면 0, 아니면 기다려야 하는 ms. 규칙 상한을 먼저 본다 — 상한을 넘긴 규칙이 그 방의 몫을
   * 더 쓰지 않게(같은 방에 알림을 보내는 다른 규칙이 그 때문에 막히지 않도록).
   */
  take(ruleId, roomId) {
    const wait = this.rule.hit(ruleId);
    if (wait > 0) return wait;
    return this.room.hit(roomId);
  }

  prune() {
    this.rule.prune();
    this.room.prune();
  }
}

/**
 * 자동화 채팅방 알림을 규칙을 저장한 사람(savedBy)의 권한으로 올려도 되는지 — 안 되면 이유(한국어), 되면 null. 채팅방에
 * 올라가는 업무 번호·제목·담당자는 그 사람이 그 방에 쓰는 셈이라, 저장할 때 통과했어도 실행할 때마다 다시 본다: 계정이 아직
 * 살아 있는 정회원 이상(서버 운영자 포함 — isEligibleProjectAccount)이고, 아직 이 프로젝트의 구성원이며, 규칙을 저장할 수
 * 있는 사람(프로젝트 담당자 또는 팀 소유자·관리자 — 자동화 규칙 저장 권한)이고, 그 채팅방의 멤버여야 한다. 하나라도 잃었으면
 * 그 사람은 더 이상 이 규칙으로 프로젝트 내용을 내보낼 수 없다 — 부르는 쪽(projectAutomation.js)이 규칙을 끈다(다른
 * 관리자가 다시 저장하면 그 사람의 권한으로 다시 켤 수 있다). 채팅방 쪽 사정(읽기 전용·보관·보드 뷰)은 여기서 보지 않는다
 * — 저장한 사람 탓이 아니라 다시 풀릴 수 있어서 규칙을 끄지 않고 그 실행만 실패로 남긴다.
 */
export function automationSaverDenial({ savedBy, saver, isProjectMember, canManageProject, isRoomMember }) {
  if (!savedBy) return '규칙을 저장한 사람을 알 수 없습니다.';
  if (!isEligibleProjectAccount(saver)) return '규칙을 저장한 사람이 탈퇴·정지됐거나 준회원이 되었습니다.';
  if (!isProjectMember) return '규칙을 저장한 사람이 더 이상 이 프로젝트의 구성원이 아닙니다.';
  if (!canManageProject) return '규칙을 저장한 사람이 더 이상 이 프로젝트를 관리할 수 없습니다.';
  if (!isRoomMember) return '규칙을 저장한 사람이 더 이상 채팅방 멤버가 아닙니다.';
  return null;
}

/**
 * 채팅방에 올라가는 자동화 메시지 — 머리말(규칙 이름·업무 번호·제목), 내용, 그리고 이번 실행을 일으킨 사람. 보낸 사람
 * 이름은 '자동화'라 누구의 변경으로 올라온 글인지 따로 적어 둔다(모르면 '알 수 없음').
 */
export function automationChatText({ ruleName, taskKey, taskTitle, body, actorName }) {
  return `[${ruleName}] ${taskKey} ${taskTitle}\n${body}\n(실행한 사람: ${actorName || '알 수 없음'})`;
}
