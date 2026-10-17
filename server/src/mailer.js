import nodemailer from 'nodemailer';
import { decryptField } from './crypto.js';
import { getServerSettings } from './db/queries/serverSettings.js';
import { MAIL_APP_NAME } from './mailTemplates.js';
import { SMTP_DEFAULT_PORT, describeSmtpError, mailFromAddress, mailReady } from './mailRules.js';

/**
 * 메일 보내기(SMTP). 설정은 관리자 콘솔 "메일" 탭에서 넣어 DB(server_settings)에 둔다 — 도메인이 없을 때는 네이버·Gmail 같은
 * 메일 계정의 SMTP와 앱 비밀번호로, 도메인이 생기면 회사 메일·발송 서비스의 값으로 바꾸기만 하면 된다.
 *
 * 메일이 꺼져 있으면(isMailEnabled 거짓) 이메일 확인·메일로 찾기·초대 메일·멘션 요약 메일이 모두 동작하지 않고, 예전처럼
 * 보안 질문으로 비밀번호를 찾는다.
 */

/** 메일을 보내지 못했을 때 — [message]는 관리자·사용자에게 보여 줄 문구(describeSmtpError). */
export class MailError extends Error {
  constructor(message, cause) {
    super(message);
    this.name = 'MailError';
    this.cause = cause;
  }
}

// 설정이 바뀔 때까지 연결 설정 객체를 다시 쓴다(updatedAt이 바뀌면 새로 만든다).
let cached = null; // { key, transporter }

function transportOptions(settings) {
  const security = settings.smtpSecurity ?? 'starttls';
  const options = {
    host: settings.smtpHost,
    port: settings.smtpPort ?? SMTP_DEFAULT_PORT[security] ?? 587,
    secure: security === 'ssl',
    // STARTTLS를 고르면 TLS로 올리지 못하는 서버엔 보내지 않는다(비밀번호가 평문으로 나가지 않게). '없음'은 사내 메일 서버용.
    requireTLS: security === 'starttls',
    ignoreTLS: security === 'none',
    connectionTimeout: 15_000,
    greetingTimeout: 15_000,
    socketTimeout: 30_000,
  };
  if (settings.smtpUsername) {
    options.auth = { user: settings.smtpUsername, pass: settings.smtpPassword ? decryptField(settings.smtpPassword) : '' };
  }
  return options;
}

function transporterFor(settings) {
  const key = `${new Date(settings.updatedAt ?? 0).getTime()}`;
  if (cached?.key !== key) {
    cached?.transporter.close();
    cached = { key, transporter: nodemailer.createTransport(transportOptions(settings)) };
  }
  return cached.transporter;
}

function fromHeader(settings) {
  return { name: settings.smtpFromName || MAIL_APP_NAME, address: mailFromAddress(settings) };
}

/** 지금 메일 기능이 켜져 있는지(관리자가 켰고 값이 갖춰짐). */
export async function isMailEnabled() {
  return mailReady(await getServerSettings());
}

/**
 * [to]에게 [mail]({ subject, text, html } — mailTemplates.js)을 보낸다. 메일이 꺼져 있거나 보내지 못하면 MailError.
 * [settings]를 주면 그 값으로(시험 메일 — 아직 켜지 않은 설정), 아니면 지금 저장된 설정으로 켜져 있을 때만 보낸다.
 */
export async function sendMail(to, mail, { settings = null } = {}) {
  const current = settings ?? (await getServerSettings());
  if (!settings && !mailReady(current)) throw new MailError('메일 기능이 꺼져 있습니다.');
  try {
    await transporterFor(current).sendMail({
      from: fromHeader(current),
      to,
      subject: mail.subject,
      text: mail.text,
      html: mail.html,
    });
  } catch (err) {
    console.error('[mail] 보내기 실패:', err?.code ?? '', err?.message ?? err);
    throw new MailError(describeSmtpError(err), err);
  }
}
