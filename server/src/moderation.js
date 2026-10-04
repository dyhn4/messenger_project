import { AUDIT, recordAudit } from './audit.js';
import { topicAccess } from './access.js';
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
 * 보드 뷰 게시글([isPost])은 두 가지가 다르다 — 남의 게시글은 팀 관리자뿐 아니라 **그 토픽의
 * 토픽 관리자**도 지울 수 있고(토픽을 관리할 수 있는 사람, permissions.js canManageTopic), 오래
 * 두고 고쳐 쓰는 글이라 **수정/삭제 가능 시간 제한이 없다**(1번 팀 스위치는 그대로 따른다).
 *
 * 투표([isPoll])도 게시글처럼 **수정/삭제 가능 시간 제한이 없고**, 남의 투표는 팀 관리자(소유자·관리자
 * 등급)와 — 토픽이면 — 토픽 관리자가 지울 수 있다(투표는 그룹·1:1에도 올라와서 게시글과 달리 토픽
 * 관리자만으로 좁히지 않는다). 투표 자체는 수정할 수 없으므로 action은 실제로 'delete'만 온다.
 *
 * 공지·할 일 댓글([isSimpleComment])은 투표와 같다 — 수정/삭제 가능 시간 제한이 없고, 남의 댓글은 팀 관리자와
 * (토픽이면) 토픽 관리자가 지울 수 있다. 수정은 다른 글처럼 본인만.
 *
 * [action]은 'edit' | 'delete'. 안내 문구를 그에 맞게 만드는 데도 쓴다.
 */
export async function canModifyContent({
  roomId,
  senderId,
  createdAt,
  requesterId,
  action,
  noun,
  isPost = false,
  isPoll = false,
  isSimpleComment = false,
}) {
  const verb = action === 'edit' ? '수정' : '삭제';
  noun ??= isPoll ? '투표' : isPost ? '게시글' : '메시지';

  const room = await findRoomById(roomId);
  if (!room) return { ok: false, status: 404, error: '방을 찾을 수 없습니다.' };
  // 나갔거나 내보내진 사람은 자기 글이라도 더 이상 고치거나 지울 수 없다 — 예전 id로 남은 멤버들의
  // 대화를 바깥에서 바꾸지 못하게(시간 제한이 없는 게시글은 특히).
  if (!(await isRoomMember(room.id, requesterId))) {
    return { ok: false, status: 403, error: '이 방의 멤버가 아닙니다.' };
  }

  const team = await findTeamById(room.teamId);
  if (team && team.messageEditDeleteEnabled === false) {
    return { ok: false, status: 403, error: `이 팀은 메시지 수정/삭제를 사용하지 않도록 설정되어 있습니다.` };
  }

  if (senderId !== requesterId) {
    const denied = { ok: false, status: 403, error: `본인 ${noun}만 ${verb}할 수 있습니다.` };
    if (action !== 'delete') return denied; // 남의 글 수정은 관리자도 불가
    if (room.isSecret) return denied;
    const access = await topicAccess(room, requesterId);
    if (!access.isRoomMember) return denied;
    // 남의 글 삭제 = 그 팀을 관리할 수 있는 사람(팀 소유자 또는 계정 등급 관리자). 게시글은
    // 토픽 관리자까지(access.canManage — 팀 관리자도 포함한다).
    const allowed =
      isPoll || isSimpleComment
      ? access.canManage || canModerateContent(access)
      : isPost
        ? access.canManage
        : canModerateContent(access);
    if (!allowed) return denied;
  }

  const windowSeconds = editDeleteWindowSeconds(team);
  if (!isPost && !isPoll && !isSimpleComment && Date.now() - new Date(createdAt).getTime() > windowSeconds * 1000) {
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
  // 게시글('post')·투표('poll')는 행위 코드는 메시지 삭제 그대로 두고(관리자 콘솔 필터가 같은 항목으로 묶임) 문구만 구분한다.
  const label = { comment: '댓글', post: '게시글', poll: '투표', file: '파일' }[kind] ?? '메시지';

  recordAudit({
    actorId: req.user.sub,
    actorName: actor?.name ?? actor?.username ?? '(알 수 없음)',
    action: kind === 'comment' ? AUDIT.commentDelete : AUDIT.messageDelete,
    teamId: team?.id ?? null,
    teamName: team?.name ?? null,
    targetType: kind === 'comment' ? 'comment' : 'message',
    targetId: content.id,
    targetLabel: content.senderName,
    detail: `${room?.name ?? '대화방'}에서 ${content.senderName} 님의 ${label} 삭제`,
  });
}
