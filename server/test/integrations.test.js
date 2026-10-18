// 외부 연동 규칙 — 토큰 모양, 들어오는 웹훅 본문(일반·Slack·Discord·그냥 글)을 글로 바꾸기, 슬래시 명령 서명·답 읽기, 누가 만들 수
// 있는지. `node --test test/*.test.js`(DB·네트워크 없이 돈다).
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { test } from 'node:test';
import {
  API_TOKEN_PREFIX,
  canManageRoomWebhooks,
  DEFAULT_BOT_EMOJI,
  generateSecretToken,
  isSecretToken,
  parseBotEmoji,
  parseBotName,
  parseCommandName,
  parseCommandResponse,
  parseCommandUrl,
  parseExpiry,
  parseScopes,
  parseSlashInvocation,
  roomAcceptsIntegrations,
  signCommandRequest,
  tokenHasScope,
  tokenPrefixOf,
  WEBHOOK_TOKEN_PREFIX,
  webhookPayloadToMessage,
} from '../src/integrationRules.js';
import { MESSAGE_TEXT_MAX } from '../src/messageLimits.js';

test('비밀 토큰: 접두어 + 영문·숫자 40자, 모양이 틀리면 거른다', () => {
  const t = generateSecretToken(WEBHOOK_TOKEN_PREFIX);
  assert.match(t, /^ttw_[A-Za-z0-9]{40}$/);
  assert.equal(isSecretToken(t, WEBHOOK_TOKEN_PREFIX), true);
  assert.equal(isSecretToken(t, API_TOKEN_PREFIX), false, '다른 종류 토큰');
  assert.equal(isSecretToken(`${t}x`, WEBHOOK_TOKEN_PREFIX), false);
  assert.equal(isSecretToken(`${t.slice(0, -1)}-`, WEBHOOK_TOKEN_PREFIX), false);
  assert.equal(isSecretToken(undefined, WEBHOOK_TOKEN_PREFIX), false);
  assert.notEqual(generateSecretToken(API_TOKEN_PREFIX), generateSecretToken(API_TOKEN_PREFIX));
  assert.equal(tokenPrefixOf(t), t.slice(0, 8));
});

test('봇 이름·아이콘: 공백·제어 문자 정리, 길이, 기본 아이콘', () => {
  assert.deepEqual(parseBotName('  배포 알림 '), { name: '배포 알림' });
  assert.ok(parseBotName('').error);
  assert.ok(parseBotName('가'.repeat(41)).error);
  assert.deepEqual(parseBotName('a\u0007b'), { name: 'ab' });
  assert.deepEqual(parseBotEmoji(undefined), { emoji: DEFAULT_BOT_EMOJI });
  assert.deepEqual(parseBotEmoji(' 🚀 '), { emoji: '🚀' });
  assert.deepEqual(parseBotEmoji('👩‍💻'), { emoji: '👩‍💻' }, '조합 이모지');
  assert.ok(parseBotEmoji('아주아주긴글자들입니다').error);
});

test('슬래시 명령 이름·주소', () => {
  assert.deepEqual(parseCommandName('/Deploy'), { command: 'deploy' });
  assert.deepEqual(parseCommandName('build_2-x'), { command: 'build_2-x' });
  assert.ok(parseCommandName('').error);
  assert.ok(parseCommandName('-x').error);
  assert.ok(parseCommandName('배포').error);
  assert.ok(parseCommandName('a'.repeat(33)).error);
  assert.deepEqual(parseCommandUrl('https://ci.example.com/hook'), { url: 'https://ci.example.com/hook' });
  assert.ok(parseCommandUrl('ftp://x').error);
  assert.ok(parseCommandUrl('https://u:p@x.com').error);
  assert.ok(parseCommandUrl('그냥 글').error);
});

test('API 토큰 권한·만료', () => {
  assert.deepEqual(parseScopes(['read']), { scopes: ['read'] });
  assert.deepEqual(parseScopes(['write']), { scopes: ['read', 'write'] }, '쓰기는 읽기를 포함');
  assert.ok(parseScopes([]).error);
  assert.ok(parseScopes(['admin']).error);
  assert.ok(parseScopes('read').error);
  assert.deepEqual(parseExpiry(null), { expiresAt: null });
  assert.equal(parseExpiry(30, 0).expiresAt.getTime(), 30 * 86_400_000);
  assert.ok(parseExpiry(0).error);
  assert.ok(parseExpiry(366).error);
  assert.ok(parseExpiry(1.5).error);
  assert.equal(tokenHasScope(['read'], 'write'), false);
  assert.equal(tokenHasScope(['read', 'write'], 'write'), true);
  assert.equal(tokenHasScope(null, 'read'), false);
});

test('웹훅 본문: 일반 JSON·그냥 글', () => {
  // 블록·바깥 그림이 없으면 blocks: null, imageUrls: [].
  const plain = (text) => ({ text, blocks: null, imageUrls: [] });
  assert.deepEqual(webhookPayloadToMessage({ text: '서버 다운' }), plain('서버 다운'));
  assert.deepEqual(webhookPayloadToMessage({ message: 'm' }), plain('m'));
  assert.deepEqual(
    webhookPayloadToMessage({ title: '설문 응답', body: '홍길동: 좋아요', url: 'https://f.example/1' }),
    plain('설문 응답\n\n홍길동: 좋아요\n\nhttps://f.example/1'),
  );
  assert.deepEqual(webhookPayloadToMessage('  그냥 글  '), plain('그냥 글'));
  // 파일을 함께 올리면(multipart) 글이 없어도 된다.
  assert.deepEqual(webhookPayloadToMessage({}, { allowEmpty: true }), plain(''));
  assert.ok(webhookPayloadToMessage('').error);
  assert.ok(webhookPayloadToMessage({}).error);
  assert.ok(webhookPayloadToMessage([1, 2]).error);
  assert.ok(webhookPayloadToMessage(null).error);
  assert.equal([...webhookPayloadToMessage({ text: 'a'.repeat(MESSAGE_TEXT_MAX + 50) }).text].length, MESSAGE_TEXT_MAX, '… 포함 상한 안');
});

test('웹훅 본문: Slack 호환(첨부·블록·링크 표기·보낸 이름)', () => {
  const slack = webhookPayloadToMessage({
    username: 'Grafana',
    text: '<https://g.example/d/1|대시보드> 경보 &amp; 확인',
    attachments: [
      {
        title: 'CPU 높음',
        title_link: 'https://g.example/a',
        text: '90% 넘음',
        fields: [{ title: '서버', value: 'web-1' }],
        footer: 'Grafana',
      },
    ],
  });
  assert.equal(slack.username, 'Grafana');
  assert.equal(
    slack.text,
    '대시보드 (https://g.example/d/1) 경보 & 확인\n\nCPU 높음 (https://g.example/a)\n90% 넘음\n서버: web-1\nGrafana',
  );
  const blocks = webhookPayloadToMessage({
    blocks: [
      { type: 'header', text: { type: 'plain_text', text: '배포 완료' } },
      { type: 'section', text: { type: 'mrkdwn', text: '*v1.2* <!here>' } },
      { type: 'divider' },
      { type: 'context', elements: [{ type: 'mrkdwn', text: 'by CI' }] },
    ],
  });
  assert.equal(blocks.text, '배포 완료\n*v1.2* @here\nby CI');
  // text가 있으면 blocks는 text의 대체 글로 보고 겹쳐 싣지 않는다.
  assert.equal(webhookPayloadToMessage({ text: '요약', blocks: [{ type: 'section', text: { text: '자세히' } }] }).text, '요약');
  // 첨부에 fallback만 있으면 그것을.
  assert.equal(webhookPayloadToMessage({ attachments: [{ fallback: '대체 글' }] }).text, '대체 글');
});

test('웹훅 본문: Discord 호환(embeds)', () => {
  const d = webhookPayloadToMessage({
    content: '빌드 결과',
    embeds: [{ title: '#42 실패', url: 'https://ci.example/42', description: '테스트 3개 실패', fields: [{ name: '브랜치', value: 'main' }] }],
  });
  assert.equal(d.text, '빌드 결과\n\n#42 실패 (https://ci.example/42)\n테스트 3개 실패\n브랜치: main');
});

test('슬래시 입력 읽기', () => {
  assert.deepEqual(parseSlashInvocation('/Deploy  web 1 '), { command: 'deploy', text: 'web 1' });
  assert.deepEqual(parseSlashInvocation('/status'), { command: 'status', text: '' });
  assert.deepEqual(parseSlashInvocation('/note 줄1\n줄2'), { command: 'note', text: '줄1\n줄2' });
  assert.equal(parseSlashInvocation('그냥 글'), null);
  assert.equal(parseSlashInvocation('//x'), null);
  assert.equal(parseSlashInvocation('/ x'), null);
  assert.equal(parseSlashInvocation('/한글'), null);
});

test('슬래시 명령 서명 — 받는 쪽이 같은 계산으로 맞출 수 있다', () => {
  const body = JSON.stringify({ command: '/deploy', text: 'web' });
  const sig = signCommandRequest('s3cret', '1700000000', body);
  const expected = crypto.createHmac('sha256', 's3cret').update(`1700000000.${body}`).digest('hex');
  assert.equal(sig, `v1=${expected}`);
  assert.notEqual(signCommandRequest('s3cret', '1700000001', body), sig, '시각이 다르면 서명도 다르다');
});

test('슬래시 명령 답 읽기', () => {
  assert.deepEqual(parseCommandResponse({ status: 200, contentType: 'application/json', bodyText: '{"text":"완료"}' }), {
    text: '완료',
    blocks: null,
    inChannel: false,
  });
  assert.deepEqual(
    parseCommandResponse({
      status: 200,
      contentType: 'application/json; charset=utf-8',
      bodyText: '{"response_type":"in_channel","text":"배포 시작"}',
    }),
    { text: '배포 시작', blocks: null, inChannel: true },
  );
  assert.deepEqual(parseCommandResponse({ status: 200, contentType: 'text/plain', bodyText: '확인' }), { text: '확인', blocks: null, inChannel: false });
  assert.deepEqual(parseCommandResponse({ status: 204 }), { empty: true });
  assert.deepEqual(parseCommandResponse({ status: 200, contentType: 'application/json', bodyText: '{}' }), { empty: true });
  assert.ok(parseCommandResponse({ status: 500, bodyText: 'x' }).error);
  assert.ok(parseCommandResponse({ status: 200, contentType: 'application/json', bodyText: '{깨짐' }).error);
});

test('연동을 붙일 수 있는 방과 관리할 수 있는 사람', () => {
  const topic = { type: 'topic', viewMode: 'chat', isSecret: false };
  const group = { type: 'group', isSecret: false };
  assert.equal(roomAcceptsIntegrations(topic), true);
  assert.equal(roomAcceptsIntegrations(group), true);
  assert.equal(roomAcceptsIntegrations({ ...topic, viewMode: 'board' }), false);
  assert.equal(roomAcceptsIntegrations({ type: 'dm', isSecret: false }), false);
  assert.equal(roomAcceptsIntegrations({ type: 'self', isSecret: false }), false);
  assert.equal(roomAcceptsIntegrations({ ...group, isSecret: true }), false);
  assert.equal(roomAcceptsIntegrations(null), false);

  assert.equal(canManageRoomWebhooks(topic, { canManage: true }), true);
  assert.equal(canManageRoomWebhooks(topic, { canManage: false, isRoomMember: true, role: 'admin' }), false);
  assert.equal(canManageRoomWebhooks(group, { isRoomMember: true, role: 'member' }), true);
  assert.equal(canManageRoomWebhooks(group, { isRoomMember: true, role: 'guest' }), false, '준회원은 안 됨');
  assert.equal(canManageRoomWebhooks(group, { isRoomMember: false, role: 'admin' }), false);
});
