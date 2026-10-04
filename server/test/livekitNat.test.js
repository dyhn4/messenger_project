// 화상회의 공인 IP 설정(livekit.yaml rtc 블록) 단위 테스트 — `node --test test/*.test.js` (DB·LiveKit 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { applyLivekitNat, livekitMediaPorts } from '../src/livekitNat.js';

// 설치 프로그램(Setup-TangoTalkServer.ps1)이 만드는 모양 그대로.
const installed = [
  '# TangoTalk 설치 프로그램이 자동 생성했습니다.',
  'port: 7880',
  'rtc:',
  '  port_range_start: 50000',
  '  port_range_end: 60000',
  '  tcp_port: 7881',
  '  use_external_ip: false',
  'turn:',
  '  enabled: true',
  '  udp_port: 3478',
  'keys:',
  '  tangotalk: secret',
].join('\r\n');

test('외부 주소를 쓴 적 없는 서버는 설정을 그대로 둔다(LiveKit 재시작 없음)', () => {
  assert.equal(applyLivekitNat(installed, null), installed);
});

test('공인 IP를 넣으면 rtc 안에 node_ip + advertise_internal_ip, 나머지·줄바꿈은 그대로', () => {
  const out = applyLivekitNat(installed, '203.0.113.5');
  const lines = out.split('\r\n');
  const rtc = lines.slice(lines.indexOf('rtc:') + 1, lines.indexOf('turn:'));
  assert.ok(rtc.includes('  port_range_start: 50000'));
  assert.ok(rtc.includes('  use_external_ip: false'));
  assert.ok(rtc.includes('  node_ip: 203.0.113.5'));
  assert.ok(rtc.includes('  advertise_internal_ip: true'));
  assert.equal(rtc.filter((l) => l.includes('use_external_ip')).length, 1);
  assert.ok(out.includes('turn:\r\n  enabled: true'));
  assert.ok(out.endsWith('  tangotalk: secret'));
});

test('같은 IP로 다시 맞추면 바뀌지 않고, IP가 바뀌면 그 줄만 바뀐다', () => {
  const once = applyLivekitNat(installed, '203.0.113.5');
  assert.equal(applyLivekitNat(once, '203.0.113.5'), once);
  const moved = applyLivekitNat(once, '198.51.100.7');
  assert.ok(moved.includes('node_ip: 198.51.100.7'));
  assert.ok(!moved.includes('203.0.113.5'));
});

test('외부 주소를 끄면 설치 때 모양(사내 IP만)으로 돌아간다', () => {
  const on = applyLivekitNat(installed, '203.0.113.5');
  assert.equal(applyLivekitNat(on, null), installed);
});

test('rtc 블록이 없으면 새로 만든다', () => {
  const out = applyLivekitNat('port: 7880\nkeys:\n  k: v\n', '203.0.113.5');
  assert.match(out, /\nrtc:\n {2}# .*\n {2}use_external_ip: false\n {2}node_ip: 203\.0\.113\.5\n {2}advertise_internal_ip: true\n$/);
});

test('공유기에 열 미디어 포트를 읽는다', () => {
  assert.deepEqual(livekitMediaPorts(installed), { udpStart: 50000, udpEnd: 60000, tcp: 7881 });
  assert.deepEqual(livekitMediaPorts('port: 7880'), { udpStart: 50000, udpEnd: 60000, tcp: 7881 });
});
