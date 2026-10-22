// 화상회의 녹화·회의록 규칙(callRecordingRules.js)과 통화 상태의 녹화 표시(callState.js) 단위 테스트 — `node --test test/*.test.js` (DB·서버 없이 돈다).
import assert from 'node:assert/strict';
import path from 'node:path';
import { test } from 'node:test';
import {
  cardRecordingEntry,
  clockText,
  durationText,
  egressOutcome,
  egressPathFor,
  EGRESS_STATUS,
  localRecordingPath,
  minutesPrompt,
  participantNamesFromCard,
  recordingDisplayName,
  recordingFileBase,
  recordingMessageText,
  recordingStartDenial,
  recordingStopDenial,
  SUMMARY_TRANSCRIPT_MAX,
  transcriptFromResponse,
} from '../src/callRecordingRules.js';
import { callStateFor, joinCall, leaveCall, setCallRecording } from '../src/callState.js';

const call = { active: true, hostId: 'host', participantIds: ['host', 'b'] };
const base = { enabled: true, call, userId: 'host', recording: false, minutesWanted: false, minutesEnabled: false };

test('녹화 시작 — 진행 중인 통화의 진행자만, 한 번에 하나', () => {
  assert.equal(recordingStartDenial(base), null);
  assert.match(recordingStartDenial({ ...base, enabled: false }), /설정되어 있지 않습니다/);
  assert.match(recordingStartDenial({ ...base, call: { ...call, active: false } }), /진행 중인 화상회의가 없습니다/);
  assert.match(recordingStartDenial({ ...base, userId: 'c' }), /들어와 있을 때만/);
  assert.match(recordingStartDenial({ ...base, userId: 'b' }), /진행자만/);
  assert.match(recordingStartDenial({ ...base, recording: true }), /이미 녹화/);
  assert.match(recordingStartDenial({ ...base, minutesWanted: true }), /회의록\(받아쓰기\)이 설정되어/);
  assert.equal(recordingStartDenial({ ...base, minutesWanted: true, minutesEnabled: true }), null);
});

test('녹화 멈춤 — 시작한 사람이나 지금 진행자', () => {
  const recording = { startedBy: 'host' };
  assert.match(recordingStopDenial({ recording: null, call, userId: 'host' }), /녹화하고 있지 않습니다/);
  assert.equal(recordingStopDenial({ recording, call, userId: 'host' }), null);
  // 진행자가 넘어간 뒤에도 시작한 사람은 멈출 수 있고, 새 진행자도 멈출 수 있다.
  const moved = { ...call, hostId: 'b' };
  assert.equal(recordingStopDenial({ recording, call: moved, userId: 'host' }), null);
  assert.equal(recordingStopDenial({ recording, call: moved, userId: 'b' }), null);
  assert.match(recordingStopDenial({ recording, call, userId: 'b' }), /시작한 사람이나 진행자만/);
});

test('녹화 파일 경로 — Egress에 시킨 이름만 녹화 폴더 안에서 찾는다', () => {
  const id = '0f8fad5b-d9cb-469f-a165-70867728950e';
  assert.equal(recordingFileBase(id, { audioOnly: false }), `${id}.mp4`);
  assert.equal(recordingFileBase(id, { audioOnly: true }), `${id}.mp3`);
  assert.equal(recordingFileBase(id, { audioOnly: true, purpose: 'minutes' }), `${id}-minutes.mp3`);
  assert.equal(egressPathFor('/out/', `${id}.mp4`), `/out/${id}.mp4`);
  const local = path.join('D:', 'rec');
  assert.equal(localRecordingPath(`/out/${id}.mp4`, local), path.join(local, `${id}.mp4`));
  assert.equal(localRecordingPath(`/out/${id}-minutes.mp3`, local), path.join(local, `${id}-minutes.mp3`));
  // 다른 이름·폴더 밖으로 나가는 이름은 받지 않는다.
  assert.equal(localRecordingPath('/out/../../etc/passwd', local), null);
  assert.equal(localRecordingPath('/out/meeting.mp4', local), null);
  assert.equal(localRecordingPath(`/out/${id}.exe`, local), null);
  assert.equal(localRecordingPath(`/out/${id}.mp4`, null), null);
});

test('녹화 파일 이름·메시지 글', () => {
  const at = new Date(2026, 9, 19, 14, 5);
  assert.equal(recordingDisplayName(at, { audioOnly: false }), '화상회의 녹화 2026-10-19 14.05.mp4');
  assert.equal(recordingDisplayName(at, { audioOnly: true }), '화상회의 녹음 2026-10-19 14.05.mp3');
  assert.equal(recordingMessageText({ audioOnly: false, durationMs: 12 * 60_000 }), '화상회의 녹화 · 12분');
  assert.equal(recordingMessageText({ audioOnly: true, durationMs: null }), '화상회의 녹음');
  assert.equal(durationText(42_000), '42초');
  assert.equal(durationText(3_600_000), '1시간');
  assert.equal(durationText(3_780_000), '1시간 3분');
});

test('Egress 상태 — 끝날 때까지 기다리고, 파일 결과를 읽는다', () => {
  assert.deepEqual(egressOutcome({ status: EGRESS_STATUS.ACTIVE }), { done: false });
  assert.deepEqual(egressOutcome({ status: EGRESS_STATUS.ENDING }), { done: false });
  const done = egressOutcome({
    status: EGRESS_STATUS.COMPLETE,
    fileResults: [{ filename: '/out/a.mp4', size: 1234n, duration: 90_000_000_000n }],
  });
  assert.deepEqual(done, { done: true, ok: true, filename: '/out/a.mp4', size: 1234, durationMs: 90_000, startedAtMs: null });
  // 최대 길이에 걸려 멈춘 것도 그때까지의 파일은 쓴다.
  assert.equal(egressOutcome({ status: EGRESS_STATUS.LIMIT_REACHED, fileResults: [{ filename: '/out/a.mp4' }] }).ok, true);
  const failed = egressOutcome({ status: EGRESS_STATUS.FAILED, error: 'no chrome' });
  assert.deepEqual(failed, { done: true, ok: false, error: 'no chrome' });
  assert.equal(egressOutcome({ status: EGRESS_STATUS.ABORTED }).error, '녹화가 중단되었습니다.');
  // 끝났다는데 파일이 없으면 실패.
  assert.equal(egressOutcome({ status: EGRESS_STATUS.COMPLETE, fileResults: [] }).ok, false);
});

test('받아쓰기 응답 — 구간마다 시각을 붙인 줄, 아니면 글 그대로', () => {
  assert.equal(clockText(5), '00:05');
  assert.equal(clockText(205.7), '03:25');
  assert.equal(clockText(3723), '1:02:03');
  const verbose = {
    text: '안녕하세요 시작하겠습니다',
    segments: [
      { start: 0, text: ' 안녕하세요.' },
      { start: 3.2, text: '  ' },
      { start: 65, text: '예산 얘기부터 하죠.' },
    ],
  };
  assert.equal(transcriptFromResponse(verbose), '[00:00] 안녕하세요.\n[01:05] 예산 얘기부터 하죠.');
  assert.equal(transcriptFromResponse({ text: ' 그냥 글 ' }), '그냥 글');
  assert.equal(transcriptFromResponse('글만 온 응답\n'), '글만 온 응답');
  assert.equal(transcriptFromResponse({}), '');
});

test('요약 부탁 — 회의 정보와 받아쓰기, 너무 길면 앞부분만', () => {
  const p = minutesPrompt({
    roomName: '개발팀',
    startedAt: new Date(2026, 9, 19, 9, 30),
    durationMs: 30 * 60_000,
    participantNames: ['홍길동', '김철수'],
    transcript: '[00:00] 시작합니다.',
  });
  assert.match(p.system, /## 결정 사항/);
  assert.match(p.system, /## 할 일/);
  assert.match(p.user, /회의: 개발팀/);
  assert.match(p.user, /일시: 2026-10-19 09:30 \(30분\)/);
  assert.match(p.user, /참석자: 홍길동, 김철수/);
  assert.match(p.user, /\[00:00\] 시작합니다\./);
  assert.equal(p.clipped, false);
  const long = minutesPrompt({
    roomName: null,
    startedAt: Date.now(),
    durationMs: 0,
    participantNames: [],
    transcript: 'a'.repeat(SUMMARY_TRANSCRIPT_MAX + 10),
  });
  assert.equal(long.clipped, true);
  assert.match(long.user, /…\(이후 생략\)$/);
  assert.match(long.user, /참석자: 알 수 없음/);
});

test('카드에 싣는 녹화 요약·참석자 이름', () => {
  const entry = cardRecordingEntry({
    id: 'r1',
    startedAt: new Date(1000),
    startedBy: 'u1',
    startedByName: '홍길동',
    audioOnly: true,
    status: 'done',
    minutesStatus: 'summarizing',
    messageId: 'm1',
  });
  assert.deepEqual(entry, {
    id: 'r1',
    at: 1000,
    userId: 'u1',
    name: '홍길동',
    audioOnly: true,
    status: 'done',
    minutes: 'summarizing',
    messageId: 'm1',
  });
  assert.equal('messageId' in cardRecordingEntry({ ...entry, startedAt: 0, messageId: null }), false);
  const card = {
    events: [
      { userId: 'a', name: '가', kind: 'start' },
      { userId: 'b', name: '나', kind: 'join' },
      { userId: 'c', name: '다', kind: 'decline' },
      { userId: 'b', name: '나', kind: 'leave' },
      { userId: 'b', name: '나', kind: 'join' },
    ],
  };
  assert.deepEqual(participantNamesFromCard(card), ['가', '나']);
  assert.deepEqual(participantNamesFromCard(null), []);
});

test('통화 상태의 녹화 표시 — 켜면 call:state에 실리고, 통화가 끝나면 사라진다', () => {
  const room = 'room-recording';
  joinCall(room, 'a', 's-a');
  assert.equal('recording' in callStateFor(room), false);
  const info = { id: 'r1', byId: 'a', byName: '가', startedAt: 1, audioOnly: false, minutes: true };
  assert.equal(setCallRecording(room, info), true);
  assert.deepEqual(callStateFor(room).recording, info);
  assert.equal(setCallRecording(room, null), true);
  assert.equal('recording' in callStateFor(room), false);
  setCallRecording(room, info);
  const ended = leaveCall(room, 'a', 's-a');
  assert.equal(ended.active, false);
  assert.equal('recording' in callStateFor(room), false);
  // 통화가 없으면 표시할 곳도 없다.
  assert.equal(setCallRecording(room, info), false);
});
