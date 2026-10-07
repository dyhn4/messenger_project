// 노트 본문 그림 주소 규칙 테스트 — `node --test test/noteImages.test.js` (DB·서버 없이 돈다).
// 그림 줄(`![이름](주소)`)은 노트를 연 사람의 앱이 직접 받으러 간다. 이 서버 파일(/uploads/<이름>, /files/<토큰>)이 아닌 그림은
// 저장할 때와 내려줄 때 링크로 바뀌어야 한다(S25 — projectNotifications.js noteBodyWithoutExternalImages, projects.js rawNoteBody·
// signNoteBody). 여기서는 앱(client/lib/screens/project/note_markdown.dart)이 그림 줄을 읽는 방식을 그대로 옮긴 함수로, 바꾼 본문에
// 바깥 그림 줄이 하나도 남지 않는지 본다 — 바꾸기가 새 그림을 만들어 내는 경우(앞의 '!', 여러 줄에 걸친 이름, '\r')까지.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';
import { isNoteImageTarget, noteBodyWithoutExternalImages } from '../src/projectNotifications.js';

/**
 * 앱이 그림 줄로 읽는 주소들 — note_markdown.dart noteMarkdownToRich와 같은 순서: '\r'을 모두 지우고 줄로 나눈 뒤, 줄 앞의 제목·인용
 * 표시를 한 번 떼고, 앞뒤 공백을 지운(Dart trim — 유니코드 공백 + BOM, JS trim에 없는 U+0085까지) 줄 전체가 그림 모양이면 그 주소.
 */
function appImageUrls(md) {
  const urls = [];
  for (let line of md.replace(/\r/g, '').split('\n')) {
    if (line.startsWith('### ')) line = line.slice(4);
    else if (line.startsWith('## ')) line = line.slice(3);
    else if (line.startsWith('# ')) line = line.slice(2);
    else if (line.startsWith('> ') || line === '>') line = line.length > 2 ? line.slice(2) : '';
    const trimmed = line.replace(/^[\s\u0085]+|[\s\u0085]+$/g, '');
    const m = /^!\[([^\]]*)\]\(([^)\s]+)\)\s*$/.exec(trimmed);
    if (m) urls.push(m[2]);
  }
  return urls;
}

/** 바꾼 본문을 앱이 읽었을 때 받으러 갈 바깥 주소들(없어야 한다). */
const externalImagesAfter = (md) => appImageUrls(noteBodyWithoutExternalImages(md)).filter((u) => !isNoteImageTarget(u));

test('isNoteImageTarget: 이 서버 파일 경로 한 마디만', () => {
  for (const ok of [
    '/uploads/3f1c0d2e-1111-4222-8333-944445555666.png',
    '/files/AbC-_09xyz',
    '/files/eyJhbGciOiJIUzI1NiJ9.eyJmaWxlIjoiYS5wbmcifQ.sig', // 예전 JWT 토큰(점이 있다)
  ]) {
    assert.equal(isNoteImageTarget(ok), true, ok);
  }
  for (const bad of [
    'http://attacker.test/t.png?n=42',
    'https://attacker.test/t.png',
    'http://192.168.0.1/admin.png',
    '//attacker.test/t.png', // 웹 앱에서는 다른 서버
    '.attacker.test/t.png', // 앱이 서버 주소를 앞에 붙이면 다른 서버 이름이 된다
    '@attacker.test/t.png', // 붙이면 앞부분이 사용자 정보가 되고 뒤가 서버가 된다
    'uploads/a.png',
    '/uploads/',
    '/files/',
    '/uploads/a/b.png',
    '/files/../x',
    '/uploads\\a.png',
    '/filesx/a',
    'javascript:alert(1)',
    'data:image/png;base64,AAAA',
    'file:///C:/secret.png',
    '',
    null,
    undefined,
  ]) {
    assert.equal(isNoteImageTarget(bad), false, String(bad));
  }
});

test('바깥 그림은 링크로, 이 서버 그림은 그대로 둔다', () => {
  const local = '![도면.png](/uploads/3f1c.png)';
  const signed = '![캡처](/files/AbC-_09)';
  assert.equal(noteBodyWithoutExternalImages(local), local);
  assert.equal(noteBodyWithoutExternalImages(signed), signed);
  assert.equal(noteBodyWithoutExternalImages('![x](http://attacker.test/t.png?n=42)'), '[x](http://attacker.test/t.png?n=42)');
  assert.equal(noteBodyWithoutExternalImages('![공유기](http://192.168.0.1/a.png)'), '[공유기](http://192.168.0.1/a.png)');
  // 이름이 비면 앱이 링크로 읽지 못하므로 그림 줄의 기본 이름을 쓴다.
  assert.equal(noteBodyWithoutExternalImages('![](https://a.test/x.png)'), '[그림](https://a.test/x.png)');
  assert.equal(noteBodyWithoutExternalImages('![  ](https://a.test/x.png)'), '[그림](https://a.test/x.png)');
  // 제목·인용 줄의 그림, 글 사이의 그림, 여러 개가 섞인 본문.
  const body = [
    '# 회의록',
    '## ![배너](https://cdn.test/b.png)',
    '> ![인용](.attacker.test/q.png)',
    local,
    '앞 ![가운데](//attacker.test/m.png) 뒤',
    '[보통 링크](https://example.test/doc)',
    signed,
  ].join('\n');
  assert.equal(
    noteBodyWithoutExternalImages(body),
    [
      '# 회의록',
      '## [배너](https://cdn.test/b.png)',
      '> [인용](.attacker.test/q.png)',
      local,
      '앞 [가운데](//attacker.test/m.png) 뒤',
      '[보통 링크](https://example.test/doc)',
      signed,
    ].join('\n'),
  );
  // 그림이 없는 본문·글자가 아닌 값은 그대로.
  assert.equal(noteBodyWithoutExternalImages('그냥 글'), '그냥 글');
  assert.equal(noteBodyWithoutExternalImages(''), '');
  assert.equal(noteBodyWithoutExternalImages(null), null);
  assert.equal(noteBodyWithoutExternalImages(undefined), undefined);
});

test('저장 경로 링크(`](/uploads/…)`)는 그대로 남는다 — 파일 정리(uploads.js findReferencedUploadPaths)가 이 모양으로 찾는다', () => {
  const body = '![a](/uploads/a.png)\n[보고서.pdf](/uploads/b.pdf)\n![밖](http://x.test/c.png)';
  const out = noteBodyWithoutExternalImages(body);
  assert.ok(out.includes('](/uploads/a.png)'));
  assert.ok(out.includes('](/uploads/b.pdf)'));
});

test('바꾼 결과가 새 그림을 만들지 않는다 — 앞의 "!", 여러 줄에 걸친 이름, "\\r", 이름 속 그림', () => {
  // 앞에 '!'가 더 있으면 하나만 떼면 남은 '!'가 '['에 붙어 그림이 된다 — 띄어 쓴다.
  assert.equal(noteBodyWithoutExternalImages('!![x](http://e.test/a.png)'), '! [x](http://e.test/a.png)');
  assert.equal(noteBodyWithoutExternalImages('놀라워!!![x](http://e.test/a.png)'), '놀라워!! [x](http://e.test/a.png)');
  assert.deepEqual(externalImagesAfter('!![x](http://e.test/a.png)'), []);
  // 앞 줄에서 시작한 "![" 때문에 다음 줄의 그림이 이름 속으로 들어가 되살아나지 않게 — 이름은 한 줄 안에서만 본다.
  assert.equal(noteBodyWithoutExternalImages('![foo\n![bar](http://e.test/a.png)'), '![foo\n[bar](http://e.test/a.png)');
  assert.deepEqual(externalImagesAfter('![foo\n![bar](http://e.test/a.png)'), []);
  // 앱은 '\r'을 지우고 읽는다 — 주소 끝의 '\r'로 검사만 비켜 가지 못한다.
  assert.deepEqual(appImageUrls('![x](http://e.test/a.png\r)'), ['http://e.test/a.png']);
  assert.equal(noteBodyWithoutExternalImages('![x](http://e.test/a.png\r)'), '[x](http://e.test/a.png)');
  assert.equal(noteBodyWithoutExternalImages('![x\r](http://e.test/a.png)\r\n다음'), '[x](http://e.test/a.png)\n다음');
  // 이름 안에 "![…"가 든 그림(앱은 이 줄 전체를 그림으로 읽는다).
  assert.deepEqual(appImageUrls('![a![b](http://e.test/a.png)'), ['http://e.test/a.png']);
  assert.deepEqual(externalImagesAfter('![a![b](http://e.test/a.png)'), []);
  // U+0085는 Dart trim만 지운다 — 줄 앞뒤에 붙여도 그대로 잡힌다.
  assert.deepEqual(appImageUrls('\u0085![x](http://e.test/a.png)\u0085'), ['http://e.test/a.png']);
  assert.deepEqual(externalImagesAfter('\u0085![x](http://e.test/a.png)\u0085'), []);
});

/** 고정 씨앗 난수(mulberry32) — 실패하면 같은 입력으로 다시 볼 수 있게. */
function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

test('그림·문법 조각을 아무렇게나 이어 붙인 본문 2만 개 — 바꾼 뒤에는 앱이 받으러 갈 바깥 그림이 없다', () => {
  // 그림 한 덩어리와 그 사이에 끼는 조각(앞의 '!', 짝 없는 괄호, 줄바꿈·'\r'·U+0085, 제목·인용 표시)을 섞는다. 이 만들기로는 '!' 처리가
  // 없거나, '\r'을 안 지우거나, 이름이 줄을 넘어가게 둔 바꾸기가 모두 걸린다(그런 바꾸기를 넣어 직접 확인했다).
  const names = ['', 'a', '이름', ' ', 'a![b', 'x[y', '![', 'q\r', 'foo\n'];
  const urls = [
    'http://e.test/a.png', 'https://e.test/x?y=1', '//e.test/z', '.e.test/p', '@e.test/q', 'e.test/a.png\r',
    '/uploads/a.png', '/uploads/b.png\r', '/files/Tok-en_1', '/files/x/y',
  ];
  const glue = ['!', '!!', '[', ']', '(', ')', '![', '](', 'a', '이름', ' ', '\n', '\r', '\r\n', '\u0085', '# ', '## ', '> ', '>'];
  const next = rng(20261007);
  const pick = (list) => list[Math.floor(next() * list.length)];
  for (let i = 0; i < 20000; i++) {
    let md = '';
    const n = 1 + Math.floor(next() * 8);
    for (let j = 0; j < n; j++) md += next() < 0.5 ? `![${pick(names)}](${pick(urls)})` : pick(glue);
    const out = noteBodyWithoutExternalImages(md);
    const leaked = appImageUrls(out).filter((u) => !isNoteImageTarget(u));
    assert.deepEqual(leaked, [], `입력 ${JSON.stringify(md)} → ${JSON.stringify(out)}`);
    // 내려줄 때 한 번 더 바꿔도(signNoteBody) 마찬가지다.
    assert.deepEqual(externalImagesAfter(out), [], `두 번째: ${JSON.stringify(out)}`);
  }
});

test('앱의 그림 줄 규칙(note_markdown.dart)이 이 테스트가 옮긴 모양 그대로인지', { skip: !fs.existsSync(new URL('../../client/lib/screens/project/note_markdown.dart', import.meta.url)) }, () => {
  // 앱 쪽 규칙이 바뀌면 위 appImageUrls도 함께 고쳐야 이 테스트가 의미가 있다(서버만 따로 둔 곳에서는 건너뛴다).
  const dart = fs.readFileSync(new URL('../../client/lib/screens/project/note_markdown.dart', import.meta.url), 'utf8');
  assert.ok(dart.includes(String.raw`final _imageLine = RegExp(r'^!\[([^\]]*)\]\(([^)\s]+)\)\s*$');`), '앱의 그림 줄 정규식');
  assert.ok(dart.includes(String.raw`final lines = md.replaceAll('\r', '').split('\n');`), "앱은 '\\r'을 지우고 줄로 나눈다");
  assert.ok(dart.includes('final image = _imageLine.firstMatch(line.trim());'), '앱은 앞뒤 공백을 지운 줄 전체를 본다');
  // 앱이 그림으로 받는 주소도 서버와 같은 규칙이다.
  assert.ok(dart.includes(String.raw`final _localImageTarget = RegExp(r'^/(?:files|uploads)/[^/\\]+$');`), '앱의 이 서버 파일 규칙');
});
