// 설치 초대·팀 초대 링크의 순수 규칙(가입 인원·유효성·만든 사람 권한·안내 페이지) 단위 테스트 — `node --test test/*.test.js`.
// DB에 붙지 않는다: 아래 모듈들은 불러올 때 접속 풀만 만들고(실제 연결은 첫 쿼리 때), 쿼리를 부르면 바로 실패하도록 db를
// 막아 둔다. 접속 주소도 .env보다 먼저 닿지 않는 값으로 정해 둔다(dotenv는 이미 있는 값을 덮지 않는다). 만든 사람을 다시
// 읽는 경로를 보는 테스트만 그 테스트 동안 db.select를 정해 둔 한 줄을 주는 가짜로 바꾼다(fakeCreator).
import assert from 'node:assert/strict';
import { mock, test } from 'node:test';

process.env.DATABASE_URL = 'postgres://test:test@127.0.0.1:1/unused';
const { db } = await import('../src/db/client.js');
for (const method of ['select', 'insert', 'update', 'delete', 'execute', 'transaction']) {
  mock.method(db, method, () => {
    throw new Error(`이 테스트는 DB를 쓰면 안 된다(db.${method})`);
  });
}
const { inviteLinkHasSeat, isInviteLinkOpen, isInviteLinkValid } = await import('../src/db/queries/inviteLinks.js');
const { INVITE_MAX_USES_LIMIT, inviteCreatorAllowed, inviteLinkConnectable, inviteLinkJoinable, inviteMaxUses } = await import(
  '../src/invites.js'
);
const { teamInviteLinkConnectable, teamInviteLinkJoinable, teamInviteMaxUses } = await import('../src/teamInvites.js');
const { createPairHandler, downloadInstaller, inviteRemainingText, inviteUnusableReason, renderInvitePage, renderTeamInvitePage } =
  await import('../src/pairing.js');
const { inviteLinks, teamInviteLinks } = await import('../src/db/schema.js');

const DAY = 24 * 60 * 60 * 1000;
const link = (over = {}) => ({
  id: 'l1',
  token: 'abc123',
  createdBy: 'u1',
  createdByName: '김관리',
  revokedAt: null,
  expiresAt: new Date(Date.now() + 7 * DAY),
  usedCount: 0,
  maxUses: 5,
  ...over,
});
const asTeamLink = (l) => l && { ...l, teamId: 't1', assignedRole: 'member' };

/** 설치 초대·팀 초대 링크를 줄 수 있는 사람(관리자 등급) — 계정·팀 소유 여부·팀 등급 조회가 모두 이 한 줄을 받는다. */
const allowedCreator = { id: 'u1', role: 'admin', isServerAdmin: false, deletedAt: null, suspendedAt: null };

/**
 * 이 테스트 동안 db.select를 표마다 정해 둔 행을 주는 가짜로 바꾼다 — 토큰으로 찾는 설치 초대·팀 초대 링크([inviteLink]·
 * [teamLink], 안 주면 못 찾음)와, 그 밖의 조회(링크를 만든 사람의 계정·팀 소유 여부·팀 등급 — access.js)가 받는 [creator].
 */
function fakeDb(t, { inviteLink = null, teamLink = null, creator = allowedCreator } = {}) {
  t.mock.method(db, 'select', () => {
    let rows = [];
    const query = {
      from: (table) => {
        if (table === inviteLinks) rows = inviteLink ? [inviteLink] : [];
        else if (table === teamInviteLinks) rows = teamLink ? [{ link: teamLink, teamName: teamLink.teamName }] : [];
        else rows = [creator];
        return query;
      },
      innerJoin: () => query,
      where: () => query,
      limit: () => query,
      then: (resolve, reject) => Promise.resolve(rows).then(resolve, reject),
    };
    return query;
  });
}
const fakeCreator = (t, over = {}) => fakeDb(t, { creator: { ...allowedCreator, ...over } });

test('isInviteLinkOpen / inviteLinkHasSeat: 인원이 다 찬 링크도 취소·만료 전에는 열려 있다', () => {
  assert.equal(isInviteLinkOpen(null), false);
  assert.equal(isInviteLinkOpen(link()), true);
  assert.equal(isInviteLinkOpen(link({ usedCount: 5 })), true);
  assert.equal(isInviteLinkOpen(link({ revokedAt: new Date() })), false);
  assert.equal(isInviteLinkOpen(link({ expiresAt: new Date(Date.now() - 1000) })), false);
  assert.equal(inviteLinkHasSeat(link({ usedCount: 4 })), true);
  assert.equal(inviteLinkHasSeat(link({ usedCount: 5 })), false);
  assert.equal(inviteLinkHasSeat(link({ maxUses: null, usedCount: 999 })), true);
});

test('isInviteLinkValid: 만료·취소·인원 마감이면 못 쓴다', () => {
  assert.equal(isInviteLinkValid(null), false);
  assert.equal(isInviteLinkValid(link()), true);
  assert.equal(isInviteLinkValid(link({ usedCount: 4 })), true);
  assert.equal(isInviteLinkValid(link({ usedCount: 5 })), false);
  assert.equal(isInviteLinkValid(link({ usedCount: 6 })), false);
  assert.equal(isInviteLinkValid(link({ revokedAt: new Date() })), false);
  assert.equal(isInviteLinkValid(link({ expiresAt: new Date(Date.now() - 1000) })), false);
  // 인원 칸이 생기기 전에 만든 링크(maxUses null)는 인원 제한이 없다.
  assert.equal(isInviteLinkValid(link({ maxUses: null, usedCount: 999 })), true);
});

test('inviteMaxUses: 기본 1명, 정수만, 최대 100명', () => {
  assert.equal(INVITE_MAX_USES_LIMIT, 100);
  for (const bad of [undefined, null, '', 'abc', 0, -3, 2.5, NaN, {}, []]) assert.equal(inviteMaxUses(bad), 1, String(bad));
  assert.equal(inviteMaxUses(1), 1);
  assert.equal(inviteMaxUses(5), 5);
  assert.equal(inviteMaxUses('30'), 30);
  assert.equal(inviteMaxUses(100), 100);
  assert.equal(inviteMaxUses(101), 100);
  assert.equal(inviteMaxUses(1e9), 100);
});

test('teamInviteMaxUses: 설치 초대와 같은 범위, 관리자 등급을 주는 링크는 늘 1명', () => {
  assert.equal(teamInviteMaxUses(30, 'member'), 30);
  assert.equal(teamInviteMaxUses(500, 'guest'), 100);
  assert.equal(teamInviteMaxUses(undefined, 'member'), 1);
  assert.equal(teamInviteMaxUses(30, 'admin'), 1);
});

test('inviteCreatorAllowed: 서버 운영자·관리자 등급·팀 소유자만, 정지·탈퇴하면 안 된다', () => {
  const user = { id: 'u1', deletedAt: null, suspendedAt: null };
  const access = (over) => ({ user, role: 'member', isServerAdmin: false, isOwnerOfAnyTeam: false, ...over });
  assert.equal(inviteCreatorAllowed(access({ isServerAdmin: true })), true);
  assert.equal(inviteCreatorAllowed(access({ role: 'admin' })), true);
  assert.equal(inviteCreatorAllowed(access({ isOwnerOfAnyTeam: true })), true);
  // 관리자 등급·팀 소유자에서 내려온 뒤.
  assert.equal(inviteCreatorAllowed(access({})), false);
  assert.equal(inviteCreatorAllowed(access({ role: 'guest' })), false);
  // 등급이 그대로여도 정지·탈퇴했으면 링크가 더는 가입 자격을 주지 않는다.
  assert.equal(inviteCreatorAllowed(access({ isServerAdmin: true, user: { ...user, suspendedAt: new Date() } })), false);
  assert.equal(inviteCreatorAllowed(access({ role: 'admin', user: { ...user, deletedAt: new Date() } })), false);
  assert.equal(inviteCreatorAllowed(access({ isServerAdmin: true, user: null })), false);
  assert.equal(inviteCreatorAllowed(null), false);
});

test('…Connectable / …Joinable: 링크 자체가 죽었으면 만든 사람을 볼 것도 없이 못 쓴다', async () => {
  // 여기서 바로 false가 나오지 않으면 만든 사람을 DB에서 읽으려 해서(위에서 막아 둔 db) 테스트가 실패한다.
  const closed = [null, link({ revokedAt: new Date() }), link({ expiresAt: new Date(0) }), link({ createdBy: null })];
  for (const dead of closed) {
    assert.equal(await inviteLinkConnectable(dead), false);
    assert.equal(await teamInviteLinkConnectable(asTeamLink(dead)), false);
  }
  // 가입은 인원이 다 찬 링크도 바로 막힌다.
  for (const dead of [...closed, link({ usedCount: 5 })]) {
    assert.equal(await inviteLinkJoinable(dead), false);
    assert.equal(await teamInviteLinkJoinable(asTeamLink(dead)), false);
  }
});

test('…Connectable: 인원이 다 찬 링크도 만든 사람이 지금 권한이 있으면 연결·설치는 된다(가입은 안 된다)', async (t) => {
  fakeCreator(t);
  const full = link({ usedCount: 5 });
  assert.equal(await inviteLinkConnectable(full), true);
  assert.equal(await teamInviteLinkConnectable(asTeamLink(full)), true);
  assert.equal(await inviteLinkJoinable(full), false);
  assert.equal(await teamInviteLinkJoinable(asTeamLink(full)), false);
  // 자리가 남았으면 가입도 된다. 인원 칸이 생기기 전에 만든 링크(maxUses null)는 인원 제한이 없다.
  for (const seated of [link({ usedCount: 4 }), link({ maxUses: null, usedCount: 999 })]) {
    assert.equal(await inviteLinkJoinable(seated), true);
    assert.equal(await teamInviteLinkJoinable(asTeamLink(seated)), true);
  }
});

test('…Connectable / …Joinable: 만든 사람이 정지·탈퇴했으면 연결도 가입도 안 된다', async (t) => {
  for (const over of [{ suspendedAt: new Date() }, { deletedAt: new Date() }]) {
    await t.test(Object.keys(over)[0], async (st) => {
      fakeCreator(st, over);
      const open = link({ usedCount: 1 });
      assert.equal(await inviteLinkConnectable(open), false);
      assert.equal(await inviteLinkJoinable(open), false);
      assert.equal(await teamInviteLinkConnectable(asTeamLink(open)), false);
      assert.equal(await teamInviteLinkJoinable(asTeamLink(open)), false);
    });
  }
});

test('GET /pair/<초대 토큰>: 인원이 다 찬 링크로도 인증서를 받는다(다른 기기 연결), 못 쓰는 링크는 404', async (t) => {
  const handler = createPairHandler(() => 'CERT');
  const pair = async (code) => {
    const res = {
      statusCode: 200,
      body: null,
      status(c) {
        this.statusCode = c;
        return this;
      },
      json(b) {
        this.body = b;
        return this;
      },
    };
    await handler({ params: { code } }, res);
    return res;
  };
  const cases = [
    ['설치 초대 · 인원 마감', { inviteLink: link({ usedCount: 5 }) }, 200],
    ['팀 초대 · 인원 마감', { teamLink: { ...asTeamLink(link({ usedCount: 5 })), teamName: '개발팀' } }, 200],
    ['설치 초대 · 만료', { inviteLink: link({ expiresAt: new Date(0) }) }, 404],
    ['팀 초대 · 취소', { teamLink: { ...asTeamLink(link({ revokedAt: new Date() })), teamName: '개발팀' } }, 404],
    ['설치 초대 · 만든 사람 정지', { inviteLink: link(), creator: { ...allowedCreator, suspendedAt: new Date() } }, 404],
    ['없는 토큰', {}, 404],
  ];
  for (const [name, rows, status] of cases) {
    await t.test(name, async (st) => {
      fakeDb(st, rows);
      const res = await pair('abc123');
      assert.equal(res.statusCode, status);
      if (status === 200) assert.deepEqual(res.body, { cert: 'CERT' });
    });
  }
});

test('설치 파일 다운로드: 모르는 플랫폼(객체 기본 속성 이름 포함)은 예외 없이 404, 아는 플랫폼은 그 파일만', () => {
  const download = (platform) => {
    const res = {
      statusCode: 200,
      sent: null,
      downloaded: null,
      status(c) {
        this.statusCode = c;
        return this;
      },
      send(b) {
        this.sent = b;
        return this;
      },
      download(file, name) {
        this.downloaded = { file, name };
        return this;
      },
    };
    downloadInstaller({ params: { platform } }, res);
    return res;
  };
  for (const platform of ['constructor', 'toString', 'valueOf', '__proto__', 'hasOwnProperty', 'ios']) {
    const res = download(platform);
    assert.equal(res.statusCode, 404, platform);
    assert.equal(res.sent, '알 수 없는 플랫폼입니다.', platform);
    assert.equal(res.downloaded, null, platform);
  }
  // 아는 플랫폼은 배포된 빌드가 있으면 그 파일을, 없으면 404 안내를 준다(이 PC의 releases 폴더 상태와 상관없이 둘 중 하나).
  for (const [platform, name] of [['windows', 'TangoTalk-Setup.exe'], ['android', 'TangoTalk.apk']]) {
    const res = download(platform);
    if (res.downloaded) assert.equal(res.downloaded.name, name);
    else assert.deepEqual([res.statusCode, res.sent], [404, '아직 배포된 빌드가 없습니다.']);
  }
});

test('inviteRemainingText: 남은 기간과 남은 가입 인원, 예전 링크는 기간만', () => {
  assert.equal(inviteRemainingText(link({ usedCount: 2 })), '남은 기간: 7일 · 남은 가입 인원: 3명');
  assert.equal(inviteRemainingText(link({ maxUses: null, usedCount: 2 })), '남은 기간: 7일');
  assert.equal(inviteRemainingText(link({ expiresAt: new Date(Date.now() + 3 * 60 * 60 * 1000), maxUses: 1 })), '남은 기간: 하루 · 남은 가입 인원: 1명');
});

test('inviteUnusableReason: 취소 > 만료 > 그 밖(만든 사람이 권한을 잃음) — 인원 마감은 연결을 막는 이유가 아니다', () => {
  assert.equal(inviteUnusableReason(link({ revokedAt: new Date(), expiresAt: new Date(0) })), '취소되었습니다');
  assert.equal(inviteUnusableReason(link({ usedCount: 5, expiresAt: new Date(0) })), '만료되었습니다');
  assert.equal(inviteUnusableReason(link({ expiresAt: new Date(0) })), '만료되었습니다');
  // 연결할 수 없는데 취소·만료도 아니면(인원이 찼든 말든) 만든 사람이 권한을 잃은 것이다.
  assert.equal(inviteUnusableReason(link({ usedCount: 5 })), '더 이상 쓸 수 없습니다');
  assert.equal(inviteUnusableReason(link()), '더 이상 쓸 수 없습니다');
});

test('설치 초대 안내 페이지: 남은 인원과 설치 버튼, 인원이 차도 설치·연결은 되고 가입만 마감, 못 쓰면 이유만', () => {
  const base = { serverAddress: 'https://192.168.0.10:3010', token: 'abc123', outside: false };
  const ok = renderInvitePage({ ...base, link: link({ usedCount: 1 }), connectable: true });
  assert.match(ok, /남은 가입 인원: 4명/);
  assert.match(ok, /\/invite\/abc123\/download\/windows/);
  assert.match(ok, /"연결"을 클릭하고 회원가입하세요/);
  assert.match(ok, /이미 계정이 있다면 바로 로그인하시고/);
  assert.doesNotMatch(ok, /가입 인원 마감/);

  // 인원이 다 찬 링크 — 이미 가입한 사람이 집 PC 등 다른 기기에 설치·연결할 수 있게 설치 버튼과 앱 열기는 그대로 둔다.
  const full = renderInvitePage({ ...base, link: link({ usedCount: 5 }), connectable: true });
  assert.match(full, /가입 인원 마감/);
  assert.match(full, /사내 와이파이 밖에서는 이 링크로 더 가입할 수 없습니다/);
  assert.match(full, /이미 가입한 분은 이 링크로 다른 기기에 설치하고 로그인할 수 있습니다/);
  assert.match(full, /\/invite\/abc123\/download\/windows/);
  assert.match(full, /tangotalk:\/\/pair\//);
  assert.match(full, /"연결"을 클릭하고 로그인하세요/);
  assert.doesNotMatch(full, /회원가입하세요/);
  assert.doesNotMatch(full, /이미 계정이 있다면/); // 이미 가입한 사람이 오는 링크라 가입 전제의 계정 안내는 뺀다.

  // 만든 사람이 권한을 잃은 링크 — 링크 자체는 멀쩡해도 라우트가 connectable: false로 넘긴다.
  const orphan = renderInvitePage({ ...base, link: link(), connectable: false });
  assert.match(orphan, /이 링크는 더 이상 쓸 수 없습니다\./);
  assert.doesNotMatch(orphan, /download/);
  assert.doesNotMatch(orphan, /tangotalk:\/\//); // 못 쓰는 링크로는 앱도 열지 않는다.

  const expired = renderInvitePage({ ...base, link: link({ usedCount: 5, expiresAt: new Date(0) }), connectable: false });
  assert.match(expired, /이 링크는 만료되었습니다\./);
  assert.doesNotMatch(expired, /download/);

  assert.match(renderInvitePage({ ...base, link: null, connectable: false }), /유효하지 않은 초대 링크입니다/);
});

test('팀 초대 안내 페이지: 남은 가입 인원을 보여주고, 인원이 차면 자동 합류 약속 대신 마감 안내(설치·연결은 된다)', () => {
  const base = { serverAddress: 'https://192.168.0.10:3010', token: 't0k', outside: true };
  const teamLink = (over) => link({ teamName: '개발팀', assignedRole: 'member', maxUses: 10, ...over });
  const ok = renderTeamInvitePage({ ...base, link: teamLink({ usedCount: 3 }), connectable: true });
  assert.match(ok, /개발팀/);
  assert.match(ok, /남은 가입 인원: 7명/);
  assert.match(ok, /자동으로 이 팀에 합류하고/);
  assert.match(ok, /공용 와이파이/); // 밖에서 열면 공용 와이파이 주의가 붙는다.
  assert.match(ok, /이미 계정이 있다면 이 링크로는 팀에 자동 합류되지 않습니다/);

  const full = renderTeamInvitePage({ ...base, link: teamLink({ usedCount: 10 }), connectable: true });
  assert.match(full, /가입 인원 마감/);
  assert.match(full, /팀에 자동으로 들어가지 않고, 사내 와이파이 밖에서는 가입도 할 수 없습니다/);
  assert.doesNotMatch(full, /자동으로 이 팀에 합류하고/);
  assert.doesNotMatch(full, /가입하면 개발팀 팀에 자동으로 들어갑니다/);
  assert.match(full, /\/team-invite\/t0k\/download\/android/);
  assert.match(full, /"연결"을 클릭하고 로그인하세요/);
  // 인원이 다 찬 링크로 오는 사람은 대개 이미 이 링크로 가입해 다른 기기를 연결하는 사람이다 — "이미 계정이 있다면 자동
  // 합류되지 않는다"는 안내는 그 사람에게 엉뚱하게 읽혀서 뺀다(설치 초대 페이지와 같다).
  assert.doesNotMatch(full, /이미 계정이 있다면/);

  const revoked = renderTeamInvitePage({ ...base, link: teamLink({ revokedAt: new Date() }), connectable: false });
  assert.match(revoked, /이 링크는 취소되었습니다\./);
  assert.doesNotMatch(revoked, /download/);
});
