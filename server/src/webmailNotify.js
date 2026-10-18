import { listMailRules } from './db/queries/webmail.js';
import { notifyMailPush } from './push.js';
import { planRules } from './webmailRules.js';

/**
 * 새로 온 메일 처리 — 받는 규칙 걸기와 알리기(바깥 메일 서버는 3분마다 확인할 때 — webmail.js checkMailAccount, 회사 메일함은 받는 즉시 —
 * localMailServer.js). 규칙이 다른 폴더로 옮겼거나 읽음으로 바꿨거나 "알리지 않기"인 메일은 알리지 않는다.
 */

/**
 * [envelopes](받은편지함의 새 메일 겉봉 `{ uid, from, to, cc, subject, seen }`)에 이 계정의 켜진 규칙을 건다. 옮길 폴더가 없으면 그
 * 옮기기는 건너뛴다. → planRules 결과(규칙이 없으면 빈 계획).
 */
export async function applyRulesToNew(account, backend, envelopes, folder = 'INBOX') {
  const empty = { moves: new Map(), seen: [], flagged: [], quiet: new Set(), matched: 0 };
  if (!envelopes.length) return empty;
  const rules = (await listMailRules(account.id)).filter((r) => r.enabled);
  if (!rules.length) return empty;
  const plan = planRules(rules, envelopes);
  for (const to of [...plan.moves.keys()]) {
    if (to === folder || !(await backend.folderExists(to).catch(() => false))) plan.moves.delete(to);
  }
  if (plan.seen.length || plan.flagged.length || plan.moves.size) await backend.applyPlan(folder, plan);
  return plan;
}

/** 알릴 메일만 — 안 읽었고, 옮기지 않았고, "알리지 않기"가 아닌 것. */
export function mailsToNotify(envelopes, plan) {
  const moved = new Set([...plan.moves.values()].flat());
  const seen = new Set(plan.seen);
  return envelopes.filter((m) => !m.seen && !seen.has(m.uid) && !moved.has(m.uid) && !plan.quiet.has(m.uid));
}

/** 소켓 `mail:new`(앱이 켜져 있으면 토스트·기기 알림)와 푸시(꺼져 있으면). 알린 수. */
export function notifyNewMail(io, account, envelopes, unseen) {
  if (!envelopes.length) return 0;
  const latest = envelopes.slice(0, 3).map((m) => ({
    from: m.from?.name || m.from?.address || '',
    subject: m.subject || '(제목 없음)',
  }));
  io?.to(`user:${account.userId}`).emit('mail:new', { accountId: account.id, email: account.email, count: envelopes.length, unseen, latest });
  const first = latest[0];
  notifyMailPush({
    userId: account.userId,
    title: envelopes.length > 1 ? `새 메일 ${envelopes.length}통` : `새 메일 — ${first.from}`,
    body: envelopes.length > 1 ? `${first.from}: ${first.subject} 외` : first.subject,
  }).catch((err) => console.error('[webmail] 새 메일 알림 실패:', err?.message ?? err));
  return envelopes.length;
}
