import { randomUUID } from 'node:crypto';
import {
  findTaskStatusById,
  insertAutomationRun,
  insertTaskComment,
  isProjectMember,
  listAutomations,
  listReferencesForTasks,
  setTaskReferences,
  updateTask,
} from './db/queries/projects.js';

export const AUTOMATION_TRIGGERS = ['task_created', 'status_changed'];
export const ACTION_KINDS = ['set_assignee', 'set_status', 'set_priority', 'add_reference', 'add_comment', 'notify'];
const PRIORITIES = ['low', 'normal', 'high'];
const ACTION_LABELS = {
  set_assignee: '담당자 지정',
  set_status: '상태 변경',
  set_priority: '우선순위 변경',
  add_reference: '참조자 추가',
  add_comment: '댓글 남기기',
  notify: '알림 보내기',
};

/** 규칙의 조건(우선순위/유형)이 이 업무와 맞는지. 비어 있으면 항상 맞다. */
function matchesCondition(condition, task) {
  if (condition?.priority && condition.priority !== task.priority) return false;
  if (condition?.typeId && condition.typeId !== task.typeId) return false;
  return true;
}

/**
 * 규칙 입력(actions/condition)을 검증해서 저장 가능한 모양으로 돌려준다. 잘못됐으면 { error }.
 * 사용자/상태/유형은 이 프로젝트의 것이어야 한다.
 */
export async function validateAutomationInput(project, body, { loadTypes }) {
  const condition = {};
  if (body.condition?.priority) {
    if (!PRIORITIES.includes(body.condition.priority)) return { error: '조건의 우선순위가 올바르지 않습니다.' };
    condition.priority = body.condition.priority;
  }
  if (body.condition?.typeId) {
    const types = await loadTypes(project.id);
    if (!types.some((t) => t.id === body.condition.typeId)) return { error: '조건의 유형이 이 프로젝트의 것이 아닙니다.' };
    condition.typeId = body.condition.typeId;
  }
  const raw = Array.isArray(body.actions) ? body.actions : [];
  if (raw.length === 0) return { error: '동작을 하나 이상 추가하세요.' };
  if (raw.length > 5) return { error: '동작은 5개까지 넣을 수 있습니다.' };
  const actions = [];
  for (const a of raw) {
    if (!ACTION_KINDS.includes(a?.kind)) return { error: '동작 종류가 올바르지 않습니다.' };
    if (a.kind === 'set_assignee' || a.kind === 'add_reference' || a.kind === 'notify') {
      if (typeof a.userId !== 'string' || !(await isProjectMember(project.id, a.userId))) {
        return { error: '사용자는 프로젝트 구성원 중에서 고를 수 있습니다.' };
      }
      actions.push({ kind: a.kind, userId: a.userId });
    } else if (a.kind === 'set_status') {
      const st = typeof a.statusId === 'string' ? await findTaskStatusById(a.statusId) : null;
      if (!st || st.projectId !== project.id) return { error: '이 프로젝트의 상태가 아닙니다.' };
      actions.push({ kind: a.kind, statusId: st.id });
    } else if (a.kind === 'set_priority') {
      if (!PRIORITIES.includes(a.priority)) return { error: '우선순위 값이 올바르지 않습니다.' };
      actions.push({ kind: a.kind, priority: a.priority });
    } else if (a.kind === 'add_comment') {
      const text = typeof a.text === 'string' ? a.text.trim() : '';
      if (!text || text.length > 500) return { error: '댓글은 1~500자로 입력하세요.' };
      actions.push({ kind: a.kind, text });
    }
  }
  return { condition, actions };
}

/**
 * 트리거(task_created / status_changed)가 일어났을 때 이 프로젝트의 켜진 규칙을 차례로 실행한다.
 * 규칙의 동작은 DB를 직접 고치므로(라우터를 다시 타지 않으므로) 자동화가 또 다른 자동화를
 * 부르지 않는다. 실행 후의 최신 업무를 돌려준다.
 */
export async function runAutomations({ project, task, trigger, notifier }) {
  const rules = (await listAutomations(project.id, { onlyEnabled: true })).filter((r) => {
    if (r.trigger !== trigger) return false;
    if (trigger === 'status_changed' && r.triggerStatusId && r.triggerStatusId !== task.statusId) return false;
    return true;
  });
  let current = task;
  for (const rule of rules) {
    if (!matchesCondition(rule.condition, current)) continue;
    const done = [];
    let failed = 0;
    for (const action of rule.actions ?? []) {
      try {
        current = await applyAction({ project, task: current, rule, action, notifier });
        done.push(ACTION_LABELS[action.kind] ?? action.kind);
      } catch (e) {
        failed += 1;
        console.error(`[automation] "${rule.name}" 동작 실패:`, e?.message ?? e);
        done.push(`${ACTION_LABELS[action.kind] ?? action.kind}(실패)`);
      }
    }
    await insertAutomationRun({
      projectId: project.id,
      automationName: rule.name,
      taskId: current.id,
      taskKey: `${project.identifier}-${current.seq}`,
      trigger,
      summary: done.join(' → '),
      ok: failed === 0,
    }).catch((e) => console.error('[automation] 실행 기록 실패:', e?.message ?? e));
  }
  return current;
}

async function applyAction({ project, task, rule, action, notifier }) {
  const title = `${project.name} · ${project.identifier}-${task.seq}`;
  switch (action.kind) {
    case 'set_assignee': {
      const updated = await updateTask(task.id, { assigneeId: action.userId, dueRemindedFor: null });
      await notifier.notify({
        project,
        task: updated,
        kind: 'assigned',
        targetIds: [action.userId],
        title,
        body: `자동화 '${rule.name}'이(가) 업무를 배정했습니다: ${task.title}`,
      });
      return updated;
    }
    case 'set_status': {
      const st = await findTaskStatusById(action.statusId);
      if (!st) return task;
      return (
        (await updateTask(task.id, {
          statusId: st.id,
          status: st.category,
          completedAt: st.category === 'done' ? (task.completedAt ?? new Date()) : null,
        })) ?? task
      );
    }
    case 'set_priority':
      return (await updateTask(task.id, { priority: action.priority })) ?? task;
    case 'add_reference': {
      const refs = (await listReferencesForTasks([task.id]))[task.id] ?? [];
      if (!refs.includes(action.userId)) {
        await setTaskReferences(task.id, [...refs, action.userId]);
        await notifier.notify({
          project,
          task,
          kind: 'referenced',
          targetIds: [action.userId],
          title,
          body: `자동화 '${rule.name}'이(가) 참조자로 지정했습니다: ${task.title}`,
        });
      }
      return task;
    }
    case 'add_comment':
      await insertTaskComment({
        id: randomUUID(),
        taskId: task.id,
        projectId: project.id,
        senderId: null,
        senderName: `자동화 · ${rule.name}`,
        text: action.text,
      });
      return task;
    case 'notify':
      await notifier.notify({
        project,
        task,
        kind: 'automation',
        targetIds: [action.userId],
        title,
        body: `자동화 '${rule.name}': ${task.title}`,
      });
      return task;
    default:
      return task;
  }
}
