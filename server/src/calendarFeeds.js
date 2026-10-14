import crypto from 'node:crypto';
import { Router } from 'express';
import { teamAccess } from './access.js';
import { accountState } from './authState.js';
import { collectOccurrences, sortOccurrences } from './calendars.js';
import { decryptField, encryptField, lookupHash } from './crypto.js';
import {
  deleteCalendarFeed,
  findCalendarFeed,
  findCalendarFeedByHash,
  touchCalendarFeed,
  upsertCalendarFeed,
} from './db/queries/externalCalendars.js';
import { findTeamById } from './db/queries/teams.js';
import { FEED_WINDOW_FUTURE_MS, FEED_WINDOW_PAST_MS } from './externalCalendarRules.js';
import { buildIcsFeed } from './icsFeed.js';
import { getWebPublicUrl } from './webAddress.js';

/**
 * 내 일정 내보내기 — 팀마다 하나의 비밀 ICS 주소(/calendar-feed/<토큰>.ics)를 만들어 두면, Google·Outlook 캘린더가 "URL로 구독"으로
 * 주기적으로 받아 간다. 이 주소는 로그인 없이 열리므로 토큰이 곧 열쇠다 — 길고 무작위이며, DB에는 조회용 해시와 앱에 다시 보여 줄
 * 암호문만 둔다. 내용은 그 사람이 앱에서 보는 일정(숨긴 캘린더·공휴일·생일·외부 캘린더 제외)과 같고, 볼 때마다 다시 계산하므로
 * 팀을 떠나거나 계정이 정지되면 바로 끊긴다.
 */

export const FEED_PATH_PREFIX = '/calendar-feed/';
const TOKEN_RE = /^[a-f0-9]{48}$/;
const TOUCH_EVERY_MS = 10 * 60 * 1000;

/** 이 피드 주소 — 공인 인증서가 걸린 웹 주소가 있으면 그것(Google·Outlook이 받으려면 필요하다), 없으면 앱이 접속한 주소. */
function feedUrl(req, token) {
  const base = getWebPublicUrl() ?? `https://${req.get('host')}`;
  return `${base.replace(/\/+$/, '')}${FEED_PATH_PREFIX}${token}.ics`;
}

function toFeedDto(req, row) {
  if (!row) return { url: null, publicAddress: getWebPublicUrl() != null };
  return {
    url: feedUrl(req, decryptField(row.tokenEnc)),
    publicAddress: getWebPublicUrl() != null,
    createdAt: row.createdAt.getTime(),
    lastAccessAt: row.lastAccessAt ? row.lastAccessAt.getTime() : null,
  };
}

/** 로그인한 사람이 자기 피드 주소를 보고·만들고(다시 만들면 예전 주소는 끊긴다)·끈다. */
export function createCalendarFeedsRouter() {
  const router = Router();

  async function requireTeam(req, res) {
    if (!/^[0-9a-f-]{36}$/i.test(req.params.teamId)) {
      res.status(404).json({ error: '팀을 찾을 수 없습니다.' });
      return false;
    }
    const team = await teamAccess(req.params.teamId, req.user.sub);
    if (!team.isMember) {
      res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
      return false;
    }
    return true;
  }

  router.get('/teams/:teamId/calendar-feed', async (req, res) => {
    if (!(await requireTeam(req, res))) return;
    res.json(toFeedDto(req, await findCalendarFeed(req.user.sub, req.params.teamId)));
  });

  router.post('/teams/:teamId/calendar-feed', async (req, res) => {
    if (!(await requireTeam(req, res))) return;
    const token = crypto.randomBytes(24).toString('hex');
    const row = await upsertCalendarFeed({
      userId: req.user.sub,
      teamId: req.params.teamId,
      tokenHash: lookupHash(token),
      tokenEnc: encryptField(token),
    });
    res.status(201).json(toFeedDto(req, row));
  });

  router.delete('/teams/:teamId/calendar-feed', async (req, res) => {
    if (!(await requireTeam(req, res))) return;
    await deleteCalendarFeed(req.user.sub, req.params.teamId);
    res.json(toFeedDto(req, null));
  });

  return router;
}

/** 로그인 없이 열리는 피드 본문(GET /calendar-feed/:token). 모르는 토큰·끊긴 사람은 모두 같은 404. */
export async function calendarFeedHandler(req, res) {
  const notFound = () => res.status(404).type('text/plain').send('Not found');
  const token = String(req.params.token ?? '').replace(/\.ics$/i, '');
  if (!TOKEN_RE.test(token)) return notFound();
  const feed = await findCalendarFeedByHash(lookupHash(token));
  if (!feed) return notFound();
  const state = await accountState(feed.userId);
  if (state.blocked) return notFound();
  const team = await teamAccess(feed.teamId, feed.userId);
  if (!team.isMember) return notFound();

  const now = Date.now();
  const { result } = await collectOccurrences({
    team,
    teamId: feed.teamId,
    userId: feed.userId,
    fromMs: now - FEED_WINDOW_PAST_MS,
    toMs: now + FEED_WINDOW_FUTURE_MS,
    builtIns: false,
    skipHidden: true,
  });
  const teamRow = await findTeamById(feed.teamId);
  const body = buildIcsFeed({
    name: `탱고톡 · ${teamRow?.name ?? '캘린더'}`,
    occurrences: sortOccurrences(result),
    nowMs: now,
  });
  if (!feed.lastAccessAt || now - feed.lastAccessAt.getTime() > TOUCH_EVERY_MS) {
    touchCalendarFeed(feed.id, new Date(now)).catch(() => {});
  }
  res.set('Content-Type', 'text/calendar; charset=utf-8');
  res.set('Content-Disposition', 'inline; filename="tangotalk.ics"');
  res.set('Cache-Control', 'private, max-age=300');
  res.send(body);
}
