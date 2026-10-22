import { randomBytes } from 'node:crypto';
import { Router } from 'express';
import { WebSocketServer } from 'ws';
import {
  captionTextFrom,
  pcmFormatFromHeaders,
  pcmToMono,
  resampleTo16k,
  Utterancer,
  wavFromSamples,
} from './callCaptionRules.js';
import { minutesEnabled, transcribeAudio } from './callMinutes.js';
import { listMicTracks, recordingEgress, recordingEnabled } from './callRecording.js';
import { newSpeakerTracks } from './callRecordingRules.js';
import { callStateFor, setCallCaptions } from './callState.js';
import {
  CALL_CAPTION_CHANNELS,
  CALL_CAPTION_SAMPLE_RATE,
  CALL_CAPTION_WS_PORT,
  CALL_CAPTION_WS_URL,
  CALL_CAPTIONS,
} from './config.js';
import { isRoomMember } from './db/queries/rooms.js';
import { findUserById } from './db/queries/users.js';

/**
 * 통화 중 실시간 자막 — 진행자가 켜면 LiveKit Egress가 마이크 트랙마다 소리(16비트 PCM)를 이 서버의 웹소켓(CALL_CAPTION_WS_PORT —
 * 평문, Egress만 붙는다)으로 흘려보내고(트랙 녹음의 웹소켓 출력), 서버가 말 한 마디씩 끊어(callCaptionRules.js Utterancer) 받아쓰기
 * 서비스(회의록과 같은 CALL_TRANSCRIBE_URL)로 받아써 `call:caption { roomId, userId, name, text, at }`을 그 방에 보낸다. 사람마다
 * 따로 받으므로 누가 말했는지 안다. 새로 들어온 사람의 마이크는 몇 초마다 살펴 더한다.
 *
 * 녹화(Egress)와 받아쓰기가 둘 다 설정돼 있어야 켜진다(CALL_CAPTIONS=off면 끔). 통화가 끝나면 저절로 끈다(callCards.js postCallLeft).
 * 자막은 저장하지 않는다 — 기록이 필요하면 회의록을 만든다.
 *
 * Egress가 웹소켓으로 보내는 소리 형식은 연결 요청의 Content-Type(`audio/x-raw;rate=…;channels=…`)으로 알고, 없으면
 * CALL_CAPTION_SAMPLE_RATE·CALL_CAPTION_CHANNELS. 글(텍스트) 메시지(마이크 꺼짐 알림 등)는 무시한다.
 */

export function captionsEnabled() {
  return CALL_CAPTIONS && recordingEnabled() && minutesEnabled();
}

const defaultDeps = {
  enabled: captionsEnabled,
  egress: () => recordingEgress(),
  micTracks: listMicTracks,
  transcribe: transcribeAudio,
  wsUrl: () => CALL_CAPTION_WS_URL,
  pollMs: 5000,
  // 한 방에서 동시에 받아쓰는 마디 수 — 넘으면 새 마디를 버린다(자막은 늦으면 쓸모가 없다).
  maxInFlight: 4,
  listen: true,
};
let deps = { ...defaultDeps };

/** roomId → { byId, byName, startedAt, tracks: [{ trackSid, identity, name, egressId, token }], timer, inFlight, dropped } */
const sessions = new Map();
/** 웹소켓 주소의 열쇠 → { roomId, identity, name } — Egress가 붙을 때 누구의 소리인지. */
const tokens = new Map();
let wss = null;

/** 시험용 — Egress·받아쓰기·웹소켓 주소를 바꿔 끼운다(인자 없이 부르면 원래대로). */
export function setCallCaptionsDepsForTest(overrides) {
  for (const s of sessions.values()) clearInterval(s.timer);
  sessions.clear();
  tokens.clear();
  deps = overrides ? { ...defaultDeps, ...overrides } : { ...defaultDeps };
}

export function activeCaptionsFor(roomId) {
  return sessions.get(roomId) ?? null;
}

function emitCallState(io, roomId) {
  const state = callStateFor(roomId);
  if (state.active) io.to(roomId).emit('call:state', state);
}

/** 말 한 마디를 받아써 자막으로 보낸다(밀려 있으면 버린다). */
function caption(io, session, who, utterance, sampleRate) {
  if (session.inFlight >= deps.maxInFlight) {
    session.dropped += 1;
    return;
  }
  session.inFlight += 1;
  const wav = wavFromSamples(resampleTo16k(utterance.samples, sampleRate));
  deps
    .transcribe(wav, 'caption.wav')
    .then((response) => {
      const text = captionTextFrom(response);
      if (!text || sessions.get(who.roomId) !== session) return;
      io.to(who.roomId).emit('call:caption', {
        roomId: who.roomId,
        userId: who.identity,
        name: who.name,
        text,
        at: Date.now(),
      });
    })
    .catch((err) => {
      if (!session.warned) console.warn('[call] 자막을 받아쓰지 못했습니다:', err?.message ?? err);
      session.warned = true;
    })
    .finally(() => {
      session.inFlight -= 1;
    });
}

/**
 * Egress가 붙은 웹소켓 하나 — [token]으로 누구의 소리인지 찾고, 소리를 말 한 마디씩 끊어 받아쓴다. [send]는 시험이 쓰는 자리가
 * 아니라 실제 소켓의 이벤트를 넘기는 [socket]. 모르는 열쇠면 닫는다.
 */
export function acceptCaptionSocket(io, socket, { token, headers }) {
  const who = tokens.get(token);
  const session = who ? sessions.get(who.roomId) : null;
  if (!who || !session) {
    socket.close(1008, 'unknown');
    return;
  }
  const format = pcmFormatFromHeaders(headers, { sampleRate: CALL_CAPTION_SAMPLE_RATE, channels: CALL_CAPTION_CHANNELS });
  const utterancer = new Utterancer(format.sampleRate);
  socket.on('message', (data, isBinary) => {
    if (!isBinary || sessions.get(who.roomId) !== session) return;
    const buffer = Buffer.isBuffer(data) ? data : Buffer.concat(Array.isArray(data) ? data : [Buffer.from(data)]);
    for (const utterance of utterancer.push(pcmToMono(buffer, format.channels))) {
      caption(io, session, who, utterance, format.sampleRate);
    }
  });
  socket.on('close', () => {
    const last = utterancer.flush();
    if (last && sessions.get(who.roomId) === session) caption(io, session, who, last, format.sampleRate);
  });
}

/** Egress가 소리를 보낼 웹소켓 서버를 띄운다(처음 자막을 켤 때 한 번). */
function ensureServer(io) {
  if (wss || !deps.listen) return;
  wss = new WebSocketServer({ port: CALL_CAPTION_WS_PORT, perMessageDeflate: false, maxPayload: 1024 * 1024 });
  wss.on('connection', (socket, req) => {
    const token = String(req.url ?? '').split('?')[0].split('/').filter(Boolean).pop() ?? '';
    acceptCaptionSocket(io, socket, { token, headers: req.headers });
  });
  wss.on('error', (err) => {
    console.error(`[call] 자막용 웹소켓(포트 ${CALL_CAPTION_WS_PORT})을 열지 못했습니다:`, err?.message ?? err);
    wss = null;
  });
  console.log(`[call] 자막용 웹소켓을 열었습니다(포트 ${CALL_CAPTION_WS_PORT} — Egress가 ${deps.wsUrl()}로 붙는다).`);
}

/** 새로 들어온 사람의 마이크를 더한다. */
async function syncTracks(roomId, session) {
  if (session.syncing || sessions.get(roomId) !== session) return;
  session.syncing = true;
  try {
    const fresh = newSpeakerTracks(session.tracks, await deps.micTracks(roomId));
    for (const t of fresh) {
      const token = randomBytes(18).toString('base64url');
      const entry = { trackSid: t.trackSid, identity: t.identity, name: t.name, egressId: null, token };
      session.tracks.push(entry);
      tokens.set(token, { roomId, identity: t.identity, name: t.name });
      try {
        ({ egressId: entry.egressId } = await deps.egress().startTrack(roomId, t.trackSid, `${deps.wsUrl()}/${token}`));
      } catch (err) {
        tokens.delete(token);
        console.warn('[call] 자막용으로 마이크를 받지 못했습니다(Egress):', t.identity, err?.message ?? err);
      }
    }
  } catch (err) {
    console.warn('[call] 자막 — 회의 참가자의 마이크를 살피지 못했습니다:', err?.message ?? err);
  } finally {
    session.syncing = false;
  }
}

/** 자막을 켤 수 없는 이유(진행자만, 통화 중일 때) — 켤 수 있으면 null. */
export function captionsStartDenial({ enabled, call, userId, on }) {
  if (!enabled) return '이 서버에는 실시간 자막이 설정되어 있지 않습니다.';
  if (!call?.active) return '진행 중인 화상회의가 없습니다.';
  if (!call.participantIds.includes(userId)) return '화상회의에 들어와 있을 때만 자막을 켤 수 있습니다.';
  if (call.hostId !== userId) return '진행자만 자막을 켤 수 있습니다.';
  if (on) return '이미 자막을 켰습니다.';
  return null;
}

/** 자막을 켠다 → `{ ok: true }` 또는 `{ ok: false, status, error }`. */
export async function startCallCaptions({ io, roomId, userId }) {
  const denial = captionsStartDenial({ enabled: deps.enabled(), call: callStateFor(roomId), userId, on: sessions.has(roomId) });
  if (denial) return { ok: false, status: denial.includes('설정되어') ? 503 : 409, error: denial };
  const user = await findUserById(userId);
  const session = {
    byId: userId,
    byName: user?.name ?? user?.username ?? '알 수 없음',
    startedAt: Date.now(),
    tracks: [],
    inFlight: 0,
    dropped: 0,
    timer: null,
  };
  sessions.set(roomId, session);
  ensureServer(io);
  setCallCaptions(roomId, { byId: session.byId, byName: session.byName, startedAt: session.startedAt });
  emitCallState(io, roomId);
  session.timer = setInterval(() => void syncTracks(roomId, session), deps.pollMs);
  session.timer.unref?.();
  await syncTracks(roomId, session);
  return { ok: true };
}

/** 자막을 끈다 — [userId]가 있으면 사람이 누른 것(진행자·켠 사람만), 없으면 서버가(통화 끝). */
export async function stopCallCaptions({ io, roomId, userId = null }) {
  const session = sessions.get(roomId);
  if (userId) {
    if (!session) return { ok: false, status: 409, error: '자막을 켜지 않았습니다.' };
    const call = callStateFor(roomId);
    if (session.byId !== userId && !(call?.active && call.hostId === userId)) {
      return { ok: false, status: 403, error: '자막을 켠 사람이나 진행자만 끌 수 있습니다.' };
    }
  }
  if (!session) return { ok: true };
  sessions.delete(roomId);
  clearInterval(session.timer);
  for (const t of session.tracks) {
    tokens.delete(t.token);
    if (!t.egressId) continue;
    await deps
      .egress()
      .stop(t.egressId)
      .catch((err) => console.warn('[call] 자막용 Egress 멈추기 실패(이미 끝났을 수 있음):', err?.message ?? err));
  }
  if (session.dropped > 0) console.log(`[call] 자막이 밀려 받아쓰지 못하고 버린 마디 ${session.dropped}개(${roomId}).`);
  setCallCaptions(roomId, null);
  emitCallState(io, roomId);
  return { ok: true };
}

/**
 *  - POST /rooms/:id/call/captions — 자막 켜기(진행자만).
 *  - DELETE /rooms/:id/call/captions — 자막 끄기(진행자·켠 사람).
 */
export function createCallCaptionsRouter(io) {
  const router = Router();
  router.post('/rooms/:id/call/captions', async (req, res) => {
    if (!(await isRoomMember(req.params.id, req.user.sub))) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
    const result = await startCallCaptions({ io, roomId: req.params.id, userId: req.user.sub });
    if (!result.ok) return res.status(result.status).json({ error: result.error });
    res.status(201).json({ ok: true });
  });
  router.delete('/rooms/:id/call/captions', async (req, res) => {
    if (!(await isRoomMember(req.params.id, req.user.sub))) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
    const result = await stopCallCaptions({ io, roomId: req.params.id, userId: req.user.sub });
    if (!result.ok) return res.status(result.status).json({ error: result.error });
    res.json({ ok: true });
  });
  return router;
}
