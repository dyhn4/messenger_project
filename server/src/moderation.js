import { AUDIT, recordAudit } from './audit.js';
import { teamAccess } from './access.js';
import { findRoomById, isRoomMember } from './db/queries/rooms.js';
import { findTeamById } from './db/queries/teams.js';
import { findUserById } from './db/queries/users.js';
import { canModerateContent, editDeleteWindowSeconds, formatWindow } from './permissions.js';

/**
 * 메시지/댓글을 수정하거나 지울 수 있는지 한 번에 판단한다(messages.js와 comments.js가 같은
 * 규칙을 쓰도록 여기 하나로 모았다). 통과하면 `{ ok: true }`, 아니면 그대로 응답할 수 있는
 * `{ ok: false, status, error }`를 돌려준다.
 *
 * 규칙:
 *  1. 팀 설정 [메시지 설정] → [메시지 수정/삭제]가 꺼져 있으면 **아무도**(소유자·관리자 포함)
 *     고치거나 지울 수 없다 — 대화 기록을 그대로 남겨야 하는 팀을 위한 스위치.
 *  2. 본인 글이면 그대로 통과.
 *  3. 남의 글은 **삭제만** 가능하다(수정은 내용 위조가 되므로 관리자도 절대 불가). 삭제하려면
 *     세 조건을 **모두** 만족해야 한다:
 *       - 그 방이 속한 팀에서 소유자 또는 관리자이고,
 *       - **그 방의 멤버**이며(초대받지 않은 비공개 토픽/그룹/1:1 대화는 관리자도 볼 수 없어
 *         관리도 못 한다),
 *       - 비밀 대화(E2EE) 방이 아니다(서버가 내용을 볼 수 없는 대화라 관리 대상에서 뺀다).
 *  4. 본인이든 관리자든 **팀이 정한 수정/삭제 가능 시간 안**이어야 한다(기본 5분).
 *
 * [action]은 'edit' | 'delete'. 안내 문구를 그에 맞게 만드는 데도 쓴다.
 */
export async function canModifyContent({ roomId, senderId, createdAt, requesterId, action, noun = '메시지' }) {
  const verb = action === 'edit' ? '수정' : '삭제';

  const room = await findRoomById(roomId);
  if (!room) return { ok: false, status: 404, error: '방을 찾을 수 없습니다.' };

  const team = await findTeamById(room.teamId);
  if (team && team.messageEditDeleteEnabled === false) {
    return { ok: false, status: 403, error: `이 팀은 메시지 수정/삭제를 사용하지 않도록 설정되어 있습니다.` };
  }

  if (senderId !== requesterId) {
    const denied = { ok: false, status: 403, error: `본인 ${noun}만 ${verb}할 수 있습니다.` };
    if (action !== 'delete') return denied; // 남의 글 수정은 관리자도 불가
    if (room.isSecret) return denied;
    if (!(await isRoomMember(room.id, requesterId))) return denied;
    // 남의 글 삭제 = 그 팀을 관리할 수 있는 사람(팀 소유자 또는 계정 등급 관리자).
    const access = await teamAccess(room.teamId, requesterId);
    if (!canModerateContent(access)) return denied;
  }

  const windowSeconds = editDeleteWindowSeconds(team);
  if (Date.now() - new Date(createdAt).getTime() > windowSeconds * 1000) {
    return {
      ok: false,
      status: 403,
      error: `작성 후 ${formatWindow(windowSeconds)}이 지나 ${verb}할 수 없습니다.`,
    };
  }

  return { ok: true };
}

/**
 * 관리자가 **남의** 메시지/댓글을 지웠을 때 감사 로그에 남긴다(본인 글 삭제는 대상 아님 —
 * 호출부에서 걸러서 부른다). 어느 팀·어느 방이었는지와 원래 작성자를 스냅샷으로 남겨서,
 * 나중에 방이 사라져도 무슨 일이었는지 알 수 있게 한다.
 */
export async function recordModerationAudit(req, content, kind) {
  const room = await findRoomById(content.roomId);
  const team = room ? await findTeamById(room.teamId) : null;
  const actor = await findUserById(req.user.sub);
  const label = kind === 'comment' ? '댓글' : '메시지';

  recordAudit({
    actorId: req.user.sub,
    actorName: actor?.name ?? actor?.username ?? '(알 수 없음)',
    action: kind === 'comment' ? AUDIT.commentDelete : AUDIT.messageDelete,
    teamId: team?.id ?? null,
    teamName: team?.name ?? null,
    targetType: kind,
    targetId: content.id,
    targetLabel: content.senderName,
    detail: `${room?.name ?? '대화방'}에서 ${content.senderName} 님의 ${label} 삭제`,
  });
}
