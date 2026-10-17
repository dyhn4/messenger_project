import { Router } from 'express';
import { teamAccess } from './access.js';
import { listTeamMemberIds } from './db/queries/teams.js';
import {
  findPage,
  findVersion,
  insertPage,
  insertVersion,
  latestVersion,
  listVersions,
  loadPageMap,
  nextPosition,
  savePageBody,
  searchPages,
  updatePage,
} from './db/queries/wiki.js';
import { ancestorChain, descendantIds } from './driveRules.js';
import { isUuid } from './favoritesRules.js';
import { createWikiDocs } from './wikiDocs.js';
import {
  WIKI_DEPTH_MAX,
  canRemovePage,
  checkPageMove,
  editorColor,
  isPageInTrash,
  pageBreadcrumb,
  parseWikiBody,
  parseWikiTitle,
  searchExcerpt,
  wikiPermissions,
  wikiTree,
} from './wikiRules.js';

const ms = (d) => (d ? new Date(d).getTime() : null);

/**
 * 동시 편집 문서들(서버 하나에 하나 — REST와 소켓이 같이 쓴다). 저장은 DB, 판은 wiki_page_versions.
 */
export const wikiDocs = createWikiDocs({
  load: (pageId) => findPage(pageId),
  save: (pageId, values) => savePageBody(pageId, values),
  snapshot: (pageId, values) => insertVersion({ pageId, ...values }).then(() => {}),
  lastSnapshot: (pageId) => latestVersion(pageId),
});

/** 팀과 내 권한 — 팀 멤버가 아니면 `{ error, status }`. */
async function wikiAccess(teamId, userId) {
  const access = await teamAccess(teamId, userId);
  if (!access.isMember || !access.user || access.user.deletedAt || access.user.suspendedAt) {
    return { error: '이 팀의 멤버가 아닙니다.', status: 403 };
  }
  return { user: access.user, perms: wikiPermissions(access) };
}

const nameOf = (u) => u.name ?? u.username;

/**
 * 팀 위키 — 팀마다 페이지 나무(마크다운 본문), 여럿이 동시에 고치기(소켓 wiki:* — registerWikiSocket), 판 기록·되돌리기, 휴지통, 찾기.
 * 팀 멤버는 읽고 준회원이 아니면 만들고 고친다. 지우기·되살리기는 만든 사람이나 팀 관리자. 나무가 바뀌면 팀 멤버에게 wiki:tree.
 * 규칙은 wikiRules.js, OT는 otText.js, 메모리 문서는 wikiDocs.js.
 */
export function createWikiRouter(io) {
  const router = Router();

  async function ctxFor(req, res, teamIdInput) {
    const teamId = teamIdInput ?? req.query.teamId ?? req.body?.teamId;
    if (!isUuid(teamId)) {
      res.status(400).json({ error: '팀을 고르세요.' });
      return null;
    }
    const access = await wikiAccess(teamId, req.user.sub);
    if (access.error) {
      res.status(access.status).json({ error: access.error });
      return null;
    }
    return { teamId, ...access };
  }

  async function broadcastTree(teamId) {
    for (const id of await listTeamMemberIds(teamId)) io.to(`user:${id}`).emit('wiki:tree', { teamId });
  }

  /** 페이지와 권한 — 없거나(휴지통 포함 여부는 [allowTrash]) 팀 멤버가 아니면 응답하고 null. */
  async function loadPage(req, res, { allowTrash = false } = {}) {
    const page = isUuid(req.params.id) ? await findPage(req.params.id) : null;
    if (!page) {
      res.status(404).json({ error: '페이지를 찾을 수 없습니다.' });
      return null;
    }
    const ctx = await ctxFor(req, res, page.teamId);
    if (!ctx) return null;
    const pages = await loadPageMap(ctx.teamId);
    if (!allowTrash && isPageInTrash(pages, page.id)) {
      res.status(404).json({ error: '페이지를 찾을 수 없습니다.' });
      return null;
    }
    return { page, pages, ctx };
  }

  const pageRow = (p) => ({
    id: p.id,
    parentId: p.parentId ?? null,
    title: p.title,
    position: p.position,
    depth: p.depth ?? 0,
    createdBy: p.createdBy ?? null,
    updatedAt: ms(p.updatedAt ?? p.createdAt),
    updatedByName: p.updatedByName ?? null,
  });

  /** 페이지 나무(휴지통 제외, 위에서 아래로 펼친 차례). */
  router.get('/wiki', async (req, res) => {
    const ctx = await ctxFor(req, res);
    if (!ctx) return;
    const pages = await loadPageMap(ctx.teamId);
    res.json({ pages: wikiTree(pages).map(pageRow), canEdit: ctx.perms.canEdit, isManager: ctx.perms.isManager });
  });

  router.get('/wiki/search', async (req, res) => {
    const ctx = await ctxFor(req, res);
    if (!ctx) return;
    const q = typeof req.query.q === 'string' ? req.query.q.trim() : '';
    if (!q) return res.json([]);
    const pages = await loadPageMap(ctx.teamId);
    const rows = (await searchPages(ctx.teamId, q)).filter((p) => !isPageInTrash(pages, p.id));
    res.json(
      rows.map((p) => {
        // 편집 중인 페이지는 메모리의 최신 본문으로 미리보기.
        const live = wikiDocs.peek(p.id);
        return {
          id: p.id,
          title: live?.title ?? p.title,
          path: pageBreadcrumb(pages, p.parentId).map((x) => x.title).join(' / '),
          excerpt: searchExcerpt(live?.body ?? p.body, q),
          updatedAt: ms(p.updatedAt),
        };
      }),
    );
  });

  /** 휴지통 — 직접 지운 페이지(지운 페이지 아래 것은 함께 되살아난다). */
  router.get('/wiki/trash', async (req, res) => {
    const ctx = await ctxFor(req, res);
    if (!ctx) return;
    const pages = await loadPageMap(ctx.teamId);
    const rows = [...pages.values()]
      .filter((p) => p.deletedAt && !isPageInTrash(pages, p.parentId))
      .sort((a, b) => new Date(b.deletedAt) - new Date(a.deletedAt));
    res.json(
      rows.map((p) => ({
        ...pageRow(p),
        deletedAt: ms(p.deletedAt),
        canRemove: canRemovePage(p, ctx.user.id, ctx.perms),
      })),
    );
  });

  /** 새 페이지 `{ teamId, parentId?, title, body? }`. */
  router.post('/wiki', async (req, res) => {
    const ctx = await ctxFor(req, res);
    if (!ctx) return;
    if (!ctx.perms.canEdit) return res.status(403).json({ error: '준회원은 위키를 읽을 수만 있습니다.' });
    const title = parseWikiTitle(req.body?.title);
    if (title.error) return res.status(400).json(title);
    const body = parseWikiBody(req.body?.body);
    if (body.error) return res.status(400).json(body);
    const pages = await loadPageMap(ctx.teamId);
    const parentId = req.body?.parentId ?? null;
    if (parentId !== null) {
      const parent = isUuid(parentId) ? pages.get(parentId) : null;
      if (!parent || isPageInTrash(pages, parent.id)) return res.status(404).json({ error: '위 페이지를 찾을 수 없습니다.' });
      if (ancestorChain(pages, parent.id).length + 1 > WIKI_DEPTH_MAX) {
        return res.status(400).json({ error: `페이지는 ${WIKI_DEPTH_MAX}단계까지 둘 수 있습니다.` });
      }
    }
    const page = await insertPage({
      teamId: ctx.teamId,
      parentId,
      title: title.title,
      body: body.body,
      position: await nextPosition(ctx.teamId, parentId),
      createdBy: ctx.user.id,
      updatedByName: nameOf(ctx.user),
    });
    await broadcastTree(ctx.teamId);
    res.status(201).json(pageRow(page));
  });

  /** 페이지 하나 — 본문은 편집 중이면 메모리의 최신 것. 지금 편집 중인 사람도. */
  router.get('/wiki/:id', async (req, res) => {
    const found = await loadPage(req, res);
    if (!found) return;
    const { page, pages, ctx } = found;
    const live = wikiDocs.peek(page.id);
    res.json({
      ...pageRow(page),
      title: live?.title ?? page.title,
      body: live?.body ?? page.body,
      revision: live?.revision ?? page.revision,
      path: pageBreadcrumb(pages, page.parentId),
      canEdit: ctx.perms.canEdit,
      canRemove: canRemovePage(page, ctx.user.id, ctx.perms),
      editors: live ? wikiDocs.editors(live) : [],
    });
  });

  /** 제목 바꾸기·옮기기·순서 `{ title?, parentId?, position? }`. 제목은 편집 화면에도 바로(wiki:title). */
  router.patch('/wiki/:id', async (req, res) => {
    const found = await loadPage(req, res);
    if (!found) return;
    const { page, pages, ctx } = found;
    if (!ctx.perms.canEdit) return res.status(403).json({ error: '준회원은 위키를 읽을 수만 있습니다.' });
    const fields = {};
    if ('title' in (req.body ?? {})) {
      const title = parseWikiTitle(req.body.title);
      if (title.error) return res.status(400).json(title);
      fields.title = title.title;
    }
    if ('parentId' in (req.body ?? {})) {
      const parentId = req.body.parentId ?? null;
      if (parentId !== null) {
        const parent = isUuid(parentId) ? pages.get(parentId) : null;
        if (!parent || isPageInTrash(pages, parent.id)) return res.status(404).json({ error: '위 페이지를 찾을 수 없습니다.' });
      }
      const moved = checkPageMove(pages, page.id, parentId);
      if (moved.error) return res.status(400).json(moved);
      fields.parentId = parentId;
      if (!('position' in (req.body ?? {}))) fields.position = await nextPosition(ctx.teamId, parentId);
    }
    if ('position' in (req.body ?? {})) {
      if (!Number.isInteger(req.body.position) || req.body.position < 0) return res.status(400).json({ error: '순서가 올바르지 않습니다.' });
      fields.position = req.body.position;
    }
    if (Object.keys(fields).length === 0) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });
    const updated = await updatePage(page.id, { ...fields, updatedAt: new Date(), updatedByName: nameOf(ctx.user) });
    if (fields.title) {
      const live = wikiDocs.peek(page.id);
      if (live) live.title = fields.title;
      io.to(`wiki:${page.id}`).emit('wiki:title', { pageId: page.id, title: fields.title });
    }
    await broadcastTree(ctx.teamId);
    res.json(pageRow(updated));
  });

  /** 휴지통으로 — 만든 사람·팀 관리자. 그 아래 페이지도 함께 숨고, 편집 중인 화면은 닫힌다(wiki:removed). */
  router.delete('/wiki/:id', async (req, res) => {
    const found = await loadPage(req, res);
    if (!found) return;
    const { page, pages, ctx } = found;
    if (!canRemovePage(page, ctx.user.id, ctx.perms)) return res.status(403).json({ error: '만든 사람이나 팀 관리자만 지울 수 있습니다.' });
    await updatePage(page.id, { deletedAt: new Date(), deletedBy: ctx.user.id });
    for (const id of descendantIds(pages, page.id)) io.to(`wiki:${id}`).emit('wiki:removed', { pageId: id });
    await broadcastTree(ctx.teamId);
    res.json({ ok: true });
  });

  /** 되살리기 — 위 페이지도 휴지통이면 맨 위로. */
  router.post('/wiki/:id/restore', async (req, res) => {
    const found = await loadPage(req, res, { allowTrash: true });
    if (!found) return;
    const { page, pages, ctx } = found;
    if (!page.deletedAt) return res.status(400).json({ error: '휴지통에 있는 페이지가 아닙니다.' });
    if (!canRemovePage(page, ctx.user.id, ctx.perms)) return res.status(403).json({ error: '만든 사람이나 팀 관리자만 되살릴 수 있습니다.' });
    const parentId = page.parentId && isPageInTrash(pages, page.parentId) ? null : (page.parentId ?? null);
    const restored = await updatePage(page.id, {
      deletedAt: null,
      deletedBy: null,
      parentId,
      ...(parentId !== page.parentId ? { position: await nextPosition(ctx.teamId, parentId) } : {}),
    });
    await broadcastTree(ctx.teamId);
    res.json(pageRow(restored));
  });

  /** 판 목록(최근 것부터). */
  router.get('/wiki/:id/versions', async (req, res) => {
    const found = await loadPage(req, res);
    if (!found) return;
    const rows = await listVersions(found.page.id);
    res.json(
      rows.map((v) => ({
        id: v.id,
        revision: v.revision,
        title: v.title,
        editorNames: v.editorNames ?? null,
        size: v.size ?? 0,
        createdAt: ms(v.createdAt),
      })),
    );
  });

  router.get('/wiki/:id/versions/:versionId', async (req, res) => {
    const found = await loadPage(req, res);
    if (!found) return;
    const v = isUuid(req.params.versionId) ? await findVersion(req.params.versionId) : null;
    if (!v || v.pageId !== found.page.id) return res.status(404).json({ error: '판을 찾을 수 없습니다.' });
    res.json({ id: v.id, revision: v.revision, title: v.title, body: v.body, editorNames: v.editorNames ?? null, createdAt: ms(v.createdAt) });
  });

  /**
   * 판 되돌리기 — 지금 본문을 먼저 판으로 남기고 그 판의 본문으로 바꾼다. 편집 중인 사람에게는 보통 연산처럼 퍼진다(wiki:op).
   */
  router.post('/wiki/:id/versions/:versionId/restore', async (req, res) => {
    const found = await loadPage(req, res);
    if (!found) return;
    const { page, ctx } = found;
    if (!ctx.perms.canEdit) return res.status(403).json({ error: '준회원은 위키를 읽을 수만 있습니다.' });
    const v = isUuid(req.params.versionId) ? await findVersion(req.params.versionId) : null;
    if (!v || v.pageId !== page.id) return res.status(404).json({ error: '판을 찾을 수 없습니다.' });
    const doc = await wikiDocs.open(page.id);
    if (!doc) return res.status(404).json({ error: '페이지를 찾을 수 없습니다.' });
    await wikiDocs.flush(doc, { forceSnapshot: true });
    const { revision, op } = wikiDocs.replaceBody(doc, v.body, { userName: nameOf(ctx.user) });
    io.to(`wiki:${page.id}`).emit('wiki:op', { pageId: page.id, revision, op, opId: null, userId: ctx.user.id });
    await wikiDocs.flush(doc, { forceSnapshot: true });
    await wikiDocs.release(doc);
    res.json({ ok: true, revision });
  });

  return router;
}

/** 소켓 하나의 연산 빈도 — 10초에 300개(빠르게 쳐도 닿지 않는 값). */
const OPS_PER_WINDOW = 300;
const OPS_WINDOW_MS = 10_000;

/**
 * 위키 동시 편집 소켓 — 연결마다 socket.js가 부른다.
 *  - wiki:join `{ pageId, sinceRevision? }` → ack `{ ok, revision, title, canEdit, body | ops, editors }`. sinceRevision을 주고 그 뒤
 *    연산이 기억에 있으면 ops(그 뒤 연산들 — 앱이 확인 못 받은 내 연산도 opId로 알아본다), 아니면 body(통째로).
 *  - wiki:op `{ pageId, revision(앱이 아는 판), op, opId }` → ack `{ ok, revision }` | `{ ok: false, error, revision }`. 다른 사람에게는
 *    방(wiki:<pageId>)으로 wiki:op `{ pageId, revision, op, opId, userId }`.
 *  - wiki:cursor `{ pageId, anchor, head }` → 다른 사람에게 wiki:cursor(이름·색과 함께). wiki:leave `{ pageId }`.
 * 편집 중인 사람이 바뀌면 방에 wiki:presence `{ pageId, editors }`.
 */
export function registerWikiSocket(io, socket) {
  const userId = socket.data.userId;
  let windowStart = Date.now();
  let opsInWindow = 0;

  const room = (pageId) => `wiki:${pageId}`;

  async function presence(doc) {
    io.to(room(doc.pageId)).emit('wiki:presence', { pageId: doc.pageId, editors: wikiDocs.editors(doc) });
  }

  socket.on('wiki:join', async (payload, ack) => {
    const reply = typeof ack === 'function' ? ack : () => {};
    try {
      const pageId = payload?.pageId;
      if (!isUuid(pageId)) return reply({ ok: false, error: '페이지를 찾을 수 없습니다.' });
      const page = await findPage(pageId);
      if (!page) return reply({ ok: false, error: '페이지를 찾을 수 없습니다.' });
      const pages = await loadPageMap(page.teamId);
      if (isPageInTrash(pages, page.id)) return reply({ ok: false, error: '페이지를 찾을 수 없습니다.' });
      const access = await wikiAccess(page.teamId, userId);
      if (access.error) return reply({ ok: false, error: access.error });
      const doc = await wikiDocs.open(pageId);
      if (!doc) return reply({ ok: false, error: '페이지를 찾을 수 없습니다.' });
      const editors = wikiDocs.join(doc, socket.id, {
        userId,
        name: nameOf(access.user),
        color: editorColor(userId),
        canEdit: access.perms.canEdit,
      });
      socket.join(room(pageId));
      const since = Number.isInteger(payload?.sinceRevision) ? wikiDocs.since(doc, payload.sinceRevision) : null;
      reply({
        ok: true,
        revision: doc.revision,
        title: doc.title,
        canEdit: access.perms.canEdit,
        ...(since ? { ops: since.map((h) => ({ revision: h.revision, op: h.op, opId: h.opId })) } : { body: doc.body }),
        editors: editors.map(({ userId: id, name, color }) => ({ userId: id, name, color })),
      });
      socket.to(room(pageId)).emit('wiki:presence', {
        pageId,
        editors: editors.map(({ userId: id, name, color }) => ({ userId: id, name, color })),
      });
    } catch (err) {
      console.error('[wiki] join 실패:', err?.message ?? err);
      reply({ ok: false, error: '페이지를 열지 못했습니다.' });
    }
  });

  socket.on('wiki:op', (payload, ack) => {
    const reply = typeof ack === 'function' ? ack : () => {};
    const pageId = payload?.pageId;
    const doc = typeof pageId === 'string' ? wikiDocs.peek(pageId) : null;
    const member = doc?.members.get(socket.id);
    if (!doc || !member) return reply({ ok: false, error: 'not_joined' });
    if (!member.canEdit) return reply({ ok: false, error: 'read_only', revision: doc.revision });
    const now = Date.now();
    if (now - windowStart > OPS_WINDOW_MS) {
      windowStart = now;
      opsInWindow = 0;
    }
    opsInWindow += 1;
    if (opsInWindow > OPS_PER_WINDOW) return reply({ ok: false, error: 'too_fast', revision: doc.revision });
    const result = wikiDocs.receive(doc, {
      baseRevision: payload.revision,
      op: payload.op,
      opId: typeof payload.opId === 'string' ? payload.opId.slice(0, 64) : null,
      userId,
      userName: member.name,
    });
    if (result.error) return reply({ ok: false, error: result.error, revision: doc.revision });
    reply({ ok: true, revision: result.revision });
    if (!result.duplicate) {
      socket.to(room(pageId)).emit('wiki:op', { pageId, revision: result.revision, op: result.op, opId: payload.opId ?? null, userId });
    }
  });

  socket.on('wiki:cursor', (payload) => {
    const pageId = payload?.pageId;
    const doc = typeof pageId === 'string' ? wikiDocs.peek(pageId) : null;
    const member = doc?.members.get(socket.id);
    if (!member || !Number.isInteger(payload.anchor) || !Number.isInteger(payload.head)) return;
    socket.to(room(pageId)).emit('wiki:cursor', {
      pageId,
      userId,
      name: member.name,
      color: member.color,
      revision: doc.revision,
      anchor: payload.anchor,
      head: payload.head,
    });
  });

  async function leaveDoc(doc) {
    socket.leave(room(doc.pageId));
    await wikiDocs.leave(doc, socket.id);
    await presence(doc);
  }

  socket.on('wiki:leave', async (payload) => {
    const doc = typeof payload?.pageId === 'string' ? wikiDocs.peek(payload.pageId) : null;
    if (doc?.members.has(socket.id)) await leaveDoc(doc).catch((e) => console.error('[wiki] 나가기 실패:', e?.message ?? e));
  });

  socket.on('disconnect', () => {
    for (const doc of wikiDocs.docsOfSocket(socket.id)) {
      leaveDoc(doc).catch((e) => console.error('[wiki] 끊김 정리 실패:', e?.message ?? e));
    }
  });
}
