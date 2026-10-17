/**
 * 메일(SMTP) 설정 값 검사와 사람이 읽을 오류 문구 — DB·네트워크 없이 시험할 수 있게 계산만 모았다(mailer.js·admin.js가 쓴다).
 */

export const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
export const EMAIL_MAX_LENGTH = 200;
export const SMTP_SECURITY = Object.freeze(['ssl', 'starttls', 'none']);
/** 보안 방식마다 흔히 쓰는 포트 — 포트를 비워 두면 이 값을 쓴다. */
export const SMTP_DEFAULT_PORT = Object.freeze({ ssl: 465, starttls: 587, none: 25 });
export const SMTP_FROM_NAME_MAX = 50;
/** 초대 메일 한 번에 보낼 수 있는 주소 수. */
export const INVITE_MAIL_MAX_RECIPIENTS = 20;
export const MENTION_DIGEST_DAYS_MIN = 1;
export const MENTION_DIGEST_DAYS_MAX = 30;

export const isEmailAddress = (v) => typeof v === 'string' && v.length <= EMAIL_MAX_LENGTH && EMAIL_PATTERN.test(v);

/** 보내는 사람 주소 — 따로 정하지 않았으면 SMTP 계정. 둘 다 이메일 모양이 아니면 null(보낼 수 없다). */
export function mailFromAddress(settings) {
  const from = settings?.smtpFromAddress?.trim() || settings?.smtpUsername?.trim() || '';
  return isEmailAddress(from) ? from : null;
}

/** 시험 메일을 보내 볼 만큼 값이 갖춰졌는지(서버·포트·보내는 주소). 계정·비밀번호는 없어도 되는 사내 메일 서버가 있다. */
export function mailConfigComplete(settings) {
  return !!settings?.smtpHost && Number.isInteger(settings?.smtpPort) && !!mailFromAddress(settings);
}

/** 지금 메일을 실제로 보내는지 — 관리자가 켰고(시험 메일 성공 뒤에만 켜진다) 값이 갖춰져 있을 때. */
export function mailReady(settings) {
  return !!settings?.smtpEnabled && mailConfigComplete(settings);
}

/** 연결 값(이게 바뀌면 시험을 다시 해야 한다). 보내는 사람 이름은 연결과 무관하다. */
const CONNECTION_FIELDS = ['smtpHost', 'smtpPort', 'smtpSecurity', 'smtpUsername', 'smtpPassword', 'smtpFromAddress'];

/** [fields](바꿀 값)가 [current]와 달라 시험을 다시 해야 하는지. 비밀번호는 암호화돼 늘 달라 보여서, 넘겼으면 바뀐 것으로 본다. */
export function smtpConnectionChanged(current, fields) {
  return CONNECTION_FIELDS.some((key) => {
    if (!(key in fields)) return false;
    if (key === 'smtpPassword') return true;
    return (fields[key] ?? null) !== (current?.[key] ?? null);
  });
}

/**
 * 관리자 콘솔에서 온 SMTP 값(PATCH /admin/mail)을 DB 칸으로 — 넘긴 항목만. 통과하면 `{ fields }`, 아니면 `{ error }`.
 * 비밀번호는 글자 그대로 돌려준다(암호화는 부르는 쪽 — 이 파일은 비밀값을 모른다). 빈 문자열은 그 값을 지운다.
 */
export function parseSmtpInput(body) {
  const fields = {};
  const text = (v) => (typeof v === 'string' ? v.trim() : null);
  if ('host' in body) {
    const host = text(body.host);
    if (host === null) return { error: '서버 주소는 글자로 넣어야 합니다.' };
    if (host && !/^[A-Za-z0-9.-]{1,253}$/.test(host)) {
      return { error: '서버 주소가 올바르지 않습니다. 예: smtp.naver.com' };
    }
    fields.smtpHost = host || null;
  }
  if ('security' in body) {
    if (!SMTP_SECURITY.includes(body.security)) return { error: '연결 보안은 SSL, STARTTLS, 없음 중 하나입니다.' };
    fields.smtpSecurity = body.security;
  }
  if ('port' in body) {
    if (body.port === null || body.port === '') {
      fields.smtpPort = null;
    } else {
      const port = Number(body.port);
      if (!Number.isInteger(port) || port < 1 || port > 65535) return { error: '포트는 1~65535 사이의 숫자입니다.' };
      fields.smtpPort = port;
    }
  }
  if ('username' in body) {
    const username = text(body.username);
    if (username === null || username.length > 200) return { error: '계정(아이디)이 올바르지 않습니다.' };
    fields.smtpUsername = username || null;
  }
  if ('password' in body) {
    if (typeof body.password !== 'string' || body.password.length > 500) return { error: '비밀번호가 올바르지 않습니다.' };
    // 앱 비밀번호는 4자리씩 띄어 보여 주는 곳이 많다(Gmail) — 앞뒤 공백만 떼고 가운데는 그대로 둔다(서비스가 알아서 본다).
    fields.smtpPassword = body.password.trim() || null;
  }
  if ('fromAddress' in body) {
    const from = text(body.fromAddress);
    if (from === null) return { error: '보내는 주소는 글자로 넣어야 합니다.' };
    if (from && !isEmailAddress(from)) return { error: '보내는 주소가 이메일 형식이 아닙니다.' };
    fields.smtpFromAddress = from || null;
  }
  if ('fromName' in body) {
    const name = text(body.fromName);
    if (name === null) return { error: '보내는 이름은 글자로 넣어야 합니다.' };
    // 메일 머리글에 들어가는 값이라 줄바꿈 같은 제어 문자는 받지 않는다.
    if (name.length > SMTP_FROM_NAME_MAX || /[\p{Cc}]/u.test(name)) {
      return { error: `보내는 이름은 ${SMTP_FROM_NAME_MAX}자 이내로, 줄바꿈 없이 넣으세요.` };
    }
    fields.smtpFromName = name || null;
  }
  if ('digestEnabled' in body) {
    if (typeof body.digestEnabled !== 'boolean') return { error: 'digestEnabled는 참/거짓이어야 합니다.' };
    fields.mentionDigestEnabled = body.digestEnabled;
  }
  if ('digestDays' in body) {
    const days = Number(body.digestDays);
    if (!Number.isInteger(days) || days < MENTION_DIGEST_DAYS_MIN || days > MENTION_DIGEST_DAYS_MAX) {
      return { error: `멘션 요약 기준은 ${MENTION_DIGEST_DAYS_MIN}~${MENTION_DIGEST_DAYS_MAX}일 사이로 정하세요.` };
    }
    fields.mentionDigestDays = days;
  }
  if ('digestPreview' in body) {
    if (typeof body.digestPreview !== 'boolean') return { error: 'digestPreview는 참/거짓이어야 합니다.' };
    fields.mentionDigestPreview = body.digestPreview;
  }
  return { fields };
}

/**
 * 메일 보내기 실패를 관리자가 고칠 수 있는 말로. nodemailer 오류의 code·responseCode를 본다 — 서버가 준 원문은 뒤에 붙인다
 * (서비스마다 문구가 달라 그대로 보여 주는 게 원인 찾기에 낫다). 비밀번호는 원문에 실리지 않는다.
 */
export function describeSmtpError(err) {
  const code = err?.code;
  const raw = String(err?.response ?? err?.message ?? '').slice(0, 300);
  const tail = raw ? ` (서버 응답: ${raw})` : '';
  if (code === 'EAUTH' || err?.responseCode === 535) {
    return `로그인에 실패했습니다. 계정과 비밀번호를 확인하세요 — Gmail·네이버는 계정 비밀번호가 아니라 "앱 비밀번호"를 넣어야 하고, 네이버는 메일 환경설정에서 SMTP 사용을 켜야 합니다.${tail}`;
  }
  if (code === 'ETIMEDOUT' || code === 'ECONNECTION' || code === 'ECONNREFUSED' || code === 'ESOCKET') {
    return `메일 서버에 연결하지 못했습니다. 서버 주소·포트·연결 보안(465는 SSL, 587은 STARTTLS)을 확인하고, 서버 PC의 방화벽이 그 포트로 나가는 연결을 막지 않는지 보세요.${tail}`;
  }
  if (code === 'EDNS' || code === 'ENOTFOUND') return `메일 서버 주소를 찾지 못했습니다. 서버 주소를 확인하세요.${tail}`;
  if (code === 'EENVELOPE' || err?.responseCode === 553 || err?.responseCode === 550) {
    return `메일 서버가 보내는 주소나 받는 주소를 거절했습니다. Gmail·네이버는 보내는 주소가 로그인한 계정과 같아야 합니다.${tail}`;
  }
  if (code === 'ETLS') return `보안 연결(TLS)에 실패했습니다. 연결 보안 방식을 바꿔 보세요.${tail}`;
  return `메일을 보내지 못했습니다.${tail || ' (알 수 없는 이유)'}`;
}

/** 화면에 일부만 보일 주소 — "ab***@naver.com"(앞 두 글자). 짧으면 한 글자만 남긴다. */
export function maskEmail(email) {
  if (typeof email !== 'string') return '';
  const at = email.lastIndexOf('@');
  if (at <= 0) return '';
  const local = email.slice(0, at);
  const shown = local.length <= 2 ? local.slice(0, 1) : local.slice(0, 2);
  return `${shown}${'*'.repeat(Math.max(2, local.length - shown.length))}${email.slice(at)}`;
}

/**
 * 초대 메일 받는 주소들 — 문자열 배열이나 쉼표·줄바꿈으로 이은 글을 받는다. 대소문자만 다른 같은 주소는 하나로. 통과하면
 * `{ emails }`, 아니면 `{ error }`(틀린 주소가 하나라도 있으면 아무 데도 보내지 않는다 — 고쳐서 다시 보내게).
 */
export function parseRecipientList(input) {
  const parts = Array.isArray(input) ? input : typeof input === 'string' ? input.split(/[,;\n]/) : null;
  if (!parts) return { error: '받는 사람 이메일을 넣으세요.' };
  const seen = new Set();
  const emails = [];
  for (const part of parts) {
    if (typeof part !== 'string') return { error: '받는 사람 이메일이 올바르지 않습니다.' };
    const email = part.trim();
    if (!email) continue;
    if (!isEmailAddress(email)) return { error: `이메일 형식이 아닙니다: ${email.slice(0, 60)}` };
    const key = email.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    emails.push(email);
  }
  if (emails.length === 0) return { error: '받는 사람 이메일을 넣으세요.' };
  if (emails.length > INVITE_MAIL_MAX_RECIPIENTS) {
    return { error: `한 번에 ${INVITE_MAIL_MAX_RECIPIENTS}명까지 보낼 수 있습니다.` };
  }
  return { emails };
}
