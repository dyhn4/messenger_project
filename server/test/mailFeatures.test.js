// 메일 기능(확인 코드·SMTP 설정·메일 본문·멘션 요약) 규칙 단위 테스트 — `node --test test/*.test.js` (DB·메일 서버 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  CODE_MAX_ATTEMPTS,
  CODE_RESEND_MS,
  emailCodeError,
  emailCodeHash,
  emailCodeState,
  generateEmailCode,
  normalizeEmailCode,
  resendWaitMs,
  sameCodeHash,
} from '../src/emailCodeRules.js';
import {
  INVITE_MAIL_MAX_RECIPIENTS,
  describeSmtpError,
  mailConfigComplete,
  mailFromAddress,
  mailReady,
  maskEmail,
  parseRecipientList,
  parseSmtpInput,
  smtpConnectionChanged,
} from '../src/mailRules.js';
import { emailCodeMail, inviteMail, mentionDigestMail } from '../src/mailTemplates.js';
import {
  DIGEST_ITEMS_MAX,
  DIGEST_LOOKBACK_MS,
  digestDue,
  digestWindowStart,
  isDigestHour,
  lastSeenOf,
  pickDigestItems,
} from '../src/mentionDigestRules.js';

const DAY = 24 * 60 * 60 * 1000;

// ── 확인 코드 ──────────────────────────────────────────────────────────

test('확인 코드는 앞자리 0까지 살린 6자리 숫자', () => {
  assert.equal(generateEmailCode(() => 42), '000042');
  assert.equal(generateEmailCode(() => 999999), '999999');
  assert.match(generateEmailCode(), /^\d{6}$/);
});

test('넣은 코드는 공백·하이픈·전각 숫자를 정리해서 6자리일 때만 받는다', () => {
  assert.equal(normalizeEmailCode(' 123 456 '), '123456');
  assert.equal(normalizeEmailCode('123-456'), '123456');
  assert.equal(normalizeEmailCode('１２３４５６'), '123456');
  assert.equal(normalizeEmailCode('12345'), null);
  assert.equal(normalizeEmailCode('1234567'), null);
  assert.equal(normalizeEmailCode('abcdef'), null);
  assert.equal(normalizeEmailCode(123456), null);
  assert.equal(normalizeEmailCode(undefined), null);
});

test('코드 해시는 목적·주소가 다르면 달라지고, 비교는 같은 값만 참', () => {
  const keyed = (s) => `h(${s})`;
  const a = emailCodeHash(keyed, { purpose: 'reset', emailLookup: 'L1', code: '123456' });
  const b = emailCodeHash(keyed, { purpose: 'signup', emailLookup: 'L1', code: '123456' });
  const c = emailCodeHash(keyed, { purpose: 'reset', emailLookup: 'L2', code: '123456' });
  assert.notEqual(a, b);
  assert.notEqual(a, c);
  assert.equal(sameCodeHash(a, emailCodeHash(keyed, { purpose: 'reset', emailLookup: 'L1', code: '123456' })), true);
  assert.equal(sameCodeHash(a, b), false);
  assert.equal(sameCodeHash(a, 'short'), false);
  assert.equal(sameCodeHash(a, null), false);
});

test('다시 보내기는 마지막으로 보낸 뒤 1분이 지나야', () => {
  const now = 1_000_000_000;
  assert.equal(resendWaitMs(null, now), 0);
  assert.equal(resendWaitMs(new Date(now - 10_000), now), CODE_RESEND_MS - 10_000);
  assert.equal(resendWaitMs(new Date(now - CODE_RESEND_MS), now), 0);
  // 시계가 뒤로 간 경우(미래 시각)에 영영 못 보내지 않게.
  assert.equal(resendWaitMs(new Date(now + 5_000), now), 0);
});

test('코드 상태 — 없음·만료·시도 다 씀·쓸 수 있음', () => {
  const now = Date.now();
  assert.equal(emailCodeState(null, now), 'missing');
  assert.equal(emailCodeState({ expiresAt: new Date(now - 1), attempts: 0 }, now), 'expired');
  assert.equal(emailCodeState({ expiresAt: new Date(now + 60_000), attempts: CODE_MAX_ATTEMPTS }, now), 'exhausted');
  assert.equal(emailCodeState({ expiresAt: new Date(now + 60_000), attempts: CODE_MAX_ATTEMPTS - 1 }, now), 'ok');
});

test('코드 오류 문구 — 틀렸으면 남은 횟수, 다 썼으면 다시 받으라고', () => {
  assert.match(emailCodeError('mismatch', { attemptsLeft: 2 }), /2번 더/);
  assert.match(emailCodeError('mismatch', { attemptsLeft: 0 }), /다시 받으세요/);
  assert.match(emailCodeError('expired'), /만료/);
  assert.match(emailCodeError('invalid'), /6자리/);
});

// ── SMTP 설정 ──────────────────────────────────────────────────────────

test('보내는 주소는 따로 정한 주소, 없으면 이메일 모양의 계정', () => {
  assert.equal(mailFromAddress({ smtpFromAddress: 'noreply@corp.com', smtpUsername: 'me@naver.com' }), 'noreply@corp.com');
  assert.equal(mailFromAddress({ smtpFromAddress: '', smtpUsername: 'me@naver.com' }), 'me@naver.com');
  assert.equal(mailFromAddress({ smtpUsername: 'relayuser' }), null);
});

test('메일은 켰고 서버·포트·보내는 주소가 있어야 동작한다', () => {
  const base = { smtpHost: 'smtp.naver.com', smtpPort: 465, smtpUsername: 'me@naver.com' };
  assert.equal(mailConfigComplete(base), true);
  assert.equal(mailReady(base), false);
  assert.equal(mailReady({ ...base, smtpEnabled: true }), true);
  assert.equal(mailReady({ ...base, smtpEnabled: true, smtpHost: null }), false);
  assert.equal(mailReady({ ...base, smtpEnabled: true, smtpPort: null }), false);
  assert.equal(mailReady({ ...base, smtpEnabled: true, smtpUsername: 'relay' }), false);
  assert.equal(mailReady(null), false);
});

test('SMTP 입력 — 넘긴 항목만, 잘못된 값은 거절', () => {
  assert.deepEqual(parseSmtpInput({ host: ' smtp.gmail.com ', port: '587', security: 'starttls' }).fields, {
    smtpHost: 'smtp.gmail.com',
    smtpPort: 587,
    smtpSecurity: 'starttls',
  });
  assert.deepEqual(parseSmtpInput({ password: '' }).fields, { smtpPassword: null });
  assert.deepEqual(parseSmtpInput({ port: null }).fields, { smtpPort: null });
  assert.ok(parseSmtpInput({ host: 'smtp naver' }).error);
  assert.ok(parseSmtpInput({ port: 70000 }).error);
  assert.ok(parseSmtpInput({ security: 'tls' }).error);
  assert.ok(parseSmtpInput({ fromAddress: 'not-mail' }).error);
  assert.ok(parseSmtpInput({ fromName: '이름\n줄바꿈' }).error, '메일 머리글에 줄바꿈을 넣지 못하게');
  assert.ok(parseSmtpInput({ digestDays: 0 }).error);
  assert.ok(parseSmtpInput({ digestDays: 31 }).error);
  assert.deepEqual(parseSmtpInput({ digestEnabled: false, digestDays: 7, digestPreview: true }).fields, {
    mentionDigestEnabled: false,
    mentionDigestDays: 7,
    mentionDigestPreview: true,
  });
});

test('연결 값이 바뀌면 시험을 다시 해야 한다 — 이름·요약 설정은 상관없다', () => {
  const current = { smtpHost: 'smtp.naver.com', smtpPort: 465, smtpSecurity: 'ssl', smtpUsername: 'a@naver.com' };
  assert.equal(smtpConnectionChanged(current, { smtpHost: 'smtp.naver.com', smtpPort: 465 }), false);
  assert.equal(smtpConnectionChanged(current, { smtpPort: 587 }), true);
  assert.equal(smtpConnectionChanged(current, { smtpPassword: 'enc' }), true, '비밀번호를 넘겼으면 바뀐 것');
  assert.equal(smtpConnectionChanged(current, { smtpFromName: '새 이름', mentionDigestDays: 5 }), false);
});

test('SMTP 오류는 고칠 수 있는 말로', () => {
  assert.match(describeSmtpError({ code: 'EAUTH', response: '535 auth failed' }), /앱 비밀번호/);
  assert.match(describeSmtpError({ code: 'ETIMEDOUT' }), /연결하지 못했습니다/);
  assert.match(describeSmtpError({ code: 'EDNS' }), /주소를 찾지 못했습니다/);
  assert.match(describeSmtpError({ code: 'EENVELOPE' }), /거절/);
  assert.match(describeSmtpError({}), /보내지 못했습니다/);
});

test('주소는 앞 두 글자만 보인다', () => {
  assert.equal(maskEmail('abcdef@naver.com'), 'ab****@naver.com');
  assert.equal(maskEmail('ab@naver.com'), 'a**@naver.com');
  assert.equal(maskEmail('nope'), '');
});

test('초대 메일 받는 주소 — 쉼표·줄바꿈으로 나누고 같은 주소는 하나로, 하나라도 틀리면 거절', () => {
  assert.deepEqual(parseRecipientList('a@x.com, B@x.com\nb@X.com ; c@y.org').emails, ['a@x.com', 'B@x.com', 'c@y.org']);
  assert.deepEqual(parseRecipientList(['a@x.com', '', ' d@z.kr ']).emails, ['a@x.com', 'd@z.kr']);
  assert.match(parseRecipientList('a@x.com, nope').error, /형식/);
  assert.ok(parseRecipientList('').error);
  assert.ok(parseRecipientList(null).error);
  const many = Array.from({ length: INVITE_MAIL_MAX_RECIPIENTS + 1 }, (_, i) => `u${i}@x.com`);
  assert.match(parseRecipientList(many).error, /까지/);
});

// ── 메일 본문 ──────────────────────────────────────────────────────────

test('코드 메일 — 제목·글·HTML에 코드가 들어간다', () => {
  const mail = emailCodeMail('reset', '012345', { minutes: 10 });
  assert.match(mail.subject, /비밀번호 재설정/);
  assert.match(mail.text, /012345/);
  assert.match(mail.html, /012345/);
  assert.match(mail.text, /10분/);
});

test('초대 메일 — 사람이 정한 글은 HTML에서 이스케이프하고, http(s) 주소만 링크로', () => {
  const mail = inviteMail({
    inviterName: '<script>김</script>',
    teamName: '영업"팀',
    internalUrl: 'http://192.168.0.10:3001/team-invite/abc',
    externalUrl: 'http://x.duckdns.org:3001/team-invite/abc',
    webUrl: 'javascript:alert(1)',
  });
  assert.ok(!mail.html.includes('<script>'));
  assert.match(mail.html, /&lt;script&gt;/);
  assert.match(mail.html, /영업&quot;팀/);
  assert.match(mail.text, /사내 와이파이에서: http:\/\/192\.168\.0\.10/);
  assert.match(mail.text, /밖\(LTE\/5G\)에서: http:\/\/x\.duckdns\.org/);
  assert.ok(!mail.html.includes('javascript:'), 'http(s)가 아닌 주소는 넣지 않는다');
});

test('멘션 요약 메일 — 미리보기는 켰을 때만, 넘치는 건 "외 N개"', () => {
  const items = [
    { teamName: '본사', roomName: '공지', actorName: '김', preview: '비밀 계획', createdAt: new Date(), kind: 'mention' },
    { teamName: '본사', roomName: '잡담', actorName: '이', preview: '점심?', createdAt: new Date(), kind: 'mention_all' },
  ];
  const plain = mentionDigestMail({ name: '홍길동', items, total: 5, days: 3, formatTime: () => '어제' });
  assert.match(plain.subject, /멘션 5개/);
  assert.match(plain.text, /본사 · 공지 — 김, 어제/);
  assert.match(plain.text, /\(@all\)/);
  assert.match(plain.text, /외 3개/);
  assert.ok(!plain.text.includes('비밀 계획'), '미리보기를 끄면 메시지 내용이 메일로 나가지 않는다');
  assert.ok(!plain.html.includes('비밀 계획'));
  const withPreview = mentionDigestMail({ name: '홍길동', items, total: 2, days: 3, includePreview: true, formatTime: () => '어제' });
  assert.match(withPreview.text, /비밀 계획/);
  assert.ok(!withPreview.text.includes('외 '));
});

// ── 멘션 요약 대상 ─────────────────────────────────────────────────────

test('요약은 아침 9시대에만', () => {
  assert.equal(isDigestHour(new Date(2026, 9, 17, 9, 30)), true);
  assert.equal(isDigestHour(new Date(2026, 9, 17, 10, 0)), false);
});

test('마지막 접속 — 계정 기록과 기기 기록 중 늦은 쪽, 둘 다 없으면 가입 시각', () => {
  const a = new Date('2026-10-01T00:00:00Z');
  const b = new Date('2026-10-05T00:00:00Z');
  assert.deepEqual(lastSeenOf({ lastSeenAt: a, deviceLastSeenAt: b }), b);
  assert.deepEqual(lastSeenOf({ lastSeenAt: b, deviceLastSeenAt: null }), b);
  assert.deepEqual(lastSeenOf({ createdAt: a }), a);
  assert.equal(lastSeenOf({}), null);
});

test('정한 날수 넘게 안 들어왔고, 지난 요약에서도 그만큼 지났을 때만', () => {
  const now = new Date('2026-10-17T09:00:00Z');
  const ago = (d) => new Date(now.getTime() - d * DAY);
  assert.equal(digestDue({ now, lastSeen: ago(2), days: 3 }), false);
  assert.equal(digestDue({ now, lastSeen: ago(3), days: 3 }), true);
  assert.equal(digestDue({ now, lastSeen: ago(10), sentAt: ago(1), days: 3 }), false, '계속 안 들어와도 3일에 한 번보다 자주 보내지 않는다');
  assert.equal(digestDue({ now, lastSeen: ago(10), sentAt: ago(3), days: 3 }), true);
  assert.equal(digestDue({ now, lastSeen: null, days: 3 }), false);
});

test('요약에 넣을 멘션은 지난 요약 뒤의 것만, 최대 30일', () => {
  const now = new Date('2026-10-17T09:00:00Z');
  assert.deepEqual(digestWindowStart({ now }), new Date(now.getTime() - DIGEST_LOOKBACK_MS));
  const sentAt = new Date(now.getTime() - 3 * DAY);
  assert.deepEqual(digestWindowStart({ now, sentAt }), sentAt);
  const old = new Date(now.getTime() - 60 * DAY);
  assert.deepEqual(digestWindowStart({ now, sentAt: old }), new Date(now.getTime() - DIGEST_LOOKBACK_MS));
});

test('@all을 꺼 둔 사람은 @all을 빼고, 최신순으로 정한 수만', () => {
  const rows = Array.from({ length: DIGEST_ITEMS_MAX + 3 }, (_, i) => ({
    kind: i % 2 ? 'mention_all' : 'mention',
    createdAt: new Date(2026, 9, 1, 0, i),
  }));
  const all = pickDigestItems(rows);
  assert.equal(all.total, rows.length);
  assert.equal(all.items.length, DIGEST_ITEMS_MAX);
  assert.ok(all.items[0].createdAt > all.items[1].createdAt, '최신순');
  const personal = pickDigestItems(rows, { mentionAll: false });
  assert.ok(personal.items.every((r) => r.kind === 'mention'));
  assert.equal(personal.total, Math.ceil(rows.length / 2));
  assert.deepEqual(pickDigestItems([{ kind: 'board_post', createdAt: new Date() }]), { items: [], total: 0 });
});
