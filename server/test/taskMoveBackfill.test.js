// 업무 이동 흔적 정리 테스트 — `node --test test/taskMoveBackfill.test.js` (DB·서버 없이 돈다).
// 업무를 다른 프로젝트로 옮길 때의 뒷정리(db/queries/projects.js detachMovedTask)가 생기기 전에 옮긴 업무는 하위 업무가 원래 프로젝트에
// 남은 채 옮겨 간 부모를 가리키고, 그 업무의 댓글은 옛 프로젝트 id를 들고 있다(S23). 한 번 정리하는 마이그레이션(drizzle/0096)과, 그런
// 행이 남아 있어도 드러나지 않게 하는 읽기·권한·삭제 쪽 방어를 본다. 쿼리는 drizzle에 SQL을 받아 적는 가짜 pg 클라이언트로 돌린다
// (실제 DB에는 아무것도 묻지 않는다 — test/teamRemoval.test.js와 같은 방식). 마이그레이션은 돌리지 않고 글만 읽는다.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';
import { PgDialect } from 'drizzle-orm/pg-core';

process.env.DATABASE_URL ??= 'postgres://test:test@127.0.0.1:9/unused';
const { db } = await import('../src/db/client.js');
const { SAME_PROJECT_AS_PARENT, countSubtasks, deleteProject, deleteTask, listRecentTaskComments, listSubtasks } =
  await import('../src/db/queries/projects.js');

const migration = fs.readFileSync(new URL('../drizzle/0096_task_move_backfill.sql', import.meta.url), 'utf8');
const journal = JSON.parse(fs.readFileSync(new URL('../drizzle/meta/_journal.json', import.meta.url), 'utf8'));
const routerSource = fs.readFileSync(new URL('../src/projects.js', import.meta.url), 'utf8');

/** 주석을 뺀 SQL 문장들(drizzle이 나누는 표시 기준) — 공백은 한 칸으로. */
function statements(sqlText) {
  return sqlText
    .split('--> statement-breakpoint')
    .map((s) => s.replace(/^\s*--.*$/gm, '').replace(/\s+/g, ' ').trim())
    .filter(Boolean);
}

/** 가짜 pg 클라이언트 — drizzle이 보내는 SQL을 받아 적고 [respond]가 준 행(rowMode 'array')을 돌려준다. */
function fakePg(respond = () => []) {
  const queries = [];
  db.$client.query = async (config, values = []) => {
    const text = typeof config === 'string' ? config : config.text;
    queries.push({ text: text.replace(/\s+/g, ' ').trim(), values });
    const rows = respond(text, values) ?? [];
    return { rows, rowCount: rows.length };
  };
  return queries;
}

/** 한 함수의 소스(다음 함수 선언 전까지). */
function functionSource(source, name) {
  const start = source.indexOf(`async function ${name}(`);
  assert.ok(start >= 0, `${name}을(를) 찾지 못했다`);
  const end = source.indexOf('\n  }\n', start);
  return source.slice(start, end);
}

test('0096: 부모와 다른 프로젝트에 있는 하위 업무를 떼고, 업무 댓글을 업무의 지금 프로젝트로 맞춘다', () => {
  assert.ok(
    journal.entries.some((e) => e.tag === '0096_task_move_backfill'),
    '마이그레이션 원장(_journal.json)에 올라가 있어야 db:migrate가 돌린다',
  );
  const [subtasks, comments, ...rest] = statements(migration);
  assert.deepEqual(rest, [], '문장은 두 개뿐이다');
  // ① 하위 업무 — 부모와 프로젝트가 다른 것만, 원래 프로젝트의 독립 업무로(detachMovedTask와 같다).
  assert.equal(
    subtasks,
    'UPDATE "tasks" AS "child" SET "parent_task_id" = NULL, "updated_at" = now() FROM "tasks" AS "parent" ' +
      'WHERE "child"."parent_task_id" = "parent"."id" AND "child"."project_id" <> "parent"."project_id";',
  );
  // ② 댓글 — 업무의 지금 프로젝트와 다른 것만.
  assert.equal(
    comments,
    'UPDATE "task_comments" AS "c" SET "project_id" = "t"."project_id" FROM "tasks" AS "t" ' +
      'WHERE "c"."task_id" = "t"."id" AND "c"."project_id" <> "t"."project_id";',
  );
  // 데이터만 고친다 — 표·칸·제약은 건드리지 않는다.
  assert.doesNotMatch(migration, /\b(CREATE|ALTER|DROP|DELETE|TRUNCATE|INSERT)\b/i);
});

test('0096이 하는 일을 행으로 따라가 보면 — 프로젝트가 어긋난 행만 바뀌고, 다시 돌려도 그대로다', () => {
  // 위 두 문장을 그대로 옮긴 것(같은 표 안의 부모는 바꾸기 전 값으로 본다 — UPDATE … FROM이 그렇게 읽는다).
  function backfill({ tasks, comments }) {
    const before = new Map(tasks.map((t) => [t.id, { ...t }]));
    const nextTasks = tasks.map((t) => {
      const parent = t.parentTaskId ? before.get(t.parentTaskId) : null;
      return parent && t.projectId !== parent.projectId ? { ...t, parentTaskId: null, touched: true } : t;
    });
    const projectOf = new Map(nextTasks.map((t) => [t.id, t.projectId]));
    const nextComments = comments.map((c) =>
      projectOf.has(c.taskId) && c.projectId !== projectOf.get(c.taskId) ? { ...c, projectId: projectOf.get(c.taskId) } : c,
    );
    return { tasks: nextTasks, comments: nextComments };
  }
  // P는 A → B로 옮겨졌고(예전 이동이라 하위 업무 S1·S2는 A에 남아 P를 가리킨다), P의 사본 C도 A에서 P를 가리킨다.
  // Q는 A 안의 평범한 부모 — 하위 업무 S3은 그대로여야 한다.
  const data = {
    tasks: [
      { id: 'P', projectId: 'B', parentTaskId: null },
      { id: 'S1', projectId: 'A', parentTaskId: 'P' },
      { id: 'S2', projectId: 'A', parentTaskId: 'P' },
      { id: 'C', projectId: 'A', parentTaskId: 'P' },
      { id: 'Q', projectId: 'A', parentTaskId: null },
      { id: 'S3', projectId: 'A', parentTaskId: 'Q' },
    ],
    comments: [
      { id: 'c1', taskId: 'P', projectId: 'A' }, // 옮기기 전에 단 댓글
      { id: 'c2', taskId: 'P', projectId: 'B' }, // 옮긴 뒤에 단 댓글
      { id: 'c3', taskId: 'S3', projectId: 'A' },
    ],
  };
  const once = backfill(data);
  assert.deepEqual(
    once.tasks.map((t) => [t.id, t.parentTaskId]),
    [['P', null], ['S1', null], ['S2', null], ['C', null], ['Q', null], ['S3', 'Q']],
  );
  assert.deepEqual(once.comments.map((c) => [c.id, c.projectId]), [['c1', 'B'], ['c2', 'B'], ['c3', 'A']]);
  assert.deepEqual(
    once.tasks.filter((t) => t.touched).map((t) => t.id),
    ['S1', 'S2', 'C'],
    '같은 프로젝트 안의 하위 업무는 건드리지 않는다',
  );
  const twice = backfill({ tasks: once.tasks.map(({ touched, ...t }) => t), comments: once.comments });
  assert.deepEqual(twice.tasks.filter((t) => t.touched), [], '다시 돌리면 바뀌는 것이 없다');
  assert.deepEqual(twice.comments, once.comments);
});

test('하위 업무 읽기: 부모와 같은 프로젝트의 것만(listSubtasks·countSubtasks)', async () => {
  const condition = new PgDialect().sqlToQuery(SAME_PROJECT_AS_PARENT);
  assert.equal(
    condition.sql,
    'exists (select 1 from "tasks" parent_task where parent_task.id = "tasks"."parent_task_id" and parent_task.project_id = "tasks"."project_id")',
  );
  assert.deepEqual(condition.params, []);

  const list = listSubtasks('P', { includeArchived: true }).toSQL();
  assert.match(list.sql, /where \("tasks"\."parent_task_id" = \$1 and exists \(select 1 from "tasks" parent_task /);
  assert.ok(list.sql.includes(condition.sql));
  assert.deepEqual(list.params, ['P']);
  // 보관한 것은 기본으로 뺀다(예전 그대로).
  assert.match(listSubtasks('P').toSQL().sql, /"tasks"\."archived_at" is null/);

  const queries = fakePg(() => [['P', 2]]);
  assert.deepEqual(await countSubtasks(['P', 'Q']), { P: 2 });
  assert.equal(queries.length, 1);
  assert.ok(queries[0].text.includes(condition.sql), queries[0].text);
  assert.match(queries[0].text, /"tasks"\."parent_task_id" in \(\$1, \$2\)/);
  assert.deepEqual(queries[0].values, ['P', 'Q']);
});

test('최근 댓글: 업무의 지금 프로젝트로 모으고, 댓글의 프로젝트도 그 값으로 내려준다', async () => {
  const comment = [
    'c1', // id
    'P', // taskId
    'A', // projectId — 예전 이동 때 남은 옛 프로젝트
    'u1', // senderId
    '홍길동', // senderName
    '확인 부탁드립니다', // text
    null, // parentCommentId
    null, // textFormat
    '2026-10-01T00:00:00.000Z', // createdAt
    null, // editedAt
  ];
  const queries = fakePg(() => [[...comment, 'B', '옮긴 업무', 1001, '개발', 'DEV']]);
  const rows = await listRecentTaskComments(['B']);
  const [{ text, values }] = queries;
  assert.match(text, /inner join "tasks" on "task_comments"\."task_id" = "tasks"\."id"/);
  assert.match(text, /inner join "projects" on "tasks"\."project_id" = "projects"\."id"/);
  assert.match(text, /where "tasks"\."project_id" in \(\$1\)/);
  assert.doesNotMatch(text, /"task_comments"\."project_id" in/);
  assert.doesNotMatch(text, /on "task_comments"\."project_id" = "projects"\."id"/);
  assert.deepEqual(values, ['B', 10]);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].projectId, 'B');
  assert.equal(rows[0].taskTitle, '옮긴 업무');
  assert.equal(rows[0].projectIdentifier, 'DEV');
  assert.ok(!('taskProjectId' in rows[0]));
  assert.deepEqual(await listRecentTaskComments([]), []);
});

test('업무·프로젝트 삭제: 다른 프로젝트에 남은 하위 업무는 같이 지우지 않고 먼저 뗀다', async () => {
  const taskQueries = fakePg((text) => (/^delete from "tasks"/.test(text) ? [['P']] : []));
  assert.equal(await deleteTask('P'), true);
  assert.equal(taskQueries.length, 2);
  assert.equal(
    taskQueries[0].text,
    'update "tasks" set parent_task_id = null, updated_at = now() where parent_task_id = $1 and project_id <> (select doomed.project_id from "tasks" doomed where doomed.id = $2)',
  );
  assert.deepEqual(taskQueries[0].values, ['P', 'P']);
  assert.equal(taskQueries[1].text, 'delete from "tasks" where "tasks"."id" = $1 returning "id"');

  const projectQueries = fakePg();
  await deleteProject('B');
  assert.equal(projectQueries.length, 2);
  assert.equal(
    projectQueries[0].text,
    'update "tasks" set parent_task_id = null, updated_at = now() where project_id <> $1 and parent_task_id in (select doomed.id from "tasks" doomed where doomed.project_id = $2)',
  );
  assert.deepEqual(projectQueries[0].values, ['B', 'B']);
  assert.equal(projectQueries[1].text, 'delete from "projects" where "projects"."id" = $1');
});

test('업무 댓글 수정·삭제 권한은 업무의 지금 프로젝트로 본다(projects.js requireOwnTaskComment)', () => {
  const body = functionSource(routerSource, 'requireOwnTaskComment');
  assert.match(body, /const task = comment \? await findTaskById\(comment\.taskId\) : null;/);
  assert.match(body, /requireProjectMember\(req, res, task\.projectId\)/);
  assert.doesNotMatch(body, /comment\.projectId/, '댓글 행의 project_id로 권한을 보지 않는다');
});

test('업무 복사: 부모가 같은 프로젝트에 있을 때만 사본도 그 부모 밑에 둔다(projects.js POST /tasks/:id/copy)', () => {
  const start = routerSource.indexOf("router.post('/tasks/:id/copy'");
  const copy = routerSource.slice(start, routerSource.indexOf("router.post('/tasks/:id/move'", start));
  assert.match(copy, /parentTaskId: parent && parent\.projectId === task\.projectId \? parent\.id : null,/);
  assert.doesNotMatch(copy, /parentTaskId: task\.parentTaskId/);
});
