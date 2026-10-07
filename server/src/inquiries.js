import { randomUUID } from 'node:crypto';
import { Router } from 'express';
import {
  findInquiryById,
  insertInquiry,
  listInquiriesForRecipient,
  listInquiriesForSender,
  updateInquiryStatus,
} from './db/queries/inquiries.js';
import { findRoomById, isRoomMember, listRoomMemberIds } from './db/queries/rooms.js';
import { findUserById } from './db/queries/users.js';
import { isUuid } from './favoritesRules.js';
import { checkFileRefs } from './fileRefs.js';
import { fileFieldsDenial, INQUIRY_CATEGORY_MAX, sanitizeFileSize } from './messageLimits.js';
import { resolvePosition } from './orgInfo.js';
import { graphemeLength, SELF_ROOM_DENIAL } from './permissions.js';
import { signFileUrl } from './upload.js';

const STATUSES = ['open', 'in_progress', 'resolved'];

function toDto(row) {
  return {
    ...row,
    createdAt: new Date(row.createdAt).getTime(),
    statusUpdatedAt: row.statusUpdatedAt ? new Date(row.statusUpdatedAt).getTime() : null,
    fileUrl: signFileUrl(row.fileUrl, row.fileName),
    thumbnailUrl: signFileUrl(row.thumbnailUrl),
  };
}

/**
 * "팀장에게 문의하기" — 1:1(평문) 대화방에서, 상대가 그 팀에서 "팀장" 직책인 경우에만 보낼 수
 * 있다(chat_input_bar.dart의 문의하기 버튼도 같은 조건으로 보이는지 여부를 정하지만, 여기서
 * 다시 확인한다). 실제 대화 메시지는 여기서 안 만든다 — 클라이언트가 이 API 호출과 별개로
 * chatSocket.send로 같은 내용을 그 방에 일반 메시지로도 보낸다(그래야 팀장이 기존 메시지
 * 알림/푸시로 바로 알 수 있다). 이 테이블은 순수하게 "문의 처리 현황 추적"만 담당한다.
 */
export function createInquiriesRouter(io) {
  const router = Router();

  router.post('/rooms/:id/inquiries', async (req, res) => {
    const room = await findRoomById(req.params.id);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    if (room.isSelf) return res.status(400).json({ error: SELF_ROOM_DENIAL });
    if (room.type !== 'dm' || room.isSecret) {
      return res.status(400).json({ error: '1:1 대화방에서만 문의할 수 있습니다.' });
    }
    if (!(await isRoomMember(room.id, req.user.sub))) {
      return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
    }

    const memberIds = await listRoomMemberIds(room.id);
    const recipientId = memberIds.find((id) => id !== req.user.sub);
    if (!recipientId) return res.status(400).json({ error: '상대를 찾을 수 없습니다.' });

    const recipientPosition = await resolvePosition(recipientId, room.teamId);
    if (recipientPosition !== '팀장') {
      return res.status(403).json({ error: '팀장에게만 문의할 수 있습니다.' });
    }

    const title = typeof req.body?.title === 'string' ? req.body.title.trim() : '';
    const category = typeof req.body?.category === 'string' ? req.body.category.trim() : '';
    const content = typeof req.body?.content === 'string' ? req.body.content.trim() : '';
    if (!title) return res.status(400).json({ error: '제목을 입력하세요.' });
    if (title.length > 100) return res.status(400).json({ error: '제목은 100자 이내로 작성하세요.' });
    if (!category) return res.status(400).json({ error: '분류를 선택하세요.' });
    // 분류는 앱이 정해 둔 몇 개 중에서 고른다(client models/inquiry.dart) — 문의함 목록에 그대로 보이므로 길이만큼은 막는다.
    if (graphemeLength(category) > INQUIRY_CATEGORY_MAX) return res.status(400).json({ error: '분류가 올바르지 않습니다.' });
    if (!content) return res.status(400).json({ error: '내용을 입력하세요.' });
    if (content.length > 2000) return res.status(400).json({ error: '내용은 2000자 이내로 작성하세요.' });

    // 첨부(선택) — 클라이언트가 /api/upload로 이미 올린 뒤 그 결과 URL만 여기로 보낸다
    // (chat_input_bar.dart의 _InquiryDialog 참고). 예전엔 보낸 값을 확인도 되돌리기도 없이 저장했다 — 이제 메시지와 같은 규칙으로
    // 직접 올린 파일(또는 지금 볼 수 있는 방의 파일)만 받는다(fileRefs.js).
    const rawFileUrl = typeof req.body?.fileUrl === 'string' && req.body.fileUrl ? req.body.fileUrl : null;
    const rawThumbnailUrl =
      typeof req.body?.thumbnailUrl === 'string' && req.body.thumbnailUrl ? req.body.thumbnailUrl : null;
    const fileName = typeof req.body?.fileName === 'string' ? req.body.fileName : null;
    const fileSize = sanitizeFileSize(req.body?.fileSize);
    const mimeType = typeof req.body?.mimeType === 'string' ? req.body.mimeType : null;
    const fileDenial = fileFieldsDenial({ fileName, mimeType });
    if (fileDenial) return res.status(400).json({ error: fileDenial });
    const files = await checkFileRefs([rawFileUrl, rawThumbnailUrl], { senderId: req.user.sub });
    if (!files.ok) return res.status(400).json({ error: files.error });
    const fileUrl = rawFileUrl ? files.paths.get(rawFileUrl) : null;
    const thumbnailUrl = rawThumbnailUrl ? files.paths.get(rawThumbnailUrl) : null;

    const [sender, recipient] = await Promise.all([findUserById(req.user.sub), findUserById(recipientId)]);
    const row = await insertInquiry({
      id: randomUUID(),
      teamId: room.teamId,
      roomId: room.id,
      senderId: req.user.sub,
      senderName: sender?.name ?? sender?.username ?? '알 수 없음',
      recipientId,
      recipientName: recipient?.name ?? recipient?.username ?? '알 수 없음',
      category,
      title,
      content,
      fileUrl,
      fileName,
      fileSize,
      mimeType,
      thumbnailUrl,
    });
    const dto = toDto(row);
    // 목록 화면을 열어둔 팀장에게 실시간으로 새 문의를 알린다(대화 알림은 클라이언트가 별도로
    // 보내는 메시지가 기존 message:new 알림 경로를 그대로 타므로 여기서 또 만들 필요 없다).
    io.to(`user:${recipientId}`).emit('inquiry:new', dto);
    res.status(201).json(dto);
  });

  /** 내가 받은 문의(팀장 시점) — ?status=open|in_progress|resolved로 좁힐 수 있다. */
  router.get('/inquiries/received', async (req, res) => {
    const status = typeof req.query.status === 'string' ? req.query.status : null;
    if (status && !STATUSES.includes(status)) {
      return res.status(400).json({ error: '상태 값이 올바르지 않습니다.' });
    }
    const rows = await listInquiriesForRecipient(req.user.sub, status);
    res.json(rows.map(toDto));
  });

  /** 내가 보낸 문의 — 처리 현황을 직접 확인할 수 있어야 의미가 있어서 만든다. */
  router.get('/inquiries/sent', async (req, res) => {
    const rows = await listInquiriesForSender(req.user.sub);
    res.json(rows.map(toDto));
  });

  /** 상태 변경 — 받는 사람(팀장) 본인만 가능. */
  router.patch('/inquiries/:id', async (req, res) => {
    const inquiry = isUuid(req.params.id) ? await findInquiryById(req.params.id) : null;
    if (!inquiry) return res.status(404).json({ error: '문의를 찾을 수 없습니다.' });
    if (inquiry.recipientId !== req.user.sub) {
      return res.status(403).json({ error: '본인에게 온 문의만 처리할 수 있습니다.' });
    }
    const status = req.body?.status;
    if (!STATUSES.includes(status)) {
      return res.status(400).json({ error: '상태 값이 올바르지 않습니다.' });
    }

    const row = await updateInquiryStatus(inquiry.id, status);
    const dto = toDto(row);
    // 보낸 사람은 처리 현황이 바뀌는 걸 실시간으로 알아야 하고(그게 이 기능의 핵심 목적),
    // 받은 사람(나) 쪽도 다른 기기가 열어둔 목록이 있으면 같이 갱신되게 둘 다에게 보낸다.
    io.to(`user:${inquiry.senderId}`).emit('inquiry:statusChanged', dto);
    io.to(`user:${inquiry.recipientId}`).emit('inquiry:statusChanged', dto);
    res.json(dto);
  });

  return router;
}
