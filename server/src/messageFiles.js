// 파일 삭제 — 잔디의 "파일 삭제"와 같다: 업로드한 본인 또는 팀 관리자가 지울 수 있고, 파일이 사라져도 그 파일에 달린
// 댓글은 남는다. 소프트 삭제라 메시지·댓글은 그대로 두고 디스크 파일도 지우지 않는다(db/queries/fileDelete.js).
// 규칙은 fileDeletePlan.js(순수), 이 파일은 권한 확인 + 저장 + 브로드캐스트를 엮는다.
import { Router } from 'express';
import { topicAccess } from './access.js';
import { recordModerationAudit } from './moderation.js';
import { canModerateContent } from './permissions.js';
import { canDeleteFile, planFileDelete } from './fileDeletePlan.js';
import { applyFileDelete } from './db/queries/fileDelete.js';
import { findMessageById, listAttachmentsForMessages } from './db/queries/messages.js';
import { findRoomById } from './db/queries/rooms.js';
import { findTeamById } from './db/queries/teams.js';
import { toMessageDto } from './messages.js';

export function createMessageFilesRouter(io) {
  const router = Router();

  /** [attachmentId]가 null이면 옛 단일 파일 칸의 파일이다. 읽기 전용·보관 토픽에서도 막지 않는다(메시지 삭제와 같다). */
  async function deleteFile(req, res, attachmentId) {
    const message = await findMessageById(req.params.messageId);
    if (!message || message.deletedAt) return res.status(404).json({ error: '메시지를 찾을 수 없습니다.' });
    const room = await findRoomById(message.roomId);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });

    const access = await topicAccess(room, req.user.sub);
    const allowed = canDeleteFile({
      senderId: message.senderId,
      requesterId: req.user.sub,
      isRoomMember: access.isRoomMember,
      isSecret: !!room.isSecret,
      isModerator: canModerateContent(access),
    });
    if (!allowed) {
      return res
        .status(403)
        .json({ error: access.isRoomMember ? '파일을 올린 사람 또는 팀 관리자만 삭제할 수 있습니다.' : '이 방의 멤버가 아닙니다.' });
    }
    // 팀이 메시지 수정/삭제를 끈 경우(moderation.js canModifyContent 1번 규칙)는 파일 삭제도 막는다 — 기록을 남겨야 하는 팀을 위한 스위치.
    const team = await findTeamById(room.teamId);
    if (team && team.messageEditDeleteEnabled === false) {
      return res.status(403).json({ error: '이 팀은 메시지 수정/삭제를 사용하지 않도록 설정되어 있습니다.' });
    }

    const rows = (await listAttachmentsForMessages([message.id]))[message.id] ?? [];
    const plan = planFileDelete({ message, rows, attachmentId });
    if (!plan.ok) return res.status(plan.status).json({ error: plan.error });

    // 남의 파일을 지운 경우(= 관리자 콘텐츠 관리)만 감사 로그에 남긴다.
    if (message.senderId !== req.user.sub) await recordModerationAudit(req, message, 'file');

    await applyFileDelete(message.id, { plan, message, userId: req.user.sub });

    const row = await findMessageById(message.id);
    const after = (await listAttachmentsForMessages([message.id]))[message.id];
    const dto = toMessageDto({ ...row, attachments: after });
    io.to(message.roomId).emit('message:edited', dto);
    res.json(dto);
  }

  router.delete('/messages/:messageId/attachments/:attachmentId', (req, res) =>
    deleteFile(req, res, req.params.attachmentId),
  );
  router.delete('/messages/:messageId/file', (req, res) => deleteFile(req, res, null));

  return router;
}
