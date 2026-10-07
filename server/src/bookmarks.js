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
import { checkFileRefs } from './fileRefs.js';
import { fileRefPath } from './fileRefRules.js';
import { fetchLinkPreview } from './linkPreview.js';
import { isRemoteImageUrl, storePreviewImage } from './linkPreviewImage.js';
import { canManageTeam } from './permissions.js';
import { knownUploadPath, signedUploadOrNull, signFileUrl, toStoredUploadUrl, uploadFileNameOf } from './upload.js';

const IMAGE_FETCH_ERROR = '이미지를 가져오지 못했습니다. 이미지를 직접 올려 주세요.';

/**
 * 업로드한 이미지(미서명 /uploads/ 경로)만 그때그때 서명해 내려준다. 바깥 사이트 이미지 주소는 내려주지 않는다 — 넘기면 북마크를
 * 보는 팀원마다 앱이 그 사이트에 직접 접속한다(누가 언제 봤는지·공인 IP가 그 사이트에 남는다). 이 규칙 전에 저장된 바깥 주소는
 * 서버가 한 번 받아 업로드 파일로 바꿔 둔다(migrateRemoteImages).
 */
function imageUrlOf(stored) {
  return signedUploadOrNull(stored);
}

/**
 * 요청의 imageUrl을 저장할 값으로 미리 바꾼다 — `{ ok: true, body }`(imageUrl을 바꾼 본문) 또는 `{ ok: false, error }`. [current]는
 * 고칠 때 지금 저장된 값.
 *  - 안 보냈거나 지우기(null·빈 값)·문자열이 아닌 값: 그대로 둔다(parseBookmarkBody가 정하거나 거절한다).
 *  - 지금 저장된 값 그대로(화면이 들고 있던 서명 링크가 만료됐어도): 그대로 둔다.
 *  - 이 서버 파일(서명 링크·저장 경로): 직접 올린 사진이나 지금 볼 수 있는 방의 파일만(fileRefs.js) — 예전엔 알아낸 파일 이름을 그대로
 *    받아, 그 북마크를 보는 팀원 모두가 그 파일을 받을 수 있었다.
 *  - 바깥 http(s) 이미지 주소: 서버가 한 번 받아 업로드 파일로 바꾼다(linkPreviewImage.js). 받지 못하면 거절한다.
 */
async function normalizeImage(body, userId, current = null) {
  const image = body?.imageUrl;
  if (typeof image !== 'string' || image === '') return { ok: true, body };
  if (current && (image === current || knownUploadPath(image) === current)) {
    return { ok: true, body: { ...body, imageUrl: current } };
  }
  if (fileRefPath(image)) {
    const checked = await checkFileRefs([image], { senderId: userId, existing: current ? [current] : [] });
    if (!checked.ok) return { ok: false, error: checked.error };
    return { ok: true, body: { ...body, imageUrl: checked.paths.get(image) } };
  }
  const remote = image.trim();
  if (isRemoteImageUrl(remote) && normalizeHttpUrl(remote)) {
    const stored = await storePreviewImage(remote, { requesterId: userId, ownerId: userId });
    if (!stored) return { ok: false, error: IMAGE_FETCH_ERROR };
    return { ok: true, body: { ...body, imageUrl: stored } };
  }
  return { ok: true, body };
}

// 이 규칙 전에 바깥 이미지 주소로 저장된 북마크 — 목록을 보여 줄 때 서버가 그 이미지를 받아 업로드 파일로 바꾸고(받는 동안과
// 받지 못하면 이미지 없이 보인다), 바꾸면 그 북마크를 보는 사람들에게 다시 불러오라고 알린다. 하나씩 차례로 받고(동시에 여럿을
// 받으면 받기 동시 상한에 걸려 그냥 실패한다), 서버를 켜 둔 동안 북마크마다 몇 번까지만 시도한다(못 받는 바깥 주소를 목록을 볼
// 때마다 다시 찌르지 않게).
const REMOTE_IMAGE_MAX_TRIES = 3;
const remoteImageTries = new Map(); // 북마크 id → 시도 횟수
const remoteImageQueued = new Set(); // 지금 차례를 기다리는 북마크 id — 목록을 여러 번 열어도 한 번만 줄 세운다.
let remoteImageQueue = Promise.resolve();

async function migrateRemoteImage(id, notifyChanged) {
  const before = await findBookmarkById(id);
  // 그사이 고치거나 지웠으면(이미 업로드 파일이거나 이미지를 뺐으면) 할 일이 없다.
  if (!before || !isRemoteImageUrl(before.imageUrl)) return;
  // 받은 그림은 북마크를 만든 사람의 파일로 남긴다 — 그 사람이 나중에 그대로 다시 저장해도 자기 사진으로 알아보게.
  const stored = await storePreviewImage(before.imageUrl, { ownerId: before.creatorId ?? null });
  if (!stored) return;
  const fresh = await findBookmarkById(id);
  if (!fresh || fresh.imageUrl !== before.imageUrl) return;
  await updateBookmark(id, { imageUrl: stored });
  remoteImageTries.delete(id);
  await notifyChanged(fresh);
}

function migrateRemoteImages(rows, notifyChanged) {
  for (const b of rows) {
    if (!isRemoteImageUrl(b.imageUrl) || uploadFileNameOf(b.imageUrl) || remoteImageQueued.has(b.id)) continue;
    const tries = remoteImageTries.get(b.id) ?? 0;
    if (tries >= REMOTE_IMAGE_MAX_TRIES) continue;
    remoteImageTries.set(b.id, tries + 1);
    remoteImageQueued.add(b.id);
    remoteImageQueue = remoteImageQueue
      .then(() => migrateRemoteImage(b.id, notifyChanged))
      .catch((err) => console.error('[bookmarks] 바깥 이미지 옮기기 실패:', err?.message ?? err))
      .finally(() => remoteImageQueued.delete(b.id));
  }
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
    migrateRemoteImages([...team, ...personal], notifyChanged);
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
    // 개수 상한은 이미지를 받기(바깥 이미지면 서버가 내려받는다) 전에 본다.
    if ((await countBookmarks(teamId, kind, req.user.sub)) >= BOOKMARK_MAX_PER_KIND) {
      return res.status(400).json({ error: `북마크는 한 종류에 ${BOOKMARK_MAX_PER_KIND}개까지 만들 수 있습니다.` });
    }
    // 제목·주소부터 본다 — 이미지는 서버가 내려받을 수도 있어서 다른 칸이 틀린 요청에는 받지 않는다.
    const shape = parseBookmarkBody({ ...req.body, imageUrl: undefined }, { toUpload: toStoredUploadUrl });
    if (!shape.ok) return res.status(400).json({ error: shape.error });
    const image = await normalizeImage(req.body, req.user.sub);
    if (!image.ok) return res.status(400).json({ error: image.error });
    const parsed = parseBookmarkBody(image.body, { toUpload: toStoredUploadUrl });
    if (!parsed.ok) return res.status(400).json({ error: parsed.error });

    const row = await insertBookmark({ teamId, kind, ownerId: req.user.sub, creatorId: req.user.sub, ...parsed.fields });
    const created = await findBookmarkById(row.id);
    notifyChanged(created).catch(() => {});
    const perms = bookmarkPermissions({ bookmark: created, requesterId: req.user.sub, canManage: canManageOf(access) });
    res.status(201).json(toBookmarkDto(created, perms));
  });

  /**
   * 링크 정보 가져오기 — 주소의 제목·대표 이미지·사이트 이름. 사설 주소 차단(SSRF 방어)은 fetchLinkPreview가 한다. 실패하면 빈 값.
   * 대표 이미지는 바깥 주소 대신 서버가 받아 둔 업로드 파일의 서명 링크로 준다(linkPreviewImage.js — 이 사람이 올린 파일로 남겨,
   * 그대로 북마크에 저장하면 fileRefs.js가 "직접 올린 사진"으로 받는다). 예전 앱도 이 값을 그대로 저장하고 그린다(bookmark_image.dart).
   */
  router.post('/bookmarks/preview', async (req, res) => {
    const url = normalizeHttpUrl(req.body?.url);
    if (!url) return res.status(400).json({ error: 'http:// 또는 https://로 시작하는 올바른 주소를 입력하세요.' });
    const preview = await fetchLinkPreview(url);
    const image = preview?.imageUrl
      ? await storePreviewImage(preview.imageUrl, { requesterId: req.user.sub, ownerId: req.user.sub })
      : null;
    res.json({
      title: preview?.title ?? null,
      imageUrl: image ? signFileUrl(image) : null,
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
    const shape = parseBookmarkBody({ ...req.body, imageUrl: undefined }, { partial: true, toUpload: toStoredUploadUrl });
    if (!shape.ok) return res.status(400).json({ error: shape.error });
    const image = await normalizeImage(req.body, req.user.sub, found.bookmark.imageUrl);
    if (!image.ok) return res.status(400).json({ error: image.error });
    const parsed = parseBookmarkBody(image.body, { partial: true, toUpload: toStoredUploadUrl });
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
