// 팀 공유 드라이브 규칙 — 이름 검사·겹침(대소문자 무시)·겹치지 않는 이름, 경로·휴지통, 폴더 옮기기(자기 아래 금지·깊이), 권한.
// `node --test test/driveRules.test.js`(DB 없이).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  DRIVE_DEPTH_MAX,
  breadcrumb,
  canRemoveDriveItem,
  checkFolderMove,
  descendantIds,
  drivePermissions,
  findNameClash,
  isInTrash,
  parseDriveName,
  parseVersionNote,
  sortEntries,
  subtreeDepthOf,
  uniqueName,
  versionedName,
} from '../src/driveRules.js';

const map = (rows) => new Map(rows.map((f) => [f.id, { parentId: null, deletedAt: null, ...f }]));

test('이름 — 다듬기, 못 쓰는 글자, 길이, 겹침은 대소문자 무시', () => {
  assert.deepEqual(parseDriveName('  분기   보고  '), { name: '분기 보고' });
  assert.match(parseDriveName('').error, /입력/);
  assert.match(parseDriveName('a/b').error, /쓸 수 없습니다/);
  assert.match(parseDriveName('..').error, /쓸 수 없는/);
  assert.match(parseDriveName('x'.repeat(121)).error, /120자/);
  const siblings = [
    { id: '1', name: 'Report.PDF' },
    { id: '2', name: '자료' },
  ];
  assert.equal(findNameClash(siblings, 'report.pdf')?.id, '1');
  assert.equal(findNameClash(siblings, 'report.pdf', '1'), null, '자기 자신은 빼고');
  assert.equal(uniqueName('report.pdf', siblings), 'report (2).pdf');
  assert.equal(uniqueName('자료', [...siblings, { id: '3', name: '자료 (2)' }]), '자료 (3)');
  assert.equal(uniqueName('새 폴더', siblings), '새 폴더');
  assert.equal(versionedName('보고서.pdf', 3), '보고서 (판 3).pdf');
  assert.equal(versionedName('README', 2), 'README (판 2)');
  assert.deepEqual(sortEntries([{ name: '파일10' }, { name: '파일2' }, { name: 'a' }]).map((e) => e.name), ['파일2', '파일10', 'a'], '숫자는 숫자대로, 한글이 먼저(ko)');
  assert.deepEqual(parseVersionNote(' 표 고침 '), { note: '표 고침' });
  assert.match(parseVersionNote('x'.repeat(201)).error, /200자/);
});

test('경로·휴지통·옮기기 — 자기 아래로 못 옮기고 깊이 제한', () => {
  const folders = map([
    { id: 'a', name: '부서' },
    { id: 'b', name: '기획', parentId: 'a' },
    { id: 'c', name: '2026', parentId: 'b' },
    { id: 'd', name: '보관', deletedAt: new Date() },
    { id: 'e', name: '안', parentId: 'd' },
  ]);
  assert.deepEqual(breadcrumb(folders, 'c').map((p) => p.name), ['부서', '기획', '2026']);
  assert.deepEqual(breadcrumb(folders, null), []);
  assert.equal(isInTrash(folders, 'e'), true, '위 폴더가 휴지통이면 함께');
  assert.equal(isInTrash(folders, 'c'), false);
  assert.match(checkFolderMove(folders, 'a', 'c', subtreeDepthOf(folders, 'a')).error, /아래 폴더/);
  assert.match(checkFolderMove(folders, 'a', 'a').error, /자기 안/);
  assert.deepEqual(checkFolderMove(folders, 'c', null), { ok: true });
  assert.equal(subtreeDepthOf(folders, 'a'), 3);
  assert.deepEqual(descendantIds(folders, 'a').sort(), ['a', 'b', 'c']);
  // 깊이 — 맨 위에서 DRIVE_DEPTH_MAX 단계 사슬 아래로 2단계짜리를 옮기면 넘친다.
  const deep = map(Array.from({ length: DRIVE_DEPTH_MAX - 1 }, (_, i) => ({ id: `f${i}`, name: `f${i}`, parentId: i === 0 ? null : `f${i - 1}` })));
  deep.set('x', { id: 'x', name: 'x', parentId: null, deletedAt: null });
  deep.set('y', { id: 'y', name: 'y', parentId: 'x', deletedAt: null });
  assert.match(checkFolderMove(deep, 'x', `f${DRIVE_DEPTH_MAX - 2}`, subtreeDepthOf(deep, 'x')).error, /단계/);
  assert.deepEqual(checkFolderMove(deep, 'y', `f${DRIVE_DEPTH_MAX - 2}`, 1), { ok: true });
});

test('권한 — 준회원은 보기만, 지우기는 만든 사람이나 관리자', () => {
  const member = drivePermissions({ role: 'member' });
  const guest = drivePermissions({ role: 'guest' });
  const owner = drivePermissions({ role: 'member', isOwner: true });
  assert.deepEqual(member, { canWrite: true, isManager: false });
  assert.equal(guest.canWrite, false);
  assert.equal(owner.isManager, true);
  assert.equal(canRemoveDriveItem({ createdBy: 'me' }, 'me', member), true);
  assert.equal(canRemoveDriveItem({ createdBy: 'other' }, 'me', member), false);
  assert.equal(canRemoveDriveItem({ createdBy: 'other' }, 'me', owner), true);
  assert.equal(canRemoveDriveItem({ createdBy: 'me' }, 'me', guest), false);
});
