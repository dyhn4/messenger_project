import { randomUUID } from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { Router } from 'express';
import { DirectFileOutput, EgressClient, EncodedFileOutput, EncodedFileType, EncodingOptions } from 'livekit-server-sdk';
import { topicAccess } from './access.js';
import { callCardParticipantNames, liveCallCardMessageId, refreshCallCardRecordings } from './callCards.js';
import { isRestrictedTopic } from './callAccess.js';
import { minutesEnabled, runCallMinutes } from './callMinutes.js';
import {
  actionItemsFromSummary,
  egressOutcome,
  egressPathFor,
  localRecordingPath,
  recordingDisplayName,
  recordingFileBase,
  recordingMessageText,
  recordingStartDenial,
  recordingStopDenial,
  newSpeakerTracks,
  speakerTrackFileBase,
} from './callRecordingRules.js';
import { livekitRoomService } from './calls.js';
import { callStateFor, setCallRecording } from './callState.js';
import {
  CALL_RECORDING_DIR,
  CALL_RECORDING_EGRESS_DIR,
  CALL_RECORDING_MAX_MINUTES,
  CALL_MINUTES_SPEAKERS,
  LIVEKIT_API_KEY,
  LIVEKIT_API_SECRET,
  LIVEKIT_PORT,
  LIVEKIT_URL,
} from './config.js';
import {
  findCallRecording,
  findLatestCallCardMessage,
  insertCallRecording,
  listUnfinishedCallRecordings,
  transitionCallMinutes,
  transitionCallRecording,
  updateCallRecording,
} from './db/queries/callRecordings.js';
import { findRoomById, isRoomMember } from './db/queries/rooms.js';
import { insertUpload } from './db/queries/uploads.js';
import { findUserById } from './db/queries/users.js';
import { topicWriteDenial } from './permissions.js';
import { sendUserMessage } from './sendMessage.js';
import { uploadsDir, uploadsDirHasRoom } from './upload.js';

/**
 * 화상회의 녹화(LiveKit Egress). 진행자가 통화 화면의 [녹화]를 누르면 LiveKit Egress에 그 회의방 전체(RoomComposite — 말하는 사람이
 * 크게, 화면 공유는 공유 화면이 크게)를 파일로 쓰게 하고, 멈추면(또는 통화가 끝나면 — callCards.js postCallLeft) Egress가 파일을
 * 마무리할 때까지 기다렸다가 그 파일을 업로드 폴더로 옮겨 **녹화를 시작한 사람 이름으로 대화방에 파일 메시지**로 올린다. 음성만
 * 녹음(mp3)할 수도 있고, 회의록을 원하면 녹음을 받아쓰고 요약한다(callMinutes.js — 영상 녹화면 받아쓰기용 음성 녹음을 하나 더 돌린다).
 *
 * Egress는 Docker 전용(+Redis)이라 설치 프로그램에 넣지 못한다 — 관리자가 따로 띄우고 녹화 폴더를 이 서버와 같이 쓰게 한 뒤
 * CALL_RECORDING_DIR을 적어야 켜진다(README "화상회의 녹화·회의록"). Egress는 LiveKit에 숨은 참가자로 붙어서 앱의 참가자 목록에는
 * 보이지 않는다 — 그래서 녹화 중에는 모두의 통화 화면에 "녹화 중" 표시를 띄운다(call:state의 recording).
 *
 * 진행 상태는 DB(call_recordings)에 둔다 — 마무리에 몇 분 걸릴 수 있고, 그 사이 서버가 다시 시작돼도 이어서 끝낸다(resumeCallRecordings).
 */

export function recordingEnabled() {
  return !!(LIVEKIT_API_SECRET && CALL_RECORDING_DIR);
}

// ── 바깥(Egress·파일·시간) — 시험이 바꿔 끼운다 ──

function livekitEgress() {
  const client = new EgressClient(LIVEKIT_URL || `http://127.0.0.1:${LIVEKIT_PORT}`, LIVEKIT_API_KEY, LIVEKIT_API_SECRET, {
    requestTimeout: 15,
  });
  return {
    /** 회의방 전체를 [filepath](Egress 쪽 경로)에 녹화하기 시작한다 → { egressId }. */
    async start(roomName, filepath, { audioOnly }) {
      const file = new EncodedFileOutput({ fileType: audioOnly ? EncodedFileType.MP3 : EncodedFileType.MP4, filepath });
      const info = await client.startRoomCompositeEgress(roomName, { file }, {
        layout: 'speaker',
        audioOnly,
        // 음성만은 받아쓰기 서비스의 파일 크기 상한(OpenAI 25MB)에 오래 들어가게 32kbps(한 시간에 약 14MB).
        ...(audioOnly && { encodingOptions: new EncodingOptions({ audioBitrate: 32 }) }),
      });
      return { egressId: info.egressId };
    },
    /**
     * 참가자 트랙 하나를 옮겨 쓴다(트랙 녹음) — [target]이 'ws'로 시작하면 그 웹소켓으로 소리(PCM)를 흘려보내고(실시간 자막 —
     * callCaptions.js), 아니면 그 경로(Egress 쪽)에 파일로(마이크는 Opus 그대로 ogg — 말한 사람 나누기). → { egressId }.
     */
    async startTrack(roomName, trackSid, target) {
      const output = /^wss?:\/\//.test(target) ? target : new DirectFileOutput({ filepath: target });
      const info = await client.startTrackEgress(roomName, output, trackSid);
      return { egressId: info.egressId };
    },
    async stop(egressId) {
      await client.stopEgress(egressId);
    },
    /** 녹화 하나의 지금 상태(EgressInfo) — 없으면 null. */
    async info(egressId) {
      const list = await client.listEgress({ egressId });
      return list[0] ?? null;
    },
  };
}

/** 지금 회의의 마이크 트랙들 — `[{ identity, name, trackSid }]`(Egress 같은 숨은 참가자는 트랙이 없다). LiveKit이 없으면 빈 목록. */
export async function listMicTracks(roomId) {
  const livekit = livekitRoomService();
  if (!livekit) return [];
  const out = [];
  for (const p of await livekit.listParticipants(roomId)) {
    for (const t of p.tracks ?? []) {
      // TrackType.AUDIO = 0, TrackSource.MICROPHONE = 2(@livekit/protocol).
      if (Number(t.type) === 0 && Number(t.source) === 2 && t.sid) {
        out.push({ identity: p.identity, name: p.name || p.identity, trackSid: t.sid });
      }
    }
  }
  return out;
}

const defaultDeps = {
  egress: null,
  // 말한 사람 나누기 — 회의록을 원한 녹화에서 마이크 트랙을 사람마다 따로 녹음한다(새로 들어온 사람은 [speakerPollMs]마다 살펴 더한다).
  speakersEnabled: () => CALL_MINUTES_SPEAKERS,
  micTracks: listMicTracks,
  speakerPollMs: 8000,
  sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms).unref?.()),
  pollMs: 3000,
  // Egress가 파일을 마무리했다고 알려 줄 때까지 기다리는 최대 시간 — 긴 녹화도 보통 몇 초 안에 끝난다.
  waitMs: 30 * 60 * 1000,
  recordingDir: () => CALL_RECORDING_DIR,
  egressDir: () => CALL_RECORDING_EGRESS_DIR,
  enabled: recordingEnabled,
};
let deps = { ...defaultDeps };

/** 시험용 — Egress·녹화 폴더·기다리는 시간을 바꿔 끼운다(인자 없이 부르면 원래대로). */
export function setCallRecordingDepsForTest(overrides) {
  deps = overrides ? { ...defaultDeps, ...overrides } : { ...defaultDeps };
  active.clear();
  starting.clear();
  startTimes.clear();
}

function egress() {
  deps.egress ??= livekitEgress();
  return deps.egress;
}

/** 녹화와 같은 Egress 연결 — 실시간 자막(callCaptions.js)이 마이크 트랙을 웹소켓으로 흘려보낼 때도 쓴다(시험이 바꿔 끼운 것 그대로). */
export function recordingEgress() {
  return egress();
}

// ── 지금 녹화 중인 것(방마다 하나) ──

/** roomId → { id, startedBy, startedAt, audioOnly, minutes, callMessageId, timer } — 녹화 중인 것. 진짜 기록은 DB. */
const active = new Map();
/** 시작 요청을 처리 중인 방 — 두 번 눌러 녹화가 둘 생기지 않게. */
const starting = new Set();
/** roomId → 최근 시작 시각들 — 시작·멈춤을 되풀이해 Egress를 계속 띄우지 못하게(10분에 10번). */
const startTimes = new Map();
const START_WINDOW_MS = 10 * 60 * 1000;
const START_MAX = 10;

function startWait(roomId, now = Date.now()) {
  const recent = (startTimes.get(roomId) ?? []).filter((t) => now - t < START_WINDOW_MS);
  startTimes.set(roomId, recent);
  return recent.length >= START_MAX ? recent[0] + START_WINDOW_MS - now : 0;
}

/** 지금 이 방에서 녹화 중인 것(없으면 null). */
export function activeRecordingFor(roomId) {
  return active.get(roomId) ?? null;
}

function recordingStateOf(rec) {
  return {
    id: rec.id,
    byId: rec.startedBy,
    byName: rec.startedByName,
    startedAt: rec.startedAt,
    audioOnly: rec.audioOnly,
    minutes: rec.minutes,
  };
}

function emitCallState(io, roomId) {
  const state = callStateFor(roomId);
  if (state.active) io.to(roomId).emit('call:state', state);
}

/**
 * 녹화를 시작한다(진행자만 — callRecordingRules.js recordingStartDenial). `{ ok: true, recording }` 또는 `{ ok: false, status, error }`.
 * [audioOnly]면 음성만(mp3), [minutes]면 끝난 뒤 회의록을 만든다.
 */
export async function startCallRecording({ io, room, userId, audioOnly = false, minutes = false }) {
  const call = callStateFor(room.id);
  const denial = recordingStartDenial({
    enabled: deps.enabled(),
    call,
    userId,
    recording: active.has(room.id) || starting.has(room.id),
    minutesWanted: minutes,
    minutesEnabled: minutesEnabled(),
  });
  if (denial) return { ok: false, status: denial.includes('설정되어') ? 503 : 409, error: denial };
  // 읽기 전용·보관된 토픽은 녹화 파일을 올릴 수 있는 사람(토픽 관리자)만.
  if (isRestrictedTopic(room)) {
    const writeDenial = topicWriteDenial({ room, canManage: (await topicAccess(room, userId)).canManage });
    if (writeDenial) return { ok: false, status: 403, error: '읽기 전용 토픽에서는 토픽 관리자만 녹화할 수 있습니다.' };
  }
  const wait = startWait(room.id);
  if (wait > 0) {
    return { ok: false, status: 429, error: `녹화를 너무 자주 시작했습니다. ${Math.ceil(wait / 60000)}분 후 다시 시도하세요.` };
  }
  starting.add(room.id);
  try {
    const user = await findUserById(userId);
    const callMessageId = liveCallCardMessageId(room.id) ?? (await findLatestCallCardMessage(room.id));
    const row = await insertCallRecording({
      roomId: room.id,
      callMessageId,
      startedBy: userId,
      startedByName: user?.name ?? user?.username ?? '알 수 없음',
      audioOnly,
      status: 'recording',
      minutesStatus: minutes ? 'pending' : 'none',
    });
    startTimes.get(room.id)?.push(Date.now()) ?? startTimes.set(room.id, [Date.now()]);
    const mainPath = egressPathFor(deps.egressDir(), recordingFileBase(row.id, { audioOnly }));
    let egressId;
    try {
      ({ egressId } = await egress().start(room.id, mainPath, { audioOnly }));
    } catch (err) {
      console.error('[call] 녹화를 시작하지 못했습니다(Egress):', err?.message ?? err);
      await updateCallRecording(row.id, {
        status: 'failed',
        error: '녹화 서버(Egress)가 녹화를 시작하지 못했습니다.',
        endedAt: new Date(),
        minutesStatus: 'none',
      });
      await refreshCallCardRecordings(io, room.id, callMessageId);
      return { ok: false, status: 502, error: '녹화를 시작하지 못했습니다. 녹화 서버(Egress)가 켜져 있는지 관리자에게 확인해 주세요.' };
    }
    // 영상 녹화에 회의록까지 — 받아쓰기는 음성 파일로 하므로 음성 녹음을 하나 더(영상 파일은 크고 받아쓰기 서비스가 못 받을 수 있다).
    let minutesEgressId = null;
    let minutesFilePath = null;
    let minutesStatus = minutes ? 'pending' : 'none';
    let minutesError = null;
    if (minutes && !audioOnly) {
      const audioPath = egressPathFor(deps.egressDir(), recordingFileBase(row.id, { audioOnly: true, purpose: 'minutes' }));
      try {
        ({ egressId: minutesEgressId } = await egress().start(room.id, audioPath, { audioOnly: true }));
        minutesFilePath = audioPath;
      } catch (err) {
        console.error('[call] 회의록용 녹음을 시작하지 못했습니다(Egress):', err?.message ?? err);
        minutesStatus = 'failed';
        minutesError = '회의록용 녹음을 시작하지 못했습니다(영상 녹화는 계속합니다).';
      }
    }
    const saved = await updateCallRecording(row.id, {
      egressId,
      filePath: mainPath,
      minutesEgressId,
      minutesFilePath,
      minutesStatus,
      minutesError,
    });
    const rec = {
      id: row.id,
      startedBy: userId,
      startedByName: row.startedByName,
      startedAt: new Date(row.startedAt).getTime(),
      audioOnly,
      minutes: minutesStatus !== 'none' && minutesStatus !== 'failed',
      callMessageId,
      timer: setTimeout(() => {
        stopCallRecording({ io, roomId: room.id, reason: 'limit' }).catch((err) =>
          console.error('[call] 최대 길이가 된 녹화를 멈추지 못했습니다:', err?.message ?? err),
        );
      }, CALL_RECORDING_MAX_MINUTES * 60 * 1000),
    };
    rec.timer.unref?.();
    active.set(room.id, rec);
    if (rec.minutes && deps.speakersEnabled()) startSpeakerTracking(rec, room.id);
    // 그사이 통화가 끝났으면(모두 나감) 바로 멈춘다 — 통화 상태가 없어 "녹화 중"을 실을 곳도 없다.
    if (!setCallRecording(room.id, recordingStateOf(rec))) {
      await stopCallRecording({ io, roomId: room.id, reason: 'call-ended' });
      return { ok: false, status: 409, error: '진행 중인 화상회의가 없습니다.' };
    }
    emitCallState(io, room.id);
    await refreshCallCardRecordings(io, room.id, callMessageId);
    return { ok: true, recording: recordingDto(saved ?? row) };
  } finally {
    starting.delete(room.id);
  }
}

/**
 * 회의록을 원한 녹화에서 마이크 트랙을 사람마다 따로 녹음하기 시작한다(말한 사람 나누기 — callMinutes.js가 사람마다 받아써 합친다).
 * 지금 있는 사람 것을 바로, 그 뒤 들어오는 사람 것은 [deps.speakerPollMs]마다 살펴 더한다. 시작하지 못한 트랙도 적어 두어 같은
 * 트랙을 계속 다시 시도하지 않는다. 다 받지 못해도 섞인 녹음은 그대로라 회의록은 만들어진다.
 */
function startSpeakerTracking(rec, roomId) {
  rec.speakerTracks = [];
  const sync = async () => {
    if (rec.syncingSpeakers || active.get(roomId) !== rec) return;
    rec.syncingSpeakers = true;
    try {
      const fresh = newSpeakerTracks(rec.speakerTracks, await deps.micTracks(roomId));
      for (const t of fresh) {
        const filePath = egressPathFor(deps.egressDir(), speakerTrackFileBase(rec.id, rec.speakerTracks.length + 1));
        const entry = { egressId: null, identity: t.identity, name: t.name, trackSid: t.trackSid, filePath, startedAt: Date.now() };
        try {
          ({ egressId: entry.egressId } = await egress().startTrack(roomId, t.trackSid, filePath));
        } catch (err) {
          console.warn('[call] 사람마다 따로 녹음하지 못했습니다(Egress 트랙 녹음):', t.identity, err?.message ?? err);
          entry.filePath = null;
        }
        rec.speakerTracks.push(entry);
      }
      if (fresh.length > 0 && active.get(roomId) === rec) {
        await updateCallRecording(rec.id, { speakerTracks: rec.speakerTracks });
      }
    } catch (err) {
      console.warn('[call] 회의 참가자의 마이크를 살피지 못했습니다:', err?.message ?? err);
    } finally {
      rec.syncingSpeakers = false;
    }
  };
  rec.speakerTimer = setInterval(() => void sync(), deps.speakerPollMs);
  rec.speakerTimer.unref?.();
  void sync();
}

/**
 * 녹화를 멈춘다. [userId]가 있으면 사람이 누른 것(진행자·시작한 사람만), 없으면 서버가(통화 끝·최대 길이). 멈춘 뒤 파일 마무리는
 * 뒤에서 이어 간다(finalizeCallRecording). `{ ok: true }` 또는 `{ ok: false, status, error }`.
 */
export async function stopCallRecording({ io, roomId, userId = null, reason = 'user' }) {
  const rec = active.get(roomId);
  if (userId) {
    const denial = recordingStopDenial({ recording: rec, call: callStateFor(roomId), userId });
    if (denial) return { ok: false, status: rec ? 403 : 409, error: denial };
  }
  if (!rec) return { ok: true };
  active.delete(roomId);
  clearTimeout(rec.timer);
  clearInterval(rec.speakerTimer);
  setCallRecording(roomId, null);
  emitCallState(io, roomId);
  const participantNames = await callCardParticipantNames(roomId, rec.callMessageId).catch(() => []);
  const row = await transitionCallRecording(rec.id, 'recording', {
    status: 'processing',
    endedAt: new Date(),
    participantNames,
    ...(rec.speakerTracks && { speakerTracks: rec.speakerTracks }),
  });
  if (!row) return { ok: true };
  if (reason === 'limit') console.log(`[call] 녹화가 최대 길이(${CALL_RECORDING_MAX_MINUTES}분)가 되어 멈췄습니다:`, roomId);
  await stopEgresses(row);
  await refreshCallCardRecordings(io, roomId, row.callMessageId);
  finalizeCallRecording(io, row.id).catch((err) => console.error('[call] 녹화 마무리 실패:', err?.message ?? err));
  return { ok: true };
}

async function stopEgresses(row) {
  const speakers = (row.speakerTracks ?? []).map((t) => t.egressId);
  for (const id of [row.egressId, row.minutesEgressId, ...speakers]) {
    if (!id) continue;
    await egress()
      .stop(id)
      .catch((err) => console.warn('[call] Egress 녹화 멈추기 실패(이미 끝났을 수 있음):', id, err?.message ?? err));
  }
}

/**
 * Egress 녹화 하나가 끝날 때까지 기다린다 → egressOutcome 결과. 답이 끝내 없으면 실패로 — 단 호출부는 파일이 이미 있으면 그걸 쓴다.
 */
export async function waitForEgress(egressId) {
  const deadline = Date.now() + deps.waitMs;
  for (;;) {
    try {
      const info = await egress().info(egressId);
      if (info) {
        const outcome = egressOutcome(info);
        if (outcome.done) return outcome;
      }
    } catch (err) {
      console.warn('[call] Egress 상태 확인 실패(다시 봅니다):', err?.message ?? err);
    }
    if (Date.now() >= deadline) {
      return { done: true, ok: false, timedOut: true, error: '녹화 서버(Egress)가 파일을 마무리했다는 답을 주지 않았습니다.' };
    }
    await deps.sleep(deps.pollMs);
  }
}

/** [egressPath]로 시킨 녹화 파일을 이 서버에서 읽을 경로 — Egress가 알려 준 이름이 있으면 그것으로. */
export function recordingLocalPath(egressPath, reported) {
  return localRecordingPath(reported ?? egressPath, deps.recordingDir());
}

async function exists(p) {
  try {
    return (await fs.stat(p)).size > 0;
  } catch {
    return false;
  }
}

/** 녹화 폴더의 파일을 업로드 폴더로 옮긴다(다른 디스크면 복사 뒤 지운다) → 저장 이름. */
async function moveIntoUploads(localPath, ext) {
  const fileName = `${randomUUID()}.${ext}`;
  const target = path.join(uploadsDir, fileName);
  try {
    await fs.rename(localPath, target);
  } catch (err) {
    if (err?.code !== 'EXDEV' && err?.code !== 'EPERM') throw err;
    await fs.copyFile(localPath, target);
    await fs.unlink(localPath).catch(() => {});
  }
  return fileName;
}

/**
 * 멈춘 녹화를 마무리한다 — Egress가 파일을 다 쓰면 업로드 폴더로 옮겨 대화방에 파일 메시지로 올리고, 회의록을 원했으면 만든다.
 * 'processing'인 줄만 한다(서버가 켜질 때 이어서 부를 수도 있다).
 */
export async function finalizeCallRecording(io, id) {
  let row = await findCallRecording(id);
  if (!row || row.status !== 'processing') return;
  const outcome = row.egressId ? await waitForEgress(row.egressId) : { done: true, ok: false, error: '녹화가 시작되지 않았습니다.' };
  const local = recordingLocalPath(row.filePath, outcome.ok ? outcome.filename : null);
  const fileThere = local ? await exists(local) : false;
  if (!fileThere) {
    row = await transitionCallRecording(id, 'processing', {
      status: 'failed',
      error: outcome.ok ? '녹화 파일을 찾지 못했습니다. 녹화 폴더 설정(CALL_RECORDING_DIR)을 확인해 주세요.' : outcome.error,
    });
    if (!outcome.ok || !local) console.error('[call] 녹화 실패:', id, outcome.error ?? '파일 경로를 알 수 없음');
    else console.error('[call] 녹화 파일이 녹화 폴더에 없습니다:', local);
  } else {
    row = await publishRecording(io, row, local, outcome);
  }
  if (!row) return;
  await refreshCallCardRecordings(io, row.roomId, row.callMessageId);
  if (row.minutesStatus === 'pending') await runCallMinutes(io, row.id);
}

/** 녹화 파일을 업로드 폴더로 옮기고 대화방에 올린다 → 고친 줄. 올리지 못해도 파일은 남기고 이유를 적는다. */
async function publishRecording(io, row, local, outcome) {
  const audioOnly = row.audioOnly;
  const size = (await fs.stat(local)).size;
  if (!(await uploadsDirHasRoom(size))) {
    return transitionCallRecording(row.id, 'processing', {
      status: 'failed',
      error: '서버 저장 공간이 부족해 녹화 파일을 옮기지 못했습니다(녹화 폴더에 남아 있습니다).',
    });
  }
  const fileName = await moveIntoUploads(local, audioOnly ? 'mp3' : 'mp4');
  if (row.startedBy) await insertUpload({ fileName, uploaderId: row.startedBy });
  const fileUrl = `/uploads/${fileName}`;
  const durationMs = outcome.durationMs ?? (row.endedAt ? new Date(row.endedAt) - new Date(row.startedAt) : null);
  const displayName = recordingDisplayName(row.startedAt, { audioOnly });
  const mimeType = audioOnly ? 'audio/mpeg' : 'video/mp4';
  const text = recordingMessageText({ audioOnly, durationMs });
  let messageId = null;
  let error = null;
  const room = await findRoomById(row.roomId);
  if (!room) {
    error = '대화방이 없어 녹화 파일을 올리지 못했습니다.';
  } else if (!row.startedBy) {
    error = '녹화를 시작한 사람의 계정이 없어 대화방에 올리지 못했습니다.';
  } else {
    // 보드 뷰 토픽은 게시글만 받으므로 게시글로 올린다.
    const board = room.type === 'topic' && room.viewMode === 'board';
    const file = { fileUrl, fileName: displayName, fileSize: size, mimeType };
    const payload = board
      ? { roomId: room.id, type: 'post', title: text, text, attachments: [{ kind: 'file', ...file }] }
      : { roomId: room.id, type: 'file', text, ...file };
    const sent = await sendUserMessage({ io, senderId: row.startedBy, payload, room, fileSource: 'server' });
    if (sent.ok) messageId = sent.message.id;
    else error = `녹화 파일을 대화방에 올리지 못했습니다: ${sent.error}`;
  }
  if (error) console.warn('[call]', error, row.id);
  const done = await transitionCallRecording(row.id, 'processing', {
    status: 'done',
    filePath: fileUrl,
    fileSize: size,
    durationMs: durationMs != null ? Math.round(durationMs) : null,
    messageId,
    error,
  });
  // 새 파일로 녹화 전체 용량을 넘었을 수 있다 — 오래된 녹화 파일부터 지운다(설정이 있을 때만, callRecordingRetention.js).
  import('./callRecordingRetention.js')
    .then((m) => m.purgeCallRecordings(io))
    .catch((err) => console.error('[call] 녹화 보관 정리 실패:', err?.message ?? err));
  return done;
}

/**
 * 서버가 켜질 때 — 지난번 실행 중에 끝내지 못한 녹화를 이어서 마무리한다. 녹화 중이던 것은 통화 상태(메모리)를 잃었으므로 거기서
 * 멈추고(Egress에 멈추라고 하고) 마무리한다. 회의록을 만들던 것은 처음부터 다시(받아쓴 글이 있으면 요약부터).
 */
export async function resumeCallRecordings(io) {
  if (!deps.enabled()) return;
  const rows = await listUnfinishedCallRecordings();
  for (const row of rows) {
    if (row.status === 'recording') {
      const stopped = await transitionCallRecording(row.id, 'recording', { status: 'processing', endedAt: new Date() });
      if (stopped) await stopEgresses(stopped);
    }
  }
  for (const row of rows) {
    if (row.status === 'recording' || row.status === 'processing') {
      finalizeCallRecording(io, row.id).catch((err) => console.error('[call] 녹화 마무리 실패:', err?.message ?? err));
    } else if (['transcribing', 'summarizing'].includes(row.minutesStatus)) {
      await transitionCallMinutes(row.id, ['transcribing', 'summarizing'], { minutesStatus: 'pending' });
      runCallMinutes(io, row.id).catch((err) => console.error('[call] 회의록 만들기 실패:', err?.message ?? err));
    } else if (row.minutesStatus === 'pending') {
      runCallMinutes(io, row.id).catch((err) => console.error('[call] 회의록 만들기 실패:', err?.message ?? err));
    }
  }
  if (rows.length > 0) console.log(`[call] 끝내지 못한 녹화·회의록 ${rows.length}건을 이어서 마무리합니다.`);
}

/** 앱에 내려줄 녹화 한 건. [full]이면 받아쓰기·요약까지. */
export function recordingDto(row, { full = false, canRetry = false } = {}) {
  return {
    id: row.id,
    roomId: row.roomId,
    callMessageId: row.callMessageId,
    startedBy: row.startedBy,
    startedByName: row.startedByName,
    startedAt: new Date(row.startedAt).getTime(),
    endedAt: row.endedAt ? new Date(row.endedAt).getTime() : null,
    durationMs: row.durationMs,
    audioOnly: row.audioOnly,
    status: row.status,
    error: row.error,
    messageId: row.messageId,
    minutesStatus: row.minutesStatus,
    minutesError: row.minutesError,
    participantNames: row.participantNames ?? [],
    // 보관 기간·용량을 넘어 녹화 파일을 지웠으면 그 시각과 까닭('age' | 'size') — 회의록은 남는다.
    purgedAt: row.purgedAt ? new Date(row.purgedAt).getTime() : null,
    purgeReason: row.purgeReason ?? null,
    ...(full && {
      transcript: row.transcript,
      summary: row.summary,
      // 요약의 "할 일" — 회의록 화면이 한 줄씩 할 일로 만든다(callRecordingRules.js actionItemsFromSummary).
      actionItems: actionItemsFromSummary(row.summary, { meetingAt: row.startedAt }),
      canRetry,
    }),
  };
}

/**
 * 녹화·회의록 API.
 *  - POST /rooms/:id/call/recording `{ audioOnly?, minutes? }` — 녹화 시작(진행자만) → `{ recording }`.
 *  - DELETE /rooms/:id/call/recording — 녹화 멈춤(진행자·시작한 사람).
 *  - GET /call-recordings/:id — 녹화 한 건과 회의록(받아쓰기·요약) — 그 방 멤버만.
 *  - POST /call-recordings/:id/minutes/retry — 못 만든 회의록을 다시(녹화를 시작한 사람·토픽 관리자).
 */
export function createCallRecordingRouter(io) {
  const router = Router();

  router.post('/rooms/:id/call/recording', async (req, res) => {
    const room = await findRoomById(req.params.id);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    if (!(await isRoomMember(room.id, req.user.sub))) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
    const result = await startCallRecording({
      io,
      room,
      userId: req.user.sub,
      audioOnly: req.body?.audioOnly === true,
      minutes: req.body?.minutes === true,
    });
    if (!result.ok) return res.status(result.status ?? 400).json({ error: result.error });
    res.status(201).json({ recording: result.recording });
  });

  router.delete('/rooms/:id/call/recording', async (req, res) => {
    if (!(await isRoomMember(req.params.id, req.user.sub))) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
    const result = await stopCallRecording({ io, roomId: req.params.id, userId: req.user.sub });
    if (!result.ok) return res.status(result.status ?? 400).json({ error: result.error });
    res.json({ ok: true });
  });

  /**
   * 이 녹화의 회의록을 다시 만들 수 있는지 — 시작한 사람이나 토픽 관리자이고, 받아쓴 글이나 받아쓸 녹음(음성만 녹음은 올린 파일, 영상은
   * 따로 받은 음성)이 있을 때.
   */
  async function canRetry(row, room, userId) {
    const hasSource = !!row.transcript || (row.audioOnly ? row.status === 'done' : !!row.minutesFilePath);
    if (!hasSource) return false;
    if (row.startedBy === userId) return true;
    return (await topicAccess(room, userId)).canManage;
  }

  router.get('/call-recordings/:id', async (req, res) => {
    const row = /^[0-9a-f-]{36}$/i.test(req.params.id) ? await findCallRecording(req.params.id) : null;
    const room = row ? await findRoomById(row.roomId) : null;
    if (!row || !room || !(await isRoomMember(room.id, req.user.sub))) {
      return res.status(404).json({ error: '녹화를 찾을 수 없습니다.' });
    }
    const retry = row.minutesStatus === 'failed' && (await canRetry(row, room, req.user.sub));
    res.json({ recording: recordingDto(row, { full: true, canRetry: retry }) });
  });

  router.post('/call-recordings/:id/minutes/retry', async (req, res) => {
    const row = /^[0-9a-f-]{36}$/i.test(req.params.id) ? await findCallRecording(req.params.id) : null;
    const room = row ? await findRoomById(row.roomId) : null;
    if (!row || !room || !(await isRoomMember(room.id, req.user.sub))) {
      return res.status(404).json({ error: '녹화를 찾을 수 없습니다.' });
    }
    if (!(await canRetry(row, room, req.user.sub))) {
      return res
        .status(403)
        .json({ error: '회의록은 녹화를 시작한 사람이나 토픽 관리자가, 녹음이 남아 있을 때만 다시 만들 수 있습니다.' });
    }
    if (!minutesEnabled()) return res.status(503).json({ error: '이 서버에는 회의록(받아쓰기)이 설정되어 있지 않습니다.' });
    const next = await transitionCallMinutes(row.id, ['failed'], { minutesStatus: 'pending', minutesError: null });
    if (!next) return res.status(409).json({ error: '회의록을 이미 만들고 있거나 다시 만들 수 없는 녹화입니다.' });
    await refreshCallCardRecordings(io, row.roomId, row.callMessageId);
    runCallMinutes(io, row.id).catch((err) => console.error('[call] 회의록 만들기 실패:', err?.message ?? err));
    res.json({ recording: recordingDto(next, { full: true }) });
  });

  return router;
}
