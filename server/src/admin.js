import fs from 'node:fs';
import path from 'node:path';
import { Router } from 'express';
import { cert } from 'firebase-admin/app';
import { AUDIT, recordAudit, toAuditLogDto } from './audit.js';
import { safeAvatarColor } from './avatarRules.js';
import { endUserCallAccess } from './callAccess.js';
import { UPLOADS_DIR } from './config.js';
import { encryptField } from './crypto.js';
import { isDuckDnsToken, parseDuckDnsDomains } from './ddns.js';
import { ddnsUpdater } from './ddnsService.js';
import { signFileUrl } from './upload.js';
import { listAuditLogs } from './db/queries/audit.js';
import { clearPushTargetsForUser } from './db/queries/devices.js';
import { countMessages, countMessagesToday, countRooms, countTeams } from './db/queries/stats.js';
import { getServerSettings, updateServerSettings } from './db/queries/serverSettings.js';
import { invalidateMessagingCache } from './push.js';
import { getWebCertificateStatus } from './webTls.js';
import {
  deletePositionOption,
  findPositionOptionByLabel,
  insertPositionOption,
  listPositionOptions,
  reorderPositionOptions,
  toggleDefaultPositionOption,
} from './db/queries/positionOptions.js';
import { listTeamIdsForUser, listTeamMemberIds, listTeamsForUser } from './db/queries/teams.js';
import {
  countActiveUsers,
  findUserById,
  listAllUsersForAdmin,
  updateUser,
  updateUserUnlessLastServerAdmin,
} from './db/queries/users.js';
import { db } from './db/client.js';
import { teams as teamsTable } from './db/schema.js';
import { isOnline } from './presence.js';
import { accountRole, ACCOUNT_ROLES, roleLabel, TEAM_CREATION_LEVELS } from './permissions.js';
import {
  addRoomMembers,
  clearTopicAdminRoles,
  findRoomById,
  listAutoInviteTopics,
  listRoomMemberIds,
} from './db/queries/rooms.js';
import { notifyMembership, notifyTodosResynced, postSystemMessage, toRoomDto } from './rooms.js';

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
    if (!me || me.deletedAt || me.suspendedAt || !me.isServerAdmin) {
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
      teamInviteLinkCreation: settings.teamInviteLinkCreation,
      orgScope: settings.orgScope,
      projectCreation: settings.projectCreation,
    });
  });

  /**
   * 웹 앱 전용 주소(.env WEB_DOMAIN)의 공인 인증서(Let's Encrypt) 상태 — 발급·갱신은 서버가 알아서 하고 여기서는 보기만 한다.
   * { enabled, domain, status: 'off'|'pending'|'valid'|'expiring'|'error', staging, expiresAt, lastAttemptAt, lastError,
   *   nextAttemptAt, challenges: { http01, tlsAlpn01 }, webUrl, … }(시각은 ms) — 자세한 뜻은 webTls.js getWebCertificateStatus.
   */
  router.get('/admin/web-certificate', (req, res) => {
    res.json(getWebCertificateStatus());
  });

  /** 서버 설정 변경(팀 생성 권한 / 팀 초대 링크 생성 권한 / 프로젝트 생성 권한 / 팀·직책 관리 범위). */
  router.patch('/admin/settings', async (req, res) => {
    const fields = {};
    if ('teamCreation' in (req.body ?? {})) {
      const value = req.body.teamCreation;
      if (!TEAM_CREATION_LEVELS.includes(value)) {
        return res.status(400).json({ error: '팀 생성 권한은 정회원/관리자/서버 운영자 중에서 고를 수 있습니다.' });
      }
      fields.teamCreation = value;
    }
    if ('teamInviteLinkCreation' in (req.body ?? {})) {
      const value = req.body.teamInviteLinkCreation;
      if (!TEAM_CREATION_LEVELS.includes(value)) {
        return res.status(400).json({ error: '팀 초대 링크 생성 권한은 정회원/관리자/서버 운영자 중에서 고를 수 있습니다.' });
      }
      fields.teamInviteLinkCreation = value;
    }
    if ('projectCreation' in (req.body ?? {})) {
      const value = req.body.projectCreation;
      if (!TEAM_CREATION_LEVELS.includes(value)) {
        return res.status(400).json({ error: '프로젝트 생성 권한은 정회원/관리자/서버 운영자 중에서 고를 수 있습니다.' });
      }
      fields.projectCreation = value;
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
    if (fields.teamInviteLinkCreation) {
      detail.push(`팀 초대 링크 생성 권한: ${TEAM_CREATION_LABEL[updated.teamInviteLinkCreation] ?? updated.teamInviteLinkCreation}`);
    }
    if (fields.projectCreation) {
      detail.push(`프로젝트 생성 권한: ${TEAM_CREATION_LABEL[updated.projectCreation] ?? updated.projectCreation}`);
    }
    if (fields.orgScope) {
      detail.push(`팀·직책 관리: ${updated.orgScope === 'account' ? '계정 단위' : '팀 단위'}`);
    }
    recordAudit({ ...actorOf(req), action: AUDIT.serverSettings, detail: detail.join(', ') });
    // 설정 행 전체를 돌려주지 않는다 — FCM 서비스 계정 키(개인키)·DDNS 토큰 같은 비밀값도 같은 행에 있다.
    res.json({
      teamCreation: updated.teamCreation,
      teamInviteLinkCreation: updated.teamInviteLinkCreation,
      orgScope: updated.orgScope,
      projectCreation: updated.projectCreation,
    });
  });

  /** 클라이언트 Firebase 초기화용 4개 값은 그대로 보여준다(비밀값 아님 — Android 클라이언트
   * API 키는 패키지명+SHA-1로 제한된다). 서비스 계정은 private_key를 다시 내려보내지 않고,
   * 설정 여부와 어느 계정인지(client_email)만 알려준다. */
  router.get('/admin/fcm-settings', async (req, res) => {
    const settings = await getServerSettings();
    let serviceAccountEmail = null;
    if (settings.fcmServiceAccountJson) {
      try {
        serviceAccountEmail = JSON.parse(settings.fcmServiceAccountJson).client_email ?? null;
      } catch {
        // 무시 — 아래서 serviceAccountConfigured만 true로 보여준다.
      }
    }
    res.json({
      apiKey: settings.fcmApiKey ?? '',
      appId: settings.fcmAppId ?? '',
      projectId: settings.fcmProjectId ?? '',
      messagingSenderId: settings.fcmMessagingSenderId ?? '',
      serviceAccountConfigured: !!settings.fcmServiceAccountJson,
      serviceAccountEmail,
    });
  });

  /** 넘긴 항목만 바꾼다. serviceAccountJson은 Firebase 콘솔에서 받은 서비스 계정 키 JSON을
   * 그대로 붙여넣은 문자열 — 올바른 서비스 계정 키 형태인지(type/private_key/client_email)
   * 확인하고 저장한다. 저장 후 push.js의 캐시를 지워서 서버 재시작 없이 다음 발송부터 바로
   * 반영되게 한다. */
  router.patch('/admin/fcm-settings', async (req, res) => {
    const body = req.body ?? {};
    const fields = {};
    for (const key of ['apiKey', 'appId', 'projectId', 'messagingSenderId']) {
      if (key in body) {
        if (typeof body[key] !== 'string') {
          return res.status(400).json({ error: `${key}는 문자열이어야 합니다.` });
        }
        fields[`fcm${key[0].toUpperCase()}${key.slice(1)}`] = body[key].trim() || null;
      }
    }
    if ('serviceAccountJson' in body) {
      const raw = body.serviceAccountJson;
      if (typeof raw !== 'string' || !raw.trim()) {
        fields.fcmServiceAccountJson = null; // 빈 문자열 = 설정 해제.
      } else {
        let parsed;
        try {
          parsed = JSON.parse(raw);
        } catch {
          return res.status(400).json({ error: '서비스 계정 JSON 형식이 올바르지 않습니다.' });
        }
        if (parsed.type !== 'service_account' || !parsed.private_key || !parsed.client_email) {
          return res.status(400).json({ error: 'Firebase 서비스 계정 키 JSON이 아닌 것 같습니다.' });
        }
        try {
          // 개인키 형식이 실제로 파싱되는지 여기서 미리 확인한다 — 안 하면 저장은 성공한
          // 것처럼 보이고, 나중에 첫 푸시를 보내려 할 때(push.js)에야 서버 콘솔에만
          // 조용히 에러가 남아 관리자가 원인을 알기 어렵다.
          cert(parsed);
        } catch (e) {
          return res.status(400).json({ error: `서비스 계정 키를 확인할 수 없습니다: ${e.message}` });
        }
        fields.fcmServiceAccountJson = raw.trim();
      }
    }
    if (Object.keys(fields).length === 0) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });

    await updateServerSettings(fields);
    invalidateMessagingCache();
    recordAudit({ ...actorOf(req), action: AUDIT.serverSettings, detail: 'FCM 설정 변경' });
    res.json({ ok: true });
  });

  // ─────────────────────────────── DDNS ───────────────────────────────

  /** 관리자 콘솔 "DDNS" 탭에 보일 내용 — 토큰은 다시 내려보내지 않고 설정 여부만. status는 ddns.js의 갱신기 상태. */
  async function ddnsView() {
    const settings = await getServerSettings();
    return {
      enabled: !!settings.ddnsEnabled,
      domains: parseDuckDnsDomains(settings.ddnsDomains ?? '').names ?? [],
      tokenConfigured: !!settings.ddnsToken,
      status: ddnsUpdater.status(),
    };
  }

  router.get('/admin/ddns', async (req, res) => {
    res.json(await ddnsView());
  });

  /**
   * DDNS 설정 변경 — 넘긴 항목만 바뀐다. domains는 "tangotalk, tangotalk-dev.duckdns.org"처럼(ddns.js
   * parseDuckDnsDomains), token은 DuckDNS 토큰(빈 문자열이면 지운다 — 그러면 꺼진다). 켜려면 도메인과 토큰이 있어야
   * 한다. 저장하면 바로 한 번 갱신해 보고 그 결과까지 돌려준다. 감사 로그에는 토큰을 남기지 않는다.
   */
  router.patch('/admin/ddns', async (req, res) => {
    const body = req.body ?? {};
    const current = await getServerSettings();
    const fields = {};
    if ('domains' in body) {
      const parsed = parseDuckDnsDomains(body.domains);
      if (parsed.error) return res.status(400).json({ error: parsed.error });
      fields.ddnsDomains = parsed.names.length ? parsed.names.join(',') : null;
    }
    if ('token' in body) {
      const token = typeof body.token === 'string' ? body.token.trim() : null;
      if (token === null) return res.status(400).json({ error: '토큰은 글자로 넣어야 합니다.' });
      if (token && !isDuckDnsToken(token)) {
        return res.status(400).json({ error: 'DuckDNS 토큰 모양이 아닙니다 — DuckDNS 첫 화면의 token 값을 그대로 붙여 넣으세요.' });
      }
      fields.ddnsToken = token ? encryptField(token) : null;
    }
    if ('enabled' in body) {
      if (typeof body.enabled !== 'boolean') return res.status(400).json({ error: 'enabled는 참/거짓이어야 합니다.' });
      fields.ddnsEnabled = body.enabled;
    }
    if (Object.keys(fields).length === 0) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });

    const next = { ...current, ...fields };
    // 토큰이나 도메인을 지우면 갱신할 수 없으니 꺼 둔다(켠 채로 두면 매번 실패만 쌓인다).
    if (!next.ddnsToken || !next.ddnsDomains) {
      if (fields.ddnsEnabled === true) {
        return res.status(400).json({ error: '켜려면 도메인과 토큰을 먼저 넣으세요.' });
      }
      fields.ddnsEnabled = false;
    }

    const updated = await updateServerSettings(fields);
    const detail = [`DDNS: ${updated.ddnsEnabled ? '켜짐' : '꺼짐'}`];
    if ('ddnsDomains' in fields) detail.push(`도메인 ${updated.ddnsDomains ?? '없음'}`);
    if ('ddnsToken' in fields) detail.push(fields.ddnsToken ? '토큰 변경' : '토큰 지움');
    recordAudit({ ...actorOf(req), action: AUDIT.serverSettings, detail: detail.join(', ') });

    await ddnsUpdater.runNow();
    res.json(await ddnsView());
  });

  /** "지금 갱신" — 설정은 그대로 두고 바로 한 번 갱신한다(이미 갱신 중이면 그 결과를 기다린다). */
  router.post('/admin/ddns/update', async (req, res) => {
    await ddnsUpdater.runNow();
    res.json(await ddnsView());
  });

  /** 직책 목록 — '부서·직책 관리 범위'가 '계정 단위'일 때, 회원 탭의 직책 수정이 자유 입력
   * 대신 여기서 고르게 한다. */
  router.get('/admin/position-options', async (req, res) => {
    res.json(await listPositionOptions());
  });

  router.post('/admin/position-options', async (req, res) => {
    const label = typeof req.body?.label === 'string' ? req.body.label.trim() : '';
    if (!label) return res.status(400).json({ error: '직책 이름을 입력하세요.' });
    if (label.length > 30) return res.status(400).json({ error: '직책은 30자 이내로 입력하세요.' });
    if (await findPositionOptionByLabel(label)) {
      return res.status(400).json({ error: '이미 있는 직책입니다.' });
    }
    const created = await insertPositionOption(label);
    recordAudit({ ...actorOf(req), action: AUDIT.serverSettings, detail: `직책 목록에 "${label}" 추가` });
    res.status(201).json(created);
  });

  router.delete('/admin/position-options/:id', async (req, res) => {
    const options = await listPositionOptions();
    const target = options.find((o) => o.id === req.params.id);
    if (!target) return res.status(404).json({ error: '직책을 찾을 수 없습니다.' });
    await deletePositionOption(target.id);
    recordAudit({ ...actorOf(req), action: AUDIT.serverSettings, detail: `직책 목록에서 "${target.label}" 삭제` });
    res.json({ ok: true });
  });

  /** 직책 서열 변경 — `ids`에 전체 직책 id를 원하는 순서대로 보낸다(끌어다 놓기). */
  router.post('/admin/position-options/order', async (req, res) => {
    const ids = Array.isArray(req.body?.ids) ? req.body.ids : [];
    const current = (await listPositionOptions()).map((o) => o.id);
    if (ids.length !== current.length || !current.every((id) => ids.includes(id))) {
      return res.status(400).json({ error: '직책 목록이 올바르지 않습니다.' });
    }
    res.json(await reorderPositionOptions(ids));
  });

  /** 직책 "기본값" 지정/해제 — 회원가입 시 이 직책이 자동으로 부여된다(auth.js). */
  router.post('/admin/position-options/:id/default', async (req, res) => {
    const updated = await toggleDefaultPositionOption(req.params.id);
    const target = updated.find((o) => o.id === req.params.id);
    recordAudit({
      ...actorOf(req),
      action: AUDIT.serverSettings,
      detail: target?.isDefault
        ? `직책 목록의 기본값을 "${target.label}"(으)로 지정`
        : '직책 목록의 기본값 해제',
    });
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
   * 준회원 → 정회원 이상으로 올리면, 그동안 빠져 있던 그 사람 소속 팀들의 '정회원 자동 초대'
   * 토픽에 자동으로 넣어준다(준회원은 자동 참여 대상이 아니었으므로 따라잡아 주는 것 — 팀에
   * 새로 들어올 때와 같은 기준, teams.js).
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

    // 로그아웃 없이 바로 반영되도록, 지금 접속 중인 그 사람의 소켓에 알려서 클라이언트가
    // 자기 프로필(/users/me)을 다시 받아오게 한다 — token_version은 안 올린다(강제 로그아웃
    // 사유가 아니라서, 정지/전체 로그아웃과 달리 이 경우는 접속을 끊을 이유가 없다).
    io.to(`user:${target.id}`).emit('user:role-updated', { role: newRole });

    // 준회원은 토픽 관리자가 될 수 없다 — 내려가면 맡던 토픽 관리자 역할을 거두고, 그 토픽 멤버들의
    // 관리자 표시·관리 메뉴가 바로 바뀌도록 방 정보를 다시 보낸다.
    if (newRole === 'guest') {
      for (const roomId of await clearTopicAdminRoles(target.id)) {
        const room = await findRoomById(roomId);
        if (room) io.to(room.id).emit('room:created', await toRoomDto(room));
      }
    }

    if (before === 'guest' && newRole !== 'guest') {
      for (const teamId of await listTeamIdsForUser(target.id)) {
        for (const room of await listAutoInviteTopics(teamId)) {
          const memberIds = await listRoomMemberIds(room.id);
          if (memberIds.includes(target.id)) continue;
          const changedTodos = await addRoomMembers(room.id, [target.id]);
          await notifyMembership(io, room);
          await notifyTodosResynced(io, room, changedTodos, req.user.sub); // 예전 담당 행이 남아 있던 사람이 다시 들어옴.
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

    // 부서·직책 관리 범위가 '계정 단위'일 때는 직책을 자유 입력 대신 '직책 목록'(관리자 콘솔
    // 운영 현황에서 서버 운영자가 관리)에서 고르게 한다 — 자유 입력은 팀 단위(team_members)
    // 쪽 org_edit_dialog에서만 계속 쓴다. 목록에 없는 값이 새로 저장되지 않도록 여기서도 한 번
    // 더 막는다(라디오 버튼 UI는 사용자 실수만 막을 뿐, 실제 강제는 서버가 한다). 값이 그대로면
    // (건드리지 않고 저장) 막지 않는다 — 이 기능이 생기기 전부터 있던 값이 목록에 없다는
    // 이유만으로 저장 자체가 막히면 안 되므로("바꾸려는" 값만 검증한다).
    if ('position' in fields && fields.position !== null && fields.position !== target.position) {
      const settings = await getServerSettings();
      if (settings.orgScope === 'account') {
        const match = await findPositionOptionByLabel(fields.position);
        if (!match) return res.status(400).json({ error: '직책 목록에 없는 값입니다.' });
      }
    }

    const updated = await updateUser(target.id, fields);
    recordAudit({
      ...actorOf(req),
      action: AUDIT.userOrg,
      targetType: 'user',
      targetId: target.id,
      targetLabel: target.name ?? target.username,
      detail: `부서·직책: ${[fields.department, fields.position].filter(Boolean).join(' / ') || '지움'}`,
    });
    // 로그아웃 없이 바로 반영되도록, 이 사람과 같은 팀에 있는 사람들 전원(본인 포함)에게
    // 알려서 room.members에 캐싱된 부서/직책을 즉시 갱신한다 — 계정 단위로 관리할 때만
    // 쓰는 라우트라(위 주석 참고) 팀 값이 아니라 방금 저장한 계정 값을 그대로 돌려준다.
    const orgPayload = {
      userId: target.id,
      department: updated.department ?? null,
      position: updated.position ?? null,
    };
    const notifyIds = new Set();
    for (const teamId of await listTeamIdsForUser(target.id)) {
      for (const id of await listTeamMemberIds(teamId)) notifyIds.add(id);
    }
    for (const id of notifyIds) {
      io.to(`user:${id}`).emit('org:updated', orgPayload);
    }
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

    // 정지하면서 tokenVersion을 올려야 이미 로그인해 있는 기기도 즉시 끊긴다. 정지된 운영자는 콘솔에
    // 못 들어오므로, 정지는 활성 서버 운영자가 한 명은 남을 때만 한다(운영자 해제와 같은 규칙).
    const updated = suspend
      ? await updateUserUnlessLastServerAdmin(target.id, {
          suspendedAt: new Date(),
          tokenVersion: (target.tokenVersion ?? 0) + 1,
        })
      : await updateUser(target.id, { suspendedAt: null });
    if (!updated) {
      return res.status(400).json({ error: '마지막 서버 운영자는 정지할 수 없습니다. 다른 회원을 서버 운영자로 먼저 지정하세요.' });
    }
    // 정지된 계정에는 알림도 가지 않는다 — 보내는 쪽이 정지·탈퇴 계정을 거르고(db/queries/devices.js), 아래 cutOffUser가
    // 기기들의 푸시 토큰·구독도 지운다(정지를 풀어도 다시 로그인하기 전까지는 그 기기들로 알림이 가지 않게).
    if (suspend) await cutOffUser(io, target.id);

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
    await cutOffUser(io, target.id);

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

  // 비밀번호 초기화 대행 기능은 없다 — 운영자가 남의 비밀번호(평문)를 직접 정해서 넣는 것은
  // 그 계정을 완전히 탈취할 수 있는 힘이라 의도적으로 제외했다. 계정에 문제가 있으면 강제
  // 로그아웃(/admin/users/:id/logout-all)이나 정지로 대응하고, 비밀번호 자체는 본인만
  // 보안 질문(/auth/reset-password)으로 재설정할 수 있다.

  /**
   * 서버 운영자 지정/해제. 마지막 운영자는 내려올 수 없다(아무도 못 들어가게 되므로) — 정지된 운영자는 콘솔에
   * 못 들어오니 남은 사람으로 치지 않는다(updateUserUnlessLastServerAdmin).
   */
  router.post('/admin/users/:id/server-admin', async (req, res) => {
    const target = await requireTarget(req, res);
    if (!target) return;
    const grant = req.body?.isServerAdmin !== false;

    const updated = grant
      ? await updateUser(target.id, { isServerAdmin: true })
      : await updateUserUnlessLastServerAdmin(target.id, { isServerAdmin: false });
    if (!updated) {
      return res.status(400).json({ error: '마지막 서버 운영자는 해제할 수 없습니다. 다른 회원을 서버 운영자로 먼저 지정하세요.' });
    }
    // 등급 변경과 같은 이유로, 로그아웃 없이 바로 반영되도록 알린다.
    io.to(`user:${target.id}`).emit('user:role-updated', { isServerAdmin: grant });
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
        iconUrl: signFileUrl(team.iconUrl) ?? null,
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
    // 회원 목록은 종류와 상관없이 이 색으로 원을 칠한다 — 앱이 못 읽는 모양이면 목록 전체가 안 그려지므로 거른다(avatarRules.js).
    avatarColor: safeAvatarColor(u.avatarColor),
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

/**
 * 정지/강제 로그아웃 직후 — 그 계정의 모든 기기가 로그아웃되는 때다(tokenVersion이 올라갔다).
 *  - 이미 붙어있는 소켓을 즉시 끊는다(다음 재연결부터는 토큰이 막힌다).
 *  - 기기들의 푸시 토큰·웹 푸시 구독을 지운다. 앱은 로그아웃할 때 자기 토큰을 서버에서 지우지만 그건 인증이 아직 살아
 *    있을 때만 되는데, 이렇게 쫓겨난 기기는 이미 인증이 막혀 못 지운다 — 그대로 두면 로그아웃된(잃어버렸을 수도 있는)
 *    폰·브라우저에 메시지 미리보기 알림이 계속 간다. 다시 로그인하면 앱이 새로 등록한다(client session.dart). 뒷정리라서
 *    실패해도(드문 DB 오류) 기록만 남기고 정지·로그아웃 처리와 감사 기록은 그대로 이어 간다.
 *  - 진행 중인 화상회의에서도 내보낸다. 통화 참가 자격은 LiveKit 토큰을 줄 때만 확인해서, 소켓을 끊어도 이미 연결된 통화
 *    미디어(남의 음성·화면 공유)는 그 사람이 스스로 나갈 때까지 계속 오가기 때문이다(callAccess.js — 실패해도 던지지 않는다).
 */
async function cutOffUser(io, userId) {
  io.to(`user:${userId}`).disconnectSockets(true);
  await clearPushTargetsForUser(userId).catch((err) =>
    console.error('[admin] 푸시 토큰·구독 지우기 실패:', userId, err?.message ?? err),
  );
  await endUserCallAccess(io, userId);
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
