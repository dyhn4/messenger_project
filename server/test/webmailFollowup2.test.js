// 웹메일 후속 2 — 서식 있는 메일 쓰기(HTML 본문·임시 저장본의 서식), 폴더 만들기·이름 바꾸기·지우기(규칙 따라가기), 대화로 묶기용
// 머리, 자체 메일 서버의 스팸 거르기(SPF·DKIM·DMARC)와 보내는 메일 DKIM 서명, 회사 메일함 백업 미러. `node --test test/*.test.js`
// (DB·네트워크 없이 돈다 — DNS는 가짜 조회, IMAP은 가짜 클라이언트).
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { dkimSign } from 'mailauth';
import { simpleParser } from 'mailparser';
import { MIRRORS, mirrorFolder } from '../src/backup.js';
import { findMirrorFor, restoreMirror } from '../src/backupRestore.js';
import {
  __setMailAuthResolver,
  checkDkimRecords,
  checkInboundMail,
  dkimPublicKeyOf,
  dkimRecords,
  dkimRecordValue,
  isSameOrSubdomain,
  mailAuthVerdict,
  normalizeDkimSelector,
  signOutgoing,
} from '../src/localMailAuth.js';
import { isLocalSystemFolder, localFolderEntries, localSummaryOf, parseLocalMailInput } from '../src/localMailRules.js';
import { composeFormat, FORMAT_PART_TYPE, formatFromParsed, formatPartOf, formatToHtml } from '../src/mailFormatHtml.js';
import { buildRaw, createFolder, deleteFolder, renameFolder } from '../src/webmailClient.js';
import {
  folderDepth,
  folderList,
  messageDetail,
  messageIdsIn,
  messageSummary,
  parseCompose,
  parseFolderName,
  retargetRules,
  rulesUsingFolder,
} from '../src/webmailRules.js';

// ── 서식 있는 메일 쓰기 ──

test('서식 → HTML — 글자 서식·색·링크, 이스케이프, 공백 살리기', () => {
  const text = '굵게 <나쁜> & 기울임  두 칸';
  const html = formatToHtml(
    text,
    composeFormat(
      [
        { s: 0, e: 2, f: 1 },
        { s: 3, e: 7, f: 0, h: 'https://ex.com/?a=1&b=2' },
        { s: 10, e: 13, f: 2 + 512 + 0x1e88e5 * 1024 },
      ],
      text,
    ),
  );
  assert.match(html, /<b>굵게<\/b>/);
  assert.match(html, /<a href="https:\/\/ex\.com\/\?a=1&amp;b=2">&lt;나쁜&gt;<\/a>/);
  assert.match(html, /<span style="color:#1e88e5"><i>기울임<\/i><\/span>/);
  assert.match(html, / &nbsp;두 칸/); // 두 칸 띄움은 하나로 줄지 않게
  assert.ok(!html.includes('<나쁜>'));
});

test('서식 → HTML — 인용은 이어진 줄끼리 한 덩어리, 제목 줄, 앱 안 링크는 글자만', () => {
  const text = '앞\n> 하나\n> 둘\n제목\n끝';
  const html = formatToHtml(
    text,
    composeFormat(
      [
        { s: 2, e: 6, f: 32 },
        { s: 7, e: 10, f: 32 },
        { s: 11, e: 13, f: 64 },
        { s: 14, e: 15, f: 0, h: 'tangotalk://room/1' },
      ],
      text,
    ),
  );
  assert.equal((html.match(/<blockquote/g) ?? []).length, 1);
  assert.match(html, /<blockquote[^>]*>&gt; 하나<br>&gt; 둘<\/blockquote>/);
  assert.match(html, /<div style="font-size:1\.6em[^"]*">제목<\/div>/);
  assert.ok(!html.includes('tangotalk://'));
});

test('보낼 메일 — 서식은 본문에 맞는 것만(공지와 같은 비트), 없으면 null', () => {
  const ok = parseCompose({ to: 'a@b.com', subject: 's', text: '안녕', format: [{ s: 0, e: 2, f: 1 }, { s: 1, e: 99, f: 2 }, 'x'] });
  assert.deepEqual(ok.values.format, [{ s: 0, e: 2, f: 1 }]);
  assert.equal(parseCompose({ to: 'a@b.com', subject: 's', text: '안녕' }).values.format, null);
});

test('임시 저장본 — 서식 구간을 숨은 부분으로 넣고 되살린다(첨부 목록·번호는 그대로), 보낸 메일에는 없음', async () => {
  const text = '첫 줄\n둘째 줄';
  const runs = composeFormat([{ s: 0, e: 4, f: 1 }], text);
  const raw = await buildRaw(
    {
      from: 'me@x.kr',
      to: 'a@b.com',
      subject: '초안',
      text,
      html: formatToHtml(text, runs),
      attachments: [{ filename: 'a.txt', content: 'hello' }, formatPartOf(runs)],
    },
    { keepBcc: true },
  );
  const parsed = await simpleParser(raw, { skipImageLinks: true });
  assert.equal(parsed.text, text);
  const draft = messageDetail(3, parsed, new Set(['\\Draft']));
  assert.deepEqual(draft.format, runs);
  assert.deepEqual(
    draft.attachments.map((a) => [a.index, a.fileName]),
    [[0, 'a.txt']],
  );
  assert.equal(parsed.attachments[1].contentType, FORMAT_PART_TYPE);
  assert.equal(parsed.attachments[1].filename, undefined); // nodemailer가 이름을 붙이지 않게
  // 보낸(임시 저장이 아닌) 메일은 서식 구간을 내보내지 않는다.
  assert.equal(messageDetail(3, parsed, new Set()).format, null);
  // 본문과 맞지 않는 구간은 버린다.
  assert.equal(formatFromParsed(parsed, '짧'), null);
});

// ── 폴더 ──

test('폴더 이름 — 앞뒤 공백, 길이, 쓸 수 없는 글자(구분 글자 포함), INBOX', () => {
  assert.deepEqual(parseFolderName('  거래처  '), { name: '거래처' });
  assert.ok(parseFolderName('').error);
  assert.ok(parseFolderName('가'.repeat(101)).error);
  assert.ok(parseFolderName('a/b').error);
  assert.ok(parseFolderName('a\\b').error);
  assert.ok(parseFolderName('줄\n바꿈').error);
  assert.ok(parseFolderName('v1.2', { delimiter: '.' }).error);
  assert.deepEqual(parseFolderName('v1.2', { delimiter: '/' }), { name: 'v1.2' });
  assert.ok(parseFolderName('inbox').error);
});

test('폴더 목록 — 깊이(INBOX 이름공간은 빼고)·구분 글자·바꿀 수 있는지', () => {
  assert.equal(folderDepth(undefined), 0);
  assert.equal(folderDepth(['Projects']), 1);
  assert.equal(folderDepth(['INBOX']), 0);
  assert.equal(folderDepth(['INBOX', 'Projects']), 1);
  const rows = folderList([
    { path: 'INBOX', name: 'INBOX', delimiter: '/', flags: new Set() },
    { path: 'Sent', name: 'Sent', delimiter: '/', specialUse: '\\Sent', flags: new Set() },
    { path: 'Projects', name: 'Projects', delimiter: '/', flags: new Set() },
    { path: 'Projects/A', name: 'A', delimiter: '/', parent: ['Projects'], flags: new Set() },
  ]);
  const by = (p) => rows.find((r) => r.path === p);
  assert.equal(by('INBOX').editable, false);
  assert.equal(by('Sent').editable, false);
  assert.equal(by('Projects').editable, true);
  assert.equal(by('Projects/A').depth, 1);
  assert.equal(by('Projects/A').delimiter, '/');
});

test('폴더 이름을 바꾸면 그 폴더(·아래 폴더)로 옮기던 규칙을 따라 고치고, 지울 때는 규칙이 쓰는지 본다', () => {
  const rules = [
    { id: '1', name: 'a', actions: { moveTo: 'Projects', markSeen: true } },
    { id: '2', name: 'b', actions: { moveTo: 'Projects/A' } },
    { id: '3', name: 'c', actions: { moveTo: 'ProjectsOld' } },
    { id: '4', name: 'd', actions: { moveTo: null, flag: true } },
  ];
  assert.deepEqual(
    retargetRules(rules, 'Projects', 'Work', '/').map((r) => [r.rule.id, r.moveTo]),
    [
      ['1', 'Work'],
      ['2', 'Work/A'],
    ],
  );
  assert.deepEqual(
    rulesUsingFolder(rules, 'Projects/A', '/').map((r) => r.id),
    ['2'],
  );
  assert.deepEqual(rulesUsingFolder(rules, 'Other', '/'), []);
});

/** 가짜 IMAP — 폴더 목록과 만들기·이름 바꾸기·지우기·상태만. */
function fakeImap(paths, { delimiter = '/', messages = {} } = {}) {
  const entry = (p) => {
    const parts = p.split(delimiter);
    return {
      path: p,
      name: parts.at(-1),
      delimiter,
      parent: parts.slice(0, -1),
      parentPath: parts.slice(0, -1).join(delimiter),
      specialUse: p === 'Sent' ? '\\Sent' : undefined,
      flags: new Set(),
    };
  };
  const state = { paths: [...paths], calls: [] };
  return {
    state,
    list: async () => state.paths.map(entry),
    mailboxCreate: async (p) => {
      state.calls.push(['create', p]);
      state.paths.push(p);
      return { path: p };
    },
    mailboxRename: async (a, b) => {
      state.calls.push(['rename', a, b]);
      state.paths = state.paths.map((p) => (p === a ? b : p.startsWith(`${a}${delimiter}`) ? `${b}${p.slice(a.length)}` : p));
      return { path: a, newPath: b };
    },
    mailboxDelete: async (p) => {
      state.calls.push(['delete', p]);
      state.paths = state.paths.filter((x) => x !== p);
      return { path: p };
    },
    status: async (p) => ({ messages: messages[p] ?? 0 }),
  };
}

test('IMAP 폴더 — 만들기(위 폴더 아래·겹치는 이름 거절), 이름 바꾸기(같은 위 폴더 안), 기본 폴더는 못 바꿈', async () => {
  const c = fakeImap(['INBOX', 'Sent', 'Projects', 'Projects/A']);
  assert.equal(await createFolder(c, ' 거래처 '), '거래처');
  assert.equal(await createFolder(c, 'B', 'Projects'), 'Projects/B');
  await assert.rejects(createFolder(c, 'projects'), { code: 'FOLDER' });
  await assert.rejects(createFolder(c, 'a', 'Projects'), { code: 'FOLDER' });
  await assert.rejects(createFolder(c, 'x/y'), { code: 'FOLDER' });
  assert.deepEqual(await renameFolder(c, 'Projects/A', 'AA'), { from: 'Projects/A', to: 'Projects/AA', delimiter: '/' });
  await assert.rejects(renameFolder(c, 'Sent', 'Out'), { code: 'FOLDER' });
  await assert.rejects(renameFolder(c, 'INBOX', 'In'), { code: 'FOLDER' });
  await assert.rejects(renameFolder(c, 'Projects/AA', 'B'), { code: 'FOLDER' }); // 같은 위 폴더에 B가 있다
});

test('IMAP 폴더 지우기 — 비어 있고 아래 폴더가 없을 때만', async () => {
  const c = fakeImap(['INBOX', 'Projects', 'Projects/A', 'Full'], { messages: { Full: 3 } });
  await assert.rejects(deleteFolder(c, 'Projects'), { code: 'FOLDER' });
  await assert.rejects(deleteFolder(c, 'Full'), { code: 'FOLDER' });
  await deleteFolder(c, 'Projects/A');
  assert.deepEqual(c.state.calls, [['delete', 'Projects/A']]);
});

test('회사 메일함 폴더 — 사람이 만든 폴더는 기본 폴더 뒤에, 바꿀 수 있고, 기본 폴더 이름은 못 씀', () => {
  const rows = folderList(localFolderEntries({ 거래처: { unseen: 1, total: 2 } }, ['거래처']));
  const custom = rows.find((r) => r.path === '거래처');
  assert.deepEqual([custom.editable, custom.unseen, custom.total, custom.delimiter], [true, 1, 2, '/']);
  assert.equal(rows.find((r) => r.path === 'Archive').editable, false);
  assert.equal(isLocalSystemFolder('trash'), true);
  assert.equal(isLocalSystemFolder('거래처'), false);
});

// ── 대화로 묶기 ──

test('대화로 묶기 — 메시지 id 뽑기, IMAP 목록 줄(봉투 + References 머리), 회사 메일함 줄', () => {
  assert.deepEqual(messageIdsIn('<a@x> <b@x>\r\n <c@x>'), ['<a@x>', '<b@x>', '<c@x>']);
  assert.deepEqual(messageIdsIn(Buffer.from('References: <a@x>\r\n\t<b@x>\r\n\r\n')), ['<a@x>', '<b@x>']);
  assert.deepEqual(messageIdsIn(Array.from({ length: 40 }, (_, i) => `<m${i}@x>`)).length, 30);
  const row = messageSummary({
    uid: 1,
    envelope: { messageId: '<m2@x>', inReplyTo: '<m1@x>', subject: 'Re: 안녕' },
    headers: Buffer.from('References: <m0@x> <m1@x>\r\n\r\n'),
    flags: new Set(),
  });
  assert.deepEqual([row.messageId, row.inReplyTo, row.references], ['<m2@x>', '<m1@x>', ['<m0@x>', '<m1@x>']]);
  const local = localSummaryOf({ uid: 2, messageId: '<l@x>', inReplyTo: '<k@x>', references: ['<k@x>'], toList: [] });
  assert.deepEqual([local.messageId, local.inReplyTo, local.references], ['<l@x>', '<k@x>', ['<k@x>']]);
  assert.deepEqual(localSummaryOf({ uid: 3, toList: [] }).references, []);
});

// ── 스팸 거르기·DKIM ──

test('관리자 입력 — 스팸 거르기·DKIM 켜기, 선택자 모양', () => {
  assert.deepEqual(parseLocalMailInput({ spamFilter: false, dkimEnabled: true, dkimSelector: ' Mail2026 ' }).fields, {
    localMailSpamFilter: false,
    localMailDkimEnabled: true,
    localMailDkimSelector: 'mail2026',
  });
  assert.ok(parseLocalMailInput({ dkimSelector: 'a_b' }).error);
  assert.ok(parseLocalMailInput({ spamFilter: 'yes' }).error);
  assert.equal(normalizeDkimSelector('-bad'), null);
  assert.equal(isSameOrSubdomain('mail.ex.com', 'ex.com'), true);
  assert.equal(isSameOrSubdomain('badex.com', 'ex.com'), false);
});

const authResult = ({ spf = 'none', spfDomain = 'sender.com', dkim = [], dmarc = null, from = 'sender.com' } = {}) => ({
  spf: { status: { result: spf }, domain: spfDomain },
  dkim: { results: dkim, headerFrom: [`a@${from}`] },
  dmarc: dmarc ? { status: { result: dmarc.result, header: { from } }, policy: dmarc.policy } : false,
});

test('판정 — DMARC 거절·격리, 우리 도메인 사칭, SPF 실패, 확인 안 됨, 통과', () => {
  const verdict = (r) => mailAuthVerdict(authResult(r), { localDomains: ['corp.kr'] }).verdict;
  assert.equal(verdict({ dmarc: { result: 'fail', policy: 'reject' } }), 'reject');
  assert.equal(verdict({ dmarc: { result: 'fail', policy: 'quarantine' } }), 'junk');
  assert.equal(verdict({ dmarc: { result: 'fail', policy: 'none' } }), 'warn');
  // 우리 도메인인데 SPF가 다른 도메인으로만 통과 — 사칭.
  assert.equal(verdict({ from: 'corp.kr', spf: 'pass', spfDomain: 'evil.com' }), 'junk');
  // 우리 도메인을 우리 키로 서명했으면 통과.
  assert.equal(verdict({ from: 'corp.kr', dkim: [{ signingDomain: 'corp.kr', status: { result: 'pass' } }] }), 'pass');
  assert.equal(verdict({ spf: 'fail' }), 'junk');
  assert.equal(verdict({ spf: 'fail', dkim: [{ signingDomain: 'sender.com', status: { result: 'pass' } }] }), 'pass');
  assert.equal(verdict({ spf: 'softfail' }), 'warn');
  assert.equal(verdict({ spf: 'pass' }), 'pass');
  assert.equal(verdict({ dmarc: { result: 'pass', policy: 'reject' } }), 'pass');
  const r = mailAuthVerdict(authResult({ dmarc: { result: 'fail', policy: 'reject' } }));
  assert.match(r.reason, /sender\.com/);
});

/** 가짜 DNS — [records] `{ 'name/TYPE': [...] }`, 없으면 ENOTFOUND. */
const fakeDns = (records) => async (name, rrtype) => {
  const v = records[`${String(name).toLowerCase()}/${rrtype}`];
  if (v) return v;
  const e = new Error(`not found ${name} ${rrtype}`);
  e.code = 'ENOTFOUND';
  throw e;
};

const keyPair = () =>
  crypto.generateKeyPairSync('rsa', {
    modulusLength: 2048,
    publicKeyEncoding: { type: 'spki', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  });

const message = (from) =>
  Buffer.from(
    [`From: 보낸이 <${from}>`, 'To: kim@corp.kr', 'Subject: test', 'Date: Mon, 19 Oct 2026 09:00:00 +0900', 'Message-ID: <t1@x>', 'MIME-Version: 1.0', 'Content-Type: text/plain; charset=utf-8', '', '본문입니다', ''].join('\r\n'),
  );

test('받는 메일 확인(mailauth) — 서명·SPF·DMARC를 가짜 DNS로: 통과·위조 거절·SPF 실패', async (t) => {
  t.after(() => __setMailAuthResolver(null));
  const { privateKey, publicKey } = keyPair();
  const p = dkimPublicKeyOf(privateKey);
  assert.equal(p, crypto.createPublicKey(publicKey).export({ type: 'spki', format: 'der' }).toString('base64'));
  __setMailAuthResolver(
    fakeDns({
      's1._domainkey.sender.com/TXT': [[dkimRecordValue(p)]],
      'sender.com/TXT': [['v=spf1 ip4:203.0.113.5 -all']],
      '_dmarc.sender.com/TXT': [['v=DMARC1; p=reject']],
    }),
  );
  const signed = await signOutgoing(message('a@sender.com'), { domain: 'sender.com', selector: 's1', privateKey });
  assert.match(signed.toString(), /^DKIM-Signature: /);
  const ok = await checkInboundMail(signed, { ip: '203.0.113.5', helo: 'mx.sender.com', mailFrom: 'a@sender.com', mta: 'corp.kr', localDomains: ['corp.kr'] });
  assert.deepEqual([ok.verdict, ok.spf, ok.dkim, ok.dmarc], ['pass', 'pass', 'pass', 'pass']);
  assert.match(ok.headers, /Authentication-Results: corp\.kr;/);
  // 서명 없이 다른 서버에서 보낸 위조 — DMARC p=reject.
  const forged = await checkInboundMail(message('a@sender.com'), { ip: '198.51.100.9', mailFrom: 'a@sender.com', mta: 'corp.kr' });
  assert.deepEqual([forged.verdict, forged.spf, forged.dmarc], ['reject', 'fail', 'fail']);
  // 본문을 바꾸면 서명이 깨진다 — SPF가 맞는 서버에서 왔으면 DMARC는 SPF로 통과.
  const tampered = Buffer.from(signed.toString().replace('본문입니다', '바뀐 본문'));
  const t2 = await checkInboundMail(tampered, { ip: '203.0.113.5', mailFrom: 'a@sender.com', mta: 'corp.kr' });
  // mailauth는 본문 해시가 다르면 neutral로 적는다(서명 자체는 맞음) — 어느 쪽이든 통과는 아니다.
  assert.notEqual(t2.dkim, 'pass');
  assert.equal(t2.verdict, 'pass');
});

test('받는 메일 확인 — DNS가 안 되면 받는다(확인 못 함), 우리 도메인 사칭은 스팸', async (t) => {
  t.after(() => __setMailAuthResolver(null));
  __setMailAuthResolver(async () => {
    const e = new Error('timeout');
    e.code = 'ETIMEOUT';
    throw e;
  });
  const down = await checkInboundMail(message('a@sender.com'), { ip: '198.51.100.9', mailFrom: 'a@sender.com', mta: 'corp.kr' });
  assert.notEqual(down.verdict, 'reject');
  assert.notEqual(down.verdict, 'junk');
  __setMailAuthResolver(fakeDns({}));
  const spoof = await checkInboundMail(message('ceo@corp.kr'), { ip: '198.51.100.9', mailFrom: 'ceo@corp.kr', mta: 'corp.kr', localDomains: ['corp.kr'] });
  assert.equal(spoof.verdict, 'junk');
  assert.match(spoof.reason, /사칭/);
});

test('DKIM 레코드 — 도메인마다 이름·값, DNS에 올라갔는지 확인', async () => {
  const records = dkimRecords(['a.kr', 'b.kr'], 'tangotalk', 'PUB');
  assert.deepEqual(records[1], { domain: 'b.kr', name: 'tangotalk._domainkey.b.kr', value: 'v=DKIM1; k=rsa; p=PUB' });
  const results = await checkDkimRecords(records, 'PUB', async (name) => {
    if (name.endsWith('a.kr')) return [['v=DKIM1; k=rsa; ', 'p=PUB']];
    if (name.endsWith('b.kr')) return [['v=DKIM1; p=OTHER']];
    throw new Error('nx');
  });
  assert.deepEqual(
    results.map((r) => [r.domain, r.ok]),
    [
      ['a.kr', true],
      ['b.kr', false],
    ],
  );
  assert.match(results[1].found, /^OTHER/);
});

test('mailauth 서명 모양 — 우리 서명은 relaxed/relaxed, rsa-sha256', async () => {
  const { privateKey } = keyPair();
  const { signatures } = await dkimSign(message('a@corp.kr'), {
    signatureData: [{ signingDomain: 'corp.kr', selector: 'tangotalk', privateKey, algorithm: 'rsa-sha256', canonicalization: 'relaxed/relaxed' }],
  });
  const ours = (await signOutgoing(message('a@corp.kr'), { domain: 'corp.kr', selector: 'tangotalk', privateKey })).toString();
  for (const tag of ['a=rsa-sha256', 'c=relaxed/relaxed', 'd=corp.kr', 's=tangotalk']) {
    assert.ok(signatures.includes(tag), tag);
    assert.ok(ours.includes(tag), tag);
  }
  // 키가 망가졌으면 서명 없이 그대로(보내기는 막지 않는다).
  const raw = message('a@corp.kr');
  assert.deepEqual(await signOutgoing(raw, { domain: 'corp.kr', selector: 'x', privateKey: 'not a key' }), raw);
});

// ── 회사 메일함 백업 ──

test('회사 메일함 미러 — 첨부파일과 같은 방식(파일마다 암호화·바뀐 것만), 다른 폴더·암호화 이름으로 복원', async (t) => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tt-mailstore-'));
  t.after(() => fs.rmSync(tmp, { recursive: true, force: true }));
  const store = path.join(tmp, 'mailstore');
  fs.mkdirSync(path.join(store, 'acc1'), { recursive: true });
  fs.writeFileSync(path.join(store, 'acc1', 'm1.eml'), 'Subject: a\r\n\r\nhello');
  const extRoot = path.join(tmp, 'ext', 'TangoTalk-Backup');
  fs.mkdirSync(path.join(extRoot, 'tangotalk_20261019_030000'), { recursive: true });
  const key = crypto.randomBytes(32);
  const quiet = { warn() {} };
  const first = await mirrorFolder({ kind: 'mailstore', sourceDir: store, extRoot, key, log: quiet });
  assert.deepEqual([first.total, first.copied], [1, 1]);
  assert.ok(fs.existsSync(path.join(extRoot, 'mailstore', MIRRORS.mailstore.marker)));
  assert.ok(fs.existsSync(path.join(extRoot, 'mailstore', 'acc1', 'm1.eml.enc')));
  assert.ok(!fs.readFileSync(path.join(extRoot, 'mailstore', 'acc1', 'm1.eml.enc')).includes(Buffer.from('hello')));
  assert.equal((await mirrorFolder({ kind: 'mailstore', sourceDir: store, extRoot, key, log: quiet })).copied, 0);

  const backupDir = path.join(extRoot, 'tangotalk_20261019_030000');
  assert.equal(findMirrorFor(backupDir), null); // 첨부파일 미러는 없다
  const mirrorDir = findMirrorFor(backupDir, 'mailstore');
  assert.ok(mirrorDir);
  const target = path.join(tmp, 'restored');
  const r = await restoreMirror({ mirrorDir, key, targetDir: target, kind: 'mailstore' });
  assert.equal(r.restored, 1);
  assert.equal(fs.readFileSync(path.join(target, 'acc1', 'm1.eml'), 'utf8'), 'Subject: a\r\n\r\nhello');
  // 첨부파일로 풀려고 하면(암호화 이름이 달라) 표시 파일부터 맞지 않는다.
  await assert.rejects(restoreMirror({ mirrorDir, key, targetDir: path.join(tmp, 'x'), kind: 'uploads' }));
});
