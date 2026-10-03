// 그룹채팅 → 토픽 전환(POST /rooms/:id/convert-to-topic)과 여러 방에 한 번에 초대(POST /rooms/invite-bulk)의
// 순수 규칙 — 요청 해석, 방 종류 판정, 초대 대상 분류. DB·소켓은 안 건드리고(rooms.js가 읽어 온 값을 받아)
// 단위 테스트(test/roomInvite.test.js)로 그대로 검증한다.
import { graphemeLength, TOPIC_DESCRIPTION_MAX, TOPIC_NAME_MAX } from './permissions.js';

export const INVITE_BULK_MAX_USERS = 200;
export const INVITE_BULK_MAX_ROOMS = 100;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** 중복·문자열 아님을 걸러 낸 id 목록(순서 유지). */
function uniqueStrings(raw) {
  if (!Array.isArray(raw)) return [];
  return [...new Set(raw.filter((id) => typeof id === 'string' && id))];
}

/**
 * 그룹→토픽 전환 본문 — 이름 1~60자(앞뒤 공백 제거), 설명 0~300자(없으면 null).
 * 통과하면 `{ name, description }`, 아니면 `{ error }`.
 */
export function parseConvertBody(body) {
  const rawName = typeof body?.name === 'string' ? body.name.trim() : '';
  if (!rawName) return { error: '토픽 이름을 입력하세요.' };
  if (graphemeLength(rawName) > TOPIC_NAME_MAX) {
    return { error: `토픽 이름은 ${TOPIC_NAME_MAX}자 이내로 입력하세요.` };
  }
  const rawDescription = body?.description;
  if (rawDescription != null && typeof rawDescription !== 'string') {
    return { error: '토픽 설명이 올바르지 않습니다.' };
  }
  const description = (rawDescription ?? '').trim();
  if (graphemeLength(description) > TOPIC_DESCRIPTION_MAX) {
    return { error: `토픽 설명은 ${TOPIC_DESCRIPTION_MAX}자 이내로 입력하세요.` };
  }
  return { name: rawName, description: description || null };
}

/**
 * 전환할 수 없는 방이면 거절 문구, 가능하면 null. 그룹채팅만 된다 — 1:1(비밀 대화 포함)·나와의 대화·이미
 * 토픽인 방은 안 된다.
 */
export function convertDenial(room) {
  if (!room) return '방을 찾을 수 없습니다.';
  if (room.isSelf) return '나와의 대화는 토픽으로 전환할 수 없습니다.';
  if (room.type === 'topic') return '이미 토픽입니다.';
  if (room.type === 'dm' || room.isSecret) return '1:1 대화는 토픽으로 전환할 수 없습니다.';
  if (room.type !== 'group') return '그룹채팅만 토픽으로 전환할 수 있습니다.';
  return null;
}

/** 전환 시스템 메시지 문구. */
export function convertNotice(actorName, topicName) {
  return `${actorName} 님이 그룹채팅을 '${topicName}' 토픽으로 전환했습니다.`;
}

/** 일괄 초대 본문 — 통과하면 `{ teamId, userIds, roomIds }`, 아니면 `{ error }`. */
export function parseInviteBulkBody(body) {
  const teamId = typeof body?.teamId === 'string' ? body.teamId : null;
  if (!teamId) return { error: 'teamId가 필요합니다.' };
  const userIds = uniqueStrings(body?.userIds);
  if (userIds.length === 0) return { error: '초대할 멤버를 선택하세요.' };
  if (userIds.length > INVITE_BULK_MAX_USERS) {
    return { error: `한 번에 ${INVITE_BULK_MAX_USERS}명까지 초대할 수 있습니다.` };
  }
  const roomIds = uniqueStrings(body?.roomIds);
  if (roomIds.length === 0) return { error: '초대할 토픽이나 그룹채팅을 선택하세요.' };
  if (roomIds.length > INVITE_BULK_MAX_ROOMS) {
    return { error: `한 번에 ${INVITE_BULK_MAX_ROOMS}개 대화방까지 초대할 수 있습니다.` };
  }
  return { teamId, userIds, roomIds };
}

/** 방 id가 uuid 모양인지(rooms.id는 text라 DB 오류는 안 나지만 'general' 같은 옛 시드 방도 있어 길이만 본다). */
export function plausibleRoomId(id) {
  return typeof id === 'string' && id.length > 0 && id.length <= 64 && (UUID_RE.test(id) || /^[\w-]+$/.test(id));
}

/**
 * 일괄 초대에서 이 방을 건너뛰는 이유(코드) — 초대할 수 있으면 null.
 * - 'notMember': 방이 없거나 내가 멤버가 아니다(있는지 여부는 알려 주지 않는다).
 * - 'wrongTeam': 다른 팀의 방.
 * - 'notAllowed': 1:1·나와의 대화·비밀 대화(단건 초대와 같은 규칙).
 */
export function bulkInviteRoomError(room, { teamId, isMember }) {
  if (!room || !isMember) return 'notMember';
  if (room.teamId !== teamId) return 'wrongTeam';
  if (room.isSelf || room.isSecret || room.type === 'dm') return 'notAllowed';
  if (room.type !== 'topic' && room.type !== 'group') return 'notAllowed';
  return null;
}

/**
 * 초대 대상 분류(단건·일괄 공통) — [userIds] 중
 * - 이미 방 멤버면 alreadyMembers,
 * - 이 팀의 (존재하는) 멤버가 아니면 failed,
 * - 나머지는 toInvite.
 * [currentMemberIds]·[eligibleIds]는 Set.
 */
export function planInvite(userIds, currentMemberIds, eligibleIds) {
  const toInvite = [];
  const alreadyMembers = [];
  const failed = [];
  for (const id of userIds) {
    if (currentMemberIds.has(id)) alreadyMembers.push(id);
    else if (eligibleIds.has(id)) toInvite.push(id);
    else failed.push(id);
  }
  return { toInvite, alreadyMembers, failed };
}

export const INVITE_FAIL_NOT_TEAM_MEMBER = '이 팀의 멤버가 아닙니다.';
