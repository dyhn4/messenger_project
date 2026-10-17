// 위키 동시 편집 OT — 적용·합치기·맞추기(transform) 성질을 무작위로 많이 돌려 본다. 앱(client/lib/services/ot_text.dart)은 같은
// 규칙이라 test/ot_text_test.dart가 같은 경우를 본다. `node --test test/otText.test.js`(DB 없이).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  apply,
  baseLength,
  compose,
  diffOp,
  isNoop,
  isValidOp,
  normalize,
  targetLength,
  transform,
  transformIndex,
} from '../src/otText.js';

/** 시드가 같으면 같은 수열 — 실패를 다시 볼 수 있게. */
function rng(seed) {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 2 ** 32;
  };
}

const ALPHABET = 'ab가나 \n😀';
function randomString(r, max = 6) {
  const n = 1 + Math.floor(r() * max);
  let s = '';
  for (let i = 0; i < n; i += 1) s += ALPHABET[Math.floor(r() * ALPHABET.length)];
  return s;
}

/** [doc]에 적용할 수 있는 무작위 연산(UTF-16 단위로 자른다 — 앱과 같다). */
function randomOp(r, doc) {
  const op = [];
  let left = doc.length;
  while (left > 0) {
    const n = 1 + Math.floor(r() * Math.min(left, 5));
    const pick = r();
    if (pick < 0.2) op.push(randomString(r));
    else if (pick < 0.5) op.push(-n);
    else op.push(n);
    if (pick >= 0.2) left -= n;
  }
  if (r() < 0.3) op.push(randomString(r));
  return normalize(op);
}

test('적용·길이·짧은 꼴', () => {
  assert.equal(apply('hello', [5, ' world']), 'hello world');
  assert.equal(apply('hello', [1, -3, 'ipp', 1]), 'hippo');
  assert.throws(() => apply('hi', [5]));
  assert.deepEqual(normalize([1, 2, 'a', 'b', -1, -2]), [3, 'ab', -3]);
  assert.deepEqual(normalize([2, -1, 'x', 1]), [2, 'x', -1, 1], '지우기 뒤 넣기는 앞으로');
  assert.equal(baseLength([2, 'xy', -3]), 5);
  assert.equal(targetLength([2, 'xy', -3]), 4);
  assert.equal(isNoop([4]), true);
  assert.equal(isValidOp([1, 'a', -2]), true);
  assert.equal(isValidOp([0]), false);
  assert.equal(isValidOp([1.5]), false);
  assert.equal(isValidOp(['']), false);
  assert.equal(isValidOp('x'), false);
});

test('같은 자리 동시 넣기 — transform의 첫 연산이 앞', () => {
  const doc = 'ac';
  const a = [1, 'X', 1];
  const b = [1, 'Y', 1];
  const [ap, bp] = transform(a, b);
  assert.equal(apply(apply(doc, a), bp), 'aXYc');
  assert.equal(apply(apply(doc, b), ap), 'aXYc');
  // 둘 다 같은 글자를 지우면 한 번만 지워진다.
  const [dp, ep] = transform([-1, 1], [-2]);
  assert.equal(apply(apply('ab', [-1, 1]), ep), '');
  assert.equal(apply(apply('ab', [-2]), dp), '');
});

test('무작위 — transform 수렴과 compose 결과가 같다(2000번)', () => {
  const r = rng(20261018);
  for (let k = 0; k < 2000; k += 1) {
    const doc = r() < 0.1 ? '' : randomString(r, 20);
    const a = randomOp(r, doc);
    const b = randomOp(r, doc);
    const [ap, bp] = transform(a, b);
    assert.equal(apply(apply(doc, a), bp), apply(apply(doc, b), ap), `transform #${k}`);
    const after = apply(doc, a);
    const c = randomOp(r, after);
    assert.equal(apply(doc, compose(a, c)), apply(after, c), `compose #${k}`);
  }
});

test('서버·앱 흐름 — 늦게 온 연산을 적용한 연산들에 맞춰도 모두 같은 글이 된다', () => {
  const r = rng(7);
  for (let k = 0; k < 300; k += 1) {
    let server = randomString(r, 15);
    // 앱 A·B가 같은 판에서 시작해 각자 고친다. A가 먼저 서버에 닿는다.
    const base = server;
    const a = randomOp(r, base);
    const b = randomOp(r, base);
    server = apply(server, a);
    // 서버: B를 이미 적용한 A에 맞춘다 — transform(늦게 온 것, 적용한 것).
    const bOnServer = transform(b, a)[0];
    server = apply(server, bOnServer);
    // 앱 B: 확인 안 된 내 연산 b가 있는 채로 a를 받는다 — transform(내 것, 서버 것).
    const [, aOnB] = transform(b, a);
    const clientB = apply(apply(base, b), aOnB);
    // 앱 A: 내 a는 확인받았고, b'(bOnServer)를 그대로 받는다.
    const clientA = apply(apply(base, a), bOnServer);
    assert.equal(clientA, server, `A #${k}`);
    assert.equal(clientB, server, `B #${k}`);
  }
});

test('글 바꾸기 연산·커서 옮기기', () => {
  assert.deepEqual(diffOp('hello world', 'hello brave world'), [6, 'brave ', 5]);
  assert.deepEqual(diffOp('abc', 'abc'), [3]);
  assert.deepEqual(diffOp('', 'new'), ['new']);
  assert.deepEqual(diffOp('abcdef', 'abXef'), [2, 'X', -2, 2]);
  const r = rng(99);
  for (let k = 0; k < 500; k += 1) {
    const from = randomString(r, 12);
    const to = randomString(r, 12);
    assert.equal(apply(from, diffOp(from, to)), to);
  }
  assert.equal(transformIndex(3, ['ab', 5]), 5);
  assert.equal(transformIndex(3, [3, 'ab', 2]), 3, '커서 자리에 넣으면 커서는 앞에 남는다');
  assert.equal(transformIndex(3, [1, -1, 3]), 2);
  assert.equal(transformIndex(3, [2, -3]), 2, '지운 범위 안의 커서는 지운 자리로');
  assert.equal(transformIndex(0, [-2, 'xy']), 0);
});
