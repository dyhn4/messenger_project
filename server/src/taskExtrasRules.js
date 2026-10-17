/**
 * 업무 기능 보강의 규칙 — 반복 업무(다음 회차 날짜), 선후행 관계(순환 막기), 소요 시간 기록(분·날짜·메모 검사)을
 * DB 없이 시험할 수 있게 계산만 모았다(taskExtras.js·projects.js가 쓴다, test/taskExtrasRules.test.js).
 *
 * 날짜는 한국 날짜(Asia/Seoul — DST가 없어 UTC+9 고정)로 센다. 서버 PC의 시간대와 무관해야 하므로 Date의 로컬
 * getter는 쓰지 않고 "ms + 9시간"의 UTC getter만 쓴다(calendarRecurrence.js와 같은 방식).
 */

export const DAY_MS = 86400000;
const KST_OFFSET_MS = 9 * 3600 * 1000;

// ── 반복 업무 ───────────────────────────────────────────────────────────
//
// recurrence 모양: { freq: 'daily'|'weekly'|'monthly'|'yearly', interval: 1..99, byWeekday?: [0..6](일=0, weekly만),
//   until?: 'YYYY-MM-DD'(그 날까지 — 다음 회차가 이 날을 넘으면 반복을 끝낸다) } — 캘린더 반복 일정과 같은 모양이다.
// 반복 업무는 "완료하면 다음 회차가 생기는" 방식이다(정해진 날 자동 생성이 아님) — 다음 회차의 마감일은 이번 회차의
// 마감일(없으면 시작일, 그것도 없으면 완료한 날) 다음 규칙 날짜이고, 그 날이 이미 지났으면 완료한 날 이후 첫 날짜로 당긴다.

export const RECURRENCE_FREQS = ['daily', 'weekly', 'monthly', 'yearly'];
export const RECURRENCE_MAX_INTERVAL = 99;
const DATE_KEY_RE = /^(\d{4})-(\d{2})-(\d{2})$/;

/** 'YYYY-MM-DD'이고 실제 있는 날짜인지. */
export function isDateKey(value) {
  const m = typeof value === 'string' ? DATE_KEY_RE.exec(value) : null;
  if (!m) return false;
  const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3]));
  return d.getUTCFullYear() === +m[1] && d.getUTCMonth() === +m[2] - 1 && d.getUTCDate() === +m[3];
}

/** 순간(ms·Date)의 한국 날짜 'YYYY-MM-DD'. */
export function kstDateKey(at) {
  const d = new Date(new Date(at).getTime() + KST_OFFSET_MS);
  return d.toISOString().slice(0, 10);
}

/** 'YYYY-MM-DD' → 그 날 UTC 자정 ms(날짜 계산용). */
function keyMs(key) {
  const [y, m, d] = key.split('-').map(Number);
  return Date.UTC(y, m - 1, d);
}

function msKey(ms) {
  return new Date(ms).toISOString().slice(0, 10);
}

/** 두 날짜 사이 날 수(b - a). */
export function daysBetween(a, b) {
  return Math.round((keyMs(b) - keyMs(a)) / DAY_MS);
}

/**
 * 반복 규칙 입력을 검사한다 — null이면 반복 끄기. `{ recurrence }`(정리된 규칙 또는 null) | `{ error }`.
 */
export function parseRecurrence(input) {
  if (input === null) return { recurrence: null };
  if (typeof input !== 'object' || Array.isArray(input)) return { error: '반복 규칙이 올바르지 않습니다.' };
  const freq = input.freq;
  if (!RECURRENCE_FREQS.includes(freq)) return { error: '반복 주기는 매일·매주·매월·매년 중 하나입니다.' };
  const interval = input.interval ?? 1;
  if (!Number.isInteger(interval) || interval < 1 || interval > RECURRENCE_MAX_INTERVAL) {
    return { error: `반복 간격은 1~${RECURRENCE_MAX_INTERVAL} 사이의 정수입니다.` };
  }
  const recurrence = { freq, interval };
  if (freq === 'weekly' && input.byWeekday != null) {
    const days = input.byWeekday;
    if (!Array.isArray(days) || days.some((d) => !Number.isInteger(d) || d < 0 || d > 6)) {
      return { error: '반복 요일이 올바르지 않습니다.' };
    }
    const unique = [...new Set(days)].sort((a, b) => a - b);
    if (unique.length > 0) recurrence.byWeekday = unique;
  }
  if (input.until != null) {
    if (!isDateKey(input.until)) return { error: '반복 종료일은 YYYY-MM-DD 형식입니다.' };
    recurrence.until = input.until;
  }
  return { recurrence };
}

/** 저장된 규칙(jsonb)을 다시 읽는다 — 모양이 틀리면 null(반복 안 함). */
export function recurrenceOf(task) {
  const raw = task?.recurrence;
  if (!raw) return null;
  const parsed = parseRecurrence(raw);
  return parsed.error ? null : parsed.recurrence;
}

/** [y]년 [m]월(1~12)의 날 수. */
function daysInMonth(y, m) {
  return new Date(Date.UTC(y, m, 0)).getUTCDate();
}

/** [key] 다음의 규칙 날짜 하나(그 날짜 자체는 빼고). [anchor]는 이 시리즈의 기준 날짜(주 간격·달 날짜를 셀 때). */
function stepAfter(rule, key, anchor) {
  const { freq, interval } = rule;
  if (freq === 'daily') return msKey(keyMs(key) + interval * DAY_MS);
  if (freq === 'weekly') {
    const days = rule.byWeekday;
    if (!days || days.length === 0) return msKey(keyMs(key) + interval * 7 * DAY_MS);
    // 기준 날짜가 든 주(일요일 시작)부터 interval 주마다 고른 요일들 — 다음 날부터 하루씩 본다(많아야 7×99일).
    const anchorMs = keyMs(anchor);
    const anchorWeekStart = anchorMs - new Date(anchorMs).getUTCDay() * DAY_MS;
    for (let ms = keyMs(key) + DAY_MS, i = 0; i < 7 * interval + 7; ms += DAY_MS, i += 1) {
      const d = new Date(ms);
      const week = Math.floor((ms - d.getUTCDay() * DAY_MS - anchorWeekStart) / (7 * DAY_MS));
      if (week % interval === 0 && days.includes(d.getUTCDay())) return msKey(ms);
    }
    return msKey(keyMs(key) + interval * 7 * DAY_MS);
  }
  // 매월·매년 — 기준 날짜의 "일"을 지키되 그 달에 없으면(31일·2월 29일) 그 달 마지막 날.
  const anchorDay = Number(anchor.slice(8, 10));
  const [y, m] = key.split('-').map(Number);
  const months = freq === 'monthly' ? interval : interval * 12;
  const total = y * 12 + (m - 1) + months;
  const ny = Math.floor(total / 12);
  const nm = (total % 12) + 1;
  const nd = Math.min(anchorDay, daysInMonth(ny, nm));
  return `${ny}-${String(nm).padStart(2, '0')}-${String(nd).padStart(2, '0')}`;
}

/**
 * 반복 업무를 [completedAt]에 끝냈을 때 다음 회차의 기준 날짜 — `{ key, shiftDays }`(기준 날짜 'YYYY-MM-DD'와
 * 이번 회차에서 며칠 옮겼는지) | null(종료일을 넘음). [base]는 이번 회차의 기준 날짜(마감일 → 시작일 → 완료한 날).
 */
export function nextOccurrence(rule, base, completedAt) {
  const today = kstDateKey(completedAt);
  let key = stepAfter(rule, base, base);
  // 늦게 끝낸 업무 — 다음 회차가 이미 지난 날이면 오늘 이후의 첫 회차로(밀린 회차를 한꺼번에 만들지 않는다).
  for (let i = 0; i < 10000 && key < today; i += 1) key = stepAfter(rule, key, base);
  if (rule.until && key > rule.until) return null;
  return { key, shiftDays: daysBetween(base, key) };
}

/**
 * 다음 회차 업무의 시작일·마감일 — 이번 회차의 날짜들을 같은 날 수만큼 옮긴다(시각은 그대로). 날짜가 없던 업무는
 * 다음 회차에 마감일만 둔다(완료한 날 기준 — 그 날 오후 6시, 한국 시각). null이면 반복이 끝났다.
 */
export function nextOccurrenceDates(task, rule, completedAt) {
  const dueAt = task.dueDate ? new Date(task.dueDate).getTime() : null;
  const startAt = task.startDate ? new Date(task.startDate).getTime() : null;
  const baseAt = dueAt ?? startAt;
  if (baseAt == null) {
    const next = nextOccurrence(rule, kstDateKey(completedAt), completedAt);
    if (!next) return null;
    // 한국 시각 그 날 18:00 = UTC 09:00.
    return { startDate: null, dueDate: new Date(keyMs(next.key) + 9 * 3600 * 1000) };
  }
  const next = nextOccurrence(rule, kstDateKey(baseAt), completedAt);
  if (!next) return null;
  const shift = next.shiftDays * DAY_MS;
  return {
    startDate: startAt == null ? null : new Date(startAt + shift),
    dueDate: dueAt == null ? null : new Date(dueAt + shift),
  };
}

const WEEKDAY_NAMES = ['일', '월', '화', '수', '목', '금', '토'];

/** "매주 월·수", "2주마다", "매월", "매일 (~2026-12-31)" — 기록·알림 문구. */
export function recurrenceLabel(rule) {
  if (!rule) return '반복 안 함';
  const unit = { daily: '일', weekly: '주', monthly: '개월', yearly: '년' }[rule.freq];
  const every = { daily: '매일', weekly: '매주', monthly: '매월', yearly: '매년' }[rule.freq];
  let text = rule.interval === 1 ? every : `${rule.interval}${unit}마다`;
  if (rule.freq === 'weekly' && rule.byWeekday?.length) text += ` ${rule.byWeekday.map((d) => WEEKDAY_NAMES[d]).join('·')}`;
  if (rule.until) text += ` (~${rule.until})`;
  return text;
}

// ── 선후행 관계 ─────────────────────────────────────────────────────────
//
// 선후행은 "이 업무(후행)는 저 업무(선행)가 끝나야 시작할 수 있다". 같은 프로젝트의 업무끼리만, 순환은 안 된다.
// 막지는 않고 알린다 — 선행이 안 끝난 업무도 진행·완료할 수 있지만 상세·목록에 "선행 업무 N개 남음"이 보이고,
// 선행이 모두 끝나면 후행 업무 담당자에게 알림이 간다.

export const TASK_PREDECESSORS_MAX = 30;

/**
 * [taskId]의 선행으로 [predecessorId]를 넣으면 순환이 생기는지 — [edges]는 지금 관계 [{ taskId, dependsOnId }].
 * 선행 쪽에서 선행을 따라 올라가다 [taskId]를 만나면 순환이다.
 */
export function wouldCreateCycle(edges, taskId, predecessorId) {
  if (taskId === predecessorId) return true;
  const preds = new Map();
  for (const e of edges) {
    if (!preds.has(e.taskId)) preds.set(e.taskId, []);
    preds.get(e.taskId).push(e.dependsOnId);
  }
  const seen = new Set();
  const stack = [predecessorId];
  while (stack.length > 0) {
    const id = stack.pop();
    if (id === taskId) return true;
    if (seen.has(id)) continue;
    seen.add(id);
    for (const p of preds.get(id) ?? []) stack.push(p);
  }
  return false;
}

// ── 소요 시간 ───────────────────────────────────────────────────────────

/** 한 번에 남길 수 있는 시간(분) — 하루. */
export const TIME_ENTRY_MAX_MINUTES = 24 * 60;
export const TIME_ENTRY_NOTE_MAX = 200;
/** 예상 소요 시간(분) 상한 — 1000시간. */
export const ESTIMATE_MAX_MINUTES = 1000 * 60;

/**
 * 시간 기록 입력 `{ minutes, workDate?, note? }` → `{ entry: { minutes, workDate, note } }` | `{ error }`.
 * 날짜는 비우면 [now]의 한국 날짜, 미래(내일 이후)는 받지 않는다.
 */
export function parseTimeEntry(body, now = new Date()) {
  const minutes = body?.minutes;
  if (!Number.isInteger(minutes) || minutes < 1 || minutes > TIME_ENTRY_MAX_MINUTES) {
    return { error: '시간은 1분~24시간 사이로 입력하세요.' };
  }
  const today = kstDateKey(now);
  const workDate = body?.workDate ?? today;
  if (!isDateKey(workDate)) return { error: '날짜는 YYYY-MM-DD 형식입니다.' };
  if (workDate > today) return { error: '앞으로의 날짜에는 시간을 남길 수 없습니다.' };
  const rawNote = body?.note;
  if (rawNote != null && typeof rawNote !== 'string') return { error: '메모가 올바르지 않습니다.' };
  const note = (rawNote ?? '').trim();
  if ([...note].length > TIME_ENTRY_NOTE_MAX) return { error: `메모는 ${TIME_ENTRY_NOTE_MAX}자까지 쓸 수 있습니다.` };
  return { entry: { minutes, workDate, note: note || null } };
}

/** 예상 소요 시간 입력 — null이면 지우기. `{ value }` | `{ error }`. */
export function parseEstimate(value) {
  if (value === null) return { value: null };
  if (!Number.isInteger(value) || value < 1 || value > ESTIMATE_MAX_MINUTES) {
    return { error: '예상 시간은 1분~1000시간 사이로 입력하세요.' };
  }
  return { value };
}

/**
 * 타이머를 멈췄을 때 남길 기록 — 1분이 안 되면 null(버린다), 하루를 넘으면 하루로 자른다. 날짜는 시작한 날(한국).
 */
export function timerEntry(startedAt, stoppedAt) {
  const minutes = Math.round((new Date(stoppedAt).getTime() - new Date(startedAt).getTime()) / 60000);
  if (minutes < 1) return null;
  return { minutes: Math.min(minutes, TIME_ENTRY_MAX_MINUTES), workDate: kstDateKey(startedAt) };
}

/** 분 → "2시간 30분" · "45분" · "3시간". */
export function minutesLabel(minutes) {
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  if (h === 0) return `${m}분`;
  return m === 0 ? `${h}시간` : `${h}시간 ${m}분`;
}

/** 소요 시간 보고의 기간 `{ from, to }`(둘 다 'YYYY-MM-DD', 포함) — 안 주면 이번 달, 최대 1년. */
export function parseReportRange(query, now = new Date()) {
  const today = kstDateKey(now);
  const from = query?.from ?? `${today.slice(0, 8)}01`;
  const to = query?.to ?? today;
  if (!isDateKey(from) || !isDateKey(to)) return { error: '기간은 YYYY-MM-DD 형식입니다.' };
  if (from > to) return { error: '시작일이 종료일보다 늦습니다.' };
  if (daysBetween(from, to) > 366) return { error: '기간은 1년까지 볼 수 있습니다.' };
  return { from, to };
}
