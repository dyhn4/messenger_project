import { Router } from 'express';
import { topicAccess } from './access.js';
import {
  ALBUM_DELETE_MAX,
  ALBUM_SHARE_MAX,
  albumRoomDenial,
  albumShareTargetDenial,
  albumWriteDenial,
  canBeCover,
  canDeleteAlbum,
  canDeleteAlbumItem,
  canEditAlbum,
  isUuid,
  parseAlbumFields,
  parseAlbumItems,
  parseAlbumListQuery,
  parseItemIds,
  parseItemsQuery,
  partitionDeletableItems,
  shareMessageType,
  toShareAttachment,
} from './albumRules.js';
import {
  countAlbumItems,
  countItemsByAlbum,
  deleteAlbum,
  deleteAlbumItems,
  findAlbumById,
  findCoverItems,
  findItemsByIds,
  insertAlbum,
  insertAlbumItems,
  listAlbumItems,
  listAlbumsForUser,
  updateAlbum,
} from './db/queries/albums.js';
import { findRoomById, getDmHistoryFloor, isRoomMember } from './db/queries/rooms.js';
import { isTeamMember } from './db/queries/teams.js';
import { findUserById } from './db/queries/users.js';
import { roomDisplayName } from './rooms.js';
import { sendUserMessage } from './sendMessage.js';
import { resolveRawUrl, signFileUrl } from './upload.js';

/** 항목 한 건의 DTO — 파일·썸네일은 짧게 만료되는 서명 링크로(DB에는 항상 원본 경로). [perms.canDelete]는 보는 사람 기준. */
export function toAlbumItemDto(item, { uploaderName = null, canDelete = false } = {}) {
  return {
    id: item.id,
    albumId: item.albumId,
    uploaderId: item.uploaderId ?? null,
    uploaderName,
    kind: item.kind,
    fileUrl: signFileUrl(item.fileUrl, item.fileName),
    fileName: item.fileName ?? null,
    fileSize: item.fileSize ?? null,
    mimeType: item.mimeType ?? null,
    thumbnailUrl: signFileUrl(item.thumbnailUrl),
    width: item.width ?? null,
    height: item.height ?? null,
    durationMs: item.durationMs ?? null,
    createdAt: new Date(item.createdAt).getTime(),
    canDelete,
  };
}

/** 앨범 한 건의 DTO — 대표 이미지는 서명된 썸네일(없으면 이미지 원본). 권한 플래그([perms])는 상세에서만 채운다. */
export function toAlbumDto(album, { roomName, itemCount, cover, creatorName, perms = null }) {
  const coverSource = cover ? (cover.thumbnailUrl ?? (cover.kind === 'image' ? cover.fileUrl : null)) : null;
  return {
    id: album.id,
    teamId: album.teamId,
    roomId: album.roomId,
    roomName: roomName ?? null,
    creatorId: album.creatorId ?? null,
    creatorName: creatorName ?? null,
    title: album.title,
    description: album.description ?? null,
    coverItemId: cover?.id ?? null,
    coverUrl: coverSource ? signFileUrl(coverSource) : null,
    itemCount,
    createdAt: new Date(album.createdAt).getTime(),
    updatedAt: new Date(album.updatedAt).getTime(),
    ...(perms ?? {}),
  };
}

async function creatorNameOf(creatorId) {
  if (!creatorId) return null;
  const u = await findUserById(creatorId);
  return u?.name ?? u?.username ?? null;
}

/**
 * 앨범 — 대화방 안에서 이미지·GIF·영상을 주제별로 모으는 공간(잔디 '앨범'). 대화방 파일과 자동 연동이 없는
 * 독립 저장소이고 그 방의 멤버가 본다. 항목은 /api/upload로 올린 파일을 참조만 한다(복사 없음).
 * 변경은 소켓 `album:changed`로 그 방 멤버에게 알린다. 방 시스템 메시지는 남기지 않는다.
 */
export function createAlbumsRouter(io) {
  const router = Router();

  function notifyChanged(album, kind) {
    io.to(album.roomId).emit('album:changed', { teamId: album.teamId, roomId: album.roomId, albumId: album.id, kind });
  }

  /** 앨범 + 방 + 내 권한까지 한 번에. 통과하면 { album, room, access }. 멤버가 아니거나 DM 기록 하한 이전이면 거절. */
  async function requireAlbumMember(req, res) {
    const album = isUuid(req.params.id) ? await findAlbumById(req.params.id.toLowerCase()) : null;
    const room = album ? await findRoomById(album.roomId) : null;
    if (!album || !room || room.isSecret) {
      res.status(404).json({ error: '앨범을 찾을 수 없습니다.' });
      return null;
    }
    if (!(await isRoomMember(room.id, req.user.sub))) {
      res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
      return null;
    }
    const floor = await getDmHistoryFloor(room.id, req.user.sub);
    if (floor && new Date(album.createdAt) < new Date(floor)) {
      res.status(404).json({ error: '앨범을 찾을 수 없습니다.' });
      return null;
    }
    return { album, room, access: await topicAccess(room, req.user.sub) };
  }

  /** 읽기 전용·보관 토픽 + 팀 탈퇴 확인 — 앨범을 만들거나 파일을 올리는 쪽에서만 부른다. 막으면 응답까지 보내고 false. */
  function checkCanWrite(res, room, access) {
    if (!access.isMember) {
      res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
      return false;
    }
    const denial = albumWriteDenial({ room, canManage: access.canManage });
    if (denial) {
      res.status(403).json({ error: denial });
      return false;
    }
    return true;
  }

  async function detailDto(album, room, access, userId) {
    const [itemCount, covers, creatorName, roomName] = await Promise.all([
      countAlbumItems(album.id),
      findCoverItems([album]),
      creatorNameOf(album.creatorId),
      roomDisplayName(room, userId),
    ]);
    return toAlbumDto(album, {
      roomName,
      itemCount,
      cover: covers.get(album.id),
      creatorName,
      perms: {
        canEdit: canEditAlbum({ album, userId, access }),
        canDelete: canDeleteAlbum({ album, userId, access }),
        // 항목을 지우는 쪽 "전부 가능" 여부 — 앨범 만든 사람·팀 관리자(그 밖에는 항목마다 canDelete를 본다).
        canDeleteAnyItem: canDeleteAlbumItem({ album, item: { uploaderId: null }, userId, access }),
      },
    });
  }

  router.post('/rooms/:roomId/albums', async (req, res) => {
    const room = await findRoomById(req.params.roomId);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    if (!(await isRoomMember(room.id, req.user.sub))) {
      return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
    }
    const roomDenial = albumRoomDenial(room);
    if (roomDenial) return res.status(400).json({ error: roomDenial });
    const access = await topicAccess(room, req.user.sub);
    if (!checkCanWrite(res, room, access)) return;
    const fields = parseAlbumFields(req.body);
    if (fields.error) return res.status(400).json({ error: fields.error });

    const album = await insertAlbum({
      teamId: room.teamId,
      roomId: room.id,
      creatorId: req.user.sub,
      title: fields.title,
      description: fields.description,
    });
    notifyChanged(album, 'created');
    res.status(201).json(await detailDto(album, room, access, req.user.sub));
  });

  router.get('/albums', async (req, res) => {
    const q = parseAlbumListQuery(req.query);
    if (q.error) return res.status(400).json({ error: q.error });
    if (!(await isTeamMember(q.teamId, req.user.sub))) {
      return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    }
    const rows = await listAlbumsForUser({ userId: req.user.sub, teamId: q.teamId, roomId: q.roomId, before: q.before, limit: q.limit + 1 });
    const hasMore = rows.length > q.limit;
    const page = rows.slice(0, q.limit);
    const albumRows = page.map((r) => r.album);
    const [counts, covers] = await Promise.all([countItemsByAlbum(albumRows.map((a) => a.id)), findCoverItems(albumRows)]);
    const roomNames = new Map();
    for (const r of page) {
      if (!roomNames.has(r.room.id)) roomNames.set(r.room.id, await roomDisplayName(r.room, req.user.sub));
    }
    const creatorNames = new Map();
    for (const a of albumRows) {
      if (a.creatorId && !creatorNames.has(a.creatorId)) creatorNames.set(a.creatorId, await creatorNameOf(a.creatorId));
    }
    res.json({
      albums: page.map((r) =>
        toAlbumDto(r.album, {
          roomName: roomNames.get(r.room.id),
          itemCount: counts.get(r.album.id) ?? 0,
          cover: covers.get(r.album.id),
          creatorName: creatorNames.get(r.album.creatorId),
        }),
      ),
      hasMore,
    });
  });

  router.get('/albums/:id', async (req, res) => {
    const ctx = await requireAlbumMember(req, res);
    if (!ctx) return;
    res.json(await detailDto(ctx.album, ctx.room, ctx.access, req.user.sub));
  });

  router.get('/albums/:id/items', async (req, res) => {
    const ctx = await requireAlbumMember(req, res);
    if (!ctx) return;
    const q = parseItemsQuery(req.query);
    if (q.error) return res.status(400).json({ error: q.error });
    const rows = await listAlbumItems(ctx.album.id, { before: q.before, limit: q.limit + 1 });
    const hasMore = rows.length > q.limit;
    res.json({
      items: rows.slice(0, q.limit).map((r) =>
        toAlbumItemDto(r.item, {
          uploaderName: r.uploaderName ?? r.uploaderUsername ?? null,
          canDelete: canDeleteAlbumItem({ album: ctx.album, item: r.item, userId: req.user.sub, access: ctx.access }),
        }),
      ),
      hasMore,
    });
  });

  router.post('/albums/:id/items', async (req, res) => {
    const ctx = await requireAlbumMember(req, res);
    if (!ctx) return;
    if (!checkCanWrite(res, ctx.room, ctx.access)) return;
    const parsed = parseAlbumItems(req.body, resolveRawUrl);
    if (parsed.error) return res.status(400).json({ error: parsed.error });
    const rows = await insertAlbumItems(ctx.album.id, req.user.sub, parsed.items);
    notifyChanged(ctx.album, 'items');
    const uploader = await findUserById(req.user.sub);
    res.status(201).json({
      items: rows.map((item) =>
        toAlbumItemDto(item, { uploaderName: uploader?.name ?? uploader?.username ?? null, canDelete: true }),
      ),
    });
  });

  router.patch('/albums/:id', async (req, res) => {
    const ctx = await requireAlbumMember(req, res);
    if (!ctx) return;
    const { album, room, access } = ctx;
    if (!canEditAlbum({ album, userId: req.user.sub, access })) {
      return res.status(403).json({ error: '앨범을 만든 사람이나 관리자만 고칠 수 있습니다.' });
    }
    const fields = parseAlbumFields(req.body, { partial: true });
    if (fields.error) return res.status(400).json({ error: fields.error });
    if (req.body?.coverItemId !== undefined) {
      if (req.body.coverItemId === null) {
        fields.coverItemId = null;
      } else {
        const [item] = isUuid(req.body.coverItemId) ? await findItemsByIds(album.id, [req.body.coverItemId.toLowerCase()]) : [];
        if (!item) return res.status(400).json({ error: '이 앨범의 항목이 아닙니다.' });
        if (!canBeCover(item)) return res.status(400).json({ error: '대표 이미지는 사진이나 썸네일이 있는 영상만 정할 수 있습니다.' });
        fields.coverItemId = item.id;
      }
    }
    if (Object.keys(fields).length === 0) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });
    const updated = await updateAlbum(album.id, fields);
    notifyChanged(updated, 'updated');
    res.json(await detailDto(updated, room, access, req.user.sub));
  });

  router.delete('/albums/:id', async (req, res) => {
    const ctx = await requireAlbumMember(req, res);
    if (!ctx) return;
    if (!canDeleteAlbum({ album: ctx.album, userId: req.user.sub, access: ctx.access })) {
      return res.status(403).json({ error: '앨범을 만든 사람이나 팀 관리자만 지울 수 있습니다.' });
    }
    await deleteAlbum(ctx.album.id);
    notifyChanged(ctx.album, 'deleted');
    res.json({ ok: true });
  });

  router.delete('/albums/:id/items', async (req, res) => {
    const ctx = await requireAlbumMember(req, res);
    if (!ctx) return;
    const parsed = parseItemIds(req.body?.itemIds, { max: ALBUM_DELETE_MAX });
    if (parsed.error) return res.status(400).json({ error: parsed.error });
    const found = await findItemsByIds(ctx.album.id, parsed.ids);
    const { allowed, skipped } = partitionDeletableItems({
      album: ctx.album,
      items: found,
      userId: req.user.sub,
      access: ctx.access,
    });
    const removed = allowed.length > 0 ? await deleteAlbumItems(ctx.album.id, allowed.map((i) => i.id)) : [];
    if (removed.length > 0) notifyChanged(ctx.album, 'items');
    res.json({ deleted: removed.length, skipped: skipped.length, deletedIds: removed.map((i) => i.id) });
  });

  router.post('/albums/:id/share', async (req, res) => {
    const ctx = await requireAlbumMember(req, res);
    if (!ctx) return;
    const roomId = typeof req.body?.roomId === 'string' ? req.body.roomId : '';
    const target = roomId ? await findRoomById(roomId) : null;
    if (!target) return res.status(404).json({ error: '공유할 방을 찾을 수 없습니다.' });
    if (!(await isRoomMember(target.id, req.user.sub))) {
      return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
    }
    if (target.teamId !== ctx.album.teamId) {
      return res.status(400).json({ error: '같은 팀의 대화방에만 공유할 수 있습니다.' });
    }
    const denial = albumShareTargetDenial(target);
    if (denial) return res.status(400).json({ error: denial });
    const parsed = parseItemIds(req.body?.itemIds, {
      max: ALBUM_SHARE_MAX,
      overLimitMessage: `한 번에 ${ALBUM_SHARE_MAX}개까지 공유할 수 있습니다.`,
    });
    if (parsed.error) return res.status(400).json({ error: parsed.error });
    const found = await findItemsByIds(ctx.album.id, parsed.ids);
    if (found.length !== parsed.ids.length) return res.status(404).json({ error: '앨범에서 찾을 수 없는 항목이 있습니다.' });
    const byId = new Map(found.map((i) => [i.id, i]));
    const ordered = parsed.ids.map((id) => byId.get(id));

    // 파일은 복사하지 않고 같은 업로드 경로를 참조한다 — 일반 첨부 메시지와 같은 규칙(읽기 전용·보관 토픽 등)을 그대로 쓴다.
    const result = await sendUserMessage({
      io,
      senderId: req.user.sub,
      room: target,
      payload: { roomId: target.id, type: shareMessageType(ordered), attachments: ordered.map(toShareAttachment) },
    });
    if (!result.ok) return res.status(result.status ?? 400).json({ error: result.error });
    res.status(201).json(result.message);
  });

  return router;
}
