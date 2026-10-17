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
import { isInviteLinkOpen } from './db/queries/inviteLinks.js';
import { getServerSettings } from './db/queries/serverSettings.js';
import { findPositionOptionByLabel } from './db/queries/positionOptions.js';
import { findUserById } from './db/queries/users.js';
import { EXTERNAL_ADDRESS, PAIRING_PORT } from './config.js';
import { inviteMaxUses } from './invites.js';
import { sendInviteMails } from './inviteMail.js';
import { ACCOUNT_ROLES, canCreateTeamInviteLink, canManageTeam, roleLabel, ROLE_RANK } from './permissions.js';

/** 팀 초대 링크도 설치→가입 초대 링크와 같은 기간만큼만 유효하다 — 고를 필요 없게 고정. */
export const TEAM_INVITE_EXPIRY_DAYS = 7;

/**
 * 링크 하나로 가입할 수 있는 사람 수 — 만들 때 고른다(기본 1명, 최대 100명 — 설치 초대 링크와 같은 범위, invites.js의
 * inviteMaxUses). 링크가 메시지 전달 등으로 새도 끝없이 가입되지 않게 하려는 것이다. 관리자 등급을 주는 링크는 늘
 * 1명이다(관리자는 모든 팀을 관리할 수 있어서).
 */
export function teamInviteMaxUses(requested, assignedRole) {
  if (assignedRole === 'admin') return 1;
  return inviteMaxUses(requested);
}

/**
 * 팀 초대 링크를 만든 사람이 지금도 이 링크를 만들 수 있는 사람인지 DB에서 새로 읽어 본다. 링크는 7일 동안 살아 있는데,
 * 그 사이 만든 사람이 팀에서 빠지거나 등급이 내려가거나 정지·탈퇴하면 그 사람이 더는 줄 수 없는 연결·팀 합류·등급을 링크가
 * 계속 주게 된다(아래 발급 조건과 같다: 그 팀을 관리할 수 있고, 부여 등급이 자기 등급 이하 — 서버 운영자는 등급 제한 없음).
 */
async function teamInviteCreatorAllowed(link) {
  if (!link.createdBy) return false;
  const creator = await teamAccess(link.teamId, link.createdBy);
  if (!creator.user || creator.user.deletedAt || creator.user.suspendedAt) return false;
  if (!creator.isMember || !canManageTeam(creator)) return false;
  return creator.isServerAdmin || ROLE_RANK[link.assignedRole] <= ROLE_RANK[creator.role];
}

/**
 * 이 팀 초대 링크로 앱을 이 서버에 연결할 수 있는지 — 인증서 받기·안내 페이지·설치 파일(pairing.js)이 본다. 취소·만료되지
 * 않았고 만든 사람이 지금도 이 링크를 줄 수 있으면 되고, 가입 인원은 보지 않는다(설치 초대의 inviteLinkConnectable과 같은
 * 이유 — 이 링크로 가입한 사람도 다른 기기를 연결하거나 다시 설치할 때 같은 링크를 쓴다). 가입·팀 합류는 teamInviteLinkJoinable.
 */
export async function teamInviteLinkConnectable(link) {
  return isInviteLinkOpen(link) && (await teamInviteCreatorAllowed(link));
}

/**
 * 지금 이 팀 초대 링크로 가입(팀 합류·등급 부여)할 수 있는지 — 연결할 수 있고 가입 인원도 남았을 때(auth.js — 실제 자리는
 * 가입할 때 consumeTeamInviteLink가 한 문장으로 잡는다).
 */
export async function teamInviteLinkJoinable(link) {
  return isTeamInviteLinkValid(link) && (await teamInviteCreatorAllowed(link));
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
    // 이 링크로 새로 가입시킬 수 있는지(열려 있고 인원이 남음) — 인원이 다 차도 만료 전에는 연결·설치에 쓰여서(위
    // teamInviteLinkConnectable) 앱은 취소·만료 여부를 따로 보고 취소 버튼을 남긴다(설치 초대 링크와 같다).
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

  // 만들 수 있는 사람인지는 새로 만들 때(POST)만 본다 — 목록·폐기는 그 권한을 잃은 뒤에도 "내가 만든 링크"라면
  // 된다. 등급이 내려가거나 서버 설정이 바뀌어 더는 못 만들게 된 사람도 아직 남아 있는 자기 링크를 확인하고
  // 거둘 수 있어야 해서다(남이 만든 링크는 어느 경우에도 보이지 않고 지울 수도 없다).

  /** 내가 만든 팀 초대 링크 목록(최신순). */
  router.get('/team-invite-links', async (req, res) => {
    const links = await listTeamInviteLinksByCreator(req.user.sub);
    const serverAddress = serverAddressFrom(req);
    res.json(links.map((l) => toTeamInviteLinkDto(l, { serverAddress })));
  });

  /** 새 팀 초대 링크 발급 — 내가 속한 팀에만 만들 수 있다(서버 전역 권한과 별개로, 아무
   * 관계 없는 팀에 초대장을 뿌릴 수는 없어야 하므로). */
  router.post('/team-invite-links', async (req, res) => {
    // 서버 설정(server_settings.teamInviteLinkCreation)이 정한 최소 등급 이상만 — 팀 생성
    // 권한(teams.js POST /teams)과 같은 구조의 서버 전역 게이트다. 이건 "이 서버에서 초대
    // 링크를 만들 수 있는 계정 등급인가"만 보고, "이 팀에 대해 만들 자격이 있는가"(멤버십 +
    // canManageTeam)는 아래에서 팀 단위로 따로 확인한다.
    const [actor, settings] = await Promise.all([userAccess(req.user.sub), getServerSettings()]);
    if (!canCreateTeamInviteLink({ ...actor, teamInviteLinkCreation: settings.teamInviteLinkCreation })) {
      const need = { serverAdmin: '서버 운영자', admin: '관리자 이상', member: '정회원 이상' }[settings.teamInviteLinkCreation] ?? '관리자 이상';
      return res.status(403).json({ error: `팀 초대 링크는 ${need}만 만들 수 있도록 설정되어 있습니다.` });
    }

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
    if (!actor.isServerAdmin && ROLE_RANK[assignedRole] > ROLE_RANK[actor.role]) {
      return res.status(403).json({ error: '자신의 등급보다 높은 등급은 부여할 수 없습니다.' });
    }
    const membership = await teamAccess(teamId, req.user.sub);
    if (!membership.isMember) {
      return res.status(403).json({ error: '내가 속한 팀에만 초대 링크를 만들 수 있습니다.' });
    }
    // 맨 위의 서버 전역 등급만으로는 부족하다 — 그 팀을 실제로 관리할 수 있는
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
      const myPosition = actor.user?.position
        ? await findPositionOptionByLabel(actor.user.position)
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
      createdByName: actor.user?.name ?? actor.user?.username ?? '(알 수 없음)',
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

  /**
   * 팀 초대 링크를 메일로 보낸다(메일이 켜진 서버에서만) — 내가 만든 링크이고 지금 그 링크로 가입할 수 있을 때만. 설치 초대
   * 메일과 같고(inviteMail.js), 본문에 팀 이름이 들어간다.
   */
  router.post('/team-invite-links/:id/email', async (req, res) => {
    const mine = await findTeamInviteLinkById(req.params.id);
    if (!mine || mine.createdBy !== req.user.sub) {
      return res.status(404).json({ error: '팀 초대 링크를 찾을 수 없습니다.' });
    }
    if (!(await teamInviteLinkJoinable(mine))) {
      return res.status(409).json({ error: '이 링크로는 더 이상 가입할 수 없습니다. 새 링크를 만들어 보내세요.' });
    }
    const me = await findUserById(req.user.sub);
    const actorName = me?.name ?? me?.username ?? '(알 수 없음)';
    await sendInviteMails(req, res, {
      link: mine,
      pathKind: 'team-invite',
      inviterName: me?.name ?? me?.username,
      teamName: mine.teamName,
      onSent: (count) =>
        recordAudit({
          actorId: req.user.sub,
          actorName,
          action: AUDIT.teamInviteLinkEmail,
          teamId: mine.teamId,
          teamName: mine.teamName,
          targetType: 'teamInvite',
          targetId: mine.id,
          targetLabel: mine.label ?? undefined,
          detail: `팀 초대 메일 ${count}통 보냄`,
        }),
    });
  });

  /** 폐기 — 내가 만든 링크만 지울 수 있다. */
  router.delete('/team-invite-links/:id', async (req, res) => {
    const mine = await findTeamInviteLinkById(req.params.id);
    if (!mine || mine.createdBy !== req.user.sub) {
      return res.status(404).json({ error: '팀 초대 링크를 찾을 수 없습니다.' });
    }

    const revoked = await revokeTeamInviteLink(mine.id);
    const link = await findTeamInviteLinkById(revoked.id);
    const me = await findUserById(req.user.sub);
    recordAudit({
      actorId: req.user.sub,
      actorName: me?.name ?? me?.username ?? '(알 수 없음)',
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
