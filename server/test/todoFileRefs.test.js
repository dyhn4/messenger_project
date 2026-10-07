// 할 일 첨부의 파일 확인 단위 테스트(S22) — `node --test test/todoFileRefs.test.js` (DB·서버 없이 돈다).
// 할 일 첨부도 메시지와 같은 규칙(fileRefs.js checkFileRefs)으로 받는다: 직접 올린 파일, 이 할 일(고칠 때)·출처 글("할 일로 등록")에 원래
// 있던 파일, 서명 링크로 온 지금 볼 수 있는 방의 파일. todos.js가 todoRules.js parseAttachments(모양 — 그리고 보낸 참조 refs)를 지난 뒤
// 그 refs를 checkFileRefs에 넘기는 것을, 같은 순서로 가짜 조회를 넣어 확인한다. 라우트의 연결은 소스에서 본다(projectGuardJoin.test.js와
// 같은 방식).
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { mock, test } from 'node:test';
import { parseAttachments, parseTodoCreate, sourceFilePaths, storedAttachmentPaths, TODO_ATTACHMENT_LINK_ERROR } from '../src/todoRules.js';
import { signFileUrl } from '../src/upload.js';

process.env.DATABASE_URL = 'postgres://test:test@127.0.0.1:1/unused';
const { db } = await import('../src/db/client.js');
for (const method of ['select', 'insert', 'update', 'delete', 'execute', 'transaction']) {
  mock.method(db, method, () => {
    throw new Error(`이 테스트는 DB를 쓰면 안 된다(db.${method})`);
  });
}
const { checkFileRefs } = await import('../src/fileRefs.js');

const ME = '11111111-1111-4111-8111-111111111111';
const OTHER = '22222222-2222-4222-8222-222222222222';
const MINE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.png';
const MINE_THUMB = 'abababab-abab-4bab-8bab-abababababab.jpg';
const THEIRS = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.png';
const THEIRS_THUMB = 'bdbdbdbd-bdbd-4dbd-8dbd-bdbdbdbdbdbd.jpg';
const DOC = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd.pdf';
const stored = (name) => `/uploads/${name}`;
const NOW = Date.now();

/** [hours]시간 전에 서명된 링크 — 최대 2시간이라 이미 만료된 것(화면을 오래 열어 둔 경우). */
function signedHoursAgo(p, hours, downloadName) {
  const issuedAt = Date.now() - hours * 60 * 60 * 1000;
  const clock = mock.method(Date, 'now', () => issuedAt);
  try {
    return signFileUrl(p, downloadName);
  } finally {
    clock.mock.restore();
  }
}

/** 가짜 조회 — 부른 기록을 남긴다. */
function fakeLookups({ reachable = [] } = {}) {
  const owners = new Map([
    [MINE, ME],
    [MINE_THUMB, ME],
    [THEIRS, OTHER],
    [THEIRS_THUMB, OTHER],
    [DOC, OTHER],
  ]);
  const calls = { uploaders: [], reachable: [] };
  return {
    calls,
    async findUploaders(names) {
      calls.uploaders.push(names);
      return new Map(names.filter((n) => owners.has(n)).map((n) => [n, owners.get(n)]));
    },
    async findReachableUploadPaths(userId, paths) {
      calls.reachable.push({ userId, paths });
      return new Set(paths.filter((p) => reachable.includes(p)));
    },
  };
}

/** POST /rooms/:roomId/todos가 하는 순서 — 모양 검사(parseTodoCreate) 뒤 첨부 확인(출처 글의 파일이 "원래 있던 파일"). */
async function createTodo(attachments, { sourcePaths = [], lookups = fakeLookups() } = {}) {
  const input = parseTodoCreate({ title: '할 일', attachments }, NOW, sourcePaths);
  if (input.error) return { error: input.error };
  const files = await checkFileRefs(
    input.attachmentRefs,
    { senderId: ME, existing: sourcePaths, error: TODO_ATTACHMENT_LINK_ERROR },
    lookups,
  );
  return files.ok ? { attachments: input.attachments } : { error: files.error };
}

/** PATCH /todos/:id가 하는 순서 — 이 할 일에 저장된 첨부(storedAttachmentPaths)가 "원래 있던 파일". */
async function updateAttachments(storedRows, attachments, lookups = fakeLookups()) {
  const existing = storedAttachmentPaths(storedRows);
  const r = parseAttachments(attachments, existing);
  if (r.error) return { error: r.error };
  const files = await checkFileRefs(r.refs, { senderId: ME, existing, error: TODO_ATTACHMENT_LINK_ERROR }, lookups);
  return files.ok ? { attachments: r.value } : { error: files.error };
}

test('parseAttachments: 받은 링크를 보낸 그대로(refs) 함께 준다 — 알아볼 수 없어 뺀 미리보기는 넣지 않는다', () => {
  const fresh = signFileUrl(stored(THEIRS), 'b.png');
  const known = signedHoursAgo(stored(DOC), 5, 'd.pdf');
  const r = parseAttachments(
    [
      { kind: 'image', fileUrl: stored(MINE), thumbnailUrl: stored(MINE_THUMB) },
      { kind: 'image', fileUrl: fresh, thumbnailUrl: signedHoursAgo(stored(THEIRS_THUMB), 5) }, // 모르는 만료 링크 → 미리보기 없이
      { kind: 'file', fileUrl: known },
    ],
    [stored(DOC)],
  );
  assert.deepEqual(r.refs, [stored(MINE), stored(MINE_THUMB), fresh, known]);
  assert.deepEqual(
    r.value.map((a) => [a.fileUrl, a.thumbnailUrl]),
    [
      [stored(MINE), stored(MINE_THUMB)],
      [stored(THEIRS), null],
      [stored(DOC), null],
    ],
  );
  // '.'·'..' 같은 이름은 저장 경로로 보지 않는다(예전엔 모양만 맞으면 받았다).
  assert.equal(parseAttachments([{ fileUrl: '/uploads/..' }]).error, TODO_ATTACHMENT_LINK_ERROR);
  // parseTodoCreate도 같은 refs를 attachmentRefs로 넘긴다.
  assert.deepEqual(parseTodoCreate({ title: 't', attachments: [{ fileUrl: stored(MINE) }] }, NOW).attachmentRefs, [stored(MINE)]);
  assert.deepEqual(parseTodoCreate({ title: 't' }, NOW).attachmentRefs, []);
});

test('새 할 일: 방금 올린 파일(업로드 응답의 저장 경로·미리보기)은 받고 방은 찾아보지 않는다', async () => {
  const lookups = fakeLookups();
  const result = await createTodo([{ kind: 'image', fileUrl: stored(MINE), thumbnailUrl: stored(MINE_THUMB) }], { lookups });
  assert.deepEqual(result.attachments.map((a) => [a.fileUrl, a.thumbnailUrl]), [[stored(MINE), stored(MINE_THUMB)]]);
  assert.deepEqual(lookups.calls.uploaders, [[MINE, MINE_THUMB]]);
  assert.deepEqual(lookups.calls.reachable, []);
});

test('감사의 공격: 알게 된 남의 파일 이름을 첨부로 실으면 거절 — 원본이든 미리보기 칸이든, 볼 수 있는 방에 있어도', async () => {
  const lookups = fakeLookups({ reachable: [stored(THEIRS), stored(THEIRS_THUMB)] });
  assert.deepEqual(await createTodo([{ kind: 'file', fileUrl: stored(THEIRS) }], { lookups }), {
    error: TODO_ATTACHMENT_LINK_ERROR,
  });
  assert.deepEqual(
    await createTodo([{ kind: 'image', fileUrl: stored(MINE), thumbnailUrl: stored(THEIRS_THUMB) }], { lookups }),
    { error: TODO_ATTACHMENT_LINK_ERROR },
  );
  // 미서명 저장 경로로 온 남의 파일은 방을 찾아보지도 않는다(지어낸 이름으로 표를 훑게 만들지 못하게).
  assert.deepEqual(lookups.calls.reachable, []);
});

test('남에게 받은(아직 살아 있는) 서명 링크 — 지금 들어가 있는 방에서 볼 수 있는 파일이면 받고, 아니면 거절', async () => {
  const link = signFileUrl(stored(THEIRS), 'b.png');
  assert.deepEqual(await createTodo([{ kind: 'image', fileUrl: link }]), { error: TODO_ATTACHMENT_LINK_ERROR });
  const lookups = fakeLookups({ reachable: [stored(THEIRS)] });
  const ok = await createTodo([{ kind: 'image', fileUrl: link }], { lookups });
  assert.deepEqual(ok.attachments.map((a) => a.fileUrl), [stored(THEIRS)]);
  assert.deepEqual(lookups.calls.reachable, [{ userId: ME, paths: [stored(THEIRS)] }]);
});

test('"할 일로 등록": 출처 메시지에 지금 붙어 있는 남의 파일은 링크가 만료됐어도 조회 없이 받는다 — 다른 파일은 그대로 거절', async () => {
  const message = { fileUrl: null, thumbnailUrl: null, fileDeletedAt: null };
  const rows = [{ fileUrl: stored(THEIRS), thumbnailUrl: stored(THEIRS_THUMB), deletedAt: null }];
  const sourcePaths = sourceFilePaths({ message, attachments: rows });
  const lookups = fakeLookups();
  const fromMessage = [
    {
      kind: 'image',
      fileUrl: signedHoursAgo(stored(THEIRS), 26, 'b.png'),
      thumbnailUrl: signedHoursAgo(stored(THEIRS_THUMB), 26),
    },
  ];
  const result = await createTodo(fromMessage, { sourcePaths, lookups });
  assert.deepEqual(result.attachments.map((a) => [a.fileUrl, a.thumbnailUrl]), [[stored(THEIRS), stored(THEIRS_THUMB)]]);
  assert.deepEqual(lookups.calls, { uploaders: [], reachable: [] });
  // 그 메시지에 없는 남의 파일(이름만 알아낸 것)을 같이 실으면 거절.
  assert.deepEqual(await createTodo([...fromMessage, { kind: 'file', fileUrl: stored(DOC) }], { sourcePaths }), {
    error: TODO_ATTACHMENT_LINK_ERROR,
  });
});

test('고치기: 이 할 일에 있던 첨부(누가 올렸든, 만료된 링크로)는 그대로 — 새로 붙인 것은 내 파일만', async () => {
  const storedRows = [{ fileUrl: stored(THEIRS), thumbnailUrl: stored(THEIRS_THUMB) }];
  const kept = {
    kind: 'image',
    fileUrl: signedHoursAgo(stored(THEIRS), 3, 'b.png'),
    thumbnailUrl: signedHoursAgo(stored(THEIRS_THUMB), 3),
  };
  const lookups = fakeLookups();
  const ok = await updateAttachments(storedRows, [kept, { kind: 'file', fileUrl: stored(MINE) }], lookups);
  assert.deepEqual(
    ok.attachments.map((a) => [a.fileUrl, a.thumbnailUrl]),
    [
      [stored(THEIRS), stored(THEIRS_THUMB)],
      [stored(MINE), null],
    ],
  );
  // 올린 사람은 새로 붙인 내 파일만 찾아본다.
  assert.deepEqual(lookups.calls.uploaders, [[MINE]]);
  assert.deepEqual(
    await updateAttachments(storedRows, [kept, { kind: 'file', fileUrl: stored(DOC) }]),
    { error: TODO_ATTACHMENT_LINK_ERROR },
  );
});

test('todos.js 연결: 만들기·고치기 모두 저장 전에 checkFileRefs를 거치고, 원래 있던 파일로 출처 글·이 할 일의 첨부를 넘긴다', () => {
  const source = fs.readFileSync(new URL('../src/todos.js', import.meta.url), 'utf8');
  const route = (start) => source.slice(source.indexOf(start), source.indexOf('\n  });\n', source.indexOf(start)));

  const create = route("router.post('/rooms/:roomId/todos'");
  assert.match(
    create,
    /await checkFileRefs\(input\.attachmentRefs, \{\s*senderId: me,\s*existing: source\.filePaths,\s*error: TODO_ATTACHMENT_LINK_ERROR,\s*\}\);\s*if \(!files\.ok\) return res\.status\(400\)/,
  );
  // 확인은 실제로 저장하기(insertTodo) 전에.
  assert.ok(create.indexOf('checkFileRefs(') < create.indexOf('insertTodo('));

  const update = route("router.patch('/todos/:id'");
  assert.match(
    update,
    /const r = parseAttachments\(fields\.attachments, existing\);[\s\S]*await checkFileRefs\(r\.refs, \{ senderId: me, existing, error: TODO_ATTACHMENT_LINK_ERROR \}\);\s*if \(!files\.ok\) return res\.status\(400\)[^\n]*\n\s*attachments = r\.value;/,
  );
  assert.ok(update.indexOf('checkFileRefs(') < update.indexOf('updateTodo('));
});

test('todos.js 연결: "할 일로 등록"의 출처 글은 1:1 "기록 지우고 나가기" 이전 글이면 받지 않는다(메시지는 그 글, 댓글은 부모 메시지 시각)', () => {
  const source = fs.readFileSync(new URL('../src/todos.js', import.meta.url), 'utf8');
  const start = source.indexOf('async function loadTodoSource(');
  const fn = source.slice(start, source.indexOf('\n  }\n', start));
  assert.match(fn, /const floor = room\.type === 'dm' \? await getDmHistoryFloor\(room\.id, userId\) : null;/);
  assert.match(fn, /const parent = await findMessageById\(comment\.messageId\);\s*if \(!parent \|\| parent\.createdAt < floor\)/);
  assert.match(fn, /\(floor && message\.createdAt < floor\)/);
  assert.match(source, /await loadTodoSource\(room, req\.body, me\)/);
});
