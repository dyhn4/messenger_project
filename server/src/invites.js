import crypto from 'node:crypto';
import { Router } from 'express';
import { AUDIT, recordAudit } from './audit.js';
import { inviteLinkAccess } from './access.js';
import {
  findInviteLinkById,
  insertInviteLink,
  isInviteLinkValid,
  listInviteLinksByCreator,
  revokeInviteLink,
} from './db/queries/inviteLinks.js';
import { EXTERNAL_ADDRESS, PAIRING_PORT } from './config.js';
import { canCreateInviteLink } from './permissions.js';

/** 초대 링크는 발급되면 항상 이 기간(일)만큼만 유효하다 — 굳이 고를 필요 없게 고정. */
export const INVITE_EXPIRY_DAYS = 7;

/** 초대 링크 하나가 유효한 동안 여러 기기가 나눠 쓸 수 있으므로, 사람이 손으로 입력할 일은
 * 거의 없다 — 그래서 4자리 페어링 코드보다 훨씬 길고 무작위한 값으로 만든다(96비트). */
function generateToken() {
  return crypto.randomBytes(12).toString('hex');
}

/** 클라이언트/랜딩 페이지에 내려줄 모양으로 다듬는다. */
function toInviteLinkDto(link, { serverAddress }) {
  return {
    id: link.id,
    token: link.token,
    label: link.label ?? null,
    createdByName: link.createdByName,
    createdAt: new Date(link.createdAt).getTime(),
    expiresAt: new Date(link.expiresAt).getTime(),
    revoked: !!link.revokedAt,
    usedCount: link.usedCount,
    lastUsedAt: link.lastUsedAt ? new Date(link.lastUsedAt).getTime() : null,
    valid: isInviteLinkValid(link),
    // 안내 페이지 URL — 평문 HTTP(페어링 포트)라 자체 서명 인증서 경고 없이 브라우저로 열린다.
    url: serverAddress ? `http://${serverAddress.host}:${PAIRING_PORT}/invite/${link.token}` : null,
    // 사내망 밖(LTE/5G)에서 열 주소 — 외부 주소(EXTERNAL_ADDRESS)가 있을 때만. 공유기에서 페어링 포트도
    // 같은 번호로 열어둬야 한다(밖에서는 안내 페이지·설치 파일만 열린다 — pairing.js).
    externalUrl: EXTERNAL_ADDRESS ? `http://${EXTERNAL_ADDRESS.host}:${PAIRING_PORT}/invite/${link.token}` : null,
  };
}

/** req로 지금 요청받은 호스트를 알아내 링크에 실을 주소를 만든다(포트는 PAIRING_PORT로 고정). */
function serverAddressFrom(req) {
  const host = req.hostname; // Express가 Host 헤더에서 포트를 뺀 호스트명만 준다.
  return host ? { host } : null;
}

export function createInvitesRouter() {
  const router = Router();

  router.use('/invite-links', async (req, res, next) => {
    const access = await inviteLinkAccess(req.user.sub);
    if (!canCreateInviteLink(access)) {
      return res.status(403).json({ error: '초대 링크는 서버 운영자·팀 소유자·관리자만 만들 수 있습니다.' });
    }
    req.inviteActor = access;
    next();
  });

  /** 내가 만든 초대 링크 목록(최신순) — 서버 전체가 아니라 내 것만 보여준다. */
  router.get('/invite-links', async (req, res) => {
    const links = await listInviteLinksByCreator(req.user.sub);
    const serverAddress = serverAddressFrom(req);
    res.json(links.map((l) => toInviteLinkDto(l, { serverAddress })));
  });

  /** 새 초대 링크 발급. 유효기간은 항상 INVITE_EXPIRY_DAYS(7일)로 고정. */
  router.post('/invite-links', async (req, res) => {
    const label = typeof req.body?.label === 'string' ? req.body.label.trim().slice(0, 30) : null;

    const link = await insertInviteLink({
      token: generateToken(),
      createdBy: req.user.sub,
      createdByName: req.inviteActor.user?.name ?? req.inviteActor.user?.username ?? '(알 수 없음)',
      label: label || null,
      expiresAt: new Date(Date.now() + INVITE_EXPIRY_DAYS * 24 * 60 * 60 * 1000),
    });

    recordAudit({
      actorId: req.user.sub,
      actorName: link.createdByName,
      action: AUDIT.inviteLinkCreate,
      targetType: 'invite',
      targetId: link.id,
      targetLabel: label ?? undefined,
      detail: `초대 링크 발급(${INVITE_EXPIRY_DAYS}일)`,
    });

    res.status(201).json(toInviteLinkDto(link, { serverAddress: serverAddressFrom(req) }));
  });

  /** 폐기 — 아직 안 쓴 만료 전 링크도 즉시 못 쓰게 막는다. 내가 만든 링크만 지울 수 있다. */
  router.delete('/invite-links/:id', async (req, res) => {
    const mine = await findInviteLinkById(req.params.id);
    if (!mine || mine.createdBy !== req.user.sub) {
      return res.status(404).json({ error: '초대 링크를 찾을 수 없습니다.' });
    }

    const revoked = await revokeInviteLink(mine.id);
    recordAudit({
      actorId: req.user.sub,
      actorName: req.inviteActor.user?.name ?? req.inviteActor.user?.username ?? '(알 수 없음)',
      action: AUDIT.inviteLinkRevoke,
      targetType: 'invite',
      targetId: mine.id,
      targetLabel: mine.label ?? undefined,
      detail: '초대 링크 폐기',
    });
    res.json(toInviteLinkDto(revoked, { serverAddress: serverAddressFrom(req) }));
  });

  return router;
}
