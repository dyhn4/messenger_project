import { decryptField, encryptField } from './crypto.js';
import { getServerSettings } from './db/queries/serverSettings.js';
import { updateMailAccount } from './db/queries/webmail.js';
import {
  localCreateFolder,
  localDelete,
  localDeleteFolder,
  localExpunge,
  localHasFolder,
  localListFolders,
  localListMessages,
  localMove,
  localReadMessage,
  localRecent,
  localRenameFolder,
  localSetFlags,
  localUnseen,
  storeLocalMessage,
} from './localMailStore.js';
import { localMailLimits } from './localMailRules.js';
import {
  appendDraft,
  appendToSent,
  applyRulePlan,
  createFolder,
  deleteFolder,
  deleteMessages,
  expungeMessages,
  folderExists,
  inboxStatus,
  listFolders,
  listMessages,
  markAnswered,
  moveMessages,
  readMessage,
  recentMessages,
  renameFolder,
  setFlags,
  withImap,
} from './webmailClient.js';
import { oauthCredentials } from './webmailOAuth.js';
import { folderList, messageSummary } from './webmailRules.js';

/**
 * 메일 계정 하나를 다루는 한 가지 모양 — 바깥 메일 서버(IMAP — webmailClient.js)든 회사 메일함(자체 메일 서버 — localMailStore.js)이든
 * webmail.js가 같은 함수로 쓴다. 바깥 메일 서버는 계정의 IMAP 연결 줄(withImap)에서 돌고, 로그인 값은 쓸 때 받는다(credentialsOf —
 * OAuth면 접근 토큰을 갱신).
 */

/** 로그인 값 — 비밀번호 계정은 `{ password }`, OAuth는 `{ accessToken }`(남은 시간이 짧으면 갱신해 저장). */
export async function credentialsOf(account) {
  if (account.authType === 'oauth') {
    const settings = await getServerSettings();
    return oauthCredentials(account, {
      settings,
      save: async (t) => {
        const patch = { oauthAccessEnc: encryptField(t.accessToken), oauthExpiresAt: t.expiresAt };
        if (t.refreshToken) patch.oauthRefreshEnc = encryptField(t.refreshToken);
        const row = await updateMailAccount(account.id, patch);
        if (row) Object.assign(account, { oauthAccessEnc: row.oauthAccessEnc, oauthRefreshEnc: row.oauthRefreshEnc, oauthExpiresAt: row.oauthExpiresAt });
      },
    });
  }
  return { password: decryptField(account.passwordEnc) ?? '' };
}

/** 회사 메일함 계정인지. */
export const isLocalAccount = (account) => account?.authType === 'local';

function imapBackend(account) {
  const run = (fn) => withImap(account, () => credentialsOf(account), fn);
  return {
    kind: 'imap',
    listFolders: async () => folderList(await run(listFolders)),
    listMessages: async (folder, opts) => {
      const r = await run((c) => listMessages(c, folder, opts));
      return { messages: r.messages.map(messageSummary), nextBefore: r.nextBefore };
    },
    readMessage: (folder, uid, opts) => run((c) => readMessage(c, folder, uid, opts)),
    setFlags: (folder, uids, flags) => run((c) => setFlags(c, folder, uids, flags)),
    move: (folder, uids, to) => run((c) => moveMessages(c, folder, uids, to)),
    remove: (folder, uids) => run((c) => deleteMessages(c, folder, uids)),
    expunge: (folder, uids) => run((c) => expungeMessages(c, folder, uids)),
    markAnswered: (folder, uid) => run((c) => markAnswered(c, folder, uid)),
    appendSent: (raw) => run((c) => appendToSent(c, raw)),
    saveDraft: (raw, messageId) => run((c) => appendDraft(c, raw, messageId)),
    inboxUnseen: async () => (await run(inboxStatus)).unseen,
    folderExists: (path) => run((c) => folderExists(c, path)),
    recent: (folder, limit) => run((c) => recentMessages(c, folder, limit)),
    applyPlan: (folder, plan) => run((c) => applyRulePlan(c, folder, plan)),
    createFolder: (name, parent) => run((c) => createFolder(c, name, parent)),
    renameFolder: (path, name) => run((c) => renameFolder(c, path, name)),
    deleteFolder: (path) => run((c) => deleteFolder(c, path)),
  };
}

function localBackend(account) {
  const id = account.id;
  const quotaBytes = async () => localMailLimits(await getServerSettings()).quotaBytes;
  return {
    kind: 'local',
    listFolders: async () => folderList(await localListFolders(id)),
    listMessages: (folder, opts) => localListMessages(id, folder, opts),
    readMessage: (folder, uid, opts) => localReadMessage(id, folder, uid, opts),
    setFlags: (folder, uids, flags) => localSetFlags(id, folder, uids, flags),
    move: (folder, uids, to) => localMove(id, folder, uids, to),
    remove: (folder, uids) => localDelete(id, folder, uids),
    expunge: (folder, uids) => localExpunge(id, folder, uids),
    markAnswered: (folder, uid) => localSetFlags(id, folder, [uid], { answered: true }),
    appendSent: async (raw) => {
      await storeLocalMessage(id, raw, { folder: 'Sent', seen: true, quotaBytes: await quotaBytes() });
      return true;
    },
    saveDraft: async (raw) => {
      const { uid } = await storeLocalMessage(id, raw, { folder: 'Drafts', seen: true, draft: true, quotaBytes: await quotaBytes() });
      return { folder: 'Drafts', uid };
    },
    inboxUnseen: () => localUnseen(id),
    folderExists: (path) => localHasFolder(id, path),
    recent: (folder, limit) => localRecent(id, folder, limit),
    applyPlan: async (folder, plan) => {
      if (plan.seen.length) await localSetFlags(id, folder, plan.seen, { seen: true });
      if (plan.flagged.length) await localSetFlags(id, folder, plan.flagged, { flagged: true });
      for (const [to, uids] of plan.moves) if (to !== folder && uids.length && (await localHasFolder(id, to))) await localMove(id, folder, uids, to);
    },
    // 회사 메일함은 하위 폴더가 없다 — [parent]는 무시.
    createFolder: (name) => localCreateFolder(id, name),
    renameFolder: (path, name) => localRenameFolder(id, path, name),
    deleteFolder: (path) => localDeleteFolder(id, path),
  };
}

/** 계정의 메일 다루기. */
export const mailBackend = (account) => (isLocalAccount(account) ? localBackend(account) : imapBackend(account));
