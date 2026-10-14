// 할 일(To-Do)의 순수 규칙 — 입력 검사·권한·진척률/알림 계산을 DB 없이 단위 테스트할 수 있게 todos.js에서 떼어 냈다.
import net from 'node:net';
import { fileRefPath, isSignedRef } from './fileRefRules.js';
import { resolveRawUrl } from './upload.js';
import { graphemeLength } from './permissions.js';

export const TODO_TITLE_MAX = 100;
export const TODO_DESCRIPTION_MAX = 2000;
export const TODO_ASSIGNEES_MAX = 30;
export const TODO_ATTACHMENTS_MAX = 30;
export const TODO_REMINDERS_MAX = 5;
export const TODO_LIST_DEFAULT_LIMIT = 30;
export const TODO_LIST_MAX_LIMIT = 100;
/** 목록 검색어(q — 검색 패널의 "할 일" 탭) 길이 상한. */
export const TODO_SEARCH_MAX = 100;
// 기간(from~to)으로 받을 때(달력 보기) — 한 번에 최대 100일(양 끝 포함), 그 대신 limit을 500까지 올려 한 번에 받는다.
export const TODO_RANGE_MAX_DAYS = 100;
export const TODO_RANGE_MAX_LIMIT = 500;
// 서버가 꺼져 있다가 켜졌을 때 하루도 더 지난 알림까지 한꺼번에 울리지 않도록 — 서버가 꺼져 있는 동안 때가 됐고 이보다
// 오래 지나서야 다시 켜졌으면 조용히 넘긴다. 서버가 돌고 있을 때 때가 된 알림은 점검이 밀려 늦어졌어도 보낸다
// (shouldDeliverReminder).
export const TODO_REMINDER_STALE_MS = 24 * 60 * 60 * 1000;
// 아직 보내지 않은 알림(앞으로 울릴 것 + 때가 됐는데 아직 못 보낸 것)의 한 사람 몫 상한 — 할 일을 만든 사람 몫으로 세고, 만든
// 사람 계정이 사라진 할 일은 담당자 몫으로 센다(todoPermissions의 관리 권한과 같은 기준). 한 사람이 알림을 끝없이 쌓아 두고
// 한꺼번에 울려 알림 점검을 밀어내지 못하게 한다(검토 S19). 할 일 200개에 알림을 5개씩 다 걸어야 닿는 수라 보통 쓰임에는
// 걸리지 않는다. 보낸 알림·지운 할 일의 알림은 세지 않는다.
export const TODO_PENDING_REMINDERS_MAX = 1000;
export const TODO_PENDING_REMINDERS_ERROR =
  `아직 울리지 않은 할 일 알림이 너무 많습니다(할 일을 만든 사람마다 최대 ${TODO_PENDING_REMINDERS_MAX}개). ` +
  '필요 없는 알림이나 할 일을 지운 뒤 다시 시도하세요.';
// 사람마다 횟수 제한 — 할 일 만들기, 그리고 알림을 새로 잡는(추가·시각 변경) 수정은 각각 10분에 60번까지. 편집 창으로
// 하나씩 만드는 속도(평균 10초에 하나 미만)로는 닿지 않게 잡았다(calendars.js의 일정 추가 제한과 같은 값). 할 일마다 대화방에
// 카드 메시지와 알림이 나가므로 스크립트로 찍어내는 것도 이것으로 늦춘다.
export const TODO_CREATE_RATE = Object.freeze({ max: 60, windowMs: 10 * 60 * 1000 });
export const TODO_REMINDER_EDIT_RATE = Object.freeze({ max: 60, windowMs: 10 * 60 * 1000 });
// 알림 점검 — 한 번에 찜하는 알림 수와, 한 바퀴에 쓰는 시간. 점검은 1분마다 돌고, 그 안에 다 못 보낸 것은 다음 점검이
// 이어서 보낸다(drainDueReminders).
export const TODO_REMINDER_SWEEP_BATCH = 200;
export const TODO_REMINDER_SWEEP_BUDGET_MS = 50 * 1000;
// 고를 수 있는 진척률(잔디: 대기 / 진행 25·50·75% / 완료 100%).
export const TODO_PROGRESS_STEPS = [0, 25, 50, 75, 100];
// 진척률을 쓸 곳이 없는 사람(담당자가 있는 할 일의 담당자 아닌 사람)의 403 문구 — 요청 앞의 검사(patchDenial)와
// 할 일 행을 잠근 뒤의 다시 판단(db/queries/todos.js updateTodo)이 같은 문구를 쓴다.
export const TODO_PROGRESS_DENIED = '담당자만 진척률을 바꿀 수 있습니다.';

// mine = 나의 할 일, assigned_by_me = 부여한 할 일, team = 모든 할 일(앱의 라벨) — 와이어 값은 예전 그대로다.
export const TODO_SCOPES = ['mine', 'assigned_by_me', 'team'];
export const TODO_SORTS = ['due', 'created'];

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/;
const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;
const STORED_UPLOAD_RE = /^\/uploads\/[^/\\]+$/;

export function isUuid(value) {
  return typeof value === 'string' && UUID_RE.test(value);
}

/** 'YYYY-MM-DD'이고 실제로 있는 날짜(2월 30일 같은 건 거절)인지. */
export function isValidDateString(value) {
  if (typeof value !== 'string') return false;
  const m = DATE_RE.exec(value);
  if (!m) return false;
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
  const date = new Date(Date.UTC(y, mo - 1, d));
  return date.getUTCFullYear() === y && date.getUTCMonth() === mo - 1 && date.getUTCDate() === d;
}

/** 진척률 → 상태: 0 = 대기, 1~99 = 진행, 100 = 완료. */
export function statusOf(progress) {
  if (progress >= 100) return 'done';
  if (progress > 0) return 'doing';
  return 'todo';
}

/** 사람이 고를 수 있는 진척률인지 — 0·25·50·75·100만(집계 값은 1~99 아무 값이나 될 수 있지만 직접 고르지는 못한다). */
export function isValidProgress(value) {
  return TODO_PROGRESS_STEPS.includes(value);
}

/** 이 대화방에 할 일을 만들 수 없는 이유 — 비밀 대화(서버가 내용을 볼 수 없음)·보드 뷰 토픽(잔디: 챗 뷰 토픽·채팅에서만). 되면 null. */
export function todoRoomError(room) {
  if (room.isSecret) return '비밀 대화에서는 할 일을 만들 수 없습니다.';
  if (room.type === 'topic' && room.viewMode === 'board') return '보드 뷰 토픽에서는 할 일을 만들 수 없습니다.';
  return null;
}

// ── 입력 검사 ───────────────────────────────────────────────────────────

function parseTitle(raw) {
  const title = typeof raw === 'string' ? raw.trim() : '';
  if (!title) return { error: '할 일 제목을 입력하세요.' };
  if (graphemeLength(title) > TODO_TITLE_MAX) return { error: `제목은 ${TODO_TITLE_MAX}자 이내로 입력하세요.` };
  return { value: title };
}

function parseDescription(raw) {
  if (raw === undefined || raw === null) return { value: null };
  if (typeof raw !== 'string') return { error: '설명이 올바르지 않습니다.' };
  const value = raw.trim() || null;
  if (value && graphemeLength(value) > TODO_DESCRIPTION_MAX) {
    return { error: `설명은 ${TODO_DESCRIPTION_MAX}자 이내로 입력하세요.` };
  }
  return { value };
}

/** 폴더 경로 글자 길이 상한 — Windows 긴 경로(32767)까지는 필요 없고 공유 폴더 경로면 넉넉하다. */
export const TODO_PATH_MAX = 1000;

// ── 폴더 경로의 서버 이름 검사(검토 S32) ────────────────────────────────────
// downloadPath·uploadPath는 담당자의 PC(Windows)가 직접 건드린다 — UNC 경로(\\서버\공유\…)면 SMB로 그 서버에 접속하며
// Windows 로그인 정보(NTLM)를 넘기고, 올리기는 고른 파일을 그 서버로 복사한다. 그래서 아무 서버나 받지 않고, 이 PC의 드라이브
// 경로이거나 "사내망에서만 닿는 서버"일 때만 받는다. 회사가 흔히 쓰는 NAS 공유(\\NAS\공유, \\192.168.0.5\share)는 그대로 되게
// 하면서, 공인 IP·도메인(인터넷 호스트)과 WebDAV(\\host@SSL\…, DavWWWRoot), 장치 경로(\\?\, \\.\)는 거른다. 운영자는
// TODO_FOLDER_HOSTS(쉼표로 나눈 이름 목록) 환경변수로 점 있는 이름(nas.corp.local, AD/DFS 도메인)이나 한글 이름의 사내 서버를
// 따로 허용할 수 있다(todos.js가 process.env에서 읽어 넘긴다). IP 주소는 목록과 상관없이 사내망 대역만 받는다 — 공인 IP로
// SMB를 여는 것은 인터넷으로 로그인 정보를 보내는 것과 같아서다. 앱(client/lib/services/todo_upload.dart folderHostKind)도 같은
// 분류로 폴더를 열기 전에 다시 본다.
const EMPTY_HOST_SET = new Set();
// Windows는 IPv4를 너그럽게 읽는다(inet_addr) — 점 없이 숫자만(134744072 = 8.8.8.8)·0x 16진(0x08080808)·앞자리 0인 8진
// (010.8.8.8 = 8.8.8.8)·줄인 표기(10.8 = 10.0.0.8)도 주소로 본다. 그래서 숫자로 된 칸이 1~4개인 이름은 모두 IP로 보고, 정식
// 점 네 개 표기(net.isIPv4 — 앞자리 0 없음)일 때만 대역을 따진다. 다른 표기로 공인 IP를 사내 이름·사설 IP처럼 꾸미지 못하게.
const NUMERIC_HOST_RE = /^(?:0x[0-9a-f]*|\d+)(?:\.(?:0x[0-9a-f]*|\d+)){0,3}$/;
// 점 없는 사내 컴퓨터 이름(NetBIOS·짧은 DNS 이름)으로 그냥 받는 글자 — ASCII 영문·숫자·-·_만. 다른 글자가 섞인 이름은 목록으로만
// 받는다: 전각·한자 마침표(．。｡)는 Windows가 이름을 풀 때(IDN 변환) '.'로 바뀌어, 점 없어 보이는 이름이 인터넷 도메인
// (evil。com → evil.com)이 될 수 있다. 원래 글자에 대고 본다('K'(켈빈 기호)처럼 소문자로 바꾸면 ASCII가 되는 글자를 거르게).
const NETBIOS_NAME_RE = /^[a-z0-9_-]{1,63}$/i;
const IPV6_LITERAL_SUFFIX = '.ipv6-literal.net';

/** 서버 이름 비교용 — 유니코드 정규형(NFC)·소문자. 경로와 TODO_FOLDER_HOSTS를 같은 모양으로 맞춘다. */
function normalizeFolderHost(host) {
  return host.normalize('NFC').toLowerCase();
}

/** TODO_FOLDER_HOSTS(쉼표로 나눈 문자열)를 비교용 이름 Set으로 — 빈 값은 빈 Set. */
export function parseFolderHostList(raw) {
  if (typeof raw !== 'string' || !raw.trim()) return new Set();
  return new Set(raw.split(',').map((s) => normalizeFolderHost(s.trim())).filter(Boolean));
}

/** 정식 표기(net.isIPv4로 확인한) IPv4가 사내망 대역인지 — 사설(RFC1918)·링크 로컬·루프백. */
function isLanIpv4(host) {
  const [a, b] = host.split('.').map(Number);
  return (
    a === 10 ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168) ||
    (a === 169 && b === 254) ||
    a === 127
  );
}

/** IPv6 표기의 서버 이름 → 주소 글자 — 대괄호([fe80::1])와 Windows의 ipv6-literal.net 표기(콜론→-, 영역 %N→sN)를 푼다. */
function ipv6OfHost(host) {
  if (host.startsWith('[') && host.endsWith(']')) return host.slice(1, -1);
  if (host.endsWith(IPV6_LITERAL_SUFFIX)) {
    return host.slice(0, -IPV6_LITERAL_SUFFIX.length).replace(/s[0-9a-z]+$/, '').replaceAll('-', ':');
  }
  return host;
}

/** IPv6 주소(net.isIPv6로 이미 확인한 것, 영역 표시 없음) → 16비트 칸 8개. 끝이 IPv4 점 표기(::ffff:1.2.3.4)여도 읽는다. */
function ipv6Groups(ip) {
  let s = ip;
  const dotted = /^(.*:)(\d{1,3}(?:\.\d{1,3}){3})$/.exec(s);
  if (dotted) {
    const [a, b, c, d] = dotted[2].split('.').map(Number);
    s = `${dotted[1]}${((a << 8) | b).toString(16)}:${((c << 8) | d).toString(16)}`;
  }
  const halves = s.split('::');
  if (halves.length > 2) return null;
  const head = halves[0] ? halves[0].split(':') : [];
  const tail = halves.length === 2 && halves[1] ? halves[1].split(':') : [];
  const fill = halves.length === 2 ? 8 - head.length - tail.length : 0;
  if (fill < 0) return null;
  const groups = [...head, ...Array(fill).fill('0'), ...tail].map((g) => parseInt(g, 16));
  return groups.length === 8 && groups.every((g) => Number.isInteger(g) && g >= 0 && g <= 0xffff) ? groups : null;
}

/**
 * 사내망 IPv6인지 — 고유 로컬(fc00::/7)·링크 로컬(fe80::/10)·루프백(::1)만. 형식이 틀리면 false. 첫 칸을 숫자로 보고 따진다
 * (글자 앞머리로 보면 fd::1 = 00fd::1 같은 줄인 표기를 고유 로컬로 잘못 본다). 영역 표시(%4)는 떼고 본다.
 */
function isLanIpv6(addr) {
  const plain = addr.replace(/%.*$/, '');
  if (!net.isIPv6(plain)) return false;
  const g = ipv6Groups(plain);
  if (!g) return false;
  if (g.slice(0, 7).every((x) => x === 0) && g[7] === 1) return true; // ::1
  return (g[0] & 0xfe00) === 0xfc00 || (g[0] & 0xffc0) === 0xfe80;
}

/**
 * UNC 서버 이름의 종류 — 앱(todo_upload.dart folderHostKind)과 같은 분류.
 * - 'lan': 정식 표기의 사설·링크 로컬·루프백 IP(v4·v6), 또는 ASCII 단일 라벨(NetBIOS 이름) — 그대로 받는다.
 * - 'named': 그 밖의 이름(점 있는 도메인·한글 이름 등) — 운영자 목록(TODO_FOLDER_HOSTS)에 있을 때만 받는다.
 * - 'blocked': 공인 IP, 숫자로 꾸민 IP(134744072·0x08080808·010.8.8.8·10.8), WebDAV 표기(host@SSL), 빈 이름 — 목록과 상관없이 거절.
 */
export function folderHostKind(rawHost) {
  const raw = typeof rawHost === 'string' ? rawHost : '';
  const host = raw.toLowerCase();
  if (!host || host.includes('@')) return 'blocked'; // \\host@SSL\…, \\host@port\… (WebDAV)
  if (host.startsWith('[') || host.includes(':') || host.endsWith(IPV6_LITERAL_SUFFIX)) {
    return isLanIpv6(ipv6OfHost(host)) ? 'lan' : 'blocked';
  }
  if (NUMERIC_HOST_RE.test(host)) return net.isIPv4(host) && isLanIpv4(host) ? 'lan' : 'blocked';
  return NETBIOS_NAME_RE.test(raw) ? 'lan' : 'named';
}

/** UNC 서버 이름을 받아도 되는지 — 'lan'이면 늘, 'named'면 [extraHosts](TODO_FOLDER_HOSTS)에 있을 때만, 'blocked'는 늘 거절. */
export function isAllowedFolderHost(rawHost, extraHosts = EMPTY_HOST_SET) {
  const kind = folderHostKind(rawHost);
  if (kind === 'lan') return true;
  return kind === 'named' && extraHosts.has(normalizeFolderHost(rawHost));
}

/** UNC 경로(\\서버\… 또는 //서버/…)면 서버 이름 — 로컬 드라이브·장치 경로(\\?\, \\.\)·서버 이름 없음은 null. */
export function folderPathHost(value) {
  if (typeof value !== 'string') return null;
  const v = value.trim();
  if (!/^[\\/]{2}/.test(v)) return null;
  const after = v.slice(2);
  if (/^[?.][\\/]/.test(after)) return null;
  return after.split(/[\\/]/)[0] || null;
}

function folderFormError(label) {
  return `${label} 경로는 이 PC 드라이브(C:\\…)나 사내망 공유 폴더(\\\\서버\\…)만 지정할 수 있습니다.`;
}

/** 폴더 경로 값이 허용되는 형식·서버인지 — 되면 null, 아니면 사용자에게 보일 까닭. */
function folderPathError(value, label, extraHosts) {
  if (/^https?:\/\//i.test(value)) return folderFormError(label); // http(s) URL(WebDAV)
  if (/^[\\/]{2}/.test(value)) {
    const after = value.slice(2);
    if (/^[?.][\\/]/.test(after)) return folderFormError(label); // 장치 경로 \\?\  \\.\
    const segments = after.split(/[\\/]/);
    const host = segments[0] ?? '';
    if (!host) return folderFormError(label);
    if (segments.some((s) => s.toLowerCase() === 'davwwwroot')) return folderFormError(label); // WebDAV 매핑
    if (isAllowedFolderHost(host, extraHosts)) return null;
    // 점 있는 이름·한글 이름은 회사 서버일 수도 있다 — 사용자가 직접 고칠 길(사내 이름·사설 IP, 관리자에게 허용 요청)을 알린다.
    if (folderHostKind(host) === 'named') {
      return (
        `${label} 경로의 서버 '${host}'은(는) 허용된 사내 서버가 아닙니다. 사내 컴퓨터 이름(영문·숫자)이나 사설 IP` +
        '(예: \\\\192.168.0.5\\공유)로 지정하거나, 회사 서버라면 서버 관리자에게 허용을 요청하세요.'
      );
    }
    return `${label} 경로의 서버 '${host}'은(는) 사내망 주소가 아닙니다. 이 PC 드라이브나 사내망 공유 폴더만 지정할 수 있습니다.`;
  }
  if (/^[A-Za-z]:[\\/]/.test(value)) return null; // 로컬 드라이브 경로
  return folderFormError(label);
}

/**
 * 폴더 경로(downloadPath·uploadPath) — 빈 값·null은 "지정 안 함"(null). 한 줄 글자만(줄바꿈·제어 문자 거절), 길이 상한.
 * 서버는 그 폴더가 있는지 모르지만(사용자 PC나 공유 폴더의 경로라) 서버 이름은 본다 — 이 PC 드라이브이거나 사내망에서만 닿는
 * 공유 서버(isAllowedFolderHost)일 때만 받는다(검토 S32). [extraHosts]는 운영자가 허용한 사내 서버 이름(TODO_FOLDER_HOSTS).
 */
export function parseFolderPath(raw, label, extraHosts = EMPTY_HOST_SET) {
  if (raw === undefined || raw === null) return { value: null };
  if (typeof raw !== 'string') return { error: `${label} 경로가 올바르지 않습니다.` };
  const value = raw.trim();
  if (!value) return { value: null };
  if (/[\u0000-\u001f]/.test(value)) return { error: `${label} 경로가 올바르지 않습니다.` };
  if (value.length > TODO_PATH_MAX) return { error: `${label} 경로가 너무 깁니다.` };
  const hostError = folderPathError(value, label, extraHosts);
  if (hostError) return { error: hostError };
  return { value };
}

/**
 * 저장된 폴더 경로를 앱에 보낼 값으로 — 지금 규칙(parseFolderPath)에 맞으면 그대로, 맞지 않으면 null. 이 규칙 전에 저장된
 * 경로(공인 서버·WebDAV·장치 경로 — 담당자가 바꿔 둔 것 포함)를, 이 검사가 없는 옛 앱이 받아서 열거나 파일을 복사하지 않게
 * 한다(검토 S32). DB 값은 그대로 두므로 운영자가 TODO_FOLDER_HOSTS에 그 서버 이름을 적으면 다시 보인다. 편집 창은 바뀐 경로만
 * 보내므로(null인 채로 두면 보내지 않는다) 저장된 값을 덮어쓰지도 않는다.
 */
export function storedFolderPath(value, extraHosts = EMPTY_HOST_SET) {
  if (typeof value !== 'string') return null;
  const r = parseFolderPath(value, '', extraHosts);
  return r.error ? null : r.value;
}

function parseDate(raw, label) {
  if (raw === undefined || raw === null || raw === '') return { value: null };
  if (!isValidDateString(raw)) return { error: `${label}이 올바르지 않습니다. (YYYY-MM-DD)` };
  return { value: raw };
}

/** 시작일≤기한 검사 — 문자열 비교가 곧 날짜 비교다. */
export function checkDateOrder(startDate, dueDate) {
  if (startDate && dueDate && startDate > dueDate) return '시작일은 종료일보다 늦을 수 없습니다.';
  return null;
}

/** 'HH:mm'(24시간, 00:00~23:59)인지 — 날짜 칸과 같은 "그 지역의 벽시계" 시각이다. */
export function isValidTimeString(value) {
  return typeof value === 'string' && TIME_RE.test(value);
}

function parseTime(raw, label) {
  if (raw === undefined || raw === null || raw === '') return { value: null };
  if (!isValidTimeString(raw)) return { error: `${label}이 올바르지 않습니다. (HH:mm)` };
  return { value: raw };
}

/**
 * 기간(시작일·시작 시간 ~ 종료일·종료 시간) 검사 — 시간은 그 날짜가 있어야 하고, 두 날짜가 다 있으면 (날짜, 시간) 순으로
 * 시작이 종료보다 늦으면 안 된다. 시간이 없는 쪽은 날짜만 비교하도록 시작은 00:00, 종료는 23:59로 본다(같은 날 시작
 * 15:00 ~ 종료 시간 없음은 통과). 'YYYY-MM-DDTHH:mm' 문자열 비교가 곧 시각 비교다. 문제가 없으면 null.
 */
export function checkPeriod({ startDate = null, startTime = null, dueDate = null, dueTime = null }) {
  if (startTime && !startDate) return '시작 시간은 시작일과 함께 정해야 합니다.';
  if (dueTime && !dueDate) return '종료 시간은 종료일과 함께 정해야 합니다.';
  if (startDate && dueDate && `${startDate}T${startTime ?? '00:00'}` > `${dueDate}T${dueTime ?? '23:59'}`) {
    return startDate > dueDate ? '시작일은 종료일보다 늦을 수 없습니다.' : '시작 시간은 종료 시간보다 늦을 수 없습니다.';
  }
  return null;
}

/**
 * PATCH의 기간 필드(startDate·startTime·dueDate·dueTime 중 보낸 것)를 저장된 값([stored])과 합친 결과 — 안 보낸 쪽은
 * 저장된 값 그대로지만, 날짜를 지우면(null) 그 시간도 함께 지운다. 통과하면 `{ value: 합친 기간, columns: 쓸 컬럼 }`
 * (columns는 보낸 필드 + 날짜를 지워 함께 지우는 시간), 아니면 `{ error }`(checkPeriod — 시간만 있고 날짜가 없음·순서).
 */
export function mergeTodoPeriod(stored, fields) {
  const value = {};
  const columns = {};
  for (const [dateKey, timeKey] of [
    ['startDate', 'startTime'],
    ['dueDate', 'dueTime'],
  ]) {
    value[dateKey] = dateKey in fields ? fields[dateKey] : (stored?.[dateKey] ?? null);
    if (dateKey in fields) columns[dateKey] = fields[dateKey];
    if (timeKey in fields) {
      value[timeKey] = fields[timeKey];
      columns[timeKey] = fields[timeKey];
    } else if (dateKey in fields && fields[dateKey] === null) {
      value[timeKey] = null;
      columns[timeKey] = null;
    } else {
      value[timeKey] = stored?.[timeKey] ?? null;
    }
  }
  const error = checkPeriod(value);
  if (error) return { error };
  return { value, columns };
}

function parseAssigneeIds(raw) {
  if (!Array.isArray(raw)) return { error: '담당자 목록이 올바르지 않습니다.' };
  if (raw.some((id) => !isUuid(id))) return { error: '담당자 목록이 올바르지 않습니다.' };
  const ids = [...new Set(raw.map((id) => id.toLowerCase()))];
  if (ids.length > TODO_ASSIGNEES_MAX) return { error: `담당자는 ${TODO_ASSIGNEES_MAX}명까지 지정할 수 있습니다.` };
  return { value: ids };
}

/**
 * 첨부 링크를 받을 수 없을 때의 문구 — 알아볼 수 없는 링크(위조·외부 주소·모르는 만료 링크, parseAttachments)와 이 사람이 쓸 수 없는
 * 파일(todos.js가 fileRefs.js checkFileRefs로 본다)을 가리지 않는다(어떤 파일이 있는지 알려 주지 않게).
 */
export const TODO_ATTACHMENT_LINK_ERROR = '사용할 수 없는 첨부 링크가 있습니다. 파일을 다시 올려 주세요.';

/**
 * 첨부 목록 검사 — 업로드 결과 모양 [{kind, fileUrl, fileName, fileSize, mimeType, thumbnailUrl}]. 서명된
 * /files/<token>은 원본 경로(/uploads/...)로 되돌려 저장한다. [existingUrls]는 이미 알고 있는 저장 경로들 — 수정 때는
 * 이 할 일에 저장된 첨부의 원본·축소 미리보기(storedAttachmentPaths), 만들 때는 출처 글(메시지·댓글)에 붙어 있는
 * 파일(sourceFilePaths). 화면이 오래 들고 있어 서명이 만료된 링크를 그대로 보내도 이 경로들의 파일이면 인정한다(서명은
 * 맞아야 한다 — fileRefPath). 원본(fileUrl)이 그 밖의 알아볼 수 없는 링크(만료·위조·외부 주소)면 조용히 빼지 않고
 * 거절하고, 미리보기(thumbnailUrl)만 알아볼 수 없으면 미리보기 없이(null) 받는다.
 *
 * 여기서는 링크의 모양만 본다. 그 파일을 이 사람이 써도 되는지(직접 올렸나·이 할 일이나 출처 글에 원래 있던 파일인가·서명 링크로 온
 * 지금 볼 수 있는 방의 파일인가)는 DB가 필요해서, todos.js가 저장 전에 fileRefs.js checkFileRefs로 본다 — 예전엔 알아낸 파일 이름
 * (/uploads/<이름>)이나 남에게 받은 링크도 그대로 저장해서, 그 할 일을 볼 수 있는 사람 모두가 그 파일을 영영 받을 수 있었다(검토
 * S22). 그 검사에 넘길, 받은 링크들을 보낸 그대로 `refs`로 함께 돌려준다(저장 경로는 늘 그 링크의 fileRefPath — checkFileRefs가
 * 통과시키는 경로와 같다). 결과는 `{ value: 첨부들, refs }` 또는 `{ error }`.
 */
export function parseAttachments(raw, existingUrls = []) {
  if (!Array.isArray(raw)) return { error: '첨부 목록이 올바르지 않습니다.' };
  if (raw.length > TODO_ATTACHMENTS_MAX) return { error: `첨부 파일은 ${TODO_ATTACHMENTS_MAX}개까지 올릴 수 있습니다.` };
  const known = new Set(existingUrls);
  const refs = [];
  const toStored = (url) => {
    if (typeof url !== 'string' || !url) return null;
    const path = fileRefPath(url);
    if (!path) return null;
    // 서명이 만료된 링크(resolveRawUrl은 살아 있는 링크만 푼다)는 알고 있는 경로의 파일일 때만 — 이 할 일·출처 글에 없던 파일을
    // 몇 시간 들고 있던 링크로 붙일 까닭은 없다.
    if (isSignedRef(url) && !resolveRawUrl(url) && !known.has(path)) return null;
    refs.push(url);
    return path;
  };
  const items = [];
  for (const a of raw) {
    if (!a || typeof a !== 'object') return { error: '첨부 목록이 올바르지 않습니다.' };
    const fileUrl = toStored(a.fileUrl);
    if (!fileUrl) return { error: TODO_ATTACHMENT_LINK_ERROR };
    items.push({
      kind: a.kind === 'file' ? 'file' : 'image',
      fileUrl,
      fileName: typeof a.fileName === 'string' ? a.fileName : null,
      fileSize: typeof a.fileSize === 'number' && Number.isFinite(a.fileSize) ? Math.trunc(a.fileSize) : null,
      mimeType: typeof a.mimeType === 'string' ? a.mimeType : null,
      thumbnailUrl: toStored(a.thumbnailUrl),
    });
  }
  return { value: items, refs };
}

/**
 * "메시지·댓글에서 할 일로 등록"의 출처 글에 지금 실제로 붙어 있는 파일 경로들(/uploads/...) — 만들기 요청의 첨부를
 * 알아보는 known 목록(parseAttachments). 댓글([comment])이면 그 댓글의 파일 칸만(앱은 댓글 자신의 파일만 싣는다),
 * 메시지([message])면 첨부 행들([attachments] — message_attachments)과 옛 방식의 파일 칸. 지운 파일(첨부 행의 deletedAt,
 * 메시지의 fileDeletedAt)은 빼고, 원본·축소 미리보기 경로를 함께 담는다(중복 없이).
 */
export function sourceFilePaths({ comment = null, message = null, attachments = [] } = {}) {
  const urls = [];
  if (comment) {
    urls.push(comment.fileUrl, comment.thumbnailUrl);
  } else if (message) {
    for (const a of attachments) {
      if (!a.deletedAt) urls.push(a.fileUrl, a.thumbnailUrl);
    }
    if (!message.fileDeletedAt) urls.push(message.fileUrl, message.thumbnailUrl);
  }
  return uniqueStoredPaths(urls);
}

/**
 * 할 일을 고칠 때 첨부를 알아보는 known 목록(parseAttachments) — 이 할 일에 지금 저장된 첨부 행들([rows] —
 * todo_attachments)의 원본과 축소 미리보기 경로. 앱은 첨부 목록이 바뀔 때마다 기존 첨부를 상세에서 받은 서명 링크
 * 그대로(원본·미리보기 모두) 다시 보내므로, 패널을 오래 열어 둬 둘 다 만료됐어도 미리보기까지 알아봐야 기존 사진의
 * 미리보기가 조용히 빠지지 않는다(검토 S2 — 만들 때의 sourceFilePaths가 미리보기를 함께 담는 것과 같은 이유).
 */
export function storedAttachmentPaths(rows = []) {
  return uniqueStoredPaths(rows.flatMap((a) => [a.fileUrl, a.thumbnailUrl]));
}

/** 저장 경로(/uploads/<이름>)인 값만 중복 없이 — 빈 칸(null)·외부 주소·서명 링크는 뺀다. */
function uniqueStoredPaths(urls) {
  return [...new Set(urls.filter((u) => typeof u === 'string' && STORED_UPLOAD_RE.test(u)))];
}

/** 새 알림 한 건 검사(ms 시각, 지금보다 뒤). */
function parseNewRemindAt(raw, now) {
  if (typeof raw !== 'number' || !Number.isFinite(raw)) return { error: '알림 시각이 올바르지 않습니다.' };
  if (raw <= now) return { error: '알림 시각은 지금보다 뒤여야 합니다.' };
  return { value: Math.trunc(raw) };
}

/** 만들 때의 알림 목록 — [ms, ...](지금보다 뒤, 최대 5개, 같은 시각 중복은 하나로). */
export function parseNewReminders(raw, now = Date.now()) {
  if (!Array.isArray(raw)) return { error: '알림 목록이 올바르지 않습니다.' };
  const times = [];
  for (const item of raw) {
    const r = parseNewRemindAt(typeof item === 'object' && item !== null ? item.remindAt : item, now);
    if (r.error) return r;
    times.push(r.value);
  }
  const unique = [...new Set(times)];
  if (unique.length > TODO_REMINDERS_MAX) return { error: `알림은 ${TODO_REMINDERS_MAX}개까지 추가할 수 있습니다.` };
  return { value: unique };
}

/**
 * POST /rooms/:roomId/todos 본문 검사 — 통과하면 `{ title, description, assigneeIds, startDate, startTime, dueDate,
 * dueTime, attachments, attachmentRefs, reminders(ms[]), sourceMessageId, sourceCommentId }`, 아니면 `{ error }`. 시간('HH:mm')은
 * 그 날짜가 있어야 하고, 시작은 종료보다 늦을 수 없다(checkPeriod).
 * 담당자가 그 방 멤버인지, 출처 글이 그 방의 것인지, 첨부를 이 사람이 써도 되는지(attachmentRefs — parseAttachments의 refs를
 * fileRefs.js checkFileRefs로)는 DB가 필요해서 todos.js가 따로 본다. [sourceFileUrls]는 출처 글에
 * 지금 붙어 있는 파일 경로들(sourceFilePaths) — 오래전에 불러온 메시지를 등록해 첨부 서명이 만료됐어도 그 파일이면 받는다.
 */
export function parseTodoCreate(body, now = Date.now(), sourceFileUrls = [], folderHosts = EMPTY_HOST_SET) {
  const title = parseTitle(body?.title);
  if (title.error) return title;
  const description = parseDescription(body?.description);
  if (description.error) return description;
  const assignees = parseAssigneeIds(body?.assigneeIds ?? []);
  if (assignees.error) return assignees;
  const start = parseDate(body?.startDate, '시작일');
  if (start.error) return start;
  const due = parseDate(body?.dueDate, '종료일');
  if (due.error) return due;
  const startTime = parseTime(body?.startTime, '시작 시간');
  if (startTime.error) return startTime;
  const dueTime = parseTime(body?.dueTime, '종료 시간');
  if (dueTime.error) return dueTime;
  const periodError = checkPeriod({
    startDate: start.value,
    startTime: startTime.value,
    dueDate: due.value,
    dueTime: dueTime.value,
  });
  if (periodError) return { error: periodError };
  const attachments = parseAttachments(body?.attachments ?? [], sourceFileUrls);
  if (attachments.error) return attachments;
  const reminders = parseNewReminders(body?.reminders ?? [], now);
  if (reminders.error) return reminders;
  const downloadPath = parseFolderPath(body?.downloadPath, '파일 다운로드', folderHosts);
  if (downloadPath.error) return downloadPath;
  const uploadPath = parseFolderPath(body?.uploadPath, '파일 업로드', folderHosts);
  if (uploadPath.error) return uploadPath;
  for (const key of ['sourceMessageId', 'sourceCommentId']) {
    if (body?.[key] !== undefined && body?.[key] !== null && !isUuid(body[key])) {
      return { error: '원본 메시지 정보가 올바르지 않습니다.' };
    }
  }
  return {
    title: title.value,
    description: description.value,
    assigneeIds: assignees.value,
    startDate: start.value,
    startTime: startTime.value,
    dueDate: due.value,
    dueTime: dueTime.value,
    attachments: attachments.value,
    attachmentRefs: attachments.refs,
    reminders: reminders.value,
    downloadPath: downloadPath.value,
    uploadPath: uploadPath.value,
    sourceMessageId: body?.sourceMessageId ?? null,
    sourceCommentId: body?.sourceCommentId ?? null,
  };
}

/** PATCH에서 보낼 수 있는 필드 전부, 그리고 그중 담당자가 못 고치는 것. */
export const PATCH_FIELDS = [
  'title',
  'description',
  'assigneeIds',
  'startDate',
  'startTime',
  'dueDate',
  'dueTime',
  'attachments',
  'reminders',
  'progress',
  'downloadPath',
  'uploadPath',
];
// 담당자가 못 고치는 필드 — 담당자 목록(관리 권한)과, 담당자의 PC가 접속할 폴더 경로(downloadPath·uploadPath). 경로는
// 담당자 PC가 그 서버에 SMB로 접속하게 만드는 값이라, 만든 사람(계정이 사라졌으면 관리 권한을 가진 담당자)만 바꾼다(검토 S32).
export const ASSIGNEE_FORBIDDEN_FIELDS = ['assigneeIds', 'downloadPath', 'uploadPath'];

/**
 * PATCH 본문 1차 검사 — 보낸 필드만 `fields`에 담는다(없는 필드는 안 바뀐다). 방을 옮기려는 시도(roomId·teamId)는
 * 거절한다. 통과하면 `{ fields: { title?, description?, assigneeIds?, startDate?, startTime?, dueDate?, dueTime?,
 * attachments?, reminders?, progress? } }`. progress는 보내는 사람의 "내 진척률"(0·25·50·75·100 — 어디에 쓰는지는
 * progressTarget). reminders는 [{id?, remindAt}] 그대로 두고(기존 것과 맞춰 보는 planReminders가 검사), attachments의
 * 기존 링크 인정과 기간(시간만 있고 날짜 없음·시작≤종료 — 안 보낸 쪽은 저장된 값 기준, mergeTodoPeriod)은 todos.js가
 * 현재 값과 합쳐 다시 본다.
 */
export function parseTodoPatch(body, folderHosts = EMPTY_HOST_SET) {
  if (!body || typeof body !== 'object') return { error: '수정할 내용이 없습니다.' };
  if ('roomId' in body || 'teamId' in body) return { error: '할 일은 다른 대화방으로 옮길 수 없습니다.' };
  const fields = {};
  if ('title' in body) {
    const r = parseTitle(body.title);
    if (r.error) return r;
    fields.title = r.value;
  }
  if ('description' in body) {
    const r = parseDescription(body.description);
    if (r.error) return r;
    fields.description = r.value;
  }
  if ('assigneeIds' in body) {
    const r = parseAssigneeIds(body.assigneeIds);
    if (r.error) return r;
    fields.assigneeIds = r.value;
  }
  if ('startDate' in body) {
    const r = parseDate(body.startDate, '시작일');
    if (r.error) return r;
    fields.startDate = r.value;
  }
  if ('dueDate' in body) {
    const r = parseDate(body.dueDate, '종료일');
    if (r.error) return r;
    fields.dueDate = r.value;
  }
  if ('startTime' in body) {
    const r = parseTime(body.startTime, '시작 시간');
    if (r.error) return r;
    fields.startTime = r.value;
  }
  if ('dueTime' in body) {
    const r = parseTime(body.dueTime, '종료 시간');
    if (r.error) return r;
    fields.dueTime = r.value;
  }
  if ('attachments' in body) {
    if (!Array.isArray(body.attachments)) return { error: '첨부 목록이 올바르지 않습니다.' };
    if (body.attachments.length > TODO_ATTACHMENTS_MAX) {
      return { error: `첨부 파일은 ${TODO_ATTACHMENTS_MAX}개까지 올릴 수 있습니다.` };
    }
    fields.attachments = body.attachments;
  }
  if ('reminders' in body) {
    if (!Array.isArray(body.reminders)) return { error: '알림 목록이 올바르지 않습니다.' };
    fields.reminders = body.reminders;
  }
  if ('progress' in body) {
    if (!isValidProgress(body.progress)) return { error: '진척률은 0·25·50·75·100 중 하나여야 합니다.' };
    fields.progress = body.progress;
  }
  for (const [key, label] of [
    ['downloadPath', '파일 다운로드'],
    ['uploadPath', '파일 업로드'],
  ]) {
    if (!(key in body)) continue;
    const r = parseFolderPath(body[key], label, folderHosts);
    if (r.error) return r;
    fields[key] = r.value;
  }
  if (Object.keys(fields).length === 0) return { error: '수정할 내용이 없습니다.' };
  return { fields };
}

// ── 권한 ────────────────────────────────────────────────────────────────

/**
 * 이 사람의 역할 — 'creator' | 'assignee' | 'viewer'. 만든 사람이면서 담당자이기도 하면 creator.
 */
export function todoRole({ creatorId, assigneeIds, userId }) {
  if (creatorId && creatorId === userId) return 'creator';
  if (assigneeIds.includes(userId)) return 'assignee';
  return 'viewer';
}

/**
 * 역할별 권한 — canEdit(제목·설명·파일·기한·알림), canManage(담당자 관리·삭제). 진척률은 역할이 아니라 담당 여부로
 * 따로 본다(progressTarget). 만든 사람 계정이 사라진(탈퇴 → creator_id null) 할 일은 아무도 지울 수 없게 되므로,
 * 그때만 담당자에게도 관리 권한을 준다.
 */
export function todoPermissions({ role, creatorId }) {
  return {
    canEdit: role === 'creator' || role === 'assignee',
    canManage: role === 'creator' || (role === 'assignee' && !creatorId),
  };
}

/**
 * "내 진척률"을 어디에 쓸지 — 내가 (그 방에 있는) 담당자면 'assignee'(내 담당 행), 담당자가 없고 내가 만든 사람이면
 * 'todo'(todos.progress — 개인 할 일, 예전 방식), 그 밖은 null(만든 사람이라도 담당자가 아니면 못 바꾼다 — 잔디 "개별 진행").
 */
export function progressTarget({ creatorId, assigneeIds, userId }) {
  if (assigneeIds.includes(userId)) return 'assignee';
  if (assigneeIds.length === 0 && creatorId && creatorId === userId) return 'todo';
  return null;
}

/** DTO의 myProgress — [assignees]는 그 방에 있는 담당자 [{ userId, progress }]. 바꿀 수 없는 사람이면 null. */
export function myProgressOf({ creatorId, assignees, progress, userId }) {
  const target = progressTarget({ creatorId, assigneeIds: assignees.map((a) => a.userId), userId });
  if (target === 'assignee') return assignees.find((a) => a.userId === userId).progress;
  if (target === 'todo') return progress;
  return null;
}

/**
 * 이 사람이 PATCH 본문의 필드들을 고칠 수 있는지 — 못 고치면 `{ status: 403, error }`, 되면 null. progress만은
 * 역할 대신 [target](progressTarget의 결과)으로 본다 — null이면 만든 사람이라도 403.
 */
export function patchDenial(role, creatorId, fieldNames, target = null) {
  const others = fieldNames.filter((f) => f !== 'progress');
  if (others.length > 0) {
    const { canEdit, canManage } = todoPermissions({ role, creatorId });
    if (!canEdit) return { status: 403, error: '이 할 일을 수정할 권한이 없습니다.' };
    const forbidden = others.filter((f) => ASSIGNEE_FORBIDDEN_FIELDS.includes(f));
    if (!canManage && forbidden.length > 0) {
      // 담당자 목록과 파일 경로는 둘 다 관리 권한이 있어야 바꾼다 — 어느 쪽을 보냈는지에 맞는 문구를 준다(검토 S32).
      return {
        status: 403,
        error: forbidden.includes('assigneeIds')
          ? '담당자는 담당자 목록을 바꿀 수 없습니다.'
          : '담당자는 파일 경로를 바꿀 수 없습니다.',
      };
    }
  }
  if (fieldNames.includes('progress') && !target) {
    return { status: 403, error: TODO_PROGRESS_DENIED };
  }
  return null;
}

// ── 진척률·알림 ─────────────────────────────────────────────────────────

/**
 * 진척률이 바뀔 때의 completedAt — 100이 되면 그때(이미 완료였으면 처음 값 유지), 100 아래로 내리면 해제.
 * 할 일(집계)과 담당자 한 사람의 행에 똑같이 쓴다.
 */
export function nextCompletedAt(progress, prevCompletedAt, now = new Date()) {
  if (progress >= 100) return prevCompletedAt ?? now;
  return null;
}

/**
 * 담당자들의 진척률로 전체(집계) 진척률 — 모두 100이면 100, 모두 0이면 0, 그 밖은 평균을 반올림해 1~99로 자른다
 * (한 명이라도 덜 했으면 완료로, 한 명이라도 시작했으면 대기로 보이지 않게). 담당자가 없으면 null — 그때는 만든
 * 사람이 직접 바꾸는 todos.progress를 그대로 둔다.
 */
export function aggregateProgress(progresses) {
  if (progresses.length === 0) return null;
  if (progresses.every((p) => p >= 100)) return 100;
  if (progresses.every((p) => p <= 0)) return 0;
  const average = Math.round(progresses.reduce((sum, p) => sum + p, 0) / progresses.length);
  return Math.min(99, Math.max(1, average));
}

/** 저장된 [todo]의 progress·completedAt을 [progress]로 맞춘 값 — 완료 시각은 nextCompletedAt 규칙, 이미 맞으면 null. */
function resyncTo(todo, progress, now) {
  const completedAt = nextCompletedAt(progress, todo.completedAt ?? null, now);
  const time = (d) => (d ? new Date(d).getTime() : null);
  if (progress === todo.progress && time(completedAt) === time(todo.completedAt)) return null;
  return { progress, completedAt };
}

/**
 * 저장된 전체 진척률([todo]의 progress·completedAt)을 그 방에 아직 있는 담당자들의 진척률([progresses])로 다시 맞춘 값 —
 * 바꿀 것이 있으면 `{ progress, completedAt }`, 담당자가 없거나(만든 사람이 직접 바꾸는 값이라 그대로 둔다) 이미 맞으면 null.
 * 할 일을 고칠 때마다, 그리고 담당자가 방을 나가거나 다시 들어올 때 쓴다(progressResync) — 그래서 방을 나간 담당자는
 * 곧바로 집계에서 빠지고, 다시 들어오면 남아 있던 그 사람의 진척률이 다시 들어간다.
 */
export function aggregateResync(todo, progresses, now = new Date()) {
  const progress = aggregateProgress(progresses);
  if (progress === null) return null;
  return resyncTo(todo, progress, now);
}

/** 진척률을 가장 가까운 단계(0·25·50·75·100)로 — 두 단계의 한가운데(12.5·37.5·62.5·87.5)는 큰 쪽으로(반은 올림). */
export function nearestProgressStep(value) {
  let nearest = TODO_PROGRESS_STEPS[0];
  for (const step of TODO_PROGRESS_STEPS) {
    // 단계가 오름차순이라 거리가 같으면 뒤의 큰 단계가 남는다.
    if (Math.abs(value - step) <= Math.abs(value - nearest)) nearest = step;
  }
  return nearest;
}

/**
 * (그 방에 있는) 담당자가 하나도 남지 않게 된 할 일이 이어받을 진척률(검토 S3) — 이제부터는 담당자 없는 할 일이라 만든
 * 사람이 직접 고르는 값이 되므로, 바로 전까지 만든 사람도 담당자였으면 만든 사람 자신의 진척률, 아니면 직전 집계를 가장
 * 가까운 단계로 맞춘 값(집계 38%처럼 고를 수 없는 값이 남지 않게). [before]는 바로 전에 그 방에 있던 담당자들
 * [{ userId, progress }](한 명 이상).
 */
export function orphanedProgress({ creatorId, before }) {
  const creator = creatorId ? before.find((a) => a.userId === creatorId) : null;
  if (creator) return creator.progress;
  return nearestProgressStep(aggregateProgress(before.map((a) => a.progress)));
}

/**
 * 할 일을 고치거나 방 멤버가 바뀐 뒤, 저장된 전체 진척률([todo]의 progress·completedAt·creatorId)을 다시 맞춘 값 — 바꿀
 * 것이 있으면 `{ progress, completedAt }`, 이미 맞거나 손댈 것이 없으면 null. [after]는 지금 그 방에 있는 담당자들
 * [{ userId, progress }] — 있으면 그들의 집계(aggregateResync). 없으면 만든 사람이 직접 바꾸는 값이라 그대로 두지만, 이번
 * 변경 바로 전([before] — 그때 그 방에 있던 담당자들, 모르면 null)에는 담당자가 있었다면(마지막 담당자가 빠짐)
 * orphanedProgress의 값을 이어받는다. 완료 시각은 어느 쪽이든 nextCompletedAt 규칙.
 */
export function progressResync(todo, { before = null, after }, now = new Date()) {
  if (after.length > 0) return aggregateResync(todo, after.map((a) => a.progress), now);
  if (!before || before.length === 0) return null;
  return resyncTo(todo, orphanedProgress({ creatorId: todo.creatorId, before }), now);
}

/**
 * 담당자 목록 수정의 차이 — removed(빠진 사람: 행 삭제), added(새 사람: 진척률 0으로 추가), kept(남는 사람: 행을
 * 그대로 둬서 진척률 보존). [beforeIds]는 저장된 담당 행 전부(방을 나간 사람 포함), [afterIds]는 새 목록.
 */
export function diffAssignees(beforeIds, afterIds) {
  const before = new Set(beforeIds);
  const after = new Set(afterIds);
  return {
    removed: [...before].filter((id) => !after.has(id)),
    added: [...after].filter((id) => !before.has(id)),
    kept: [...after].filter((id) => before.has(id)),
  };
}

/**
 * 알림 일정 수정 계획 — [existing]은 저장된 {id, remindAt(ms), sent}, [incoming]은 본문의 [{id?, remindAt}].
 * 기존 id에 같은 시각이면 그대로 두고(보낸 기록 유지), 시각이 바뀌면 시각만 바꿔 보낸 기록을 지우고(다시 울림),
 * id 없는 새 항목은 추가한다. 본문에 없는 기존 항목은 지운다. 새로 잡거나 바꾸는 시각은 지금보다 뒤여야 한다.
 * 통과하면 `{ deleteIds, updates:[{id, remindAt}], inserts:[ms] }`, 아니면 `{ error }`.
 */
export function planReminders(existing, incoming, now = Date.now()) {
  if (!Array.isArray(incoming)) return { error: '알림 목록이 올바르지 않습니다.' };
  if (incoming.length > TODO_REMINDERS_MAX) return { error: `알림은 ${TODO_REMINDERS_MAX}개까지 추가할 수 있습니다.` };
  const byId = new Map(existing.map((e) => [e.id, e]));
  const keptIds = new Set();
  const updates = [];
  const inserts = [];
  const seenTimes = new Set();
  for (const item of incoming) {
    const remindAt = typeof item === 'object' && item !== null ? item.remindAt : item;
    const id = typeof item === 'object' && item !== null ? item.id : null;
    if (typeof remindAt !== 'number' || !Number.isFinite(remindAt)) return { error: '알림 시각이 올바르지 않습니다.' };
    const time = Math.trunc(remindAt);
    if (seenTimes.has(time)) continue; // 같은 시각을 두 번 넣어도 하나로.
    seenTimes.add(time);
    const prev = id ? byId.get(id) : null;
    if (prev && !keptIds.has(prev.id)) {
      keptIds.add(prev.id);
      if (prev.remindAt !== time) {
        if (time <= now) return { error: '알림 시각은 지금보다 뒤여야 합니다.' };
        updates.push({ id: prev.id, remindAt: time });
      }
      continue;
    }
    if (time <= now) return { error: '알림 시각은 지금보다 뒤여야 합니다.' };
    inserts.push(time);
  }
  if (keptIds.size + inserts.length > TODO_REMINDERS_MAX) {
    return { error: `알림은 ${TODO_REMINDERS_MAX}개까지 추가할 수 있습니다.` };
  }
  return { deleteIds: existing.filter((e) => !keptIds.has(e.id)).map((e) => e.id), updates, inserts };
}

/**
 * 이 알림 수정 계획([plan] — planReminders의 결과)이 알림을 새로 잡는지 — 새 알림을 넣거나 시각을 바꾸면(바꾼 알림은 보낸
 * 기록이 지워져 다시 울린다) true, 지우기만 하거나 그대로면 false. 알림 수정 횟수 제한(TODO_REMINDER_EDIT_RATE)과 아직
 * 보내지 않은 알림 상한(TODO_PENDING_REMINDERS_MAX) 검사는 이때만 한다 — 지우는 수정은 상한을 넘은 사람도 늘 할 수 있게.
 */
export function schedulesReminders(plan) {
  return !!plan && (plan.inserts.length > 0 || plan.updates.length > 0);
}

/** 담당자를 바꿨을 때 새로 담당이 된 사람 — 푸시·토스트 대상(바꾼 본인은 뺀다). */
export function newlyAssigned(beforeIds, afterIds, actorId) {
  const before = new Set(beforeIds);
  return afterIds.filter((id) => !before.has(id) && id !== actorId);
}

/**
 * 푸시를 받을 사람 — 후보 중 소켓이 안 붙어 있고([onlineIds] 아님) 그 방을 뮤트하지 않은([mutedIds] 아님) 사람.
 * 온라인인 사람은 소켓 이벤트(todo:changed / todo:reminder)로 앱이 직접 알린다(채팅 푸시와 같은 분리).
 */
export function pushTargets(candidateIds, { actorId = null, onlineIds = new Set(), mutedIds = new Set() } = {}) {
  return [...new Set(candidateIds)].filter((id) => id !== actorId && !onlineIds.has(id) && !mutedIds.has(id));
}

/**
 * 알림이 울릴 사람 — 담당자가 있으면 아직 다 하지 않은(진척률 100 미만) 담당자들, 없으면 만든 사람에게 넘어간다.
 * [assignees]는 그 방에 아직 있는 담당자 [{ userId, progress }]. 할 일 전체가 완료면 shouldDeliverReminder가 먼저 거른다.
 * 만든 사람으로 넘어가는 경우(fallback)는 그 사람이 아직 이 할 일의 방·팀 멤버일 때만 — [creatorIsMember]가 true일 때만
 * 보낸다(검토 S33). 방·팀에서 내보내진(또는 나간) 만든 사람에게는, requireTodo가 이미 403을 주는 할 일의 제목·기한이 담긴
 * 알림이 가지 않게 한다. 멤버 여부는 DB가 필요해 todos.js(sweepTodoReminders)가 담당자가 없을 때만 확인해 넘긴다.
 */
export function reminderTargets(assignees, creatorId, { creatorIsMember = false } = {}) {
  if (assignees.length > 0) return assignees.filter((a) => a.progress < 100).map((a) => a.userId);
  return creatorId && creatorIsMember ? [creatorId] : [];
}

/**
 * 이 알림을 지금 보내도 되는지 — 이미 완료된 할 일의 알림은 보내지 않는다. 그리고 서버가 꺼져 있는 동안(알림 점검이 돌지
 * 못한 동안) 때가 됐는데 하루(TODO_REMINDER_STALE_MS)가 넘게 지나서야 서버가 다시 켜진 알림도, 켜지자마자 지난 알림이
 * 한꺼번에 울리지 않도록 조용히 넘긴다. 서버가 돌고 있을 때 때가 된 알림은 점검이 밀려 늦어졌을 뿐이라 얼마나 늦었든
 * 보낸다 — 예전에는 늦어진 시간만 보고 하루가 넘으면 버려서, 누군가 알림을 한꺼번에 몰아 두면 남의 알림이 밀리다가 아무
 * 표시 없이 사라졌다(검토 S19).
 * [upSince]·[downSince]는 가동 상태(reminderUptimeAfterSweep) — 점검이 끊김 없이 돌기 시작한 시각과, 그 직전에 점검이
 * 끊긴 시각(모르면 null — 서버를 막 켰으면 그 전 전부를 꺼져 있던 것으로 본다). [upSince]를 안 주면 [now](서버가 지금
 * 막 켜진 것으로 본다 — 예전과 같은 판단).
 */
export function shouldDeliverReminder({ progress, remindAt, now = Date.now(), upSince = null, downSince = null }) {
  if (progress >= 100) return false;
  // 점검이 끊기기 전(서버가 돌고 있을 때)에 때가 된 알림 — 밀려서 늦어졌을 뿐이다.
  if (downSince !== null && remindAt <= downSince) return true;
  // 다시 켜진 뒤에 때가 됐으면(0 이하) 늘 보내고, 꺼져 있는 동안 때가 됐으면 다시 켜질 때까지 하루를 넘겼는지 본다.
  return (upSince ?? now) - remindAt <= TODO_REMINDER_STALE_MS;
}

/** 알림 점검이 아직 한 번도 성공하지 못한 가동 상태(서버를 막 켰을 때) — reminderUptimeAfterSweep의 처음 값. */
export const TODO_REMINDER_UPTIME_START = Object.freeze({ lastOkAt: null, upSince: null, downSince: null });

/**
 * 알림 점검(보낼 알림 찜하기)이 [now]에 성공했을 때의 가동 상태 — `{ lastOkAt(마지막으로 성공한 시각), upSince(끊김 없이
 * 점검하기 시작한 시각), downSince(그 직전에 점검이 끊긴 시각 — 모르면 null) }`. 서버를 켜고 처음 성공하면 그 전 전부를
 * 꺼져 있던 구간으로 보고(downSince null — 이전 서버가 언제 꺼졌는지는 기록이 없다), 그 뒤로는 점검이 하루
 * (TODO_REMINDER_STALE_MS)보다 오래 성공하지 못했을 때(DB에 닿지 못함 등)만 그 사이를 꺼져 있던 구간으로 새로 잡는다 —
 * 하루 안의 끊김은 그동안 때가 된 알림이 다시 점검할 때까지 하루를 넘길 수 없어 따로 기억할 필요가 없다. 가동 상태는
 * 서버(프로세스) 메모리에만 둔다(todos.js).
 */
export function reminderUptimeAfterSweep(state, now) {
  if (!state || state.lastOkAt === null) return { lastOkAt: now, upSince: now, downSince: null };
  if (now - state.lastOkAt > TODO_REMINDER_STALE_MS) return { lastOkAt: now, upSince: now, downSince: state.lastOkAt };
  return { ...state, lastOkAt: Math.max(state.lastOkAt, now) };
}

/**
 * 보낼 때가 된 알림을 남김없이 보낸다 — 묶음마다 찜하고([claim]) 보내기([deliver])를 남은 것이 없을 때까지 되풀이하되,
 * [budgetMs]를 다 쓰면 거기서 멈추고 나머지는 다음 점검이 이어서 보낸다. 예전에는 1분에 한 묶음(200건)만 보내서, 누군가
 * 알림을 한꺼번에 몰아 두면 그만큼 모두의 알림이 밀렸다(검토 S19). 묶음마다 "지금"을 새로 재므로 오래 도는 동안 때가 된
 * 알림도 같은 바퀴에서 찜한다. 한 묶음 안에서 누구 알림을 먼저 고르는지(사람마다 돌아가며)는 찜하는 쪽이 정한다
 * (db/queries/todos.js claimDueTodoReminders).
 * [claim](at) → `{ reminders, more }`(more = 같은 조건에 더 남았을 수 있음), [deliver](reminders, at) → 보낸 개수. 찜·보내기를
 * 받아서 쓰는 것은 DB 없이 시험하려고다(실제로는 todos.js sweepTodoReminders). 돌려주는 값은
 * `{ claimed, delivered, batches, outOfTime(시간을 다 써서 멈췄으면 true) }`.
 */
export async function drainDueReminders({ claim, deliver, now = () => Date.now(), budgetMs = TODO_REMINDER_SWEEP_BUDGET_MS }) {
  const startedAt = now();
  const result = { claimed: 0, delivered: 0, batches: 0, outOfTime: false };
  for (;;) {
    const at = now();
    const { reminders, more } = await claim(at);
    result.batches += 1;
    result.claimed += reminders.length;
    if (reminders.length > 0) result.delivered += await deliver(reminders, at);
    // 다 보냈으면 끝. 이번 묶음이 비었으면(골라 둔 것을 다른 서버가 먼저 찜함) 헛돌지 않게 다음 점검으로 넘긴다.
    if (!more || reminders.length === 0) return result;
    if (now() - startedAt >= budgetMs) {
      result.outOfTime = true;
      return result;
    }
  }
}

// ── 목록 쿼리 ───────────────────────────────────────────────────────────

/** 두 날짜('YYYY-MM-DD') 사이의 날 수(to − from). */
function daysBetween(from, to) {
  const utc = (s) => Date.UTC(Number(s.slice(0, 4)), Number(s.slice(5, 7)) - 1, Number(s.slice(8, 10)));
  return Math.round((utc(to) - utc(from)) / (24 * 60 * 60 * 1000));
}

/**
 * 목록의 기간 조건 검사(달력 보기) — from/to('YYYY-MM-DD')는 둘 다 주거나 둘 다 빼야 하고, from ≤ to, 양 끝을 포함해
 * 최대 100일. 둘 다 없으면 `{ value: null }`, 통과하면 `{ value: { from, to } }`, 아니면 `{ error }`.
 */
export function parseTodoRange(from, to) {
  const given = (v) => v !== undefined && v !== null && v !== '';
  if (!given(from) && !given(to)) return { value: null };
  if (!given(from) || !given(to)) return { error: 'from과 to는 함께 보내야 합니다.' };
  if (!isValidDateString(from) || !isValidDateString(to)) return { error: '기간이 올바르지 않습니다. (YYYY-MM-DD)' };
  if (from > to) return { error: '기간의 시작일은 종료일보다 늦을 수 없습니다.' };
  if (daysBetween(from, to) + 1 > TODO_RANGE_MAX_DAYS) {
    return { error: `기간은 최대 ${TODO_RANGE_MAX_DAYS}일까지 조회할 수 있습니다.` };
  }
  return { value: { from, to } };
}

/**
 * 목록의 "기준 진척률"을 누구 것으로 볼지 — assigneeId가 있으면 그 사람, 없고 나의 할 일(mine)이면 나(담당자가
 * 아닌 할 일은 todos.progress로 대신), 그 밖은 null(집계 todos.progress). 완료 제외와 "완료 여부" 정렬이 이 값을 본다.
 */
export function progressPerspective({ scope, assigneeId, userId }) {
  if (assigneeId) return assigneeId;
  if (scope === 'mine') return userId;
  return null;
}

/**
 * GET /todos 쿼리 검사 — 통과하면 `{ teamId, scope, includeDone, roomId, assigneeId, from, to, sort, limit, offset }`,
 * 아니면 `{ error }`. assigneeId(선택)는 그 사람이 담당자인 것만 — 어떤 scope에도 걸 수 있다. from/to(선택)는 기간이
 * 겹치는 것만(parseTodoRange) — 이때는 limit을 500까지 받는다(없으면 100까지). 정렬이 "즐겨찾기 먼저·미완료 먼저·
 * 마감 임박순·생성순"의 복합 키라 커서 대신 offset으로 이어 받는다(다른 목록의 before와 다른 점).
 * q(선택 — 검색 패널의 "할 일" 탭)는 제목·설명에 그 글이 든 것만(대소문자 무시) — 앞뒤 공백을 떼고 소문자로, 비면 null,
 * [TODO_SEARCH_MAX]자가 넘으면 오류.
 */
export function parseTodoListQuery(query) {
  const teamId = typeof query?.teamId === 'string' ? query.teamId : '';
  if (!isUuid(teamId)) return { error: 'teamId가 필요합니다.' };
  let q = null;
  if (query?.q !== undefined && query.q !== '') {
    if (typeof query.q !== 'string') return { error: 'q가 올바르지 않습니다.' };
    const trimmed = query.q.trim().toLowerCase();
    if (graphemeLength(trimmed) > TODO_SEARCH_MAX) return { error: `검색어는 ${TODO_SEARCH_MAX}자 이내로 입력하세요.` };
    q = trimmed || null;
  }
  const scope = typeof query?.scope === 'string' && query.scope ? query.scope : 'mine';
  if (!TODO_SCOPES.includes(scope)) return { error: `scope는 ${TODO_SCOPES.join('|')} 중 하나여야 합니다.` };
  const sort = typeof query?.sort === 'string' && query.sort ? query.sort : 'due';
  if (!TODO_SORTS.includes(sort)) return { error: `sort는 ${TODO_SORTS.join('|')} 중 하나여야 합니다.` };
  let includeDone = true;
  if (query?.includeDone !== undefined && query.includeDone !== '') {
    if (query.includeDone === 'true' || query.includeDone === true) includeDone = true;
    else if (query.includeDone === 'false' || query.includeDone === false) includeDone = false;
    else return { error: 'includeDone은 true/false여야 합니다.' };
  }
  let roomId = null;
  if (query?.roomId !== undefined && query.roomId !== '') {
    if (typeof query.roomId !== 'string') return { error: 'roomId가 올바르지 않습니다.' };
    roomId = query.roomId;
  }
  let assigneeId = null;
  if (query?.assigneeId !== undefined && query.assigneeId !== '') {
    if (!isUuid(query.assigneeId)) return { error: 'assigneeId가 올바르지 않습니다.' };
    assigneeId = query.assigneeId.toLowerCase();
  }
  const range = parseTodoRange(query?.from, query?.to);
  if (range.error) return range;
  let limit = TODO_LIST_DEFAULT_LIMIT;
  if (query?.limit !== undefined && query.limit !== '') {
    const n = Math.floor(Number(query.limit));
    if (!Number.isFinite(n) || n < 1) return { error: 'limit은 1 이상의 숫자여야 합니다.' };
    limit = Math.min(n, range.value ? TODO_RANGE_MAX_LIMIT : TODO_LIST_MAX_LIMIT);
  }
  let offset = 0;
  if (query?.offset !== undefined && query.offset !== '') {
    const n = Math.floor(Number(query.offset));
    if (!Number.isFinite(n) || n < 0) return { error: 'offset은 0 이상의 숫자여야 합니다.' };
    offset = n;
  }
  return {
    teamId,
    scope,
    includeDone,
    roomId,
    assigneeId,
    q,
    from: range.value?.from ?? null,
    to: range.value?.to ?? null,
    sort,
    limit,
    offset,
  };
}

// ── 할 일 카드 메시지 ───────────────────────────────────────────────────

/** 카드 스냅샷의 설명 글자 수·첨부 이름 수 상한 — 카드에는 앞부분만 보이고 자세한 건 상세에서 본다. */
export const TODO_CARD_DESCRIPTION_MAX = 300;
export const TODO_CARD_ATTACHMENTS_MAX = 5;

/**
 * 할 일을 만들 때 그 대화방에 올리는 "할 일 카드" 메시지(생성 창 "대화방에 알리기" — 잔디의 할 일 메시지) — `{ text,
 * mentions, card }`. 메시지 자체는 일반 글(type 'text')이고 messages.todo_id·todo_card로 카드가 붙는다(앨범 공유와 같은
 * 방식). [text]는 미리보기·검색·알림에 쓰이는 `[할 일] 제목`이고, 멘션할 수 있는 방(토픽·그룹 — [roomCanMention])이면 다음
 * 줄에 `담당: @이름 @이름`을 붙여 담당자(만든 사람 빼고)를 멘션한다 — 그러면 다른 멤버에게는 평범한 메시지이고 담당자만
 * 멘션 알림을 받는다. 1:1은 상대가 한 명뿐이라 일반 메시지 알림으로 충분하고, 나와의 대화는 알림이 없다. [card]는 보낼
 * 때의 스냅샷(제목·설명 앞부분·기간·첨부 이름·담당자 이름) — 앱은 이것을 먼저 그리고, 할 일을 다시 받아 최신으로 바꾼다.
 */
export function todoCardMessage({ todo, assignees = [], creatorId, attachments = [], roomCanMention }) {
  const description = typeof todo.description === 'string' ? todo.description : null;
  const card = {
    title: todo.title,
    description: description && description.length > TODO_CARD_DESCRIPTION_MAX
      ? `${description.slice(0, TODO_CARD_DESCRIPTION_MAX)}…`
      : description,
    startDate: todo.startDate ?? null,
    startTime: todo.startTime ?? null,
    dueDate: todo.dueDate ?? null,
    dueTime: todo.dueTime ?? null,
    attachments: attachments
      .slice(0, TODO_CARD_ATTACHMENTS_MAX)
      .map((a) => ({ kind: a.kind === 'file' ? 'file' : 'image', fileName: a.fileName ?? null })),
    attachmentCount: attachments.length,
    assigneeNames: assignees.map((a) => a.name),
  };
  let text = `[할 일] ${todo.title}`;
  const mentions = [];
  const targets = roomCanMention ? assignees.filter((a) => a.id !== creatorId) : [];
  if (targets.length > 0) {
    text += '\n담당:';
    for (const a of targets) {
      text += ' ';
      const s = text.length;
      text += `@${a.name}`;
      mentions.push({ type: 'user', userId: a.id, s, e: text.length });
    }
  }
  return { text, mentions, card };
}

/** 메시지 DTO의 할 일 카드 `{ id(할 일이 지워졌으면 null), ...스냅샷 }` — 카드가 없거나 지운 메시지면 null. */
export function toSharedTodoDto(m) {
  const card = m?.todoCard;
  if (!card || typeof card !== 'object' || m.deletedAt) return null;
  return { ...card, id: m.todoId ?? null };
}
