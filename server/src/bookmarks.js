// 북마크 — 잔디의 북마크와 같다. 이미지·제목·링크로 이루어지고, 팀 북마크(팀 모두에게 보임)와 개인 북마크(나만 보임)가 있다.
// 한 번 만들면 종류는 못 바꾼다. 수정·삭제는 만든 사람과 팀 관리자만(개인 북마크는 본인만), 순서 변경은 팀 북마크는 팀 관리자만.
// 순수 규칙은 bookmarkRules.js, 저장은 db/queries/bookmarks.js.
import { Router } from 'express';
import { teamAccess } from './access.js';
import {
  BOOKMARK_KINDS,
  BOOKMARK_MAX_PER_KIND,
  bookmarkPermissions,
  canCreateBookmark,
  isUuid,
  normalizeHttpUrl,
  parseBookmarkBody,
  reorderIdsMatch,
} from './bookmarkRules.js';
import {
  countBookmarks,
  deleteBookmark,
  findBookmarkById,
  insertBookmark,
  listPersonalBookmarks,
  listTeamBookmarks,
  reorderBookmarks,
  updateBookmark,
} from './db/queries/bookmarks.js';
import { listTeamMemberIds } from './db/queries/teams.js';
import { fetchLinkPreview } from './linkPreview.js';
import { canManageTeam } from './permissions.js';
import { signFileUrl, toStoredUploadUrl } from './upload.js';

/** 업로드한 이미지(미서명 /uploads/ 경로)는 그때그때 서명하고, 외부 이미지 주소는 그대로 내려준다. */
function imageUrlOf(stored) {
  if (!stored) return null;
  return stored.startsWith('/uploads/') ? signFileUrl(stored) : stored;
}

function toBookmarkDto(b, perms) {
  return {
    id: b.id,
    teamId: b.teamId,
    kind: b.kind,
    title: b.title,
    url: b.url,
    imageUrl: imageUrlOf(b.imageUrl),
    position: b.position,
    creator: b.creatorId ? { id: b.creatorId, name: b.creatorName ?? '' } : null,
    canEdit: perms.canEdit,
    canReorder: perms.canReorder,
    createdAt: new Date(b.createdAt).getTime(),
    updatedAt: new Date(b.updatedAt).getTime(),
  };
}

export function createBookmarksRouter(io) {
  const router = Router();

  const canManageOf = (access) => access.isMember && canManageTeam(access);

  /** 팀 북마크는 그 팀 멤버 모두에게, 개인 북마크는 본인에게 "다시 불러와라"를 알린다. */
  async function notifyChanged({ teamId, kind, ownerId }) {
    const payload = { teamId, kind };
    if (kind === 'personal') {
      io.to(`user:${ownerId}`).emit('bookmark:changed', payload);
      return;
    }
    for (const id of await listTeamMemberIds(teamId)) io.to(`user:${id}`).emit('bookmark:changed', payload);
  }

  router.get('/bookmarks', async (req, res) => {
    const teamId = req.query.teamId;
    if (!isUuid(teamId)) return res.status(400).json({ error: 'teamId가 필요합니다.' });
    const access = await teamAccess(teamId, req.user.sub);
    if (!access.isMember) return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    const canManage = canManageOf(access);

    // 준회원도 팀 북마크를 볼 수는 있다(만들기만 정회원 이상) — 팀이 공유하는 링크 모음이라 읽기까지 막을 이유가 없다.
    const [team, personal] = await Promise.all([listTeamBookmarks(teamId), listPersonalBookmarks(teamId, req.user.sub)]);
    const dto = (list) =>
      list.map((b) => toBookmarkDto(b, bookmarkPermissions({ bookmark: b, requesterId: req.user.sub, canManage })));
    res.json({ team: dto(team), personal: dto(personal) });
  });

  router.post('/bookmarks', async (req, res) => {
    const { teamId, kind } = req.body ?? {};
    if (!isUuid(teamId)) return res.status(400).json({ error: 'teamId가 필요합니다.' });
    if (!BOOKMARK_KINDS.includes(kind)) return res.status(400).json({ error: '북마크 종류가 올바르지 않습니다.' });
    const access = await teamAccess(teamId, req.user.sub);
    if (!access.isMember) return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    if (!canCreateBookmark({ kind, role: access.role, isMember: access.isMember })) {
      return res.status(403).json({ error: '준회원은 팀 북마크를 만들 수 없습니다. 개인 북마크를 이용하세요.' });
    }
    const parsed = parseBookmarkBody(req.body, { toUpload: toStoredUploadUrl });
    if (!parsed.ok) return res.status(400).json({ error: parsed.error });
    if ((await countBookmarks(teamId, kind, req.user.sub)) >= BOOKMARK_MAX_PER_KIND) {
      return res.status(400).json({ error: `북마크는 한 종류에 ${BOOKMARK_MAX_PER_KIND}개까지 만들 수 있습니다.` });
    }

    const row = await insertBookmark({ teamId, kind, ownerId: req.user.sub, creatorId: req.user.sub, ...parsed.fields });
    const created = await findBookmarkById(row.id);
    notifyChanged(created).catch(() => {});
    const perms = bookmarkPermissions({ bookmark: created, requesterId: req.user.sub, canManage: canManageOf(access) });
    res.status(201).json(toBookmarkDto(created, perms));
  });

  /** 링크 정보 가져오기 — 주소의 제목·대표 이미지·사이트 이름. 사설 주소 차단(SSRF 방어)은 fetchLinkPreview가 한다. 실패하면 빈 값. */
  router.post('/bookmarks/preview', async (req, res) => {
    const url = normalizeHttpUrl(req.body?.url);
    if (!url) return res.status(400).json({ error: 'http:// 또는 https://로 시작하는 올바른 주소를 입력하세요.' });
    const preview = await fetchLinkPreview(url);
    res.json({
      title: preview?.title ?? null,
      imageUrl: preview?.imageUrl ?? null,
      siteName: preview?.siteName ?? null,
    });
  });

  router.post('/bookmarks/reorder', async (req, res) => {
    const { teamId, kind, ids } = req.body ?? {};
    if (!isUuid(teamId)) return res.status(400).json({ error: 'teamId가 필요합니다.' });
    if (!BOOKMARK_KINDS.includes(kind)) return res.status(400).json({ error: '북마크 종류가 올바르지 않습니다.' });
    const access = await teamAccess(teamId, req.user.sub);
    if (!access.isMember) return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    if (kind === 'team' && !canManageOf(access)) {
      return res.status(403).json({ error: '팀 북마크 순서는 관리자만 바꿀 수 있습니다.' });
    }
    // 개인 북마크는 내 것만 목록에 오르므로 "현재 전체 집합"도 내 것 기준이다.
    const current = kind === 'team' ? await listTeamBookmarks(teamId) : await listPersonalBookmarks(teamId, req.user.sub);
    if (
      !reorderIdsMatch(
        ids,
        current.map((b) => b.id),
      )
    ) {
      return res.status(409).json({ error: '북마크 목록이 바뀌었습니다. 새로고침한 뒤 다시 시도하세요.' });
    }
    await reorderBookmarks(ids);
    notifyChanged({ teamId, kind, ownerId: req.user.sub }).catch(() => {});
    res.json({ ok: true });
  });

  /** 수정·삭제 공통: 북마크를 찾고 이 사람이 고칠 수 있는지 확인한다. 안 되면 응답을 보내고 null. */
  async function loadEditable(req, res) {
    if (!isUuid(req.params.id)) {
      res.status(404).json({ error: '북마크를 찾을 수 없습니다.' });
      return null;
    }
    const bookmark = await findBookmarkById(req.params.id);
    // 남의 개인 북마크는 존재 자체를 숨긴다.
    if (!bookmark || (bookmark.kind === 'personal' && bookmark.ownerId !== req.user.sub)) {
      res.status(404).json({ error: '북마크를 찾을 수 없습니다.' });
      return null;
    }
    const access = await teamAccess(bookmark.teamId, req.user.sub);
    if (!access.isMember) {
      res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
      return null;
    }
    const perms = bookmarkPermissions({ bookmark, requesterId: req.user.sub, canManage: canManageOf(access) });
    if (!perms.canEdit) {
      res.status(403).json({ error: '북마크를 만든 사람 또는 팀 관리자만 고치거나 지울 수 있습니다.' });
      return null;
    }
    return { bookmark, perms };
  }

  router.patch('/bookmarks/:id', async (req, res) => {
    const found = await loadEditable(req, res);
    if (!found) return;
    // 종류는 만든 뒤 바꿀 수 없다.
    if (req.body?.kind !== undefined && req.body.kind !== found.bookmark.kind) {
      return res.status(400).json({ error: '북마크 종류는 만든 뒤에 바꿀 수 없습니다.' });
    }
    const parsed = parseBookmarkBody(req.body, { partial: true, toUpload: toStoredUploadUrl });
    if (!parsed.ok) return res.status(400).json({ error: parsed.error });
    if (Object.keys(parsed.fields).length > 0) await updateBookmark(found.bookmark.id, parsed.fields);
    const updated = await findBookmarkById(found.bookmark.id);
    notifyChanged(updated).catch(() => {});
    res.json(toBookmarkDto(updated, found.perms));
  });

  router.delete('/bookmarks/:id', async (req, res) => {
    const found = await loadEditable(req, res);
    if (!found) return;
    await deleteBookmark(found.bookmark.id);
    notifyChanged(found.bookmark).catch(() => {});
    res.json({ ok: true });
  });

  return router;
}
