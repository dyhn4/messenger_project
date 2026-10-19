import path from 'node:path';

/**
 * 화상회의 녹화·회의록의 규칙(callRecording.js·callMinutes.js가 쓴다) — DB·LiveKit·바깥 서비스를 모르는 순수 함수라 단위 테스트가 그대로
 * 돌린다(test/callRecording.test.js).
 */

/** 녹화를 시작할 수 없는 이유(문구) — 시작할 수 있으면 null. [call]은 callState.js의 상태. */
export function recordingStartDenial({ enabled, call, userId, recording, minutesWanted, minutesEnabled }) {
  if (!enabled) return '이 서버에는 화상회의 녹화가 설정되어 있지 않습니다.';
  if (!call?.active) return '진행 중인 화상회의가 없습니다.';
  if (!call.participantIds.includes(userId)) return '화상회의에 들어와 있을 때만 녹화할 수 있습니다.';
  if (call.hostId !== userId) return '진행자만 녹화를 시작할 수 있습니다.';
  if (recording) return '이미 녹화하고 있습니다.';
  if (minutesWanted && !minutesEnabled) return '이 서버에는 회의록(받아쓰기)이 설정되어 있지 않습니다.';
  return null;
}

/** 녹화를 멈출 수 없는 이유 — 진행자나 녹화를 시작한 사람만. 멈출 수 있으면 null. */
export function recordingStopDenial({ recording, call, userId }) {
  if (!recording) return '녹화하고 있지 않습니다.';
  if (recording.startedBy === userId) return null;
  if (call?.active && call.hostId === userId) return null;
  return '녹화를 시작한 사람이나 진행자만 녹화를 멈출 수 있습니다.';
}

/** 녹화 파일 이름(Egress에 시킬 것) — 녹화 줄 id로 만들어 겹치지 않는다. [purpose] 'minutes'는 받아쓰기용 음성. */
export function recordingFileBase(recordingId, { audioOnly, purpose = 'main' }) {
  return `${recordingId}${purpose === 'minutes' ? '-minutes' : ''}.${audioOnly ? 'mp3' : 'mp4'}`;
}

/** Egress 컨테이너 안에서 본 경로 — 늘 슬래시(리눅스 컨테이너). */
export function egressPathFor(egressDir, base) {
  return `${egressDir.replace(/[\\/]+$/, '')}/${base}`;
}

const RECORDING_FILE_RE = /^[0-9a-f-]{36}(-minutes)?\.(mp4|mp3)$/;

/**
 * Egress가 알려 준 파일 경로(컨테이너 안) → 이 서버에서 읽을 경로. 이름만 떼어 [localDir]에 붙인다 — Egress가 무슨 경로를 돌려주든
 * 녹화 폴더 밖의 파일을 옮기지 않게, 우리가 시킨 모양의 이름(녹화 줄 id)이 아니면 null.
 */
export function localRecordingPath(egressFilename, localDir) {
  if (typeof egressFilename !== 'string' || !localDir) return null;
  const base = egressFilename.split(/[\\/]/).pop();
  if (!base || !RECORDING_FILE_RE.test(base)) return null;
  return path.join(localDir, base);
}

/** 대화방에 올릴 녹화 파일의 이름 — "화상회의 녹화 2026-10-19 14.30.mp4"(서버 시각). */
export function recordingDisplayName(startedAt, { audioOnly }) {
  const d = new Date(startedAt);
  const two = (n) => String(n).padStart(2, '0');
  const stamp = `${d.getFullYear()}-${two(d.getMonth() + 1)}-${two(d.getDate())} ${two(d.getHours())}.${two(d.getMinutes())}`;
  return `화상회의 ${audioOnly ? '녹음' : '녹화'} ${stamp}.${audioOnly ? 'mp3' : 'mp4'}`;
}

/** 길이 "12초" / "5분" / "1시간 3분". */
export function durationText(ms) {
  const seconds = Math.max(0, Math.round((ms ?? 0) / 1000));
  if (seconds < 60) return `${seconds}초`;
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes}분`;
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return m === 0 ? `${h}시간` : `${h}시간 ${m}분`;
}

/** 녹화 파일 메시지의 글 — "화상회의 녹화 · 12분". */
export function recordingMessageText({ audioOnly, durationMs }) {
  return `화상회의 ${audioOnly ? '녹음' : '녹화'}${durationMs ? ` · ${durationText(durationMs)}` : ''}`;
}

/** LiveKit EgressStatus 번호(@livekit/protocol) — SDK를 불러오지 않고 비교한다. */
export const EGRESS_STATUS = { STARTING: 0, ACTIVE: 1, ENDING: 2, COMPLETE: 3, FAILED: 4, ABORTED: 5, LIMIT_REACHED: 6 };

/**
 * Egress 상태 → 기다릴지·결과. `{ done: false }`(아직 쓰는 중) 또는 `{ done: true, ok, filename?, size?, durationMs?, error? }`.
 * 최대 길이에 걸려 멈춘 것(LIMIT_REACHED)도 그때까지의 파일은 있다.
 */
export function egressOutcome(info) {
  const status = Number(info?.status);
  if (![EGRESS_STATUS.COMPLETE, EGRESS_STATUS.FAILED, EGRESS_STATUS.ABORTED, EGRESS_STATUS.LIMIT_REACHED].includes(status)) {
    return { done: false };
  }
  const file = info.fileResults?.[0] ?? info.file ?? null;
  const filename = file?.filename || file?.location || null;
  if ((status === EGRESS_STATUS.COMPLETE || status === EGRESS_STATUS.LIMIT_REACHED) && filename) {
    // duration은 나노초(bigint) — 밀리초로.
    const durationMs = file.duration != null ? Number(BigInt(file.duration) / 1_000_000n) : null;
    return { done: true, ok: true, filename, size: file.size != null ? Number(file.size) : null, durationMs };
  }
  return { done: true, ok: false, error: info.error || (status === EGRESS_STATUS.ABORTED ? '녹화가 중단되었습니다.' : '녹화에 실패했습니다.') };
}

/** 받아쓰기 시각 "03:25" / "1:02:03". */
export function clockText(seconds) {
  const s = Math.max(0, Math.floor(seconds));
  const two = (n) => String(n).padStart(2, '0');
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  return h > 0 ? `${h}:${two(m)}:${two(s % 60)}` : `${two(m)}:${two(s % 60)}`;
}

/**
 * 받아쓰기 응답(OpenAI 호환 — verbose_json이면 segments, 아니면 text) → 회의록에 둘 글. 구간마다 "[03:25] 말" 한 줄. 빈 결과면 ''.
 */
export function transcriptFromResponse(json) {
  if (typeof json === 'string') return json.trim();
  const segments = Array.isArray(json?.segments) ? json.segments : null;
  if (segments && segments.length > 0) {
    return segments
      .map((s) => ({ at: Number(s.start) || 0, text: String(s.text ?? '').trim() }))
      .filter((s) => s.text)
      .map((s) => `[${clockText(s.at)}] ${s.text}`)
      .join('\n');
  }
  return String(json?.text ?? '').trim();
}

/** 요약에 넘기는 받아쓰기 글 상한(글자) — 넘으면 앞부분만 넘기고 잘랐다고 적는다(긴 회의라도 요청 하나가 너무 커지지 않게). */
export const SUMMARY_TRANSCRIPT_MAX = 150_000;

/** 회의록 요약을 부탁하는 글 — `{ system, user }`. 회의 정보(방·일시·길이·참석자)와 받아쓰기를 준다. */
export function minutesPrompt({ roomName, startedAt, durationMs, participantNames, transcript }) {
  const clipped = transcript.length > SUMMARY_TRANSCRIPT_MAX;
  const body = clipped ? `${transcript.slice(0, SUMMARY_TRANSCRIPT_MAX)}\n…(이후 생략)` : transcript;
  const d = new Date(startedAt);
  const two = (n) => String(n).padStart(2, '0');
  const when = `${d.getFullYear()}-${two(d.getMonth() + 1)}-${two(d.getDate())} ${two(d.getHours())}:${two(d.getMinutes())}`;
  const system = [
    '당신은 회사 화상회의의 회의록을 쓰는 비서입니다. 받아쓰기(음성 인식 결과)를 읽고 한국어 회의록을 마크다운으로 씁니다.',
    '받아쓰기에는 인식 오류가 있을 수 있으니 문맥으로 바로잡되, 없는 내용을 지어내지 마세요. 누가 말했는지는 받아쓰기에 없으므로 확실할 때만 적습니다.',
    '다음 제목을 이 순서로 쓰고, 해당 내용이 없으면 "없음"이라고 적습니다:',
    '## 요약 (3~5문장)',
    '## 논의한 내용 (주제별 글머리표)',
    '## 결정 사항 (글머리표)',
    '## 할 일 (글머리표 — "담당자: 할 일 (기한)" 꼴, 담당자·기한을 모르면 빼고)',
    '회의록 본문만 쓰고 앞뒤 인사말은 쓰지 마세요.',
  ].join('\n');
  const user = [
    `회의: ${roomName || '화상회의'}`,
    `일시: ${when} (${durationText(durationMs)})`,
    `참석자: ${participantNames.length > 0 ? participantNames.join(', ') : '알 수 없음'}`,
    '',
    '받아쓰기:',
    body,
  ].join('\n');
  return { system, user, clipped };
}

/** 화상회의 카드(messages.call_card)에 싣는 녹화 요약 — 카드에는 짧은 상태만, 받아쓰기·요약은 GET /call-recordings/:id로. */
export function cardRecordingEntry(row) {
  return {
    id: row.id,
    at: new Date(row.startedAt).getTime(),
    userId: row.startedBy,
    name: row.startedByName,
    audioOnly: row.audioOnly,
    status: row.status,
    minutes: row.minutesStatus,
    ...(row.messageId && { messageId: row.messageId }),
  };
}

/** 카드 하나에 싣는 녹화 수 상한 — 한 통화에서 녹화를 계속 껐다 켜도 카드가 끝없이 커지지 않게(그 뒤 녹화는 파일만 올라간다). */
export const CALL_CARD_MAX_RECORDINGS = 20;

/** 화상회의 카드에서 함께한 사람 이름(시작·참여, 같은 사람은 한 번) — 요약에 참석자로 알려 준다. */
export function participantNamesFromCard(card) {
  const seen = new Map();
  for (const e of card?.events ?? []) {
    if ((e.kind === 'start' || e.kind === 'join') && e.userId && !seen.has(e.userId)) seen.set(e.userId, e.name);
  }
  return [...seen.values()];
}
