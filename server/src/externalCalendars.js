import crypto from 'node:crypto';
import { Router } from 'express';
import { teamAccess } from './access.js';
import { RateLimiter, tooMany } from './authGuard.js';
import { KST_OFFSET_MS } from './calendarRecurrence.js';
import { decryptField, encryptField } from './crypto.js';
import {
  countExternalCalendars,
  deleteExternalCalendar,
  findExternalCalendar,
  insertExternalCalendar,
  listDueExternalCalendars,
  listExternalCalendars,
  listExternalEventsForWindow,
  replaceExternalEvents,
  updateExternalCalendar,
} from './db/queries/externalCalendars.js';
import {
  EXTERNAL_CALENDAR_MAX,
  EXTERNAL_FETCH_DEADLINE_MS,
  EXTERNAL_FETCH_MAX_BYTES,
  EXTERNAL_MANUAL_REFRESH_MIN_MS,
  EXTERNAL_NAME_MAX,
  EXTERNAL_REFRESH_INTERVAL_MS,
  EXTERNAL_WINDOW_FUTURE_MS,
  EXTERNAL_WINDOW_PAST_MS,
  fetchErrorText,
  normalizeIcsUrl,
  toExternalCalendarDto,
  toExternalOccurrenceDto,
} from './externalCalendarRules.js';
import { parseIcs } from './icsImport.js';
import { safeFetch } from './linkPreview.js';

/**
 * 외부 캘린더 구독(가져오기) — Google·Outlook·iCloud 등에서 복사한 ICS 주소를 넣으면 서버가 받아(30분마다) 펼친 회차를 저장하고,
 * 일정 조회(calendars.js)가 내 화면에 붙여 보낸다. 나에게만 보이고 읽기 전용이다. 규칙은 externalCalendarRules.js, ICS 읽기는
 * icsImport.js. 바깥 주소로 나가는 요청은 safeFetch(사설 IP·다른 포트 차단, 크기·시간 상한)만 쓴다.
 */

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const COLOR_RE = /^#[0-9a-fA-F]{6}$/;
const PALETTE = ['#8E24AA', '#039BE5', '#0B8043', '#F4511E', '#616161', '#D81B60', '#3F51B5', '#7CB342'];
/** 일정 조회 한 번에 붙이는 외부 회차 상한(62일 구간이면 넉넉하다). */
const QUERY_EXTERNAL_MAX = 3000;
const JOB_INTERVAL_MS = 5 * 60 * 1000;
const JOB_BATCH = 20;

/** 새 구독 추가는 바깥 주소를 그 자리에서 받아 보므로 사람마다 횟수를 묶는다. */
const addLimiter = new RateLimiter({ max: 20, windowMs: 10 * 60 * 1000 });

/** 같은 구독을 동시에 두 번 받지 않게(자동 새로고침과 "지금 새로고침"이 겹칠 때). */
const refreshing = new Set();

function parseName(raw) {
  if (raw == null) return null;
  if (typeof raw !== 'string') return { error: '이름을 올바르게 보내세요.' };
  const s = raw.trim();
  if (!s) return { error: '이름을 입력하세요.' };
  if ([...s].length > EXTERNAL_NAME_MAX) return { error: `이름은 ${EXTERNAL_NAME_MAX}자 이하로 입력하세요.` };
  return { value: s };
}

/** ICS 주소를 받아 펼친다 — { name, occurrences, hash } 또는 throw(err.userMessage에 앱에 보일 이유). */
export async function fetchIcs(url, now = Date.now()) {
  let res;
  try {
    res = await safeFetch(url, {
      maxRedirects: 5,
      maxBytes: EXTERNAL_FETCH_MAX_BYTES,
      accept: 'text/calendar, text/plain;q=0.5, */*;q=0.1',
      truncate: false,
      deadlineMs: EXTERNAL_FETCH_DEADLINE_MS,
    });
  } catch (err) {
    throw Object.assign(new Error(err.message), { userMessage: fetchErrorText(err) });
  }
  if (!res) throw Object.assign(new Error('no response'), { userMessage: fetchErrorText(null) });
  if (res.status !== 200) throw Object.assign(new Error(`status ${res.status}`), { userMessage: fetchErrorText(null, res.status) });
  const text = res.body.toString('utf8');
  // 펼쳐 둔 구간은 날마다 밀리므로, 내용이 그대로여도 일주일에 한 번은 다시 펼친다(해시에 주 번호를 섞는다).
  const week = Math.floor(now / (7 * 86400000));
  const hash = crypto.createHash('sha256').update(text).update(`|${week}`).digest('hex');
  let parsed;
  try {
    parsed = parseIcs(text, { fromMs: now - EXTERNAL_WINDOW_PAST_MS, toMs: now + EXTERNAL_WINDOW_FUTURE_MS });
  } catch (err) {
    throw Object.assign(new Error(err.message), { userMessage: fetchErrorText(new Error('ICS 형식')) });
  }
  return { ...parsed, hash };
}

/** 구독 하나를 다시 받는다. 바뀐 게 있으면 그 사람에게 calendar:changed. 실패는 lastError에 남기고 던지지 않는다. */
export async function refreshExternalCalendar(io, row, { now = Date.now() } = {}) {
  if (refreshing.has(row.id)) return row;
  refreshing.add(row.id);
  try {
    const at = new Date(now);
    let fetched;
    try {
      fetched = await fetchIcs(decryptField(row.urlEnc), now);
    } catch (err) {
      const updated = await updateExternalCalendar(row.id, { lastFetchedAt: at, lastError: err.userMessage ?? fetchErrorText(err) });
      if (row.lastError !== updated?.lastError) emitChanged(io, row);
      return updated;
    }
    if (fetched.hash === row.contentHash) {
      const updated = await updateExternalCalendar(row.id, { lastFetchedAt: at, lastSuccessAt: at, lastError: null });
      if (row.lastError) emitChanged(io, row);
      return updated;
    }
    if (fetched.truncated) console.warn(`[external-calendar] ${row.id}: 회차가 많아 앞의 일부만 저장했습니다.`);
    const updated = await replaceExternalEvents(row.id, fetched.occurrences, {
      contentHash: fetched.hash,
      lastFetchedAt: at,
      lastSuccessAt: at,
      lastError: null,
    });
    emitChanged(io, row);
    return updated;
  } finally {
    refreshing.delete(row.id);
  }
}

function emitChanged(io, row) {
  io?.to(`user:${row.userId}`).emit('calendar:changed', { teamId: row.teamId, calendarId: `ext:${row.id}` });
}

/** 일정 조회에 붙일 내 외부 회차 — 종일 회차는 한국 날짜로 구간과 겹치는지 본다(calendars.js의 공휴일과 같다). */
export async function externalOccurrencesFor({ teamId, userId, fromMs, toMs }) {
  const calendars = await listExternalCalendars(userId, teamId);
  if (calendars.length === 0) return [];
  const byId = new Map(calendars.map((c) => [c.id, c]));
  const rows = await listExternalEventsForWindow([...byId.keys()], fromMs, toMs, KST_OFFSET_MS, QUERY_EXTERNAL_MAX);
  const dayFrom = fromMs + KST_OFFSET_MS;
  const dayTo = toMs + KST_OFFSET_MS;
  const out = [];
  for (const row of rows) {
    const start = row.startAt.getTime();
    const end = row.endAt.getTime();
    const overlaps = row.allDay ? start < dayTo && end > dayFrom : start < toMs && (end > fromMs || (end === start && start >= fromMs));
    if (overlaps) out.push(toExternalOccurrenceDto(row, byId.get(row.externalCalendarId)));
  }
  return out;
}

export function createExternalCalendarsRouter(io) {
  const router = Router();

  /** 내 구독을 읽는다 — 없거나 남의 것이면 404로 응답하고 null. */
  async function loadMine(req, res) {
    const id = String(req.params.id ?? '').replace(/^ext:/, '');
    const row = UUID_RE.test(id) ? await findExternalCalendar(id) : null;
    if (!row || row.userId !== req.user.sub) {
      res.status(404).json({ error: '캘린더를 찾을 수 없습니다.' });
      return null;
    }
    return row;
  }

  router.post('/teams/:teamId/external-calendars', async (req, res) => {
    const userId = req.user.sub;
    const teamId = req.params.teamId;
    if (!UUID_RE.test(teamId)) return res.status(404).json({ error: '팀을 찾을 수 없습니다.' });
    const team = await teamAccess(teamId, userId);
    if (!team.isMember) return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    const wait = addLimiter.hit(userId);
    if (wait > 0) return tooMany(res, wait, '캘린더 추가');

    const target = normalizeIcsUrl(req.body?.url);
    if (target.error) return res.status(400).json({ error: target.error });
    const name = parseName(req.body?.name);
    if (name?.error) return res.status(400).json({ error: name.error });
    const color = req.body?.color;
    if (color != null && !(typeof color === 'string' && COLOR_RE.test(color))) {
      return res.status(400).json({ error: '색을 올바르게 보내세요.' });
    }
    const existing = await countExternalCalendars(userId, teamId);
    if (existing >= EXTERNAL_CALENDAR_MAX) {
      return res.status(400).json({ error: `외부 캘린더는 ${EXTERNAL_CALENDAR_MAX}개까지 구독할 수 있습니다.` });
    }

    // 넣자마자 받아 본다 — 잘못된 주소면 저장하지 않고 이유를 알려 준다.
    const now = Date.now();
    let fetched;
    try {
      fetched = await fetchIcs(target.url, now);
    } catch (err) {
      return res.status(400).json({ error: err.userMessage ?? fetchErrorText(err) });
    }
    const row = await insertExternalCalendar({
      teamId,
      userId,
      name: name?.value ?? ([...(fetched.name ?? '')].slice(0, EXTERNAL_NAME_MAX).join('') || target.host),
      urlEnc: encryptField(target.url),
      host: target.host,
      color: color ?? PALETTE[existing % PALETTE.length],
    });
    const at = new Date(now);
    const saved = await replaceExternalEvents(row.id, fetched.occurrences, {
      contentHash: fetched.hash,
      lastFetchedAt: at,
      lastSuccessAt: at,
      lastError: null,
    });
    emitChanged(io, row);
    res.status(201).json(toExternalCalendarDto(saved ?? row));
  });

  router.patch('/external-calendars/:id', async (req, res) => {
    const row = await loadMine(req, res);
    if (!row) return;
    const patch = {};
    const name = parseName(req.body?.name);
    if (name?.error) return res.status(400).json({ error: name.error });
    if (name) patch.name = name.value;
    if (req.body?.color != null) {
      if (!(typeof req.body.color === 'string' && COLOR_RE.test(req.body.color))) {
        return res.status(400).json({ error: '색을 올바르게 보내세요.' });
      }
      patch.color = req.body.color;
    }
    if (req.body?.hidden != null) {
      if (typeof req.body.hidden !== 'boolean') return res.status(400).json({ error: 'hidden을 올바르게 보내세요.' });
      patch.hidden = req.body.hidden;
    }
    const updated = Object.keys(patch).length > 0 ? await updateExternalCalendar(row.id, patch) : row;
    emitChanged(io, row);
    res.json(toExternalCalendarDto(updated ?? row));
  });

  router.delete('/external-calendars/:id', async (req, res) => {
    const row = await loadMine(req, res);
    if (!row) return;
    await deleteExternalCalendar(row.id);
    emitChanged(io, row);
    res.json({ ok: true });
  });

  /** 지금 새로고침 — 1분에 한 번까지. */
  router.post('/external-calendars/:id/refresh', async (req, res) => {
    const row = await loadMine(req, res);
    if (!row) return;
    const since = row.lastFetchedAt ? Date.now() - row.lastFetchedAt.getTime() : Infinity;
    if (since < EXTERNAL_MANUAL_REFRESH_MIN_MS) return tooMany(res, EXTERNAL_MANUAL_REFRESH_MIN_MS - since, '새로고침');
    const updated = await refreshExternalCalendar(io, row);
    res.json(toExternalCalendarDto(updated ?? row));
  });

  return router;
}

/** 30분이 지난 구독을 차례로 다시 받는다(5분마다 한 묶음). 그 팀을 떠난 사람의 구독은 지운다. */
export function startExternalCalendarJob(io) {
  let running = false;
  const tick = async () => {
    if (running) return;
    running = true;
    try {
      const due = await listDueExternalCalendars(new Date(Date.now() - EXTERNAL_REFRESH_INTERVAL_MS), JOB_BATCH);
      for (const row of due) {
        const team = await teamAccess(row.teamId, row.userId);
        if (!team.isMember) {
          await deleteExternalCalendar(row.id);
          continue;
        }
        await refreshExternalCalendar(io, row);
      }
    } catch (err) {
      console.error('[external-calendar] 새로고침 실패:', err);
    } finally {
      running = false;
    }
  };
  setTimeout(tick, 30 * 1000).unref?.();
  setInterval(tick, JOB_INTERVAL_MS).unref?.();
}
