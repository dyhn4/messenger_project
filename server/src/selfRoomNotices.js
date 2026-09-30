import { hasBotMessage } from './db/queries/messages.js';
import { withRoomLock } from './db/queries/rooms.js';
import { findTeamById, listTeamManagerIds } from './db/queries/teams.js';
import { nameOf, openSelfRoom, postBotMessage } from './rooms.js';

/**
 * 나와의 대화로 보내는 안내 — 발신자는 사람이 아니라 '탱고톡'이고(postBotMessage), 안읽음·방 목록 미리보기·
 * 푸시가 사람 메시지처럼 나간다. 팀에 들어온 사람에게는 사용 안내를(팀마다 한 번), 팀 관리자(그 팀의 소유자 +
 * 계정 등급이 관리자인 팀원)에게는 누가 들어오고 나갔는지를 알린다 — 그 일을 한 본인에게는 보내지 않는다.
 * 안내가 실패해도 팀 합류·제외 자체를 막으면 안 되므로 여기서 오류를 삼키고 로그만 남긴다.
 */
export const SELF_ROOM_BOT_NAME = '탱고톡';
export const SELF_ROOM_WELCOME_TEXT =
  "탱고톡에 오신 것을 환영합니다! 🎉\n여기는 나만 보는 '나와의 대화'예요. 메모나 파일을 자유롭게 저장해 두세요.\n사용법은 오른쪽 위 ☰ 메뉴의 '도움말'에서 볼 수 있어요.";

async function postToSelfRoom(io, userId, teamId, text) {
  const room = await openSelfRoom(io, userId, teamId);
  await postBotMessage(io, room, text, { senderName: SELF_ROOM_BOT_NAME });
}

/** 사용 안내 — 이미 받은 적이 있으면(팀에서 빠졌다가 다시 들어온 경우 등) 또 보내지 않는다. 동시에 두 번 불려도
 * 한 번만 가도록 그 사람의 나와의 대화 방을 잠근 채로 확인하고 올린다. */
async function welcome(io, userId, teamId) {
  const room = await openSelfRoom(io, userId, teamId);
  await withRoomLock(room.id, async (tx) => {
    if (await hasBotMessage(room.id, SELF_ROOM_BOT_NAME, SELF_ROOM_WELCOME_TEXT, tx)) return;
    await postBotMessage(io, room, SELF_ROOM_WELCOME_TEXT, { senderName: SELF_ROOM_BOT_NAME });
  });
}

/**
 * 팀에 새로 들어온 사람들([joinerIds] — 이미 멤버였던 사람은 빼고 넘긴다) — 본인에게 사용 안내, 팀 관리자들
 * ([actorId]와 들어온 본인 제외)에게 "OOO 님이 OO팀에 참여했습니다.". 팀 생성·팀원 추가·팀 초대 링크 가입이 부른다.
 */
export async function announceTeamJoin(io, { teamId, joinerIds, actorId = null }) {
  if (joinerIds.length === 0) return;
  try {
    const team = await findTeamById(teamId);
    if (!team) return;
    for (const userId of joinerIds) {
      await welcome(io, userId, teamId).catch((err) =>
        console.error('[selfRoom] 환영 안내 실패:', err?.message ?? err),
      );
    }
    const managerIds = await listTeamManagerIds(teamId);
    for (const joinerId of joinerIds) {
      // 팀 이름 뒤에 '팀'을 덧붙이지 않는다('개발팀 팀' 방지) — '에'/'에서'는 받침과 상관없이 붙는다.
      const text = `${await nameOf(joinerId)} 님이 ${team.name}에 참여했습니다.`;
      for (const managerId of managerIds) {
        if (managerId === actorId || managerId === joinerId) continue;
        await postToSelfRoom(io, managerId, teamId, text).catch((err) =>
          console.error('[selfRoom] 팀 참여 알림 실패:', err?.message ?? err),
        );
      }
    }
  } catch (err) {
    console.error('[selfRoom] 팀 참여 안내 실패:', err?.message ?? err);
  }
}

/** 팀에서 제외된 사람([userId]) — 팀 관리자들([actorId] 제외)에게 "OOO 님이 OO팀에서 제외되었습니다.". */
export async function announceTeamRemoval(io, { teamId, userId, actorId = null }) {
  try {
    const team = await findTeamById(teamId);
    if (!team) return;
    const text = `${await nameOf(userId)} 님이 ${team.name}에서 제외되었습니다.`;
    for (const managerId of await listTeamManagerIds(teamId)) {
      if (managerId === actorId || managerId === userId) continue;
      await postToSelfRoom(io, managerId, teamId, text).catch((err) =>
        console.error('[selfRoom] 팀 제외 알림 실패:', err?.message ?? err),
      );
    }
  } catch (err) {
    console.error('[selfRoom] 팀 제외 안내 실패:', err?.message ?? err);
  }
}
