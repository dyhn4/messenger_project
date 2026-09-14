import { Router } from 'express';
import {
  addTeamMembers,
  deleteTeam,
  findTeamById,
  findTeamMember,
  getTeamRole,
  insertTeam,
  isTeamMember,
  listTeamMemberIds,
  listTeamMemberIdsByRole,
  listTeamMemberUsers,
  listTeamsForUser,
  listTopicCreatorIds,
  removeTeamMember,
  setTeamRole,
  setTopicCreators,
  updateTeam,
  updateTeamMember,
} from './db/queries/teams.js';
import { addRoomMembers, listPublicTopics, listRoomMemberIds } from './db/queries/rooms.js';
import { getServerSettings } from './db/queries/serverSettings.js';
import { findPositionOptionByLabel } from './db/queries/positionOptions.js';
import { findUserById, updateUser } from './db/queries/users.js';
import { db } from './db/client.js';
import { teams as teamsTable } from './db/schema.js';
import { AUDIT, recordAudit } from './audit.js';
import {
  accountRole,
  canCreateTeam,
  canManageTeam,
  EDIT_DELETE_WINDOW_OPTIONS,
  editDeleteWindowSeconds,
  roleLabel,
  TOPIC_CREATION_LEVELS,
} from './permissions.js';
import { teamAccess, userAccess } from './access.js';
import { nameOf, notifyMembership, postSystemMessage } from './rooms.js';
import { publicUser } from './users.js';

export function toTeamDto(team, { isOwner = false, memberCount = null, topicCreatorIds = [] } = {}) {
  return {
    id: team.id,
    name: team.name,
    iconEmoji: team.iconEmoji ?? null,
    iconColor: team.iconColor ?? null,
    topicCreationPolicy: team.topicCreationPolicy ?? 'member',
    // topicCreationPolicy가 'designated'일 때만 의미가 있다 — 팀 설정 화면이 이 id 목록과
    // 자기가 이미 갖고 있는 팀원 목록을 대조해서 이름을 보여준다(서버가 이름까지 싣지 않는다).
    topicCreatorIds,
    messageEditDeleteEnabled: team.messageEditDeleteEnabled !== false,
    messageEditDeleteWindowSeconds: editDeleteWindowSeconds(team),
    createdBy: team.createdBy ?? null,
    createdAt: new Date(team.createdAt).getTime(),
    // 이 응답을 받는 사람 기준 값 — 이 사람이 그 팀의 소유자인지. 등급은 계정 단위라
    // 팀마다 다르지 않으므로 여기 싣지 않는다(클라이언트는 session의 계정 등급을 본다).
    isOwner,
    memberCount,
  };
}

/** topicCreationPolicy가 'designated'일 때만 지정자 목록을 조회한다(그 외 정책이면 DB를
 * 두드릴 필요가 없다). toTeamDto에 넘길 topicCreatorIds를 만들 때 여기저기서 반복해서 쓴다. */
function topicCreatorIdsFor(team) {
  return team.topicCreationPolicy === 'designated' ? listTopicCreatorIds(team.id) : Promise.resolve([]);
}

/**
 * 팀 멤버 목록 응답 — 계정 등급(role), 소유자 여부(isOwner), 부서/직책을 함께 준다.
 * 부서/직책은 서버 설정(orgScope)에 따라 팀 값(team_members) 또는 계정 값(users)을 쓴다.
 */
async function memberListResponse(teamId) {
  const [members, settings] = await Promise.all([listTeamMemberUsers(teamId), getServerSettings()]);
  const byTeam = settings.orgScope !== 'account';
  return members.map((m) => ({
    ...publicUser(m),
    role: accountRole(m),
    isOwner: !!m.isOwner,
    department: (byTeam ? m.teamDepartment : m.department) ?? null,
    position: (byTeam ? m.teamPosition : m.position) ?? null,
  }));
}

export function createTeamsRouter(io) {
  const router = Router();

  /**
   * 팀 정보가 바뀌면 그 팀 사람 모두에게 알린다. isOwner는 받는 사람마다 다르므로 사람별로
   * 따로 emit한다 — 클라이언트는 이 값과 자기 계정 등급을 합쳐 화면의 권한 UI를 다시 그린다.
   */
  async function broadcastTeamUpdated(team) {
    const [memberIds, topicCreatorIds] = await Promise.all([listTeamMemberIds(team.id), topicCreatorIdsFor(team)]);
    const dto = toTeamDto(team, { memberCount: memberIds.length, topicCreatorIds });
    for (const userId of memberIds) {
      const isOwner = (await getTeamRole(team.id, userId)) === 'owner';
      io.to(`user:${userId}`).emit('team:updated', { ...dto, isOwner });
    }
  }

  /** 내가 속한 팀 목록 — 로그인/앱 시작 직후 팀 선택 화면이 이걸 그린다. */
  router.get('/teams', async (req, res) => {
    const rows = await listTeamsForUser(req.user.sub);
    const dtos = [];
    for (const { team, role } of rows) {
      const [memberIds, topicCreatorIds] = await Promise.all([listTeamMemberIds(team.id), topicCreatorIdsFor(team)]);
      dtos.push(toTeamDto(team, { isOwner: role === 'owner', memberCount: memberIds.length, topicCreatorIds }));
    }
    res.json(dtos);
  });

  /**
   * 조직도 — 서버 전체 팀과 각 팀의 멤버 id 목록. GET /teams와 달리 내가 속하지 않은 팀도
   * 포함한다("관리자 이상"이 회사 전체 구조를 보는 용도라서). 계정 등급이 관리자이거나
   * 서버 운영자만 볼 수 있다 — 소유자라는 이유만으로는 안 된다(그 팀 하나만 관리할 뿐, 다른
   * 팀 멤버 구성까지 볼 권한은 아니므로).
   *
   * 멤버 이름/아바타 등 상세 정보는 이미 등급과 무관하게 공개인 GET /users로 따로 받게 하고,
   * 여기서는 "어느 팀에 누가 속해 있는지"라는 조직도 고유의 정보만 준다. ownerId는 조직도
   * "멤버" 탭이 등급 배지 옆에 "소유자" 표시를 붙일지 판단하는 데 쓴다.
   */
  router.get('/org-chart/teams', async (req, res) => {
    const me = await findUserById(req.user.sub);
    if (!me || me.deletedAt) return res.status(404).json({ error: '사용자를 찾을 수 없습니다.' });
    if (!me.isServerAdmin && accountRole(me) !== 'admin') {
      return res.status(403).json({ error: '조직도는 관리자 이상만 볼 수 있습니다.' });
    }
    const rows = await db.select().from(teamsTable).orderBy(teamsTable.createdAt);
    const dtos = [];
    for (const team of rows) {
      const [memberIds, ownerIds] = await Promise.all([
        listTeamMemberIds(team.id),
        listTeamMemberIdsByRole(team.id, 'owner'),
      ]);
      dtos.push({
        id: team.id,
        name: team.name,
        iconEmoji: team.iconEmoji ?? null,
        iconColor: team.iconColor ?? null,
        memberIds,
        ownerId: ownerIds[0] ?? null,
      });
    }
    res.json(dtos);
  });

  /** 팀 생성 — 만든 사람이 그 팀의 소유자가 된다(잔디와 동일, 별도 소유자 비밀번호 없음). */
  router.post('/teams', async (req, res) => {
    // 팀을 만들 수 있는 최소 계정 등급은 서버 설정에서 정한다(관리자 콘솔 → 팀 생성 권한).
    const settings = await getServerSettings();
    const me = await userAccess(req.user.sub);
    if (!canCreateTeam({ role: me.role, isServerAdmin: me.isServerAdmin, teamCreation: settings.teamCreation })) {
      const need = { serverAdmin: '서버 운영자', admin: '관리자 이상', member: '정회원 이상' }[settings.teamCreation] ?? '정회원 이상';
      return res.status(403).json({ error: `이 서버는 ${need}만 팀을 만들 수 있도록 설정되어 있습니다.` });
    }

    const name = typeof req.body?.name === 'string' ? req.body.name.trim() : '';
    if (!name) return res.status(400).json({ error: '팀 이름을 입력하세요.' });
    if (name.length > 30) return res.status(400).json({ error: '팀 이름은 30자 이내로 입력하세요.' });

    const team = await insertTeam({
      name,
      iconEmoji: typeof req.body?.iconEmoji === 'string' ? req.body.iconEmoji : null,
      iconColor: typeof req.body?.iconColor === 'string' ? req.body.iconColor : null,
      createdBy: req.user.sub,
    });
    await addTeamMembers(team.id, [req.user.sub], 'owner');
    recordAudit({
      actorId: req.user.sub,
      actorName: await nameOf(req.user.sub),
      action: AUDIT.teamCreate,
      teamId: team.id,
      teamName: team.name,
      targetType: 'team',
      targetId: team.id,
      targetLabel: team.name,
      detail: '팀 생성(만든 사람이 소유자)',
    });
    res.status(201).json(toTeamDto(team, { isOwner: true, memberCount: 1 }));
  });

  /** 팀 이름/아이콘/토픽 생성 권한 변경 — 소유자·관리자만. */
  router.patch('/teams/:id', async (req, res) => {
    const team = await findTeamById(req.params.id);
    if (!team) return res.status(404).json({ error: '팀을 찾을 수 없습니다.' });
    const me = await teamAccess(team.id, req.user.sub);
    if (!canManageTeam(me)) return res.status(403).json({ error: '팀 설정을 바꿀 권한이 없습니다.' });

    const fields = {};
    if (typeof req.body?.name === 'string') {
      const name = req.body.name.trim();
      if (!name) return res.status(400).json({ error: '팀 이름을 입력하세요.' });
      if (name.length > 30) return res.status(400).json({ error: '팀 이름은 30자 이내로 입력하세요.' });
      fields.name = name;
    }
    if ('iconEmoji' in (req.body ?? {})) fields.iconEmoji = req.body.iconEmoji || null;
    if ('iconColor' in (req.body ?? {})) fields.iconColor = req.body.iconColor || null;
    // 'designated'로 정할 때만 topicCreatorIds가 함께 온다 — 다른 값으로 바꿀 때는 안 보내도
    // 되고, 기존 지정 목록은 그대로 남는다(스키마의 topicCreators 주석 참고).
    let topicCreatorIdsToSet = null;
    if ('topicCreationPolicy' in (req.body ?? {})) {
      const policy = req.body.topicCreationPolicy;
      if (!TOPIC_CREATION_LEVELS.includes(policy)) {
        return res.status(400).json({ error: `topicCreationPolicy는 ${TOPIC_CREATION_LEVELS.join('/')} 중 하나여야 합니다.` });
      }
      fields.topicCreationPolicy = policy;

      if (policy === 'designated') {
        const ids = Array.isArray(req.body.topicCreatorIds)
          ? [...new Set(req.body.topicCreatorIds.filter((id) => typeof id === 'string'))]
          : [];
        if (ids.length === 0) {
          return res.status(400).json({ error: '토픽을 만들 수 있는 사람을 한 명 이상 지정하세요.' });
        }
        for (const id of ids) {
          if (!(await findTeamMember(team.id, id))) {
            return res.status(400).json({ error: '이 팀의 멤버만 지정할 수 있습니다.' });
          }
          const target = await findUserById(id);
          if (accountRole(target) === 'guest') {
            return res.status(400).json({ error: '정회원 이상만 지정할 수 있습니다.' });
          }
        }
        topicCreatorIdsToSet = ids;
      }
    }
    // [메시지 설정] 수정/삭제 허용 여부 + 수정/삭제 가능 시간.
    if ('messageEditDeleteEnabled' in (req.body ?? {})) {
      if (typeof req.body.messageEditDeleteEnabled !== 'boolean') {
        return res.status(400).json({ error: 'messageEditDeleteEnabled는 true/false여야 합니다.' });
      }
      fields.messageEditDeleteEnabled = req.body.messageEditDeleteEnabled;
    }
    if ('messageEditDeleteWindowSeconds' in (req.body ?? {})) {
      const seconds = req.body.messageEditDeleteWindowSeconds;
      if (!EDIT_DELETE_WINDOW_OPTIONS.includes(seconds)) {
        return res.status(400).json({ error: '수정/삭제 가능 시간은 5분/30분/1시간/24시간/7일 중에서 고를 수 있습니다.' });
      }
      fields.messageEditDeleteWindowSeconds = seconds;
    }
    if (Object.keys(fields).length === 0) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });

    const updated = await updateTeam(team.id, fields);
    if (topicCreatorIdsToSet) await setTopicCreators(team.id, topicCreatorIdsToSet);
    await broadcastTeamUpdated(updated);
    const [memberIds, topicCreatorIds] = await Promise.all([
      listTeamMemberIds(team.id),
      topicCreatorIdsFor(updated),
    ]);
    res.json(toTeamDto(updated, { isOwner: me.isOwner, memberCount: memberIds.length, topicCreatorIds }));
  });

  /**
   * 소유권 이양 — 소유자만. 넘겨받는 사람이 소유자가 되고, 넘긴 사람은 관리자로 내려온다
   * (팀에 소유자가 없어지는 상태를 만들지 않기 위해 두 변경을 항상 함께 한다).
   */
  router.post('/teams/:id/transfer-owner', async (req, res) => {
    const team = await findTeamById(req.params.id);
    if (!team) return res.status(404).json({ error: '팀을 찾을 수 없습니다.' });
    if ((await getTeamRole(team.id, req.user.sub)) !== 'owner') {
      return res.status(403).json({ error: '소유자만 소유권을 넘길 수 있습니다.' });
    }

    const targetId = typeof req.body?.userId === 'string' ? req.body.userId : null;
    if (!targetId) return res.status(400).json({ error: '넘겨받을 사람을 선택하세요.' });
    if (targetId === req.user.sub) return res.status(400).json({ error: '이미 소유자입니다.' });
    if (!(await isTeamMember(team.id, targetId))) return res.status(404).json({ error: '이 팀의 멤버가 아닙니다.' });

    await setTeamRole(team.id, targetId, 'owner');
    await setTeamRole(team.id, req.user.sub, 'member'); // 넘긴 사람은 일반 멤버로(계정 등급은 그대로)
    await broadcastTeamUpdated(team);
    recordAudit({
      actorId: req.user.sub,
      actorName: await nameOf(req.user.sub),
      action: AUDIT.teamTransferOwner,
      teamId: team.id,
      teamName: team.name,
      targetType: 'user',
      targetId,
      targetLabel: await nameOf(targetId),
      detail: '소유권 이양',
    });
    res.json(await memberListResponse(team.id));
  });

  /**
   * 팀 삭제 — 소유자만. 그 팀의 방/메시지/댓글/멤버십이 전부 함께 사라진다(FK onDelete
   * cascade). 실수를 막기 위해 팀 이름을 그대로 다시 보내야만 진행한다.
   * (업로드된 첨부 파일 자체는 디스크에 남는다 — README "팀 삭제" 주의사항 참고.)
   */
  router.delete('/teams/:id', async (req, res) => {
    const team = await findTeamById(req.params.id);
    if (!team) return res.status(404).json({ error: '팀을 찾을 수 없습니다.' });
    if ((await getTeamRole(team.id, req.user.sub)) !== 'owner') {
      return res.status(403).json({ error: '소유자만 팀을 삭제할 수 있습니다.' });
    }

    const confirm = typeof req.body?.name === 'string' ? req.body.name.trim() : '';
    if (confirm !== team.name) {
      return res.status(400).json({ error: '확인을 위해 팀 이름을 정확히 입력하세요.' });
    }

    // 지우기 전에 멤버를 확보해야 한다 — 지운 뒤에는 누구에게 알려야 할지 알 수 없다.
    const memberIds = await listTeamMemberIds(team.id);
    const actorName = await nameOf(req.user.sub);
    await deleteTeam(team.id);
    for (const userId of memberIds) {
      io.to(`user:${userId}`).emit('team:left', { teamId: team.id, teamName: team.name, deleted: true });
    }
    // 팀이 사라졌으므로 teamId는 null이 된다(FK set null) — 이름 스냅샷만 남는다.
    recordAudit({
      actorId: req.user.sub,
      actorName,
      action: AUDIT.teamDelete,
      teamName: team.name,
      targetType: 'team',
      targetId: team.id,
      targetLabel: team.name,
      detail: `팀 삭제(멤버 ${memberIds.length}명)`,
    });
    res.json({ ok: true });
  });

  /** 팀 멤버 목록 — 조직도(멤버 패널)와 "새 대화" 상대 선택이 이걸 쓴다. */
  router.get('/teams/:id/members', async (req, res) => {
    const team = await findTeamById(req.params.id);
    if (!team) return res.status(404).json({ error: '팀을 찾을 수 없습니다.' });
    if (!(await isTeamMember(team.id, req.user.sub))) {
      return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    }
    res.json(await memberListResponse(team.id));
  });

  /**
   * 팀에 멤버 추가 — 그 팀의 소유자 또는 계정 등급이 관리자인 사람만.
   * **등급은 여기서 정하지 않는다** — 계정 등급은 서버 운영자가 관리자 콘솔에서만 바꾼다.
   * 각자가 이미 가진 계정 등급 그대로 팀에 들어온다.
   */
  router.post('/teams/:id/members', async (req, res) => {
    const team = await findTeamById(req.params.id);
    if (!team) return res.status(404).json({ error: '팀을 찾을 수 없습니다.' });
    const me = await teamAccess(team.id, req.user.sub);
    if (!canManageTeam(me)) return res.status(403).json({ error: '멤버를 추가할 권한이 없습니다.' });

    const userIds = Array.isArray(req.body?.userIds) ? req.body.userIds.filter((id) => typeof id === 'string') : [];
    if (userIds.length === 0) return res.status(400).json({ error: '추가할 멤버를 선택하세요.' });

    await addTeamMembers(team.id, userIds, 'member');

    // 팀에 들어오면 그 팀의 공개 토픽에 자동으로 참여시킨다. 준회원은 제외 —
    // 초대받은 방에만 들어간다(계정 등급 기준이라 사람마다 따로 판단한다).
    const autoJoinIds = [];
    for (const id of userIds) {
      const u = await findUserById(id);
      if (accountRole(u) !== 'guest') autoJoinIds.push(id);
    }
    if (autoJoinIds.length > 0) {
      for (const room of await listPublicTopics(team.id)) {
        const before = await listRoomMemberIds(room.id);
        const missing = autoJoinIds.filter((id) => !before.includes(id));
        if (missing.length === 0) continue;
        await addRoomMembers(room.id, missing);
        await notifyMembership(io, room);
        const names = await Promise.all(missing.map(nameOf));
        await postSystemMessage(io, room, `${names.join(', ')} 님이 참여했습니다.`);
      }
    }

    const [memberIds, topicCreatorIds] = await Promise.all([listTeamMemberIds(team.id), topicCreatorIdsFor(team)]);
    // 새로 들어온 사람의 다른 기기까지 팀 목록을 갱신시킨다(팀 선택 화면에 바로 뜨도록).
    for (const userId of userIds) {
      io.to(`user:${userId}`).emit(
        'team:joined',
        toTeamDto(team, { isOwner: false, memberCount: memberIds.length, topicCreatorIds }),
      );
    }
    const addedNames = await Promise.all(userIds.map(nameOf));
    recordAudit({
      actorId: req.user.sub,
      actorName: await nameOf(req.user.sub),
      action: AUDIT.teamMemberAdd,
      teamId: team.id,
      teamName: team.name,
      targetType: 'user',
      targetId: userIds.length === 1 ? userIds[0] : null,
      targetLabel: addedNames.join(', '),
      detail: '팀에 추가',
    });
    res.json(await memberListResponse(team.id));
  });

  /**
   * 팀원의 부서/직책 변경 — 그 팀의 소유자 또는 계정 등급이 관리자인 사람만.
   * **등급은 여기서 바꿀 수 없다** — 계정 등급은 서버 운영자가 관리자 콘솔에서만 정한다.
   * 부서/직책을 계정 단위로 쓰도록 설정한 서버(orgScope='account')에서도 팀 설정에서 바꾸면
   * 계정 값이 바뀌도록, 설정에 따라 저장 위치를 나눈다. 직책을 실제로 바꿀 때는(그대로
   * 저장하는 기존 값은 통과) 직책 목록(position_options)에 있는 값이어야 하고, 요청자
   * 자신의 직책보다 서열이 높으면 안 된다(team_settings_dialog.dart의 "직책 수정" 참고).
   */
  router.patch('/teams/:id/members/:userId', async (req, res) => {
    const team = await findTeamById(req.params.id);
    if (!team) return res.status(404).json({ error: '팀을 찾을 수 없습니다.' });
    const me = await teamAccess(team.id, req.user.sub);
    if (!canManageTeam(me)) return res.status(403).json({ error: '팀원 정보를 바꿀 권한이 없습니다.' });

    const targetId = req.params.userId;
    const target = await findTeamMember(team.id, targetId);
    if (!target) return res.status(404).json({ error: '이 팀의 멤버가 아닙니다.' });
    if ('role' in (req.body ?? {})) {
      return res.status(400).json({ error: '등급은 서버 운영자만 관리자 콘솔에서 바꿀 수 있습니다.' });
    }

    const fields = {};
    if ('department' in (req.body ?? {})) {
      const v = typeof req.body.department === 'string' ? req.body.department.trim() : '';
      if (v.length > 30) return res.status(400).json({ error: '부서는 30자 이내로 입력하세요.' });
      fields.department = v || null;
    }
    if ('position' in (req.body ?? {})) {
      const v = typeof req.body.position === 'string' ? req.body.position.trim() : '';
      if (v.length > 30) return res.status(400).json({ error: '직책은 30자 이내로 입력하세요.' });
      fields.position = v || null;
    }
    if (Object.keys(fields).length === 0) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });

    const settings = await getServerSettings();
    // 저장 위치와 같은 규칙으로 "지금 값"을 고른다(계정 단위/팀 단위) — 그대로 다시 저장하는
    // 건(자유 입력이던 시절의 기존 값 포함) 막지 않고, "바뀌는" 값만 검사한다(팀 초대 링크·
    // 관리자 콘솔 직책 수정과 같은 정책). 새 값은 직책 목록에 있어야 하고, 내(요청자) 직책보다
    // 서열이 높으면 안 된다 — sortOrder는 **작을수록 서열이 낮다**(기본 목록이 사원(0)→
    // 대표(7) 순인 것과 같은 방향)이므로 "더 높음"은 sortOrder가 더 큰 쪽이다. 클라이언트는
    // 이미 이렇게 골라서 보내지만, 여기서 한 번 더 막는다.
    if ('position' in fields && fields.position !== null) {
      const currentPosition =
        settings.orgScope === 'account' ? ((await findUserById(targetId))?.position ?? null) : (target.position ?? null);
      if (fields.position !== currentPosition) {
        const match = await findPositionOptionByLabel(fields.position);
        if (!match) return res.status(400).json({ error: '직책 목록에 없는 값입니다.' });
        const myPosition = me.user?.position ? await findPositionOptionByLabel(me.user.position) : null;
        if (!myPosition || match.sortOrder > myPosition.sortOrder) {
          return res.status(403).json({ error: '자신의 직책보다 높은 직책은 부여할 수 없습니다.' });
        }
      }
    }

    if (settings.orgScope === 'account') {
      await updateUser(targetId, fields); // 계정 하나로 관리하는 서버
    } else {
      await updateTeamMember(team.id, targetId, fields); // 팀마다 다르게(기본)
    }

    recordAudit({
      actorId: req.user.sub,
      actorName: await nameOf(req.user.sub),
      action: AUDIT.teamMemberRole,
      teamId: team.id,
      teamName: team.name,
      targetType: 'user',
      targetId,
      targetLabel: await nameOf(targetId),
      detail: `부서·직책 변경(${[fields.department, fields.position].filter(Boolean).join(' / ') || '지움'})`,
    });
    res.json(await memberListResponse(team.id));
  });

  /** 팀에서 멤버 빼기 — 그 팀의 소유자 또는 계정 등급이 관리자인 사람만. 소유자는 뺄 수 없다. */
  router.delete('/teams/:id/members/:userId', async (req, res) => {
    const team = await findTeamById(req.params.id);
    if (!team) return res.status(404).json({ error: '팀을 찾을 수 없습니다.' });
    const me = await teamAccess(team.id, req.user.sub);
    if (!canManageTeam(me)) return res.status(403).json({ error: '멤버를 뺄 권한이 없습니다.' });

    const targetRole = await getTeamRole(team.id, req.params.userId);
    if (targetRole === null) return res.status(404).json({ error: '이 팀의 멤버가 아닙니다.' });
    if (targetRole === 'owner') return res.status(400).json({ error: '소유자는 팀에서 뺄 수 없습니다.' });
    // 관리자(계정 등급)는 소유자만 뺄 수 있다 — 관리자끼리 서로 빼는 상황을 막는다.
    const target = await findUserById(req.params.userId);
    if (accountRole(target) === 'admin' && !me.isOwner) {
      return res.status(403).json({ error: '관리자는 그 팀의 소유자만 뺄 수 있습니다.' });
    }

    await removeTeamMember(team.id, req.params.userId);
    io.to(`user:${req.params.userId}`).emit('team:left', { teamId: team.id, teamName: team.name });
    recordAudit({
      actorId: req.user.sub,
      actorName: await nameOf(req.user.sub),
      action: AUDIT.teamMemberRemove,
      teamId: team.id,
      teamName: team.name,
      targetType: 'user',
      targetId: req.params.userId,
      targetLabel: await nameOf(req.params.userId),
      detail: `팀에서 제외(${roleLabel(accountRole(target))})`,
    });
    res.json(await memberListResponse(team.id));
  });

  return router;
}
