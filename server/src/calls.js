import { Router } from 'express';
import { AccessToken } from 'livekit-server-sdk';
import { LIVEKIT_API_KEY, LIVEKIT_API_SECRET, LIVEKIT_PORT, LIVEKIT_URL } from './config.js';
import { findRoomById, isRoomMember } from './db/queries/rooms.js';
import { findUserById } from './db/queries/users.js';
import { SELF_ROOM_DENIAL } from './permissions.js';

/**
 * 화상회의(LiveKit SFU) — 대화방 하나당 회의방 하나를 그대로 대응시킨다(LiveKit room 이름 =
 * 우리 방 id). 1:1이든 그룹이든 같은 경로를 쓴다: LiveKit에서 1:1은 그냥 참가자가 2명인
 * 방이라, P2P 시그널링을 따로 만들 이유가 없다.
 *
 * 서버가 하는 일은 **참가 토큰 발급**뿐이다. 미디어는 클라이언트↔LiveKit이 직접 주고받고,
 * 이 Node 서버는 그 경로에 끼지 않는다. 토큰은 "누가(identity) 어느 방에(roomJoin) 들어갈 수
 * 있는지"를 LiveKit API 비밀키로 서명한 것이라, 클라이언트가 스스로 만들 수 없다 —
 * 방 멤버십 검사를 여기서 한 번 하고 나면 LiveKit이 그 결과를 신뢰하는 구조다.
 */

/** LiveKit 비밀값이 없으면(설치 안 됨/미설정) 화상회의 기능 전체를 끈다. */
export function callsEnabled() {
  return !!LIVEKIT_API_SECRET;
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
 * 클라이언트가 접속할 LiveKit 주소. 보통은 지금 이 요청이 들어온 바로 그 호스트의 LiveKit
 * 포트다 — 클라이언트는 이미 이 서버 주소로 접속해 있으므로(페어링으로 정해둔 주소) 그
 * 호스트를 그대로 재사용하면 별도 설정이 필요 없다. LiveKit을 다른 장비에 띄운 경우에만
 * LIVEKIT_URL로 덮어쓴다.
 */
function livekitUrlFor(req) {
  if (LIVEKIT_URL) return LIVEKIT_URL;
  const host = req.hostname;
  if (!host) return null;
  return `ws://${host}:${LIVEKIT_PORT}`;
}

export function createCallsRouter() {
  const router = Router();

  /** 이 서버에서 화상회의를 쓸 수 있는지 + 접속 주소. 클라이언트가 통화 버튼을 보여줄지 정한다. */
  router.get('/calls/config', (req, res) => {
    res.json({ enabled: callsEnabled(), url: callsEnabled() ? livekitUrlFor(req) : null });
  });

  /**
   * 이 방의 화상회의에 들어갈 참가 토큰 발급. 방 멤버만 받을 수 있다.
   *
   * 비밀 대화(E2EE)는 제외한다 — 서버가 내용을 볼 수 없어야 하는 방인데 SFU는 미디어를
   * 복호화해서 중계하는 구성요소라 그 약속이 깨진다(대화 내보내기를 막아둔 것과 같은 이유).
   * LiveKit 자체는 E2EE를 지원하므로 나중에 열어줄 수 있다.
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
    if (room.isSecret) {
      return res.status(400).json({ error: '비밀 대화에서는 아직 화상회의를 쓸 수 없습니다.' });
    }
    // 나와의 대화는 나 혼자라 회의할 상대가 없다(클라이언트도 버튼을 감춘다).
    if (room.isSelf) return res.status(400).json({ error: SELF_ROOM_DENIAL });

    const url = livekitUrlFor(req);
    if (!url) return res.status(500).json({ error: 'LiveKit 주소를 알 수 없습니다.' });

    const me = await findUserById(req.user.sub);
    const token = new AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET, {
      identity: req.user.sub, // 참가자 식별자 = 우리 사용자 id(클라이언트가 누가 누군지 매칭한다).
      name: me?.name ?? me?.username ?? '알 수 없음',
      // 토큰은 "입장권"이라 짧게 — 통화가 이어지는 동안은 LiveKit이 연결을 유지하므로
      // 만료돼도 통화가 끊기지 않는다(다시 들어올 땐 새로 발급받는다).
      ttl: '10m',
    });
    token.addGrant({
      roomJoin: true,
      room: room.id,
      canPublish: true,
      canSubscribe: true,
      // 통화 중 채팅/상태 공유(참가자 목록의 손들기 등)에 쓰는 LiveKit data channel.
      canPublishData: true,
    });

    res.json({ url, roomName: room.id, token: await token.toJwt() });
  });

  return router;
}
