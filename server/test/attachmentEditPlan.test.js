// 사진·파일 메시지 수정(첨부 삭제)과 "메시지를 공지로 등록" 규칙 단위 테스트 — `node --test test/*.test.js` (DB·서버 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { currentAttachmentsOf, planAttachmentEdit } from '../src/attachmentEditPlan.js';
import { announcementFieldsFromMessage } from '../src/announcementFromMessage.js';

const att = (id, extra = {}) => ({ id, kind: 'image', fileUrl: `/uploads/${id}.png`, fileName: `${id}.png`, ...extra });

test('currentAttachmentsOf: 첨부 행이 있으면 그걸, 없으면 파일 칸 하나를 메시지 id로', () => {
  const msg = { id: 'm1', type: 'image', fileUrl: '/uploads/a.png', fileName: 'a.png' };
  assert.deepEqual(currentAttachmentsOf(msg, []).map((a) => a.id), ['m1']);
  assert.deepEqual(currentAttachmentsOf(msg, [att('x1'), att('x2')]).map((a) => a.id), ['x1', 'x2']);
  assert.deepEqual(currentAttachmentsOf({ id: 'm2', type: 'text', fileUrl: null }, []), []);
  // 글 메시지에 파일 칸이 남아 있어도 첨부로 보지 않는다.
  assert.deepEqual(currentAttachmentsOf({ id: 'm3', type: 'text', fileUrl: '/uploads/z' }, []), []);
});

test('planAttachmentEdit: 일부만 지우면 남은 것과 지운 것을 나눈다', () => {
  const msg = { id: 'm1', type: 'image', fileUrl: '/uploads/x1.png' };
  const plan = planAttachmentEdit({ message: msg, rows: [att('x1'), att('x2'), att('x3')], removeIds: ['x1', 'x3'] });
  assert.equal(plan.ok, true);
  assert.deepEqual(plan.removed.map((a) => a.id), ['x1', 'x3']);
  assert.deepEqual(plan.remaining.map((a) => a.id), ['x2']);
  assert.equal(plan.hasRows, true);
});

test('planAttachmentEdit: 파일을 다 지워 사진만 남으면 nextType은 image, 파일이 남으면 file', () => {
  const msg = { id: 'm1', type: 'file', fileUrl: '/uploads/d1.txt' };
  const rows = [att('d1', { kind: 'file' }), att('d2', { kind: 'file' }), att('p1'), att('p2')];
  assert.equal(planAttachmentEdit({ message: msg, rows, removeIds: ['d1', 'd2'] }).nextType, 'image');
  assert.equal(planAttachmentEdit({ message: msg, rows, removeIds: ['d1'] }).nextType, 'file');
  assert.equal(planAttachmentEdit({ message: msg, rows, removeIds: ['d1', 'd2', 'p1', 'p2'] }).nextType, null);
});

test('planAttachmentEdit: 행 없는 예전 메시지는 메시지 id로 지운다', () => {
  const msg = { id: 'm1', type: 'file', fileUrl: '/uploads/a.pdf', fileName: 'a.pdf' };
  const plan = planAttachmentEdit({ message: msg, rows: [], removeIds: ['m1'] });
  assert.equal(plan.ok, true);
  assert.equal(plan.remaining.length, 0);
  assert.equal(plan.hasRows, false);
});

test('planAttachmentEdit: 없는 id·잘못된 모양은 거절, 안 보내면 그대로', () => {
  const msg = { id: 'm1', type: 'image', fileUrl: '/uploads/x1.png' };
  const rows = [att('x1'), att('x2')];
  assert.equal(planAttachmentEdit({ message: msg, rows, removeIds: ['nope'] }).ok, false);
  assert.equal(planAttachmentEdit({ message: msg, rows, removeIds: 'x1' }).ok, false);
  assert.equal(planAttachmentEdit({ message: msg, rows, removeIds: [1] }).ok, false);
  const none = planAttachmentEdit({ message: msg, rows, removeIds: undefined });
  assert.equal(none.ok, true);
  assert.equal(none.removed.length, 0);
  assert.equal(none.remaining.length, 2);
});

test('announcementFieldsFromMessage: 텍스트와 이미지만, 나머지는 거절', () => {
  const text = announcementFieldsFromMessage({ type: 'text', text: '  안녕  ' });
  assert.deepEqual(text, { ok: true, text: '안녕', textFormat: null, image: null });

  const image = announcementFieldsFromMessage({
    type: 'image',
    text: null,
    fileUrl: '/uploads/a.png',
    thumbnailUrl: '/uploads/a_t.png',
    fileName: 'a.png',
  });
  assert.equal(image.ok, true);
  assert.equal(image.text, '');
  assert.deepEqual(image.image, { url: '/uploads/a.png', thumbnailUrl: '/uploads/a_t.png', name: 'a.png' });

  for (const type of ['file', 'sticker', 'system', 'post', 'poll']) {
    assert.equal(announcementFieldsFromMessage({ type, text: 'x', fileUrl: '/uploads/a' }).ok, false, type);
  }
  assert.equal(announcementFieldsFromMessage({ type: 'text', text: '   ' }).ok, false);
  assert.equal(announcementFieldsFromMessage({ type: 'text', text: 'x', deletedAt: new Date() }).status, 404);
  assert.equal(announcementFieldsFromMessage({ type: 'text', text: 'x'.repeat(2001) }).ok, false);
  assert.equal(announcementFieldsFromMessage({ type: 'image', fileUrl: null }).ok, false);
});
