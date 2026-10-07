import crypto from 'node:crypto';
import { Router } from 'express';
import { AUDIT, recordAudit } from './audit.js';
import { inviteLinkAccess } from './access.js';
import {
  findInviteLinkById,
  insertInviteLink,
  isInviteLinkOpen,
  isInviteLinkValid,
  listInviteLinksByCreator,
  revokeInviteLink,
} from './db/queries/inviteLinks.js';
import { findUserById } from './db/queries/users.js';
import { EXTERNAL_ADDRESS, PAIRING_PORT } from './config.js';
import { canCreateInviteLink } from './permissions.js';

/** 초대 링크는 발급되면 항상 이 기간(일)만큼만 유효하다 — 굳이 고를 필요 없게 고정. */
export const INVITE_EXPIRY_DAYS = 7;

/**
 * 링크 하나로 가입할 수 있는 사람 수 — 만들 때 고른다(기본 1명, 최대 100명). 사내망 밖에서는 초대 링크가 곧 가입
 * 자격이라(auth.js), 링크가 메시지 전달 등으로 새도 끝없이 가입되지 않게 하려는 것이다. 팀 초대 링크도 같은 범위를
 * 쓴다(teamInvites.js의 teamInviteMaxUses).
 */
export const INVITE_MAX_USES_LIMIT = 100;

export function inviteMaxUses(requested) {
  const n = Number(requested);
  if (!Number.isInteger(n) || n < 1) return 1;
  return Math.min(n, INVITE_MAX_USES_LIMIT);
}

/**
 * 초대 링크를 만든 사람(inviteLinkAccess의 결과)이 지금 초대 링크를 줄 수 있는 사람인지 — 발급할 때와 링크가 쓰일
 * 때(inviteLinkConnectable·inviteLinkJoinable) 같은 기준으로 본다. 정지·탈퇴한 계정은 등급과 상관없이 안 된다.
 */
export function inviteCreatorAllowed(creator) {
  const user = creator?.user;
  return !!user && !user.deletedAt && !user.suspendedAt && canCreateInviteLink(creator);
}

/**
 * 링크를 만든 사람이 지금도 초대 링크를 줄 수 있는지 DB에서 새로 읽어 본다. 링크는 7일 동안 살아 있는데, 그 사이 만든
 * 사람이 관리자 등급이나 팀 소유자에서 내려오거나 정지·탈퇴하면, 그 사람이 더는 줄 수 없는 연결·"사내망 밖 가입 자격"을
 * 링크가 계속 주게 된다(팀 초대 링크도 같은 이유로 teamInvites.js가 다시 본다).
 */
async function creatorStillAllowed(link) {
  return !!link.createdBy && inviteCreatorAllowed(await inviteLinkAccess(link.createdBy));
}

/**
 * 이 링크로 앱을 이 서버에 연결할 수 있는지 — 인증서 받기·안내 페이지·설치 파일(pairing.js)이 본다. 취소·만료되지 않았고
 * 만든 사람이 지금도 초대 링크를 줄 수 있으면 되고, 가입 인원은 보지 않는다: 이 링크로 가입한 사람도 집 PC 등 다른 기기를
 * 연결하거나 앱을 다시 설치할 때 같은 링크를 다시 쓰는데(아니면 서버 운영자에게 페어링 코드나 새 링크를 받아야 한다),
 * 인증서는 원래 공개 정보라 인원이 찼다고 막아도 얻는 게 없다. 이것만으로는 계정을 만들 수 없다 — 가입은 inviteLinkJoinable.
 */
export async function inviteLinkConnectable(link) {
  return isInviteLinkOpen(link) && (await creatorStillAllowed(link));
}

/**
 * 지금 이 링크로 가입할 수 있는지 — 연결할 수 있고 가입 인원도 남았을 때(isInviteLinkValid). 사내망 밖에서는 이게 곧 가입
 * 자격이다(auth.js — 실제 자리는 가입할 때 consumeInviteLink가 한 문장으로 잡는다).
 */
export async function inviteLinkJoinable(link) {
  return isInviteLinkValid(link) && (await creatorStillAllowed(link));
}

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
    // 이 링크로 가입한 사람 수(페어링은 세지 않는다)와 가입할 수 있는 사람 수 — null은 제한이 생기기 전에 만든 링크.
    usedCount: link.usedCount,
    maxUses: link.maxUses ?? null,
    lastUsedAt: link.lastUsedAt ? new Date(link.lastUsedAt).getTime() : null,
    // 이 링크로 새로 가입시킬 수 있는지(열려 있고 인원이 남음). 인원이 다 차도 만료 전에는 연결·설치에 쓰이므로(위
    // inviteLinkConnectable) 앱은 취소·만료 여부(revoked·expiresAt)를 따로 보고 취소 버튼을 남긴다.
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

  // 만들 수 있는 사람인지(inviteCreatorAllowed)는 새로 만들 때(POST)만 본다 — 목록·폐기는 그 권한을 잃은 뒤에도
  // "내가 만든 링크"라면 된다. 관리자 등급이나 팀 소유자에서 내려온 사람도 아직 남아 있는 자기 링크를 확인하고
  // 거둘 수 있어야 해서다(남이 만든 링크는 어느 경우에도 보이지 않고 지울 수도 없다).

  /** 내가 만든 초대 링크 목록(최신순) — 서버 전체가 아니라 내 것만 보여준다. */
  router.get('/invite-links', async (req, res) => {
    const links = await listInviteLinksByCreator(req.user.sub);
    const serverAddress = serverAddressFrom(req);
    res.json(links.map((l) => toInviteLinkDto(l, { serverAddress })));
  });

  /** 새 초대 링크 발급. 유효기간은 항상 INVITE_EXPIRY_DAYS(7일)로 고정, 가입 인원은 고른 만큼(inviteMaxUses). */
  router.post('/invite-links', async (req, res) => {
    const actor = await inviteLinkAccess(req.user.sub);
    if (!inviteCreatorAllowed(actor)) {
      return res.status(403).json({ error: '초대 링크는 서버 운영자·팀 소유자·관리자만 만들 수 있습니다.' });
    }
    const label = typeof req.body?.label === 'string' ? req.body.label.trim().slice(0, 30) : null;

    const link = await insertInviteLink({
      token: generateToken(),
      createdBy: req.user.sub,
      createdByName: actor.user.name ?? actor.user.username ?? '(알 수 없음)',
      label: label || null,
      maxUses: inviteMaxUses(req.body?.maxUses),
      expiresAt: new Date(Date.now() + INVITE_EXPIRY_DAYS * 24 * 60 * 60 * 1000),
    });

    recordAudit({
      actorId: req.user.sub,
      actorName: link.createdByName,
      action: AUDIT.inviteLinkCreate,
      targetType: 'invite',
      targetId: link.id,
      targetLabel: label ?? undefined,
      detail: `초대 링크 발급(${INVITE_EXPIRY_DAYS}일, ${link.maxUses}명)`,
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
    const me = await findUserById(req.user.sub);
    recordAudit({
      actorId: req.user.sub,
      actorName: me?.name ?? me?.username ?? '(알 수 없음)',
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
