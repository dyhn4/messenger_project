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
import { findPositionOptionByLabel } from './db/queries/positionOptions.js';
import { EXTERNAL_ADDRESS, PAIRING_PORT } from './config.js';
import { ACCOUNT_ROLES, canCreateTeamInviteLink, canManageTeam, roleLabel, ROLE_RANK } from './permissions.js';

/** 팀 초대 링크도 설치→가입 초대 링크와 같은 기간만큼만 유효하다 — 고를 필요 없게 고정. */
export const TEAM_INVITE_EXPIRY_DAYS = 7;

/**
 * 링크 하나로 가입할 수 있는 사람 수 — 만들 때 고른다(기본 1명, 최대 100명). 링크가 메시지 전달 등으로 새도
 * 끝없이 가입되지 않게 하려는 것이다. 관리자 등급을 주는 링크는 늘 1명이다(관리자는 모든 팀을 관리할 수 있어서).
 */
export const TEAM_INVITE_MAX_USES_LIMIT = 100;

export function teamInviteMaxUses(requested, assignedRole) {
  if (assignedRole === 'admin') return 1;
  const n = Number(requested);
  if (!Number.isInteger(n) || n < 1) return 1;
  return Math.min(n, TEAM_INVITE_MAX_USES_LIMIT);
}

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
    assignedPosition: link.assignedPosition ?? null,
    label: link.label ?? null,
    createdByName: link.createdByName,
    createdAt: new Date(link.createdAt).getTime(),
    expiresAt: new Date(link.expiresAt).getTime(),
    revoked: !!link.revokedAt,
    usedCount: link.usedCount,
    maxUses: link.maxUses ?? null,
    lastUsedAt: link.lastUsedAt ? new Date(link.lastUsedAt).getTime() : null,
    valid: isTeamInviteLinkValid(link),
    // 설치 초대 링크와 같은 평문 페어링 포트로 서빙 — 자체 서명 인증서 경고 없이 열린다.
    url: serverAddress ? `http://${serverAddress.host}:${PAIRING_PORT}/team-invite/${link.token}` : null,
    // 사내망 밖(LTE/5G)에서 열 주소 — 외부 주소(EXTERNAL_ADDRESS)가 있을 때만. 공유기에서 페어링 포트도
    // 같은 번호로 열어둬야 한다(밖에서는 안내 페이지·설치 파일만 열린다 — pairing.js).
    externalUrl: EXTERNAL_ADDRESS ? `http://${EXTERNAL_ADDRESS.host}:${PAIRING_PORT}/team-invite/${link.token}` : null,
  };
}

function serverAddressFrom(req) {
  const host = req.hostname;
  return host ? { host } : null;
}

export function createTeamInvitesRouter() {
  const router = Router();

  // 서버 설정(server_settings.teamInviteLinkCreation)이 정한 최소 등급 이상만 — 팀 생성
  // 권한(teams.js POST /teams)과 같은 구조의 서버 전역 게이트다. 이건 "이 서버에서 초대
  // 링크를 만들 수 있는 계정 등급인가"만 보고, "이 팀에 대해 만들 자격이 있는가"(멤버십 +
  // canManageTeam)는 실제로 링크를 만드는 POST 라우트에서 팀 단위로 따로 확인한다.
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
    // 정회원도(teamInviteLinkCreation 설정에 따라) 링크를 만들 수 있는데, 자기보다 높은
    // 등급을 남에게 부여할 수 있게 두면 권한 상승 구멍이 된다 — 서버 운영자는 관리자
    // 콘솔에서 이미 자유롭게 등급을 바꿀 수 있는 사람이라 이 제한에서 뺀다.
    if (!req.inviteActor.isServerAdmin && ROLE_RANK[assignedRole] > ROLE_RANK[req.inviteActor.role]) {
      return res.status(403).json({ error: '자신의 등급보다 높은 등급은 부여할 수 없습니다.' });
    }
    const membership = await teamAccess(teamId, req.user.sub);
    if (!membership.isMember) {
      return res.status(403).json({ error: '내가 속한 팀에만 초대 링크를 만들 수 있습니다.' });
    }
    // 위 미들웨어의 서버 전역 등급만으로는 부족하다 — 그 팀을 실제로 관리할 수 있는
    // 사람(소유자 또는 계정 등급 관리자)만 만들 수 있어야 한다. 클라이언트는 이 버튼을 팀
    // 설정 안에만 두지만(team_settings_dialog.dart, 팀 설정 자체가 canManageTeam으로 막혀
    // 있음), 서버가 같이 막지 않으면 API를 직접 부르는 평범한 팀원도 "가입과 동시에 등급이
    // 자동 부여되는" 링크를 만들 수 있다.
    if (!canManageTeam(membership)) {
      return res.status(403).json({ error: '팀 초대 링크는 팀 소유자나 관리자만 만들 수 있습니다.' });
    }
    const label = typeof req.body?.label === 'string' ? req.body.label.trim().slice(0, 30) : null;

    // 직책도(선택 사항) 등급과 같은 이유로 "내 서열 이하"만 부여할 수 있게 막는다 — 안 그러면
    // 나보다 높은 직책을 남에게 줄 수 있는 권한 상승 구멍이 된다. 직책 목록의 순서(sortOrder)는
    // **작을수록 서열이 낮다**(기본 목록이 사원(0)→대표(7) 순인 것과 같은 방향)로 비교한다.
    let assignedPosition = null;
    if (typeof req.body?.assignedPosition === 'string' && req.body.assignedPosition) {
      const target = await findPositionOptionByLabel(req.body.assignedPosition);
      if (!target) return res.status(400).json({ error: '직책 목록에 없는 값입니다.' });
      const myPosition = req.inviteActor.user?.position
        ? await findPositionOptionByLabel(req.inviteActor.user.position)
        : null;
      if (!myPosition || target.sortOrder > myPosition.sortOrder) {
        return res.status(403).json({ error: '자신의 직책보다 높은 직책은 부여할 수 없습니다.' });
      }
      assignedPosition = target.label;
    }

    const inserted = await insertTeamInviteLink({
      token: generateToken(),
      teamId,
      assignedRole,
      assignedPosition,
      createdBy: req.user.sub,
      createdByName: req.inviteActor.user?.name ?? req.inviteActor.user?.username ?? '(알 수 없음)',
      label: label || null,
      maxUses: teamInviteMaxUses(req.body?.maxUses, assignedRole),
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
      detail:
        `팀 초대 링크 발급(${roleLabel(assignedRole)} 등급` +
        (assignedPosition ? ` · ${assignedPosition} 직책` : '') +
        ` 부여, ${TEAM_INVITE_EXPIRY_DAYS}일, ${link.maxUses}명)`,
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
