// 대화형 봇 메시지의 블록 — Slack Block Kit 모양을 걸러 저장 모양으로, 글로 바꾸기, 그림 받기 자리 바꾸기, 누른 단추 찾기.
// `node --test test/*.test.js`(DB·네트워크 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  BLOCK_IMAGES_MAX,
  blockImageSources,
  blocksHaveActions,
  blocksToText,
  findBlockAction,
  mapBlockImages,
  plainFromSlack,
  resolveBlockImages,
  sanitizeBlocks,
} from '../src/botBlocks.js';

const slackApproval = [
  { type: 'header', text: { type: 'plain_text', text: '휴가 승인 요청' } },
  {
    type: 'section',
    text: { type: 'mrkdwn', text: '*홍길동* 님 · <https://hr.example/r/1|신청서>' },
    fields: [
      { type: 'mrkdwn', text: '*기간*\n3/2~3/4' },
      { type: 'plain_text', text: '연차' },
    ],
  },
  { type: 'divider' },
  {
    type: 'actions',
    block_id: 'approve-1',
    elements: [
      { type: 'button', text: { type: 'plain_text', text: '승인' }, style: 'primary', action_id: 'approve', value: 'r1' },
      { type: 'button', text: { type: 'plain_text', text: '반려' }, style: 'danger', action_id: 'reject', value: 'r1' },
      { type: 'button', text: { type: 'plain_text', text: '열기' }, url: 'https://hr.example/r/1', action_id: 'open' },
      {
        type: 'static_select',
        action_id: 'delegate',
        placeholder: { type: 'plain_text', text: '대결자' },
        options: [
          { text: { type: 'plain_text', text: '김가' }, value: 'u1' },
          { text: { type: 'plain_text', text: '이나' }, value: 'u2' },
        ],
      },
    ],
  },
  { type: 'context', elements: [{ type: 'mrkdwn', text: '인사팀 봇' }, { type: 'image', image_url: 'https://x/i.png' }] },
];

test('블록 거르기: Slack 모양 → 저장 모양(글 객체·링크 표기·단추·선택지)', () => {
  const b = sanitizeBlocks(slackApproval);
  assert.deepEqual(b[0], { type: 'header', text: '휴가 승인 요청' });
  assert.equal(b[1].text, '*홍길동* 님 · 신청서 (https://hr.example/r/1)');
  assert.deepEqual(b[1].fields, ['*기간*\n3/2~3/4', '연차']);
  assert.equal(b[1].accessory, null);
  assert.deepEqual(b[2], { type: 'divider' });
  const actions = b[3];
  assert.equal(actions.blockId, 'approve-1');
  assert.deepEqual(actions.elements[0], { type: 'button', actionId: 'approve', text: '승인', value: 'r1', url: null, style: 'primary' });
  assert.equal(actions.elements[2].url, 'https://hr.example/r/1');
  assert.deepEqual(actions.elements[3], {
    type: 'select',
    actionId: 'delegate',
    placeholder: '대결자',
    options: [
      { text: '김가', value: 'u1' },
      { text: '이나', value: 'u2' },
    ],
    initial: null,
  });
  assert.deepEqual(b[4], { type: 'context', text: '인사팀 봇' }, '문맥의 그림은 뺀다');
});

test('블록 거르기: 모르는 것·빈 것·잘못된 것은 빼고, 다 빠지면 null', () => {
  assert.equal(sanitizeBlocks(null), null);
  assert.equal(sanitizeBlocks('x'), null);
  assert.equal(sanitizeBlocks([{ type: 'video' }, { type: 'header', text: '' }, null]), null);
  const b = sanitizeBlocks([
    { type: 'actions', elements: [{ type: 'button', text: '' }, { type: 'overflow' }, { type: 'button', text: 'ok', url: 'javascript:x' }] },
  ]);
  assert.deepEqual(b[0].elements, [{ type: 'button', actionId: '0-2', text: 'ok', value: null, url: null, style: null }], 'action_id가 없으면 자리 번호, 위험한 주소는 뺀다');
  // 같은 action_id가 또 오면 자리 번호로 바꾼다(누른 것을 하나로 찾게).
  const dup = sanitizeBlocks([{ type: 'actions', elements: [{ type: 'button', text: 'a', action_id: 'x' }, { type: 'button', text: 'b', action_id: 'x' }] }]);
  assert.deepEqual(dup[0].elements.map((e) => e.actionId), ['x', '0-1']);
  // 제어 문자는 뗀다(줄바꿈은 남긴다).
  assert.equal(sanitizeBlocks([{ type: 'section', text: 'a\u0007b\nc' }])[0].text, 'ab\nc');
});

test('블록 그림: 바깥 주소는 받아 둔 경로로, 못 받은 것은 글로, 앱에는 서명 링크로', () => {
  const many = Array.from({ length: BLOCK_IMAGES_MAX + 2 }, (_, i) => ({ type: 'image', image_url: `https://img.example/${i}.png`, alt_text: `그림${i}` }));
  const b = sanitizeBlocks(many);
  assert.equal(b.length, BLOCK_IMAGES_MAX, '그림은 정해진 수까지');
  assert.deepEqual(blockImageSources(b).slice(0, 2), ['https://img.example/0.png', 'https://img.example/1.png']);
  const resolved = resolveBlockImages(b, new Map([['https://img.example/0.png', '/uploads/a.webp']]));
  assert.deepEqual(resolved[0], { type: 'image', file: '/uploads/a.webp', alt: '그림0', title: null });
  assert.deepEqual(resolved[1], { type: 'context', text: '그림1: https://img.example/1.png' });
  const signed = mapBlockImages(resolved, (f) => `/files/signed${f}`);
  assert.deepEqual(signed[0], { type: 'image', url: '/files/signed/uploads/a.webp', alt: '그림0', title: null });
  assert.equal(mapBlockImages(null, () => ''), null);
});

test('블록 → 글(검색·알림·예전 앱), 단추 있는지', () => {
  const b = sanitizeBlocks(slackApproval);
  assert.equal(
    blocksToText(b),
    '휴가 승인 요청\n*홍길동* 님 · 신청서 (https://hr.example/r/1)\n*기간*\n3/2~3/4\n연차\n[승인] [반려] [열기] [대결자]\n인사팀 봇',
  );
  assert.equal(blocksHaveActions(b), true);
  assert.equal(blocksHaveActions(sanitizeBlocks([{ type: 'actions', elements: [{ type: 'button', text: '열기', url: 'https://x.example' }] }])), false, '링크 단추만');
  assert.equal(plainFromSlack('<!channel> &lt;b&gt;'), '@channel <b>');
});

test('누른 것 찾기 — 단추는 저장한 값, 선택지는 보기 중 하나일 때만, 링크 단추·없는 id는 null', () => {
  const b = sanitizeBlocks([
    ...slackApproval,
    { type: 'section', text: '환경', accessory: { type: 'static_select', action_id: 'env', options: [{ text: '운영', value: 'prod' }] } },
  ]);
  assert.deepEqual(findBlockAction(b, 'approve'), { element: b[3].elements[0], blockId: 'approve-1', value: 'r1' });
  assert.deepEqual(findBlockAction(b, 'delegate', 'u2'), { element: b[3].elements[3], blockId: 'approve-1', value: 'u2', optionText: '이나' });
  assert.equal(findBlockAction(b, 'delegate', 'u9'), null, '없는 보기');
  assert.equal(findBlockAction(b, 'open'), null, '링크 단추는 서버로 오지 않는다');
  assert.equal(findBlockAction(b, 'nope'), null);
  assert.equal(findBlockAction(null, 'approve'), null);
  assert.equal(findBlockAction(b, 'env', 'prod').value, 'prod', '글 칸의 곁들임(accessory)도');
});
