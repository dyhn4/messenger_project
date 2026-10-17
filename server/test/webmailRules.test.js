// 웹메일 규칙 — 계정 입력(미리 정한 서비스·직접 입력·포트·보안), 막는 주소, 받는 사람 목록, 보낼 메일 검사, IMAP 오류 문구, 폴더 순서, 목록·읽기 모양,
// 새 메일 수. `node --test test/*.test.js`(DB 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  accountDto,
  describeImapError,
  folderList,
  fromHeaderOf,
  hasAttachment,
  isBlockedAddress,
  messageDetail,
  messageSummary,
  newMailCount,
  parseAccountInput,
  parseAddress,
  parseAddressList,
  parseCompose,
  presetList,
  RECIPIENTS_MAX,
} from '../src/webmailRules.js';

test('계정 입력 — 미리 정한 서비스는 연결 값을 채우고, 아이디를 비우면 이메일', () => {
  const r = parseAccountInput({ email: 'me@naver.com', provider: 'naver', password: 'app-pass', displayName: ' 홍길동 ' });
  assert.deepEqual(r.values, {
    email: 'me@naver.com',
    displayName: '홍길동',
    provider: 'naver',
    imapHost: 'imap.naver.com',
    imapPort: 993,
    imapSecurity: 'ssl',
    smtpHost: 'smtp.naver.com',
    smtpPort: 465,
    smtpSecurity: 'ssl',
    username: 'me@naver.com',
    password: 'app-pass',
  });
  assert.match(parseAccountInput({ email: 'x', provider: 'naver', password: 'p' }).error, /이메일/);
  assert.match(parseAccountInput({ email: 'a@b.co', provider: 'yahoo', password: 'p' }).error, /서비스/);
  assert.match(parseAccountInput({ email: 'a@b.co', provider: 'gmail' }).error, /비밀번호/);
  assert.equal(parseAccountInput({ email: 'a@b.co', provider: 'gmail' }, { existing: {} }).values.password, null, '고치기는 비워도 됨');
  assert.ok(presetList().some((p) => p.key === 'gmail' && p.hint.includes('앱 비밀번호')));
});

test('계정 입력 — 직접 입력은 주소·포트·보안을 검사(암호화 없는 연결과 메일 포트가 아닌 곳은 막음)', () => {
  const ok = parseAccountInput({
    email: 'me@corp.co.kr',
    provider: 'custom',
    imap: { host: 'Mail.Corp.co.kr', port: 143, security: 'starttls' },
    smtp: { host: '10.0.0.5', port: 587, security: 'starttls' },
    username: 'me',
    password: 'p',
  });
  assert.equal(ok.values.imapHost, 'mail.corp.co.kr');
  assert.equal(ok.values.smtpHost, '10.0.0.5', '사내 메일 서버(사설 주소)는 됨');
  assert.equal(ok.values.username, 'me');
  const base = { email: 'me@corp.co.kr', provider: 'custom', password: 'p', smtp: { host: 'smtp.corp.co.kr', port: 465, security: 'ssl' } };
  assert.match(parseAccountInput({ ...base, imap: { host: 'mail.corp', port: 22, security: 'ssl' } }).error, /포트는 143·993/);
  assert.match(parseAccountInput({ ...base, imap: { host: 'mail.corp', port: 143, security: 'none' } }).error, /암호화 없는/);
  assert.match(parseAccountInput({ ...base, imap: { host: 'bad host!', port: 993, security: 'ssl' } }).error, /서버 주소/);
  assert.match(
    parseAccountInput({ ...base, imap: { host: 'mail.corp', port: 993, security: 'ssl' }, smtp: { host: 'smtp.corp', port: 80, security: 'ssl' } }).error,
    /SMTP.*포트/,
  );
});

test('막는 주소 — 이 PC 자신·링크 로컬·메타데이터, 사설망은 됨', () => {
  for (const ip of ['127.0.0.1', '127.8.8.8', '0.0.0.0', '169.254.169.254', '::1', '::', 'fe80::1', '::ffff:127.0.0.1', 'not-an-ip']) {
    assert.equal(isBlockedAddress(ip), true, ip);
  }
  for (const ip of ['10.0.0.5', '192.168.0.10', '172.16.1.1', '125.209.238.100', '2404:6800:4004::6d', '::ffff:10.0.0.1']) {
    assert.equal(isBlockedAddress(ip), false, ip);
  }
});

test('주소 — "이름 <주소>"와 주소만, 목록은 같은 주소 하나로', () => {
  assert.deepEqual(parseAddress('"홍 길동" <hong@corp.kr>'), { name: '홍 길동', address: 'hong@corp.kr' });
  assert.deepEqual(parseAddress(' kim@corp.kr '), { name: '', address: 'kim@corp.kr' });
  assert.deepEqual(parseAddress({ name: '이', address: 'lee@corp.kr' }), { name: '이', address: 'lee@corp.kr' });
  assert.equal(parseAddress('nope'), null);
  assert.deepEqual(parseAddressList('a@x.kr, A@X.kr; 나 <b@x.kr>', '받는 사람').list.map((a) => a.address), ['a@x.kr', 'b@x.kr']);
  assert.match(parseAddressList(['a@x.kr', 'oops'], '참조').error, /참조 주소가 올바르지 않습니다: oops/);
  assert.deepEqual(parseAddressList(undefined, '참조').list, []);
});

test('보낼 메일 — 받는 사람·제목·본문·첨부·답장 머리', () => {
  const r = parseCompose({
    to: ['a@x.kr'],
    cc: 'b@x.kr',
    subject: '회의\r\n안내',
    text: '내일 10시',
    attachments: [{ fileUrl: '/uploads/f.pdf', fileName: '자료.pdf', mimeType: 'application/pdf' }],
    inReplyTo: '<abc@x.kr>',
    references: ['<r1@x.kr>', 'bad', '<abc@x.kr>'],
  });
  assert.equal(r.values.subject, '회의 안내', '머리에 줄바꿈이 끼지 않게');
  assert.deepEqual(r.values.cc, [{ name: '', address: 'b@x.kr' }]);
  assert.deepEqual(r.values.references, ['<r1@x.kr>', '<abc@x.kr>']);
  assert.equal(r.values.inReplyTo, '<abc@x.kr>');
  assert.equal(r.values.attachments[0].fileName, '자료.pdf');
  assert.equal(parseCompose({ bcc: 'a@x.kr', text: '숨은 참조만' }).values.subject, '(제목 없음)');
  assert.match(parseCompose({ subject: '제목' }).error, /받는 사람/);
  assert.match(parseCompose({ to: 'a@x.kr' }).error, /제목이나 본문/);
  const many = Array.from({ length: RECIPIENTS_MAX + 1 }, (_, i) => `u${i}@x.kr`);
  assert.match(parseCompose({ to: many, text: 'x' }).error, /50명/);
  assert.match(parseCompose({ to: 'a@x.kr', text: 'x', attachments: [{}] }).error, /첨부/);
  assert.equal(parseCompose({ to: 'a@x.kr', text: 'x', inReplyTo: 'not-an-id' }).values.inReplyTo, null);
});

test('보내는 사람 머리·계정 모양(비밀번호는 안 나감)', () => {
  const account = {
    email: 'me@naver.com',
    displayName: '홍길동',
    provider: 'naver',
    imapHost: 'imap.naver.com',
    imapPort: 993,
    imapSecurity: 'ssl',
    smtpHost: 'smtp.naver.com',
    smtpPort: 465,
    smtpSecurity: 'ssl',
    username: 'me',
    passwordEnc: 'SECRET',
    notify: true,
    lastError: null,
  };
  assert.deepEqual(fromHeaderOf(account), { name: '홍길동', address: 'me@naver.com' });
  assert.equal(fromHeaderOf({ ...account, displayName: null }), 'me@naver.com');
  const dto = accountDto(account);
  assert.equal(dto.providerLabel, '네이버 메일');
  assert.equal(JSON.stringify(dto).includes('SECRET'), false);
  assert.equal(accountDto(null), null);
});

test('IMAP 오류 문구', () => {
  assert.match(describeImapError({ authenticationFailed: true, responseText: 'Invalid credentials' }), /앱 비밀번호/);
  assert.match(describeImapError({ code: 'ENOTFOUND' }), /주소를 찾지 못했습니다/);
  assert.match(describeImapError({ code: 'ECONNREFUSED' }), /연결하지 못했습니다/);
  assert.match(describeImapError({ message: 'self signed certificate' }), /TLS/);
  assert.match(describeImapError({}), /알 수 없는 이유/);
});

test('폴더 — 받은편지함·보낸편지함·…·휴지통 순서, 고를 수 없는 폴더는 뺌, 특수 폴더는 한국어 이름', () => {
  const list = folderList([
    { path: 'Work', name: 'Work', flags: new Set(), status: { unseen: 1, messages: 3 } },
    { path: '[Gmail]', name: '[Gmail]', flags: new Set(['\\Noselect']) },
    { path: '[Gmail]/Trash', name: 'Trash', specialUse: '\\Trash', flags: new Set() },
    { path: 'Sent Messages', name: 'Sent Messages', specialUse: '\\Sent', flags: new Set() },
    { path: 'INBOX', name: 'INBOX', flags: new Set(), status: { unseen: 4, messages: 10 } },
  ]);
  assert.deepEqual(list.map((f) => f.name), ['받은편지함', '보낸편지함', '휴지통', 'Work']);
  assert.deepEqual([list[0].unseen, list[0].total], [4, 10]);
  assert.equal(list[0].specialUse, '\\Inbox');
});

test('목록 한 줄·첨부 여부·읽기 모양', () => {
  const structure = {
    type: 'multipart/mixed',
    childNodes: [{ type: 'text/plain' }, { type: 'application/pdf', disposition: 'attachment', dispositionParameters: { filename: 'a.pdf' } }],
  };
  assert.equal(hasAttachment(structure), true);
  assert.equal(hasAttachment({ type: 'multipart/alternative', childNodes: [{ type: 'text/plain' }, { type: 'text/html' }] }), false);
  const row = messageSummary({
    uid: 7,
    envelope: { subject: '', from: [{ name: '김', address: 'kim@x.kr' }], to: [{ address: 'me@x.kr' }], date: new Date(1000) },
    flags: new Set(['\\Seen', '\\Flagged']),
    bodyStructure: structure,
    size: 1234,
  });
  assert.deepEqual(row, {
    uid: 7,
    subject: '(제목 없음)',
    from: { name: '김', address: 'kim@x.kr' },
    to: [{ name: '', address: 'me@x.kr' }],
    date: 1000,
    seen: true,
    flagged: true,
    answered: false,
    hasAttachments: true,
    size: 1234,
  });
  const detail = messageDetail(
    7,
    {
      subject: '안녕',
      from: { value: [{ name: '김', address: 'kim@x.kr' }] },
      to: { value: [{ name: '', address: 'me@x.kr' }] },
      date: new Date(2000),
      text: '본문',
      html: '<p>본문</p>',
      messageId: '<m1@x.kr>',
      references: '<r0@x.kr>',
      attachments: [
        { filename: 'a.pdf', contentType: 'application/pdf', size: 10, contentDisposition: 'attachment' },
        { contentType: 'image/png', size: 5, contentDisposition: 'inline' },
      ],
    },
    new Set(['\\Flagged']),
  );
  assert.deepEqual(detail.references, ['<r0@x.kr>']);
  assert.equal(detail.html, true);
  assert.deepEqual(detail.attachments, [{ index: 0, fileName: 'a.pdf', contentType: 'application/pdf', size: 10, inline: false }]);
  assert.equal(detail.flagged, true);
});

test('새 메일 수 — 처음·UIDVALIDITY가 바뀌면 0(기준만 잡음)', () => {
  assert.equal(newMailCount({ lastUidNext: null, lastUidValidity: null }, { uidNext: 50, uidValidity: '1' }), 0);
  assert.equal(newMailCount({ lastUidNext: 48, lastUidValidity: '1' }, { uidNext: 50, uidValidity: '1' }), 2);
  assert.equal(newMailCount({ lastUidNext: 48, lastUidValidity: '1' }, { uidNext: 50, uidValidity: '2' }), 0);
  assert.equal(newMailCount({ lastUidNext: 48, lastUidValidity: '1' }, { uidNext: 40, uidValidity: '1' }), 0);
});
