import fs from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { simpleParser } from 'mailparser';
import { MAIL_STORE_DIR } from './config.js';
import {
  deleteLocalFolder,
  deleteLocalMessages,
  findLocalMessage,
  insertLocalFolder,
  insertLocalMessage,
  listLocalFolders,
  listExpiredTrash,
  listLocalMessages,
  listLocalMessagesByUid,
  localFolderCounts,
  localFolderMessageCount,
  localInboxUnseen,
  localQuotaUsed,
  recentLocalMessages,
  renameLocalFolder,
  updateLocalMessages,
} from './db/queries/localMail.js';
import { isFormatPart } from './mailFormatHtml.js';
import {
  flagSetOf,
  isLocalSystemFolder,
  LOCAL_FOLDERS,
  LOCAL_TRASH_DAYS,
  localFolderEntries,
  localSummaryOf,
  searchTextOf,
} from './localMailRules.js';
import { LIST_LIMIT_MAX, MESSAGE_BYTES_MAX, messageIdsIn, parseFolderName, SEARCH_MAX } from './webmailRules.js';

/**
 * 회사 메일함 — 자체 메일 서버가 받은 메일과 회사 메일함에서 보낸·임시 저장한 메일. 원문(.eml)은 디스크(MAIL_STORE_DIR/<계정 id>/)에,
 * 목록·찾기에 쓰는 겉봉과 플래그는 DB(local_mail_messages)에 둔다. 웹메일 API(webmail.js)는 IMAP 계정과 똑같은 모양으로 쓴다
 * (webmailBackend.js). 메일함 크기는 관리자가 정한 상한(server_settings.localMailQuotaMb)까지.
 */

const dirOf = (accountId) => path.join(MAIL_STORE_DIR, path.basename(String(accountId)));
const fileOf = (accountId, fileName) => path.join(dirOf(accountId), path.basename(fileName));

/** 메일함이 가득 찼을 때(받는 쪽은 452, 보내기·임시 저장은 400). */
export class LocalQuotaError extends Error {
  constructor() {
    super('메일함이 가득 찼습니다. 오래된 메일을 지우세요.');
    this.code = 'QUOTA';
  }
}

/** 기본 폴더인지(받은 메일·보낸 메일·임시 저장을 넣는 곳 — 사람이 만든 폴더는 옮기기로만 들어간다). */
const isFolder = (folder) => LOCAL_FOLDERS.includes(folder);

/** 이 계정의 폴더 이름들 — 기본 폴더와 사람이 만든 폴더. */
export async function localFolderNames(accountId) {
  return [...LOCAL_FOLDERS, ...(await listLocalFolders(accountId))];
}

/** 이 계정에 [folder]가 있는지(기본 폴더이거나 사람이 만든 폴더). */
export async function localHasFolder(accountId, folder) {
  return isFolder(folder) || (typeof folder === 'string' && (await listLocalFolders(accountId)).includes(folder));
}

function folderError(message) {
  const e = new Error(message);
  e.code = 'FOLDER';
  return e;
}

/**
 * 메일함에 넣는다 — 원문을 풀어 겉봉을 뽑고, 파일로 쓴 뒤 표에 남긴다. `{ uid, parsed, row }`. [quotaBytes]를 넘으면 LocalQuotaError.
 * [parsed]를 이미 풀어 왔으면 그대로 쓴다. [auth]는 자체 메일 서버가 받을 때 본 보낸 쪽 확인 결과(localMailAuth.js — 읽기 화면의 경고).
 */
export async function storeLocalMessage(
  accountId,
  raw,
  { folder = 'INBOX', seen = false, draft = false, answered = false, quotaBytes = null, parsed = null, auth = null } = {},
) {
  if (!isFolder(folder)) throw new Error('폴더를 확인하세요.');
  const bytes = Buffer.isBuffer(raw) ? raw : Buffer.from(raw);
  if (quotaBytes != null && (await localQuotaUsed(accountId)) + bytes.length > quotaBytes) throw new LocalQuotaError();
  const p = parsed ?? (await simpleParser(bytes, { skipImageLinks: true }));
  await fs.mkdir(dirOf(accountId), { recursive: true });
  const fileName = `${randomUUID()}.eml`;
  const filePath = fileOf(accountId, fileName);
  await fs.writeFile(filePath, bytes);
  const people = (v) => (v?.value ?? []).map((a) => ({ name: (a.name ?? '').slice(0, 100), address: (a.address ?? '').slice(0, 200) })).slice(0, 100);
  const from = p.from?.value?.[0];
  try {
    const row = await insertLocalMessage({
      accountId,
      folder,
      seen,
      draft,
      answered,
      subject: (p.subject ?? '').slice(0, 1000),
      fromName: (from?.name ?? '').slice(0, 200),
      fromAddress: (from?.address ?? '').slice(0, 200),
      toList: people(p.to),
      ccList: people(p.cc),
      sentAt: p.date && !Number.isNaN(p.date.getTime()) ? p.date : null,
      size: bytes.length,
      hasAttachments: (p.attachments ?? []).some((a) => (a.contentDisposition !== 'inline' || !!a.filename) && !isFormatPart(a)),
      messageId: p.messageId ? String(p.messageId).slice(0, 500) : null,
      inReplyTo: messageIdsIn(p.inReplyTo, 1)[0] ?? null,
      references: messageIdsIn(p.references),
      auth,
      searchText: searchTextOf(p),
      fileName,
    });
    return { uid: row.uid, parsed: p, row };
  } catch (err) {
    await fs.unlink(filePath).catch(() => {});
    throw err;
  }
}

/** 폴더 목록(imapflow list 모양 — webmailRules.js folderList가 이름을 붙인다). */
export async function localListFolders(accountId) {
  const [counts, custom] = await Promise.all([localFolderCounts(accountId), listLocalFolders(accountId)]);
  return localFolderEntries(counts, custom);
}

/** 폴더 만들기(맨 위에만 — 회사 메일함은 하위 폴더가 없다). 만든 이름. */
export async function localCreateFolder(accountId, raw) {
  const parsed = parseFolderName(raw);
  if (parsed.error) throw folderError(parsed.error);
  if (isLocalSystemFolder(parsed.name) || !(await insertLocalFolder(accountId, parsed.name))) throw folderError('같은 이름의 폴더가 이미 있습니다.');
  return parsed.name;
}

/** 사람이 만든 폴더의 이름 바꾸기 — 그 폴더의 메일도 같이 옮겨 적는다. → `{ from, to, delimiter }`. */
export async function localRenameFolder(accountId, from, raw) {
  if (isFolder(from)) throw folderError('기본 폴더는 이름을 바꾸거나 지울 수 없습니다.');
  const parsed = parseFolderName(raw);
  if (parsed.error) throw folderError(parsed.error);
  const to = parsed.name;
  if (to === from) return { from, to, delimiter: '/' };
  const others = (await listLocalFolders(accountId)).filter((n) => n !== from);
  if (isLocalSystemFolder(to) || others.some((n) => n.toLowerCase() === to.toLowerCase())) throw folderError('같은 이름의 폴더가 이미 있습니다.');
  if (!(await renameLocalFolder(accountId, from, to))) throw folderError('폴더를 찾을 수 없습니다. 다른 곳에서 바꿨을 수 있습니다.');
  return { from, to, delimiter: '/' };
}

/** 사람이 만든 폴더 지우기 — 비어 있을 때만. */
export async function localDeleteFolder(accountId, folder) {
  if (isFolder(folder)) throw folderError('기본 폴더는 이름을 바꾸거나 지울 수 없습니다.');
  if ((await localFolderMessageCount(accountId, folder)) > 0) throw folderError('메일이 들어 있는 폴더는 지울 수 없습니다. 메일을 먼저 옮기거나 지우세요.');
  if (!(await deleteLocalFolder(accountId, folder))) throw folderError('폴더를 찾을 수 없습니다. 다른 곳에서 바꿨을 수 있습니다.');
  return { delimiter: '/' };
}

/** 목록 `{ messages: [요약], nextBefore }`. */
export async function localListMessages(accountId, folder, { before = null, limit = 30, q = null } = {}) {
  if (!(await localHasFolder(accountId, folder))) return { messages: [], nextBefore: null };
  const size = Math.min(Math.max(1, limit), q ? Math.min(LIST_LIMIT_MAX, SEARCH_MAX) : LIST_LIMIT_MAX);
  const rows = await listLocalMessages(accountId, folder, { before, limit: size, q: q ? q.toLowerCase() : null });
  const page = rows.slice(0, size);
  return { messages: page.map(localSummaryOf), nextBefore: rows.length > size ? page[page.length - 1].uid : null };
}

/** 메일 하나 — 없으면 null, 너무 크면 `{ tooLarge }`. 열면 읽음으로. */
export async function localReadMessage(accountId, folder, uid, { markSeen = true, withSource = false } = {}) {
  const row = await findLocalMessage(accountId, folder, uid);
  if (!row) return null;
  if (row.size > MESSAGE_BYTES_MAX) return { tooLarge: true, size: row.size };
  const source = await fs.readFile(fileOf(accountId, row.fileName)).catch(() => null);
  if (!source) return null;
  const parsed = await simpleParser(source, { skipImageLinks: true });
  if (markSeen && !row.seen) await updateLocalMessages(accountId, folder, [uid], { seen: true });
  return { parsed, flags: flagSetOf(row), source: withSource ? source : undefined, auth: row.auth ?? null };
}

export async function localSetFlags(accountId, folder, uids, { seen, flagged, answered }) {
  const patch = {};
  if (typeof seen === 'boolean') patch.seen = seen;
  if (typeof flagged === 'boolean') patch.flagged = flagged;
  if (typeof answered === 'boolean') patch.answered = answered;
  if (Object.keys(patch).length) await updateLocalMessages(accountId, folder, uids, patch);
}

/** 다른 폴더로 — 휴지통으로 옮기면 그 시각을 남긴다(30일 뒤 아주 지움). */
export async function localMove(accountId, folder, uids, to) {
  if (!(await localHasFolder(accountId, to))) {
    const e = new Error('회사 메일함에 없는 폴더입니다.');
    e.code = 'NO_FOLDER';
    throw e;
  }
  await updateLocalMessages(accountId, folder, uids, { folder: to, trashedAt: to === 'Trash' ? new Date() : null });
}

/** 지우기 — 휴지통이 아니면 휴지통으로, 휴지통이면 아주 지운다. `'trash'` | `'deleted'`. */
export async function localDelete(accountId, folder, uids) {
  if (folder !== 'Trash') {
    await localMove(accountId, folder, uids, 'Trash');
    return 'trash';
  }
  await localExpunge(accountId, folder, uids);
  return 'deleted';
}

/** 아주 지운다(표와 파일). */
export async function localExpunge(accountId, folder, uids) {
  const gone = await deleteLocalMessages(accountId, folder, uids);
  await Promise.all(gone.map((g) => fs.unlink(fileOf(accountId, g.fileName)).catch(() => {})));
}

/** 받은편지함 안 읽은 수(메뉴 숫자). */
export const localUnseen = (accountId) => localInboxUnseen(accountId);

/** [folder]의 최근 [limit]통 겉봉(받는 규칙) `[{ uid, from, to, cc, subject, seen }]`. */
export async function localRecent(accountId, folder, limit) {
  const rows = await recentLocalMessages(accountId, folder, limit);
  return rows.map(envelopeOfRow);
}

/** 고른 uid들의 겉봉(새로 받은 메일에 규칙 걸기). */
export async function localEnvelopes(accountId, folder, uids) {
  return (await listLocalMessagesByUid(accountId, folder, uids)).map(envelopeOfRow);
}

const envelopeOfRow = (r) => ({
  uid: r.uid,
  from: { name: r.fromName ?? '', address: r.fromAddress ?? '' },
  to: Array.isArray(r.toList) ? r.toList : [],
  cc: Array.isArray(r.ccList) ? r.ccList : [],
  subject: r.subject ?? '',
  seen: !!r.seen,
});

/** 휴지통에 30일 넘게 있던 메일을 아주 지운다(하루 한 번). 지운 수. */
export async function purgeLocalTrash(now = new Date()) {
  const before = new Date(now.getTime() - LOCAL_TRASH_DAYS * 24 * 60 * 60 * 1000);
  const expired = await listExpiredTrash(before);
  const byAccount = new Map();
  for (const e of expired) byAccount.set(e.accountId, [...(byAccount.get(e.accountId) ?? []), e.uid]);
  for (const [accountId, uids] of byAccount) await localExpunge(accountId, 'Trash', uids);
  return expired.length;
}

/** 계정을 지울 때 원문 폴더도 지운다(표는 계정과 함께 지워진다 — cascade). */
export async function removeLocalStore(accountId) {
  await fs.rm(dirOf(accountId), { recursive: true, force: true }).catch(() => {});
}
