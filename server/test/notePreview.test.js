// 노트 목록 미리보기 테스트 — `node --test test/notePreview.test.js` (DB·서버 없이 돈다).
// 목록의 미리보기가 본문 앞 140자를 그대로 잘라 주면 첫머리 그림·파일 링크의 저장 경로(/uploads/<이름>)가 서명 없이 나갔다(S24).
// 미리보기는 링크·그림 주소를 걷어 낸 뒤에 자른다(projectNotifications.js notePreview) — 목록 질의(db/queries/projects.js
// listNotesInProjects)는 본문 앞부분(NOTE_PREVIEW_SOURCE_MAX자)만 읽어 이 함수에 넘긴다. 질의는 drizzle에 SQL을 받아 적는 가짜 pg
// 클라이언트로 돌린다(test/teamRemoval.test.js와 같은 방식 — 실제 DB에는 아무것도 묻지 않는다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { NOTE_PREVIEW_MAX, NOTE_PREVIEW_SOURCE_MAX, notePreview } from '../src/projectNotifications.js';

process.env.DATABASE_URL ??= 'postgres://test:test@127.0.0.1:9/unused';
const { db } = await import('../src/db/client.js');
const { listNotesInProjects } = await import('../src/db/queries/projects.js');

test('미리보기에서 그림·링크 주소는 지우고 이름·글자는 남긴다', () => {
  assert.equal(
    notePreview('![도면.png](/uploads/3f1c0d2e-1111-4222-8333-944445555666.png)\n회의 내용'),
    '![도면.png](#)\n회의 내용',
  );
  assert.equal(notePreview('[보고서.pdf](/files/AbC-_09) 참고'), '[보고서.pdf](#) 참고');
  assert.equal(notePreview('[문서](https://example.test/a?b=c) 외부'), '[문서](#) 외부');
  // 주소 칸이 아닌 괄호·공백이 든 것은 링크가 아니라 그대로(앱도 링크로 읽지 않고, 서버도 서명하지 않는 모양이다).
  assert.equal(notePreview('결과(초안) 정리'), '결과(초안) 정리');
  assert.equal(notePreview('[a](b c)'), '[a](b c)');
  assert.equal(notePreview(''), '');
  assert.equal(notePreview(null), '');
  assert.equal(notePreview(undefined), '');
});

test('읽어 온 앞부분이 주소 중간에서 끝나면 그 조각도 지운다', () => {
  assert.equal(notePreview('회의록 ![도면](/uploads/3f1c0d2e-11'), '회의록 ![도면]');
  assert.equal(notePreview('회의록 [첨부](/fi'), '회의록 [첨부]');
  assert.equal(notePreview('회의록 [첨부]('), '회의록 [첨부]');
  assert.equal(notePreview('회의록 [첨부]'), '회의록 [첨부]');
});

test('주소를 지운 뒤 140자(글자 단위)로 자른다 — 이모지 반쪽이 남지 않는다', () => {
  const long = `![그림](/uploads/${'a'.repeat(36)}.png)${'가'.repeat(300)}`;
  const preview = notePreview(long);
  assert.equal(Array.from(preview).length, NOTE_PREVIEW_MAX);
  assert.ok(preview.startsWith('![그림](#)가'));
  assert.ok(!preview.includes('/uploads/'));
  const emoji = '😀'.repeat(200);
  assert.equal(notePreview(emoji), '😀'.repeat(NOTE_PREVIEW_MAX));
  assert.equal(notePreview('짧은 글'), '짧은 글');
  assert.equal(notePreview('줄\r\n바꿈'), '줄\n바꿈');
});

test('본문을 어디서 잘라 읽어도 미리보기에 주소 조각이 남지 않는다', () => {
  // 주소에만 쓰는 글자(Z·Q·X·J·'/'·숫자)를 넣어, 잘린 조각이 하나라도 새면 걸리게 한다.
  const body = [
    '![도면](/uploads/ZQXJ0000-ZQXJ.png)',
    '회의 내용 정리',
    '[첨부 파일](/files/ZQXJtoken_-ZQXJ) 확인',
    '- 항목 [[긴급] 점검](/uploads/ZQXJ9.pdf)',
    '> 인용 ![사진](/uploads/ZQXJ1.jpg)',
    '끝',
  ].join('\n');
  for (let n = 0; n <= body.length; n++) {
    const preview = notePreview(body.slice(0, n));
    assert.doesNotMatch(preview, /[ZQXJ/0-9]/, `${n}자에서 자름: ${JSON.stringify(preview)}`);
  }
});

/** 가짜 pg 클라이언트 — drizzle이 보내는 SQL을 받아 적고 [rows]를 돌려준다(rowMode 'array'라 열 순서대로). */
function fakePg(rows = []) {
  const queries = [];
  db.$client.query = async (config, values = []) => {
    queries.push({ text: typeof config === 'string' ? config : config.text, values });
    return { rows, rowCount: rows.length };
  };
  return queries;
}

test('listNotesInProjects: 본문은 앞부분만 읽고, 미리보기는 주소를 걷어 낸 것만 내보낸다', async () => {
  const source = `![도면.png](/uploads/3f1c0d2e-1111-4222-8333-944445555666.png) ${'회의 '.repeat(400)}`.slice(0, NOTE_PREVIEW_SOURCE_MAX);
  const queries = fakePg([
    [
      'note-1', // id
      'project-1', // projectId
      '주간 회의', // title
      10, // seq
      source, // previewSource
      'u1', // createdBy
      'u2', // updatedBy
      '2026-10-01T00:00:00.000Z', // createdAt
      '2026-10-02T00:00:00.000Z', // updatedAt
      '마케팅', // projectName
      '#5B8DEF', // projectColor
      'MKT', // projectIdentifier
    ],
  ]);
  const notes = await listNotesInProjects(['project-1']);
  assert.equal(queries.length, 1);
  const [{ text, values }] = queries;
  // 본문 전체(최대 5만 자)가 아니라 앞부분만, 미리보기 길이(140자)가 아니라 주소를 걷어 낼 여유까지.
  assert.match(text, new RegExp(`left\\("project_notes"\\."body", ${NOTE_PREVIEW_SOURCE_MAX}\\)`));
  assert.doesNotMatch(text, /left\("project_notes"\."body", 140\)/);
  // 목록에는 본문 칸 자체를 싣지 않는다(본문은 상세에서 서명해서 내려준다).
  assert.doesNotMatch(text.replace(/left\("project_notes"\."body", \d+\)/, ''), /"project_notes"\."body"/);
  assert.deepEqual(values, ['project-1']);

  assert.equal(notes.length, 1);
  const [note] = notes;
  assert.equal(note.id, 'note-1');
  assert.equal(note.title, '주간 회의');
  assert.ok(!('previewSource' in note), '앞부분 원문은 결과에 남기지 않는다');
  assert.equal(note.preview, notePreview(source));
  assert.ok(note.preview.startsWith('![도면.png](#) 회의'));
  assert.ok(!note.preview.includes('/uploads/'));
  assert.ok(!note.preview.includes('3f1c'));
});

test('listNotesInProjects: 프로젝트가 없으면 DB에 묻지 않는다', async () => {
  const queries = fakePg();
  assert.deepEqual(await listNotesInProjects([]), []);
  assert.equal(queries.length, 0);
});
