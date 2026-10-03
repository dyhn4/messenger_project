// 파일 삭제 규칙 단위 테스트 — `node --test test/*.test.js` (DB·서버 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { canDeleteFile, planFileDelete } from '../src/fileDeletePlan.js';
import { currentAttachmentsOf } from '../src/attachmentEditPlan.js';

const row = (id, extra = {}) => ({ id, kind: 'image', fileUrl: `/uploads/${id}.png`, fileName: `${id}.png`, deletedAt: null, ...extra });

test('canDeleteFile: 올린 본인 또는 팀 관리자(방 멤버)만', () => {
  const base = { senderId: 'u1', requesterId: 'u1', isRoomMember: true, isSecret: false, isModerator: false };
  assert.equal(canDeleteFile(base), true);
  assert.equal(canDeleteFile({ ...base, requesterId: 'u2' }), false);
  assert.equal(canDeleteFile({ ...base, requesterId: 'u2', isModerator: true }), true);
  // 방 멤버가 아니면 본인이든 관리자든 불가.
  assert.equal(canDeleteFile({ ...base, isRoomMember: false }), false);
  assert.equal(canDeleteFile({ ...base, requesterId: 'u2', isModerator: true, isRoomMember: false }), false);
  // 비밀 대화는 관리자 관리 대상이 아니지만 본인은 지울 수 있다.
  assert.equal(canDeleteFile({ ...base, requesterId: 'u2', isModerator: true, isSecret: true }), false);
  assert.equal(canDeleteFile({ ...base, isSecret: true }), true);
  // 보낸 사람이 없는(탈퇴·자동화) 메시지는 본인 판정이 안 된다.
  assert.equal(canDeleteFile({ ...base, senderId: null, requesterId: null }), false);
});

test('planFileDelete: 첨부 여럿 중 하나를 지우면 남은 첨부와 다음 종류를 계획한다', () => {
  const message = { id: 'm1', type: 'file' };
  const rows = [row('a', { kind: 'file' }), row('b'), row('c')];
  const plan = planFileDelete({ message, rows, attachmentId: 'a' });
  assert.equal(plan.ok, true);
  assert.equal(plan.hasRows, true);
  assert.deepEqual(plan.remaining.map((r) => r.id), ['b', 'c']);
  assert.equal(plan.allGone, false);
  assert.equal(plan.nextType, 'image'); // 파일을 다 지웠으니 사진 메시지로.
});

test('planFileDelete: 마지막 남은 첨부를 지우면 allGone, 이미 지운 첨부는 404', () => {
  const message = { id: 'm1', type: 'image' };
  const rows = [row('a', { deletedAt: new Date() }), row('b')];
  const plan = planFileDelete({ message, rows, attachmentId: 'b' });
  assert.equal(plan.ok, true);
  assert.equal(plan.allGone, true);
  const again = planFileDelete({ message, rows, attachmentId: 'a' });
  assert.equal(again.ok, false);
  assert.equal(again.status, 404);
  assert.equal(planFileDelete({ message, rows, attachmentId: 'zzz' }).status, 404);
  // 첨부 행이 있는 메시지에서 id 없이 부르면 400.
  assert.equal(planFileDelete({ message, rows, attachmentId: null }).status, 400);
});

test('planFileDelete: 첨부 행이 없는 옛 단일 파일 메시지', () => {
  const message = { id: 'm1', type: 'file', fileUrl: '/uploads/x.pdf', fileName: 'x.pdf' };
  const plan = planFileDelete({ message, rows: [], attachmentId: null });
  assert.equal(plan.ok, true);
  assert.equal(plan.hasRows, false);
  assert.equal(plan.allGone, true);
  assert.equal(plan.target.id, 'm1');
  assert.equal(planFileDelete({ message, rows: [], attachmentId: 'm1' }).ok, true);
  assert.equal(planFileDelete({ message, rows: [], attachmentId: 'other' }).status, 404);
  // 이미 지웠으면 404, 파일 없는 글/삭제된 메시지는 거절.
  assert.equal(planFileDelete({ message: { ...message, fileDeletedAt: new Date() }, rows: [], attachmentId: null }).status, 404);
  assert.equal(planFileDelete({ message: { id: 'm2', type: 'text' }, rows: [], attachmentId: null }).status, 400);
  assert.equal(planFileDelete({ message: { ...message, deletedAt: new Date() }, rows: [], attachmentId: null }).status, 404);
});

test('currentAttachmentsOf: 파일을 지운 메시지의 파일 칸은 첨부로 안 센다', () => {
  const msg = { id: 'm1', type: 'image', fileUrl: '/uploads/a.png', fileDeletedAt: new Date() };
  assert.deepEqual(currentAttachmentsOf(msg, []), []);
});
