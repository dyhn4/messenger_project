import { JSONFilePreset } from 'lowdb/node';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const dbPath = path.join(__dirname, '..', 'db.json');

const defaultData = { users: [], rooms: [], messages: [] };

// JSON 파일 기반 저장소입니다. 인원이 적은 개인용 메신저라 이걸로 충분하고,
// 나중에 메시지 양이 많아지면 SQLite/Postgres로 옮기면 됩니다.
export const db = await JSONFilePreset(dbPath, defaultData);

export const GENERAL_ROOM_ID = 'general';

// 룸(토픽/단톡/개인톡) 개념을 도입하면서, 예전 버전에서 만들어진 db.json
// (룸 없이 메시지가 플랫하게 저장된 상태)을 한 번 마이그레이션합니다.
// 멱등이라 서버를 여러 번 재시작해도 안전합니다.
async function migrate() {
  let changed = false;

  // 예전 db.json에는 rooms 필드 자체가 없을 수 있습니다 (lowdb는 defaultData를
  // 파일이 아예 없을 때만 쓰고, 있으면 파일 내용을 그대로 로드하기 때문).
  if (!db.data.rooms) {
    db.data.rooms = [];
    changed = true;
  }
  if (!db.data.messages) {
    db.data.messages = [];
    changed = true;
  }
  if (!db.data.users) {
    db.data.users = [];
    changed = true;
  }

  if (!db.data.rooms.some((r) => r.id === GENERAL_ROOM_ID)) {
    db.data.rooms.push({
      id: GENERAL_ROOM_ID,
      type: 'topic',
      name: '일반',
      description: '전체 공지 및 자유 대화',
      memberIds: db.data.users.map((u) => u.id),
      createdBy: 'system',
      createdAt: Date.now(),
    });
    changed = true;
  }

  for (const m of db.data.messages) {
    if (!m.roomId) {
      m.roomId = GENERAL_ROOM_ID;
      changed = true;
    }
  }

  for (const r of db.data.rooms) {
    if (!r.lastRead) {
      r.lastRead = {};
      changed = true;
    }
  }

  if (changed) await db.write();
}

await migrate();
