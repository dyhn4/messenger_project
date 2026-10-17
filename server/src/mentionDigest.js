import { decryptField } from './crypto.js';
import {
  listMentionDigestCandidates,
  listUnreadMentionsForDigest,
  markMentionDigestSent,
} from './db/queries/mentionDigest.js';
import { getServerSettings } from './db/queries/serverSettings.js';
import { sendMail } from './mailer.js';
import { mailReady } from './mailRules.js';
import { mentionDigestMail } from './mailTemplates.js';
import { digestDue, digestWindowStart, isDigestHour, lastSeenOf, pickDigestItems } from './mentionDigestRules.js';
import { isOnline } from './presence.js';

const CHECK_INTERVAL_MS = 30 * 60 * 1000; // 30분마다 들여다보고, 보낼 시간(mentionDigestRules.js DIGEST_HOUR)에만 보낸다.
const DAY = 24 * 60 * 60 * 1000;

let running = false;

/**
 * 오래 접속하지 않은 사람들에게 안 읽은 멘션 요약 메일을 보낸다 — 메일이 켜져 있고 관리자가 요약을 끄지 않았을 때만. 대상·내용
 * 규칙은 mentionDigestRules.js. 한 사람에게 못 보내도 다음 사람은 계속하고, 못 보낸 사람은 보냈다고 적지 않아 다음 날 다시 한다.
 * 보낸 수.
 */
export async function runMentionDigest(now = new Date()) {
  const settings = await getServerSettings();
  if (!mailReady(settings) || !settings.mentionDigestEnabled) return 0;
  const days = settings.mentionDigestDays;
  const candidates = await listMentionDigestCandidates({
    sentBefore: new Date(now.getTime() - days * DAY),
    since: digestWindowStart({ now }),
  });
  let sent = 0;
  for (const user of candidates) {
    // 지금 붙어 있는 사람은 앱으로 보면 된다.
    if (isOnline(user.id)) continue;
    if (!digestDue({ now, lastSeen: lastSeenOf(user), sentAt: user.sentAt, days })) continue;
    const rows = await listUnreadMentionsForDigest(user.id, digestWindowStart({ now, sentAt: user.sentAt }));
    const { items, total } = pickDigestItems(rows, { mentionAll: user.mentionAll });
    if (total === 0) continue;
    try {
      await sendMail(
        decryptField(user.emailEnc),
        mentionDigestMail({ name: user.name, items, total, days, includePreview: settings.mentionDigestPreview }),
      );
      await markMentionDigestSent(user.id, now);
      sent += 1;
    } catch (err) {
      console.error('[mention-digest] 보내기 실패:', user.id, err?.message ?? err);
    }
  }
  if (sent > 0) console.log(`[mention-digest] 멘션 요약 메일 ${sent}통 보냄`);
  return sent;
}

/** 서버가 켜져 있는 동안 30분마다 들여다본다 — 보낼 시간대(아침 9시)에 든 때만 실제로 모은다. */
export function startMentionDigestJob() {
  const tick = () => {
    if (running || !isDigestHour()) return;
    running = true;
    runMentionDigest()
      .catch((err) => console.error('[mention-digest] 작업 실패:', err?.message ?? err))
      .finally(() => {
        running = false;
      });
  };
  setInterval(tick, CHECK_INTERVAL_MS).unref();
  tick();
}
