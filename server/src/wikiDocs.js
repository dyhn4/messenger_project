import { apply, baseLength, diffOp, isNoop, isValidOp, normalize, transform } from './otText.js';
import {
  WIKI_BODY_MAX,
  WIKI_HISTORY_MAX,
  WIKI_INSERT_MAX,
  WIKI_SAVE_DELAY_MS,
  WIKI_SNAPSHOT_INTERVAL_MS,
} from './wikiRules.js';

/**
 * 위키 동시 편집 문서 — 열려 있는(누군가 편집 중인) 페이지를 메모리에 두고 연산을 차례로 적용한다(서버가 기준 — 한 페이지의 연산은
 * 한 번에 하나씩, 동기로 적용된다). 늦게 온 연산은 그 사이 적용된 연산들에 맞춰(transform) 바꾼 뒤 적용하고, 최근 연산
 * [historyMax]개를 기억해 다시 붙은 앱이 그 뒤를 따라잡게 한다(연산마다 앱이 붙인 opId로 같은 연산을 두 번 적용하지 않는다).
 * 마지막 연산 뒤 [saveDelayMs]가 지나면 저장하고, 편집하는 동안 [snapshotIntervalMs]마다·마지막 사람이 나갈 때 판을 남긴다.
 *
 * DB는 주입받는다(테스트 — test/wikiDocs.test.js): load(pageId) → { id, teamId, title, body, revision } | null,
 * save(pageId, { body, revision, updatedByName }), snapshot(pageId, { revision, title, body, editorNames }), lastSnapshot(pageId) → { revision, createdAt } | null.
 */
export function createWikiDocs({
  load,
  save,
  snapshot,
  lastSnapshot = async () => null,
  now = () => Date.now(),
  saveDelayMs = WIKI_SAVE_DELAY_MS,
  snapshotIntervalMs = WIKI_SNAPSHOT_INTERVAL_MS,
  historyMax = WIKI_HISTORY_MAX,
  setTimer = (fn, ms) => setTimeout(fn, ms),
  clearTimer = (t) => clearTimeout(t),
}) {
  const docs = new Map();
  const loading = new Map();

  /** 페이지 문서를 연다(메모리에 없으면 DB에서). 없는 페이지면 null. */
  async function open(pageId) {
    if (docs.has(pageId)) return docs.get(pageId);
    if (!loading.has(pageId)) {
      loading.set(
        pageId,
        (async () => {
          const [page, snap] = await Promise.all([load(pageId), lastSnapshot(pageId)]);
          if (!page) return null;
          const doc = {
            pageId,
            teamId: page.teamId,
            title: page.title,
            body: page.body ?? '',
            revision: page.revision ?? 0,
            savedRevision: page.revision ?? 0,
            snapshotRevision: snap?.revision ?? page.revision ?? 0,
            snapshotAt: snap?.createdAt ? new Date(snap.createdAt).getTime() : now(),
            history: [],
            members: new Map(),
            editorsSinceSnapshot: new Set(),
            lastEditorName: null,
            saveTimer: null,
          };
          docs.set(pageId, doc);
          return doc;
        })().finally(() => loading.delete(pageId)),
      );
    }
    return loading.get(pageId);
  }

  const peek = (pageId) => docs.get(pageId) ?? null;

  /** [revision] 뒤의 연산들 — 너무 오래돼 기억에 없으면 null(앱은 본문을 통째로 다시 받는다). */
  function since(doc, revision) {
    if (revision === doc.revision) return [];
    const first = doc.revision - doc.history.length;
    if (revision < first || revision > doc.revision) return null;
    return doc.history.slice(revision - first);
  }

  function record(doc, entry) {
    doc.history.push(entry);
    if (doc.history.length > historyMax) doc.history.splice(0, doc.history.length - historyMax);
  }

  /**
   * 앱의 연산 하나 — `{ ok: true, revision, op, duplicate? }`(적용한 뒤의 판 번호와 실제로 적용한 연산) | `{ error }`.
   * error: 'resync'(앱이 아는 판이 너무 오래됐거나 앞섬 — 본문을 다시 받는다) | 'invalid' | 'too_big'.
   */
  function receive(doc, { baseRevision, op, opId, userId, userName }) {
    if (!Number.isInteger(baseRevision) || !isValidOp(op)) return { error: 'invalid' };
    if (typeof opId === 'string' && opId) {
      const seen = doc.history.find((h) => h.opId === opId);
      if (seen) return { ok: true, revision: seen.revision, op: seen.op, duplicate: true };
    }
    const concurrent = since(doc, baseRevision);
    if (concurrent === null) return { error: 'resync' };
    let incoming = normalize(op);
    if (incoming.some((c) => typeof c === 'string' && c.length > WIKI_INSERT_MAX)) return { error: 'too_big' };
    try {
      for (const h of concurrent) incoming = transform(incoming, h.op)[0];
    } catch {
      return { error: 'resync' };
    }
    if (baseLength(incoming) !== doc.body.length) return { error: 'resync' };
    const next = apply(doc.body, incoming);
    if (next.length > WIKI_BODY_MAX) return { error: 'too_big' };
    doc.body = next;
    doc.revision += 1;
    record(doc, { revision: doc.revision, op: incoming, opId: opId ?? null, userId });
    if (!isNoop(incoming)) {
      if (userName) {
        doc.editorsSinceSnapshot.add(userName);
        doc.lastEditorName = userName;
      }
      scheduleSave(doc);
    }
    return { ok: true, revision: doc.revision, op: incoming };
  }

  /** 본문을 통째로 바꾼다(판 되돌리기) — 편집 중인 앱에는 보통 연산처럼 퍼진다. `{ revision, op }`. */
  function replaceBody(doc, body, { userName = null } = {}) {
    const op = diffOp(doc.body, body);
    doc.body = body;
    doc.revision += 1;
    record(doc, { revision: doc.revision, op, opId: null, userId: null });
    if (userName) {
      doc.editorsSinceSnapshot.add(userName);
      doc.lastEditorName = userName;
    }
    scheduleSave(doc);
    return { revision: doc.revision, op };
  }

  function scheduleSave(doc) {
    if (doc.saveTimer) clearTimer(doc.saveTimer);
    doc.saveTimer = setTimer(() => {
      doc.saveTimer = null;
      flush(doc).catch((e) => console.error('[wiki] 저장 실패:', e?.message ?? e));
    }, saveDelayMs);
  }

  /** 지금 본문을 저장하고, 판 간격이 지났거나 [forceSnapshot]이면 판을 남긴다. */
  async function flush(doc, { forceSnapshot = false } = {}) {
    if (doc.saveTimer) {
      clearTimer(doc.saveTimer);
      doc.saveTimer = null;
    }
    const { revision, body } = doc;
    if (doc.savedRevision < revision) {
      await save(doc.pageId, { body, revision, updatedByName: doc.lastEditorName });
      doc.savedRevision = Math.max(doc.savedRevision, revision);
    }
    const due = now() - doc.snapshotAt >= snapshotIntervalMs;
    if (doc.snapshotRevision < revision && (forceSnapshot || due)) {
      const editorNames = [...doc.editorsSinceSnapshot].join(', ') || null;
      doc.snapshotRevision = revision;
      doc.snapshotAt = now();
      doc.editorsSinceSnapshot.clear();
      await snapshot(doc.pageId, { revision, title: doc.title, body, editorNames });
    }
  }

  /** 편집 화면에 들어온 사람(소켓 하나). 지금 편집 중인 사람 목록을 돌려준다. */
  function join(doc, socketId, member) {
    doc.members.set(socketId, member);
    return editors(doc);
  }

  /** 나갔다 — 마지막 사람이면 저장·판을 남기고 메모리에서 내린다. 남은 사람 목록. */
  async function leave(doc, socketId) {
    doc.members.delete(socketId);
    if (doc.members.size > 0) return editors(doc);
    await flush(doc, { forceSnapshot: true });
    // 그 사이 다시 들어온 사람이 없을 때만 내린다.
    if (doc.members.size === 0 && docs.get(doc.pageId) === doc) docs.delete(doc.pageId);
    return [];
  }

  /** 편집하는 사람이 없는 문서를 저장하고 내린다(편집 화면 밖에서 되돌리기를 한 뒤). */
  async function release(doc) {
    if (doc.members.size > 0) return;
    await flush(doc);
    if (doc.members.size === 0 && docs.get(doc.pageId) === doc) docs.delete(doc.pageId);
  }

  /** 같은 사람이 여러 기기로 들어와도 한 번만. */
  function editors(doc) {
    const byUser = new Map();
    for (const m of doc.members.values()) if (!byUser.has(m.userId)) byUser.set(m.userId, m);
    return [...byUser.values()];
  }

  /** [socketId]가 들어가 있는 문서들(끊겼을 때 나가기). */
  function docsOfSocket(socketId) {
    return [...docs.values()].filter((d) => d.members.has(socketId));
  }

  /** 서버를 끌 때 — 열린 문서를 모두 저장. */
  async function flushAll() {
    for (const doc of docs.values()) await flush(doc, { forceSnapshot: true }).catch(() => {});
  }

  return { open, peek, since, receive, replaceBody, flush, join, leave, release, editors, docsOfSocket, flushAll, _docs: docs };
}
