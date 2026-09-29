-- Custom SQL migration file, put your code below! --
-- 준회원은 토픽 관리자가 될 수 없다(rooms.js PUT /rooms/:id/admins). 0069는 토픽을 만든 사람을 등급과
-- 상관없이 토픽 관리자로 올렸으므로, 만든 뒤 준회원으로 내려간 사람의 관리자 역할을 거둔다(그 토픽은
-- 팀 관리자가 관리하면서 새로 지정할 수 있다 — 만든 사람이 나간 토픽과 같은 상태).
UPDATE "room_members" rm SET "role" = 'member' FROM "users" u WHERE rm."user_id" = u."id" AND rm."role" = 'admin' AND u."role" NOT IN ('member', 'admin');
