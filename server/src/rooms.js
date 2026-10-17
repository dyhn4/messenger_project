import { randomUUID } from 'node:crypto';
import { Router } from 'express';
import ExcelJS from 'exceljs';
import {
  addRoomMembers,
  convertGroupToTopic,
  countTopicFolders,
  deleteRoom,
  deleteTopicFolder,
  ensureSelfRoom,
  findDmRoomByKey,
  findRoomById,
  findTopicFolderById,
  getDmHistoryFloor,
  getMemberFavorite,
  getMemberHidden,
  getMemberLastReadAnnouncementAt,
  getMemberMuted,
  getMemberCustomName,
  setMemberCustomName,
  getRoomLastReadMap,
  insertRoom,
  insertTopicFolder,
  isRoomMember,
  listBrowsableTopics,
  listRoomMemberIds,
  listRoomMemberRoles,
  listRoomMemberUsers,
  listRoomMemberUsersWithOrg,
  listRoomsForUser,
  listTopicFolderRoomIds,
  listTopicFolders,
  listTopicSummaries,
  removeMemberFromRoom,
  removeRoomMembers,
  reorderTopicFolders,
  setDmHistoryFloor,
  setMemberFavorite,
  setMemberHidden,
  setMemberMuted,
  setRoomAdmins,
  setSecretDepartedMember,
  setTopicFolder,
  updateRoom,
  updateTopicFolder,
  withRoomLock,
} from './db/queries/rooms.js';
import { countUnreadMentionsInRoom } from './db/queries/notifications.js';
import { findTeamById, isTeamMember, isTopicCreator, listTeamMemberIds } from './db/queries/teams.js';
import { teamAccess, topicAccess } from './access.js';
import { AUDIT, recordAudit } from './audit.js';
import { endRoomCallAccess, endUserCallAccess } from './callAccess.js';
import {
  accountRole,
  canBrowseTopics,
  canCreateRooms,
  canCreateTopic,
  canManageTeam,
  graphemeLength,
  GROUP_DESCRIPTION_MAX,
  GROUP_NAME_MAX,
  SELF_ROOM_DENIAL,
  TOPIC_DESCRIPTION_MAX,
  TOPIC_FOLDER_MAX_PER_TEAM,
  TOPIC_FOLDER_NAME_MAX,
  TOPIC_NAME_MAX,
} from './permissions.js';
import {
  countUnreadForUser,
  getLastMessageAt,
  getLastMessageForPreview,
  insertMessage,
  iterateMessagesForExport,
  listAttachmentsForMessages,
  listMessagesByIds,
  listMessagesByRoom,
  listPinnedPosts,
} from './db/queries/messages.js';
import {
  countUnreadCommentsForUser,
  getLastCommentAt,
  getLastCommentForPreview,
  listCommentsForMessages,
  listCommentsInRoomBetween,
} from './db/queries/comments.js';
import { findSecretSessionByRoomId } from './db/queries/secretSessions.js';
import { secretRoomFields } from './secretContextRules.js';
import { getServerSettings } from './db/queries/serverSettings.js';
import { findUserById } from './db/queries/users.js';
import { publicUser } from './users.js';
import { toCommentDto } from './comments.js';
import { toMessageDto } from './messages.js';
import { attachPolls } from './polls.js';
import { attachReactions } from './reactions.js';
import { notifyOfflineMembers, previewFor, roomTagFor, SECRET_PREVIEW_PLACEHOLDER } from './push.js';
import { latestAnnouncementDtoFor } from './announcements.js';
import { checkIconRef } from './fileRefs.js';
import { signFileUrl } from './upload.js';
import { countUnreadAnnouncementsForUser } from './db/queries/announcements.js';
import { readPostIdsOf } from './db/queries/board.js';
import { boardCategoriesOf, parseBoardCategories } from './boardRules.js';
import { listScheduledForRoom } from './db/queries/scheduledMessages.js';
import { failScheduledForArchivedTopic, failScheduledForDeletedRoom } from './scheduledMessages.js';
import {
  bulkInviteRoomError,
  convertDenial,
  convertNotice,
  INVITE_FAIL_NOT_TEAM_MEMBER,
  parseConvertBody,
  parseInviteBulkBody,
  planInvite,
  plausibleRoomId,
} from './roomInviteRules.js';

/** teams.js의 memberListResponse와 같은 규칙 — 서버 설정(orgScope)에 따라 팀 값(team_members)
 * 또는 계정 값(users) 중 하나를 부서/직책으로 쓴다. 채팅방 상단 헤더/방 목록의 직책 표시
 * (desktop_home_screen.dart)가 이 값을 쓴다 — publicUser()에는 원래 이 필드가 없다(팀마다
 * 다를 수 있는 값이라 방이 속한 팀을 모르면 어느 값을 써야 할지 정할 수 없어서, 방 단위로만
 * 계산하는 여기서 얹는다).
 * 토픽 관리자 id 목록(adminIds)도 같은 조회에서 뽑는다 — 멤버마다 따로 조회하지 않도록. */
async function resolveMembers(roomId, teamId) {
  const [rows, settings] = await Promise.all([
    listRoomMemberUsersWithOrg(roomId, teamId),
    getServerSettings(),
  ]);
  const byTeam = settings.orgScope !== 'account';
  return {
    members: rows.map((u) => ({
      ...publicUser(u),
      department: (byTeam ? u.teamDepartment : u.department) ?? null,
      position: (byTeam ? u.teamPosition : u.position) ?? null,
      // 그 팀의 소유자인지 — 토픽 "참여 멤버" 목록의 '소유자' 배지·정렬, 내보내기 권한 표시에 쓴다.
      isOwner: u.isTeamOwner === true,
    })),
    adminIds: rows.filter((u) => u.roomRole === 'admin').map((u) => u.id),
  };
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** 사이드바 토픽 폴더(개인 설정) — roomIds는 내가 멤버인 토픽만. */
function toTopicFolderDto(folder, roomIds = folder.roomIds ?? []) {
  return {
    id: folder.id,
    name: folder.name,
    position: folder.position,
    collapsed: folder.collapsed,
    roomIds,
  };
}

/** 토픽 이름 — 앞뒤 공백을 빼고 1~60자(글자 단위 — 앱 입력창의 글자 수 표시와 같은 기준). */
function parseTopicName(raw) {
  const name = typeof raw === 'string' ? raw.trim() : '';
  if (!name) return { error: '토픽 이름을 입력하세요.' };
  if (graphemeLength(name) > TOPIC_NAME_MAX) return { error: `토픽 이름은 ${TOPIC_NAME_MAX}자 이내로 입력하세요.` };
  return { name };
}

/** 토픽 설명 — 없거나 비면 null, 앞뒤 공백을 빼고 300자까지. 통과하면 `{ value }`. */
function parseTopicDescription(raw) {
  if (raw == null) return { value: null };
  if (typeof raw !== 'string') return { error: '토픽 설명이 올바르지 않습니다.' };
  const value = raw.trim();
  if (graphemeLength(value) > TOPIC_DESCRIPTION_MAX) {
    return { error: `토픽 설명은 ${TOPIC_DESCRIPTION_MAX}자 이내로 입력하세요.` };
  }
  return { value: value || null };
}

/** 그룹채팅 이름 — 선택(비우면 null = 멤버 이름으로 표시), 앞뒤 공백을 빼고 60자까지(토픽과 같은 글자 단위). */
function parseGroupName(raw) {
  if (raw == null) return { value: null };
  if (typeof raw !== 'string') return { error: '그룹 채팅 이름이 올바르지 않습니다.' };
  const value = raw.trim();
  if (graphemeLength(value) > GROUP_NAME_MAX) {
    return { error: `그룹 채팅 이름은 ${GROUP_NAME_MAX}자 이내로 입력하세요.` };
  }
  return { value: value || null };
}

/** 그룹채팅 설명 — 선택, 앞뒤 공백을 빼고 300자까지. 비면 null. */
function parseGroupDescription(raw) {
  if (raw == null) return { value: null };
  if (typeof raw !== 'string') return { error: '설명이 올바르지 않습니다.' };
  const value = raw.trim();
  if (graphemeLength(value) > GROUP_DESCRIPTION_MAX) {
    return { error: `설명은 ${GROUP_DESCRIPTION_MAX}자 이내로 입력하세요.` };
  }
  return { value: value || null };
}

const GROUP_ICON_TYPES = ['members', 'initial', 'emoji', 'photo'];
const GROUP_ICON_KEYS = ['iconType', 'iconEmoji', 'iconColor', 'iconUrl'];

// 그룹 아이콘 사진을 받을 수 없을 때 — 알아볼 수 없는 링크와 이 사람이 쓸 수 없는 파일을 가리지 않는다(어떤 파일이 있는지 알려 주지 않게).
const GROUP_ICON_ERROR = '그룹 아이콘 사진이 올바르지 않습니다. 다시 올려주세요.';

/**
 * 그룹채팅 아이콘 — 'members'(기본, null과 같음 — 멤버 아바타를 겹쳐 보여줌) | 'initial'(그룹 이름 앞 2글자) |
 * 'emoji'(iconEmoji 필수) | 'photo'(iconUrl 필수 — 업로드 응답의 URL). iconColor는 initial·emoji의 배경색이다.
 * 만들 때(POST /rooms)와 정보 변경(PATCH)이 같이 쓴다. 통과하면 저장할 네 칸 `{ icon }`, 아니면 `{ error }`.
 * 사진은 [userId]가 올린 사진, 지금 아이콘([currentIconUrl] — 정보 변경 때. 방 정보를 받은 지 오래돼 서명 링크가 만료된 채
 * 돌아와도), 서명 링크로 온 지금 볼 수 있는 방의 사진만 받는다(fileRefs.js — 검토 S22). 예전엔 어디서 알게 된 파일
 * 이름(/uploads/<이름>)도 그대로 받아, 그 그룹 멤버 모두가 그 파일의 새 링크를 영영 받을 수 있었다.
 */
async function parseGroupIcon({ iconType, iconEmoji, iconColor, iconUrl }, { userId, currentIconUrl = null }) {
  if (iconType != null && !GROUP_ICON_TYPES.includes(iconType)) return { error: 'iconType이 올바르지 않습니다.' };
  if (iconType === 'emoji' && (typeof iconEmoji !== 'string' || !iconEmoji)) return { error: '이모지를 선택하세요.' };
  let storedIconUrl = null;
  if (iconType === 'photo') {
    const photo = await checkIconRef(iconUrl, { senderId: userId, currentIconUrl, error: GROUP_ICON_ERROR });
    if (!photo.ok) return { error: photo.error };
    storedIconUrl = photo.path;
  }
  return {
    icon: {
      iconType: iconType && iconType !== 'members' ? iconType : null,
      iconEmoji: iconType === 'emoji' ? String(iconEmoji) : null,
      iconColor:
        (iconType === 'emoji' || iconType === 'initial') && typeof iconColor === 'string' && iconColor
          ? iconColor
          : null,
      iconUrl: storedIconUrl,
    },
  };
}

/** 시스템 메시지 문구("OOO 님이 참여했습니다" 등)에 쓸 표시 이름. 이름이 없으면 아이디로 대체. */
export async function nameOf(id) {
  const u = await findUserById(id);
  return u?.name ?? u?.username ?? '알 수 없음';
}

/**
 * 서버가 방 이름을 글로 써야 할 때(검색 결과, 예약 메시지 목록) — 클라이언트 Room.displayName()과 같은 규칙:
 * 나와의 대화는 '나와의 대화', 이름이 있으면 그대로, DM은 상대방 이름, 이름 없는 그룹은 [viewerId]를 뺀 나머지
 * 멤버 이름을 이름순으로 나열.
 */
export async function roomDisplayName(room, viewerId) {
  if (room.isSelf) return '나와의 대화';
  if (room.name) return room.name;
  const members = await listRoomMemberUsers(room.id);
  if (room.type === 'dm') {
    const other = members.find((m) => m.id !== viewerId);
    if (other) return other.name ?? '(알 수 없음)';
    // 상대가 빠진 1:1 대화(비밀 대화 혼자 나가기·팀에서 제외 — removeMemberFromRoom)는 남겨 둔 이름으로.
    return room.secretDepartedMemberName ? `${room.secretDepartedMemberName} (나갔음)` : '(알 수 없음)';
  }
  const names = members
    .filter((m) => m.id !== viewerId)
    .map((m) => m.name)
    .filter(Boolean)
    .sort();
  return names.length > 0 ? names.join(', ') : '(알 수 없음)';
}

/**
 * requesterId를 넘기면 그 사람 기준 안읽음 개수(unreadCount)를 계산해 넣는다. 안읽음은
 * 보는 사람마다 값이 다르므로, 여러 멤버에게 동시에 뿌리는 브로드캐스트에는 절대 넣으면 안 되고
 * (requesterId 생략) 요청자 한 명에게만 가는 REST 응답에서만 넣는다(requesterId 전달).
 */
export async function toRoomDto(room, requesterId) {
  const [{ members, adminIds }, lastRead, lastMessageAt, lastCommentAt, lastMessageRow, lastCommentRow] = await Promise.all([
    resolveMembers(room.id, room.teamId),
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
  // 그 미리보기를 보낸 사람 이름 — 알림 센터 "메시지" 탭이 그룹·토픽에서 "이름: 미리보기"로 보여 준다.
  let lastMessageSenderName = null;
  if (room.isSecret) {
    if (lastMessageRow || lastCommentRow) lastMessagePreview = SECRET_PREVIEW_PLACEHOLDER;
  } else {
    const newerRow =
      lastMessageRow && lastCommentRow
        ? (new Date(lastMessageRow.createdAt) >= new Date(lastCommentRow.createdAt) ? lastMessageRow : lastCommentRow)
        : lastMessageRow ?? lastCommentRow;
    if (newerRow) {
      lastMessagePreview = previewFor(newerRow);
      lastMessageSenderName = newerRow.senderName ?? null;
    }
  }
  const isTopic = room.type === 'topic';
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
    lastMessageSenderName,
    isSecret: !!room.isSecret,
    // 나와의 대화(나 혼자만 멤버인 DM) — 클라이언트가 '나와의 대화'로 이름 붙이고 채팅 목록 맨 위에 고정한다.
    isSelf: !!room.isSelf,
    // 토픽방 채팅 화면 상단 배너용 — 방을 열 때 별도 요청 없이 바로 그릴 수 있게 방 DTO에
    // 얹는다(announcements.js의 latestAnnouncementDtoFor). 그룹/DM은 공지가 없는 기능이라
    // 쿼리 자체를 건너뛴다.
    latestAnnouncement:
      room.type === 'topic' ? await latestAnnouncementDtoFor(room.id) : null,
    // 그룹채팅 아이콘(room_avatar.dart) — 'members'/null이면 기존처럼 멤버 아바타를 겹쳐
    // 보여준다. 토픽/DM은 항상 null.
    iconType: room.iconType ?? null,
    iconEmoji: room.iconEmoji ?? null,
    iconColor: room.iconColor ?? null,
    iconUrl: signFileUrl(room.iconUrl) ?? null,
    // 토픽 설정(schema.js rooms 참고) — 그룹/DM은 항상 기본값이다. 클라이언트가 이 값으로 보드 뷰,
    // 읽기 전용 입력창, '보관된 토픽' 묶음, 토픽 관리 메뉴(adminIds + 팀 관리자)를 그린다.
    viewMode: isTopic && room.viewMode === 'board' ? 'board' : 'chat',
    readOnly: isTopic && !!room.readOnly,
    autoInvite: isTopic && room.isPublic !== false && !!room.autoInvite,
    quietLeave: isTopic && !!room.quietLeave,
    archived: isTopic && !!room.archivedAt,
    archivedAt: isTopic && room.archivedAt ? new Date(room.archivedAt).getTime() : null,
    adminIds: isTopic ? adminIds : [],
    // 보드 뷰 토픽의 말머리 목록(boardRules.js) — 다른 방은 [].
    boardCategories: boardCategoriesOf(room),
    createdBy: room.createdBy ?? null,
  };
  if (room.isSecret) {
    // 비밀 대화 상태(핸드셰이크 진행 여부/자동 삭제 타이머)도 방 목록에 실어 보낸다 —
    // 클라이언트가 매번 별도 조회 없이 RoomOptionsMenu의 타이머 표시나 초대 대기 UI에 바로
    // 쓸 수 있게. 양쪽 사용자·기기 id도 싣는다(앱이 상대 기기를 기억해 두지 않았던 예전 대화를 그 기기에 묶는 데 쓴다).
    // 공개키·서명·공유비밀/체인키는 여기 절대 없다 — 칸 목록은 secretContextRules.js의 secretRoomFields.
    const session = await findSecretSessionByRoomId(room.id);
    Object.assign(dto, secretRoomFields(session));
  }
  if (room.type === 'dm' && !room.isSelf) {
    // 1:1 대화에서 한 사람이 빠진 경우(비밀 대화를 "상대방도 나가기" 없이 혼자 나감, 팀에서 제외됨) 남은 멤버 쪽에서
    // Room.displayName()이 "(알 수 없음)" 대신 "OOO님 (나갔음)"을 보여줄 수 있게 나간 사람 이름을 실어 보낸다
    // (removeMemberFromRoom 참고 — 필드 이름은 비밀 대화에만 쓰던 시절 그대로다).
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
    // 이 방에서 내가 읽지 않은 멘션 알림 수 — 방 목록의 안읽음 옆 "@" 표시(notifications.js).
    dto.unreadMentionCount = await countUnreadMentionsInRoom(requesterId, room.id);
    dto.favorite = await getMemberFavorite(room.id, requesterId);
    dto.muted = await getMemberMuted(room.id, requesterId);
    dto.customName = room.type === 'group' ? await getMemberCustomName(room.id, requesterId) : null;
    dto.hidden = room.type === 'dm' ? await getMemberHidden(room.id, requesterId) : false;
    // 알림 센터에 "안 읽은 공지"로 띄울지 — 내가 직접 쓴 글이면 읽은 걸로 치고, 공지 목록/
    // 상세를 실제로 열어본 적(lastReadAnnouncementAt) 없이 그보다 최근에 올라온 고정 공지가
    // 있으면 true. 방에 들어와 있기만 해도 올라가는 일반 lastRead와는 다른 값을 쓴다.
    const lastReadAnnouncementAt = await getMemberLastReadAnnouncementAt(room.id, requesterId);
    dto.hasUnreadAnnouncement =
      dto.latestAnnouncement != null &&
      dto.latestAnnouncement.authorId !== requesterId &&
      lastReadAnnouncementAt < dto.latestAnnouncement.createdAt;
    // 알림 센터 배지 숫자 — 안 읽은 공지가 여러 개일 수 있다(전엔 있으면 무조건 1로 셌다).
    dto.unreadAnnouncementCount = dto.hasUnreadAnnouncement
      ? Math.max(1, await countUnreadAnnouncementsForUser(room.id, requesterId, new Date(lastReadAnnouncementAt)))
      : 0;
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

/**
 * 멤버가 바뀌어(나가기·내보내기·참여·초대) 전체 진척률이 다시 맞춰진 할 일들([todos] — db/queries/rooms.js의
 * removeRoomMembers/addRoomMembers가 돌려준 행)을 지금 그 방 멤버 모두의 user:<id>에 todo:changed(kind 'updated')로
 * 알린다 — 열려 있는 할 일 패널·상세가 다시 받는다(todos.js emitChanged와 같은 모양, 새로 지정된 담당자는 없음).
 */
export async function notifyTodosResynced(io, room, todos, actorId) {
  if (!todos || todos.length === 0) return;
  const memberIds = await listRoomMemberIds(room.id);
  for (const todo of todos) {
    const payload = {
      teamId: todo.teamId,
      roomId: todo.roomId,
      todoId: todo.id,
      kind: 'updated',
      actorId,
      title: todo.title,
      addedAssigneeIds: [],
    };
    for (const id of memberIds) io.to(`user:${id}`).emit('todo:changed', payload);
  }
}

/**
 * 나와의 대화를 찾거나 만든다(db/queries/rooms.js ensureSelfRoom). 이번에 새로 만들었거나 멤버로 다시 넣었으면(팀에서
 * 빠졌다가 돌아옴) 그 사람의 소켓(모든 기기)을 방에 넣고 room:created로 알린다 — 다른 방이 새로 생길 때와 같은
 * 경로(notifyMembership).
 */
export async function openSelfRoom(io, userId, teamId) {
  const { room, joined } = await ensureSelfRoom(userId, teamId);
  if (joined) await notifyMembership(io, room);
  return room;
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

function uniqueStringIds(raw) {
  return Array.isArray(raw) ? [...new Set(raw.filter((id) => typeof id === 'string' && id))] : [];
}

/**
 * 한 방에 멤버를 초대하는 공통 경로(POST /rooms/:id/invite 단건, POST /rooms/invite-bulk 일괄) — 이미 멤버인
 * 사람과 이 팀 멤버가 아닌 사람을 가려내고, 나머지를 추가한 뒤 소켓 알림(notifyMembership)과 "OOO 님이 …
 * 초대했습니다" 시스템 메시지를 남긴다. 호출부가 방 멤버십·정회원 등급을 이미 확인했어야 한다.
 * 일괄 초대는 방마다 부르므로 팀 멤버 id 집합([teamMemberIds])과 이름 캐시([nameCache])를 넘겨 재조회를 줄인다.
 * 돌려주는 값: `{ invited, alreadyMembers, failed }` — 각 `{ userId, name }`(failed는 reason도).
 */
export async function inviteMembersToRoom(io, room, inviterId, userIds, { teamMemberIds, nameCache } = {}) {
  const [currentMemberIds, eligibleIds] = await Promise.all([
    listRoomMemberIds(room.id),
    teamMemberIds ?? listTeamMemberIds(room.teamId),
  ]);
  const plan = planInvite(userIds, new Set(currentMemberIds), new Set(eligibleIds));
  const names = nameCache ?? new Map();
  const nameFor = async (id) => {
    if (!names.has(id)) names.set(id, await nameOf(id));
    return names.get(id);
  };
  const withName = async (id) => ({ userId: id, name: await nameFor(id) });

  if (plan.toInvite.length > 0) {
    const changedTodos = await addRoomMembers(room.id, plan.toInvite);
    await notifyMembership(io, room);
    await notifyTodosResynced(io, room, changedTodos, inviterId); // 다시 들어온 담당자가 있던 할 일.
    const invitedNames = await Promise.all(plan.toInvite.map(nameFor));
    await postSystemMessage(io, room, `${await nameFor(inviterId)} 님이 ${invitedNames.join(', ')} 님을 초대했습니다.`);
  }
  return {
    invited: await Promise.all(plan.toInvite.map(withName)),
    alreadyMembers: await Promise.all(plan.alreadyMembers.map(withName)),
    failed: await Promise.all(
      plan.failed.map(async (id) => ({ ...(await withName(id)), reason: INVITE_FAIL_NOT_TEAM_MEMBER })),
    ),
  };
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

/**
 * 사람이 아닌 발신자(프로젝트 자동화 등)의 글을 일반 텍스트 메시지로 올린다. 시스템 메시지와
 * 달리 안읽음 숫자·방 목록 미리보기·데스크톱/모바일 알림이 사람 메시지와 똑같이 나가야 해서
 * socket.js의 message:send와 같은 순서(숨긴 DM 되살리기 → message:new → 푸시)로 보낸다.
 * senderId가 null이라 누구의 "내 메시지"도 아니고, 푸시에서 보낸 사람으로 빠지는 멤버도 없다.
 */
export async function postBotMessage(io, room, text, { senderName, reminderCard = null, integrationId = null, botEmoji = null }) {
  const message = await insertMessage({
    id: randomUUID(),
    roomId: room.id,
    senderId: null,
    senderName,
    type: 'text',
    text,
    // 메시지 리마인더가 울릴 때 붙는 원본 메시지 카드(reminders.js) — 그 밖에는 null.
    reminderCard,
    // 외부 연동(웹훅·슬래시 명령 — integrations.js)이 올린 봇 메시지의 연동과 아이콘 — 그 밖에는 null.
    integrationId,
    botEmoji,
  });
  await unhideDmForOtherMembers(io, room, null);
  const dto = toMessageDto(message);
  io.to(room.id).emit('message:new', dto);
  // 푸시는 기다리지 않는다(socket.js와 같은 이유) — 실패해도 메시지는 이미 올라갔다.
  listRoomMemberIds(room.id)
    .then((memberIds) =>
      notifyOfflineMembers({
        memberIds,
        senderId: null,
        senderName,
        sender: null,
        room,
        entry: message,
        roomTag: roomTagFor(room),
        kind: 'message',
      }),
    )
    .catch((err) => console.error('[push] 자동 메시지 알림 실패:', err?.message ?? err));
  return dto;
}

/** 비밀 대화에서 한쪽이 빠졌을 때 남은 쪽에 남기는 안내 — 혼자 나가기와 팀에서 제외될 때가 같은 문구를 쓴다(시스템
 * 메시지는 평문이고 클라이언트도 복호화를 건너뛰므로 비밀 대화에 그대로 남겨도 된다 — secretChats.js 참고). */
const SECRET_CHAT_ENDED_NOTICE = '상대방이 비밀대화를 종료했습니다.';

/**
 * 누가 방에서 빠진 뒤(db/queries/rooms.js removeMemberFromRoom의 결과) 남은 멤버들에게 알린다 — 바뀐 방 정보(멤버 목록·
 * 토픽 관리자·1:1 대화의 "(나갔음)" 이름), 다시 맞춰진 할 일 진척률, [notice](null이면 안내 없음) 순서로. 방째 지워졌거나
 * 남은 사람이 없으면 알릴 사람이 없다. 빠진 사람의 소켓은 호출부가 먼저 방에서 빼 둬야 자기 퇴장 안내를 받지 않는다.
 */
async function notifyRoomAfterDeparture(io, removal, { actorId, notice }) {
  const { room, deleted, remainingMemberIds, changedTodos } = removal;
  if (deleted || remainingMemberIds.length === 0) return;
  io.to(room.id).emit('room:created', await toRoomDto(room));
  await notifyTodosResynced(io, room, changedTodos, actorId);
  if (notice) await postSystemMessage(io, room, notice);
}

/** 팀에서 제외돼 방에서 빠졌다는 안내 — 비밀 대화는 혼자 나가기와 같은 문구, 나와의 대화는 남는 사람이 없어서, 조용히
 * 나가기 토픽은 설정대로 안내가 없다. [leftover]는 서버를 켤 때 남은 멤버십을 정리한 경우(teams.js
 * sweepLeftoverTeamRoomMembers) — 언제 어떻게 팀 밖이 됐는지 모르므로(예전엔 그룹에 팀 밖 사람을 넣을 수도 있었다) 지금
 * 사실인 "팀 멤버가 아니어서"라고 쓴다. */
function teamRemovalNotice(room, userName, { leftover = false } = {}) {
  if (room.isSelf) return null;
  if (room.isSecret) return SECRET_CHAT_ENDED_NOTICE;
  if (room.quietLeave) return null;
  return leftover ? `${userName} 님이 팀 멤버가 아니어서 나갔습니다.` : `${userName} 님이 팀에서 제외되어 나갔습니다.`;
}

/**
 * 팀에서 제외된 사람([userId])이 그 팀의 모든 방에서 빠진 뒤(db/queries/teams.js removeTeamMember가 돌려준 [removals])의
 * 실시간 정리 — 토픽 내보내기와 같은 순서로: 그 사람의 소켓(모든 기기)을 방들에서 빼서 새 메시지·통화 상태가 더는 가지
 * 않게 하고, room:removed(reason 'team')로 열려 있던 화면을 닫게 하고, 그 방들의 진행 중인 통화에서도 내보낸 뒤(LiveKit
 * 미디어까지 — callAccess.js), 남은 멤버들에게 방 정보·할 일·안내를 알린다.
 * DB는 이미 바뀌었으므로 한 방의 알림이 실패해도 나머지 방은 계속 알린다. [leftover]는 teamRemovalNotice 참고.
 */
export async function notifyRemovedFromTeamRooms(io, { userId, userName, actorId, removals, leftover = false }) {
  if (removals.length === 0) return;
  io.in(`user:${userId}`).socketsLeave(removals.map(({ room }) => room.id));
  for (const { room } of removals) {
    io.to(`user:${userId}`).emit('room:removed', { roomId: room.id, reason: 'team', name: room.name });
  }
  // 그 방들의 통화(LiveKit 미디어 포함)에서도 내보낸다 — 소켓을 방에서 빼는 것만으로는 이미 붙은 미디어가 끊기지 않는다.
  await endUserCallAccess(io, userId, { roomIds: removals.map(({ room }) => room.id) });
  for (const removal of removals) {
    try {
      const notice = teamRemovalNotice(removal.room, userName, { leftover });
      await notifyRoomAfterDeparture(io, removal, { actorId, notice });
    } catch (err) {
      console.error('[teams] 팀 제외 후 방 알림 실패:', removal.room.id, err?.message ?? err);
    }
  }
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

  /**
   * 토픽 관리 라우트 공통 — :id가 토픽이고, 내가 그 토픽의 멤버이며, 토픽을 관리할 수 있는
   * 사람(토픽 관리자 또는 팀 관리자 — permissions.js canManageTopic)인지 확인한다. 통과하면
   * `{ room, access }`, 아니면 응답까지 끝내고 null.
   */
  async function requireTopicManager(req, res) {
    const room = await findRoomById(req.params.id);
    if (!room) {
      res.status(404).json({ error: '방을 찾을 수 없습니다.' });
      return null;
    }
    if (room.isSelf) {
      res.status(400).json({ error: SELF_ROOM_DENIAL });
      return null;
    }
    if (room.type !== 'topic') {
      res.status(400).json({ error: '토픽에서만 할 수 있습니다.' });
      return null;
    }
    const access = await topicAccess(room, req.user.sub);
    if (!access.isRoomMember) {
      res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
      return null;
    }
    if (!access.canManage) {
      res.status(403).json({ error: '토픽을 관리할 권한이 없습니다.' });
      return null;
    }
    return { room, access };
  }

  router.get('/rooms', async (req, res) => {
    const teamId = await requireTeamId(req, res, req.query.teamId);
    if (!teamId) return;
    // 나와의 대화는 팀원마다 늘 있어야 한다 — 목록을 줄 때 없으면 먼저 만든다(이 응답에 바로 들어간다).
    // 만들다 실패해도 나머지 방 목록은 그대로 준다(다음 요청이나 POST /rooms/self에서 다시 만든다).
    await openSelfRoom(io, req.user.sub, teamId).catch((err) =>
      console.error('[rooms] 나와의 대화 준비 실패:', err?.message ?? err),
    );
    const myRooms = await listRoomsForUser(req.user.sub, teamId);
    res.json(await Promise.all(myRooms.map((r) => toRoomDto(r, req.user.sub))));
  });

  /** 나와의 대화 열기 — 없으면 만들고(GET /rooms와 같은 방식) 그 방을 돌려준다. */
  router.post('/rooms/self', async (req, res) => {
    const teamId = await requireTeamId(req, res, req.body?.teamId);
    if (!teamId) return;
    const room = await openSelfRoom(io, req.user.sub, teamId);
    res.json(await toRoomDto(room, req.user.sub));
  });

  // ── 사이드바 토픽 폴더(개인 설정) ────────────────────────────────
  // 사람마다(팀마다) 따로 만드는 정리용 폴더라 다른 사람에게는 보이지 않는다(projects.js의 프로젝트
  // 폴더와 같은 방식). 바뀔 때마다 내 기기들(user:<id>)에만 topic-folders:changed를 보내 PC와
  // 모바일이 같은 모양을 유지한다. /rooms/:id보다 먼저 등록해야 'folders'가 방 id로 잡히지 않는다.

  /** 폴더 이름 검사 — 앞뒤 공백을 빼고 1~30자(글자 단위). */
  function parseFolderName(raw) {
    const name = typeof raw === 'string' ? raw.trim() : '';
    if (!name) return { error: '폴더 이름을 입력하세요.' };
    if (graphemeLength(name) > TOPIC_FOLDER_NAME_MAX) {
      return { error: `폴더 이름은 ${TOPIC_FOLDER_NAME_MAX}자 이내로 입력하세요.` };
    }
    return { name };
  }

  /** 내 폴더인지 확인하고, 아니면 응답까지 보내고 null — 남의 폴더는 있는지조차 알려주지 않는다.
   * uuid 모양이 아니면 DB가 형식 오류(500)를 내므로 조회 전에 걸러 같은 404로 답한다. */
  async function requireMyFolder(req, res, folderId) {
    const folder =
      typeof folderId === 'string' && UUID_RE.test(folderId) ? await findTopicFolderById(folderId) : null;
    if (!folder || folder.userId !== req.user.sub) {
      res.status(404).json({ error: '폴더를 찾을 수 없습니다.' });
      return null;
    }
    return folder;
  }

  function notifyTopicFoldersChanged(userId, teamId) {
    io.to(`user:${userId}`).emit('topic-folders:changed', { teamId });
  }

  /**
   * 새 토픽 설정 검사(POST /rooms) — 통과하면 저장할 값들, 아니면 `{ error }`. 보기 방식은 만든 뒤
   * 못 바꾸므로 여기서만 정한다. 조용히 나가기는 안 보내면 보드 뷰는 켜고(게시판 사이에 입퇴장
   * 안내가 끼지 않게) 챗 뷰는 끈다. [folderId]는 이 팀의 내 폴더여야 한다.
   */
  async function parseTopicCreateOptions(req, teamId, name) {
    const body = req.body ?? {};
    const nameCheck = parseTopicName(name);
    if (nameCheck.error) return nameCheck;
    const viewMode = body.viewMode ?? 'chat';
    if (viewMode !== 'chat' && viewMode !== 'board') return { error: '보기 방식이 올바르지 않습니다.' };
    const description = parseTopicDescription(body.description);
    if (description.error) return description;
    for (const key of ['readOnly', 'autoInvite', 'quietLeave']) {
      if (body[key] != null && typeof body[key] !== 'boolean') return { error: `${key}는 true/false여야 합니다.` };
    }
    const isPublic = body.isPublic !== false;
    let folder = null;
    if (body.folderId != null) {
      folder =
        typeof body.folderId === 'string' && UUID_RE.test(body.folderId)
          ? await findTopicFolderById(body.folderId)
          : null;
      if (!folder || folder.userId !== req.user.sub || folder.teamId !== teamId) {
        return { error: '폴더를 찾을 수 없습니다.' };
      }
    }
    return {
      viewMode,
      isPublic,
      description: description.value,
      readOnly: body.readOnly === true,
      // 정회원 자동 초대는 공개 토픽에서만 의미가 있다 — 비공개면 보내와도 끈다.
      autoInvite: isPublic && body.autoInvite === true,
      quietLeave: typeof body.quietLeave === 'boolean' ? body.quietLeave : viewMode === 'board',
      folder,
    };
  }

  router.get('/rooms/folders', async (req, res) => {
    const teamId = await requireTeamId(req, res, req.query.teamId);
    if (!teamId) return;
    const folders = await listTopicFolders(teamId, req.user.sub);
    res.json(folders.map((f) => toTopicFolderDto(f)));
  });

  router.post('/rooms/folders', async (req, res) => {
    const teamId = await requireTeamId(req, res, req.body?.teamId);
    if (!teamId) return;
    const { name, error } = parseFolderName(req.body?.name);
    if (error) return res.status(400).json({ error });
    if ((await countTopicFolders(teamId, req.user.sub)) >= TOPIC_FOLDER_MAX_PER_TEAM) {
      return res.status(400).json({ error: `폴더는 ${TOPIC_FOLDER_MAX_PER_TEAM}개까지 만들 수 있습니다.` });
    }
    const folder = await insertTopicFolder({ teamId, userId: req.user.sub, name });
    notifyTopicFoldersChanged(req.user.sub, teamId);
    res.status(201).json(toTopicFolderDto(folder, []));
  });

  /**
   * 내 폴더 순서를 통째로 다시 정한다 — [folderIds] 순서대로 0부터. 목록에 없는 내 폴더(다른 기기에서
   * 방금 만든 것 등)는 지금 순서 그대로 그 뒤에 붙인다(자리가 겹치지 않게).
   */
  router.put('/topic-folders/order', async (req, res) => {
    const teamId = await requireTeamId(req, res, req.body?.teamId);
    if (!teamId) return;
    const folderIds = req.body?.folderIds;
    if (!Array.isArray(folderIds) || folderIds.some((id) => typeof id !== 'string')) {
      return res.status(400).json({ error: 'folderIds가 필요합니다.' });
    }
    if (new Set(folderIds).size !== folderIds.length) {
      return res.status(400).json({ error: '폴더 순서가 올바르지 않습니다.' });
    }
    const mine = await listTopicFolders(teamId, req.user.sub);
    const mineIds = new Set(mine.map((f) => f.id));
    if (folderIds.some((id) => !mineIds.has(id))) {
      return res.status(400).json({ error: '이 팀의 내 폴더만 순서를 바꿀 수 있습니다.' });
    }
    const listed = new Set(folderIds);
    await reorderTopicFolders([...folderIds, ...mine.map((f) => f.id).filter((id) => !listed.has(id))]);
    notifyTopicFoldersChanged(req.user.sub, teamId);
    res.json({ ok: true });
  });

  /** 이름 바꾸기·접기/펼치기 — 만든 사람만(개인 설정). */
  router.patch('/topic-folders/:id', async (req, res) => {
    const folder = await requireMyFolder(req, res, req.params.id);
    if (!folder) return;
    const body = req.body ?? {};
    const fields = {};
    if ('name' in body) {
      const { name, error } = parseFolderName(body.name);
      if (error) return res.status(400).json({ error });
      fields.name = name;
    }
    if ('collapsed' in body) {
      if (typeof body.collapsed !== 'boolean') return res.status(400).json({ error: '접기 값이 올바르지 않습니다.' });
      fields.collapsed = body.collapsed;
    }
    if (Object.keys(fields).length === 0) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });
    const updated = await updateTopicFolder(folder.id, fields);
    notifyTopicFoldersChanged(req.user.sub, folder.teamId);
    res.json(toTopicFolderDto(updated, await listTopicFolderRoomIds(folder.id, req.user.sub)));
  });

  /** 폴더만 지운다 — 안에 있던 토픽은 폴더 밖 목록으로 돌아간다. */
  router.delete('/topic-folders/:id', async (req, res) => {
    const folder = await requireMyFolder(req, res, req.params.id);
    if (!folder) return;
    await deleteTopicFolder(folder.id);
    notifyTopicFoldersChanged(req.user.sub, folder.teamId);
    res.json({ ok: true });
  });

  /** 토픽을 내 폴더에 넣거나 옮기거나(folderId) 폴더에서 뺀다(null). 내가 멤버인 토픽만. */
  router.put('/rooms/:id/folder', async (req, res) => {
    const folderId = req.body?.folderId;
    if (folderId !== null && typeof folderId !== 'string') {
      return res.status(400).json({ error: 'folderId가 필요합니다.' });
    }
    const room = await findRoomById(req.params.id);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    if (room.type !== 'topic') return res.status(400).json({ error: '토픽만 폴더에 넣을 수 있습니다.' });
    if (!(await isRoomMember(room.id, req.user.sub))) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
    if (folderId !== null) {
      const folder = await requireMyFolder(req, res, folderId);
      if (!folder) return;
      if (folder.teamId !== room.teamId) {
        return res.status(400).json({ error: '같은 팀의 폴더에만 넣을 수 있습니다.' });
      }
    }
    await setTopicFolder(req.user.sub, room.id, folderId);
    notifyTopicFoldersChanged(req.user.sub, room.teamId);
    res.json({ ok: true });
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
    // 멤버 수·토픽 관리자 이름은 방마다 조회하지 않고 목록 전체를 한 번에 모은다.
    const summaries = await listTopicSummaries(rows.map(({ room }) => room.id));
    res.json(
      rows.map(({ room, joined }) => ({
        id: room.id,
        name: room.name,
        description: room.description ?? null,
        isPublic: room.isPublic !== false,
        memberCount: summaries[room.id]?.memberCount ?? 0,
        joined: !!joined,
        // 목록 배지(보드 뷰·읽기 전용·보관됨)와 "관리자 OOO" 표시용. 보관된 공개 토픽도 그대로
        // 보이고 참여할 수 있다(보관은 삭제가 아니라 읽기 전용으로 남겨두는 것).
        viewMode: room.viewMode === 'board' ? 'board' : 'chat',
        readOnly: !!room.readOnly,
        archived: !!room.archivedAt,
        createdAt: new Date(room.createdAt).getTime(),
        adminNames: summaries[room.id]?.adminNames ?? [],
      })),
    );
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
    // 나 혼자 쓰는 대화는 나와의 대화(POST /rooms/self)가 맡는다 — 자기 자신과의 DM은 따로 만들지 않는다.
    if (targetUserId === req.user.sub) {
      return res.status(400).json({ error: SELF_ROOM_DENIAL });
    }
    const target = await findUserById(targetUserId);
    if (!target) return res.status(404).json({ error: '대상 사용자를 찾을 수 없습니다.' });
    // 1:1 대화도 팀 안에서만 만들어진다 — 상대가 그 팀 멤버가 아니면 시작할 수 없다.
    if (!(await isTeamMember(teamId, targetUserId))) {
      return res.status(403).json({ error: '이 팀의 멤버가 아닌 사람과는 대화를 시작할 수 없습니다.' });
    }

    const dmKey = dmKeyFor(req.user.sub, targetUserId);
    let existing = await findDmRoomByKey(teamId, dmKey);
    if (existing) {
      // 둘 중 한쪽이 예전에 "채팅방 나가기"를 했거나 팀에서 제외돼 빠졌을 수 있으니, 다시 대화를 걸면 그 사람을 되살린다.
      const memberIds = await listRoomMemberIds(existing.id);
      const missing = [req.user.sub, targetUserId].filter((id) => !memberIds.includes(id));
      if (missing.length > 0) {
        const changedTodos = await addRoomMembers(existing.id, missing);
        // 팀에서 제외돼 "(나갔음)"으로 보이던 사람이 다시 들어왔으면 그 표시를 지운다(removeMemberFromRoom 참고).
        if (existing.secretDepartedMemberId && missing.includes(existing.secretDepartedMemberId)) {
          existing = (await setSecretDepartedMember(existing.id, { userId: null, name: null })) ?? existing;
        }
        await notifyMembership(io, existing);
        await notifyTodosResynced(io, existing, changedTodos, req.user.sub);
      }
      // 내가 숨겨 둔 DM이면 내 쪽만 다시 보이게 한다(내 다른 기기에도 알림) — 상대의 숨김 상태는 그대로 둔다.
      if (await getMemberHidden(existing.id, req.user.sub)) {
        await setMemberHidden(existing.id, req.user.sub, false);
        io.to(`user:${req.user.sub}`).emit('room:hidden', { roomId: existing.id, hidden: false });
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
    const { type, name, description, memberIds, isPublic, iconType, iconEmoji, iconColor, iconUrl } =
      req.body ?? {};
    if (type !== 'topic' && type !== 'group') {
      return res.status(400).json({ error: "type은 'topic' 또는 'group'이어야 합니다 (DM은 /rooms/dm 사용)." });
    }
    // 그룹채팅 아이콘·이름·설명 — 채팅 정보 변경(PATCH /rooms/:id)과 같은 검사(parseGroupIcon 등)를 쓴다.
    // 토픽은 아이콘 값들을 무시한다(항상 null).
    let group = null;
    if (type === 'group') {
      const iconCheck = await parseGroupIcon({ iconType, iconEmoji, iconColor, iconUrl }, { userId: req.user.sub });
      if (iconCheck.error) return res.status(400).json({ error: iconCheck.error });
      const nameCheck = parseGroupName(name);
      if (nameCheck.error) return res.status(400).json({ error: nameCheck.error });
      const descriptionCheck = parseGroupDescription(description);
      if (descriptionCheck.error) return res.status(400).json({ error: descriptionCheck.error });
      group = { icon: iconCheck.icon, name: nameCheck.value, description: descriptionCheck.value };
    }
    // 토픽은 팀 설정(topicCreationPolicy)이 정한 등급 이상만 — 그룹채팅은 위 canCreateRooms
    // 체크(정회원 이상)로 이미 충분하고 이 설정과 무관하다(README "토픽 생성 권한" 참고).
    if (type === 'topic') {
      const team = await findTeamById(teamId);
      // 'designated'일 때만 지정자 목록 조회가 필요하다(그 외 정책은 DB 조회 없이 판정 가능).
      const isDesignatedTopicCreator =
        team?.topicCreationPolicy === 'designated' ? await isTopicCreator(teamId, req.user.sub) : false;
      if (!canCreateTopic({ role, isOwner, isDesignatedTopicCreator, team })) {
        const need = { admin: '관리자 이상', owner: '소유자', designated: '지정된 사람' }[team?.topicCreationPolicy] ?? '정회원 이상';
        return res.status(403).json({ error: `이 팀은 ${need}만 토픽을 만들 수 있도록 설정되어 있습니다.` });
      }
    }
    const trimmedName = typeof name === 'string' ? name.trim() : '';
    if (type === 'topic' && !trimmedName) {
      return res.status(400).json({ error: '토픽 이름을 입력하세요.' });
    }

    // 토픽 설정(보기 방식·공개 여부·설명·읽기 전용·정회원 자동 초대·조용히 나가기·폴더) 검사.
    let topic = null;
    if (type === 'topic') {
      topic = await parseTopicCreateOptions(req, teamId, trimmedName);
      if (topic.error) return res.status(400).json({ error: topic.error });
    }

    let roomMemberIds;
    if (type === 'topic') {
      // 공개 토픽도 이제 만드는 순간 팀 전원이 들어가지 않는다(잔디 방식) — "참여 가능한 토픽"에서
      // 찾아서 들어오고, 만든 사람이 바로 이어서 "멤버 초대하기"로 한 번에 부를 수 있다. 호출부가
      // memberIds를 보냈으면 그중 이 팀 멤버만 같이 넣는다(다른 팀 사람이 섞이지 않게).
      const teamMemberIds = new Set(await listTeamMemberIds(teamId));
      const invited = (Array.isArray(memberIds) ? memberIds : []).filter(
        (id) => typeof id === 'string' && id !== req.user.sub && teamMemberIds.has(id),
      );
      roomMemberIds = [req.user.sub, ...new Set(invited)];
    } else {
      // 그룹도 이 팀 안의 대화라 이 팀 멤버만 넣는다 — 예전엔 아무 사용자 id나 넣을 수 있어서 다른 팀 사람을 마음대로
      // 대화방에 끌어들이고 그 사람 정보를 받아 볼 수 있었다.
      const teamMemberIds = new Set(await listTeamMemberIds(teamId));
      const invited = (Array.isArray(memberIds) ? memberIds : []).filter(
        (id) => typeof id === 'string' && teamMemberIds.has(id),
      );
      const memberIdSet = new Set([req.user.sub, ...invited]);
      if (type === 'group' && memberIdSet.size < 2) {
        return res.status(400).json({ error: '그룹에는 나 이외의 멤버가 최소 1명 필요합니다.' });
      }
      roomMemberIds = [...memberIdSet];
    }

    const room = await insertRoom({
      id: randomUUID(),
      teamId,
      type,
      name: group ? group.name : trimmedName || null,
      description: group ? group.description : (topic?.description ?? null),
      // 공개 토픽은 지금 회원뿐 아니라 나중에 가입하는 회원에게도 계속 보인다(/rooms/browse).
      isPublic: type === 'topic' ? topic.isPublic : null,
      ...(topic
        ? {
            viewMode: topic.viewMode,
            readOnly: topic.readOnly,
            autoInvite: topic.autoInvite,
            quietLeave: topic.quietLeave,
          }
        : {}),
      createdBy: req.user.sub,
      ...(group ? group.icon : { iconType: null, iconEmoji: null, iconColor: null, iconUrl: null }),
    });
    if (type === 'topic') {
      // 토픽을 만든 사람은 토픽 관리자로 시작한다.
      await addRoomMembers(room.id, [req.user.sub], 'admin');
      await addRoomMembers(room.id, roomMemberIds.filter((id) => id !== req.user.sub));
    } else {
      await addRoomMembers(room.id, roomMemberIds);
    }
    await notifyMembership(io, room);

    // 만들면서 고른 내 폴더에 넣는다(개인 설정 — 내 다른 기기에도 알린다).
    if (topic?.folder) {
      await setTopicFolder(req.user.sub, room.id, topic.folder.id);
      notifyTopicFoldersChanged(req.user.sub, teamId);
    }

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
    if (room.isSelf) return res.status(400).json({ error: SELF_ROOM_DENIAL });
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
      const changedTodos = await addRoomMembers(room.id, [req.user.sub]);
      await notifyMembership(io, room);
      await notifyTodosResynced(io, room, changedTodos, req.user.sub); // 나갔다가 다시 들어온 담당자.
      await postSystemMessage(io, room, `${await nameOf(req.user.sub)} 님이 참여했습니다.`);
    }
    res.json(await toRoomDto(room, req.user.sub));
  });

  router.post('/rooms/:id/invite', async (req, res) => {
    const room = await findRoomById(req.params.id);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    if (room.isSelf) return res.status(400).json({ error: SELF_ROOM_DENIAL });
    if (room.type === 'dm') return res.status(403).json({ error: 'DM에는 멤버를 초대할 수 없습니다.' });
    if (!(await isRoomMember(room.id, req.user.sub))) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
    // 이미 있는 방에 멤버를 추가로 초대하는 건 팀 설정과 무관하게 정회원 이상이면 누구나 —
    // 준회원만 불가(canCreateRooms와 같은 기준). 새 토픽을 만드는 것과는 별개 규칙이다.
    const inviter = await teamAccess(room.teamId, req.user.sub);
    // 팀에서 빠지면 그 팀 방에서도 빠지지만(removeMemberFromTeamRooms), 팀에서 빠져도 방 멤버십을 남겨 두던 예전에 남은
    // 행이 있어도 그 팀 방에 사람을 데려올 수는 없게 팀 멤버인지 한 번 더 본다.
    if (!inviter.isMember || !canCreateRooms(inviter.role)) {
      return res.status(403).json({ error: '멤버를 초대할 권한이 없습니다.' });
    }

    const { userIds } = req.body ?? {};
    const result = await inviteMembersToRoom(io, room, req.user.sub, uniqueStringIds(userIds));
    if (result.invited.length === 0) {
      return res.status(400).json({ error: '초대할 멤버를 선택하세요.' });
    }

    res.json(await toRoomDto(room, req.user.sub));
  });

  /**
   * 여러 토픽·그룹채팅에 한 번에 초대('여러 토픽/그룹채팅에 초대') — 정회원 이상. 방마다 단건 초대와 같은 코드
   * (inviteMembersToRoom)로 처리해 시스템 메시지·소켓 알림이 똑같고, 방별로 부분 성공을 허용한다.
   * 내가 멤버가 아닌 방·1:1·나와의 대화·비밀 대화·다른 팀 방은 그 방만 `error` 코드로 표시하고 건너뛴다.
   * 응답: `{ results: [{ roomId, roomName, roomType, invited, alreadyMembers, failed, error? }] }` (요청한 방 순서).
   */
  router.post('/rooms/invite-bulk', async (req, res) => {
    const parsed = parseInviteBulkBody(req.body);
    if (parsed.error) return res.status(400).json({ error: parsed.error });
    const scope = await requireTeamRole(req, res, parsed.teamId);
    if (!scope) return;
    if (!canCreateRooms(scope.role)) {
      return res.status(403).json({ error: '멤버를 초대할 권한이 없습니다.' });
    }
    const { teamId, userIds, roomIds } = parsed;
    const teamMemberIds = new Set(await listTeamMemberIds(teamId));
    const nameCache = new Map();
    const results = [];
    for (const roomId of roomIds) {
      const entry = { roomId, roomName: null, roomType: null, invited: [], alreadyMembers: [], failed: [] };
      results.push(entry);
      try {
        const room = plausibleRoomId(roomId) ? await findRoomById(roomId) : null;
        const isMember = room ? await isRoomMember(room.id, req.user.sub) : false;
        const code = bulkInviteRoomError(room, { teamId, isMember });
        if (code) {
          entry.error = code;
          // 내가 멤버인 방만 이름·종류를 알려 준다(남의 방은 있는지조차 알려 주지 않는다).
          if (room && isMember) {
            entry.roomName = await roomDisplayName(room, req.user.sub);
            entry.roomType = room.type;
          }
          continue;
        }
        entry.roomName = await roomDisplayName(room, req.user.sub);
        entry.roomType = room.type;
        Object.assign(entry, await inviteMembersToRoom(io, room, req.user.sub, userIds, { teamMemberIds, nameCache }));
      } catch (err) {
        console.error('[rooms] 일괄 초대 실패:', roomId, err?.message ?? err);
        entry.error = 'failed';
      }
    }
    res.json({ results });
  });

  /**
   * 그룹채팅 → 토픽 전환('채팅 정보 변경' 창의 '토픽으로 전환') — 대화 내용·멤버는 그대로, 비공개 토픽이 되고 전환한
   * 사람이 토픽 관리자가 된다. 되돌릴 수 없다. 정회원 이상 멤버만 — 토픽 생성 권한 정책(topicCreationPolicy)이 있는
   * 팀은 새 토픽을 만드는 것과 같은 기준을 따른다. 방 정보는 기존 방 정보 변경과 같은 room:created로 뿌린다.
   */
  router.post('/rooms/:id/convert-to-topic', async (req, res) => {
    const room = await findRoomById(req.params.id);
    const denial = convertDenial(room);
    if (denial) return res.status(room ? 400 : 404).json({ error: denial });
    if (!(await isRoomMember(room.id, req.user.sub))) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
    const access = await teamAccess(room.teamId, req.user.sub);
    if (!access.isMember) return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    if (!canCreateRooms(access.role)) {
      return res.status(403).json({ error: '준회원은 그룹채팅을 토픽으로 전환할 수 없습니다.' });
    }
    const team = await findTeamById(room.teamId);
    const isDesignatedTopicCreator =
      team?.topicCreationPolicy === 'designated' ? await isTopicCreator(room.teamId, req.user.sub) : false;
    if (!canCreateTopic({ role: access.role, isOwner: access.isOwner, isDesignatedTopicCreator, team })) {
      const need = { admin: '관리자 이상', owner: '소유자', designated: '지정된 사람' }[team?.topicCreationPolicy] ?? '정회원 이상';
      return res.status(403).json({ error: `이 팀은 ${need}만 토픽을 만들 수 있도록 설정되어 있습니다.` });
    }
    const parsed = parseConvertBody(req.body);
    if (parsed.error) return res.status(400).json({ error: parsed.error });

    const updated = await convertGroupToTopic(room.id, req.user.sub, parsed);
    if (!updated) return res.status(409).json({ error: '이미 전환되었거나 그룹채팅이 아닙니다.' });
    io.to(room.id).emit('room:created', await toRoomDto(updated));
    const actorName = await nameOf(req.user.sub);
    await postSystemMessage(io, updated, convertNotice(actorName, updated.name));
    recordAudit({
      actorId: req.user.sub,
      actorName,
      action: AUDIT.roomConvert,
      teamId: room.teamId,
      teamName: team?.name ?? null,
      targetType: 'room',
      targetId: room.id,
      targetLabel: updated.name,
      detail: '그룹채팅을 비공개 토픽으로 전환',
    });
    res.json(await toRoomDto(updated, req.user.sub));
  });

  router.post('/rooms/:id/leave', async (req, res) => {
    const room = await findRoomById(req.params.id);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    // 나와의 대화는 나가기·숨기기가 없다(팀마다 늘 하나씩 있는 내 메모 공간).
    if (room.isSelf) return res.status(400).json({ error: SELF_ROOM_DENIAL });
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

      // 체크 안 함 — 나만 나간다(팀에서 제외될 때와 같은 정리 — removeMemberFromRoom). 남은 멤버가 없으면(상대가 이미
      // 먼저 혼자 나가있던 상태였다면) 아무도 못 보는 방이라 완전히 지워지고, 아니면 남은 쪽에 나간 사람 이름이 남는다.
      // 방 잠금 안에서 해서 두 사람이 동시에 혼자 나가도 한쪽이 지운 방에 이름을 남기려다 실패하지 않는다.
      const leaverName = await nameOf(req.user.sub);
      const removal = await withRoomLock(room.id, (tx) =>
        removeMemberFromRoom(tx, room, req.user.sub, { departedName: leaverName }),
      );
      io.in(`user:${req.user.sub}`).socketsLeave(room.id); // socketsLeave 이후라 본인은 자기 퇴장 메시지를 안 받음.
      // 남은 멤버의 멤버 목록+나간 사람 이름을 갱신시키고 종료 안내를 남긴다(그새 이미 나가 있었으면 할 일이 없다).
      if (removal.removed) {
        await notifyRoomAfterDeparture(io, removal, { actorId: req.user.sub, notice: SECRET_CHAT_ENDED_NOTICE });
      }
      return res.json({ ok: true });
    }

    if (room.type === 'dm') {
      // 평문 DM의 "채팅방 숨기기"/"채팅방 나가기" — 상대방에게는 아무 영향이 없어야 한다는
      // 요구사항에 따라(room_options_menu.dart), 이제 진짜 멤버십을 건드리지 않는다. 예전엔
      // 나를 멤버에서 뺐는데, DM은 멤버가 나+상대 둘뿐이라 그러면 상대 쪽 화면에서 방
      // 이름이 "(알 수 없음)"이 되고(Room.displayName이 상대를 못 찾음),
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

    // 그룹/토픽 — 진짜 멤버십이 없어지는 공개적인 이벤트라 지금까지처럼 실제로 나간다(내 토픽 폴더
    // 배치도 같이 지워지고, 내가 담당자인 이 방 할 일의 전체 진척률도 다시 맞춰진다).
    let left;
    if (room.type === 'topic') {
      // 토픽 관리자가 마지막 한 명이면 먼저 다른 멤버를 토픽 관리자로 정해야 나갈 수 있다 — 관리할
      // 사람 없이 남은 멤버들만 두고 떠나지 않게(나 혼자 남은 토픽이면 그냥 나갈 수 있다). 확인과
      // 나가기를 방 잠금 안에서 한 번에 해서, 관리자 둘이 동시에 나가도 둘 다 빠지지 않게 한다.
      left = await withRoomLock(room.id, async (tx) => {
        const members = await listRoomMemberRoles(room.id, tx);
        const isAdmin = members.some((m) => m.userId === req.user.sub && m.role === 'admin');
        // 토픽 관리자로 지정할 수 있는 사람(정회원 이상)이 남아 있을 때만 막는다 — 남은 멤버가 모두
        // 준회원이면 지정할 방법이 없으니 그냥 나가게 둔다(팀 관리자는 계속 관리할 수 있다).
        const eligibleOthers = members.filter(
          (m) => m.userId !== req.user.sub && accountRole({ role: m.accountRole }) !== 'guest',
        );
        if (isAdmin && eligibleOthers.length > 0 && !eligibleOthers.some((m) => m.role === 'admin')) return null;
        return removeRoomMembers(room.id, [req.user.sub], tx);
      });
      if (!left) {
        return res
          .status(400)
          .json({ error: '토픽 관리자는 다른 멤버를 토픽 관리자로 지정한 뒤에 나갈 수 있습니다.' });
      }
    } else {
      left = await removeRoomMembers(room.id, [req.user.sub]);
    }

    io.in(`user:${req.user.sub}`).socketsLeave(room.id); // 나간 사람은 이후 이 방 메시지를 더 이상 받지 않게.
    // 이 방 통화에 들어와 있었으면 통화에서도 뺀다 — 앱은 방을 나가며 통화를 먼저 끊지만, 다른 기기의 연결이나 앱이 못 끊은
    // 미디어가 남아 멤버가 아닌 채로 회의를 계속 듣지 않게(callAccess.js).
    await endUserCallAccess(io, req.user.sub, { roomIds: [room.id] });
    // 조용히 나가기 토픽은 "나갔습니다" 안내를 남기지 않는다(그룹은 항상 false).
    if (!room.quietLeave) {
      await postSystemMessage(io, room, `${await nameOf(req.user.sub)} 님이 나갔습니다.`); // socketsLeave 이후라 본인은 자기 퇴장 메시지를 안 받음.
    }
    io.to(room.id).emit('room:created', await toRoomDto(room)); // 남은 멤버들의 목록을 갱신시킨다.
    // 폴더에 넣어뒀던 토픽이면 내 다른 기기의 폴더 목록도 다시 불러오게 한다.
    if (left.folderItemRemoved) io.to(`user:${req.user.sub}`).emit('topic-folders:changed', { teamId: room.teamId });
    // 내가 담당자였던 할 일은 남은 담당자들로 전체 진척률이 바뀌었을 수 있다 — 남은 멤버의 할 일 화면을 새로 고친다.
    await notifyTodosResynced(io, room, left.changedTodos, req.user.sub);

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

  // 그룹채팅방 이름을 나에게만 다르게 부르기 — 내 다른 기기(user:<id> 룸)에만 알린다.
  // 빈 문자열/null이면 별칭을 지우고 원래 이름으로 돌아간다.
  router.post('/rooms/:id/nickname', async (req, res) => {
    const room = await findRoomById(req.params.id);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    if (room.isSelf) return res.status(400).json({ error: SELF_ROOM_DENIAL });
    if (!(await isRoomMember(room.id, req.user.sub))) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
    if (room.type !== 'group') return res.status(400).json({ error: '그룹채팅방만 이름을 바꿀 수 있습니다.' });

    const raw = typeof req.body?.name === 'string' ? req.body.name.trim() : '';
    if (raw.length > 100) return res.status(400).json({ error: '이름은 100자 이하여야 합니다.' });
    const customName = raw || null;
    await setMemberCustomName(room.id, req.user.sub, customName);
    io.to(`user:${req.user.sub}`).emit('room:renamed', { roomId: room.id, customName });
    res.json(await toRoomDto(room, req.user.sub));
  });

  // ── 토픽 관리(토픽 관리자·팀 관리자) ────────────────────────────────
  // 바뀐 방 DTO는 기존 방식대로 room:created로 멤버 전원에게 다시 뿌린다(클라이언트가 같은 id면
  // 덮어쓴다). 안내 문구는 시스템 메시지로 남긴다(보드 뷰는 클라이언트가 시스템 메시지를 숨긴다).

  /**
   * 그룹채팅 정보 변경('채팅 정보 변경' 창) — 이름('' → null = 멤버 이름으로 표시), 설명, 아이콘. 토픽처럼 관리자를
   * 따로 두지 않고 그 방 멤버 중 정회원 이상이면 누구나 바꾼다. 실제로 달라진 게 있을 때만 저장하고, 방 정보를
   * 다시 뿌리고(room:created), 안내를 한 줄 남긴다 — 이름이 바뀌었으면 이름 안내, 아니면 "채팅 정보를 변경했습니다".
   */
  async function updateGroupInfo(req, res, room) {
    if (!(await isRoomMember(room.id, req.user.sub))) {
      return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
    }
    // 팀에서 빠진 사람은 그 팀 방에서도 빠지지만, 방 멤버십을 남겨 두던 예전에 남은 행이 있어도 그 팀의 방 정보는
    // 못 바꾼다(토픽 관리와 같은 원칙).
    const access = await teamAccess(room.teamId, req.user.sub);
    if (!access.isMember) return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    if (access.role === 'guest') {
      return res.status(403).json({ error: '준회원은 채팅 정보를 바꿀 수 없습니다.' });
    }
    const body = req.body ?? {};
    const fields = {};
    if ('name' in body) {
      const { value, error } = parseGroupName(body.name);
      if (error) return res.status(400).json({ error });
      fields.name = value;
    }
    if ('description' in body) {
      const { value, error } = parseGroupDescription(body.description);
      if (error) return res.status(400).json({ error });
      fields.description = value;
    }
    if (GROUP_ICON_KEYS.some((key) => key in body)) {
      // 보낸 칸만 바꾸고(색만 바꾸는 등) 나머지는 지금 값을 그대로 합쳐서, 만들 때와 같은 규칙으로 검사한다.
      // 지금 사진을 그대로 돌려보냈으면(방 정보를 받은 지 오래돼 서명 링크가 만료됐을 수 있다) 지금 값으로 본다 —
      // parseGroupIcon이 지금 아이콘(currentIconUrl)을 "원래 있던 파일"로 받는다.
      const { icon, error } = await parseGroupIcon(
        {
          iconType: 'iconType' in body ? body.iconType : room.iconType,
          iconEmoji: 'iconEmoji' in body ? body.iconEmoji : room.iconEmoji,
          iconColor: 'iconColor' in body ? body.iconColor : room.iconColor,
          iconUrl: 'iconUrl' in body ? body.iconUrl : room.iconUrl,
        },
        { userId: req.user.sub, currentIconUrl: room.iconUrl },
      );
      if (error) return res.status(400).json({ error });
      Object.assign(fields, icon);
    }
    if (Object.keys(fields).length === 0) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });

    // 그대로 다시 저장한 칸은 뺀다 — 아무것도 안 바뀌었으면 안내도 방 정보 재전송도 없이 지금 모습을 돌려준다.
    for (const key of Object.keys(fields)) {
      if ((room[key] ?? null) === fields[key]) delete fields[key];
    }
    if (Object.keys(fields).length === 0) return res.json(await toRoomDto(room, req.user.sub));

    const updated = await updateRoom(room.id, fields);
    io.to(room.id).emit('room:created', await toRoomDto(updated));
    const actor = await nameOf(req.user.sub);
    let notice;
    if ('name' in fields) {
      notice = fields.name
        ? `${actor} 님이 그룹 채팅 이름을 '${fields.name}'(으)로 바꿨습니다.`
        : `${actor} 님이 그룹 채팅 이름을 지웠습니다.`;
    } else {
      notice = `${actor} 님이 채팅 정보를 변경했습니다.`;
    }
    await postSystemMessage(io, updated, notice);
    res.json(await toRoomDto(updated, req.user.sub));
  }

  /** 토픽 정보·설정 변경 — 이름, 설명, 공개 여부, 읽기 전용, 정회원 자동 초대, 조용히 나가기. 그룹채팅은
   * 위 updateGroupInfo(채팅 정보 변경)로 보낸다. */
  router.patch('/rooms/:id', async (req, res) => {
    const target = await findRoomById(req.params.id);
    if (target?.type === 'group') return updateGroupInfo(req, res, target);
    const scope = await requireTopicManager(req, res);
    if (!scope) return;
    const { room } = scope;
    const body = req.body ?? {};

    // 보기 방식은 만든 뒤에 못 바꾼다(이미 쌓인 글의 모양이 달라서) — 같은 값이면 그냥 둔다.
    if ('viewMode' in body && body.viewMode !== (room.viewMode ?? 'chat')) {
      return res.status(400).json({ error: '보기 방식은 바꿀 수 없습니다.' });
    }
    const fields = {};
    if ('name' in body) {
      const { name, error } = parseTopicName(body.name);
      if (error) return res.status(400).json({ error });
      fields.name = name;
    }
    if ('description' in body) {
      const { value, error } = parseTopicDescription(body.description);
      if (error) return res.status(400).json({ error });
      fields.description = value;
    }
    // 보드 뷰 토픽의 말머리 목록 — 통째로 바꾼다(지운 말머리의 게시글은 말머리 없이 보인다).
    if ('boardCategories' in body) {
      if (room.viewMode !== 'board') return res.status(400).json({ error: '말머리는 보드 뷰 토픽에만 둘 수 있습니다.' });
      const parsed = parseBoardCategories(body.boardCategories);
      if (parsed.error) return res.status(400).json({ error: parsed.error });
      fields.boardCategories = parsed.categories;
    }
    for (const key of ['isPublic', 'readOnly', 'autoInvite', 'quietLeave']) {
      if (!(key in body)) continue;
      if (typeof body[key] !== 'boolean') return res.status(400).json({ error: `${key}는 true/false여야 합니다.` });
      fields[key] = body[key];
    }
    if (Object.keys(fields).length === 0 && !('viewMode' in body)) {
      return res.status(400).json({ error: '바꿀 내용이 없습니다.' });
    }
    const wasPublic = room.isPublic !== false;
    const willBePublic = 'isPublic' in fields ? fields.isPublic : wasPublic;
    // 비공개 토픽은 정회원 자동 초대를 쓸 수 없다 — 비공개로 바꾸면 같이 끈다.
    if (!willBePublic && ('isPublic' in fields || 'autoInvite' in fields)) fields.autoInvite = false;

    const updated = Object.keys(fields).length > 0 ? await updateRoom(room.id, fields) : room;
    io.to(room.id).emit('room:created', await toRoomDto(updated));

    const actor = await nameOf(req.user.sub);
    if ('name' in fields && fields.name !== room.name) {
      await postSystemMessage(
        io,
        updated,
        `${actor} 님이 토픽 이름을 '${room.name ?? ''}'에서 '${fields.name}'(으)로 바꿨습니다.`,
      );
    }
    if ('readOnly' in fields && fields.readOnly !== !!room.readOnly) {
      await postSystemMessage(
        io,
        updated,
        fields.readOnly ? `${actor} 님이 읽기 전용을 설정했습니다.` : `${actor} 님이 읽기 전용을 해제했습니다.`,
      );
    }
    if (willBePublic !== wasPublic) {
      await postSystemMessage(
        io,
        updated,
        willBePublic ? `${actor} 님이 토픽을 공개로 바꿨습니다.` : `${actor} 님이 토픽을 비공개로 바꿨습니다.`,
      );
    }
    res.json(await toRoomDto(updated, req.user.sub));
  });

  /** 토픽 보관/보관 해제 — 보관하면 목록의 '보관된 토픽'으로 옮겨지고 토픽 관리자만 글을 쓴다. */
  router.post('/rooms/:id/archive', async (req, res) => {
    const scope = await requireTopicManager(req, res);
    if (!scope) return;
    const { room } = scope;
    if (typeof req.body?.archived !== 'boolean') {
      return res.status(400).json({ error: 'archived는 true/false여야 합니다.' });
    }
    const archived = req.body.archived;
    let updated = room;
    // 이미 그 상태면 아무것도 안 바꾸고 안내도 안 남긴다(두 기기에서 동시에 눌러도 무해).
    if (archived !== !!room.archivedAt) {
      updated = await updateRoom(room.id, { archivedAt: archived ? new Date() : null });
      io.to(room.id).emit('room:created', await toRoomDto(updated));
      const actor = await nameOf(req.user.sub);
      await postSystemMessage(
        io,
        updated,
        archived ? `${actor} 님이 토픽을 보관했습니다.` : `${actor} 님이 토픽 보관을 해제했습니다.`,
      );
      // 보관된 토픽에는 토픽 관리자만 쓴다 — 다른 사람들의 예약은 보낼 시각을 기다리지 않고 지금 실패로 알린다.
      if (archived) await failScheduledForArchivedTopic(io, updated);
    }
    res.json(await toRoomDto(updated, req.user.sub));
  });

  /**
   * 토픽 삭제 — 메시지·댓글·공지·첨부 기록까지 전부 사라진다(FK cascade, 되돌릴 수 없음). 지우기
   * 전에 멤버들에게 room:removed를 보내 열려 있는 화면을 닫게 하고, 소켓도 방에서 빼 둔다.
   * (업로드된 파일 자체는 팀 삭제와 마찬가지로 디스크에 남는다.)
   */
  router.delete('/rooms/:id', async (req, res) => {
    const scope = await requireTopicManager(req, res);
    if (!scope) return;
    const { room } = scope;

    const memberIds = await listRoomMemberIds(room.id);
    const payload = { roomId: room.id, reason: 'deleted', name: room.name };
    for (const userId of memberIds) io.to(`user:${userId}`).emit('room:removed', payload);
    // 진행 중인 통화가 있으면 끝낸다 — 방이 없어지면 아무도 그 통화에 있을 자격이 없다(LiveKit 방째 닫는다 — callAccess.js).
    // 소켓을 방에서 빼기 전이라 멤버들이 "통화 끝남"(call:state)도 받아 통화 표시를 지운다.
    await endRoomCallAccess(io, room.id);
    io.in(room.id).socketsLeave(room.id);
    const [actorName, team] = await Promise.all([nameOf(req.user.sub), findTeamById(room.teamId)]);
    // 지우면 예약의 방 id가 비워지므로(set null) 그 전에 이 방 예약을 골라 두었다가, 지운 뒤 실패로 알린다.
    const scheduled = await listScheduledForRoom(room.id);
    await deleteRoom(room.id);
    await failScheduledForDeletedRoom(io, room, scheduled);
    recordAudit({
      actorId: req.user.sub,
      actorName,
      action: AUDIT.topicDelete,
      teamId: room.teamId,
      teamName: team?.name ?? null,
      targetType: 'room',
      targetId: room.id,
      targetLabel: room.name,
      detail: `토픽 삭제(멤버 ${memberIds.length}명)`,
    });
    res.json({ ok: true });
  });

  /**
   * 멤버 내보내기 — 나 자신은 안 되고, 팀 관리자가 아닌 토픽 관리자는 다른 토픽 관리자를 내보낼 수
   * 없다. 내보낸 사람에게는 room:removed(reason 'kicked')를 보내 화면을 닫게 한다. 공개 토픽이면
   * 다시 찾아서 참여할 수 있다(내보내기는 차단이 아니다).
   */
  router.post('/rooms/:id/kick', async (req, res) => {
    const scope = await requireTopicManager(req, res);
    if (!scope) return;
    const { room, access } = scope;
    const ids = Array.isArray(req.body?.userIds)
      ? [...new Set(req.body.userIds.filter((id) => typeof id === 'string'))]
      : [];
    if (ids.length === 0) return res.status(400).json({ error: '내보낼 멤버를 선택하세요.' });
    if (ids.includes(req.user.sub)) return res.status(400).json({ error: '자기 자신은 내보낼 수 없습니다.' });

    // 확인과 내보내기를 방 잠금 안에서 한 번에 — 같은 때 들어온 토픽 관리자 지정·나가기와 엇갈려 토픽
    // 관리자가 하나도 안 남는 일이 없게.
    const outcome = await withRoomLock(room.id, async (tx) => {
      const members = new Map((await listRoomMemberRoles(room.id, tx)).map((m) => [m.userId, m]));
      // 그새 스스로 나간 사람 등 이미 멤버가 아닌 id는 조용히 건너뛴다.
      const found = ids.filter((id) => members.has(id));
      if (found.length === 0) return { status: 400, error: '내보낼 멤버를 선택하세요.' };
      if (!canManageTeam(access) && found.some((id) => members.get(id).role === 'admin')) {
        return { status: 403, error: '토픽 관리자는 다른 토픽 관리자를 내보낼 수 없습니다.' };
      }
      // 그 사람들의 토픽 폴더 배치도 같이 지우고, 그 사람들이 담당자인 할 일의 전체 진척률도 다시 맞춘다.
      const { changedTodos } = await removeRoomMembers(room.id, found, tx);
      return { targets: found, changedTodos };
    });
    if (outcome.error) return res.status(outcome.status).json({ error: outcome.error });
    const { targets, changedTodos } = outcome;
    io.in(targets.map((id) => `user:${id}`)).socketsLeave(room.id);
    const payload = { roomId: room.id, reason: 'kicked', name: room.name };
    for (const userId of targets) io.to(`user:${userId}`).emit('room:removed', payload);
    // 이 방 통화에 들어와 있었으면 통화(LiveKit 미디어 포함)에서도 내보낸다 — 소켓을 방에서 빼는 것만으로는 이미 붙은 미디어가
    // 끊기지 않아, 내보낸 사람이 회의를 계속 듣고 진행자였으면 남의 마이크도 계속 끌 수 있었다(callAccess.js).
    for (const userId of targets) await endUserCallAccess(io, userId, { roomIds: [room.id] });
    io.to(room.id).emit('room:created', await toRoomDto(room)); // 남은 멤버들의 목록을 갱신시킨다.
    await notifyTodosResynced(io, room, changedTodos, req.user.sub);
    if (!room.quietLeave) {
      const names = await Promise.all(targets.map(nameOf));
      await postSystemMessage(io, room, `${await nameOf(req.user.sub)} 님이 ${names.join(', ')} 님을 내보냈습니다.`);
    }
    res.json(await toRoomDto(room, req.user.sub));
  });

  /**
   * 토픽 관리자 지정 — 보낸 목록으로 통째로 바꾼다(한 명 이상). 이 토픽의 멤버 중 정회원 이상만
   * 지정할 수 있다(준회원은 초대받은 방에서 활동만 하는 등급이라 관리 권한을 주지 않는다).
   */
  router.put('/rooms/:id/admins', async (req, res) => {
    const scope = await requireTopicManager(req, res);
    if (!scope) return;
    const { room, access } = scope;
    const ids = Array.isArray(req.body?.userIds)
      ? [...new Set(req.body.userIds.filter((id) => typeof id === 'string'))]
      : [];
    if (ids.length === 0) return res.status(400).json({ error: '토픽 관리자를 한 명 이상 지정하세요.' });

    // 확인과 저장을 방 잠금 안에서 한 번에 — 지정하는 사이 그 사람이 나가거나 내보내져서 토픽 관리자가
    // 하나도 안 남는 일이 없게.
    const outcome = await withRoomLock(room.id, async (tx) => {
      const memberRows = await listRoomMemberRoles(room.id, tx);
      const members = new Map(memberRows.map((m) => [m.userId, m]));
      for (const id of ids) {
        const member = members.get(id);
        if (!member) return { error: '이 토픽의 멤버만 토픽 관리자로 지정할 수 있습니다.' };
        if (accountRole({ role: member.accountRole }) === 'guest') {
          return { error: '준회원은 토픽 관리자로 지정할 수 없습니다.' };
        }
      }
      const before = new Set(memberRows.filter((m) => m.role === 'admin').map((m) => m.userId));
      // 토픽 관리자는 다른 토픽 관리자를 뺄 수 없다(자기 자신만) — 내보내기의 같은 규칙을 "먼저 관리자에서 빼고 그다음
      // 내보내기"로 돌아가지 못하게. 팀 소유자·관리자는 그대로 누구든 바꿀 수 있다.
      if (!canManageTeam(access) && [...before].some((id) => id !== req.user.sub && !ids.includes(id))) {
        return { error: '토픽 관리자는 다른 토픽 관리자를 해제할 수 없습니다. 팀 소유자·관리자에게 요청하세요.' };
      }
      const changed = before.size !== ids.length || ids.some((id) => !before.has(id));
      // 그대로 다시 저장한 것이면 안내를 또 남기지 않는다.
      if (changed) await setRoomAdmins(room.id, ids, tx);
      return { changed };
    });
    if (outcome.error) return res.status(400).json({ error: outcome.error });
    if (outcome.changed) {
      io.to(room.id).emit('room:created', await toRoomDto(room));
      const names = await Promise.all(ids.map(nameOf));
      await postSystemMessage(
        io,
        room,
        `${await nameOf(req.user.sub)} 님이 토픽 관리자를 ${names.join(', ')} 님으로 지정했습니다.`,
      );
    }
    res.json(await toRoomDto(room, req.user.sub));
  });

  router.get('/rooms/:id', async (req, res) => {
    const room = await findRoomById(req.params.id);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    if (!(await isRoomMember(room.id, req.user.sub))) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
    res.json(await toRoomDto(room, req.user.sub));
  });

  /**
   * 보드 뷰 상단 "고정된 게시글" — 지워지지 않은 고정 게시글 전부를 작성 시각 최신순으로.
   * GET /rooms/:id/messages의 항목과 같은 모양(댓글 포함)이라 클라이언트가 같은 파서를 쓴다.
   */
  router.get('/rooms/:id/pinned-posts', async (req, res) => {
    const room = await findRoomById(req.params.id);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    if (!(await isRoomMember(room.id, req.user.sub))) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });

    // 고정은 게시글만 되지만(messages.js) 같은 모양을 지키려고 투표도 붙일 수 있게 attachPolls를 거친다.
    const rows = await attachReactions(await attachPolls(await listPinnedPosts(room.id), req.user.sub));
    const ids = rows.map((m) => m.id);
    const [attachmentsByMessageId, comments] = await Promise.all([
      listAttachmentsForMessages(ids),
      listCommentsForMessages(ids),
    ]);
    const commentsByMessageId = new Map();
    for (const c of comments) {
      const list = commentsByMessageId.get(c.messageId) ?? [];
      list.push(toCommentDto(c));
      commentsByMessageId.set(c.messageId, list);
    }
    res.json(
      rows.map((m) => ({
        ...toMessageDto({ ...m, attachments: attachmentsByMessageId[m.id] }),
        comments: commentsByMessageId.get(m.id) ?? [],
        outOfWindow: false,
      })),
    );
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
    // 사진 여러 장짜리 메시지의 첨부 목록을 한 번에 붙인다(없으면 toMessageDto가 예전 방식으로
    // messages의 파일 칸을 첨부 하나로 본다).
    // 투표 메시지에는 보기·집계와 "내가 고른 보기/즐겨찾기"(요청자 기준)를 붙인다(polls.js).
    // 공감(이모지 반응)도 붙인다(reactions.js) — 비밀 대화는 공감을 받지 않아 늘 빈 목록이다.
    const all = await attachReactions(await attachPolls([...extraParents, ...rows], req.user.sub));
    const attachmentsByMessageId = await listAttachmentsForMessages(all.map((m) => m.id));
    // 보드 게시글은 "내가 읽었는지"(boardExtras.js — 게시글 상세를 연 적이 있는지, 쓴 사람은 늘 읽음)를 붙인다.
    const isBoard = room.type === 'topic' && room.viewMode === 'board';
    const readIds = isBoard ? await readPostIdsOf(req.user.sub, all.filter((m) => m.type === 'post').map((m) => m.id)) : null;
    res.json(
      all.map((m) => ({
        ...toMessageDto({ ...m, attachments: attachmentsByMessageId[m.id] }),
        comments: commentsByMessageId.get(m.id) ?? [],
        outOfWindow: extraParentIds.has(m.id),
        ...(readIds && m.type === 'post' ? { readByMe: m.senderId === req.user.sub || readIds.has(m.id) } : {}),
      })),
    );
  });

  /**
   * "대화 내보내기" — 이 방의 메시지 전체(또는 [since]~[until] 기간)를 엑셀(.xlsx)로 받는다.
   * 비밀 대화는 서버가 평문을 아예 모르므로(종단간 암호화, secretChats.js 참고) 애초에
   * 대상에서 뺀다. 큰 방도 메모리에 한 번에 안 올리도록 exceljs의 스트리밍 writer로 바로
   * 응답에 흘려보낸다(iterateMessagesForExport와 짝).
   */
  router.get('/rooms/:id/export', async (req, res) => {
    const room = await findRoomById(req.params.id);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    if (!(await isRoomMember(room.id, req.user.sub))) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
    if (room.isSecret) {
      return res.status(400).json({ error: '비밀 대화는 서버가 내용을 알 수 없어 내보낼 수 없습니다.' });
    }

    const sinceMs = Number(req.query.since);
    const untilMs = Number(req.query.until);
    const since = Number.isFinite(sinceMs) && sinceMs > 0 ? new Date(sinceMs) : null;
    const until = Number.isFinite(untilMs) && untilMs > 0 ? new Date(untilMs) : null;
    // DM "진짜 나가기" 이력이 있으면(dm_history_floors) 그 시각 이전 메시지는 이 요청자에게
    // 아예 없는 것처럼 뺀다 — /rooms/:id/messages와 같은 규칙.
    const floor = room.type === 'dm' ? await getDmHistoryFloor(room.id, req.user.sub) : null;

    // 실제 로컬 파일명은 클라이언트가 방 이름 + 기간으로 직접 짓는다(서버는 DM 상대방 이름을
    // 알려면 추가 조회가 필요해서 여기서는 신경 쓰지 않는다) — 이 헤더는 브라우저 등 다른
    // 클라이언트로 접속했을 때를 위한 기본값일 뿐이다.
    const asciiFallback = 'chat-export.xlsx';
    const utf8Name = '대화내역.xlsx';
    res.setHeader(
      'Content-Type',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    );
    res.setHeader(
      'Content-Disposition',
      `attachment; filename="${asciiFallback}"; filename*=UTF-8''${encodeURIComponent(utf8Name)}`,
    );

    const workbook = new ExcelJS.stream.xlsx.WorkbookWriter({ stream: res, useStyles: true });
    const sheet = workbook.addWorksheet('대화 내역');
    sheet.columns = [
      { header: '시간', key: 'time', width: 20, style: { numFmt: 'yyyy-mm-dd hh:mm:ss' } },
      { header: '보낸사람', key: 'sender', width: 16 },
      { header: '내용', key: 'content', width: 80 },
    ];
    sheet.getRow(1).font = { bold: true };

    for await (const batch of iterateMessagesForExport({ roomId: room.id, since, until, floor })) {
      for (const m of batch) {
        sheet
          .addRow({ time: m.createdAt, sender: m.senderName, content: exportContentFor(m) })
          .commit();
      }
    }
    await sheet.commit();
    await workbook.commit();
  });

  return router;
}

/** "대화 내보내기" 셀 내용 — push.js의 previewFor와 같은 규칙이지만, 미리보기 한 줄이 아니라
 * 엑셀 셀이라 파일명까지 그대로 적어준다. 삭제된 메시지는 소프트 삭제로 내용이 이미 비어
 * 있으므로(softDeleteMessage) 그 사실만 표시한다. */
function exportContentFor(m) {
  if (m.deletedAt) return '(삭제된 메시지)';
  const suffix = m.editedAt ? ' (수정됨)' : '';
  switch (m.type) {
    case 'text':
    case 'system':
      return (m.text ?? '') + suffix;
    case 'image':
      return (m.fileName ? `[사진: ${m.fileName}]` : '[사진]') + suffix;
    case 'file':
      return (m.fileName ? `[파일: ${m.fileName}]` : '[파일]') + suffix;
    case 'sticker':
      return '[이모티콘]' + suffix;
    case 'post':
      // 보드 뷰 게시글 — 제목 줄 다음에 본문 전체(첨부는 파일 보기에서 받는다).
      return `[게시글] ${m.title ?? ''}\n${m.text ?? ''}` + suffix;
    case 'poll':
      // 투표 — messages.text에 제목이 들어 있다(보기·결과는 앱에서 본다).
      return `[투표] ${m.text ?? ''}`;
    default:
      return (m.text ?? '') + suffix;
  }
}
