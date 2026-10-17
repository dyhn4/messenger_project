import fs from 'node:fs';
import path from 'node:path';
import { Router } from 'express';
import { teamAccess } from './access.js';
import {
  addFileVersion,
  countFilesInFolders,
  deleteFilePermanently,
  deleteFoldersPermanently,
  driveUsage,
  findFile,
  findFolder,
  findVersion,
  insertFileWithVersion,
  insertFolder,
  listFolderFiles,
  listTrashedFiles,
  listVersions,
  loadFolderMap,
  searchFiles,
  siblingNames,
  updateFile,
  updateFolder,
} from './db/queries/drive.js';
import { listTeamMemberIds } from './db/queries/teams.js';
import {
  DRIVE_DEPTH_MAX,
  DRIVE_ENTRIES_MAX,
  ancestorChain,
  breadcrumb,
  canRemoveDriveItem,
  checkFolderMove,
  descendantIds,
  drivePermissions,
  findNameClash,
  isInTrash,
  parseDriveName,
  parseVersionNote,
  sortEntries,
  subtreeDepthOf,
  uniqueName,
  versionedName,
} from './driveRules.js';
import { isUuid } from './favoritesRules.js';
import { checkFileRefs } from './fileRefs.js';
import { signFileUrl, uploadFileNameOf, uploadsDir } from './upload.js';

const ms = (d) => (d ? new Date(d).getTime() : null);
const FILE_ERROR = '파일을 확인할 수 없습니다. 파일을 다시 올려 주세요.';

/**
 * 팀 공유 드라이브 — 폴더·파일·파일 판(같은 이름으로 다시 올리면 새 판)·휴지통(규칙은 driveRules.js). 팀 멤버는 보고 내려받고, 준회원이
 * 아니면 올리고 고치고, 지우기(휴지통)·되살리기·영구 삭제는 만든 사람이나 팀 관리자. 파일은 앱이 먼저 /api/upload로 올린 뒤 그 경로를
 * 넘긴다(자기가 올린 파일만 — fileRefs.js). 바뀌면 팀 멤버에게 drive:changed `{ teamId }`.
 */
export function createDriveRouter(io) {
  const router = Router();

  /** 팀과 내 권한 — 팀 멤버가 아니면 응답하고 null. */
  async function teamCtx(req, res, teamIdInput) {
    const teamId = teamIdInput ?? req.query.teamId ?? req.body?.teamId;
    if (!isUuid(teamId)) {
      res.status(400).json({ error: '팀을 고르세요.' });
      return null;
    }
    const access = await teamAccess(teamId, req.user.sub);
    if (!access.isMember || !access.user || access.user.deletedAt || access.user.suspendedAt) {
      res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
      return null;
    }
    return { teamId, user: access.user, perms: drivePermissions(access) };
  }

  function requireWrite(res, ctx) {
    if (ctx.perms.canWrite) return true;
    res.status(403).json({ error: '준회원은 드라이브를 볼 수만 있습니다.' });
    return false;
  }

  async function broadcast(teamId) {
    for (const id of await listTeamMemberIds(teamId)) io.to(`user:${id}`).emit('drive:changed', { teamId });
  }

  const userName = (u) => u.name ?? u.username;

  function folderDto(f) {
    return { id: f.id, name: f.name, parentId: f.parentId ?? null, createdBy: f.createdBy ?? null, updatedAt: ms(f.updatedAt ?? f.createdAt) };
  }

  function fileDto(f, { withUrl = true } = {}) {
    return {
      id: f.id,
      name: f.name,
      folderId: f.folderId ?? null,
      version: f.version,
      size: f.size ?? null,
      mimeType: f.mimeType ?? null,
      createdBy: f.createdBy ?? null,
      createdAt: ms(f.createdAt),
      updatedAt: ms(f.updatedAt ?? f.createdAt),
      updatedByName: f.updatedByName ?? null,
      // 내려받기 링크 — 드라이브의 파일 이름으로 받는다.
      url: withUrl ? (signFileUrl(f.filePath, f.name) ?? null) : null,
    };
  }

  /** 올린 파일 확인 — 자기가 올린 파일만. `{ filePath, size, mimeType, originalName }` | `{ error }`. */
  async function uploadedFile(req) {
    const ref = req.body?.file;
    if (typeof ref !== 'string' || !ref) return { error: '올릴 파일을 고르세요.' };
    const checked = await checkFileRefs([ref], { senderId: req.user.sub, ownedOnly: true, error: FILE_ERROR });
    if (!checked.ok) return { error: checked.error };
    const filePath = checked.paths.get(ref);
    if (!filePath) return { error: FILE_ERROR };
    const stat = await fs.promises.stat(path.join(uploadsDir, uploadFileNameOf(filePath))).catch(() => null);
    if (!stat) return { error: FILE_ERROR };
    const mime = typeof req.body?.mimeType === 'string' ? req.body.mimeType.slice(0, 100) : null;
    const originalName = typeof req.body?.fileName === 'string' ? req.body.fileName.slice(0, 200) : null;
    return { filePath, size: stat.size, mimeType: mime, originalName };
  }

  /** 폴더 확인 — 이 팀의 휴지통 아닌 폴더(null = 맨 위). `{ folder }` | 응답하고 null. */
  function folderIn(ctx, folders, folderId, res) {
    if (folderId == null) return { folder: null };
    const folder = isUuid(folderId) ? folders.get(folderId) : null;
    if (!folder || folder.teamId !== ctx.teamId || isInTrash(folders, folder.id)) {
      res.status(404).json({ error: '폴더를 찾을 수 없습니다.' });
      return null;
    }
    return { folder };
  }

  /** 폴더 내용 `?teamId&folderId=` — 빵부스러기·하위 폴더·파일, 내 권한과 드라이브 사용량. */
  router.get('/drive', async (req, res) => {
    const ctx = await teamCtx(req, res);
    if (!ctx) return;
    const folders = await loadFolderMap(ctx.teamId);
    const found = folderIn(ctx, folders, req.query.folderId || null, res);
    if (!found) return;
    const folderId = found.folder?.id ?? null;
    const [files, usage] = await Promise.all([listFolderFiles(ctx.teamId, folderId), driveUsage(ctx.teamId)]);
    res.json({
      folder: found.folder ? folderDto(found.folder) : null,
      path: breadcrumb(folders, folderId),
      folders: sortEntries([...folders.values()].filter((f) => (f.parentId ?? null) === folderId && !f.deletedAt)).map(folderDto),
      files: sortEntries(files).map((f) => fileDto(f)),
      canWrite: ctx.perms.canWrite,
      isManager: ctx.perms.isManager,
      usageBytes: usage,
    });
  });

  /** 이름으로 찾기 `?teamId&q=` — 파일·폴더(휴지통 제외), 어느 폴더에 있는지 경로와 함께. */
  router.get('/drive/search', async (req, res) => {
    const ctx = await teamCtx(req, res);
    if (!ctx) return;
    const q = typeof req.query.q === 'string' ? req.query.q.trim() : '';
    if (!q) return res.json({ folders: [], files: [] });
    const folders = await loadFolderMap(ctx.teamId);
    const key = q.toLocaleLowerCase('ko');
    const pathText = (folderId) => breadcrumb(folders, folderId).map((p) => p.name).join(' / ');
    const files = (await searchFiles(ctx.teamId, q)).filter((f) => !isInTrash(folders, f.folderId));
    res.json({
      folders: [...folders.values()]
        .filter((f) => !isInTrash(folders, f.id) && f.name.toLocaleLowerCase('ko').includes(key))
        .slice(0, 50)
        .map((f) => ({ ...folderDto(f), path: pathText(f.parentId) })),
      files: files.map((f) => ({ ...fileDto(f), path: pathText(f.folderId) })),
    });
  });

  // ── 폴더 ──────────────────────────────────────────────────────────────

  router.post('/drive/folders', async (req, res) => {
    const ctx = await teamCtx(req, res);
    if (!ctx || !requireWrite(res, ctx)) return;
    const parsed = parseDriveName(req.body?.name, '폴더 이름');
    if (parsed.error) return res.status(400).json(parsed);
    const folders = await loadFolderMap(ctx.teamId);
    const found = folderIn(ctx, folders, req.body?.parentId ?? null, res);
    if (!found) return;
    const parentId = found.folder?.id ?? null;
    if (ancestorChain(folders, parentId).length + 1 > DRIVE_DEPTH_MAX) {
      return res.status(400).json({ error: `폴더는 ${DRIVE_DEPTH_MAX}단계까지 만들 수 있습니다.` });
    }
    const siblings = await siblingNames(ctx.teamId, parentId, folders);
    if (siblings.length >= DRIVE_ENTRIES_MAX) return res.status(400).json({ error: `한 폴더에는 ${DRIVE_ENTRIES_MAX}개까지 둘 수 있습니다.` });
    if (findNameClash(siblings, parsed.name)) return res.status(409).json({ error: `'${parsed.name}'이(가) 이미 있습니다.` });
    const folder = await insertFolder({ teamId: ctx.teamId, parentId, name: parsed.name, createdBy: ctx.user.id });
    await broadcast(ctx.teamId);
    res.status(201).json(folderDto(folder));
  });

  /** 폴더 이름 바꾸기·옮기기 `{ name?, parentId? }`(parentId null = 맨 위). */
  router.patch('/drive/folders/:id', async (req, res) => {
    const folder = isUuid(req.params.id) ? await findFolder(req.params.id) : null;
    if (!folder) return res.status(404).json({ error: '폴더를 찾을 수 없습니다.' });
    const ctx = await teamCtx(req, res, folder.teamId);
    if (!ctx || !requireWrite(res, ctx)) return;
    const folders = await loadFolderMap(ctx.teamId);
    if (isInTrash(folders, folder.id)) return res.status(409).json({ error: '휴지통에 있는 폴더입니다.' });
    const fields = {};
    let name = folder.name;
    if ('name' in (req.body ?? {})) {
      const parsed = parseDriveName(req.body.name, '폴더 이름');
      if (parsed.error) return res.status(400).json(parsed);
      name = fields.name = parsed.name;
    }
    let parentId = folder.parentId ?? null;
    if ('parentId' in (req.body ?? {})) {
      const found = folderIn(ctx, folders, req.body.parentId ?? null, res);
      if (!found) return;
      parentId = found.folder?.id ?? null;
      const moved = checkFolderMove(folders, folder.id, parentId, subtreeDepthOf(folders, folder.id));
      if (moved.error) return res.status(400).json(moved);
      fields.parentId = parentId;
    }
    if (Object.keys(fields).length === 0) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });
    if (findNameClash(await siblingNames(ctx.teamId, parentId, folders), name, folder.id)) {
      return res.status(409).json({ error: `'${name}'이(가) 이미 있습니다.` });
    }
    const updated = await updateFolder(folder.id, fields);
    await broadcast(ctx.teamId);
    res.json(folderDto(updated));
  });

  /** 폴더를 휴지통으로 — 만든 사람·관리자. 그 아래도 함께 숨는다. */
  router.delete('/drive/folders/:id', async (req, res) => {
    const folder = isUuid(req.params.id) ? await findFolder(req.params.id) : null;
    if (!folder || folder.deletedAt) return res.status(404).json({ error: '폴더를 찾을 수 없습니다.' });
    const ctx = await teamCtx(req, res, folder.teamId);
    if (!ctx) return;
    if (!canRemoveDriveItem(folder, ctx.user.id, ctx.perms)) {
      return res.status(403).json({ error: '만든 사람이나 팀 관리자만 지울 수 있습니다.' });
    }
    await updateFolder(folder.id, { deletedAt: new Date(), deletedBy: ctx.user.id });
    await broadcast(ctx.teamId);
    res.json({ ok: true });
  });

  // ── 파일 ──────────────────────────────────────────────────────────────

  /**
   * 파일 올리기 `{ teamId, folderId?, file(올린 경로), fileName, mimeType?, name?, note? }` — 같은 이름이 있으면 409와 그 파일 id
   * (`existingId` — 앱이 "새 판으로 올리기"를 묻는다).
   */
  router.post('/drive/files', async (req, res) => {
    const ctx = await teamCtx(req, res);
    if (!ctx || !requireWrite(res, ctx)) return;
    const parsed = parseDriveName(req.body?.name ?? req.body?.fileName, '파일 이름');
    if (parsed.error) return res.status(400).json(parsed);
    const note = parseVersionNote(req.body?.note);
    if (note.error) return res.status(400).json(note);
    const folders = await loadFolderMap(ctx.teamId);
    const found = folderIn(ctx, folders, req.body?.folderId ?? null, res);
    if (!found) return;
    const folderId = found.folder?.id ?? null;
    const siblings = await siblingNames(ctx.teamId, folderId, folders);
    if (siblings.length >= DRIVE_ENTRIES_MAX) return res.status(400).json({ error: `한 폴더에는 ${DRIVE_ENTRIES_MAX}개까지 둘 수 있습니다.` });
    const clash = findNameClash(siblings, parsed.name);
    if (clash) {
      const isFile = !folders.has(clash.id);
      return res.status(409).json({
        error: isFile ? `'${parsed.name}'이(가) 이미 있습니다. 새 판으로 올릴 수 있습니다.` : `같은 이름의 폴더가 있습니다: '${parsed.name}'`,
        existingId: isFile ? clash.id : null,
      });
    }
    const upload = await uploadedFile(req);
    if (upload.error) return res.status(400).json(upload);
    const file = await insertFileWithVersion(
      {
        teamId: ctx.teamId,
        folderId,
        name: parsed.name,
        filePath: upload.filePath,
        size: upload.size,
        mimeType: upload.mimeType,
        createdBy: ctx.user.id,
        updatedByName: userName(ctx.user),
      },
      {
        filePath: upload.filePath,
        originalName: upload.originalName,
        size: upload.size,
        mimeType: upload.mimeType,
        uploadedBy: ctx.user.id,
        uploaderName: userName(ctx.user),
        note: note.note,
      },
    );
    await broadcast(ctx.teamId);
    res.status(201).json(fileDto(file));
  });

  async function loadFile(req, res, { allowTrash = false } = {}) {
    const file = isUuid(req.params.id) ? await findFile(req.params.id) : null;
    if (!file) {
      res.status(404).json({ error: '파일을 찾을 수 없습니다.' });
      return null;
    }
    const ctx = await teamCtx(req, res, file.teamId);
    if (!ctx) return null;
    if (!allowTrash) {
      const folders = await loadFolderMap(ctx.teamId);
      if (file.deletedAt || isInTrash(folders, file.folderId)) {
        res.status(404).json({ error: '파일을 찾을 수 없습니다.' });
        return null;
      }
    }
    return { file, ctx };
  }

  /** 파일 하나와 판 기록(판마다 내려받기 링크). */
  router.get('/drive/files/:id', async (req, res) => {
    const found = await loadFile(req, res);
    if (!found) return;
    const { file, ctx } = found;
    const folders = await loadFolderMap(ctx.teamId);
    const versions = await listVersions(file.id);
    res.json({
      ...fileDto(file),
      path: breadcrumb(folders, file.folderId),
      canRemove: canRemoveDriveItem(file, ctx.user.id, ctx.perms),
      canWrite: ctx.perms.canWrite,
      versions: versions.map((v) => ({
        version: v.version,
        size: v.size ?? null,
        mimeType: v.mimeType ?? null,
        uploaderName: v.uploaderName,
        note: v.note ?? null,
        createdAt: ms(v.createdAt),
        // 지난 판은 "이름 (판 N).확장자"로 받는다.
        url: signFileUrl(v.filePath, v.version === file.version ? file.name : versionedName(file.name, v.version)) ?? null,
      })),
    });
  });

  /** 새 판 올리기 `{ file, fileName, mimeType?, note? }` — 이름은 그대로. */
  router.post('/drive/files/:id/versions', async (req, res) => {
    const found = await loadFile(req, res);
    if (!found) return;
    const { file, ctx } = found;
    if (!requireWrite(res, ctx)) return;
    const note = parseVersionNote(req.body?.note);
    if (note.error) return res.status(400).json(note);
    const upload = await uploadedFile(req);
    if (upload.error) return res.status(400).json(upload);
    const updated = await addFileVersion(
      file.id,
      {
        filePath: upload.filePath,
        originalName: upload.originalName,
        size: upload.size,
        mimeType: upload.mimeType,
        uploadedBy: ctx.user.id,
        uploaderName: userName(ctx.user),
        note: note.note,
      },
      { updatedByName: userName(ctx.user) },
    );
    await broadcast(ctx.teamId);
    res.status(201).json(fileDto(updated));
  });

  /** 지난 판 되돌리기 — 그 판을 새 판으로 다시 올린다(기록은 그대로 남는다). */
  router.post('/drive/files/:id/versions/:version/restore', async (req, res) => {
    const found = await loadFile(req, res);
    if (!found) return;
    const { file, ctx } = found;
    if (!requireWrite(res, ctx)) return;
    const n = Number(req.params.version);
    const old = Number.isInteger(n) ? await findVersion(file.id, n) : null;
    if (!old) return res.status(404).json({ error: '그 판을 찾을 수 없습니다.' });
    if (old.version === file.version) return res.status(400).json({ error: '이미 지금 판입니다.' });
    const updated = await addFileVersion(
      file.id,
      {
        filePath: old.filePath,
        originalName: old.originalName,
        size: old.size,
        mimeType: old.mimeType,
        uploadedBy: ctx.user.id,
        uploaderName: userName(ctx.user),
        note: `판 ${old.version}로 되돌림`,
      },
      { updatedByName: userName(ctx.user) },
    );
    await broadcast(ctx.teamId);
    res.json(fileDto(updated));
  });

  /** 파일 이름 바꾸기·옮기기 `{ name?, folderId? }`(folderId null = 맨 위). */
  router.patch('/drive/files/:id', async (req, res) => {
    const found = await loadFile(req, res);
    if (!found) return;
    const { file, ctx } = found;
    if (!requireWrite(res, ctx)) return;
    const fields = {};
    let name = file.name;
    if ('name' in (req.body ?? {})) {
      const parsed = parseDriveName(req.body.name, '파일 이름');
      if (parsed.error) return res.status(400).json(parsed);
      name = fields.name = parsed.name;
    }
    const folders = await loadFolderMap(ctx.teamId);
    let folderId = file.folderId ?? null;
    if ('folderId' in (req.body ?? {})) {
      const target = folderIn(ctx, folders, req.body.folderId ?? null, res);
      if (!target) return;
      folderId = fields.folderId = target.folder?.id ?? null;
    }
    if (Object.keys(fields).length === 0) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });
    if (findNameClash(await siblingNames(ctx.teamId, folderId, folders), name, file.id)) {
      return res.status(409).json({ error: `'${name}'이(가) 이미 있습니다.` });
    }
    const updated = await updateFile(file.id, fields);
    await broadcast(ctx.teamId);
    res.json(fileDto(updated));
  });

  router.delete('/drive/files/:id', async (req, res) => {
    const found = await loadFile(req, res);
    if (!found) return;
    const { file, ctx } = found;
    if (!canRemoveDriveItem(file, ctx.user.id, ctx.perms)) {
      return res.status(403).json({ error: '만든 사람이나 팀 관리자만 지울 수 있습니다.' });
    }
    await updateFile(file.id, { deletedAt: new Date(), deletedBy: ctx.user.id });
    await broadcast(ctx.teamId);
    res.json({ ok: true });
  });

  // ── 휴지통 ────────────────────────────────────────────────────────────

  /** 휴지통 — 직접 지운 폴더·파일(지운 폴더 안의 것은 그 폴더와 함께 되살아난다). */
  router.get('/drive/trash', async (req, res) => {
    const ctx = await teamCtx(req, res);
    if (!ctx) return;
    const folders = await loadFolderMap(ctx.teamId);
    // 위 폴더가 이미 휴지통에 있으면 따로 보이지 않는다(그 폴더를 되살리면 같이 돌아온다).
    const parentTrashed = (folderId) => isInTrash(folders, folderId);
    const trashedFolders = [...folders.values()].filter((f) => f.deletedAt && !parentTrashed(f.parentId));
    const files = (await listTrashedFiles(ctx.teamId)).filter((f) => !parentTrashed(f.folderId));
    const pathText = (folderId) => breadcrumb(folders, folderId).map((p) => p.name).join(' / ');
    res.json({
      folders: trashedFolders.map((f) => ({ ...folderDto(f), deletedAt: ms(f.deletedAt), path: pathText(f.parentId) })),
      files: files.map((f) => ({ ...fileDto(f, { withUrl: false }), deletedAt: ms(f.deletedAt), path: pathText(f.folderId) })),
      isManager: ctx.perms.isManager,
    });
  });

  /**
   * 되살리기 `{ kind: 'folder'|'file', id }` — 원래 자리가 없어졌거나(위 폴더도 휴지통) 같은 이름이 생겼으면 맨 위로·"이름 (2)"로.
   */
  router.post('/drive/trash/restore', async (req, res) => {
    const kind = req.body?.kind === 'folder' ? 'folder' : 'file';
    const id = req.body?.id;
    const item = isUuid(id) ? await (kind === 'folder' ? findFolder(id) : findFile(id)) : null;
    if (!item || !item.deletedAt) return res.status(404).json({ error: '휴지통에서 찾을 수 없습니다.' });
    const ctx = await teamCtx(req, res, item.teamId);
    if (!ctx) return;
    if (!canRemoveDriveItem(item, ctx.user.id, ctx.perms)) {
      return res.status(403).json({ error: '만든 사람이나 팀 관리자만 되살릴 수 있습니다.' });
    }
    const folders = await loadFolderMap(ctx.teamId);
    const parentKey = kind === 'folder' ? 'parentId' : 'folderId';
    let parentId = item[parentKey] ?? null;
    if (parentId && isInTrash(folders, parentId)) parentId = null;
    const name = uniqueName(item.name, await siblingNames(ctx.teamId, parentId, folders));
    const fields = { deletedAt: null, deletedBy: null, name, [parentKey]: parentId };
    const restored = kind === 'folder' ? await updateFolder(item.id, fields) : await updateFile(item.id, fields);
    await broadcast(ctx.teamId);
    res.json(kind === 'folder' ? folderDto(restored) : fileDto(restored));
  });

  /** 영구 삭제 — 만든 사람·관리자. 폴더면 그 아래 폴더·파일도 모두. */
  router.delete('/drive/trash/:kind/:id', async (req, res) => {
    const kind = req.params.kind === 'folder' ? 'folder' : 'file';
    const item = isUuid(req.params.id) ? await (kind === 'folder' ? findFolder(req.params.id) : findFile(req.params.id)) : null;
    if (!item || !item.deletedAt) return res.status(404).json({ error: '휴지통에서 찾을 수 없습니다.' });
    const ctx = await teamCtx(req, res, item.teamId);
    if (!ctx) return;
    if (!canRemoveDriveItem(item, ctx.user.id, ctx.perms)) {
      return res.status(403).json({ error: '만든 사람이나 팀 관리자만 영구 삭제할 수 있습니다.' });
    }
    if (kind === 'folder') {
      const folders = await loadFolderMap(ctx.teamId);
      const ids = descendantIds(folders, item.id);
      const files = await countFilesInFolders(ids);
      await deleteFoldersPermanently(ids);
      await broadcast(ctx.teamId);
      return res.json({ ok: true, folders: ids.length, files });
    }
    await deleteFilePermanently(item.id);
    await broadcast(ctx.teamId);
    res.json({ ok: true, folders: 0, files: 1 });
  });

  return router;
}
