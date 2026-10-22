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

/** 말한 사람을 나누려고 사람마다 따로 받는 음성(Egress 트랙 녹음 — 마이크 트랙을 옮겨 쓰기만 해서 Opus 그대로 ogg). [n]은 1부터. */
export function speakerTrackFileBase(recordingId, n) {
  return `${recordingId}-spk-${n}.ogg`;
}

/** 한 녹화에서 따로 받는 마이크 트랙 수 상한 — Egress 하나가 트랙마다 일을 하나씩 더 한다. */
export const SPEAKER_TRACKS_MAX = 16;

/**
 * 지금 회의의 마이크 트랙([live] — `[{ identity, name, trackSid }]`) 중 아직 따로 받지 않는 것 — [existing]은 이미 시작한 것
 * (`speakerTracks` 줄, 같은 trackSid는 다시 받지 않는다 — 나갔다 들어오면 트랙이 새로 생겨 그 사람 파일이 하나 더 생긴다). [max]를
 * 넘지 않게 앞에서부터.
 */
export function newSpeakerTracks(existing, live, max = SPEAKER_TRACKS_MAX) {
  const known = new Set(existing.map((t) => t.trackSid));
  const room = Math.max(0, max - existing.length);
  return live.filter((t) => t.trackSid && !known.has(t.trackSid)).slice(0, room);
}

/**
 * 사람마다 받아쓴 구간들 → 한 회의록 글. [parts]는 `[{ name, offsetSeconds, response }]`(response는 받아쓰기 응답 — verbose_json이면
 * segments, 아니면 글 하나를 그 트랙 시작 자리에). 시각 순으로 "[03:25] 홍길동: 말" 한 줄씩. 같은 사람이 이어 말한 짧은 구간도 줄을
 * 나눠 둔다(시각을 잃지 않게). 받아쓴 말이 없으면 ''.
 */
export function mergeSpeakerTranscripts(parts) {
  const lines = [];
  for (const { name, offsetSeconds, response } of parts) {
    const offset = Number(offsetSeconds) || 0;
    if (typeof response === 'string') {
      const text = response.trim();
      if (text) lines.push({ at: offset, name, text });
      continue;
    }
    const segments = Array.isArray(response?.segments) ? response.segments : null;
    if (segments && segments.length > 0) {
      for (const s of segments) {
        const text = String(s.text ?? '').trim();
        if (text) lines.push({ at: offset + (Number(s.start) || 0), name, text });
      }
    } else {
      const text = String(response?.text ?? '').trim();
      if (text) lines.push({ at: offset, name, text });
    }
  }
  lines.sort((a, b) => a.at - b.at);
  return lines.map((l) => `[${clockText(l.at)}] ${l.name}: ${l.text}`).join('\n');
}

const RECORDING_FILE_RE = /^[0-9a-f-]{36}(-minutes|-spk-\d{1,3})?\.(mp4|mp3|ogg)$/;

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
    // 실제로 쓰기 시작한 시각(나노초) — 사람마다 받은 음성을 회의 시각에 맞출 때 쓴다(없으면 null).
    const startedAtNs = file.startedAt ?? info.startedAt;
    const startedAtMs = startedAtNs != null && BigInt(startedAtNs) > 0n ? Number(BigInt(startedAtNs) / 1_000_000n) : null;
    return { done: true, ok: true, filename, size: file.size != null ? Number(file.size) : null, durationMs, startedAtMs };
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

/** 받아쓰기가 사람마다 나뉜 것인지 — 줄 대부분이 "[03:25] 이름: 말" 꼴. */
export function hasSpeakerNames(transcript) {
  const lines = String(transcript ?? '')
    .split('\n')
    .filter((l) => l.trim());
  if (lines.length === 0) return false;
  const named = lines.filter((l) => /^\[\d{1,2}:\d{2}(?::\d{2})?\] [^:\n]{1,40}: /.test(l)).length;
  return named / lines.length >= 0.8;
}

/** 회의록 요약을 부탁하는 글 — `{ system, user }`. 회의 정보(방·일시·길이·참석자)와 받아쓰기를 준다. */
export function minutesPrompt({ roomName, startedAt, durationMs, participantNames, transcript }) {
  const clipped = transcript.length > SUMMARY_TRANSCRIPT_MAX;
  const body = clipped ? `${transcript.slice(0, SUMMARY_TRANSCRIPT_MAX)}\n…(이후 생략)` : transcript;
  const d = new Date(startedAt);
  const two = (n) => String(n).padStart(2, '0');
  const when = `${d.getFullYear()}-${two(d.getMonth() + 1)}-${two(d.getDate())} ${two(d.getHours())}:${two(d.getMinutes())}`;
  // 사람마다 따로 받아쓴 것이면 줄마다 "[03:25] 이름: 말"이다(mergeSpeakerTranscripts).
  const bySpeaker = hasSpeakerNames(transcript);
  const system = [
    '당신은 회사 화상회의의 회의록을 쓰는 비서입니다. 받아쓰기(음성 인식 결과)를 읽고 한국어 회의록을 마크다운으로 씁니다.',
    bySpeaker
      ? '받아쓰기에는 인식 오류가 있을 수 있으니 문맥으로 바로잡되, 없는 내용을 지어내지 마세요. 받아쓰기 줄의 "[시각] 이름:"이 그 말을 한 사람입니다(마이크마다 따로 받아썼습니다) — 결정·할 일의 담당자도 그 이름으로 적습니다.'
      : '받아쓰기에는 인식 오류가 있을 수 있으니 문맥으로 바로잡되, 없는 내용을 지어내지 마세요. 누가 말했는지는 받아쓰기에 없으므로 확실할 때만 적습니다.',
    '다음 제목을 이 순서로 쓰고, 해당 내용이 없으면 "없음"이라고 적습니다:',
    '## 요약 (3~5문장)',
    '## 논의한 내용 (주제별 글머리표)',
    '## 결정 사항 (글머리표)',
    '## 할 일 (글머리표 한 줄에 하나 — "담당자: 할 일 (기한)" 꼴, 기한은 날짜를 알면 YYYY-MM-DD로, 담당자·기한을 모르면 빼고)',
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

/** 녹화 보관 설정의 범위 — 보관 기간(일)·전체 용량(GB). null은 제한 없음. */
export const RECORDING_RETENTION_DAYS_MAX = 3650;
export const RECORDING_MAX_GB_MAX = 100_000;

/**
 * 관리자 콘솔이 보낸 녹화 보관 설정 → 저장할 값 `{ callRecordingRetentionDays?, callRecordingMaxGb? }` 또는 `{ error }`. 넘긴
 * 것만, null·0·''은 제한 없음.
 */
export function parseRecordingRetention(body) {
  const fields = {};
  const read = (key, max, label) => {
    if (!(key in (body ?? {}))) return null;
    const v = body[key];
    if (v === null || v === '' || v === 0) return { value: null };
    const n = Number(v);
    if (!Number.isInteger(n) || n < 1 || n > max) return { error: `${label}은(는) 1~${max} 사이의 정수로 적거나 비워 두세요.` };
    return { value: n };
  };
  const days = read('retentionDays', RECORDING_RETENTION_DAYS_MAX, '보관 기간(일)');
  if (days?.error) return days;
  if (days) fields.callRecordingRetentionDays = days.value;
  const gb = read('maxGb', RECORDING_MAX_GB_MAX, '전체 용량(GB)');
  if (gb?.error) return gb;
  if (gb) fields.callRecordingMaxGb = gb.value;
  if (Object.keys(fields).length === 0) return { error: '바꿀 내용이 없습니다.' };
  return { fields };
}

/**
 * 보관 기간·용량을 넘은 녹화 파일 — [rows]는 아직 지우지 않은 녹화 `{ id, startedAt, fileSize }`(대화방에 올라간 것). 먼저 보관
 * 기간([retentionDays]일)이 지난 것을, 그러고도 남은 것의 합이 [maxBytes]를 넘으면 오래된 것부터 넘지 않을 때까지 고른다.
 * → `[{ id, reason: 'age' | 'size' }]`(오래된 순).
 */
export function planRecordingPurge(rows, { now = Date.now(), retentionDays = null, maxBytes = null } = {}) {
  const sorted = [...rows].sort((a, b) => new Date(a.startedAt) - new Date(b.startedAt));
  const purge = [];
  const kept = [];
  const cutoff = retentionDays ? now - retentionDays * 24 * 60 * 60 * 1000 : null;
  for (const r of sorted) {
    if (cutoff != null && new Date(r.startedAt).getTime() < cutoff) purge.push({ id: r.id, reason: 'age' });
    else kept.push(r);
  }
  if (maxBytes != null) {
    let total = kept.reduce((sum, r) => sum + (Number(r.fileSize) || 0), 0);
    for (const r of kept) {
      if (total <= maxBytes) break;
      purge.push({ id: r.id, reason: 'size' });
      total -= Number(r.fileSize) || 0;
    }
  }
  return purge;
}

/** 회의록 할 일 한 줄의 상한(글자) — 할 일 제목으로 옮길 때 너무 길지 않게. */
export const ACTION_ITEM_MAX = 200;

/**
 * 기한 글 → 'YYYY-MM-DD'(모르면 null). 'YYYY-MM-DD'·'YYYY.MM.DD'·'YYYY/MM/DD'·'M/D'·'M월 D일'을 읽는다 — 해가 없으면 회의한 해로
 * 보고, 그러면 회의보다 두 달 넘게 앞서는 날이면 다음 해로 본다(12월 회의의 "1/10").
 */
export function parseDueDate(text, meetingAt) {
  if (typeof text !== 'string') return null;
  const two = (n) => String(n).padStart(2, '0');
  const valid = (y, m, d) => {
    const date = new Date(Date.UTC(y, m - 1, d));
    return date.getUTCFullYear() === y && date.getUTCMonth() === m - 1 && date.getUTCDate() === d ? `${y}-${two(m)}-${two(d)}` : null;
  };
  const full = text.match(/(\d{4})\s*[-./년]\s*(\d{1,2})\s*[-./월]\s*(\d{1,2})/);
  if (full) return valid(Number(full[1]), Number(full[2]), Number(full[3]));
  const short = text.match(/(?:^|[^\d])(\d{1,2})\s*(?:\/|월\s*)(\d{1,2})(?:\s*일)?(?!\d)/);
  if (!short) return null;
  const base = new Date(meetingAt ?? Date.now());
  const month = Number(short[1]);
  const day = Number(short[2]);
  let year = base.getFullYear();
  if (new Date(year, month - 1, day) < new Date(base.getFullYear(), base.getMonth() - 2, base.getDate())) year += 1;
  return valid(year, month, day);
}

/**
 * 요약(마크다운)의 "## 할 일" 글머리표 → `[{ text, owner, dueText, due }]`(회의록 화면의 "할 일로 만들기" — 앱이 담당자 이름을 방
 * 멤버에서 찾는다). 줄 모양은 요약에 부탁한 "담당자: 할 일 (기한)"이지만 담당자·기한은 없을 수 있다. "없음"뿐이면 빈 목록.
 */
export function actionItemsFromSummary(summary, { meetingAt } = {}) {
  if (typeof summary !== 'string') return [];
  const lines = summary.split(/\r?\n/);
  const start = lines.findIndex((l) => /^#{1,4}\s*할\s*일/.test(l.trim()));
  if (start < 0) return [];
  const items = [];
  for (const raw of lines.slice(start + 1)) {
    const line = raw.trim();
    if (/^#{1,4}\s/.test(line)) break;
    const bullet = line.match(/^(?:[-*•]|\d+[.)])\s+(.+)$/);
    if (!bullet) continue;
    let text = bullet[1].replace(/\*\*|__|`/g, '').replace(/^\[[ xX]\]\s*/, '').trim();
    if (!text || /^없음\.?$/.test(text)) continue;
    let dueText = null;
    const due = text.match(/\s*[(（]([^()（）]*)[)）]\s*$/);
    if (due) {
      dueText = due[1].replace(/^(기한|마감)\s*[:：]?\s*/, '').trim() || null;
      text = text.slice(0, due.index).trim();
    }
    let owner = null;
    // "담당자: 할 일" — 앞쪽이 짧은 이름(두 낱말까지)일 때만 담당자로 본다("다음 회의: 3월에" 같은 글이 담당자가 되지 않게).
    const colon = text.match(/^([^:：]{1,20})\s*[:：]\s*(.+)$/);
    if (colon && colon[1].trim().split(/\s+/).length <= 2 &&!/^(담당자?|미정|없음)$/.test(colon[1].trim())) {
      owner = colon[1].trim();
      text = colon[2].trim();
    } else if (colon && /^(담당자?|미정)$/.test(colon[1].trim())) {
      text = colon[2].trim();
    }
    if (!text) continue;
    items.push({
      text: text.slice(0, ACTION_ITEM_MAX),
      owner,
      dueText,
      due: dueText ? parseDueDate(dueText, meetingAt) : null,
    });
  }
  return items;
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
    // 보관 기간·용량을 넘어 파일을 지웠으면 그 까닭('age' | 'size').
    ...(row.purgedAt && { purged: row.purgeReason ?? 'age' }),
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
