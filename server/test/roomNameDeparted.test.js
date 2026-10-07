// 상대가 빠진 1:1 대화의 이름(notificationRules.js roomNameForViewer) 단위 테스트 — `node --test test/*.test.js`(DB 없이 돈다).
// 팀에서 제외되면 그 팀의 1:1 대화에서도 빠지고(db/queries/rooms.js removeMemberFromRoom) 남은 쪽에는 빠진 사람 이름만
// 남는다 — 방 목록(클라이언트 Room.displayName, rooms.js roomDisplayName)처럼 검색 패널도 "OOO (나갔음)"으로 보여야 한다.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { roomNameForViewer } from '../src/notificationRules.js';
import { matchRoomsByName, roomSearchDisplayName } from '../src/roomSearchRules.js';

const ME = 'me';
const meOnly = [{ id: ME, name: '나' }];

test('roomNameForViewer: 상대가 빠진 1:1 대화는 남겨 둔 이름 + (나갔음), 남은 이름이 없으면 (알 수 없음)', () => {
  const departed = { id: 'd1', type: 'dm', name: null, isSelf: false, isSecret: false, secretDepartedMemberName: '김철수' };
  assert.equal(roomNameForViewer(departed, meOnly, ME), '김철수 (나갔음)');
  assert.equal(roomNameForViewer({ ...departed, isSecret: true }, meOnly, ME), '김철수 (나갔음)');
  assert.equal(roomNameForViewer({ ...departed, secretDepartedMemberName: null }, meOnly, ME), '(알 수 없음)');
  // 상대가 아직 멤버면(다시 들어와 표시가 지워지기 전이라도) 지금 멤버의 이름이 먼저다.
  assert.equal(roomNameForViewer(departed, [...meOnly, { id: 'u2', name: '김철수2' }], ME), '김철수2');
});

test('검색 패널: 상대가 빠진 1:1 대화도 방 목록과 같은 이름으로 보이고 그 사람 이름으로 찾힌다', () => {
  const departed = { id: 'd1', type: 'dm', name: null, isSelf: false, isSecret: false, secretDepartedMemberName: '김철수' };
  assert.equal(roomSearchDisplayName(departed, null, meOnly, ME), '김철수 (나갔음)');
  const rows = [{ room: departed, customName: null, teamName: '팀A' }];
  const matched = matchRoomsByName(rows, new Map([['d1', meOnly]]), '철수', ME);
  assert.deepEqual(matched.map((r) => r.name), ['김철수 (나갔음)']);
});
