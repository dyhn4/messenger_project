import { limits, retryLater, waitText } from './authGuard.js';
import { lookupHash } from './crypto.js';
import { deleteEmailCode, findLatestEmailCode, replaceEmailCode, takeEmailCodeAttempt } from './db/queries/emailCodes.js';
import {
  CODE_MAX_ATTEMPTS,
  CODE_RESEND_MS,
  CODE_TTL_MS,
  emailCodeError,
  emailCodeHash,
  emailCodeState,
  generateEmailCode,
  normalizeEmailCode,
  resendWaitMs,
  sameCodeHash,
} from './emailCodeRules.js';
import { MailError, sendMail } from './mailer.js';
import { emailCodeMail } from './mailTemplates.js';

/**
 * 메일로 보내는 확인 코드 — 보내기(issueEmailCode)와 확인(checkEmailCode·consumeEmailCode). 규칙은 emailCodeRules.js.
 *
 * 보내기는 여러 겹으로 막는다 — 같은 목적·주소로 1분에 한 번, 한 주소로 한 시간에 5통(어느 목적이든), 그리고 부르는 쪽의 IP·계정
 * 제한(auth.js·users.js). 코드 하나로는 5번까지만 맞혀 볼 수 있으니, 한 주소로 한 시간에 맞혀 볼 수 있는 건 100만 개 중 25개다.
 */

const codeHashOf = (purpose, emailLookup, code) => emailCodeHash(lookupHash, { purpose, emailLookup, code });

/**
 * 코드를 만들어 [email]로 보낸다. 보냈으면 `{ ok: true, expiresInSeconds, resendInSeconds }`. 막혔으면 429를 보내고 null,
 * 메일을 못 보냈으면 503을 보내고 null — 응답은 이 함수가 끝낸다([res]).
 *
 * [emailEnc]는 이메일 변경에서 확인되면 바꿔 넣을 새 주소(암호화한 값).
 */
export async function issueEmailCode(res, { purpose, email, userId = null, emailEnc = null }) {
  const emailLookup = lookupHash(email);
  const slot = { purpose, emailLookup, userId };
  const latest = await findLatestEmailCode(slot);
  const wait = resendWaitMs(latest?.createdAt);
  if (wait > 0) {
    retryLater(res, wait, `방금 코드를 보냈습니다. ${waitText(wait)} 뒤에 다시 받을 수 있습니다. 메일이 안 보이면 스팸함도 확인하세요.`);
    return null;
  }
  const addressWait = limits.mailSendAddress.hit(emailLookup);
  if (addressWait > 0) {
    retryLater(res, addressWait, `이 주소로 메일을 너무 많이 보냈습니다. ${waitText(addressWait)} 뒤에 다시 시도하세요.`);
    return null;
  }

  const code = generateEmailCode();
  const row = await replaceEmailCode({
    purpose,
    emailLookup,
    userId,
    emailEnc,
    codeHash: codeHashOf(purpose, emailLookup, code),
    expiresAt: new Date(Date.now() + CODE_TTL_MS),
  });
  try {
    await sendMail(email, emailCodeMail(purpose, code, { minutes: Math.round(CODE_TTL_MS / 60_000) }));
  } catch (err) {
    // 못 보낸 코드는 지운다 — 남겨 두면 다시 보내기 대기(1분)에 걸려 고친 뒤에도 바로 못 받는다.
    await deleteEmailCode(row.id);
    res.status(503).json({ error: mailFailureText(err) });
    return null;
  }
  return {
    ok: true,
    expiresInSeconds: Math.round(CODE_TTL_MS / 1000),
    resendInSeconds: Math.round(CODE_RESEND_MS / 1000),
  };
}

/** 사용자에게 보여 줄 메일 실패 문구 — 연결·계정 문제의 자세한 내용은 운영자 몫이라 서버 콘솔에만 남긴다(mailer.js). */
export function mailFailureText(err) {
  return err instanceof MailError && err.message === '메일 기능이 꺼져 있습니다.'
    ? '이 서버는 메일 기능이 꺼져 있습니다.'
    : '메일을 보내지 못했습니다. 잠시 뒤 다시 시도하고, 계속 안 되면 서버 운영자에게 알려 주세요.';
}

/**
 * [code]가 [email]로 받은 [purpose] 코드가 맞는지 — 맞으면 `{ ok: true, row }`(아직 쓰지 않았다 — 다 끝난 뒤 consumeEmailCode),
 * 아니면 `{ ok: false, error, counted }`. 맞혀 볼 때마다 시도 한 칸을 쓴다(모양이 아닌 값은 쓰지 않는다). [counted]는 시도를 써서
 * 틀린 경우만 참 — 비밀번호 재설정은 그때만 무차별 대입 제한(auth.js recoveryGuard)에 센다(만료된 코드를 넣은 건 세지 않는다).
 */
export async function checkEmailCode({ purpose, email, userId = null, code }) {
  const normalized = normalizeEmailCode(code);
  if (!normalized) return { ok: false, error: emailCodeError('invalid') };
  const emailLookup = lookupHash(email);
  const latest = await findLatestEmailCode({ purpose, emailLookup, userId });
  const state = emailCodeState(latest);
  if (state !== 'ok') return { ok: false, error: emailCodeError(state) };
  // 시도를 먼저 한 칸 쓰고(동시에 들어온 요청도 한 칸씩) 그 뒤에 맞는지 본다.
  const taken = await takeEmailCodeAttempt(latest.id, CODE_MAX_ATTEMPTS);
  if (!taken) return { ok: false, error: emailCodeError(emailCodeState({ ...latest, attempts: CODE_MAX_ATTEMPTS })) };
  if (!sameCodeHash(taken.codeHash, codeHashOf(purpose, emailLookup, normalized))) {
    return {
      ok: false,
      counted: true,
      error: emailCodeError('mismatch', { attemptsLeft: CODE_MAX_ATTEMPTS - taken.attempts }),
    };
  }
  return { ok: true, row: taken };
}

/** 다 쓴 코드를 지운다 — 그 사이 다른 요청이 먼저 썼으면 false(그 요청은 이미 끝냈다). */
export function consumeEmailCode(row) {
  return deleteEmailCode(row.id);
}
