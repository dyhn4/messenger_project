// 웹메일 후속 — HTML 메일 걸러 내기(htmlToRich), 받는 규칙, 자동 완성, 계정 설정·그림 허용, 임시 저장 입력, 자체 메일 서버 규칙, OAuth 연결
// 규칙. `node --test test/*.test.js`(DB 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  localAddressOf,
  localMailLimits,
  localMailReady,
  localPartOf,
  localSummaryOf,
  parseDomains,
  parseLocalMailInput,
} from '../src/localMailRules.js';
import { htmlToRich, parseColor, parseFontScale, safeHref } from '../src/webmailHtml.js';
import { buildMailAuthorizeUrl, checkMailIdToken, mailOAuthProblem } from '../src/webmailOAuth.js';
import {
  accountDto,
  conditionMatches,
  contactsToRecord,
  isFullOrder,
  isTrustedSender,
  mergeSuggestions,
  normalizeTrustedSender,
  parseAccountPatch,
  parseCompose,
  parseRule,
  planRules,
  presetList,
  ruleMatches,
} from '../src/webmailRules.js';

const texts = (node) => (node.x ? [node.x] : (node.c ?? []).flatMap(texts));
const find = (node, pred) => (pred(node) ? [node] : (node.c ?? []).flatMap((c) => find(c, pred)));

test('HTML — 스크립트·스타일·양식·숨긴 글은 버리고 글 모양·링크는 남김', () => {
  const { doc, truncated } = htmlToRich(`
    <html><head><style>.a{}</style><script>alert(1)</script></head><body>
    <span style="display:none">미리보기</span>
    <p>보통 <strong>굵게</strong> <em>기울임</em> <u>밑줄</u> <s>취소</s> <code>코드</code>
    <span style="color:#f00;background-color:yellow">색</span> <font color="blue" size="5">큰 파랑</font></p>
    <a href="javascript:alert(1)">나쁜</a> <a href="https://ex.com/x">좋은</a> <a href="mailto:a@b.com">메일</a>
    <form><input value="v"><button>버튼</button><textarea>t</textarea></form>
    <iframe src="https://evil"></iframe><svg><text>s</text></svg>
    </body></html>`);
  assert.equal(truncated, false);
  const all = texts(doc).join('');
  for (const gone of ['미리보기', 'alert', '버튼', '.a{}']) assert.ok(!all.includes(gone), gone);
  const runs = find(doc, (n) => typeof n.x === 'string');
  const by = (t) => runs.find((r) => r.x.includes(t));
  assert.deepEqual(by('굵게').s, { b: 1 });
  assert.deepEqual(by('기울임').s, { i: 1 });
  assert.deepEqual(by('밑줄').s, { u: 1 });
  assert.deepEqual(by('취소').s, { st: 1 });
  assert.deepEqual(by('코드').s, { m: 1 });
  assert.deepEqual(by('색').s, { c: '#ff0000', bg: '#ffff00' });
  assert.deepEqual(by('큰 파랑').s, { c: '#0000ff', z: 1.4 });
  assert.equal(by('나쁜').h, undefined);
  assert.equal(by('좋은').h, 'https://ex.com/x');
  assert.equal(by('메일').h, 'mailto:a@b.com');
});

test('HTML — 그림: cid는 첨부 번호, 바깥은 주소만(센다), 추적 픽셀·이상한 주소는 버림', () => {
  const r = htmlToRich(
    `<img src="cid:Logo%40x" alt="로고"><img src="https://ex.com/a.png" width="300" height="100">
     <img src="https://track.ex.com/p.gif" width="1" height="1"><img src="file:///c:/x.png"><img src="data:image/png;base64,iVBORw0KGgo=">
     <a href="https://ex.com"><img src="https://ex.com/b.png"></a>`,
    { attachments: [{ filename: 'x.pdf' }, { cid: 'logo@x', contentType: 'image/png' }] },
  );
  const imgs = find(r.doc, (n) => n.b === 'img');
  assert.deepEqual(imgs.map((i) => i.src), [{ cid: 1 }, { url: 'https://ex.com/a.png' }, { data: 'iVBORw0KGgo=', mime: 'image/png' }, { url: 'https://ex.com/b.png' }]);
  assert.equal(imgs[0].alt, '로고');
  assert.equal(imgs[1].w, 300);
  assert.equal(imgs[1].ht, 100);
  assert.equal(imgs[3].h, 'https://ex.com/');
  assert.equal(r.remoteImages, 2);
  assert.deepEqual(r.cidIndexes, [1]);
});

test('HTML — 칸 하나짜리 배치용 표는 풀고, 칸이 여럿이면 표(너비·배경)', () => {
  const r = htmlToRich(`<table bgcolor="#eeeeee"><tr><td align="center"><table><tr><td>안쪽</td></tr></table></td></tr></table>
    <table><tr bgcolor="#123456"><td width="30%">왼</td><td style="width:200px">오</td></tr><tr><td></td><td></td></tr></table>`);
  assert.equal(find(r.doc, (n) => n.b === 'table').length, 1);
  const table = find(r.doc, (n) => n.b === 'table')[0];
  assert.equal(table.c.length, 1, '빈 줄은 뺌');
  assert.deepEqual(
    table.c[0].c.map((c) => ({ wp: c.wp, wx: c.wx, bg: c.bg })),
    [
      { wp: 30, wx: undefined, bg: '#123456' },
      { wp: undefined, wx: 200, bg: '#123456' },
    ],
  );
  const centered = find(r.doc, (n) => n.al === 'center');
  assert.ok(centered.length >= 1 && texts(centered[0]).includes('안쪽'));
});

test('HTML — 빈칸 정리·줄바꿈·목록·pre', () => {
  const r = htmlToRich('<p>  하나   둘\n셋 <br>  넷  </p><ol start="3"><li>가</li><li>나</li></ol><pre>a\n  b</pre>');
  const p = find(r.doc, (n) => n.b === 'p')[0];
  assert.deepEqual(p.c, [{ x: '하나 둘 셋' }, { br: 1 }, { x: '넷' }]);
  const ol = find(r.doc, (n) => n.b === 'ol')[0];
  assert.equal(ol.n, 3);
  assert.equal(ol.c.length, 2);
  const pre = find(r.doc, (n) => n.b === 'pre')[0];
  assert.deepEqual(texts(pre), ['a\n  b']);
});

test('HTML — 상한을 넘으면 truncated', () => {
  const r = htmlToRich(`<p>${'가'.repeat(400_000)}</p>`);
  assert.equal(r.truncated, true);
  assert.ok(texts(r.doc).join('').length <= 300_000);
});

test('색·글자 크기·링크 모양', () => {
  assert.equal(parseColor('#ABC'), '#aabbcc');
  assert.equal(parseColor('rgb(1, 2, 3)'), '#010203');
  assert.equal(parseColor('rgba(1,2,3,0)'), null);
  assert.equal(parseColor('transparent'), null);
  assert.equal(parseColor('Red !important'), '#ff0000');
  assert.equal(parseFontScale('28px'), 2);
  assert.equal(parseFontScale('12pt'), 1.14);
  assert.equal(parseFontScale('0'), 0);
  assert.equal(parseFontScale('large'), 1.15);
  assert.equal(safeHref('JavaScript:alert(1)'), null);
  assert.equal(safeHref('data:text/html,x'), null);
  assert.equal(safeHref('https://a.com/ b'), 'https://a.com/%20b');
});

test('받는 규칙 — 입력 검사', () => {
  assert.match(parseRule({}).error, /이름/);
  assert.match(parseRule({ name: 'a', conditions: [] }).error, /조건/);
  assert.match(parseRule({ name: 'a', conditions: [{ field: 'body', op: 'contains', value: 'x' }] }).error, /조건/);
  assert.match(parseRule({ name: 'a', conditions: [{ field: 'from', op: 'contains', value: ' ' }] }).error, /글/);
  assert.match(parseRule({ name: 'a', conditions: [{ field: 'from', op: 'contains', value: 'x' }], actions: {} }).error, /할 일/);
  const ok = parseRule({ name: ' 뉴스 ', match: 'any', conditions: [{ field: 'subject', op: 'is', value: ' 안녕 ' }], actions: { moveTo: '업무', flag: true }, stop: true });
  assert.deepEqual(ok.values, {
    name: '뉴스',
    enabled: true,
    match: 'any',
    conditions: [{ field: 'subject', op: 'is', value: '안녕' }],
    actions: { moveTo: '업무', markSeen: false, flag: true, skipNotify: false },
    stop: true,
  });
});

test('받는 규칙 — 맞추기와 할 일 모으기(옮기기는 처음 것, stop이면 멈춤)', () => {
  const msg = { uid: 5, from: { name: '뉴스', address: 'news@Ex.com' }, to: [{ name: '', address: 'me@a.com' }], cc: [{ address: 'team@a.com' }], subject: '주간 소식', seen: false };
  assert.equal(conditionMatches({ field: 'from', op: 'contains', value: 'ex.com' }, msg), true);
  assert.equal(conditionMatches({ field: 'from', op: 'is', value: 'NEWS@ex.com' }, msg), true);
  assert.equal(conditionMatches({ field: 'to', op: 'contains', value: 'team@' }, msg), true, '참조도 받는 사람');
  assert.equal(conditionMatches({ field: 'subject', op: 'not_contains', value: '광고' }, msg), true);
  assert.equal(conditionMatches({ field: 'subject', op: 'is', value: '주간' }, msg), false);
  const r1 = { enabled: true, match: 'all', conditions: [{ field: 'from', op: 'contains', value: 'ex.com' }], actions: { moveTo: 'A', markSeen: true }, stop: false };
  const r2 = { enabled: true, match: 'any', conditions: [{ field: 'subject', op: 'contains', value: '소식' }], actions: { moveTo: 'B', flag: true, skipNotify: true }, stop: true };
  const r3 = { enabled: true, match: 'all', conditions: [{ field: 'subject', op: 'contains', value: '주간' }], actions: { flag: true }, stop: false };
  assert.equal(ruleMatches({ ...r1, enabled: false }, msg), false);
  const plan = planRules([r1, r2, r3], [msg, { ...msg, uid: 6, from: { address: 'x@y.com' }, subject: 'hi' }]);
  assert.deepEqual([...plan.moves], [['A', [5]]]);
  assert.deepEqual(plan.seen, [5]);
  assert.deepEqual(plan.flagged, [5]);
  assert.deepEqual([...plan.quiet], [5]);
  assert.equal(plan.matched, 1);
});

test('자동 완성 — 주소록 먼저, 앞이 맞는 것 먼저, 같은 주소는 하나', () => {
  const rows = mergeSuggestions({
    q: 'ki',
    directory: [{ name: '김철수', email: 'kim@corp.com' }],
    contacts: [
      { name: null, address: 'kim@corp.com' },
      { name: 'Joe', address: 'joe.kim@x.com' },
      { name: 'Kiwi', address: 'k@fruit.com' },
    ],
  });
  assert.deepEqual(rows, [
    { name: '김철수', address: 'kim@corp.com', member: true },
    { name: 'Kiwi', address: 'k@fruit.com', member: false },
    { name: 'Joe', address: 'joe.kim@x.com', member: false },
  ]);
  assert.deepEqual(mergeSuggestions({ q: ' ', contacts: [{ address: 'a@b.com' }] }), []);
  assert.deepEqual(
    contactsToRecord({ to: [{ name: 'A', address: 'A@x.com' }], cc: [{ name: '', address: 'a@x.com' }], bcc: [{ name: '', address: 'me@x.com' }] }, ['ME@x.com']),
    [{ address: 'a@x.com', name: 'A' }],
  );
});

test('계정 설정·그림 허용·순서', () => {
  assert.deepEqual(parseAccountPatch({ signature: ' 서명\r\n둘째  \n\n', notify: false }).patch, { notify: false, signature: ' 서명\n둘째' });
  assert.deepEqual(parseAccountPatch({ signature: '' }).patch, { signature: null });
  assert.match(parseAccountPatch({ signature: 'x'.repeat(2001) }).error, /2000/);
  assert.match(parseAccountPatch({ signatureOnNew: 'yes' }).error, /설정/);
  assert.match(parseAccountPatch({}).error, /바꿀/);
  assert.equal(normalizeTrustedSender(' A@B.com '), 'a@b.com');
  assert.equal(normalizeTrustedSender('@News.co.kr'), '@news.co.kr');
  assert.equal(normalizeTrustedSender('@x'), null);
  assert.equal(isTrustedSender(['@b.com'], 'Z@B.com'), true);
  assert.equal(isTrustedSender(['a@b.com'], 'c@b.com'), false);
  assert.equal(isFullOrder(['b', 'a'], ['a', 'b']), true);
  assert.equal(isFullOrder(['a', 'a'], ['a', 'b']), false);
  assert.equal(isFullOrder(['a'], ['a', 'b']), false);
});

test('계정 모양 — 회사 메일함·OAuth 이름, 비밀값은 내보내지 않음', () => {
  const local = accountDto({ id: 'L', email: 'bob@corp.test', provider: 'local', authType: 'local', notify: true, trustedSenders: [] });
  assert.equal(local.providerLabel, '회사 메일함');
  assert.equal(local.imap, null);
  const oauth = accountDto({ id: 'O', email: 'a@gmail.com', provider: 'gmail', authType: 'oauth', oauthProvider: 'google', imapHost: 'imap.gmail.com', imapPort: 993, imapSecurity: 'ssl', smtpHost: 'smtp.gmail.com', smtpPort: 465, smtpSecurity: 'ssl', username: 'a@gmail.com', oauthRefreshEnc: 'secret', passwordEnc: 'x' });
  assert.equal(oauth.providerLabel, 'Gmail (Google 로그인)');
  assert.ok(!JSON.stringify(oauth).includes('secret'));
  assert.equal(presetList(['google']).find((p) => p.key === 'gmail').oauth, 'google');
  assert.equal(presetList([]).find((p) => p.key === 'outlook').oauth, null);
});

test('임시 저장 — 받는 사람·제목·본문이 비어도 되고, 이어 온 첨부 번호를 본다', () => {
  assert.match(parseCompose({}).error, /받는 사람/);
  const d = parseCompose({ text: '', draftAttachments: [0, 2] }, { draft: true });
  assert.deepEqual([d.values.subject, d.values.draftAttachments], ['', [0, 2]]);
  assert.match(parseCompose({ to: 'a@b.com', text: 'x', draftAttachments: [1, 1] }).error, /첨부/);
  assert.match(parseCompose({ to: 'a@b.com', text: 'x', draftAttachments: Array.from({ length: 6 }, (_, i) => i), attachments: Array.from({ length: 5 }, () => ({ fileUrl: '/uploads/a' })) }).error, /10개/);
});

test('자체 메일 서버 — 설정 검사·받을 주소·회사 주소', () => {
  assert.deepEqual(parseDomains('Corp.com, corp.co.kr corp.com').list, ['corp.com', 'corp.co.kr']);
  assert.match(parseDomains('corp').error, /도메인/);
  assert.match(parseLocalMailInput({ enabled: true }, {}).error, /도메인/);
  assert.deepEqual(parseLocalMailInput({ enabled: true, domains: 'a.com', port: 2525 }, {}).fields, {
    localMailDomains: 'a.com',
    localMailPort: 2525,
    localMailEnabled: true,
  });
  assert.match(parseLocalMailInput({ port: 0 }).error, /포트/);
  assert.match(parseLocalMailInput({ quotaMb: 10 }).error, /메일함/);
  const s = { localMailEnabled: true, localMailDomains: 'corp.com, corp.kr' };
  assert.equal(localMailReady(s), true);
  assert.equal(localMailReady({ localMailEnabled: true }), false);
  assert.deepEqual(localMailLimits({}), { port: 25, maxBytes: 25 * 1024 * 1024, quotaBytes: 2048 * 1024 * 1024 });
  assert.equal(localAddressOf('Kim.J', s), 'kim.j@corp.com');
  assert.equal(localAddressOf('.bad', s), null);
  assert.equal(localPartOf('Kim+Work@CORP.KR', ['corp.com', 'corp.kr']), 'kim');
  assert.equal(localPartOf('kim@evil.com', ['corp.com']), null, '우리 도메인이 아니면 거절(열린 중계 아님)');
  assert.equal(localPartOf('k!m@corp.com', ['corp.com']), null);
  const row = localSummaryOf({ uid: 3, subject: '', fromName: '김', fromAddress: 'k@x.com', toList: [{ address: 'a@b.com' }], sentAt: new Date(5000), seen: true, draft: true, hasAttachments: false, size: 10 });
  assert.equal(row.subject, '(제목 없음)');
  assert.equal(row.date, 5000);
  assert.equal(row.draft, true);
});

test('OAuth 연결 — 쓸 수 있는지, 로그인 주소, ID 토큰 확인', () => {
  const s = { mailOauthGoogle: true, ssoGoogleClientId: 'cid', ssoGoogleClientSecretEnc: 'enc', mailOauthMicrosoft: true, ssoMicrosoftTenantId: 'nope' };
  assert.equal(mailOAuthProblem('google', s), null);
  assert.match(mailOAuthProblem('google', { ...s, mailOauthGoogle: false }), /꺼져/);
  assert.match(mailOAuthProblem('microsoft', s), /테넌트/);
  const url = new URL(buildMailAuthorizeUrl({ provider: 'google', settings: s, redirectUri: 'https://w/cb', state: 'st', nonce: 'no', codeChallenge: 'ch', loginHint: 'a@gmail.com' }));
  assert.equal(url.origin + url.pathname, 'https://accounts.google.com/o/oauth2/v2/auth');
  assert.equal(url.searchParams.get('prompt'), 'consent');
  assert.equal(url.searchParams.get('login_hint'), 'a@gmail.com');
  assert.match(url.searchParams.get('scope'), /https:\/\/mail\.google\.com\//);
  const claims = { aud: 'cid', iss: 'https://accounts.google.com', exp: Date.now() / 1000 + 60, nonce: 'no', email: 'A@Gmail.com', name: '에이' };
  assert.deepEqual(checkMailIdToken({ provider: 'google', settings: s, claims, nonce: 'no' }), { email: 'a@gmail.com', name: '에이' });
  assert.match(checkMailIdToken({ provider: 'google', settings: s, claims: { ...claims, aud: 'other' }, nonce: 'no' }).error, /다른 앱/);
  assert.match(checkMailIdToken({ provider: 'google', settings: s, claims, nonce: 'x' }).error, /확인 값/);
  assert.match(checkMailIdToken({ provider: 'google', settings: s, claims: { ...claims, email_verified: false }, nonce: 'no' }).error, /확인되지/);
});
