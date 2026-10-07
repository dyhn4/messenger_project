// 비밀 대화(E2EE) 핸드셰이크·재키잉에서 서버가 받아 저장하고 상대에게 넘기는 값의 모양 규칙 — 맥락 서명 검사, 이벤트·응답
// payload, 방 DTO의 비밀 대화 칸. DB·소켓은 안 건드리고(secretChats.js·socket.js·rooms.js가 읽어 온 행을 받아) 단위
// 테스트(test/secretContextRules.test.js)로 그대로 검증한다.
//
// 맥락 서명(v2)은 임시 공개키만이 아니라 "누가(사용자·기기) 누구와, 어느 방의 몇 번째 키로" 낸 키인지까지 묶어 기기의 장기
// 서명키로 서명한 값이다(client secret_chat_crypto.dart). 예전 서명(…EphemeralSignature)은 키 바이트만 서명해서, 서버가
// 한 대화에서 본 서명된 키를 다른 대화·다른 상대에게 그대로 다시 쓸 수 있었다(검토 S5). 서버는 이 서명을 검증하지 않는다 —
// 막으려는 상대가 바로 서버라서 서버의 확인은 아무것도 보장하지 못한다. 받는 앱이 고정해 둔 상대 기기 키로 직접 검증한다.
// 여기서는 모양(64바이트 Ed25519 서명의 base64)만 봐서 엉뚱한 값·큰 값이 DB에 쌓이거나 상대에게 넘어가지 않게 한다.
// 예전 앱은 이 칸을 아예 보내지 않으므로, 없으면 null로 저장·전달하고 나머지는 예전과 똑같이 받는다.

/** Ed25519 서명 길이(바이트). */
export const CONTEXT_SIGNATURE_BYTES = 64;

// 64바이트의 base64는 글자 86개 + 패딩 '=='(앱의 base64Encode는 패딩을 붙여 88자). 표준(+/)·URL 안전(-_) 글자를 모두
// 받는다 — 받는 앱의 디코더(dart:convert)가 둘 다 읽어서. 글자 수를 정규식으로 먼저 묶어 큰 값은 디코딩하지도 않는다.
const CONTEXT_SIGNATURE_RE = /^[A-Za-z0-9+/_-]{86}(?:==)?$/;

/** 맥락 서명 모양인지 — 문자열이고 base64로 풀면 정확히 64바이트. */
export function isContextSignature(value) {
  return (
    typeof value === 'string' &&
    CONTEXT_SIGNATURE_RE.test(value) &&
    Buffer.from(value, 'base64').length === CONTEXT_SIGNATURE_BYTES
  );
}

/**
 * 본문·payload의 맥락 서명 칸 하나 → `{ value }`(없으면 — undefined·null, 예전 앱 — null) | `{ error }`. [field]는 오류
 * 문구에 넣을 칸 이름. 모양이 틀린 값을 null로 바꿔 받지 않는다 — 그러면 받는 새 앱이 "예전 앱이 보낸 핸드셰이크"로
 * 잘못 알 수 있어서, REST는 400으로 거절하고 소켓은 이벤트째 버린다.
 */
export function parseContextSignature(raw, field) {
  if (raw === undefined || raw === null) return { value: null };
  if (!isContextSignature(raw)) return { error: `맥락 서명(${field})이 올바르지 않습니다.` };
  return { value: raw };
}

/**
 * secret:rekey-propose / secret:rekey-ack payload → `{ roomId, keyEpoch, ephemeralPublicKey, ephemeralSignature,
 * contextSignature }` | null(모양이 틀림 — 다른 잘못된 payload처럼 조용히 버린다). 임시 공개키·예전 서명은 예전처럼 비어
 * 있지만 않으면 받는다(예전 앱과 같은 동작). 맥락 서명(ephemeralContextSignature)은 없으면 null, 있는데 모양이 틀리면
 * 통째로 버린다(parseContextSignature와 같은 이유).
 */
export function parseRekeyPayload(payload) {
  if (!payload || typeof payload !== 'object') return null;
  const { roomId, keyEpoch, ephemeralPublicKey, ephemeralSignature, ephemeralContextSignature } = payload;
  if (typeof roomId !== 'string' || !roomId) return null;
  if (!Number.isInteger(keyEpoch) || !ephemeralPublicKey || !ephemeralSignature) return null;
  const context = parseContextSignature(ephemeralContextSignature, 'ephemeralContextSignature');
  if (context.error) return null;
  return { roomId, keyEpoch, ephemeralPublicKey, ephemeralSignature, contextSignature: context.value };
}

/**
 * secret:invite 이벤트와 GET /secret-chats/:roomId/invite 응답(앱이 꺼져 있어 이벤트를 놓쳤을 때) — 둘 다 같은 세션 행에서
 * 같은 모양으로 만든다(어느 길로 받든 앱이 같은 값을 검증하게). initiatorContextSignature는 예전 앱이 만든 세션이면 null.
 */
export function secretInvitePayload(session) {
  return {
    roomId: session.roomId,
    initiatorUserId: session.initiatorUserId,
    initiatorDeviceId: session.initiatorDeviceId,
    initiatorEphemeralPublicKey: session.initiatorEphemeralPublicKey,
    initiatorEphemeralSignature: session.initiatorEphemeralSignature,
    initiatorContextSignature: session.initiatorContextSignature ?? null,
  };
}

/**
 * secret:accepted 이벤트 — 수락으로 바뀐 세션 행에서 만든다. responderUserId는 초대한 앱이 맥락 서명을 검증할 때 쓴다(서명한
 * 문자열 안에 들어 있다). responderContextSignature는 예전 앱이 수락했으면 null.
 */
export function secretAcceptedPayload(session) {
  return {
    roomId: session.roomId,
    responderUserId: session.responderUserId,
    responderDeviceId: session.responderDeviceId,
    responderEphemeralPublicKey: session.responderEphemeralPublicKey,
    responderEphemeralSignature: session.responderEphemeralSignature,
    responderContextSignature: session.responderContextSignature ?? null,
  };
}

/** secret:rekey-propose 중계 — 제안한 사람(proposerUserId)은 payload가 아니라 이 소켓의 로그인 사용자다. */
export function rekeyProposeRelay(roomId, proposerUserId, rekey) {
  return {
    roomId,
    keyEpoch: rekey.keyEpoch,
    proposerUserId,
    proposerEphemeralPublicKey: rekey.ephemeralPublicKey,
    proposerEphemeralSignature: rekey.ephemeralSignature,
    proposerContextSignature: rekey.contextSignature ?? null,
  };
}

/** secret:rekey-ack 중계 — 응답한 사람(responderUserId)도 이 소켓의 로그인 사용자다. */
export function rekeyAckRelay(roomId, responderUserId, rekey) {
  return {
    roomId,
    keyEpoch: rekey.keyEpoch,
    responderUserId,
    responderEphemeralPublicKey: rekey.ephemeralPublicKey,
    responderEphemeralSignature: rekey.ephemeralSignature,
    responderContextSignature: rekey.contextSignature ?? null,
  };
}

/**
 * 방 DTO(rooms.js toRoomDto)의 비밀 대화 칸 — 세션 행이 없으면(지워지는 중 등) 기본값. 상태·키 세대·자동 삭제 타이머·
 * 초대한 사람에 더해 양쪽 사용자·기기 id를 싣는다: 앱이 상대 기기를 따로 기억해 두지 않았던 대화(이 칸이 생기기 전에
 * 만들어진 대화)를 앱이 다시 켜진 뒤에도 그 상대 기기에 묶어 재키잉을 이어 가게. 아직 모르는 값(수락 전의 받는 쪽 기기)은
 * null. 공개키·서명·공유비밀은 여기에 싣지 않는다(공개키·서명은 핸드셰이크 이벤트로만 오간다).
 */
export function secretRoomFields(session) {
  return {
    secretStatus: session?.status ?? null,
    secretKeyEpoch: session?.keyEpoch ?? 0,
    secretSelfDestructSeconds: session?.selfDestructSeconds ?? null,
    secretInitiatorUserId: session?.initiatorUserId ?? null,
    secretInitiatorDeviceId: session?.initiatorDeviceId ?? null,
    secretResponderUserId: session?.responderUserId ?? null,
    secretResponderDeviceId: session?.responderDeviceId ?? null,
  };
}
