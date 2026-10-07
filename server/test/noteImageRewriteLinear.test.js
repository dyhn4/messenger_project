import assert from 'node:assert/strict';
import { test } from 'node:test';
import { isNoteImageTarget, noteBodyWithoutExternalImages } from '../src/projectNotifications.js';

// 노트 본문의 바깥 그림을 링크로 바꾸는 정규식이 본문 길이에 비례하는 시간에 끝나는지(서버가 한 줄기로 돌아서 오래 걸리면 다른 요청이
// 모두 멈춘다), 그리고 빨리 끝나게 고친 뒤에도 예전 모양과 똑같이 바꾸는지 본다.

// 예전(한 덩어리만 찾던) 모양 — 결과를 맞춰 볼 기준. 짧은 본문에서만 쓴다(긴 본문에서는 느리다).
const OLD_PATTERN = /(!+)\[([^\]\n]*)\]\(([^)\s]+)\)/g;
function oldRewrite(body) {
  if (typeof body !== 'string') return body;
  const text = body.includes('\r') ? body.replace(/\r/g, '') : body;
  if (!text.includes('![')) return text;
  return text.replace(OLD_PATTERN, (match, bangs, name, url) => {
    if (isNoteImageTarget(url)) return match;
    const before = bangs.length > 1 ? `${bangs.slice(1)} ` : '';
    return `${before}[${name.trim() ? name : '그림'}](${url})`;
  });
}

// 결정적인 의사 난수(테스트가 매번 같은 본문을 만든다) — 상위 비트를 쓴다.
function rng(seed) {
  let s = seed >>> 0;
  return () => {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    return s / 2 ** 32;
  };
}

const PIECES = [
  '!', '!', '[', ']', '(', ')', ' ', '\n', 'a', 'b', '그림', '![', '](', ')', '![a](', 'http://e.com/t.png',
  '/uploads/x.png', '/files/tok', '//e.com/x', '\r', ']()', '![](', '!!![x](', 'x![a](http://e)', '](x',
  // 정규식 \s가 공백으로 보는 여러 글자(탭·줄 안 바꿈 공백·전각 공백·줄 구분자)와 서로게이트 쌍(이모지).
  '\t', ' ', '　', ' ', '😀',
];

test('예전 모양과 똑같이 바꾼다(무작위 본문 30,000개)', () => {
  const next = rng(12345);
  for (let i = 0; i < 30000; i++) {
    const count = 1 + Math.floor(next() * 40);
    let body = '';
    for (let j = 0; j < count; j++) body += PIECES[Math.floor(next() * PIECES.length)];
    assert.equal(noteBodyWithoutExternalImages(body), oldRewrite(body), JSON.stringify(body));
  }
});

test('예시 — 바깥 그림은 링크로, 이 서버 파일 그림은 그대로, 닫힌 주소 칸 안의 그림도 놓치지 않는다', () => {
  assert.equal(noteBodyWithoutExternalImages('![도면](http://e.com/a.png)'), '[도면](http://e.com/a.png)');
  assert.equal(noteBodyWithoutExternalImages('![도면](/uploads/a.png)'), '![도면](/uploads/a.png)');
  assert.equal(noteBodyWithoutExternalImages('!!![x](http://e)'), '!! [x](http://e)');
  assert.equal(noteBodyWithoutExternalImages('![](http://e)'), '[그림](http://e)');
  // ')'로 닫힌 주소 칸은 건너뛰지 않는다 — 그 안에서 시작하는 그림도 찾는다.
  assert.equal(noteBodyWithoutExternalImages('[a](x![b](http://e))'), oldRewrite('[a](x![b](http://e))'));
  assert.equal(noteBodyWithoutExternalImages('](x![b](http://e)'), '](x[b](http://e)');
  // 닫히지 않은 주소 칸과 그림이 못 된 이름 칸은 그대로 남는다.
  assert.equal(noteBodyWithoutExternalImages('![a](x y'), '![a](x y');
  assert.equal(noteBodyWithoutExternalImages('![a [b'), '![a [b');
});

// 5만 자(저장 상한)와 20만 자(새 노트의 서명 링크 포함 상한)에서 잰다 — 고치기 전에는 '![' 5만 자가 1초 가까이 걸렸다.
const CRAFTED = {
  '![ 반복': (n) => '!['.repeat(n / 2),
  '! 반복': (n) => '!'.repeat(n),
  '! 반복 + [': (n) => `${'!'.repeat(n - 1)}[`,
  '[ 반복': (n) => '['.repeat(n),
  '](  반복': (n) => ']('.repeat(n / 2),
  '![a](x 반복': (n) => '![a](x'.repeat(n / 6),
  '![a] 반복': (n) => '![a]'.repeat(n / 4),
  '![a](b![a](b … 끝에 공백': (n) => `${'![a](b'.repeat(n / 6)} `,
  '](x![a 반복': (n) => '](x![a'.repeat(n / 6),
  '!![![ 반복': (n) => '!![!['.repeat(n / 5),
  '![aaaa 반복(이름이 길고 닫히지 않음)': (n) => `![${'a'.repeat(n - 2)}`,
};

for (const size of [50_000, 200_000]) {
  for (const [label, make] of Object.entries(CRAFTED)) {
    test(`${size.toLocaleString()}자 ${label} — 빨리 끝난다`, () => {
      const body = make(size);
      let best = Infinity;
      for (let i = 0; i < 3; i++) {
        const started = performance.now();
        noteBodyWithoutExternalImages(body);
        best = Math.min(best, performance.now() - started);
      }
      assert.ok(best < 100, `${best.toFixed(1)}ms`);
    });
  }
}
