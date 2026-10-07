// 초대 안내 페이지(설치 초대·팀 초대)의 아이폰 안내 단위 테스트 — `node --test test/*.test.js`.
// 아이폰에는 설치형 앱이 없어서 웹 앱 주소를 알려 주는데, 그 주소는 공인 인증서가 실제로 걸려 있을 때만(webAddress.js의
// getWebPublicUrl) 값이 있다. DB에 붙지 않는다: pairing.js가 불러오는 DB 모듈은 접속 풀만 만들므로(실제 연결은 첫 쿼리 때)
// inviteLinks.test.js처럼 닿지 않는 접속 주소를 먼저 정해 두고, 쿼리를 부르면 바로 실패하도록 db를 막아 둔다.
import assert from 'node:assert/strict';
import { after, mock, test } from 'node:test';

process.env.DATABASE_URL = 'postgres://test:test@127.0.0.1:1/unused';
const { db } = await import('../src/db/client.js');
for (const method of ['select', 'insert', 'update', 'delete', 'execute', 'transaction']) {
  mock.method(db, method, () => {
    throw new Error(`이 테스트는 DB를 쓰면 안 된다(db.${method})`);
  });
}
const { renderInvitePage, renderTeamInvitePage } = await import('../src/pairing.js');
const { getWebPublicUrl, setWebPublicUrl } = await import('../src/webAddress.js');

after(() => setWebPublicUrl(null));

const DAY = 24 * 60 * 60 * 1000;
// 서버가 만드는 초대 코드와 같은 모양(16진수 24자 — invites.js·teamInvites.js).
const TOKEN = 'a1b2c3d4e5f60718293a4b5c';
const link = (over = {}) => ({
  id: 'l1',
  token: TOKEN,
  createdBy: 'u1',
  createdByName: '김관리',
  revokedAt: null,
  expiresAt: new Date(Date.now() + 7 * DAY),
  usedCount: 0,
  maxUses: 5,
  teamName: '개발팀',
  assignedRole: 'member',
  ...over,
});
const base = { serverAddress: 'https://xxx.iptime.org:3000', token: TOKEN, outside: true };
const pages = [
  ['설치 초대', renderInvitePage],
  ['팀 초대', renderTeamInvitePage],
];
const IPHONE = '아이폰은 앱 대신 웹 앱을 씁니다';
// 웹 앱 주소에 초대 코드를 붙여(?invite=) 알려 준다 — 웹 앱이 그 코드로 가입해서 사내 와이파이 밖에서도 가입되고, 팀 초대면 팀
// 자동 합류도 받는다(client web_launch_invite.dart → auth.js /register).
const SIGNUP_NOTE = '처음 가입할 때는 꼭 이 주소로 여세요 — 초대 코드가 들어 있어 사내 와이파이 밖에서도 가입됩니다.';

/** 아이폰 안내 상자(.ios-web) 안의 글만 — 같은 문구가 상자 밖(설치 안내 등)에 있어서 맞는 것으로 치지 않게. */
function iphoneBox(html) {
  const start = html.indexOf('<div class="ios-web">');
  return start < 0 ? '' : html.slice(start, html.indexOf('</div>', start));
}

test('웹 앱 주소가 없으면(공인 인증서 없음·기능 꺼짐) 아이폰 안내를 넣지 않는다', () => {
  setWebPublicUrl(null);
  assert.equal(getWebPublicUrl(), null);
  for (const [name, render] of pages) {
    const html = render({ ...base, link: link(), connectable: true });
    assert.doesNotMatch(html, new RegExp(IPHONE), name);
    assert.doesNotMatch(html, /class="ios-web"/, name);
    assert.ok(!html.includes('?invite='), name);
    assert.match(html, /Windows용 다운로드/, name); // 나머지 안내는 그대로다.
  }
});

test('공인 인증서가 걸려 있으면 설치 버튼 아래에 초대 코드를 붙인 웹 앱 주소와 Safari·홈 화면 추가 안내를 넣는다', () => {
  setWebPublicUrl('https://xxx.iptime.org');
  const url = `https://xxx\\.iptime\\.org/\\?invite=${TOKEN}`;
  for (const [name, render] of pages) {
    const html = render({ ...base, link: link(), connectable: true });
    assert.match(html, new RegExp(`${IPHONE}:</b> <a href="${url}">${url}</a> 을 Safari로 열어 가입하고 홈 화면에 추가하세요`), name);
    assert.match(html, /홈 화면에서 열어야 새 메시지 알림도 받을 수 있습니다/, name);
    assert.ok(iphoneBox(html).includes(SIGNUP_NOTE), name);
    // 설치 버튼(Windows·Android) 다음, 설치 후 안내 앞 — "어느 기기로 쓰나"를 한 묶음으로 본다.
    const downloads = html.indexOf('Android용 다운로드');
    const iphone = html.indexOf(IPHONE);
    const steps = html.indexOf('설치가 끝나면 이 페이지를 새로고침 하세요');
    assert.ok(downloads >= 0 && downloads < iphone && iphone < steps, name);
  }
});

test('웹 포트가 443이 아니면 주소에 포트까지 그대로 보인다', () => {
  setWebPublicUrl('https://xxx.iptime.org:8443');
  for (const [name, render] of pages) {
    const html = render({ ...base, link: link(), connectable: true });
    assert.ok(html.includes(`<a href="https://xxx.iptime.org:8443/?invite=${TOKEN}">`), name);
  }
});

test('팀 초대도 같은 주소로 안내한다 — 웹 앱 가입도 초대 코드를 보내 팀 자동 합류를 받는다', () => {
  setWebPublicUrl('https://xxx.iptime.org');
  const team = iphoneBox(renderTeamInvitePage({ ...base, link: link(), connectable: true }));
  assert.ok(team.includes(`?invite=${TOKEN}`));
  assert.ok(!team.includes('자동으로 들어가지 않습니다'));
  assert.ok(!team.includes('사내 와이파이에서만'));
});

test('인원이 다 찬 링크(이미 가입한 사람이 다른 기기를 연결할 때)에는 초대 코드 없이 로그인 주소로 안내한다', () => {
  setWebPublicUrl('https://xxx.iptime.org');
  for (const [name, render] of pages) {
    const html = render({ ...base, link: link({ usedCount: 5 }), connectable: true });
    assert.match(html, /가입 인원 마감/, name);
    const box = iphoneBox(html);
    assert.ok(box.includes(IPHONE), name);
    assert.ok(box.includes('<a href="https://xxx.iptime.org">https://xxx.iptime.org</a> 을 Safari로 열어 로그인하고'), name);
    assert.ok(!box.includes('?invite='), name);
    assert.ok(!box.includes(SIGNUP_NOTE), name);
  }
});

test('못 쓰는 링크(취소·만료·없는 토큰)에는 설치 안내처럼 아이폰 안내도 없다', () => {
  setWebPublicUrl('https://xxx.iptime.org');
  for (const [name, render] of pages) {
    for (const [why, l] of [
      ['취소', link({ revokedAt: new Date() })],
      ['만료', link({ expiresAt: new Date(0) })],
      ['없음', null],
    ]) {
      const html = render({ ...base, link: l, connectable: false });
      assert.doesNotMatch(html, new RegExp(IPHONE), `${name} · ${why}`);
      assert.doesNotMatch(html, /xxx\.iptime\.org/, `${name} · ${why}`);
      assert.doesNotMatch(html, /class="ios-web"/, `${name} · ${why}`);
    }
  }
});

test('webUrl을 직접 넘기면 그 값을 쓴다 — null이면 공인 인증서가 있어도 넣지 않는다', () => {
  setWebPublicUrl('https://xxx.iptime.org');
  for (const [name, render] of pages) {
    assert.doesNotMatch(render({ ...base, link: link(), connectable: true, webUrl: null }), new RegExp(IPHONE), name);
    assert.ok(
      render({ ...base, link: link(), connectable: true, webUrl: 'https://chat.example.com' }).includes(
        `<a href="https://chat.example.com/?invite=${TOKEN}">`,
      ),
      name,
    );
  }
});

test('초대 코드 모양이 아니면 주소에 붙이지 않는다(로그인 주소로만 안내)', () => {
  setWebPublicUrl('https://xxx.iptime.org');
  for (const [name, render] of pages) {
    for (const bad of ['abc', 'a"b<c>d&e1234', 'x'.repeat(200)]) {
      const box = iphoneBox(render({ ...base, token: bad, link: link({ token: bad }), connectable: true }));
      assert.ok(box.includes('<a href="https://xxx.iptime.org">'), `${name} · ${bad}`);
      assert.ok(!box.includes('?invite='), `${name} · ${bad}`);
    }
  }
});

test('https 주소가 아니면 안내하지 않고, 주소 속 특수 문자는 이스케이프한다', () => {
  for (const [name, render] of pages) {
    for (const bad of ['http://xxx.iptime.org', 'javascript:alert(1)', 'xxx.iptime.org', '', 'https://']) {
      const html = render({ ...base, link: link(), connectable: true, webUrl: bad });
      assert.doesNotMatch(html, new RegExp(IPHONE), `${name} · ${bad}`);
      assert.doesNotMatch(html, /class="ios-web"/, `${name} · ${bad}`);
    }
    const html = render({ ...base, link: link(), connectable: true, webUrl: 'https://a.example/"><script>x</script>' });
    assert.match(html, new RegExp(IPHONE), name);
    assert.doesNotMatch(html, /<script>x<\/script>/, name);
    assert.ok(html.includes('href="https://a.example/&quot;&gt;&lt;script&gt;x&lt;/script&gt;/?invite='), name);
  }
});

test('아이폰·아이패드에서는 tangotalk:// 앱 열기를 시도하지 않는다(Safari "주소가 유효하지 않음" 경고 방지)', () => {
  setWebPublicUrl(null);
  for (const [name, render] of pages) {
    const html = render({ ...base, link: link(), connectable: true });
    assert.match(html, /var noInstalledApp = \/iPhone\|iPad\|iPod\/\.test\(navigator\.userAgent\)/, name);
    assert.match(html, /navigator\.platform === 'MacIntel' && navigator\.maxTouchPoints > 1/, name);
    assert.match(html, /function tryDeepLink\(\) \{ if \(noInstalledApp\) return; try \{ window\.location\.href = "tangotalk:\/\/pair\//, name);
    // 다른 기기에서는 지금처럼 열자마자, 그리고 탭이 다시 보일 때마다 시도한다.
    assert.match(html, /\ntryDeepLink\(\);\n/, name);
    assert.match(html, /visibilitychange/, name);
  }
});
