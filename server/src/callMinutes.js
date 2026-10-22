import fs from 'node:fs/promises';
import path from 'node:path';
import { refreshCallCardRecordings } from './callCards.js';
import { recordingLocalPath, waitForEgress } from './callRecording.js';
import { mergeSpeakerTranscripts, minutesPrompt, transcriptFromResponse } from './callRecordingRules.js';
import {
  ANTHROPIC_API_KEY,
  CALL_SUMMARY_API_KEY,
  CALL_SUMMARY_MODEL,
  CALL_SUMMARY_URL,
  CALL_TRANSCRIBE_API_KEY,
  CALL_TRANSCRIBE_LANGUAGE,
  CALL_TRANSCRIBE_MODEL,
  CALL_TRANSCRIBE_URL,
} from './config.js';
import { findCallRecording, transitionCallMinutes, updateCallRecording } from './db/queries/callRecordings.js';
import { findRoomById } from './db/queries/rooms.js';
import { uploadFileNameOf, uploadsDir } from './upload.js';

/**
 * 자동 회의록 — 녹화를 멈추면(callRecording.js) 그 녹음을 받아쓰고(OpenAI 호환 음성 인식 API) 요약해(OpenAI 호환 채팅 API 또는
 * Claude) call_recordings에 둔다. 앱은 화상회의 카드의 [회의록]으로 보고, 위키에 옮길 수 있다.
 *
 * 둘 다 바깥 서비스라 관리자가 정했을 때만 켜진다(config.js CALL_TRANSCRIBE_URL — 요약은 없어도 받아쓰기는 남는다). 녹음 파일을 그
 * 서비스로 보내므로, 회사 밖으로 내보내기 어려우면 사내에 띄운 받아쓰기·LLM 서버 주소를 적는다(README).
 *
 * 단계: pending → transcribing → summarizing → done | failed. 받아쓴 글은 바로 저장해서, 요약만 실패하면 다시 만들기가 요약부터 한다.
 */

export function minutesEnabled() {
  return deps.transcribeConfigured();
}

/** 요약까지 하는지(요약 서비스가 정해져 있는지). */
export function summaryEnabled() {
  return deps.summaryConfigured();
}

// ── 바깥 서비스 ──

/** 바깥 서비스 응답이 실패일 때의 오류 — 상태와 본문 앞부분을 붙인다(키는 들어가지 않는다). */
async function serviceError(what, res) {
  const body = (await res.text().catch(() => '')).replace(/\s+/g, ' ').slice(0, 200);
  return new Error(`${what} 서비스가 ${res.status}로 거절했습니다${body ? `: ${body}` : ''}`);
}

/** 녹음 [buffer]를 받아쓴다 → 응답(JSON 또는 글). verbose_json(구간별 시각)을 못 하는 서비스면 json으로 한 번 더. */
async function transcribeWithService(buffer, fileName) {
  const send = async (format) => {
    const form = new FormData();
    const type = fileName.endsWith('.mp4')
      ? 'video/mp4'
      : fileName.endsWith('.ogg')
        ? 'audio/ogg'
        : fileName.endsWith('.wav')
          ? 'audio/wav'
          : 'audio/mpeg';
    form.append('file', new Blob([buffer], { type }), fileName);
    form.append('model', CALL_TRANSCRIBE_MODEL);
    if (CALL_TRANSCRIBE_LANGUAGE) form.append('language', CALL_TRANSCRIBE_LANGUAGE);
    form.append('response_format', format);
    return fetch(`${CALL_TRANSCRIBE_URL}/audio/transcriptions`, {
      method: 'POST',
      headers: CALL_TRANSCRIBE_API_KEY ? { Authorization: `Bearer ${CALL_TRANSCRIBE_API_KEY}` } : {},
      body: form,
      signal: AbortSignal.timeout(60 * 60 * 1000),
    });
  };
  let res = await send('verbose_json');
  if (res.status === 400) res = await send('json');
  if (!res.ok) throw await serviceError('받아쓰기', res);
  const type = res.headers.get('content-type') ?? '';
  return type.includes('json') ? res.json() : res.text();
}

/** 회의록 요약 → 마크다운 글. 사내 LLM(OpenAI 호환)이 정해져 있으면 그것, 아니면 Claude. */
async function summarizeWithService({ system, user }) {
  if (CALL_SUMMARY_URL) {
    if (!CALL_SUMMARY_MODEL) throw new Error('요약 모델(CALL_SUMMARY_MODEL)이 정해지지 않았습니다.');
    const res = await fetch(`${CALL_SUMMARY_URL}/chat/completions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(CALL_SUMMARY_API_KEY && { Authorization: `Bearer ${CALL_SUMMARY_API_KEY}` }),
      },
      body: JSON.stringify({
        model: CALL_SUMMARY_MODEL,
        messages: [
          { role: 'system', content: system },
          { role: 'user', content: user },
        ],
      }),
      signal: AbortSignal.timeout(10 * 60 * 1000),
    });
    if (!res.ok) throw await serviceError('요약', res);
    const json = await res.json();
    return String(json?.choices?.[0]?.message?.content ?? '').trim();
  }
  const res = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': ANTHROPIC_API_KEY,
      'anthropic-version': '2023-06-01',
    },
    body: JSON.stringify({
      model: CALL_SUMMARY_MODEL || 'claude-opus-5-5',
      max_tokens: 8000,
      system,
      messages: [{ role: 'user', content: user }],
    }),
    signal: AbortSignal.timeout(10 * 60 * 1000),
  });
  if (!res.ok) throw await serviceError('요약', res);
  const json = await res.json();
  return (json?.content ?? [])
    .filter((b) => b?.type === 'text')
    .map((b) => b.text)
    .join('')
    .trim();
}

/** 소리 한 토막을 받아쓴다(실시간 자막 — callCaptions.js). 회의록과 같은 서비스·설정. */
export function transcribeAudio(buffer, fileName) {
  return deps.transcribe(buffer, fileName);
}

const defaultDeps = {
  transcribeConfigured: () => !!CALL_TRANSCRIBE_URL,
  summaryConfigured: () => !!(CALL_SUMMARY_URL || ANTHROPIC_API_KEY),
  transcribe: transcribeWithService,
  summarize: summarizeWithService,
};
let deps = { ...defaultDeps };

/** 시험용 — 받아쓰기·요약 서비스를 바꿔 끼운다(인자 없이 부르면 원래대로). */
export function setCallMinutesDepsForTest(overrides) {
  deps = overrides ? { ...defaultDeps, ...overrides } : { ...defaultDeps };
}

/** 받아쓸 녹음 파일(이 서버 경로)과 다 쓰고 지울지 — 음성만 녹음이면 대화방에 올린 그 파일(지우지 않음), 영상이면 따로 받은 음성. */
async function audioSourceOf(row) {
  if (row.audioOnly) {
    const name = uploadFileNameOf(row.filePath);
    if (row.status !== 'done' || !name) return null;
    return { localPath: path.join(uploadsDir, name), temporary: false };
  }
  if (!row.minutesFilePath) return null;
  // 회의록용 녹음이 다 써졌는지 — 영상 녹화와 함께 멈췄으므로 보통 이미 끝나 있다.
  const outcome = row.minutesEgressId ? await waitForEgress(row.minutesEgressId) : null;
  const localPath = recordingLocalPath(row.minutesFilePath, outcome?.ok ? outcome.filename : null);
  return localPath ? { localPath, temporary: true } : null;
}

/**
 * 사람마다 따로 받은 음성(speakerTracks — callRecording.js)을 하나씩 받아써 "[03:25] 홍길동: …"으로 합친다 → `{ text, files }`(files는
 * 다 쓰면 지울 파일들). 받아쓸 파일이 하나도 없으면 null — 그때는 섞인 녹음으로 받아쓴다. 한 사람 것이 실패해도 나머지는 하고, 모두
 * 실패하면 그 오류를 던진다.
 */
async function transcribeBySpeaker(row) {
  const tracks = (row.speakerTracks ?? []).filter((t) => t.egressId && t.filePath);
  if (tracks.length === 0) return null;
  const startMs = new Date(row.startedAt).getTime();
  const parts = [];
  const files = [];
  let lastError = null;
  for (const t of tracks) {
    const outcome = await waitForEgress(t.egressId);
    const local = recordingLocalPath(t.filePath, outcome?.ok ? outcome.filename : null);
    if (!local) continue;
    let buffer;
    try {
      buffer = await fs.readFile(local);
    } catch {
      continue;
    }
    files.push(local);
    if (buffer.length === 0) continue;
    try {
      const response = await deps.transcribe(buffer, path.basename(local));
      const begin = outcome?.startedAtMs ?? t.startedAt ?? startMs;
      parts.push({ name: t.name || '알 수 없음', offsetSeconds: Math.max(0, (begin - startMs) / 1000), response });
    } catch (err) {
      lastError = err;
      console.warn('[call] 한 사람의 음성을 받아쓰지 못했습니다:', t.identity, err?.message ?? err);
    }
  }
  if (parts.length === 0) {
    if (lastError) throw lastError;
    return null;
  }
  return { text: mergeSpeakerTranscripts(parts), files };
}

/**
 * 녹화 [id]의 회의록을 만든다 — 'pending'일 때만(다시 만들기는 라우터가 failed → pending으로 바꾼 뒤 부른다). 단계마다 카드를 고친다.
 */
export async function runCallMinutes(io, id) {
  let row = await transitionCallMinutes(id, ['pending'], { minutesStatus: 'transcribing', minutesError: null });
  if (!row) return;
  const card = () => refreshCallCardRecordings(io, row.roomId, row.callMessageId);
  await card();
  const fail = async (message) => {
    console.warn('[call] 회의록을 만들지 못했습니다:', id, message);
    row = (await updateCallRecording(id, { minutesStatus: 'failed', minutesError: message })) ?? row;
    await card();
  };
  try {
    let source = null;
    let speakerFiles = [];
    let transcript = row.transcript;
    if (!transcript) {
      // 사람마다 따로 받은 음성이 있으면 그것으로(누가 말했는지 나뉜다), 없으면 섞인 녹음 하나로.
      const bySpeaker = await transcribeBySpeaker(row);
      if (bySpeaker) {
        transcript = bySpeaker.text;
        speakerFiles = bySpeaker.files;
      } else {
        source = await audioSourceOf(row);
        let buffer = null;
        try {
          if (source) buffer = await fs.readFile(source.localPath);
        } catch {
          buffer = null;
        }
        if (!buffer || buffer.length === 0) return fail('받아쓸 녹음 파일을 찾지 못했습니다.');
        const response = await deps.transcribe(buffer, path.basename(source.localPath));
        transcript = transcriptFromResponse(response);
      }
      if (!transcript) transcript = '(받아쓴 말이 없습니다 — 녹음에 말소리가 없었을 수 있습니다.)';
      row = (await updateCallRecording(id, { transcript })) ?? row;
    }
    let summary = null;
    if (deps.summaryConfigured()) {
      row = (await updateCallRecording(id, { minutesStatus: 'summarizing' })) ?? row;
      await card();
      const room = await findRoomById(row.roomId);
      summary = await deps.summarize(
        minutesPrompt({
          roomName: room?.name ?? null,
          startedAt: row.startedAt,
          durationMs: row.durationMs ?? (row.endedAt ? new Date(row.endedAt) - new Date(row.startedAt) : 0),
          participantNames: row.participantNames ?? [],
          transcript,
        }),
      );
    }
    row = (await updateCallRecording(id, { minutesStatus: 'done', summary: summary || null, minutesError: null })) ?? row;
    // 회의록용으로 따로 받은 음성은 다 썼으니 지운다(영상 녹화가 대화방에 올라가 있다). 실패하면 남겨 두어 다시 만들 수 있게.
    const temporary = source?.temporary ? source.localPath : !row.audioOnly ? recordingLocalPath(row.minutesFilePath) : null;
    if (temporary) await fs.unlink(temporary).catch(() => {});
    // 사람마다 받은 음성도(받아쓴 글이 남았다). 다시 만들기로 받아쓴 글에서 시작했으면 남은 파일을 찾아 지운다.
    const leftovers = speakerFiles.length > 0
      ? speakerFiles
      : (row.speakerTracks ?? []).map((t) => recordingLocalPath(t.filePath)).filter(Boolean);
    for (const f of leftovers) await fs.unlink(f).catch(() => {});
    await card();
  } catch (err) {
    await fail(err?.message ?? String(err));
  }
}
