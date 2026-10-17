import { DAY_MS, isDateKey, kstDateKey } from './taskExtrasRules.js';

/**
 * 그룹웨어 업무일지(일일·주간 업무보고)의 규칙 — 보고 기간, 본문 검사, 누가 볼 수 있는지를 DB 없이 시험할 수 있게 모았다
 * (groupwareReports.js가 쓴다, test/workReportRules.test.js). 날짜는 한국 날짜.
 *
 * 보고 하나는 (사람, 범위, 종류, 기간 시작일)마다 하나 — 일일은 그 날, 주간은 그 주 월요일. 쓴 사람은 언제든 고칠 수 있다.
 * 보는 사람(검토자)은 조직도의 상위자(가까운 두 명)와 그룹웨어 관리자 — 상위자가 정해지지 않은 사람의 보고는 관리자만 본다.
 */

export const REPORT_KINDS = ['daily', 'weekly'];
export const REPORT_KIND_LABEL = { daily: '일일 업무보고', weekly: '주간 업무보고' };
export const REPORT_FIELD_MAX = 5000;
export const REPORT_COMMENT_MAX = 1000;
/** 보고를 받는 상위자 수(가까운 사람부터). */
export const REPORT_REVIEWER_DEPTH = 2;

/** 'YYYY-MM-DD'의 요일(일=0). */
function weekdayOf(key) {
  const [y, m, d] = key.split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d)).getUTCDay();
}

function shiftKey(key, days) {
  const [y, m, d] = key.split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d) + days * DAY_MS).toISOString().slice(0, 10);
}

/** [key]가 든 기간의 시작일 — 일일은 그 날, 주간은 그 주 월요일. */
export function periodStartOf(kind, key) {
  if (kind === 'weekly') {
    const wd = weekdayOf(key);
    return shiftKey(key, wd === 0 ? -6 : 1 - wd);
  }
  return key;
}

/** 기간의 마지막 날 — 일일은 그 날, 주간은 일요일. */
export function periodEndOf(kind, start) {
  return kind === 'weekly' ? shiftKey(start, 6) : start;
}

/** 지금 쓰는 기간의 시작일(오늘·이번 주). */
export function currentPeriodStart(kind, now = new Date()) {
  return periodStartOf(kind, kstDateKey(now));
}

/** 앞뒤 기간 시작일(목록의 ◀ ▶). */
export function adjacentPeriod(kind, start, step) {
  return shiftKey(start, (kind === 'weekly' ? 7 : 1) * step);
}

/**
 * 보고 기간 입력 → `{ kind, periodStart }` | `{ error }`. 주간은 월요일이어야 하고, 아직 오지 않은 기간에는 쓸 수 없다.
 */
export function parseReportPeriod(kindInput, startInput, now = new Date()) {
  const kind = REPORT_KINDS.includes(kindInput) ? kindInput : null;
  if (!kind) return { error: '보고 종류는 일일·주간 중 하나입니다.' };
  const periodStart = startInput ?? currentPeriodStart(kind, now);
  if (!isDateKey(periodStart)) return { error: '보고 날짜는 YYYY-MM-DD 형식입니다.' };
  if (kind === 'weekly' && weekdayOf(periodStart) !== 1) return { error: '주간 보고는 그 주 월요일 날짜로 씁니다.' };
  if (periodStart > currentPeriodStart(kind, now)) return { error: '아직 오지 않은 기간의 보고는 쓸 수 없습니다.' };
  return { kind, periodStart };
}

/** 보고 본문 `{ done, plan, issues }` → `{ values }` | `{ error }` — 한 일·할 일 중 하나는 있어야 한다. */
export function parseReportBody(body) {
  const field = (name) => (typeof body?.[name] === 'string' ? body[name].replace(/\r\n/g, '\n').trim() : '');
  const values = { done: field('done'), plan: field('plan'), issues: field('issues') };
  for (const [name, label] of [
    ['done', '한 일'],
    ['plan', '할 일'],
    ['issues', '이슈·건의'],
  ]) {
    if ([...values[name]].length > REPORT_FIELD_MAX) return { error: `${label}은 ${REPORT_FIELD_MAX}자까지 쓸 수 있습니다.` };
  }
  if (!values.done && !values.plan) return { error: '한 일이나 할 일을 쓰세요.' };
  return { values: { done: values.done || null, plan: values.plan || null, issues: values.issues || null } };
}

/** 보고를 볼 수 있는지 — 쓴 사람, 그 사람의 검토자(상위자), 그룹웨어 관리자. */
export function canViewReport({ writerId, viewerId, reviewerIds, isManager }) {
  return writerId === viewerId || isManager || reviewerIds.includes(viewerId);
}

/**
 * 팀 보고 현황 — [people]([{ id, name }] 내가 볼 수 있는 사람들) 각각의 이 기간 보고(없으면 null). 안 쓴 사람이 위로, 그 안에서 이름순.
 */
export function reportRoster(people, reports) {
  const byUser = new Map(reports.map((r) => [r.userId, r]));
  return people
    .map((p) => ({ userId: p.id, name: p.name, report: byUser.get(p.id) ?? null }))
    .sort((a, b) => Number(!!a.report) - Number(!!b.report) || a.name.localeCompare(b.name, 'ko'));
}
