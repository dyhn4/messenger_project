// 통화 녹화·회의록 후속 — 회의록 할 일 나누기, 녹화 파일 보관 정리, 말한 사람 나누기, 화이트보드 저장 모양, 실시간 자막의 소리 다루기.
// `node --test test/*.test.js`(DB 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  captionTextFrom,
  pcmFormatFromHeaders,
  pcmToMono,
  resampleTo16k,
  Utterancer,
  wavFromSamples,
} from '../src/callCaptionRules.js';
import {
  actionItemsFromSummary,
  cardRecordingEntry,
  hasSpeakerNames,
  localRecordingPath,
  mergeSpeakerTranscripts,
  minutesPrompt,
  newSpeakerTracks,
  parseDueDate,
  parseRecordingRetention,
  planRecordingPurge,
  speakerTrackFileBase,
} from '../src/callRecordingRules.js';
import { parseWhiteboardData, whiteboardTitle } from '../src/callWhiteboardRules.js';

test('회의록 할 일 — "담당자: 할 일 (기한)"을 나누고, 날짜로 읽히는 기한만 날짜로', () => {
  const summary = [
    '## 요약',
    '- 이건 할 일이 아님',
    '',
    '## 할 일',
    '- 김민수: 견적서 보내기 (2026-10-30)',
    '- **박지영**: 디자인 시안 정리 (10/25)',
    '* 서버 점검 일정 잡기',
    '1. 미정: 고객 연락 (기한: 11월 3일)',
    '- 이수진: 회의록 공유 (다음 주)',
    '- 다음 회의 안건: 예산 확정하기',
    '',
    '## 기타',
    '- 다른 칸',
  ].join('\n');
  const items = actionItemsFromSummary(summary, { meetingAt: new Date(2026, 9, 22) });
  assert.deepEqual(items, [
    { text: '견적서 보내기', owner: '김민수', dueText: '2026-10-30', due: '2026-10-30' },
    { text: '디자인 시안 정리', owner: '박지영', dueText: '10/25', due: '2026-10-25' },
    { text: '서버 점검 일정 잡기', owner: null, dueText: null, due: null },
    { text: '고객 연락', owner: null, dueText: '11월 3일', due: '2026-11-03' },
    { text: '회의록 공유', owner: '이수진', dueText: '다음 주', due: null },
    // 앞쪽이 두 낱말보다 길면 담당자가 아니라 글이다.
    { text: '다음 회의 안건: 예산 확정하기', owner: null, dueText: null, due: null },
  ]);
  assert.deepEqual(actionItemsFromSummary('## 할 일\n- 없음'), []);
  assert.deepEqual(actionItemsFromSummary(null), []);
  assert.deepEqual(actionItemsFromSummary('## 요약\n- 할 일 칸이 없음'), []);
  // 해가 없는 날짜 — 12월 회의의 1월은 다음 해, 없는 날은 null.
  assert.equal(parseDueDate('1/10', new Date(2026, 11, 20)), '2027-01-10');
  assert.equal(parseDueDate('2/30', new Date(2026, 0, 1)), null);
  assert.equal(parseDueDate('2026.3.5'), '2026-03-05');
});

test('녹화 파일 보관 — 기간이 지난 것부터, 그래도 넘으면 오래된 것부터 용량 안으로', () => {
  const day = 24 * 60 * 60 * 1000;
  const now = Date.UTC(2026, 9, 22);
  const rows = [
    { id: 'c', startedAt: new Date(now - 2 * day), fileSize: 300 },
    { id: 'a', startedAt: new Date(now - 40 * day), fileSize: 100 },
    { id: 'b', startedAt: new Date(now - 10 * day), fileSize: 200 },
    { id: 'd', startedAt: new Date(now - 1 * day), fileSize: 400 },
  ];
  assert.deepEqual(planRecordingPurge(rows, { now }), []);
  assert.deepEqual(planRecordingPurge(rows, { now, retentionDays: 30 }), [{ id: 'a', reason: 'age' }]);
  assert.deepEqual(planRecordingPurge(rows, { now, retentionDays: 30, maxBytes: 700 }), [
    { id: 'a', reason: 'age' },
    { id: 'b', reason: 'size' },
  ]);
  assert.deepEqual(planRecordingPurge(rows, { now, maxBytes: 0 }).map((p) => p.id), ['a', 'b', 'c', 'd']);

  assert.deepEqual(parseRecordingRetention({ retentionDays: 90, maxGb: '' }), {
    fields: { callRecordingRetentionDays: 90, callRecordingMaxGb: null },
  });
  assert.deepEqual(parseRecordingRetention({ maxGb: 500 }), { fields: { callRecordingMaxGb: 500 } });
  assert.match(parseRecordingRetention({ retentionDays: -1 }).error, /보관 기간/);
  assert.match(parseRecordingRetention({ maxGb: 1.5 }).error, /전체 용량/);
  assert.match(parseRecordingRetention({}).error, /바꿀 내용/);

  // 카드에는 지운 까닭만.
  const entry = cardRecordingEntry({ id: 'r', startedAt: new Date(now), startedBy: 'u', startedByName: 'A', audioOnly: false, status: 'done', minutesStatus: 'done', purgedAt: new Date(now), purgeReason: 'size' });
  assert.equal(entry.purged, 'size');
});

test('말한 사람 나누기 — 새 마이크만 상한까지, 사람마다 받아쓴 것을 시각 순으로 합친다', () => {
  const existing = [{ trackSid: 'TR_a' }];
  const live = [
    { identity: 'u1', name: '김민수', trackSid: 'TR_a' },
    { identity: 'u2', name: '박지영', trackSid: 'TR_b' },
    { identity: 'u3', name: '이수진', trackSid: 'TR_c' },
  ];
  assert.deepEqual(newSpeakerTracks(existing, live).map((t) => t.trackSid), ['TR_b', 'TR_c']);
  assert.deepEqual(newSpeakerTracks(existing, live, 2).map((t) => t.trackSid), ['TR_b']);
  assert.deepEqual(newSpeakerTracks([], [{ identity: 'x', trackSid: '' }]), []);

  const id = '0b7f3d1e-1111-4222-8333-444455556666';
  assert.equal(speakerTrackFileBase(id, 3), `${id}-spk-3.ogg`);
  // 녹화 폴더에서 옮겨 올 수 있는 이름.
  assert.ok(localRecordingPath(`/out/${id}-spk-3.ogg`, '/rec'));
  assert.equal(localRecordingPath(`/out/${id}-spk-x.ogg`, '/rec'), null);

  const merged = mergeSpeakerTranscripts([
    { name: '김민수', offsetSeconds: 0, response: { segments: [{ start: 1, text: ' 시작하겠습니다 ' }, { start: 30, text: '네 좋습니다' }] } },
    { name: '박지영', offsetSeconds: 20, response: { segments: [{ start: 2, text: '자료 공유할게요' }, { start: 3, text: '' }] } },
    { name: '이수진', offsetSeconds: 65, response: '한 줄 글' },
  ]);
  assert.equal(merged, ['[00:01] 김민수: 시작하겠습니다', '[00:22] 박지영: 자료 공유할게요', '[00:30] 김민수: 네 좋습니다', '[01:05] 이수진: 한 줄 글'].join('\n'));
  assert.equal(hasSpeakerNames(merged), true);
  assert.equal(hasSpeakerNames('[00:01] 그냥 받아쓴 말\n[00:05] 또 말'), false);
  // 요약에 이름이 말한 사람이라고 알려 준다.
  assert.match(minutesPrompt({ roomName: 'R', startedAt: 0, durationMs: 1000, participantNames: [], transcript: merged }).system, /이름:"이 그 말을 한 사람/);
  assert.match(minutesPrompt({ roomName: 'R', startedAt: 0, durationMs: 1000, participantNames: [], transcript: '[00:01] 말' }).system, /확실할 때만/);
});

test('화이트보드 저장 모양 — 쪽·획·점 모양을 보고, 넘치면 거절, 제목 기본값', () => {
  const ok = parseWhiteboardData({
    v: 1,
    pages: [
      { id: 'p1', strokes: [{ id: 's1', a: 'u1', c: 0xff000000, w: 0.004, p: [100, 200, 3, -4], extra: 'drop' }] },
      { id: 'u1-p2', strokes: [] },
    ],
  });
  assert.equal(ok.pageCount, 2);
  assert.deepEqual(ok.data.pages[0].strokes[0], { id: 's1', a: 'u1', c: 0xff000000, w: 0.004, p: [100, 200, 3, -4] });
  for (const bad of [
    null,
    { v: 2, pages: [] },
    { v: 1, pages: [] },
    { v: 1, pages: [{ id: 'p1', strokes: [{ id: 's', c: 1, w: 0.004, p: [1] }] }] },
    { v: 1, pages: [{ id: 'p1', strokes: [{ id: 's', c: 1, w: 2, p: [] }] }] },
    { v: 1, pages: [{ id: 'p1', strokes: [{ id: 's', c: 1, w: 0.004, p: [99999, 0] }] }] },
    { v: 1, pages: Array.from({ length: 21 }, (_, i) => ({ id: `p${i}`, strokes: [] })) },
  ]) {
    assert.ok(parseWhiteboardData(bad).error, JSON.stringify(bad)?.slice(0, 80));
  }
  const huge = { v: 1, pages: [{ id: 'p1', strokes: [{ id: 's', c: 1, w: 0.004, p: new Array(400_002).fill(1) }] }] };
  assert.match(parseWhiteboardData(huge).error, /너무 많아/);
  assert.equal(whiteboardTitle('  회의 판  '), '회의 판');
  assert.equal(whiteboardTitle('', new Date(2026, 9, 22, 9, 5)), '화이트보드 2026-10-22 09.05');
});

test('실시간 자막 — 형식 읽기, 모노·16kHz WAV, 말 한 마디씩 끊기, 지어낸 말 버리기', () => {
  assert.deepEqual(pcmFormatFromHeaders({ 'content-type': 'audio/x-raw;format=S16LE;rate=24000;channels=2' }), { sampleRate: 24000, channels: 2 });
  assert.deepEqual(pcmFormatFromHeaders({}, { sampleRate: 44100, channels: 1 }), { sampleRate: 44100, channels: 1 });

  const stereo = Buffer.alloc(8);
  stereo.writeInt16LE(16384, 0);
  stereo.writeInt16LE(-16384, 2);
  stereo.writeInt16LE(32767, 4);
  stereo.writeInt16LE(32767, 6);
  const mono = pcmToMono(stereo, 2);
  assert.equal(mono.length, 2);
  assert.equal(mono[0], 0);
  assert.ok(mono[1] > 0.99);
  assert.equal(resampleTo16k(new Float32Array(48000), 48000).length, 16000);
  const wav = wavFromSamples(new Float32Array(160));
  assert.equal(wav.toString('ascii', 0, 4), 'RIFF');
  assert.equal(wav.readUInt32LE(24), 16000);
  assert.equal(wav.length, 44 + 320);

  // 16kHz: 조용함 0.5초 → 말 1초 → 조용함 1초 → 짧은 딸깍(0.1초) → 조용함 1초.
  const rate = 16000;
  const tone = (seconds) => Float32Array.from({ length: rate * seconds }, (_, i) => 0.3 * Math.sin(i / 5));
  const quiet = (seconds) => new Float32Array(rate * seconds);
  const u = new Utterancer(rate);
  const got = [];
  for (const chunk of [quiet(0.5), tone(1), quiet(1), tone(0.1), quiet(1)]) {
    // 조각을 여럿으로 나눠 넣어도(웹소켓 메시지 크기와 상관없이) 같게.
    for (let i = 0; i < chunk.length; i += 777) got.push(...u.push(chunk.subarray(i, i + 777)));
  }
  assert.equal(got.length, 1, '짧은 딸깍은 버린다');
  assert.ok(Math.abs(got[0].startMs - 200) <= 40, `말 앞 0.3초를 붙여 시작(${got[0].startMs})`);
  assert.ok(got[0].samples.length >= rate * 1.2 && got[0].samples.length <= rate * 2.1);
  // 길게 이어 말하면 10초에서 끊는다.
  const long = new Utterancer(rate);
  const cuts = long.push(tone(23));
  assert.equal(cuts.length, 2);
  assert.ok(long.flush());

  assert.equal(captionTextFrom({ text: '  안녕하세요\n 여러분 ' }), '안녕하세요 여러분');
  assert.equal(captionTextFrom('시청해 주셔서 감사합니다.'), '');
  assert.equal(captionTextFrom({ text: '감사합니다' }), '감사합니다');
  assert.equal(captionTextFrom(null), '');
});
