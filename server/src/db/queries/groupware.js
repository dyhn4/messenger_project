import { and, asc, desc, eq, gte, inArray, isNull, lt, lte, or, sql } from 'drizzle-orm';
import { db } from '../client.js';
import {
  approvalCc,
  approvalCounters,
  approvalDelegations,
  approvalDocuments,
  approvalLines,
  approvalNotifications,
  approvalSteps,
  approvalTemplates,
  attendanceRecords,
  attendanceReminders,
  groupwareOptions,
  leavePromotions,
  workSchedules,
  leaveAdjustments,
  teamMembers,
  teams,
  users,
  workWages,
} from '../schema.js';

// ── 결재 문서 ───────────────────────────────────────────────────────────

/**
 * 문서·결재선·참조자를 한 번에 넣는다. 첫 단계(합의면 여럿)가 바로 차례(pending)다. [approvers]는 `[{ id, name, role?, stage? }]`
 * (단계가 없으면 순서대로 한 사람씩). [numberOf](year, seq)를 주면 같은 트랜잭션에서 범위·해마다 번호를 하나 올려 문서 번호를 매긴다.
 * 넣은 문서 행.
 */
export async function insertApprovalDocument({ doc, approvers, ccIds, numberOf = null, year = new Date().getFullYear() }) {
  return db.transaction(async (tx) => {
    let docNumber = null;
    if (numberOf) {
      const [counter] = await tx
        .insert(approvalCounters)
        .values({ scopeKey: doc.scopeKey, year, lastSeq: 1 })
        .onConflictDoUpdate({
          target: [approvalCounters.scopeKey, approvalCounters.year],
          set: { lastSeq: sql`${approvalCounters.lastSeq} + 1` },
        })
        .returning();
      docNumber = numberOf(year, counter.lastSeq);
    }
    const [row] = await tx
      .insert(approvalDocuments)
      .values({ ...doc, docNumber, status: 'pending', currentStep: 0 })
      .returning();
    const stageOf = (a, i) => a.stage ?? i;
    const firstStage = Math.min(...approvers.map(stageOf));
    await tx.insert(approvalSteps).values(
      approvers.map((a, i) => ({
        documentId: row.id,
        stepOrder: i,
        approverId: a.id,
        approverName: a.name,
        stage: stageOf(a, i),
        role: a.role ?? 'approve',
        status: stageOf(a, i) === firstStage ? 'pending' : 'waiting',
      })),
    );
    if (ccIds.length > 0) await tx.insert(approvalCc).values(ccIds.map((userId) => ({ documentId: row.id, userId })));
    return row;
  });
}

/** 문서 하나와 그 결재선(순서대로)·참조자 id. 없으면 null. */
export async function findApprovalDocument(id) {
  const [doc] = await db.select().from(approvalDocuments).where(eq(approvalDocuments.id, id));
  if (!doc) return null;
  const [steps, cc] = await Promise.all([
    db.select().from(approvalSteps).where(eq(approvalSteps.documentId, id)).orderBy(asc(approvalSteps.stepOrder)),
    db.select({ userId: approvalCc.userId }).from(approvalCc).where(eq(approvalCc.documentId, id)),
  ]);
  return { doc, steps, ccIds: cc.map((c) => c.userId) };
}

/**
 * 결재 진행 — 문서 행을 잠근 채(FOR UPDATE) 다시 읽어 [plan](approvalRules.js planDecision을 감싼 함수)에 넘기고, 돌려받은 값을 한
 * 트랜잭션으로 쓴다. 두 사람이 동시에 눌러도 한쪽은 바뀐 상태를 보고 거절된다. plan이 `{ error }`면 그대로 돌려준다.
 * [afterApply](tx, { doc, steps, ccIds, result })는 같은 트랜잭션에서 더 할 일(근태 수정 반영 등).
 */
export async function applyApprovalDecision(id, plan, afterApply = null) {
  return db.transaction(async (tx) => {
    const [doc] = await tx.select().from(approvalDocuments).where(eq(approvalDocuments.id, id)).for('update');
    if (!doc) return { error: '결재 문서를 찾을 수 없습니다.', status: 404 };
    const steps = await tx.select().from(approvalSteps).where(eq(approvalSteps.documentId, id)).orderBy(asc(approvalSteps.stepOrder));
    const ccIds = (await tx.select({ userId: approvalCc.userId }).from(approvalCc).where(eq(approvalCc.documentId, id))).map((c) => c.userId);
    const result = await plan({ doc, steps, ccIds });
    if (result.error) return result;
    const [updated] = await tx.update(approvalDocuments).set(result.doc).where(eq(approvalDocuments.id, id)).returning();
    for (const { id: stepId, patch } of result.steps) {
      await tx.update(approvalSteps).set(patch).where(eq(approvalSteps.id, stepId));
    }
    if (afterApply) {
      // 결정을 반영한 칸들(전자서명이 지금 값으로 서명하게 — approvalSeal.js).
      const freshSteps = await tx.select().from(approvalSteps).where(eq(approvalSteps.documentId, id)).orderBy(asc(approvalSteps.stepOrder));
      await afterApply(tx, { doc: updated, steps, freshSteps, ccIds, result });
    }
    return { ...result, before: doc, document: updated };
  });
}

/**
 * 문서 목록(최신순) — [box]: 'inbox'(내가 지금 결재할 것) | 'mine'(내가 올린 것) | 'cc'(참조) | 'done'(내가 결재한 것) | 'all'(관리자 —
 * 이 범위 전부). [kind]·[status]로 좁히고 [before](만든 시각 ms)로 다음 쪽을 받는다. 결재선은 따로 붙인다(attachSteps).
 * [proxyFor]는 오늘 나에게 대결을 맡긴 사람들 — 'inbox'에 그 사람 차례인 문서도 넣는다(내가 올렸거나 이미 결재선에 있는 문서는 빼고).
 */
export async function listApprovalDocuments({
  scopeKey,
  box,
  userId,
  kind = null,
  status = null,
  before = null,
  limit = 50,
  proxyFor = [],
  unsettled = false,
  q = null,
  from = null,
  to = null,
  isManager = false,
}) {
  const conditions = [eq(approvalDocuments.scopeKey, scopeKey)];
  // 검색 — 제목·문서 번호·올린 사람 이름에 [q]가 들어간 것(대소문자 무시), 올린 날 [from]~[to]('YYYY-MM-DD' — 서버 PC 날짜).
  if (q) {
    const like = `%${q.replace(/[\\%_]/g, (c) => `\\${c}`)}%`;
    conditions.push(
      or(
        sql`${approvalDocuments.title} ilike ${like}`,
        sql`${approvalDocuments.docNumber} ilike ${like}`,
        sql`${approvalDocuments.authorName} ilike ${like}`,
      ),
    );
  }
  if (from) conditions.push(gte(approvalDocuments.createdAt, new Date(`${from}T00:00:00`)));
  if (to) conditions.push(lt(approvalDocuments.createdAt, new Date(new Date(`${to}T00:00:00`).getTime() + 86_400_000)));
  // 보관함 — 끝난 문서(결재 중이 아닌 것) 중 내가 볼 수 있는 것: 관리자는 범위 전부, 아니면 올렸거나 결재선(대결 포함)·참조에 있는 것.
  if (box === 'archive') {
    conditions.push(sql`${approvalDocuments.status} <> 'pending'`);
    if (!isManager) {
      conditions.push(
        or(
          eq(approvalDocuments.authorId, userId),
          sql`exists (select 1 from ${approvalSteps} where ${approvalSteps.documentId} = ${approvalDocuments.id}
            and (${approvalSteps.approverId} = ${userId} or ${approvalSteps.actedById} = ${userId}))`,
          sql`exists (select 1 from ${approvalCc} where ${approvalCc.documentId} = ${approvalDocuments.id} and ${approvalCc.userId} = ${userId})`,
        ),
      );
    }
  }
  // 정산 안 된 것 — 승인된 구매·출장 중 결재 중이거나 승인된 정산(지출 결재)이 없는 것(settlementRules.js).
  if (unsettled) {
    conditions.push(inArray(approvalDocuments.kind, ['purchase', 'trip']), eq(approvalDocuments.status, 'approved'));
    conditions.push(
      sql`not exists (select 1 from ${approvalDocuments} as s where s.settles_id = ${approvalDocuments.id}
        and s.status in ('pending', 'approved'))`,
    );
  }
  if (kind) conditions.push(eq(approvalDocuments.kind, kind));
  if (status) conditions.push(eq(approvalDocuments.status, status));
  if (before) conditions.push(lt(approvalDocuments.createdAt, new Date(before)));
  if (box === 'mine') conditions.push(eq(approvalDocuments.authorId, userId));
  if (box === 'inbox') {
    conditions.push(or(myPendingStep(userId), proxyPendingStep(userId, proxyFor)));
    // 결재 중인 문서, 또는 승인된 문서의 후결 차례(그 밖의 끝난 문서에는 차례인 칸이 없다).
    conditions.push(inArray(approvalDocuments.status, ['pending', 'approved']));
  }
  if (box === 'done') {
    // 내가 결정한 칸 — 내 칸이거나 대결로 내가 처리한 칸.
    conditions.push(
      sql`exists (select 1 from ${approvalSteps} where ${approvalSteps.documentId} = ${approvalDocuments.id}
        and (${approvalSteps.approverId} = ${userId} or ${approvalSteps.actedById} = ${userId})
        and ${inArray(approvalSteps.status, ['approved', 'rejected', 'disagreed'])})`,
    );
  }
  if (box === 'cc') {
    conditions.push(
      sql`exists (select 1 from ${approvalCc} where ${approvalCc.documentId} = ${approvalDocuments.id} and ${approvalCc.userId} = ${userId})`,
    );
  }
  const docs = await db
    .select()
    .from(approvalDocuments)
    .where(and(...conditions))
    .orderBy(desc(approvalDocuments.createdAt))
    .limit(limit);
  return attachSteps(docs);
}

/** 칸들에 전자서명을 적는다(applyApprovalDecision의 afterApply 안에서 — [seals] `[{ id, seal }]`). */
export async function writeStepSeals(tx, seals) {
  for (const { id, seal } of seals) await tx.update(approvalSteps).set({ seal }).where(eq(approvalSteps.id, id));
}

/** 문서들에 결재선을 붙인다 `[{ doc, steps }]`. */
async function attachSteps(docs) {
  if (docs.length === 0) return [];
  const steps = await db
    .select()
    .from(approvalSteps)
    .where(inArray(approvalSteps.documentId, docs.map((d) => d.id)))
    .orderBy(asc(approvalSteps.stepOrder));
  const byDoc = new Map(docs.map((d) => [d.id, []]));
  for (const s of steps) byDoc.get(s.documentId)?.push(s);
  return docs.map((doc) => ({ doc, steps: byDoc.get(doc.id) ?? [] }));
}

/** 문서에 내 차례인 칸이 있다. */
const myPendingStep = (userId) =>
  sql`exists (select 1 from ${approvalSteps} where ${approvalSteps.documentId} = ${approvalDocuments.id}
    and ${approvalSteps.approverId} = ${userId} and ${approvalSteps.status} = 'pending')`;

/** 문서에 나에게 대결을 맡긴 사람의 차례인 칸이 있다 — 내가 올렸거나 이미 결재선에 있는 문서는 뺀다(approvalRules.js proxyForOf). */
function proxyPendingStep(userId, proxyFor) {
  if (!proxyFor.length) return sql`false`;
  return and(
    sql`exists (select 1 from ${approvalSteps} where ${approvalSteps.documentId} = ${approvalDocuments.id}
      and ${inArray(approvalSteps.approverId, proxyFor)} and ${approvalSteps.status} = 'pending')`,
    sql`not exists (select 1 from ${approvalSteps} where ${approvalSteps.documentId} = ${approvalDocuments.id}
      and ${approvalSteps.approverId} = ${userId})`,
    sql`${approvalDocuments.authorId} is distinct from ${userId}`,
  );
}

/** 이 범위에서 내가 지금 결재할 문서 수(메뉴의 숫자 뱃지) — 대결을 맡은 문서 포함. */
export async function countPendingApprovals(scopeKey, userId, proxyFor = []) {
  const [row] = await db
    .select({ count: sql`count(*)`.mapWith(Number) })
    .from(approvalDocuments)
    .where(
      and(
        eq(approvalDocuments.scopeKey, scopeKey),
        // 승인된 문서의 후결 차례도 센다.
        inArray(approvalDocuments.status, ['pending', 'approved']),
        or(myPendingStep(userId), proxyPendingStep(userId, proxyFor)),
      ),
    );
  return row?.count ?? 0;
}

// ── 대결(부재 중 대신 결재) ──

/** 범위의 대결 설정 중 [today] 이후로 끝나는 것(지난 것은 뺌). [userIds]를 주면 그 사람들이 맡긴 것만. */
export function listCurrentDelegations(scopeKey, today, { userId = null } = {}) {
  const conditions = [eq(approvalDelegations.scopeKey, scopeKey), gte(approvalDelegations.endDate, today)];
  if (userId) conditions.push(eq(approvalDelegations.userId, userId));
  return db
    .select()
    .from(approvalDelegations)
    .where(and(...conditions))
    .orderBy(asc(approvalDelegations.startDate));
}

export async function insertDelegation(fields) {
  const [row] = await db.insert(approvalDelegations).values(fields).returning();
  return row;
}

export async function findDelegation(id) {
  const [row] = await db.select().from(approvalDelegations).where(eq(approvalDelegations.id, id)).limit(1);
  return row ?? null;
}

export async function deleteDelegation(id) {
  await db.delete(approvalDelegations).where(eq(approvalDelegations.id, id));
}

// ── 결재 통계 ──

/** [from]~[to](둘 다 포함, 'YYYY-MM-DD' — 서버 시각 기준) 사이에 올린 문서와 결재선 `[{ doc, steps }]`(통계용, 최대 5000건). */
export async function listDocumentsCreatedBetween({ scopeKey, from, to }) {
  const docs = await db
    .select()
    .from(approvalDocuments)
    .where(
      and(
        eq(approvalDocuments.scopeKey, scopeKey),
        gte(approvalDocuments.createdAt, new Date(`${from}T00:00:00`)),
        lt(approvalDocuments.createdAt, new Date(new Date(`${to}T00:00:00`).getTime() + 86_400_000)),
      ),
    )
    .orderBy(desc(approvalDocuments.createdAt))
    .limit(5000);
  return attachSteps(docs);
}

// ── 결재 알림함(알림 센터 "결재" 탭) ──────────────────────────────────────

/** 받는 사람마다 한 줄씩 넣는다 — [rows]: `[{ userId, documentId, teamId, kind, title, body, actorId, actorName }]`. 넣은 행들. */
export async function insertApprovalNotifications(rows) {
  if (rows.length === 0) return [];
  return db.insert(approvalNotifications).values(rows).returning();
}

/**
 * 내 결재 알림 최신순 — 팀 이름, 문서 종류·상태, 그리고 `actionable`(지금 내가 결재할 차례인지 — 요청 알림을 받은 뒤 이미 처리했거나
 * 회수됐으면 false)을 붙인다.
 */
export async function listApprovalNotifications(userId, limit = 50) {
  const rows = await db
    .select({
      n: approvalNotifications,
      teamName: teams.name,
      docKind: approvalDocuments.kind,
      docStatus: approvalDocuments.status,
      actionable: sql`(${approvalDocuments.status} = 'pending' and exists (select 1 from ${approvalSteps}
        where ${approvalSteps.documentId} = ${approvalDocuments.id} and ${approvalSteps.approverId} = ${userId}
        and ${approvalSteps.status} = 'pending'))`.mapWith(Boolean),
    })
    .from(approvalNotifications)
    .innerJoin(approvalDocuments, eq(approvalDocuments.id, approvalNotifications.documentId))
    .leftJoin(teams, eq(teams.id, approvalNotifications.teamId))
    .where(eq(approvalNotifications.userId, userId))
    .orderBy(desc(approvalNotifications.createdAt))
    .limit(limit);
  return rows.map((r) => ({ ...r.n, teamName: r.teamName, docKind: r.docKind, docStatus: r.docStatus, actionable: !!r.actionable }));
}

export async function countUnreadApprovalNotifications(userId) {
  const [row] = await db
    .select({ n: sql`count(*)::int` })
    .from(approvalNotifications)
    .where(and(eq(approvalNotifications.userId, userId), isNull(approvalNotifications.readAt)));
  return row?.n ?? 0;
}

/** 읽음 — [ids]도 [documentId]도 없으면 내 결재 알림 전부, [documentId]면 그 문서의 알림만(결재를 처리하면 그 요청 알림도 읽은 것으로). 바뀐 수. */
export async function markApprovalNotificationsRead(userId, { ids = null, documentId = null } = {}) {
  const conds = [eq(approvalNotifications.userId, userId), isNull(approvalNotifications.readAt)];
  if (ids && ids.length > 0) conds.push(inArray(approvalNotifications.id, ids));
  if (documentId) conds.push(eq(approvalNotifications.documentId, documentId));
  const rows = await db
    .update(approvalNotifications)
    .set({ readAt: new Date() })
    .where(and(...conds))
    .returning({ id: approvalNotifications.id });
  return rows.length;
}

export async function deleteApprovalNotificationsOlderThan(cutoff) {
  const rows = await db
    .delete(approvalNotifications)
    .where(lt(approvalNotifications.createdAt, cutoff))
    .returning({ id: approvalNotifications.id });
  return rows.length;
}

// ── 휴가 ───────────────────────────────────────────────────────────────

const DEDUCTING = ['annual', 'half_am', 'half_pm'];

/**
 * 연차에서 빠지는 휴가 합(반일 단위) — [statuses] 문서 중 시작일이 [from] 이상 [to] 미만인 것(기간을 걸친 휴가는 시작일 쪽 기간에 센다).
 * `{ approved, pending }`.
 */
export async function sumDeductedLeave({ scopeKey, userId, from, to }) {
  const rows = await db
    .select({
      status: approvalDocuments.status,
      // 시간 연차는 0.25 단위라 정수가 아니다.
      halfDays: sql`coalesce(sum((${approvalDocuments.payload}->>'halfDays')::numeric), 0)`.mapWith(Number),
    })
    .from(approvalDocuments)
    .where(
      and(
        eq(approvalDocuments.scopeKey, scopeKey),
        eq(approvalDocuments.authorId, userId),
        eq(approvalDocuments.kind, 'leave'),
        inArray(approvalDocuments.status, ['approved', 'pending']),
        // 신청할 때 적어 둔 연차 차감 여부(이 기능 전 신청은 기본 종류로 판단).
        sql`coalesce((${approvalDocuments.payload}->>'deducts')::boolean, ${approvalDocuments.payload}->>'leaveType' in (${sql.join(
          DEDUCTING.map((k) => sql`${k}`),
          sql`, `,
        )}))`,
        gte(sql`${approvalDocuments.payload}->>'startDate'`, from),
        lt(sql`${approvalDocuments.payload}->>'startDate'`, to),
      ),
    )
    .groupBy(approvalDocuments.status);
  const of = (s) => rows.find((r) => r.status === s)?.halfDays ?? 0;
  return { approved: of('approved'), pending: of('pending') };
}

/**
 * 승인된 휴가 중 [from]~[to](둘 다 포함)와 겹치는 것 — 캘린더 "팀 휴가"와 근태 요약이 쓴다. [userIds]를 주면 그 사람들 것만.
 * `[{ id, authorId, authorName, payload }]`.
 */
export async function listApprovedLeaves({ scopeKey, from, to, userIds = null }) {
  const conditions = [
    eq(approvalDocuments.scopeKey, scopeKey),
    eq(approvalDocuments.kind, 'leave'),
    eq(approvalDocuments.status, 'approved'),
    lte(sql`${approvalDocuments.payload}->>'startDate'`, to),
    gte(sql`${approvalDocuments.payload}->>'endDate'`, from),
  ];
  if (userIds) {
    if (userIds.length === 0) return [];
    conditions.push(inArray(approvalDocuments.authorId, userIds));
  }
  return db
    .select({
      id: approvalDocuments.id,
      authorId: approvalDocuments.authorId,
      authorName: approvalDocuments.authorName,
      payload: approvalDocuments.payload,
    })
    .from(approvalDocuments)
    .where(and(...conditions));
}

/** [from]~[to]와 겹치는 승인된 출장(양식 'trip' — payload.startDate·endDate)들 — 출장 날은 근태에서 결근으로 세지 않는다. */
export async function listApprovedTrips({ scopeKey, from, to, userIds = null }) {
  const conditions = [
    eq(approvalDocuments.scopeKey, scopeKey),
    eq(approvalDocuments.kind, 'trip'),
    eq(approvalDocuments.status, 'approved'),
    lte(sql`${approvalDocuments.payload}->>'startDate'`, to),
    gte(sql`${approvalDocuments.payload}->>'endDate'`, from),
  ];
  if (userIds) {
    if (userIds.length === 0) return [];
    conditions.push(inArray(approvalDocuments.authorId, userIds));
  }
  return db
    .select({
      id: approvalDocuments.id,
      authorId: approvalDocuments.authorId,
      authorName: approvalDocuments.authorName,
      payload: approvalDocuments.payload,
    })
    .from(approvalDocuments)
    .where(and(...conditions));
}

/**
 * [sourceIds] 결재들을 정산하는 지출 결재들 `[{ id, settlesId, docNumber, title, status, amount, createdAt }]`(settlementRules.js).
 */
export async function listSettlementsOf(sourceIds) {
  if (!sourceIds.length) return [];
  const rows = await db
    .select({
      id: approvalDocuments.id,
      settlesId: approvalDocuments.settlesId,
      docNumber: approvalDocuments.docNumber,
      title: approvalDocuments.title,
      status: approvalDocuments.status,
      payload: approvalDocuments.payload,
      createdAt: approvalDocuments.createdAt,
    })
    .from(approvalDocuments)
    .where(and(inArray(approvalDocuments.settlesId, sourceIds), eq(approvalDocuments.kind, 'expense')));
  return rows.map(({ payload, ...r }) => ({ ...r, amount: Number.isFinite(payload?.amount) ? payload.amount : null }));
}

/** 결재 문서 한 줄만(정산할 원래 결재 확인 — 결재선 없이). */
export async function findApprovalDocumentRow(id) {
  const [row] = await db.select().from(approvalDocuments).where(eq(approvalDocuments.id, id)).limit(1);
  return row ?? null;
}

/** [authorId]가 올려 결재 중인 휴가 중 [from]~[to]와 겹치는 것(휴가 달력에 내 것만 "결재 중"으로). */
export function listPendingLeavesOf({ scopeKey, authorId, from, to }) {
  return db
    .select({
      id: approvalDocuments.id,
      authorId: approvalDocuments.authorId,
      authorName: approvalDocuments.authorName,
      payload: approvalDocuments.payload,
    })
    .from(approvalDocuments)
    .where(
      and(
        eq(approvalDocuments.scopeKey, scopeKey),
        eq(approvalDocuments.kind, 'leave'),
        eq(approvalDocuments.status, 'pending'),
        eq(approvalDocuments.authorId, authorId),
        lte(sql`${approvalDocuments.payload}->>'startDate'`, to),
        gte(sql`${approvalDocuments.payload}->>'endDate'`, from),
      ),
    );
}

/** [from]~[to] 사이 승인된 연장근무(양식 'overtime' — payload.workDate·minutes)들. */
export async function listApprovedOvertime({ scopeKey, from, to, userIds = null }) {
  const conditions = [
    eq(approvalDocuments.scopeKey, scopeKey),
    eq(approvalDocuments.kind, 'overtime'),
    eq(approvalDocuments.status, 'approved'),
    gte(sql`${approvalDocuments.payload}->>'workDate'`, from),
    lte(sql`${approvalDocuments.payload}->>'workDate'`, to),
  ];
  if (userIds) {
    if (userIds.length === 0) return [];
    conditions.push(inArray(approvalDocuments.authorId, userIds));
  }
  return db
    .select({ id: approvalDocuments.id, authorId: approvalDocuments.authorId, payload: approvalDocuments.payload })
    .from(approvalDocuments)
    .where(and(...conditions));
}

/** [userId]의 결재 중·승인된 연장근무 신청 중 근무일이 [from]~[to](둘 다 포함)인 것 — 주 52시간 지키기(workPolicy.js). */
export async function listOvertimeRequests({ scopeKey, userId, from, to }) {
  return db
    .select({ id: approvalDocuments.id, status: approvalDocuments.status, payload: approvalDocuments.payload })
    .from(approvalDocuments)
    .where(
      and(
        eq(approvalDocuments.scopeKey, scopeKey),
        eq(approvalDocuments.authorId, userId),
        eq(approvalDocuments.kind, 'overtime'),
        inArray(approvalDocuments.status, ['approved', 'pending']),
        gte(sql`${approvalDocuments.payload}->>'workDate'`, from),
        lte(sql`${approvalDocuments.payload}->>'workDate'`, to),
      ),
    );
}

/** 이 사람의 결재 중·승인된 휴가 가운데 [from]~[to](둘 다 포함)와 겹치는 것 하나(없으면 null) — 같은 날 휴가를 두 번 내지 못하게. */
export async function findOverlappingLeave({ scopeKey, userId, from, to }) {
  const [row] = await db
    .select({ id: approvalDocuments.id, title: approvalDocuments.title, payload: approvalDocuments.payload })
    .from(approvalDocuments)
    .where(
      and(
        eq(approvalDocuments.scopeKey, scopeKey),
        eq(approvalDocuments.authorId, userId),
        eq(approvalDocuments.kind, 'leave'),
        inArray(approvalDocuments.status, ['approved', 'pending']),
        lte(sql`${approvalDocuments.payload}->>'startDate'`, to),
        gte(sql`${approvalDocuments.payload}->>'endDate'`, from),
      ),
    )
    .limit(1);
  return row ?? null;
}

/** 연차 조정 합(반일 단위)과 목록 — 그 연차 기간([periodStart]) 것. */
export async function listLeaveAdjustments({ scopeKey, userId, periodStart }) {
  return db
    .select()
    .from(leaveAdjustments)
    .where(and(eq(leaveAdjustments.scopeKey, scopeKey), eq(leaveAdjustments.userId, userId), eq(leaveAdjustments.periodStart, periodStart)))
    .orderBy(asc(leaveAdjustments.createdAt));
}

export async function insertLeaveAdjustment(fields) {
  const [row] = await db.insert(leaveAdjustments).values(fields).returning();
  return row;
}

// ── 입사일·구성원 ──────────────────────────────────────────────────────

/**
 * 이 범위의 구성원(탈퇴 제외) — 팀 범위면 그 팀 멤버와 팀의 입사일, 회사 전체면 모든 계정과 계정의 입사일.
 * `[{ id, name, username, role, suspendedAt, deletedAt, isOwner, hireDate }]`.
 */
export async function listGroupwareMembers({ scope, teamId }) {
  if (scope === 'team') {
    const rows = await db
      .select({ user: users, teamRole: teamMembers.role, hireDate: teamMembers.hireDate })
      .from(teamMembers)
      .innerJoin(users, eq(users.id, teamMembers.userId))
      .where(and(eq(teamMembers.teamId, teamId), isNull(users.deletedAt)));
    return rows.map((r) => ({ ...memberOf(r.user), isOwner: r.teamRole === 'owner', hireDate: r.hireDate ?? null }));
  }
  const rows = await db.select().from(users).where(isNull(users.deletedAt));
  return rows.map((u) => ({ ...memberOf(u), isOwner: false, hireDate: u.hireDate ?? null }));
}

const memberOf = (u) => ({
  id: u.id,
  name: u.name ?? u.username,
  username: u.username,
  role: u.role ?? 'guest',
  suspendedAt: u.suspendedAt ?? null,
  deletedAt: u.deletedAt ?? null,
});

/** 한 사람의 입사일(범위에 맞는 쪽). */
export async function findHireDate({ scope, teamId, userId }) {
  if (scope === 'team') {
    const [row] = await db
      .select({ hireDate: teamMembers.hireDate })
      .from(teamMembers)
      .where(and(eq(teamMembers.teamId, teamId), eq(teamMembers.userId, userId)));
    return row?.hireDate ?? null;
  }
  const [row] = await db.select({ hireDate: users.hireDate }).from(users).where(eq(users.id, userId));
  return row?.hireDate ?? null;
}

/** 입사일을 정한다(null이면 지움). 바꿨으면 true(팀 범위인데 그 팀 멤버가 아니면 false). */
export async function setHireDate({ scope, teamId, userId, hireDate }) {
  const rows =
    scope === 'team'
      ? await db
          .update(teamMembers)
          .set({ hireDate })
          .where(and(eq(teamMembers.teamId, teamId), eq(teamMembers.userId, userId)))
          .returning({ userId: teamMembers.userId })
      : await db.update(users).set({ hireDate }).where(eq(users.id, userId)).returning({ userId: users.id });
  return rows.length > 0;
}

// ── 저장한 결재선 ──────────────────────────────────────────────────────

export function listApprovalLines(ownerId, scopeKey) {
  return db
    .select()
    .from(approvalLines)
    .where(and(eq(approvalLines.ownerId, ownerId), eq(approvalLines.scopeKey, scopeKey)))
    .orderBy(desc(approvalLines.createdAt));
}

export async function insertApprovalLine(fields) {
  const [row] = await db.insert(approvalLines).values(fields).returning();
  return row;
}

/** 내 결재선을 지운다 — 지웠으면 true. */
export async function deleteApprovalLine(id, ownerId) {
  const rows = await db
    .delete(approvalLines)
    .where(and(eq(approvalLines.id, id), eq(approvalLines.ownerId, ownerId)))
    .returning({ id: approvalLines.id });
  return rows.length > 0;
}

// ── 출퇴근 ─────────────────────────────────────────────────────────────

/** 이 사람의 [fromDate] 이후 기록(최신 날짜 먼저). */
export function listRecentAttendance({ scopeKey, userId, fromDate }) {
  return db
    .select()
    .from(attendanceRecords)
    .where(and(eq(attendanceRecords.scopeKey, scopeKey), eq(attendanceRecords.userId, userId), gte(attendanceRecords.workDate, fromDate)))
    .orderBy(desc(attendanceRecords.workDate));
}

/** [from]~[to](둘 다 포함) 기록 — [userId]를 주면 그 사람 것만. */
export function listAttendanceInRange({ scopeKey, from, to, userId = null }) {
  const conditions = [eq(attendanceRecords.scopeKey, scopeKey), gte(attendanceRecords.workDate, from), lte(attendanceRecords.workDate, to)];
  if (userId) conditions.push(eq(attendanceRecords.userId, userId));
  return db.select().from(attendanceRecords).where(and(...conditions)).orderBy(asc(attendanceRecords.workDate));
}

/** 출근 — 그날 기록이 없을 때만 넣는다(이미 있으면 null — 한 번만 출근을 누른다). */
export async function insertClockIn(fields) {
  const [row] = await db.insert(attendanceRecords).values(fields).onConflictDoNothing().returning();
  return row ?? null;
}

/** 퇴근 — 아직 안 닫힌 기록만 닫는다(이미 퇴근했으면 null). [extra]는 함께 바꿀 값(열린 휴게 닫기·퇴근 위치). */
export async function updateClockOut(id, { clockOutAt, clockOutLan, ...extra }) {
  const [row] = await db
    .update(attendanceRecords)
    .set({ clockOutAt, clockOutLan, ...extra, updatedAt: new Date() })
    .where(and(eq(attendanceRecords.id, id), isNull(attendanceRecords.clockOutAt)))
    .returning();
  return row ?? null;
}

/** 휴게 목록 바꾸기 — 퇴근 전인 기록만(퇴근했으면 null). */
export async function updateAttendanceBreaks(id, breaks) {
  const [row] = await db
    .update(attendanceRecords)
    .set({ breaks, updatedAt: new Date() })
    .where(and(eq(attendanceRecords.id, id), isNull(attendanceRecords.clockOutAt)))
    .returning();
  return row ?? null;
}

// ── 통상시급(가산 수당 — workPolicy.js) ──

export async function listWorkWages(scopeKey) {
  return db.select().from(workWages).where(eq(workWages.scopeKey, scopeKey));
}

export async function findWorkWage(scopeKey, userId) {
  const [row] = await db
    .select()
    .from(workWages)
    .where(and(eq(workWages.scopeKey, scopeKey), eq(workWages.userId, userId)))
    .limit(1);
  return row ?? null;
}

/** 통상시급 정하기 — [hourlyWage]가 null이면 지운다. */
export async function setWorkWage(scopeKey, userId, hourlyWage) {
  if (hourlyWage === null) {
    await db.delete(workWages).where(and(eq(workWages.scopeKey, scopeKey), eq(workWages.userId, userId)));
    return null;
  }
  const [row] = await db
    .insert(workWages)
    .values({ scopeKey, userId, hourlyWage })
    .onConflictDoUpdate({ target: [workWages.scopeKey, workWages.userId], set: { hourlyWage, updatedAt: new Date() } })
    .returning();
  return row;
}

/**
 * 근태 수정 결재가 승인됐을 때(같은 트랜잭션 [tx]) — 그날 기록의 시각을 바꾸고 처음 값을 남긴다(이미 고쳐진 적이 있으면 처음 값은 그대로).
 * 기록이 없던 날이면 새로 만든다.
 */
export async function applyAttendanceCorrection(tx, { scopeKey, teamId, userId, workDate, clockInAt, clockOutAt, docId }) {
  const [existing] = await tx
    .select()
    .from(attendanceRecords)
    .where(and(eq(attendanceRecords.scopeKey, scopeKey), eq(attendanceRecords.userId, userId), eq(attendanceRecords.workDate, workDate)))
    .for('update');
  if (!existing) {
    await tx.insert(attendanceRecords).values({
      scopeKey,
      teamId,
      userId,
      workDate,
      clockInAt,
      clockOutAt,
      correctedDocId: docId,
      corrected: true,
    });
    return;
  }
  await tx
    .update(attendanceRecords)
    .set({
      clockInAt,
      clockOutAt: clockOutAt ?? existing.clockOutAt,
      correctedDocId: docId,
      originalClockInAt: existing.corrected ? existing.originalClockInAt : existing.clockInAt,
      originalClockOutAt: existing.corrected ? existing.originalClockOutAt : existing.clockOutAt,
      corrected: true,
      updatedAt: new Date(),
    })
    .where(eq(attendanceRecords.id, existing.id));
}

/**
 * 승인된 근태 수정을 관리자가 취소했을 때(같은 트랜잭션) — 그 결재로 고친 기록이면 처음 값으로 되돌린다. 처음 값이 없던 날(결재로 새로
 * 만든 기록)은 지운다. 그 뒤에 다른 결재로 또 고쳤으면(corrected_doc_id가 다르면) 손대지 않는다.
 */
export async function revertAttendanceCorrection(tx, docId) {
  const [record] = await tx.select().from(attendanceRecords).where(eq(attendanceRecords.correctedDocId, docId)).for('update');
  if (!record) return;
  // 출근 단추로 만든 기록은 사내 와이파이 여부(clock_in_lan)가 참·거짓으로 남는다 — null이면 결재로 새로 만든 기록이다.
  const createdByCorrection = record.clockInLan === null && !record.originalClockInAt && !record.originalClockOutAt;
  if (createdByCorrection) {
    await tx.delete(attendanceRecords).where(eq(attendanceRecords.id, record.id));
    return;
  }
  await tx
    .update(attendanceRecords)
    .set({
      clockInAt: record.originalClockInAt,
      clockOutAt: record.originalClockOutAt,
      correctedDocId: null,
      corrected: false,
      originalClockInAt: null,
      originalClockOutAt: null,
      updatedAt: new Date(),
    })
    .where(eq(attendanceRecords.id, record.id));
}

// ── 결재 양식(approvalForms.js) ──

/** 범위의 양식 줄들 — 관리자가 만든 양식과 기본 양식을 켜고 끈 기록. */
export function listApprovalTemplates(scopeKey) {
  return db
    .select()
    .from(approvalTemplates)
    .where(eq(approvalTemplates.scopeKey, scopeKey))
    .orderBy(asc(approvalTemplates.sortOrder), asc(approvalTemplates.createdAt));
}

export async function findApprovalTemplate(id) {
  const [row] = await db.select().from(approvalTemplates).where(eq(approvalTemplates.id, id)).limit(1);
  return row ?? null;
}

export async function insertApprovalTemplate(fields) {
  const [row] = await db.insert(approvalTemplates).values(fields).returning();
  return row;
}

export async function updateApprovalTemplate(id, patch) {
  const [row] = await db
    .update(approvalTemplates)
    .set({ ...patch, updatedAt: new Date() })
    .where(eq(approvalTemplates.id, id))
    .returning();
  return row ?? null;
}

export async function deleteApprovalTemplate(id) {
  await db.delete(approvalTemplates).where(eq(approvalTemplates.id, id));
}

/** 기본 양식을 이 범위에서 켜고 끈 기록 — 없으면 만들고 있으면 바꾼다. */
/** 기본 양식의 이 범위 기록 — 켜고 끄기·순서와 기본 결재선([defaults] `{ defaultLine, defaultCcIds }` — 주지 않으면 그대로). */
export async function upsertBuiltinTemplate(scopeKey, builtinKey, { name, enabled, sortOrder, defaults = null }) {
  const extra = defaults ? { defaultLine: defaults.defaultLine, defaultCcIds: defaults.defaultCcIds } : {};
  const [row] = await db
    .insert(approvalTemplates)
    .values({ scopeKey, builtinKey, name, fields: [], enabled, sortOrder, ...extra })
    .onConflictDoUpdate({
      target: [approvalTemplates.scopeKey, approvalTemplates.builtinKey],
      set: { enabled, sortOrder, ...extra, updatedAt: new Date() },
    })
    .returning();
  return row;
}

// ── 범위 설정·유연근무·알림·연차 촉진(groupwareWork.js) ──

/** 범위의 그룹웨어 설정 줄(없으면 null — 기본값). */
export async function findGroupwareOptions(scopeKey) {
  const [row] = await db.select().from(groupwareOptions).where(eq(groupwareOptions.scopeKey, scopeKey)).limit(1);
  return row ?? null;
}

export async function upsertGroupwareOptions(scopeKey, patch) {
  const [row] = await db
    .insert(groupwareOptions)
    .values({ scopeKey, ...patch })
    .onConflictDoUpdate({ target: groupwareOptions.scopeKey, set: { ...patch, updatedAt: new Date() } })
    .returning();
  return row;
}

/** 출근·퇴근 알림을 켠 범위들. */
export function listReminderScopes() {
  return db
    .select()
    .from(groupwareOptions)
    .where(sql`${groupwareOptions.clockInReminder} or ${groupwareOptions.clockOutReminder}`);
}

export function listWorkSchedules(scopeKey) {
  return db.select().from(workSchedules).where(eq(workSchedules.scopeKey, scopeKey));
}

export async function findWorkSchedule(scopeKey, userId) {
  const [row] = await db
    .select()
    .from(workSchedules)
    .where(and(eq(workSchedules.scopeKey, scopeKey), eq(workSchedules.userId, userId)))
    .limit(1);
  return row ?? null;
}

export async function upsertWorkSchedule(scopeKey, userId, schedule) {
  const [row] = await db
    .insert(workSchedules)
    .values({ scopeKey, userId, ...schedule })
    .onConflictDoUpdate({ target: [workSchedules.scopeKey, workSchedules.userId], set: { ...schedule, updatedAt: new Date() } })
    .returning();
  return row;
}

export async function deleteWorkSchedule(scopeKey, userId) {
  await db.delete(workSchedules).where(and(eq(workSchedules.scopeKey, scopeKey), eq(workSchedules.userId, userId)));
}

/** 알림을 보냈다고 적는다 — 이미 있으면 false(그날 그 종류는 한 번만). */
export async function claimAttendanceReminder({ scopeKey, userId, workDate, kind }) {
  const rows = await db
    .insert(attendanceReminders)
    .values({ scopeKey, userId, workDate, kind })
    .onConflictDoNothing()
    .returning({ userId: attendanceReminders.userId });
  return rows.length > 0;
}

export async function listAttendanceRemindersOn(scopeKey, workDate) {
  return db
    .select()
    .from(attendanceReminders)
    .where(and(eq(attendanceReminders.scopeKey, scopeKey), eq(attendanceReminders.workDate, workDate)));
}

/** 최근 [sinceDate]부터 출퇴근을 한 번이라도 누른 사람들 — 출근 알림은 출퇴근을 쓰는 사람에게만. */
export async function listRecentAttendanceUsers(scopeKey, sinceDate) {
  const rows = await db
    .selectDistinct({ userId: attendanceRecords.userId })
    .from(attendanceRecords)
    .where(and(eq(attendanceRecords.scopeKey, scopeKey), gte(attendanceRecords.workDate, sinceDate)));
  return rows.map((r) => r.userId);
}

export async function insertLeavePromotion(fields) {
  const [row] = await db.insert(leavePromotions).values(fields).returning();
  return row;
}

export async function findLeavePromotion(id) {
  const [row] = await db.select().from(leavePromotions).where(eq(leavePromotions.id, id)).limit(1);
  return row ?? null;
}

export async function updateLeavePromotion(id, patch) {
  const [row] = await db.update(leavePromotions).set(patch).where(eq(leavePromotions.id, id)).returning();
  return row ?? null;
}

/** 범위의 촉진 통지 — [userId]를 주면 그 사람 것만, [periodStart]를 주면 그 연차 기간 것만. 최근 것부터. */
export function listLeavePromotions(scopeKey, { userId = null, periodStart = null } = {}) {
  const conditions = [eq(leavePromotions.scopeKey, scopeKey)];
  if (userId) conditions.push(eq(leavePromotions.userId, userId));
  if (periodStart) conditions.push(eq(leavePromotions.periodStart, periodStart));
  return db
    .select()
    .from(leavePromotions)
    .where(and(...conditions))
    .orderBy(desc(leavePromotions.sentAt));
}
