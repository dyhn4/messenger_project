import { randomUUID } from 'node:crypto';
import { Router } from 'express';
import {
  findFirstStatusOfCategory,
  findProjectById,
  findTaskById,
  findTaskStatusById,
  insertChecklistItem,
  insertTask,
  listChecklistItems,
  listReferencesForTasks,
  setTaskReferences,
  takeNextTaskSeq,
} from './db/queries/projects.js';
import {
  countOpenPredecessors,
  countPredecessors,
  deleteDependency,
  deleteTimeEntry,
  findTimeEntryById,
  findTimerOf,
  insertDependency,
  insertTimeEntry,
  listPredecessors,
  listProjectDependencies,
  listSuccessors,
  listTimeEntries,
  startTimer,
  sumTimeForTasks,
  takeRecurrence,
  takeTimer,
  timeReport,
} from './db/queries/taskExtras.js';
import { runAutomations } from './projectAutomation.js';
import {
  TASK_PREDECESSORS_MAX,
  minutesLabel,
  nextOccurrenceDates,
  parseReportRange,
  parseTimeEntry,
  recurrenceLabel,
  recurrenceOf,
  timerEntry,
  wouldCreateCycle,
} from './taskExtrasRules.js';

/** 업무 번호(MKT-12) — projects.js taskKey와 같다. */
const keyOf = (identifier, seq) => `${identifier}-${seq}`;

/** 선후행 목록 한 줄. */
function toTaskSummaryDto(row, identifier) {
  return {
    id: row.id,
    key: keyOf(identifier, row.seq),
    title: row.title,
    status: row.status,
    statusName: row.statusName ?? null,
    statusColor: row.statusColor ?? null,
    assigneeId: row.assigneeId ?? null,
    assigneeName: row.assigneeName ?? null,
    dueDate: row.dueDate ? new Date(row.dueDate).getTime() : null,
    archived: !!row.archivedAt,
  };
}

function toTimeEntryDto(e) {
  return {
    id: e.id,
    taskId: e.taskId,
    userId: e.userId,
    userName: e.userName ?? null,
    minutes: e.minutes,
    workDate: e.workDate,
    note: e.note ?? null,
    createdAt: new Date(e.createdAt).getTime(),
  };
}

function toTimerDto(t) {
  if (!t) return null;
  return {
    taskId: t.taskId,
    key: keyOf(t.identifier, t.seq),
    title: t.title,
    projectId: t.projectId,
    projectName: t.projectName,
    startedAt: new Date(t.startedAt).getTime(),
  };
}

/** 목록·상세 업무에 붙는 값 — 기록한 시간 합과 안 끝난 선행 수(projects.js decorateTasks가 함께 부른다). */
export async function taskExtrasCounts(taskIds) {
  const [spent, openPredecessors] = await Promise.all([sumTimeForTasks(taskIds), countOpenPredecessors(taskIds)]);
  return { spent, openPredecessors };
}

/**
 * 업무 기능 보강 — 반복 업무(완료하면 다음 회차), 선후행 관계, 소요 시간 기록·타이머·보고. projects.js 라우터 안에서 만들어
 * 같은 입구(준회원 막기)와 권한 도우미를 쓴다. 규칙은 taskExtrasRules.js.
 *
 * [ctx]: { io, notifier, requireProjectMember, isProjectManager, rejectIfArchived, rejectIfTaskArchived,
 *   recordTaskActivity, notifyProjectMembers }.
 * 돌려주는 것: { router, afterStatusChange(project, before, after, actorId), detailExtras(task, project) }.
 */
export function createTaskExtras(ctx) {
  const {
    io,
    notifier,
    requireProjectMember,
    isProjectManager,
    rejectIfArchived,
    rejectIfTaskArchived,
    recordTaskActivity,
    notifyProjectMembers,
  } = ctx;
  const router = Router();

  /** 업무와 그 프로젝트(구성원만) — 아니면 응답하고 null. [write]면 종료된 프로젝트·보관한 업무를 막는다. */
  async function loadTask(req, res, { write = false } = {}) {
    const task = await findTaskById(req.params.id);
    if (!task) {
      res.status(404).json({ error: '업무를 찾을 수 없습니다.' });
      return null;
    }
    const project = await requireProjectMember(req, res, task.projectId);
    if (!project) return null;
    if (write && (rejectIfArchived(res, project) || rejectIfTaskArchived(res, task))) return null;
    return { task, project };
  }

  // ── 반복 업무 ─────────────────────────────────────────────────────────

  /**
   * 반복 업무를 끝냈다 — 규칙을 이 업무에서 떼어(한 번만) 다음 회차 업무를 만든다. 제목·설명·담당자·참조자·유형·우선순위·
   * 필드·예상 시간·체크리스트(모두 안 한 것으로)를 그대로 옮기고, 날짜는 규칙대로 옮긴다. 만든 업무(없으면 null).
   */
  async function spawnNextOccurrence(project, task, actorId) {
    const rule = recurrenceOf(task);
    if (!rule) return null;
    if (!(await takeRecurrence(task.id))) return null;
    const dates = nextOccurrenceDates(task, rule, new Date());
    if (!dates) {
      await recordTaskActivity(task.id, actorId, ['반복 종료일이 지나 반복을 마쳤습니다.']);
      return null;
    }
    const parent = task.parentTaskId ? await findTaskById(task.parentTaskId) : null;
    const todo = await findFirstStatusOfCategory(project.id, 'todo');
    const seq = await takeNextTaskSeq(project.id);
    const inserted = await insertTask({
      id: randomUUID(),
      projectId: project.id,
      seq,
      parentTaskId: parent && parent.projectId === project.id && !parent.archivedAt ? parent.id : null,
      title: task.title,
      description: task.description,
      assigneeId: task.assigneeId,
      status: 'todo',
      statusId: todo?.id ?? null,
      customValues: task.customValues ?? {},
      priority: task.priority,
      priorityId: task.priorityId,
      typeId: task.typeId,
      startDate: dates.startDate,
      dueDate: dates.dueDate,
      createdBy: actorId,
      completedAt: null,
      recurrence: rule,
      estimateMinutes: task.estimateMinutes ?? null,
    });
    const refs = (await listReferencesForTasks([task.id]))[task.id] ?? [];
    if (refs.length > 0) await setTaskReferences(inserted.id, refs);
    for (const item of await listChecklistItems(task.id)) await insertChecklistItem(inserted.id, item.text);
    const nextKey = keyOf(project.identifier, inserted.seq);
    const prevKey = keyOf(project.identifier, task.seq);
    await recordTaskActivity(task.id, actorId, [`반복 업무 — 다음 회차 ${nextKey}를 만들었습니다.`]);
    const status = inserted.statusId ? await findTaskStatusById(inserted.statusId) : null;
    await recordTaskActivity(inserted.id, actorId, [
      { text: '업무를 만들었습니다.', kind: 'created', detail: status?.name ?? null, color: status?.color ?? null },
      `반복 업무(${recurrenceLabel(rule)}) — ${prevKey}에서 이어졌습니다.`,
    ]);
    // 새 업무에도 "업무 생성" 자동화를 돌린다(자동 배정 등) — 손으로 만든 업무와 같게.
    const created = await runAutomations({ project, task: inserted, trigger: 'task_created', notifier, io, actorId });
    if (created.assigneeId) {
      const when = created.dueDate ? new Date(created.dueDate).toISOString().slice(0, 10) : null;
      await notifier.notify({
        project,
        task: created,
        kind: 'recurring',
        actorId,
        targetIds: [created.assigneeId],
        title: `${project.name} · ${nextKey}`,
        body: `반복 업무의 다음 회차가 만들어졌습니다${when ? `(마감 ${when})` : ''}: ${created.title}`,
      });
    }
    await notifyProjectMembers(project, created.id);
    return created;
  }

  /** 끝낸 업무를 선행으로 둔 후행 업무 중 이제 선행이 모두 끝난 것 — 기록을 남기고 담당자에게 알린다. */
  async function releaseSuccessors(project, task, actorId) {
    const successors = (await listSuccessors(task.id)).filter((s) => s.status !== 'done' && !s.archivedAt);
    if (successors.length === 0) return;
    const open = await countOpenPredecessors(successors.map((s) => s.id));
    for (const s of successors) {
      if ((open[s.id] ?? 0) > 0) continue;
      const key = keyOf(project.identifier, s.seq);
      await recordTaskActivity(s.id, actorId, [
        `선행 업무 ${keyOf(project.identifier, task.seq)}이(가) 끝나 선행 업무가 모두 끝났습니다.`,
      ]);
      if (s.assigneeId) {
        await notifier.notify({
          project,
          task: s,
          kind: 'dependency',
          actorId,
          targetIds: [s.assigneeId],
          title: `${project.name} · ${key}`,
          body: `선행 업무가 모두 끝나 시작할 수 있습니다: ${s.title}`,
        });
      }
    }
  }

  /**
   * PATCH /tasks/:id가 상태를 바꾼 뒤 부른다 — 완료로 바뀌었으면 다음 회차를 만들고 후행 업무를 풀어 준다.
   * 만든 다음 회차 업무(없으면 null)를 돌려준다(응답의 nextRecurrence).
   */
  async function afterStatusChange(project, before, after, actorId) {
    if (before.status === 'done' || after.status !== 'done') return null;
    const next = await spawnNextOccurrence(project, after, actorId);
    await releaseSuccessors(project, after, actorId);
    return next;
  }

  // ── 선후행 ────────────────────────────────────────────────────────────

  /** 선행 업무 넣기 `{ taskId }` — 같은 프로젝트, 순환 없이, 업무마다 30개까지. → `{ predecessors, successors }`. */
  router.post('/tasks/:id/dependencies', async (req, res) => {
    const ctxTask = await loadTask(req, res, { write: true });
    if (!ctxTask) return;
    const { task, project } = ctxTask;
    const otherId = req.body?.taskId;
    if (typeof otherId !== 'string') return res.status(400).json({ error: '선행 업무를 고르세요.' });
    if (otherId === task.id) return res.status(400).json({ error: '자기 자신을 선행 업무로 둘 수 없습니다.' });
    const other = await findTaskById(otherId).catch(() => null);
    if (!other || other.projectId !== project.id) {
      return res.status(400).json({ error: '같은 프로젝트의 업무만 선행 업무로 둘 수 있습니다.' });
    }
    if ((await countPredecessors(task.id)) >= TASK_PREDECESSORS_MAX) {
      return res.status(400).json({ error: `선행 업무는 ${TASK_PREDECESSORS_MAX}개까지 둘 수 있습니다.` });
    }
    if (wouldCreateCycle(await listProjectDependencies(project.id), task.id, other.id)) {
      return res.status(400).json({ error: '이 업무를 선행으로 두면 서로 기다리는 순환이 생깁니다.' });
    }
    if (await insertDependency(task.id, other.id, req.user.sub)) {
      await recordTaskActivity(task.id, req.user.sub, [
        `선행 업무로 ${keyOf(project.identifier, other.seq)}을(를) 지정했습니다.`,
      ]);
      await notifyProjectMembers(project, task.id);
    }
    res.json(await dependencyLists(task, project));
  });

  router.delete('/tasks/:id/dependencies/:otherId', async (req, res) => {
    const ctxTask = await loadTask(req, res, { write: true });
    if (!ctxTask) return;
    const { task, project } = ctxTask;
    if (await deleteDependency(task.id, req.params.otherId)) {
      const other = await findTaskById(req.params.otherId).catch(() => null);
      await recordTaskActivity(task.id, req.user.sub, [
        other ? `선행 업무 ${keyOf(project.identifier, other.seq)}을(를) 해제했습니다.` : '선행 업무를 해제했습니다.',
      ]);
      await notifyProjectMembers(project, task.id);
    }
    res.json(await dependencyLists(task, project));
  });

  async function dependencyLists(task, project) {
    const [predecessors, successors] = await Promise.all([listPredecessors(task.id), listSuccessors(task.id)]);
    return {
      predecessors: predecessors.map((r) => toTaskSummaryDto(r, project.identifier)),
      successors: successors.map((r) => toTaskSummaryDto(r, project.identifier)),
    };
  }

  // ── 소요 시간 ─────────────────────────────────────────────────────────

  router.get('/tasks/:id/time-entries', async (req, res) => {
    const ctxTask = await loadTask(req, res);
    if (!ctxTask) return;
    res.json((await listTimeEntries(ctxTask.task.id)).map(toTimeEntryDto));
  });

  /** 시간 남기기 `{ minutes, workDate?, note? }` — 구성원 누구나 자기 시간을. → 남긴 기록. */
  router.post('/tasks/:id/time-entries', async (req, res) => {
    const ctxTask = await loadTask(req, res, { write: true });
    if (!ctxTask) return;
    const parsed = parseTimeEntry(req.body);
    if (parsed.error) return res.status(400).json({ error: parsed.error });
    const row = await insertTimeEntry({ id: randomUUID(), taskId: ctxTask.task.id, userId: req.user.sub, ...parsed.entry });
    await recordTaskActivity(ctxTask.task.id, req.user.sub, [`소요 시간 ${minutesLabel(row.minutes)}을 기록했습니다.`]);
    await notifyProjectMembers(ctxTask.project, ctxTask.task.id);
    const [entry] = (await listTimeEntries(ctxTask.task.id)).filter((e) => e.id === row.id);
    res.status(201).json(toTimeEntryDto(entry ?? row));
  });

  /** 시간 기록 지우기 — 남긴 사람 또는 프로젝트 관리자. */
  router.delete('/tasks/:id/time-entries/:entryId', async (req, res) => {
    const ctxTask = await loadTask(req, res);
    if (!ctxTask) return;
    if (rejectIfArchived(res, ctxTask.project)) return;
    const entry = await findTimeEntryById(req.params.entryId).catch(() => null);
    if (!entry || entry.taskId !== ctxTask.task.id) return res.status(404).json({ error: '시간 기록을 찾을 수 없습니다.' });
    if (entry.userId !== req.user.sub && !(await isProjectManager(ctxTask.project, req.user.sub))) {
      return res.status(403).json({ error: '내가 남긴 기록만 지울 수 있습니다.' });
    }
    await deleteTimeEntry(entry.id);
    await notifyProjectMembers(ctxTask.project, ctxTask.task.id);
    res.json({ ok: true });
  });

  /** 프로젝트 소요 시간 보고 `?from=YYYY-MM-DD&to=YYYY-MM-DD`(기본 이번 달) — 구성원 누구나. */
  router.get('/projects/:id/time-report', async (req, res) => {
    const project = await requireProjectMember(req, res, req.params.id);
    if (!project) return;
    const range = parseReportRange(req.query);
    if (range.error) return res.status(400).json({ error: range.error });
    const { byMember, byTask } = await timeReport(project.id, range.from, range.to);
    res.json({
      from: range.from,
      to: range.to,
      totalMinutes: byMember.reduce((sum, m) => sum + (m.minutes ?? 0), 0),
      byMember: byMember.map((m) => ({ userId: m.userId, name: m.name ?? null, minutes: m.minutes ?? 0 })),
      byTask: byTask.map((t) => ({
        taskId: t.taskId,
        key: keyOf(project.identifier, t.seq),
        title: t.title,
        minutes: t.minutes ?? 0,
        estimateMinutes: t.estimateMinutes ?? null,
      })),
    });
  });

  // ── 타이머 ────────────────────────────────────────────────────────────
  // 사람마다 하나 — 다른 업무에서 켜면 돌던 것을 멈춰 기록하고 새로 켠다. 바뀌면 내 기기들에 task:timer로 알린다.

  async function emitTimer(userId) {
    io.to(`user:${userId}`).emit('task:timer', { timer: toTimerDto(await findTimerOf(userId)) });
  }

  /** 돌던 타이머를 멈추고 1분 이상이면 기록으로 남긴다 — 남긴 기록(없으면 null). */
  async function stopTimerOf(userId, note = null) {
    const timer = await takeTimer(userId);
    if (!timer) return null;
    const made = timerEntry(timer.startedAt, new Date());
    if (!made) return null;
    const task = await findTaskById(timer.taskId);
    if (!task) return null;
    const row = await insertTimeEntry({ id: randomUUID(), taskId: task.id, userId, ...made, note });
    await recordTaskActivity(task.id, userId, [`타이머로 소요 시간 ${minutesLabel(row.minutes)}을 기록했습니다.`]);
    return row;
  }

  router.get('/tasks/timer', async (req, res) => {
    res.json({ timer: toTimerDto(await findTimerOf(req.user.sub)) });
  });

  router.post('/tasks/:id/timer/start', async (req, res) => {
    const ctxTask = await loadTask(req, res, { write: true });
    if (!ctxTask) return;
    const running = await findTimerOf(req.user.sub);
    if (running?.taskId === ctxTask.task.id) return res.json({ timer: toTimerDto(running), stopped: null });
    const stopped = running ? await stopTimerOf(req.user.sub) : null;
    await startTimer(req.user.sub, ctxTask.task.id);
    await emitTimer(req.user.sub);
    res.json({ timer: toTimerDto(await findTimerOf(req.user.sub)), stopped: stopped ? toTimeEntryDto(stopped) : null });
  });

  /** 타이머 멈추기 `{ note? }` → `{ entry }`(1분이 안 되면 null — 버림). */
  router.post('/tasks/timer/stop', async (req, res) => {
    const note = typeof req.body?.note === 'string' ? req.body.note.trim().slice(0, 200) || null : null;
    const running = await findTimerOf(req.user.sub);
    const entry = await stopTimerOf(req.user.sub, note);
    await emitTimer(req.user.sub);
    if (entry && running) {
      const project = await findProjectById(running.projectId);
      if (project) await notifyProjectMembers(project, running.taskId);
    }
    res.json({ entry: entry ? toTimeEntryDto(entry) : null });
  });

  /** 업무 상세(GET /tasks/:id)에 덧붙일 값 — 반복 규칙·예상 시간·선후행·시간 기록. */
  async function detailExtras(task, project) {
    const [lists, entries] = await Promise.all([dependencyLists(task, project), listTimeEntries(task.id)]);
    return { recurrence: recurrenceOf(task), ...lists, timeEntries: entries.map(toTimeEntryDto) };
  }

  return { router, afterStatusChange, detailExtras, stopTimerOf };
}
