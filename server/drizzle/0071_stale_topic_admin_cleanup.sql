-- Custom SQL migration file, put your code below! --
-- 0069는 토픽을 만든 사람을 토픽 관리자로 올렸는데, 그중 이미 그 팀을 떠났거나 탈퇴한 사람의 행도
-- 관리자로 남았다. 이 사람들은 토픽을 관리할 수 없으므로(access.js topicAccess — 팀 멤버여야 함)
-- 관리자 목록(adminIds·adminNames)에만 이름이 보이는 상태다 — 역할을 거둬서 목록을 실제와 맞춘다.
-- 이후 팀에서 빠지거나 탈퇴하는 경우는 teams.js·users.js가 그때그때 거둔다.
UPDATE "room_members" rm SET "role" = 'member'
FROM "rooms" r, "users" u
WHERE rm."room_id" = r."id"
  AND rm."user_id" = u."id"
  AND rm."role" = 'admin'
  AND (
    u."deleted_at" IS NOT NULL
    OR NOT EXISTS (
      SELECT 1 FROM "team_members" tm WHERE tm."team_id" = r."team_id" AND tm."user_id" = rm."user_id"
    )
  );
