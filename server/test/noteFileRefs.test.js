// 프로젝트 노트 본문 속 파일 링크 검사 단위 테스트(S22) — `node --test test/noteFileRefs.test.js` (DB·서버 없이 돈다).
// 노트 본문의 `](/uploads/…)`는 볼 때마다 새로 서명되므로(projects.js signNoteBody), 저장할 때 본문 속 이 서버 파일 링크를 하나씩 본다:
// 쓴 사람이 올린 파일·이 노트(되돌리는 이력)에 원래 있던 파일·서명 링크로 온 지금 볼 수 있는 파일(구성원인 프로젝트의 노트·이력, 들어가
// 있는 방)만 남기고, 나머지는 저장을 거절하지 않고 글자로 바꾼다(fileRefRules.js — rewriteNoteFileLinks, fileRefs.js filterNoteFileLinks).
// 노트 사이 복사·복제 판단은 db/queries/uploads.js findNoteReachableUploadPaths — 실제 쿼리 빌더에 SQL을 받아 적는 가짜 pg 클라이언트를
// 붙여 본다(접속 주소도 닿지 않는 값으로 정해 둔다 — fileRefCheck.test.js와 같은 방식).
import assert from 'node:assert/strict';
import nodeCrypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { mock, test } from 'node:test';
import jwt from 'jsonwebtoken';
import { drizzle } from 'drizzle-orm/node-postgres';
import {
  decideNoteFileTargets,
  noteFilePaths,
  noteFileTargets,
  rewriteNoteFileLinks,
  signNoteFileLinks,
} from '../src/fileRefRules.js';
import { isNoteImageTarget, noteBodyWithoutExternalImages } from '../src/projectNotifications.js';
import { signFileUrl } from '../src/upload.js';

process.env.DATABASE_URL = 'postgres://test:test@127.0.0.1:1/unused';
const { db } = await import('../src/db/client.js');
for (const method of ['select', 'insert', 'update', 'delete', 'execute', 'transaction']) {
  mock.method(db, method, () => {
    throw new Error(`이 테스트는 DB를 쓰면 안 된다(db.${method})`);
  });
}
const { filterNoteFileLinks } = await import('../src/fileRefs.js');
const { findNoteReachableUploadPaths } = await import('../src/db/queries/uploads.js');

const WRITER = '11111111-1111-4111-8111-111111111111';
const OTHER = '22222222-2222-4222-8222-222222222222';
const MINE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.png';
const THEIRS = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.png';
const DOC = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd.pdf';
const OLD = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc.jpg'; // uploads 표가 생기기 전에 올린 파일 — 기록이 없다.
const stored = (name) => `/uploads/${name}`;
const uploaders = new Map([
  [MINE, WRITER],
  [THEIRS, OTHER],
  [DOC, OTHER],
]);

/** [hours]시간 전에 서명된 링크 — 최대 2시간이라 이미 만료된 것(편집 창을 오래 열어 둔 경우). */
function signedHoursAgo(p, hours) {
  const issuedAt = Date.now() - hours * 60 * 60 * 1000;
  const clock = mock.method(Date, 'now', () => issuedAt);
  try {
    return signFileUrl(p);
  } finally {
    clock.mock.restore();
  }
}

/**
 * 서명(projects.js signNoteBody — fileRefRules.js signNoteFileLinks)이 이 본문에서 서명해 줄 파일 이름들 — 서버가 쓰는 서명 함수에
 * 기록만 하는 서명을 넣어 본다. 이름은 upload.js signFileUrl이 쓰는 basename 그대로(Windows 포함).
 */
function signedFileNames(body) {
  const names = [];
  signNoteFileLinks(body, (p) => {
    names.push(path.posix.basename(p), path.win32.basename(p));
    return p;
  });
  return names;
}

/**
 * 작은 결정적 난수(테스트가 매번 같은 본문을 만들게) — [seed]마다 다른 줄기(C rand()와 같은 선형 합동, 2^31로 나눈 나머지). 곱셈은
 * Math.imul로 32비트 그대로 한다(그냥 곱하면 2^53을 넘어 아랫자리가 반올림으로 사라진다). 값은 윗자리(16비트 위)를 쓴다: 이 방식의
 * 아랫자리는 주기가 짧아서 `% n`으로 쓰면 어떤 조각 순서는 아예 나오지 않는다.
 */
function seededRandom(seed) {
  let s = seed;
  return (n) => {
    s = (Math.imul(s, 1103515245) + 12345) & 0x7fffffff;
    return (s >>> 16) % n;
  };
}

const RANDOM_MINE_SIGNED = signFileUrl(stored(MINE));
const RANDOM_THEIRS_SIGNED = signFileUrl(stored(THEIRS));
/** 링크 문법 조각을 무작위로 이은 본문([rand] — seededRandom, 조각 1..[maxPieces]개). '\r'도 섞여 있다. */
function randomNoteBody(rand, maxPieces) {
  const pieces = [
    ']', '[', '!', '(', ')', '\n', '\r', ' ', 'a', '그림', '\\', '/x', '#', '![', '[[', ']]',
    `](${stored(MINE)})`, `](${stored(THEIRS)})`, `(${stored(THEIRS)})`, stored(THEIRS), THEIRS,
    `](${RANDOM_MINE_SIGNED})`, `](${RANDOM_THEIRS_SIGNED})`, `(${RANDOM_THEIRS_SIGNED})`, `![x](${stored(THEIRS)})`,
    `[y](${RANDOM_MINE_SIGNED})`, '](http://evil.example/t.png)', '(http://evil.example/t.png)', '](/uploads/', '](/files/',
    `/uploads/${MINE}`, '](/uploads/a', '[b c',
  ];
  let raw = '';
  for (let k = 1 + rand(maxPieces); k > 0; k--) raw += pieces[rand(pieces.length)];
  return raw;
}

/** 가짜 조회 — 부른 기록을 남긴다. [noteReachable]은 내가 구성원인 프로젝트의 노트·이력에 있는 경로, [roomReachable]은 방의 경로. */
function fakeLookups({ noteReachable = [], roomReachable = [] } = {}) {
  const calls = { uploaders: [], notes: [], rooms: [] };
  return {
    calls,
    async findUploaders(names) {
      calls.uploaders.push(names);
      return new Map(names.filter((n) => uploaders.has(n)).map((n) => [n, uploaders.get(n)]));
    },
    async findNoteReachableUploadPaths(userId, paths) {
      calls.notes.push({ userId, paths });
      return new Set(paths.filter((p) => noteReachable.includes(p)));
    },
    async findReachableUploadPaths(userId, paths) {
      calls.rooms.push({ userId, paths });
      return new Set(paths.filter((p) => roomReachable.includes(p)));
    },
  };
}

// ── 규칙(fileRefRules.js) ─────────────────────────────────────────────

test('noteFileTargets: 그림·링크·맨 `](주소)`의 이 서버 파일 주소만, 본문 그대로(중복 없이) — 바깥 주소·다른 경로는 아니다', () => {
  const signed = signFileUrl(stored(THEIRS));
  const body = [
    `![도면.png](${stored(MINE)})`,
    `[보고서](${signed}) 참고, 다시 [보고서](${signed})`,
    `이상한 모양 [a [b] c](${stored(DOC)})`,
    '[웹](https://example.test/a.png) ![밖](http://10.0.0.1/x.png) [상대](uploads/x.png) [노트](#)',
    `하위 경로 [x](/uploads/sub/${THEIRS}) 빈 [y](/uploads/) 가짜 [z](/files/garbage)`,
  ].join('\n');
  assert.deepEqual(noteFileTargets(body), [
    stored(MINE),
    signed,
    stored(DOC),
    `/uploads/sub/${THEIRS}`,
    '/uploads/',
    '/files/garbage',
  ]);
  assert.deepEqual(noteFileTargets(''), []);
  assert.deepEqual(noteFileTargets(null), []);
  assert.deepEqual(noteFileTargets('링크 없는 글 (괄호) [대괄호]'), []);
});

test('noteFilePaths: 지금 본문에 있던 파일 — 저장 경로, 서명이 맞는 예전 /files/ 링크(만료돼도)는 그 파일로, 알아볼 수 없는 것은 빼고', () => {
  const body = [
    `![a](${stored(THEIRS)})`,
    `[b](${signedHoursAgo(stored(DOC), 30)})`,
    '[c](/files/garbage)',
    `[d](/uploads/sub/${OLD})`,
    `[e](${stored(THEIRS)})`,
  ].join('\n');
  assert.deepEqual(noteFilePaths(body), [stored(THEIRS), stored(DOC)]);
  assert.deepEqual(noteFilePaths(undefined), []);
});

test('decideNoteFileTargets: 주소마다 따로 — 내가 올린 것·원래 있던 것·서명 링크로 온 볼 수 있는 것만 저장 경로로', () => {
  const theirsSigned = signedHoursAgo(stored(THEIRS), 5);
  const docSigned = signFileUrl(stored(DOC));
  const legacyJwt = `/files/${jwt.sign({ file: THEIRS, type: 'file' }, 'any-secret')}`;
  const targets = [
    stored(MINE), // 내가 올림(업로드 응답 그대로)
    signFileUrl(stored(MINE)), // 내가 올림(서명 링크로)
    stored(THEIRS), // 남의 파일 이름을 그대로 — 볼 수 있는 곳에 있어도 받지 않는다
    theirsSigned, // 남의 파일 서명 링크 — 볼 수 있으면(아래 reachable) 받는다
    docSigned, // 남의 파일 서명 링크 — 볼 수 없다
    stored(OLD), // 기록 없는 옛 파일 — 원래 있던 파일이면 받는다(아래 existing)
    `/uploads/sub/${MINE}`, // 하위 경로 — 서명은 마지막 마디를 떼어 쓰므로 알아볼 수 없는 것으로 버린다
    legacyJwt, // 예전 JWT 링크
  ];
  const accepted = decideNoteFileTargets(targets, {
    senderId: WRITER,
    existing: [stored(OLD)],
    uploaders,
    reachable: new Set([stored(THEIRS)]),
  });
  assert.deepEqual([...accepted], [
    [stored(MINE), stored(MINE)],
    [targets[1], stored(MINE)],
    [theirsSigned, stored(THEIRS)],
    [stored(OLD), stored(OLD)],
  ]);
  // 쓴 사람을 모르면(null) 올린 사람 기록과 맞춰 보지 않는다.
  assert.equal(decideNoteFileTargets([stored(MINE)], { senderId: null, uploaders }).size, 0);
});

test('decideNoteFileTargets: 링크로 다시 쓰면 문법이 흐트러지는 이름(괄호·대괄호·공백)의 파일은 내 파일이어도 받지 않는다', () => {
  const odd = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee.p](x';
  const own = new Map([[odd, WRITER]]);
  assert.equal(decideNoteFileTargets([stored(odd)], { senderId: WRITER, uploaders: own }).size, 0);
  assert.equal(decideNoteFileTargets([signFileUrl(stored('ffff.p ng'))], { senderId: WRITER, uploaders: new Map([['ffff.p ng', WRITER]]) }).size, 0);
});

test('rewriteNoteFileLinks: 받은 링크는 저장 경로로, 받지 못한 링크는 글자만 — 그림은 이름(없으면 "그림"), 링크는 글', () => {
  const mineSigned = signedHoursAgo(stored(MINE), 3);
  const accepted = new Map([
    [mineSigned, stored(MINE)],
    [stored(MINE), stored(MINE)],
  ]);
  const body = [
    `![도면.png](${mineSigned})`,
    `> [내 파일](${stored(MINE)}) 확인`,
    `![남의 그림](${stored(THEIRS)})`,
    `![](${stored(THEIRS)})`,
    `!![느낌표 둘](${stored(THEIRS)})`,
    `회의록 [남의 문서](${signFileUrl(stored(DOC))}) 참고`,
    '[가짜](/files/garbage) 끝',
    '[웹 링크](https://example.test/x)는 그대로',
  ].join('\n');
  assert.equal(
    rewriteNoteFileLinks(body, accepted),
    [
      `![도면.png](${stored(MINE)})`,
      `> [내 파일](${stored(MINE)}) 확인`,
      '남의 그림',
      '그림',
      '!느낌표 둘',
      '회의록 남의 문서 참고',
      '가짜 끝',
      '[웹 링크](https://example.test/x)는 그대로',
    ].join('\n'),
  );
  // 이름 칸을 알아볼 수 없는 맨 `](주소)`는 주소만 지우고 글자(']' 포함)는 남긴다.
  assert.equal(rewriteNoteFileLinks(`[a [b] c](${stored(THEIRS)}) 뒤`, accepted), '[a [b] c] 뒤');
  assert.equal(rewriteNoteFileLinks(`줄바꿈 [a\nb](${stored(THEIRS)})`, accepted), '줄바꿈 [a\nb]');
  // 받은 맨 `](주소)`도 저장 경로로.
  assert.equal(rewriteNoteFileLinks(`[a [b] c](${mineSigned})`, accepted), `[a [b] c](${stored(MINE)})`);
  assert.equal(rewriteNoteFileLinks('', accepted), '');
  assert.equal(rewriteNoteFileLinks('파일 링크 없음', accepted), '파일 링크 없음');
});

test('rewriteNoteFileLinks: 글자로 바꾼 자리가 앞뒤와 이어져 새 링크가 생기면 그 주소도 지운다(서명이 받지 않은 파일을 찾지 못하게)', () => {
  const accepted = new Map([[stored(MINE), stored(MINE)]]);
  const crafted = [
    // 받지 못한 링크의 글이 '('로 시작하고 앞에 ']'가 있으면, 바꾼 뒤 `[a](/uploads/남의 것)`이 생긴다.
    `[a][(${stored(THEIRS)})](${stored(DOC)})`,
    // 맨 `](주소)`를 지운 자리의 ']'와 뒤의 '('가 이어진다.
    `]](${stored(DOC)})(${stored(THEIRS)})`,
    // 받지 못한 링크(글 없음)가 사라지며 앞의 ']'와 뒤의 '('가 이어진다.
    `x][](${stored(DOC)})(${stored(THEIRS)})`,
    // 주소 칸 안에 숨긴 `](/uploads/…` — 주소째 지운다.
    `[a](/files/x](${stored(THEIRS)})`,
    `[a](${stored(MINE)}\\${THEIRS})`,
  ];
  for (const body of crafted) {
    const out = rewriteNoteFileLinks(body, accepted);
    assert.deepEqual(signedFileNames(out).filter((n) => n !== MINE), [], `${body} → ${out}`);
    assert.doesNotMatch(out, /\]\(\/files\//, out);
  }
  // 받은 것은 그대로 남는다.
  assert.equal(rewriteNoteFileLinks(`[a][(${stored(THEIRS)})](${stored(MINE)})`, accepted), `[a][(${stored(THEIRS)})](${stored(MINE)})`);
});

test('저장 경로 전체(\\r 지우기 → 파일 링크 → 바깥 그림): 무작위 본문에서도 서명되는 것은 받은 파일뿐이고, 바깥 그림은 남지 않는다', () => {
  const rand = seededRandom(22);
  const appImageUrls = (md) =>
    md.split('\n').flatMap((line) => {
      const m = /^!\[([^\]]*)\]\(([^)\s]+)\)\s*$/.exec(line.trim());
      return m ? [m[2]] : [];
    });
  for (let i = 0; i < 4000; i++) {
    const raw = randomNoteBody(rand, 16);
    const body = raw.replace(/\r/g, '');
    const accepted = decideNoteFileTargets(noteFileTargets(body), { senderId: WRITER, uploaders });
    const out = noteBodyWithoutExternalImages(rewriteNoteFileLinks(body, accepted));
    // 노트를 열 때와 똑같이(projects.js signNoteBody: 바깥 그림을 한 번 더 바꾼 뒤 서명) 본다.
    assert.deepEqual(signedFileNames(noteBodyWithoutExternalImages(out)).filter((n) => n !== MINE), [], JSON.stringify({ raw, out }));
    assert.doesNotMatch(out, /\]\(\/files\/[^)\s]*\)/, JSON.stringify({ raw, out }));
    assert.deepEqual(appImageUrls(out).filter((u) => !isNoteImageTarget(u)), [], JSON.stringify({ raw, out }));
  }
});

// 예전 모양(시작점마다 끝까지 다시 읽어 시간이 본문 길이의 제곱으로 늘던 것) — 지금 모양이 찾는 링크와 서명하는 링크가 그대로인지
// 맞춰 보는 기준. 바꾼 것은 시간뿐이어야 한다.
const QUADRATIC_LINK_PATTERN =
  /(!*)\[([^\]\n]*)\]\(((?:\/uploads\/|\/files\/)[^)\s]*)\)|\]\(((?:\/uploads\/|\/files\/)[^)\s]*)\)/g;
const QUADRATIC_SIGN_PATTERN = /\]\((\/uploads\/[^)\s]+)\)/g;

test('지금 모양은 예전 모양과 같은 링크를 같은 차례로 찾고(noteFileTargets), 같은 링크를 서명한다(signNoteFileLinks) — 무작위 본문', () => {
  const rand = seededRandom(5);
  const sign = (p) => `/files/<${p}>`;
  for (let i = 0; i < 6000; i++) {
    const body = randomNoteBody(rand, 24).replace(/\r/g, '');
    const before = [...new Set([...body.matchAll(QUADRATIC_LINK_PATTERN)].map((m) => m[3] ?? m[4]))];
    assert.deepEqual(noteFileTargets(body), before, JSON.stringify(body));
    assert.equal(
      signNoteFileLinks(body, sign),
      body.replace(QUADRATIC_SIGN_PATTERN, (_, p) => `](${sign(p)})`),
      JSON.stringify(body),
    );
  }
});

test('닫히지 않은 주소 칸은 링크가 아니다 — 찾지도·바꾸지도·서명하지도 않고 글 그대로 둔다', () => {
  const accepted = new Map([[stored(MINE), stored(MINE)]]);
  const body = `열린 칸 ](/uploads/${THEIRS} 그리고 [글](/files/abc\n다음 줄 [내 것](${stored(MINE)}) 끝 ](/uploads/`;
  assert.deepEqual(noteFileTargets(body), [stored(MINE)]);
  assert.equal(rewriteNoteFileLinks(body, accepted), body);
  assert.equal(
    signNoteFileLinks(body, (p) => `/files/<${p}>`),
    body.replace(`](${stored(MINE)})`, `](/files/<${stored(MINE)}>)`),
  );
  // 닫히지 않은 칸 바로 뒤에서 시작해 빈칸 너머로 이어지는 링크도 그대로 찾는다(주소 칸은 같고, 남는 글자만 예전과 다르다).
  const joined = `](/uploads/a[b c](${stored(THEIRS)})`;
  assert.deepEqual(noteFileTargets(joined), [stored(THEIRS)]);
  assert.equal(rewriteNoteFileLinks(joined, accepted), '](/uploads/a[b c]');
  assert.equal(rewriteNoteFileLinks(`[a[b](${stored(MINE)})`, accepted), `[a[b](${stored(MINE)})`);
  assert.equal(rewriteNoteFileLinks(`![a[b](${stored(THEIRS)})`, accepted), '![ab');
});

test('본문 길이에 비례하는 시간 — 5만 자 공격 본문도 고치기 한 번(링크 찾기·지금 본문 읽기·다시 쓰기)과 서명이 금방 끝난다', async () => {
  // 예전 모양은 이런 본문 하나에 몇 초씩 걸렸다('['·'!'만 5만 자: 약 2초, 닫히지 않은 `](/uploads/a`를 이은 것: 0.2초 남짓을 여러 번).
  const N = 50000;
  // 맨 앞에 받는 링크를 하나 둔다 — 파일 링크가 하나도 없으면 다시 쓰기(rewriteNoteFileLinks — 마지막에 다시 훑기까지)를 건너뛰므로.
  const LINK = `[](${stored(MINE)})\n`;
  const fill = (unit) => (LINK + unit.repeat(Math.ceil(N / unit.length))).slice(0, N);
  const bodies = {
    '[': fill('['),
    '!': fill('!'),
    '![': fill('!['),
    '!…![': `${LINK}${'!'.repeat(N - LINK.length - 1)}[`,
    '[aaaaaaaaaa': fill('[aaaaaaaaaa'),
    '](/uploads/a': fill('](/uploads/a'),
    '](/files/a': fill('](/files/a'),
    '[x](/uploads/a': fill('[x](/uploads/a'),
    '![x](/uploads/a': fill('![x](/uploads/a'),
    '[](/uploads/': fill('[](/uploads/'),
    '[a](/files/a](/uploads/a': fill('[a](/files/a](/uploads/a'),
    '서로 다른 링크': fill(Array.from({ length: 4000 }, (_, i) => `[](/uploads/${i}.png)`).join('')),
    // 서명 링크를 푸는 일(복호화)은 링크마다 드는 값이라 시간 대신 아래 테스트가 횟수로 본다.
  };
  const lookups = fakeLookups();
  for (const [name, body] of Object.entries(bodies)) {
    assert.equal(body.length, N);
    // 셋 가운데 가장 빠른 것 — 같은 컴퓨터에서 다른 테스트가 함께 돌아 생기는 들쭉날쭉함을 덜어 낸다.
    let best = Infinity;
    for (let run = 0; run < 3; run++) {
      const started = performance.now();
      const saved = await filterNoteFileLinks(body, { writerId: WRITER, existingBodies: [body] }, lookups);
      await filterNoteFileLinks(body, { writerId: WRITER }, lookups);
      signNoteFileLinks(saved, (p) => p);
      signNoteFileLinks(body, (p) => p);
      best = Math.min(best, performance.now() - started);
    }
    assert.ok(best < 100, `${name}: ${best.toFixed(1)}ms`);
  }
});

test('서명 링크는 주소마다 한 번만 푼다 — 가짜 서명 링크를 늘어놓아도 푸는 일(복호화)은 서로 다른 주소 수만큼만', async (t) => {
  const tokens = Array.from({ length: 50 }, (_, i) => `/files/${'A'.repeat(40)}${i}`);
  // 같은 주소가 두 번 나와도 한 번만.
  const body = [...tokens, tokens[0]].map((u) => `![](${u})`).join('\n');
  const decrypts = t.mock.method(nodeCrypto, 'createDecipheriv');
  const out = await filterNoteFileLinks(body, { writerId: WRITER }, fakeLookups());
  assert.equal(decrypts.mock.callCount(), tokens.length);
  assert.equal(out, Array(tokens.length + 1).fill('그림').join('\n'));
  // 이력을 되돌릴 때처럼 원래 있던 본문이 같은 본문이어도 마찬가지.
  decrypts.mock.resetCalls();
  await filterNoteFileLinks(body, { writerId: WRITER, existingBodies: [body] }, fakeLookups());
  assert.equal(decrypts.mock.callCount(), tokens.length);
});

// ── 조회를 엮는 쪽(fileRefs.js filterNoteFileLinks) ─────────────────────

test('새 노트: 내가 올린 그림은 그대로 — 남의 파일 이름을 적은 링크는 글자로(방·노트를 찾아보지도 않는다)', async () => {
  const lookups = fakeLookups({ noteReachable: [stored(THEIRS)], roomReachable: [stored(THEIRS)] });
  const body = `![내 그림](${stored(MINE)})\n![알아낸 이름](${stored(THEIRS)})`;
  assert.equal(await filterNoteFileLinks(body, { writerId: WRITER }, lookups), `![내 그림](${stored(MINE)})\n알아낸 이름`);
  assert.deepEqual(lookups.calls.uploaders, [[MINE, THEIRS]]);
  assert.deepEqual(lookups.calls.notes, []);
  assert.deepEqual(lookups.calls.rooms, []);
});

test('노트 복제·노트 사이 복사: 구성원인 프로젝트의 노트·이력에 있는 남의 그림(서명 링크)은 받는다 — 노트를 먼저 보고, 없으면 방', async () => {
  const theirs = signFileUrl(stored(THEIRS));
  const doc = signedHoursAgo(stored(DOC), 4);
  const lookups = fakeLookups({ noteReachable: [stored(THEIRS)], roomReachable: [stored(DOC)] });
  const body = `![도면](${theirs})\n[첨부](${doc})`;
  assert.equal(
    await filterNoteFileLinks(body, { writerId: WRITER }, lookups),
    `![도면](${stored(THEIRS)})\n[첨부](${stored(DOC)})`,
  );
  assert.deepEqual(lookups.calls.notes, [{ userId: WRITER, paths: [stored(THEIRS), stored(DOC)] }]);
  // 노트에서 찾은 것은 방에서 다시 찾지 않는다.
  assert.deepEqual(lookups.calls.rooms, [{ userId: WRITER, paths: [stored(DOC)] }]);
});

test('볼 수 없는 남의 파일 서명 링크는 글자로 — 저장은 거절하지 않는다', async () => {
  const lookups = fakeLookups();
  const body = `앞 글\n![남의 그림](${signFileUrl(stored(THEIRS))})\n뒤 글`;
  assert.equal(await filterNoteFileLinks(body, { writerId: WRITER }, lookups), '앞 글\n남의 그림\n뒤 글');
});

test('고치기: 지금 본문에 있던 파일은 누가 올렸든, 편집 창이 들고 있던 만료된 링크로 돌아와도 조회 없이 그대로', async () => {
  const lookups = fakeLookups();
  const current = `![도면](${stored(THEIRS)})\n[옛 파일](${stored(OLD)})`;
  const edited = `![도면](${signedHoursAgo(stored(THEIRS), 6)})\n[옛 파일](${signedHoursAgo(stored(OLD), 6)})\n덧붙인 글`;
  assert.equal(
    await filterNoteFileLinks(edited, { writerId: WRITER, existingBodies: [current] }, lookups),
    `![도면](${stored(THEIRS)})\n[옛 파일](${stored(OLD)})\n덧붙인 글`,
  );
  assert.deepEqual(lookups.calls, { uploaders: [], notes: [], rooms: [] });
});

test('이력 되돌리기: 그 이력에 있던 파일은 그대로(조회 없이), 알아볼 수 없는 링크만 글자로', async () => {
  const lookups = fakeLookups();
  const version = `![a](${stored(THEIRS)})\n[b](${stored(DOC)})\n[c](/files/garbage)`;
  assert.equal(
    await filterNoteFileLinks(version, { writerId: WRITER, existingBodies: [version] }, lookups),
    `![a](${stored(THEIRS)})\n[b](${stored(DOC)})\nc`,
  );
  assert.deepEqual(lookups.calls, { uploaders: [], notes: [], rooms: [] });
});

test('파일 링크가 없거나 알아볼 수 없는 링크뿐이면 DB를 보지 않는다', async () => {
  const lookups = fakeLookups();
  assert.equal(await filterNoteFileLinks('그냥 글 [웹](https://example.test)', { writerId: WRITER }, lookups), '그냥 글 [웹](https://example.test)');
  const legacy = `/files/${jwt.sign({ file: THEIRS, type: 'file' }, 'any-secret')}`;
  assert.equal(await filterNoteFileLinks(`![옛 링크](${legacy})`, { writerId: WRITER }, lookups), '옛 링크');
  assert.deepEqual(lookups.calls, { uploaders: [], notes: [], rooms: [] });
});

// ── findNoteReachableUploadPaths — 실제 쿼리 빌더 + 가짜 pg 클라이언트 ──────

test('findNoteReachableUploadPaths: 내가 유효한 구성원인 프로젝트의 노트 본문과 그 이력에서, 서명하는 모양의 링크로 찾는다', async (t) => {
  const seen = [];
  const fake = drizzle({
    client: {
      async query(config, values = []) {
        seen.push({ text: (typeof config === 'string' ? config : config.text).replace(/\s+/g, ' ').trim(), values });
        return { rows: [{ p: stored(THEIRS) }] };
      },
    },
  });
  t.mock.method(db, 'execute', (...args) => fake.execute(...args));

  const found = await findNoteReachableUploadPaths(WRITER, [stored(THEIRS), stored(DOC), stored(THEIRS)]);
  assert.deepEqual([...found], [stored(THEIRS)]);
  assert.equal(seen.length, 1);
  const [{ text, values }] = seen;
  // 노트 본문과 수정 이력 둘 다.
  assert.match(text, /from "project_notes", regexp_matches\("project_notes"\."body", \$1, 'g'\) as m\(link\)/);
  assert.match(text, /from "note_versions" join "project_notes" on "project_notes"\."id" = "note_versions"\."note_id", regexp_matches\("note_versions"\."body", \$5, 'g'\)/);
  // 구성원은 유효한 행만(팀에 있고 정회원 이상·정지/탈퇴 아님 — ACTIVE_PROJECT_MEMBER), 그 노트의 프로젝트로.
  const member =
    /exists \( select 1 from "project_members" where "project_members"\."project_id" = "project_notes"\."project_id" and "project_members"\."user_id" = \$\d+ and exists \( select 1 from "projects" amp join "team_members" amt on amt\.team_id = amp\.team_id and amt\.user_id = "project_members"\."user_id" join "users" amu on amu\.id = amt\.user_id where amp\.id = "project_members"\."project_id" and amu\.deleted_at is null and amu\.suspended_at is null and \(amu\.role in \('member', 'admin'\) or amu\.is_server_admin\)\)\)/g;
  assert.equal(text.match(member)?.length, 2);
  // 서명(signNoteBody)과 같은 모양으로 찾고, 후보는 배열 하나로(중복 없이) 넘긴다.
  assert.deepEqual(values, [
    String.raw`\]\((/uploads/[^)\s]+)\)`,
    '](/uploads/',
    [stored(THEIRS), stored(DOC)],
    WRITER,
    String.raw`\]\((/uploads/[^)\s]+)\)`,
    '](/uploads/',
    [stored(THEIRS), stored(DOC)],
    WRITER,
  ]);
});

test('findNoteReachableUploadPaths: 후보가 없거나 사람을 모르면 묻지 않는다', async () => {
  assert.deepEqual([...(await findNoteReachableUploadPaths(WRITER, []))], []);
  assert.deepEqual([...(await findNoteReachableUploadPaths(null, [stored(THEIRS)]))], []);
});

// ── 라우트 연결(projects.js) ──────────────────────────────────────────

test('노트를 쓰는 세 곳(만들기·고치기·이력 되돌리기)이 모두 파일 링크를 거르고, 원래 있던 본문을 알맞게 넘긴다', () => {
  const source = fs.readFileSync(new URL('../src/projects.js', import.meta.url), 'utf8');
  const fn = source.slice(source.indexOf('async function rawNoteBody('), source.indexOf('\n}\n', source.indexOf('async function rawNoteBody(')));
  // '\r'을 먼저 지우고 → 파일 링크 → 바깥 그림 순서.
  assert.match(fn, /await filterNoteFileLinks\(body\.replace\(\/\\r\/g, ''\), \{ writerId, existingBodies \}\)/);
  assert.match(fn, /return noteBodyWithoutExternalImages\(filtered\);/);
  // 부르는 곳 전부(선언은 빼고) — 모두 await로 기다리고, 쓴 사람과 원래 있던 본문을 넘긴다.
  const calls = [...source.matchAll(/(?<!function )(await )?rawNoteBody\(([^\n]*)\)/g)];
  assert.deepEqual(
    calls.map((m) => [!!m[1], m[2]]),
    [
      [true, 'rawBody, { writerId: req.user.sub }'],
      [true, 'req.body.body, { writerId: req.user.sub, existingBodies: [note.body] }'],
      [true, 'v.body, { writerId: req.user.sub, existingBodies: [v.body] }'],
    ],
  );
  // 새 노트는 저장할 모양으로 길이를 재지만, 그 전에 터무니없이 긴 본문은 읽지 않고 거절한다(고치기는 보낸 그대로 5만 자로 잰다).
  const create = source.slice(source.indexOf("router.post('/projects/:id/notes'"), source.indexOf("router.patch('/notes/:id'"));
  const capAt = create.indexOf('if (rawBody.length > NOTE_BODY_RAW_MAX) return res.status(400)');
  assert.ok(capAt > 0 && capAt < create.indexOf('await rawNoteBody(rawBody'), '새 노트 본문 상한을 rawNoteBody보다 먼저 본다');
  assert.match(create, /if \(body\.length > NOTE_BODY_MAX\) return res\.status\(400\)/);
  const patch = source.slice(source.indexOf("router.patch('/notes/:id'"), source.indexOf('// ── 노트 댓글 ──'));
  assert.ok(
    patch.indexOf('if (req.body.body.length > NOTE_BODY_MAX)') < patch.indexOf('await rawNoteBody(req.body.body'),
    '고치기는 rawNoteBody 전에 5만 자로 잰다',
  );
  // 내려줄 때도 저장할 때의 검사와 한곳에 둔 모양으로 서명한다(fileRefRules.js signNoteFileLinks).
  assert.match(source, /return signNoteFileLinks\(noteBodyWithoutExternalImages\(body\), \(url\) => signFileUrl\(url\)\);/);
  assert.doesNotMatch(source, /\.replace\(\/\\\]\\\(\(\\\/uploads/);
  // 예전처럼 서명 링크만 되돌리고 그대로 저장하는 길이 남아 있지 않다.
  assert.doesNotMatch(source, /resolveRawUrl/);
});

test('새 노트 본문 상한(NOTE_BODY_RAW_MAX)은 5만 자 노트를 서명 링크째 복제해도 넉넉하다 — 서명 링크가 가장 많이 늘어나는 본문으로', () => {
  const source = fs.readFileSync(new URL('../src/projects.js', import.meta.url), 'utf8');
  const max = Number(/const NOTE_BODY_MAX = (\d+);/.exec(source)?.[1]);
  const factor = Number(/const NOTE_BODY_RAW_MAX = NOTE_BODY_MAX \* (\d+);/.exec(source)?.[1]);
  assert.ok(max > 0 && factor > 0, 'projects.js의 노트 본문 상한을 읽지 못했다');
  // 링크만으로 꽉 채운 노트 — 앱의 노트 복제는 내려받은(서명된) 본문을 그대로 보낸다. 앱이 넣는 그림 줄과 가장 짧은 맨 링크 둘 다.
  for (const unit of [`![](${stored(MINE)})\n`, `](${stored(MINE)})`]) {
    const storedBody = unit.repeat(Math.floor(max / unit.length));
    const sent = signNoteFileLinks(storedBody, (p) => signFileUrl(p));
    assert.ok(sent.length > max, `${unit}: 서명 링크째 보내면 5만 자를 넘는 경우여야 한다(${sent.length})`);
    assert.ok(sent.length <= max * factor, `${unit}: ${sent.length} > ${max * factor}`);
  }
});
