/**
 * 공지 읽음 확인의 **순수 규칙** — DB를 만지지 않아 `node --test`로 그대로 시험한다(test/announcementReaders.test.js).
 *
 * 읽음 기록은 공지마다 따로 두지 않고 방 멤버마다 "공지를 마지막으로 연 시각"(room_members.last_read_announcement_at — 공지
 * 목록·상세를 실제로 열었을 때만 오른다, socket.js announcement:read) 하나다. 그래서 그 시각이 공지가 올라온 시각 이후면 그 공지를
 * 읽은 것으로 본다(그 뒤에 목록·상세를 열었으면 그 공지가 맨 위에 보였다). 쓴 사람은 늘 읽은 쪽이다.
 */

/**
 * [announcement] `{ authorId, createdAt }`, [members] `[{ userId, name, lastReadAnnouncementAt }]`(방 멤버 — 탈퇴한 사람은 부른 쪽이
 * 뺀다) → `{ read: [{ userId, name, readAt }], unread: [{ userId, name }] }`. 읽은 쪽은 먼저 읽은 순, 안 읽은 쪽은 이름순.
 */
export function splitAnnouncementReaders({ announcement, members }) {
  const postedAt = new Date(announcement.createdAt).getTime();
  const read = [];
  const unread = [];
  for (const m of members) {
    const at = m.lastReadAnnouncementAt ? new Date(m.lastReadAnnouncementAt).getTime() : null;
    if (m.userId === announcement.authorId) {
      read.push({ userId: m.userId, name: m.name, readAt: postedAt });
    } else if (at !== null && at >= postedAt) {
      read.push({ userId: m.userId, name: m.name, readAt: at });
    } else {
      unread.push({ userId: m.userId, name: m.name });
    }
  }
  read.sort((a, b) => a.readAt - b.readAt);
  unread.sort((a, b) => a.name.localeCompare(b.name, 'ko'));
  return { read, unread };
}
