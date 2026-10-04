// 공지 본문·서식 규칙 단위 테스트 — `node --test test/*.test.js` (DB·서버 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { announcementFieldsFromMessage } from '../src/announcementFromMessage.js';
import { parseAnnouncementText, shiftTextFormat } from '../src/announcementText.js';
import { sanitizeTextFormat } from '../src/textFormat.js';

// 클라이언트 Fmt.withColor와 같은 계산 — "색 있음"(512) + RGB를 1024배 자리부터.
const color = (rgb) => 512 + rgb * 1024;

test('parseAnnouncementText: 앞뒤 공백을 떼고 뗀 앞 공백만큼 서식 위치를 당긴다', () => {
  const r = parseAnnouncementText('  굵게 보통  ', [{ s: 2, e: 4, f: 1 }]);
  assert.equal(r.text, '굵게 보통');
  assert.deepEqual(r.textFormat, [{ s: 0, e: 2, f: 1 }]);
});

test('parseAnnouncementText: 서식이 없거나 모양이 틀리면 null, 글이 문자열이 아니면 빈 글', () => {
  assert.deepEqual(parseAnnouncementText('공지', undefined), { text: '공지', textFormat: null });
  assert.deepEqual(parseAnnouncementText('공지', 'bold'), { text: '공지', textFormat: null });
  assert.deepEqual(parseAnnouncementText('공지', [{ s: 0, e: 9, f: 1 }]).textFormat, [{ s: 0, e: 2, f: 1 }]);
  assert.deepEqual(parseAnnouncementText(42, [{ s: 0, e: 1, f: 1 }]), { text: '', textFormat: null });
});

test('parseAnnouncementText: 노트 편집기처럼 제목(H1~H3)과 글자색까지 받는다', () => {
  const red = color(0xe53935);
  const r = parseAnnouncementText('제목\n빨강', [
    { s: 0, e: 2, f: 64 },
    { s: 3, e: 5, f: red },
    { s: 3, e: 5, f: red + 1 },
  ]);
  // 32비트를 넘는 값이라 비트 연산(&)으로 자르면 색이 날아간다 — 그대로 남아야 한다.
  assert.ok(red > 2 ** 32);
  assert.deepEqual(r.textFormat, [
    { s: 0, e: 2, f: 64 },
    { s: 3, e: 5, f: red },
    { s: 3, e: 5, f: red + 1 },
  ]);
});

test('sanitizeTextFormat rich: "색 있음" 비트가 없으면 색 자리를 버리고, 음수·실수는 서식 없음', () => {
  // 색 비트 없이 RGB 자리만 있는 값 → 아래 9비트(굵게 등·제목)만.
  assert.deepEqual(sanitizeTextFormat([{ s: 0, e: 1, f: 1024 * 5 + 2 }], '가', { rich: true }), [{ s: 0, e: 1, f: 2 }]);
  assert.equal(sanitizeTextFormat([{ s: 0, e: 1, f: -1 }], '가', { rich: true }), null);
  assert.equal(sanitizeTextFormat([{ s: 0, e: 1, f: 1.5 }], '가', { rich: true }), null);
  // 링크는 서식 비트가 없어도 남는다.
  assert.deepEqual(sanitizeTextFormat([{ s: 0, e: 1, f: 0, h: 'https://a.b' }], '가', { rich: true }), [
    { s: 0, e: 1, f: 0, h: 'https://a.b' },
  ]);
});

test('sanitizeTextFormat 기본(채팅·댓글): 제목·글자색은 예전처럼 받지 않는다', () => {
  assert.deepEqual(sanitizeTextFormat([{ s: 0, e: 1, f: 64 | 1 }], '가'), [{ s: 0, e: 1, f: 1 }]);
  assert.equal(sanitizeTextFormat([{ s: 0, e: 1, f: color(0xff0000) }], '가'), null);
});

test('shiftTextFormat: 본문 밖으로 나간 구간은 잘라내고, 남는 게 없으면 null', () => {
  assert.deepEqual(shiftTextFormat([{ s: 0, e: 6, f: 1 }], 2, '가나다'), [{ s: 0, e: 3, f: 1 }]);
  assert.equal(shiftTextFormat([{ s: 0, e: 2, f: 1 }], 2, '가나다'), null);
  assert.equal(shiftTextFormat([{ s: 0, e: 1, f: 1 }], 0, ''), null);
});

test('announcementFieldsFromMessage: 메시지의 글 서식을 공백을 뗀 위치에 맞춰 가져온다', () => {
  const fields = announcementFieldsFromMessage({
    type: 'text',
    text: '\n 중요 공지',
    textFormat: [{ s: 2, e: 4, f: 1 }],
  });
  assert.equal(fields.ok, true);
  assert.equal(fields.text, '중요 공지');
  assert.deepEqual(fields.textFormat, [{ s: 0, e: 2, f: 1 }]);

  const plain = announcementFieldsFromMessage({ type: 'text', text: '평문' });
  assert.equal(plain.textFormat, null);

  const image = announcementFieldsFromMessage({
    type: 'image',
    text: '설명',
    textFormat: [{ s: 0, e: 2, f: 2 }],
    fileUrl: '/uploads/a.png',
  });
  assert.deepEqual(image.textFormat, [{ s: 0, e: 2, f: 2 }]);
});
