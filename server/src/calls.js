import { Router } from 'express';
import { AccessToken, ParticipantInfo_State, RoomServiceClient } from 'livekit-server-sdk';
import { topicAccess } from './access.js';
import { tooMany } from './authGuard.js';
import {
  CALL_TOKEN_TTL_MS,
  callRoomDenial,
  callStartDenial,
  callStartWait,
  isLivekitNotFound,
  isRestrictedTopic,
  recordCallToken,
} from './callAccess.js';
import { callStateFor } from './callState.js';
import { LIVEKIT_API_KEY, LIVEKIT_API_SECRET, LIVEKIT_PORT, LIVEKIT_URL } from './config.js';
import { findRoomById, isRoomMember } from './db/queries/rooms.js';
import { findUserById } from './db/queries/users.js';
import { LIVEKIT_PROXY_PREFIX } from './livekitProxy.js';
import { minutesEnabled, summaryEnabled } from './callMinutes.js';
import { recordingEnabled } from './callRecording.js';
import { captionsEnabled } from './callCaptions.js';

/**
 * 화상회의(LiveKit SFU) — 대화방 하나당 회의방 하나를 그대로 대응시킨다(LiveKit room 이름 =
 * 우리 방 id). 1:1이든 그룹이든 같은 경로를 쓴다: LiveKit에서 1:1은 그냥 참가자가 2명인
 * 방이라, P2P 시그널링을 따로 만들 이유가 없다.
 *
 * 서버가 하는 일은 **참가 토큰 발급**과, 자격을 잃은 사람을 LiveKit에서 내보내기(방 관리 API —
 * callAccess.js)다. 미디어는 클라이언트↔LiveKit이 직접 주고받고, 이 Node 서버는 그 경로에 끼지
 * 않는다. 토큰은 "누가(identity) 어느 방에(roomJoin) 들어갈 수 있는지"를 LiveKit API 비밀키로
 * 서명한 것이라, 클라이언트가 스스로 만들 수 없다 — 방 멤버십 검사를 여기서 한 번 하고 나면
 * LiveKit이 그 결과를 신뢰하는 구조라, 나중에 멤버십을 잃으면 서버가 직접 내보내야 한다.
 */

/** LiveKit 비밀값이 없으면(설치 안 됨/미설정) 화상회의 기능 전체를 끈다. */
export function callsEnabled() {
  return !!LIVEKIT_API_SECRET;
}

/**
 * LiveKit 방 관리 API(참가자 확인·내보내기) — 같은 PC의 LiveKit에 바로 붙는다. 메인 포트의 /livekit 프록시는 앱이 쓰는
 * 신호 경로만 넘기고 방 관리 API는 넘기지 않으므로(livekitProxy.js) 그쪽으로 가지 않는다. LiveKit을 다른 장비에 띄웠으면
 * (LIVEKIT_URL) 그 주소의 같은 포트가 API다(SDK가 ws→http로 바꾼다). 화상회의가 설정 안 된 서버면 null.
 */
let roomService = null;
export function livekitRoomService() {
  if (!callsEnabled()) return null;
  roomService ??= new RoomServiceClient(LIVEKIT_URL || `http://127.0.0.1:${LIVEKIT_PORT}`, LIVEKIT_API_KEY, LIVEKIT_API_SECRET, {
    // 같은 PC라 보통 바로 답한다 — LiveKit이 멈춰 있어도 통화 신호·내보내기를 오래 붙잡지 않게.
    requestTimeout: 5,
  });
  return roomService;
}

/**
 * [userId]가 지금 이 방의 LiveKit 회의에 실제로 연결돼 있는지(LiveKit room 이름 = 방 id, identity = 사용자 id). call:join이
 * 토큰 발급 기록도 통화 상태도 없이 왔을 때(오래 끊겼다 다시 알림·서버 재시작 뒤 — callAccess.js) 확인한다. 못 물어보면
 * (LiveKit이 꺼짐 등) false — 그때는 미디어도 안 될 때다.
 */
export async function livekitHasParticipant(roomId, userId) {
  const livekit = livekitRoomService();
  if (!livekit) return false;
  try {
    const participant = await livekit.getParticipant(roomId, userId);
    return participant.state !== ParticipantInfo_State.DISCONNECTED;
  } catch (err) {
    if (!isLivekitNotFound(err)) console.error('[call] LiveKit 참가자 확인 실패:', err?.message ?? err);
    return false;
  }
}

// 진행 중인 통화의 메모리 상태(참가자·진행자·화질 단계)는 callState.js에 있다 — DB를 몰라 단위 테스트가 그대로 돌린다.
export {
  activeCallStatesFor,
  callStateFor,
  canControlMic,
  joinCall,
  leaveAllCallsForSocket,
  leaveCall,
  refreshVideoTiers,
} from './callState.js';

/**
 * 통화가 끝났을 때 대화에 남길 한 줄. 녹화 대신 "언제 누가 얼마나 회의했는지"를 대화 기록에
 * 남겨두는 용도다(슬랙/카카오톡이 통화 후 남기는 줄과 같은 역할).
 *
 * [names]는 참여자 이름 목록(호출부가 id로 조회해서 넘긴다). 인원이 많으면 이름을 다 늘어놓는
 * 대신 앞의 몇 명만 쓰고 "외 N명"으로 줄인다 — 대화 목록 미리보기에도 이 줄이 그대로 뜨므로
 * 너무 길면 안 된다.
 */
export function callSummaryText(ended, names) {
  if (!ended.answered) return '부재중 화상회의';
  const seconds = Math.round(ended.durationMs / 1000);
  const length = seconds < 60 ? `${seconds}초` : `${Math.round(seconds / 60)}분`;

  const shown = names.slice(0, 3);
  const rest = names.length - shown.length;
  const who = rest > 0 ? `${shown.join(', ')} 외 ${rest}명` : shown.join(', ');
  return `화상회의 · ${length} · ${who} 참여`;
}

/**
 * 클라이언트가 접속할 LiveKit 주소. 지금 이 요청이 들어온 바로 그 주소(호스트:포트)의 /livekit —
 * 메인 HTTPS 서버가 같은 PC의 LiveKit으로 넘겨준다(livekitProxy.js). 클라이언트가 사내 주소로
 * 왔든 외부(LTE/5G) 주소로 왔든 그 주소를 그대로 쓰므로 별도 설정이 필요 없고, 공유기에는 메인
 * 포트만 열면 된다. LiveKit을 다른 장비에 띄운 경우에만 LIVEKIT_URL로 덮어쓴다.
 */
function livekitUrlFor(req) {
  if (LIVEKIT_URL) return LIVEKIT_URL;
  const host = req.headers.host;
  if (!host) return null;
  return `wss://${host}${LIVEKIT_PROXY_PREFIX}`;
}

export function createCallsRouter() {
  const router = Router();

  /**
   * 이 서버에서 화상회의를 쓸 수 있는지 + 접속 주소. 클라이언트가 통화 버튼을 보여줄지 정한다. recording·minutes·summary는 녹화(Egress)·
   * 회의록 받아쓰기·요약이 설정됐는지 — 통화 화면이 [녹화]와 "회의록 만들기"를 보여줄지 정한다(callRecording.js·callMinutes.js).
   */
  router.get('/calls/config', (req, res) => {
    const enabled = callsEnabled();
    const recording = enabled && recordingEnabled();
    res.json({
      enabled,
      url: enabled ? livekitUrlFor(req) : null,
      recording,
      minutes: recording && minutesEnabled(),
      summary: recording && minutesEnabled() && summaryEnabled(),
      // 통화 중 실시간 자막(callCaptions.js) — 진행자가 켠다.
      captions: enabled && captionsEnabled(),
    });
  });

  /**
   * 이 방의 화상회의에 들어갈 참가 토큰 발급. 방 멤버만 받을 수 있다.
   *
   * 비밀 대화(E2EE)·나와의 대화는 제외한다(callAccess.js callRoomDenial). 진행 중인 통화가 없으면 이 요청은 통화를 "시작"
   * 하는 것이라, 읽기 전용·보관된 토픽은 토픽 관리자만(callStartDenial), 너무 자주는 안 된다(callStartWait — 세는 건 실제로
   * 통화가 시작되는 call:join이고 여기서는 미리 알려 줄 뿐이다). 앱은 이 토큰으로 LiveKit에 연결한 뒤 call:join을 보내는데,
   * call:join은 방금 토큰을 받은 사람인지도 본다(recordCallToken).
   */
  router.post('/rooms/:id/call/token', async (req, res) => {
    if (!callsEnabled()) {
      return res.status(503).json({ error: '이 서버에는 화상회의가 설정되어 있지 않습니다.' });
    }
    const room = await findRoomById(req.params.id);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    if (!(await isRoomMember(room.id, req.user.sub))) {
      return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
    }
    // 비밀 대화는 SFU가 미디어를 풀어 중계해서 안 되고, 나와의 대화는 회의할 상대가 없다(클라이언트도 버튼을 감춘다).
    const roomDenial = callRoomDenial(room);
    if (roomDenial) return res.status(400).json({ error: roomDenial });
    if (!callStateFor(room.id).active) {
      if (isRestrictedTopic(room)) {
        const startDenial = callStartDenial({ room, canManage: (await topicAccess(room, req.user.sub)).canManage });
        if (startDenial) return res.status(403).json({ error: startDenial });
      }
      const wait = callStartWait(req.user.sub, room.id);
      if (wait > 0) return tooMany(res, wait, '화상회의 시도');
    }

    const url = livekitUrlFor(req);
    if (!url) return res.status(500).json({ error: 'LiveKit 주소를 알 수 없습니다.' });

    const me = await findUserById(req.user.sub);
    const token = new AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET, {
      identity: req.user.sub, // 참가자 식별자 = 우리 사용자 id(클라이언트가 누가 누군지 매칭한다).
      name: me?.name ?? me?.username ?? '알 수 없음',
      // 토큰은 "입장권"이라 짧게 — 통화가 이어지는 동안은 LiveKit이 연결을 유지하므로
      // 만료돼도 통화가 끊기지 않는다(다시 들어올 땐 새로 발급받는다).
      ttl: CALL_TOKEN_TTL_MS / 1000,
    });
    token.addGrant({
      roomJoin: true,
      room: room.id,
      canPublish: true,
      canSubscribe: true,
      // 통화 중 채팅/상태 공유(참가자 목록의 손들기 등)에 쓰는 LiveKit data channel.
      canPublishData: true,
    });

    const jwt = await token.toJwt();
    recordCallToken(req.user.sub, room.id);
    res.json({ url, roomName: room.id, token: jwt });
  });

  return router;
}
