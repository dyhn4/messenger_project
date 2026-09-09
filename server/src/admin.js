import fs from 'node:fs';
import path from 'node:path';
import bcrypt from 'bcryptjs';
import { Router } from 'express';
import { AUDIT, recordAudit, toAuditLogDto } from './audit.js';
import { UPLOADS_DIR } from './config.js';
import { listAuditLogs } from './db/queries/audit.js';
import { countMessages, countMessagesToday, countRooms, countTeams } from './db/queries/stats.js';
import { getServerSettings, updateServerSettings } from './db/queries/serverSettings.js';
import { listTeamIdsForUser, listTeamMemberIds, listTeamsForUser } from './db/queries/teams.js';
import { countActiveUsers, findUserById, listAllUsersForAdmin, updateUser } from './db/queries/users.js';
import { db } from './db/client.js';
import { teams as teamsTable } from './db/schema.js';
import { isOnline } from './presence.js';
import { accountRole, ACCOUNT_ROLES, roleLabel, TEAM_CREATION_LEVELS } from './permissions.js';
import { addRoomMembers, listPublicTopics, listRoomMemberIds } from './db/queries/rooms.js';
import { notifyMembership, postSystemMessage } from './rooms.js';

/**
 * 서버 운영자(users.isServerAdmin)만 쓸 수 있는 관리자 콘솔 API.
 *
 * 계정 등급(준회원/정회원/관리자)과도 별개의 축이다 — 계정 등급은 "이 서버에서 무엇을 할 수
 * 있는지"이고, 서버 운영자는 "그 등급을 정하고 서버를 관리하는 사람"이다. 그래서 권한 검사도
 * 등급이 아니라 isServerAdmin 하나로만 한다.
 */
export function createAdminRouter(io) {
  const router = Router();

  // 이 라우터는 '/api'에 통째로 마운트되므로(index.js), 경로를 '/admin'으로 좁혀서 걸어야
  // 한다 — 경로 없이 router.use(...)로 걸면 /api/teams 같은 다른 요청까지 전부 이 검사를
  // 거치면서 일반 회원이 403을 받는다.
  router.use('/admin', async (req, res, next) => {
    const me = await findUserById(req.user.sub);
    if (!me || me.deletedAt || !me.isServerAdmin) {
      return res.status(403).json({ error: '서버 운영자만 접근할 수 있습니다.' });
    }
    req.admin = me;
    next();
  });

  /** 감사 로그의 "누가"에 쓸 이름. */
  const actorOf = (req) => ({ actorId: req.admin.id, actorName: req.admin.name ?? req.admin.username });

  // ─────────────────────────────── 운영 현황 ───────────────────────────────

  /** 대시보드 숫자들. 업로드 폴더 용량은 파일을 훑어야 해서 여기서만 계산한다. */
  router.get('/admin/stats', async (req, res) => {
    const [userCount, teamCount, roomCount, messageCount, todayCount, settings] = await Promise.all([
      countActiveUsers(),
      countTeams(),
      countRooms(),
      countMessages(),
      countMessagesToday(),
      getServerSettings(),
    ]);
    res.json({
      users: userCount,
      teams: teamCount,
      rooms: roomCount,
      messages: messageCount,
      messagesToday: todayCount,
      uploadBytes: uploadsDirSize(),
      serverStartedAt: Math.round(Date.now() - process.uptime() * 1000),
      teamCreation: settings.teamCreation,
      orgScope: settings.orgScope,
    });
  });

  /** 서버 설정 변경(지금은 팀 생성 권한 하나). */
  router.patch('/admin/settings', async (req, res) => {
    const fields = {};
    if ('teamCreation' in (req.body ?? {})) {
      const value = req.body.teamCreation;
      if (!TEAM_CREATION_LEVELS.includes(value)) {
        return res.status(400).json({ error: '팀 생성 권한은 정회원/관리자/서버 운영자 중에서 고를 수 있습니다.' });
      }
      fields.teamCreation = value;
    }
    if ('orgScope' in (req.body ?? {})) {
      const value = req.body.orgScope;
      if (value !== 'team' && value !== 'account') {
        return res.status(400).json({ error: "orgScope는 'team' 또는 'account'여야 합니다." });
      }
      fields.orgScope = value;
    }
    if (Object.keys(fields).length === 0) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });

    const updated = await updateServerSettings(fields);
    const detail = [];
    if (fields.teamCreation) {
      detail.push(`팀 생성 권한: ${TEAM_CREATION_LABEL[updated.teamCreation] ?? updated.teamCreation}`);
    }
    if (fields.orgScope) {
      detail.push(`부서·직책 관리: ${updated.orgScope === 'account' ? '계정 단위' : '팀 단위'}`);
    }
    recordAudit({ ...actorOf(req), action: AUDIT.serverSettings, detail: detail.join(', ') });
    res.json(updated);
  });

  // ─────────────────────────────── 회원 관리 ───────────────────────────────

  /** 전체 회원 목록(탈퇴 포함) + 각자의 소속 팀. */
  router.get('/admin/users', async (req, res) => {
    const rows = await listAllUsersForAdmin();
    const dtos = [];
    for (const u of rows) {
      const teamRows = await listTeamsForUser(u.id);
      dtos.push(toAdminUserDto(u, teamRows));
    }
    res.json(dtos);
  });

  /**
   * 계정 등급 변경(준회원/정회원/관리자) — **서버 운영자만** 할 수 있는 일이다.
   * 준회원 → 정회원 이상으로 올리면, 그동안 빠져 있던 그 사람 소속 팀들의 공개 토픽에
   * 자동으로 넣어준다(준회원은 공개 토픽 자동 참여 대상이 아니었으므로 따라잡아 주는 것).
   */
  router.post('/admin/users/:id/role', async (req, res) => {
    const target = await requireTarget(req, res);
    if (!target) return;
    const newRole = req.body?.role;
    if (!ACCOUNT_ROLES.includes(newRole)) {
      return res.status(400).json({ error: '등급은 준회원/정회원/관리자 중에서 고를 수 있습니다.' });
    }
    const before = accountRole(target);
    if (before === newRole) return res.json(toAdminUserDto(target, await listTeamsForUser(target.id)));

    const updated = await updateUser(target.id, { role: newRole });

    if (before === 'guest' && newRole !== 'guest') {
      for (const teamId of await listTeamIdsForUser(target.id)) {
        for (const room of await listPublicTopics(teamId)) {
          const memberIds = await listRoomMemberIds(room.id);
          if (memberIds.includes(target.id)) continue;
          await addRoomMembers(room.id, [target.id]);
          await notifyMembership(io, room);
          await postSystemMessage(io, room, `${target.name ?? target.username} 님이 참여했습니다.`);
        }
      }
    }

    recordAudit({
      ...actorOf(req),
      action: AUDIT.userRole,
      targetType: 'user',
      targetId: target.id,
      targetLabel: target.name ?? target.username,
      detail: `등급 ${roleLabel(before)} → ${roleLabel(newRole)}`,
    });
    res.json(toAdminUserDto(updated, await listTeamsForUser(target.id)));
  });

  /** 부서/직책 변경(계정 단위로 관리하는 설정일 때 관리자 콘솔에서 쓴다). */
  router.patch('/admin/users/:id/org', async (req, res) => {
    const target = await requireTarget(req, res);
    if (!target) return;
    const fields = {};
    for (const key of ['department', 'position']) {
      if (key in (req.body ?? {})) {
        const v = typeof req.body[key] === 'string' ? req.body[key].trim() : '';
        if (v.length > 30) return res.status(400).json({ error: '부서·직책은 30자 이내로 입력하세요.' });
        fields[key] = v || null;
      }
    }
    if (Object.keys(fields).length === 0) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });

    const updated = await updateUser(target.id, fields);
    recordAudit({
      ...actorOf(req),
      action: AUDIT.userOrg,
      targetType: 'user',
      targetId: target.id,
      targetLabel: target.name ?? target.username,
      detail: `부서·직책: ${[fields.department, fields.position].filter(Boolean).join(' / ') || '지움'}`,
    });
    res.json(toAdminUserDto(updated, await listTeamsForUser(target.id)));
  });

  /** 계정 정지/해제 — 정지되면 로그인·토큰 재발급·소켓 연결이 모두 막힌다. */
  router.post('/admin/users/:id/suspend', async (req, res) => {
    const target = await requireTarget(req, res);
    if (!target) return;
    const suspend = req.body?.suspended !== false;
    if (suspend && target.id === req.admin.id) {
      return res.status(400).json({ error: '자기 계정은 정지할 수 없습니다.' });
    }

    // 정지하면서 tokenVersion을 올려야 이미 로그인해 있는 기기도 즉시 끊긴다.
    const updated = await updateUser(target.id, {
      suspendedAt: suspend ? new Date() : null,
      ...(suspend ? { tokenVersion: (target.tokenVersion ?? 0) + 1 } : {}),
    });
    if (suspend) disconnectUserSockets(io, target.id);

    recordAudit({
      ...actorOf(req),
      action: suspend ? AUDIT.userSuspend : AUDIT.userUnsuspend,
      targetType: 'user',
      targetId: target.id,
      targetLabel: target.name ?? target.username,
      detail: suspend ? '계정 정지' : '정지 해제',
    });
    res.json(toAdminUserDto(updated, await listTeamsForUser(target.id)));
  });

  /** 모든 기기에서 강제 로그아웃(tokenVersion을 올려 기존 토큰을 전부 무효화). */
  router.post('/admin/users/:id/logout-all', async (req, res) => {
    const target = await requireTarget(req, res);
    if (!target) return;
    const updated = await updateUser(target.id, { tokenVersion: (target.tokenVersion ?? 0) + 1 });
    disconnectUserSockets(io, target.id);

    recordAudit({
      ...actorOf(req),
      action: AUDIT.userLogoutAll,
      targetType: 'user',
      targetId: target.id,
      targetLabel: target.name ?? target.username,
      detail: '모든 기기에서 강제 로그아웃',
    });
    res.json(toAdminUserDto(updated, await listTeamsForUser(target.id)));
  });

  /**
   * 비밀번호 초기화 대행 — 운영자가 임시 비밀번호를 정해서 알려주는 방식이다.
   * (서버가 임의 문자열을 만들어 화면에 보여줄 수도 있지만, 어차피 운영자가 당사자에게
   * 직접 전달해야 하므로 입력받는 편이 단순하고 실수도 적다.)
   */
  router.post('/admin/users/:id/reset-password', async (req, res) => {
    const target = await requireTarget(req, res);
    if (!target) return;
    const password = typeof req.body?.password === 'string' ? req.body.password : '';
    if (password.length < 4 || password.length > 20) {
      return res.status(400).json({ error: '비밀번호는 4~20자여야 합니다.' });
    }

    await updateUser(target.id, {
      passwordHash: await bcrypt.hash(password, 10),
      tokenVersion: (target.tokenVersion ?? 0) + 1, // 기존 로그인 전부 무효화
    });
    disconnectUserSockets(io, target.id);

    recordAudit({
      ...actorOf(req),
      action: AUDIT.userResetPassword,
      targetType: 'user',
      targetId: target.id,
      targetLabel: target.name ?? target.username,
      detail: '운영자가 비밀번호를 초기화함',
    });
    res.json({ ok: true });
  });

  /** 서버 운영자 지정/해제. 마지막 운영자는 스스로 내려올 수 없다(아무도 못 들어가게 되므로). */
  router.post('/admin/users/:id/server-admin', async (req, res) => {
    const target = await requireTarget(req, res);
    if (!target) return;
    const grant = req.body?.isServerAdmin !== false;

    if (!grant) {
      const remaining = (await listAllUsersForAdmin()).filter(
        (u) => u.isServerAdmin && !u.deletedAt && u.id !== target.id,
      );
      if (remaining.length === 0) {
        return res.status(400).json({ error: '마지막 서버 운영자는 해제할 수 없습니다.' });
      }
    }

    const updated = await updateUser(target.id, { isServerAdmin: grant });
    recordAudit({
      ...actorOf(req),
      action: AUDIT.userServerAdmin,
      targetType: 'user',
      targetId: target.id,
      targetLabel: target.name ?? target.username,
      detail: grant ? '서버 운영자로 지정' : '서버 운영자 해제',
    });
    res.json(toAdminUserDto(updated, await listTeamsForUser(target.id)));
  });

  // ─────────────────────────────── 팀 관리 ───────────────────────────────

  /** 서버의 모든 팀(내가 속하지 않은 팀 포함) + 인원수. */
  router.get('/admin/teams', async (req, res) => {
    const rows = await db.select().from(teamsTable).orderBy(teamsTable.createdAt);
    const dtos = [];
    for (const team of rows) {
      const memberIds = await listTeamMemberIds(team.id);
      const creator = team.createdBy ? await findUserById(team.createdBy) : null;
      dtos.push({
        id: team.id,
        name: team.name,
        iconEmoji: team.iconEmoji ?? null,
        iconColor: team.iconColor ?? null,
        domain: team.domain ?? null,
        memberCount: memberIds.length,
        createdBy: creator ? (creator.name ?? creator.username) : null,
        createdAt: new Date(team.createdAt).getTime(),
      });
    }
    res.json(dtos);
  });

  // ─────────────────────────────── 감사 로그 ───────────────────────────────

  router.get('/admin/audit-logs', async (req, res) => {
    const limit = Math.min(Number(req.query.limit) || 50, 200);
    const offset = Math.max(Number(req.query.offset) || 0, 0);
    const { rows, total } = await listAuditLogs({
      action: typeof req.query.action === 'string' && req.query.action ? req.query.action : undefined,
      actorId: typeof req.query.actorId === 'string' && req.query.actorId ? req.query.actorId : undefined,
      teamId: typeof req.query.teamId === 'string' && req.query.teamId ? req.query.teamId : undefined,
      limit,
      offset,
    });
    res.json({ total, logs: rows.map(toAuditLogDto) });
  });

  /** :id로 지정한 대상 사용자를 찾아온다. 없으면 응답까지 끝내고 null. */
  async function requireTarget(req, res) {
    const target = await findUserById(req.params.id);
    if (!target) {
      res.status(404).json({ error: '사용자를 찾을 수 없습니다.' });
      return null;
    }
    return target;
  }

  return router;
}

/**
 * 관리자 콘솔용 사용자 DTO — 일반 publicUser와 달리 운영에 필요한 정보(가입일, 정지 여부,
 * 운영자 여부, 소속 팀)를 담고, 이메일은 여기서도 복호화하지 않는다(필요하면 프로필에서 본다).
 */
function toAdminUserDto(u, teamRows = []) {
  return {
    id: u.id,
    username: u.username,
    name: u.name ?? u.username,
    avatarType: u.avatarType ?? 'initial',
    avatarEmoji: u.avatarEmoji ?? null,
    avatarColor: u.avatarColor ?? null,
    online: isOnline(u.id),
    role: accountRole(u),
    department: u.department ?? null,
    position: u.position ?? null,
    isServerAdmin: !!u.isServerAdmin,
    suspended: !!u.suspendedAt,
    suspendedAt: u.suspendedAt ? new Date(u.suspendedAt).getTime() : null,
    deleted: !!u.deletedAt,
    createdAt: new Date(u.createdAt).getTime(),
    teams: teamRows.map(({ team, role }) => ({ id: team.id, name: team.name, role })),
  };
}

const TEAM_CREATION_LABEL = { member: '정회원 이상', admin: '관리자 이상', serverAdmin: '서버 운영자만' };

/** 정지/강제 로그아웃 직후 이미 붙어있는 소켓을 즉시 끊는다(다음 재연결부터는 토큰이 막힌다). */
function disconnectUserSockets(io, userId) {
  io.to(`user:${userId}`).disconnectSockets(true);
}

/** uploads 폴더 총 용량(바이트). 파일이 아주 많으면 느릴 수 있어 대시보드에서만 쓴다. */
function uploadsDirSize() {
  let total = 0;
  const walk = (dir) => {
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return; // 폴더가 없거나 권한이 없으면 0으로 둔다.
    }
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        walk(full);
      } else {
        try {
          total += fs.statSync(full).size;
        } catch {
          /* 그 사이 지워진 파일은 건너뛴다 */
        }
      }
    }
  };
  walk(UPLOADS_DIR);
  return total;
}
