import { randomUUID } from 'node:crypto';
import { Router } from 'express';
import {
  addRoomMembers,
  deleteRoom,
  findDmRoomByKey,
  findRoomById,
  getDmHistoryFloor,
  getMemberFavorite,
  getMemberHidden,
  getMemberMuted,
  getRoomLastReadMap,
  insertRoom,
  isRoomMember,
  listBrowsableTopics,
  listRoomMemberIds,
  listRoomMemberUsers,
  listRoomsForUser,
  removeRoomMember,
  setDmHistoryFloor,
  setMemberFavorite,
  setMemberHidden,
  setMemberMuted,
  setSecretDepartedMember,
} from './db/queries/rooms.js';
import { findTeamById, isTeamMember, listAutoJoinTeamMemberIds } from './db/queries/teams.js';
import { teamAccess } from './access.js';
import { canBrowseTopics, canCreateRooms, canCreateTopic } from './permissions.js';
import {
  countUnreadForUser,
  getLastMessageAt,
  getLastMessageForPreview,
  insertMessage,
  listMessagesByIds,
  listMessagesByRoom,
} from './db/queries/messages.js';
import {
  countUnreadCommentsForUser,
  getLastCommentAt,
  getLastCommentForPreview,
  listCommentsForMessages,
  listCommentsInRoomBetween,
} from './db/queries/comments.js';
import { findSecretSessionByRoomId } from './db/queries/secretSessions.js';
import { findUserById } from './db/queries/users.js';
import { publicUser } from './users.js';
import { toCommentDto } from './comments.js';
import { toMessageDto } from './messages.js';
import { previewFor, SECRET_PREVIEW_PLACEHOLDER } from './push.js';

async function resolveMembers(roomId) {
  return (await listRoomMemberUsers(roomId)).map(publicUser);
}

/** 시스템 메시지 문구("OOO 님이 참여했습니다" 등)에 쓸 표시 이름. 이름이 없으면 아이디로 대체. */
export async function nameOf(id) {
  const u = await findUserById(id);
  return u?.name ?? u?.username ?? '알 수 없음';
}

/**
 * requesterId를 넘기면 그 사람 기준 안읽음 개수(unreadCount)를 계산해 넣는다. 안읽음은
 * 보는 사람마다 값이 다르므로, 여러 멤버에게 동시에 뿌리는 브로드캐스트에는 절대 넣으면 안 되고
 * (requesterId 생략) 요청자 한 명에게만 가는 REST 응답에서만 넣는다(requesterId 전달).
 */
export async function toRoomDto(room, requesterId) {
  const [members, lastRead, lastMessageAt, lastCommentAt, lastMessageRow, lastCommentRow] = await Promise.all([
    resolveMembers(room.id),
    getRoomLastReadMap(room.id),
    getLastMessageAt(room.id),
    getLastCommentAt(room.id),
    getLastMessageForPreview(room.id),
    getLastCommentForPreview(room.id),
  ]);
  // 방 목록에서 카테고리 안 정렬 기준(누구에게나 동일한, 사용자 무관 값) — 로그인 직후에도
  // 오프라인 동안 쌓인 활동이 반영되도록, 실시간 소켓 없이도 방 목록 응답 자체에 이 시각을
  // 담아 보낸다(클라이언트 Room.lastActivityAt, desktop_home_screen.dart/room_list_screen.dart
  // 의 _favoriteFirst 정렬 참고).
  const lastActivityAt = Math.max(
    new Date(room.createdAt).getTime(),
    lastMessageAt ? new Date(lastMessageAt).getTime() : 0,
    lastCommentAt ? new Date(lastCommentAt).getTime() : 0,
  );
  // 그룹채팅/채팅 목록의 이름 아래 한 줄 미리보기(room_list_screen.dart) — 메시지/댓글 중 더
  // 최근 것을 고른다. 비밀 대화는 서버가 내용을 복호화할 수 없어 애초에 평문을 모르므로
  // push.js와 같은 고정 문구를 쓴다. 로그인 시점엔 이 값을 그대로 쓰고, 이후 실시간으로는
  // Session이 소켓으로 받은 메시지/댓글의 실제(복호화된) 내용으로 직접 갱신한다.
  let lastMessagePreview = null;
  if (room.isSecret) {
    if (lastMessageRow || lastCommentRow) lastMessagePreview = SECRET_PREVIEW_PLACEHOLDER;
  } else {
    const newerRow =
      lastMessageRow && lastCommentRow
        ? (new Date(lastMessageRow.createdAt) >= new Date(lastCommentRow.createdAt) ? lastMessageRow : lastCommentRow)
        : lastMessageRow ?? lastCommentRow;
    if (newerRow) lastMessagePreview = previewFor(newerRow);
  }
  const dto = {
    id: room.id,
    teamId: room.teamId,
    type: room.type,
    name: room.name,
    description: room.description ?? null,
    isPublic: room.type === 'topic' ? room.isPublic !== false : undefined,
    members,
    createdAt: new Date(room.createdAt).getTime(),
    lastRead,
    lastActivityAt,
    lastMessagePreview,
    isSecret: !!room.isSecret,
  };
  if (room.isSecret) {
    // 비밀 대화 상태(핸드셰이크 진행 여부/자동 삭제 타이머)도 방 목록에 실어 보낸다 —
    // 클라이언트가 매번 별도 조회 없이 RoomOptionsMenu의 타이머 표시나 초대 대기 UI에 바로
    // 쓸 수 있게. 공개키/서명만 포함되고 공유비밀/체인키는 여기 절대 없다.
    const session = await findSecretSessionByRoomId(room.id);
    dto.secretStatus = session?.status ?? null;
    dto.secretKeyEpoch = session?.keyEpoch ?? 0;
    dto.secretSelfDestructSeconds = session?.selfDestructSeconds ?? null;
    dto.secretInitiatorUserId = session?.initiatorUserId ?? null;
    // "상대방도 나가기" 없이 혼자 나간 경우, 남은 멤버 쪽에서 Room.displayName()이
    // "(알 수 없음)" 대신 "OOO님 (나갔음)"을 보여줄 수 있게 나간 사람 이름을 실어 보낸다.
    dto.secretDepartedMemberName = room.secretDepartedMemberName ?? null;
  }
  if (requesterId) {
    const myLastRead = lastRead[requesterId] ?? 0;
    // DM "진짜 나가기" 이력이 있으면 그 시각 이전 메시지는 안읽음 개수에도 안 세운다 —
    // getDmHistoryFloor 사용처(rooms.js의 /rooms/:id/messages) 참고.
    const floor = room.type === 'dm' ? await getDmHistoryFloor(room.id, requesterId) : null;
    // 로그아웃해 있는 동안 달린 댓글은 comment:new 소켓을 못 받아서 클라이언트가 실시간으로
    // unreadCount를 못 올리므로, 다시 로그인해서 방 목록을 받아올 때 이 REST 응답에서
    // 메시지·댓글 안읽음 수를 합쳐서 내려줘야 뱃지가 정확하다.
    const [unreadMessages, unreadComments] = await Promise.all([
      countUnreadForUser(room.id, requesterId, myLastRead, floor),
      countUnreadCommentsForUser(room.id, requesterId, myLastRead),
    ]);
    dto.unreadCount = unreadMessages + unreadComments;
    dto.favorite = await getMemberFavorite(room.id, requesterId);
    dto.muted = await getMemberMuted(room.id, requesterId);
    dto.hidden = room.type === 'dm' ? await getMemberHidden(room.id, requesterId) : false;
  }
  return dto;
}

export function dmKeyFor(userIdA, userIdB) {
  return [userIdA, userIdB].sort().join(':');
}

/** 방 멤버십이 바뀔 때 해당 유저들의 소켓을 즉시 방에 join시키고 알린다. */
export async function notifyMembership(io, room) {
  const memberIds = await listRoomMemberIds(room.id);
  const userRooms = memberIds.map((id) => `user:${id}`);
  if (userRooms.length > 0) io.in(userRooms).socketsJoin(room.id);
  io.to(room.id).emit('room:created', await toRoomDto(room));
}

/** 이 사람이 속한 모든 방(다른 기기 포함)에 갱신된 멤버 정보를 알린다 — 프로필/탈퇴 변경 후. */
export async function broadcastMemberUpdate(io, userId) {
  for (const room of await listRoomsForUser(userId)) {
    io.to(room.id).emit('room:created', await toRoomDto(room));
  }
}

/**
 * 평문 DM에 메시지/댓글이 새로 오면, 그 방을 숨겨둔(hidden) 상대 멤버는 자동으로 다시
 * 보이게 한다 — "숨기기"의 원래 의미(room_options_menu.dart: 다시 대화를 시작하면 예전
 * 내용이 그대로 복원됨)를 멤버십 변경 없이 재현한다(socket.js message:send, comments.js 참고).
 * 이 방에 대해서만, 개인 채널(user:<id>)로만 알린다 — 상대는 애초에 멤버십이 안 바뀌었으니
 * room:created(멤버 변경 브로드캐스트)를 보낼 필요가 없다.
 */
export async function unhideDmForOtherMembers(io, room, senderId) {
  if (room.type !== 'dm' || room.isSecret) return;
  const memberIds = await listRoomMemberIds(room.id);
  for (const userId of memberIds) {
    if (userId === senderId) continue;
    if (await getMemberHidden(room.id, userId)) {
      await setMemberHidden(room.id, userId, false);
      io.to(`user:${userId}`).emit('room:hidden', { roomId: room.id, hidden: false });
    }
  }
}

/** 참여/초대/퇴장 안내 문구를 일반 메시지처럼 저장하고 방에 브로드캐스트한다. */
export async function postSystemMessage(io, room, text) {
  const message = await insertMessage({
    id: randomUUID(),
    roomId: room.id,
    senderId: null, // 시스템 메시지는 작성자가 없다 — type='system'이 판별 기준.
    senderName: '시스템',
    type: 'system',
    text,
  });
  const dto = { ...message, createdAt: new Date(message.createdAt).getTime() };
  io.to(room.id).emit('message:new', dto);
  return dto;
}

export function createRoomsRouter(io) {
  const router = Router();

  /**
   * 방/토픽은 전부 팀 안에서만 의미가 있으므로, 팀을 가리키는 요청은 teamId를 받아서 내가 그
   * 팀의 멤버인지부터 확인한다. 통과하면 팀 id를, 아니면 응답까지 끝내고 null을 돌려준다.
   */
  async function requireTeamId(req, res, raw) {
    const teamId = typeof raw === 'string' ? raw : null;
    if (!teamId) {
      res.status(400).json({ error: 'teamId가 필요합니다.' });
      return null;
    }
    if (!(await isTeamMember(teamId, req.user.sub))) {
      res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
      return null;
    }
    return teamId;
  }

  /**
   * requireTeamId + 그 팀에서의 내 권한(계정 등급 + 소유자 여부)까지. 등급별 제한(준회원은
   * 방 생성/초대 불가 등)을 검사해야 하는 라우트가 쓴다. 통과하면 `{ teamId, ...access }`,
   * 아니면 응답까지 끝내고 null.
   */
  async function requireTeamRole(req, res, raw) {
    const teamId = typeof raw === 'string' ? raw : null;
    if (!teamId) {
      res.status(400).json({ error: 'teamId가 필요합니다.' });
      return null;
    }
    const access = await teamAccess(teamId, req.user.sub);
    if (!access.isMember) {
      res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
      return null;
    }
    return { teamId, ...access };
  }

  router.get('/rooms', async (req, res) => {
    const teamId = await requireTeamId(req, res, req.query.teamId);
    if (!teamId) return;
    const myRooms = await listRoomsForUser(req.user.sub, teamId);
    res.json(await Promise.all(myRooms.map((r) => toRoomDto(r, req.user.sub))));
  });

  // /rooms/:id 보다 먼저 등록해야 'browse'가 :id로 매칭되지 않습니다.
  // 공개 토픽은 누구에게나(나중에 가입한 회원 포함) 보이고, 비공개 토픽은 이미 멤버인
  // 사람에게만 보인다(초대로만 들어올 수 있음 — 자유 참여 불가는 /join에서 막는다).
  router.get('/rooms/browse', async (req, res) => {
    const scope = await requireTeamRole(req, res, req.query.teamId);
    if (!scope) return;
    const { teamId, role } = scope;
    // 준회원은 초대받은 방에서만 활동한다 — 찾아볼 토픽 자체가 없다(클라이언트도 "토픽 찾기"
    // 버튼을 감추지만, 서버에서도 빈 목록으로 못박는다).
    if (!canBrowseTopics(role)) return res.json([]);
    const rows = await listBrowsableTopics(req.user.sub, teamId);
    const withCounts = await Promise.all(
      rows.map(async ({ room, joined }) => ({
        id: room.id,
        name: room.name,
        description: room.description ?? null,
        isPublic: room.isPublic !== false,
        memberCount: (await listRoomMemberIds(room.id)).length,
        joined: !!joined,
      })),
    );
    res.json(withCounts);
  });

  router.post('/rooms/dm', async (req, res) => {
    const scope = await requireTeamRole(req, res, req.body?.teamId);
    if (!scope) return;
    const { teamId, role } = scope;
    // 준회원은 스스로 대화를 열 수 없다(초대받은 방에서만 활동). 반대 방향 — 정회원이
    // 준회원에게 말을 거는 것 — 은 막지 않는다.
    if (!canCreateRooms(role)) {
      return res.status(403).json({ error: '준회원은 대화를 시작할 수 없습니다. 초대받은 방에서만 활동할 수 있습니다.' });
    }
    const { targetUserId } = req.body ?? {};
    if (!targetUserId || typeof targetUserId !== 'string') {
      return res.status(400).json({ error: 'targetUserId가 필요합니다.' });
    }
    if (targetUserId === req.user.sub) {
      return res.status(400).json({ error: '자기 자신과는 DM을 시작할 수 없습니다.' });
    }
    const target = await findUserById(targetUserId);
    if (!target) return res.status(404).json({ error: '대상 사용자를 찾을 수 없습니다.' });
    // 1:1 대화도 팀 안에서만 만들어진다 — 상대가 그 팀 멤버가 아니면 시작할 수 없다.
    if (!(await isTeamMember(teamId, targetUserId))) {
      return res.status(403).json({ error: '이 팀의 멤버가 아닌 사람과는 대화를 시작할 수 없습니다.' });
    }

    const dmKey = dmKeyFor(req.user.sub, targetUserId);
    const existing = await findDmRoomByKey(teamId, dmKey);
    if (existing) {
      // 둘 중 한쪽이 예전에 "채팅방 나가기"를 했을 수 있으니, 다시 대화를 걸면 그 사람을 되살린다.
      const memberIds = await listRoomMemberIds(existing.id);
      const missing = [req.user.sub, targetUserId].filter((id) => !memberIds.includes(id));
      if (missing.length > 0) {
        await addRoomMembers(existing.id, missing);
        await notifyMembership(io, existing);
      }
      return res.status(200).json(await toRoomDto(existing, req.user.sub));
    }

    const room = await insertRoom({
      id: randomUUID(),
      teamId,
      type: 'dm',
      name: null,
      dmKey,
      createdBy: req.user.sub,
    });
    await addRoomMembers(room.id, [req.user.sub, targetUserId]);
    await notifyMembership(io, room);
    res.status(201).json(await toRoomDto(room, req.user.sub));
  });

  router.post('/rooms', async (req, res) => {
    const scope = await requireTeamRole(req, res, req.body?.teamId);
    if (!scope) return;
    const { teamId, role, isOwner } = scope;
    if (!canCreateRooms(role)) {
      return res.status(403).json({ error: '준회원은 방을 만들 수 없습니다. 초대받은 방에서만 활동할 수 있습니다.' });
    }
    const { type, name, description, memberIds, isPublic } = req.body ?? {};
    if (type !== 'topic' && type !== 'group') {
      return res.status(400).json({ error: "type은 'topic' 또는 'group'이어야 합니다 (DM은 /rooms/dm 사용)." });
    }
    // 토픽은 팀 설정(topicCreationPolicy)이 정한 등급 이상만 — 그룹채팅은 위 canCreateRooms
    // 체크(정회원 이상)로 이미 충분하고 이 설정과 무관하다(README "토픽 생성 권한" 참고).
    if (type === 'topic') {
      const team = await findTeamById(teamId);
      if (!canCreateTopic({ role, isOwner, team })) {
        const need = { admin: '관리자 이상', owner: '소유자' }[team?.topicCreationPolicy] ?? '정회원 이상';
        return res.status(403).json({ error: `이 팀은 ${need}만 토픽을 만들 수 있도록 설정되어 있습니다.` });
      }
    }
    const trimmedName = typeof name === 'string' ? name.trim() : '';
    if (type === 'topic' && !trimmedName) {
      return res.status(400).json({ error: '토픽 이름을 입력하세요.' });
    }

    const isPublicTopic = type === 'topic' && isPublic !== false;

    let roomMemberIds;
    if (isPublicTopic) {
      // 공개 토픽은 만드는 순간 그 팀 멤버 전원이 들어간다(나중에 팀에 들어오는 사람은
      // teams.js에서 그 팀의 공개 토픽 전체에 자동으로 추가된다). 준회원은 제외 —
      // 초대받은 방에만 들어간다.
      roomMemberIds = await listAutoJoinTeamMemberIds(teamId);
      if (!roomMemberIds.includes(req.user.sub)) roomMemberIds.push(req.user.sub);
    } else {
      const memberIdSet = new Set([req.user.sub, ...(Array.isArray(memberIds) ? memberIds : [])]);
      if (type === 'group' && memberIdSet.size < 2) {
        return res.status(400).json({ error: '그룹에는 나 이외의 멤버가 최소 1명 필요합니다.' });
      }
      roomMemberIds = [...memberIdSet];
    }

    const room = await insertRoom({
      id: randomUUID(),
      teamId,
      type,
      name: trimmedName || null,
      description: type === 'topic' && description ? String(description).trim() : null,
      // 공개 토픽은 지금 회원뿐 아니라 나중에 가입하는 회원에게도 계속 보인다(/rooms/browse).
      isPublic: type === 'topic' ? isPublic !== false : null,
      createdBy: req.user.sub,
    });
    await addRoomMembers(room.id, roomMemberIds);
    await notifyMembership(io, room);

    if (type === 'group') {
      const invitedIds = roomMemberIds.filter((id) => id !== req.user.sub);
      const invitedNames = await Promise.all(invitedIds.map(nameOf));
      if (invitedNames.length > 0) {
        await postSystemMessage(io, room, `${await nameOf(req.user.sub)} 님이 ${invitedNames.join(', ')} 님을 초대했습니다.`);
      }
    }

    res.status(201).json(await toRoomDto(room, req.user.sub));
  });

  router.post('/rooms/:id/join', async (req, res) => {
    const room = await findRoomById(req.params.id);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    if (room.type !== 'topic') return res.status(403).json({ error: '토픽방만 자유롭게 참여할 수 있습니다.' });
    if (room.isPublic === false) {
      return res.status(403).json({ error: '비공개 토픽은 초대를 통해서만 참여할 수 있습니다.' });
    }
    // 공개 토픽이라도 그 팀 사람만 들어갈 수 있고, 준회원은 스스로 참여할 수 없다.
    const joiner = await teamAccess(room.teamId, req.user.sub);
    if (!joiner.isMember) return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    if (!canBrowseTopics(joiner.role)) {
      return res.status(403).json({ error: '준회원은 초대받은 방에만 참여할 수 있습니다.' });
    }

    if (!(await isRoomMember(room.id, req.user.sub))) {
      await addRoomMembers(room.id, [req.user.sub]);
      await notifyMembership(io, room);
      await postSystemMessage(io, room, `${await nameOf(req.user.sub)} 님이 참여했습니다.`);
    }
    res.json(await toRoomDto(room, req.user.sub));
  });

  router.post('/rooms/:id/invite', async (req, res) => {
    const room = await findRoomById(req.params.id);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    if (room.type === 'dm') return res.status(403).json({ error: 'DM에는 멤버를 초대할 수 없습니다.' });
    if (!(await isRoomMember(room.id, req.user.sub))) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
    // 이미 있는 방에 멤버를 추가로 초대하는 건 팀 설정과 무관하게 정회원 이상이면 누구나 —
    // 준회원만 불가(canCreateRooms와 같은 기준). 새 토픽을 만드는 것과는 별개 규칙이다.
    const inviter = await teamAccess(room.teamId, req.user.sub);
    if (!canCreateRooms(inviter.role)) {
      return res.status(403).json({ error: '멤버를 초대할 권한이 없습니다.' });
    }

    const { userIds } = req.body ?? {};
    const currentMemberIds = await listRoomMemberIds(room.id);
    const candidateIds = (Array.isArray(userIds) ? userIds : []).filter(
      (id) => typeof id === 'string' && !currentMemberIds.includes(id),
    );
    const toInvite = [];
    for (const id of candidateIds) {
      // 방은 팀 안에만 있으므로, 그 팀 멤버만 초대할 수 있다.
      if ((await findUserById(id)) && (await isTeamMember(room.teamId, id))) toInvite.push(id);
    }
    if (toInvite.length === 0) {
      return res.status(400).json({ error: '초대할 멤버를 선택하세요.' });
    }

    await addRoomMembers(room.id, toInvite);
    await notifyMembership(io, room);

    const invitedNames = await Promise.all(toInvite.map(nameOf));
    await postSystemMessage(io, room, `${await nameOf(req.user.sub)} 님이 ${invitedNames.join(', ')} 님을 초대했습니다.`);

    res.json(await toRoomDto(room, req.user.sub));
  });

  router.post('/rooms/:id/leave', async (req, res) => {
    const room = await findRoomById(req.params.id);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    if (!(await isRoomMember(room.id, req.user.sub))) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });

    if (room.isSecret) {
      if (req.body?.alsoRemoveOther === true) {
        // "상대방도 나가기" 체크 — 방 자체를 완전히 지워서 양쪽 모두 나가진 것으로
        // 취급한다(메시지/멤버/비밀 세션은 전부 onDelete:'cascade'로 함께 삭제). 서버가
        // 내용을 못 보니, 상대만 남기고 나 혼자 지우면 상대는 이미 끊어진 세션을 계속
        // 들고 있게 된다는 문제를 이 옵션으로 확실히 해결한다.
        const memberIds = await listRoomMemberIds(room.id);
        io.to(room.id).emit('secret:left', { roomId: room.id });
        io.in(memberIds.map((id) => `user:${id}`)).socketsLeave(room.id);
        await deleteRoom(room.id);
        return res.json({ ok: true });
      }

      // 체크 안 함 — 나만 나간다.
      await removeRoomMember(room.id, req.user.sub);
      io.in(`user:${req.user.sub}`).socketsLeave(room.id); // socketsLeave 이후라 본인은 자기 퇴장 메시지를 안 받음.

      const remainingMemberIds = await listRoomMemberIds(room.id);
      if (remainingMemberIds.length === 0) {
        // 남은 멤버가 없으면(상대가 이미 먼저 혼자 나가있던 상태였다면) 아무도 못 보는
        // 방을 DB에 계속 남겨둘 이유가 없다 — 완전히 지운다.
        await deleteRoom(room.id);
        return res.json({ ok: true });
      }

      const leaver = await findUserById(req.user.sub);
      const updated = await setSecretDepartedMember(room.id, {
        userId: req.user.sub,
        name: leaver?.name ?? leaver?.username ?? '알 수 없음',
      });
      io.to(room.id).emit('room:created', await toRoomDto(updated)); // 남은 멤버의 멤버 목록+나간 사람 이름을 갱신시킨다.
      await postSystemMessage(io, room, '상대방이 비밀대화를 종료했습니다.');
      return res.json({ ok: true });
    }

    if (room.type === 'dm') {
      // 평문 DM의 "채팅방 숨기기"/"채팅방 나가기" — 상대방에게는 아무 영향이 없어야 한다는
      // 요구사항에 따라(room_options_menu.dart), 이제 진짜 멤버십을 건드리지 않는다. 예전엔
      // removeRoomMember로 나를 멤버에서 뺐는데, DM은 멤버가 나+상대 둘뿐이라 그러면 상대
      // 쪽 화면에서 방 이름이 "(알 수 없음)"이 되고(Room.displayName이 상대를 못 찾음),
      // 내 소켓이 그 방에서 나가버려서 상대가 보낸 메시지도 못 받는 문제가 있었다. 그래서
      // 이제 즐겨찾기/뮤트와 동일하게 순전히 내 개인 설정(hidden)으로만 다룬다 — 시스템
      // 메시지도, 상대에게 가는 브로드캐스트도 없다. 체크박스로 고른 "나가기"(진짜 나가기)면
      // 추가로 기록 시작선을 남겨서, 나중에 방이 다시 보여도 그 이전 내용은 안 보이게 한다
      // (getDmHistoryFloor 사용처 참고). "숨기기"(기본)는 이 시작선을 안 남기므로 상대가
      // 다시 말을 걸면 예전 내용이 그대로 복원된다.
      if (req.body?.realLeave === true) {
        await setDmHistoryFloor(room.id, req.user.sub);
      }
      await setMemberHidden(room.id, req.user.sub, true);
      // 즐겨찾기/뮤트와 동일하게, 이 사람의 다른 기기에도 같이 알려서 동기화한다(상대방에게는
      // 안 감 — user:<id> 채널이지 room 채널이 아니다).
      io.to(`user:${req.user.sub}`).emit('room:hidden', { roomId: room.id, hidden: true });
      return res.json({ ok: true });
    }

    // 그룹/토픽 — 진짜 멤버십이 없어지는 공개적인 이벤트라 지금까지처럼 실제로 나간다.
    await removeRoomMember(room.id, req.user.sub);

    io.in(`user:${req.user.sub}`).socketsLeave(room.id); // 나간 사람은 이후 이 방 메시지를 더 이상 받지 않게.
    await postSystemMessage(io, room, `${await nameOf(req.user.sub)} 님이 나갔습니다.`); // socketsLeave 이후라 본인은 자기 퇴장 메시지를 안 받음.
    io.to(room.id).emit('room:created', await toRoomDto(room)); // 남은 멤버들의 목록을 갱신시킨다.

    res.json({ ok: true });
  });

  // 즐겨찾기는 나 혼자만의 표시 설정이라 방 멤버 전체가 아니라 내 다른 기기(user:<id> 룸)에만 알린다.
  router.post('/rooms/:id/favorite', async (req, res) => {
    const room = await findRoomById(req.params.id);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    if (!(await isRoomMember(room.id, req.user.sub))) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });

    const favorite = req.body?.favorite === true;
    await setMemberFavorite(room.id, req.user.sub, favorite);
    io.to(`user:${req.user.sub}`).emit('room:favorite', { roomId: room.id, favorite });
    res.json(await toRoomDto(room, req.user.sub));
  });

  // 알림 끄기도 즐겨찾기와 같은 이유로 내 다른 기기(user:<id> 룸)에만 알린다.
  router.post('/rooms/:id/muted', async (req, res) => {
    const room = await findRoomById(req.params.id);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    if (!(await isRoomMember(room.id, req.user.sub))) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });

    const muted = req.body?.muted === true;
    await setMemberMuted(room.id, req.user.sub, muted);
    io.to(`user:${req.user.sub}`).emit('room:muted', { roomId: room.id, muted });
    res.json(await toRoomDto(room, req.user.sub));
  });

  router.get('/rooms/:id', async (req, res) => {
    const room = await findRoomById(req.params.id);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    if (!(await isRoomMember(room.id, req.user.sub))) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
    res.json(await toRoomDto(room, req.user.sub));
  });

  router.get('/rooms/:id/messages', async (req, res) => {
    const room = await findRoomById(req.params.id);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    if (!(await isRoomMember(room.id, req.user.sub))) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });

    const limit = Math.min(Number(req.query.limit) || 50, 200);
    // 클라이언트가 보내는 epoch ms(가장 오래 불러온 메시지의 createdAt) — "위로 스크롤해서
    // 더 불러오기"/검색으로 오래된 메시지 찾기(before로 여러 번 페이지네이션)에 쓴다.
    const beforeMs = Number(req.query.before);
    const before = Number.isFinite(beforeMs) && beforeMs > 0 ? new Date(beforeMs) : undefined;
    // DM "진짜 나가기" 이력이 있으면(dm_history_floors) 그 시각 이전 메시지는 이 요청자에게
    // 아예 없는 것처럼 뺀다 — room_options_menu.dart의 나가기 대화상자 참고.
    const floor = room.type === 'dm' ? await getDmHistoryFloor(room.id, req.user.sub) : null;
    const rows = await listMessagesByRoom(room.id, limit, before, floor);

    // 이 창의 시간대에 달린 댓글 중 부모 메시지가 창 밖(더 오래됨)에 있는 것들의 부모를 추가로
    // 끌어온다. 옛날 메시지에 오늘 댓글을 달면 그렇게 되는데, 부모가 없으면 클라이언트가 댓글
    // 카드를 아예 안 그린다(chat_panel.dart의 parent == null 분기). 이 추가분은 창(페이지)의
    // 일부가 아니므로 outOfWindow로 표시해서, 클라이언트가 "다음 페이지" 커서를 잡을 때
    // 이것들 때문에 중간 메시지를 건너뛰지 않게 한다.
    const inWindowIds = new Set(rows.map((m) => m.id));
    let extraParents = [];
    let windowComments = [];
    if (rows.length > 0) {
      windowComments = await listCommentsInRoomBetween(room.id, rows[0].createdAt, before);
      const missingParentIds = [
        ...new Set(windowComments.map((c) => c.messageId).filter((id) => !inWindowIds.has(id))),
      ];
      extraParents = await listMessagesByIds(missingParentIds);
      // floor보다 오래된 부모는(=이 요청자가 real leave로 못 보게 된 메시지) 여기로도
      // 새면 안 된다 — 위 listMessagesByRoom의 floor 필터를 그대로 한 번 더 적용한다.
      if (floor) extraParents = extraParents.filter((m) => m.createdAt >= floor);
    }

    const commentsByMessageId = new Map();
    const pushComment = (c) => {
      const list = commentsByMessageId.get(c.messageId) ?? [];
      list.push(toCommentDto(c));
      commentsByMessageId.set(c.messageId, list);
    };
    for (const c of await listCommentsForMessages(rows.map((m) => m.id))) pushComment(c);
    // 창 밖 부모에는 이 창 시간대의 댓글만 붙인다 — 그 부모의 옛 댓글까지 다 보내면 창과
    // 상관없는 옛 댓글 카드가 목록 맨 위에 뜬금없이 끼어든다.
    const extraParentIds = new Set(extraParents.map((m) => m.id));
    for (const c of windowComments) {
      if (extraParentIds.has(c.messageId)) pushComment(c);
    }

    // 저장은 항상 원본 상대경로(/uploads/xxx)로 해두고, 응답에 낼 때만 매번 새로 서명한다
    // (DB에 서명된 URL을 그대로 저장하면 나중에 다시 조회할 때 이미 만료돼있게 된다).
    res.json(
      [...extraParents, ...rows].map((m) => ({
        ...toMessageDto(m),
        comments: commentsByMessageId.get(m.id) ?? [],
        outOfWindow: extraParentIds.has(m.id),
      })),
    );
  });

  return router;
}
