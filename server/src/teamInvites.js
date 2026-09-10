import crypto from 'node:crypto';
import { Router } from 'express';
import { AUDIT, recordAudit } from './audit.js';
import { userAccess, teamAccess } from './access.js';
import {
  findTeamInviteLinkById,
  insertTeamInviteLink,
  isTeamInviteLinkValid,
  listTeamInviteLinksByCreator,
  revokeTeamInviteLink,
} from './db/queries/teamInviteLinks.js';
import { getServerSettings } from './db/queries/serverSettings.js';
import { PAIRING_PORT } from './config.js';
import { ACCOUNT_ROLES, canCreateTeamInviteLink, roleLabel } from './permissions.js';

/** 팀 초대 링크도 설치→가입 초대 링크와 같은 기간만큼만 유효하다 — 고를 필요 없게 고정. */
export const TEAM_INVITE_EXPIRY_DAYS = 7;

/** 4자리 페어링 코드/설치 초대 링크 토큰과 겹치지 않도록 같은 방식(96비트 무작위)으로 만든다. */
function generateToken() {
  return crypto.randomBytes(12).toString('hex');
}

function toTeamInviteLinkDto(link, { serverAddress }) {
  return {
    id: link.id,
    token: link.token,
    teamId: link.teamId,
    teamName: link.teamName,
    assignedRole: link.assignedRole,
    label: link.label ?? null,
    createdByName: link.createdByName,
    createdAt: new Date(link.createdAt).getTime(),
    expiresAt: new Date(link.expiresAt).getTime(),
    revoked: !!link.revokedAt,
    usedCount: link.usedCount,
    lastUsedAt: link.lastUsedAt ? new Date(link.lastUsedAt).getTime() : null,
    valid: isTeamInviteLinkValid(link),
    // 설치 초대 링크와 같은 평문 페어링 포트로 서빙 — 자체 서명 인증서 경고 없이 열린다.
    url: serverAddress ? `http://${serverAddress.host}:${PAIRING_PORT}/team-invite/${link.token}` : null,
  };
}

function serverAddressFrom(req) {
  const host = req.hostname;
  return host ? { host } : null;
}

export function createTeamInvitesRouter() {
  const router = Router();

  // 서버 설정(server_settings.teamInviteLinkCreation)이 정한 최소 등급 이상만 — 팀 생성
  // 권한(teams.js POST /teams)과 같은 구조의 서버 전역 게이트다. 특정 팀에 대한 권한(그
  // 팀의 소유자/관리자인지)은 실제로 링크를 만드는 POST 라우트에서 팀 단위로 따로 확인한다.
  router.use('/team-invite-links', async (req, res, next) => {
    const [access, settings] = await Promise.all([userAccess(req.user.sub), getServerSettings()]);
    if (!canCreateTeamInviteLink({ ...access, teamInviteLinkCreation: settings.teamInviteLinkCreation })) {
      const need = { serverAdmin: '서버 운영자', admin: '관리자 이상', member: '정회원 이상' }[settings.teamInviteLinkCreation] ?? '관리자 이상';
      return res.status(403).json({ error: `팀 초대 링크는 ${need}만 만들 수 있도록 설정되어 있습니다.` });
    }
    req.inviteActor = access;
    next();
  });

  /** 내가 만든 팀 초대 링크 목록(최신순). */
  router.get('/team-invite-links', async (req, res) => {
    const links = await listTeamInviteLinksByCreator(req.user.sub);
    const serverAddress = serverAddressFrom(req);
    res.json(links.map((l) => toTeamInviteLinkDto(l, { serverAddress })));
  });

  /** 새 팀 초대 링크 발급 — 내가 속한 팀에만 만들 수 있다(서버 전역 권한과 별개로, 아무
   * 관계 없는 팀에 초대장을 뿌릴 수는 없어야 하므로). */
  router.post('/team-invite-links', async (req, res) => {
    const teamId = req.body?.teamId;
    const assignedRole = req.body?.assignedRole;
    if (typeof teamId !== 'string' || !teamId) {
      return res.status(400).json({ error: '팀을 선택하세요.' });
    }
    if (!ACCOUNT_ROLES.includes(assignedRole)) {
      return res.status(400).json({ error: '부여할 등급은 준회원/정회원/관리자 중에서 고를 수 있습니다.' });
    }
    const membership = await teamAccess(teamId, req.user.sub);
    if (!membership.isMember) {
      return res.status(403).json({ error: '내가 속한 팀에만 초대 링크를 만들 수 있습니다.' });
    }
    const label = typeof req.body?.label === 'string' ? req.body.label.trim().slice(0, 30) : null;

    const inserted = await insertTeamInviteLink({
      token: generateToken(),
      teamId,
      assignedRole,
      createdBy: req.user.sub,
      createdByName: req.inviteActor.user?.name ?? req.inviteActor.user?.username ?? '(알 수 없음)',
      label: label || null,
      expiresAt: new Date(Date.now() + TEAM_INVITE_EXPIRY_DAYS * 24 * 60 * 60 * 1000),
    });
    const link = await findTeamInviteLinkById(inserted.id);

    recordAudit({
      actorId: req.user.sub,
      actorName: link.createdByName,
      action: AUDIT.teamInviteLinkCreate,
      teamId,
      teamName: link.teamName,
      targetType: 'teamInvite',
      targetId: link.id,
      targetLabel: label ?? undefined,
      detail: `팀 초대 링크 발급(${roleLabel(assignedRole)} 등급 부여, ${TEAM_INVITE_EXPIRY_DAYS}일)`,
    });

    res.status(201).json(toTeamInviteLinkDto(link, { serverAddress: serverAddressFrom(req) }));
  });

  /** 폐기 — 내가 만든 링크만 지울 수 있다. */
  router.delete('/team-invite-links/:id', async (req, res) => {
    const mine = await findTeamInviteLinkById(req.params.id);
    if (!mine || mine.createdBy !== req.user.sub) {
      return res.status(404).json({ error: '팀 초대 링크를 찾을 수 없습니다.' });
    }

    const revoked = await revokeTeamInviteLink(mine.id);
    const link = await findTeamInviteLinkById(revoked.id);
    recordAudit({
      actorId: req.user.sub,
      actorName: req.inviteActor.user?.name ?? req.inviteActor.user?.username ?? '(알 수 없음)',
      action: AUDIT.teamInviteLinkRevoke,
      teamId: mine.teamId,
      teamName: mine.teamName,
      targetType: 'teamInvite',
      targetId: mine.id,
      targetLabel: mine.label ?? undefined,
      detail: '팀 초대 링크 폐기',
    });
    res.json(toTeamInviteLinkDto(link, { serverAddress: serverAddressFrom(req) }));
  });

  return router;
}
