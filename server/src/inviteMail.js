import { limits, retryLater, waitText } from './authGuard.js';
import { EXTERNAL_ADDRESS, PAIRING_PORT } from './config.js';
import { mailFailureText } from './emailCodes.js';
import { isMailEnabled, sendMail } from './mailer.js';
import { parseRecipientList } from './mailRules.js';
import { inviteMail } from './mailTemplates.js';
import { getWebPublicUrl } from './webAddress.js';

/**
 * 초대 링크를 메일로 보내기 — 설치 초대(invites.js)와 팀 초대(teamInvites.js)가 같이 쓴다. 본문은 서버가 링크 값으로 만든다
 * (앱이 보낸 글을 그대로 싣지 않는다 — 서버 메일 계정으로 아무 글이나 보내는 통로가 되지 않게).
 *
 * [pathKind]는 안내 페이지 경로('invite' | 'team-invite' — pairing.js), [teamName]은 팀 초대일 때만. 응답까지 끝낸다:
 * `{ sent, failed: [{ email, error }] }` — 일부만 실패해도 200(보낸 것은 보냈다).
 */
export async function sendInviteMails(req, res, { link, pathKind, inviterName, teamName = null, onSent }) {
  if (!(await isMailEnabled())) return res.status(409).json({ error: '이 서버는 메일 기능이 꺼져 있습니다.' });
  const parsed = parseRecipientList(req.body?.emails);
  if (parsed.error) return res.status(400).json({ error: parsed.error });
  // 받는 사람 수만큼 센다 — 한 계정에서 한 시간에 보낼 수 있는 초대 메일 수(authGuard.js inviteMailUser).
  for (let i = 0; i < parsed.emails.length; i += 1) {
    const wait = limits.inviteMailUser.hit(req.user.sub);
    if (wait > 0) {
      return retryLater(res, wait, `초대 메일을 너무 많이 보냈습니다. ${waitText(wait)} 뒤에 다시 보내세요.`);
    }
  }

  const host = req.hostname;
  const internalUrl = host ? `http://${host}:${PAIRING_PORT}/${pathKind}/${link.token}` : null;
  const externalUrl = EXTERNAL_ADDRESS ? `http://${EXTERNAL_ADDRESS.host}:${PAIRING_PORT}/${pathKind}/${link.token}` : null;
  const web = getWebPublicUrl();
  // 아이폰용 웹 앱은 주소의 ?invite=로 초대 코드를 받아 밖에서도 가입한다(client web_launch_invite.dart).
  const webUrl = web ? `${web.endsWith('/') ? web : `${web}/`}?invite=${encodeURIComponent(link.token)}` : null;
  const mail = inviteMail({
    inviterName,
    teamName,
    internalUrl,
    externalUrl,
    webUrl,
    expiresText: expiresText(link.expiresAt),
  });

  const failed = [];
  let sent = 0;
  for (const email of parsed.emails) {
    try {
      await sendMail(email, mail);
      sent += 1;
    } catch (err) {
      failed.push({ email, error: mailFailureText(err) });
    }
  }
  if (sent > 0) onSent?.(sent);
  res.json({ sent, failed });
}

const expiresFormatter = new Intl.DateTimeFormat('ko-KR', { month: 'long', day: 'numeric', hour: 'numeric', minute: '2-digit' });

function expiresText(expiresAt) {
  const date = new Date(expiresAt);
  return Number.isNaN(date.getTime()) ? null : expiresFormatter.format(date);
}
