ALTER TABLE "server_settings" ALTER COLUMN "team_creation" SET DEFAULT 'member';--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "org_scope" text DEFAULT 'team' NOT NULL;--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "role" text DEFAULT 'guest' NOT NULL;--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "department" text;--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "position" text;--> statement-breakpoint
-- 등급을 팀 단위(team_members.role)에서 계정 단위(users.role)로 올린다.
-- 한 사람이 팀마다 다른 등급일 수 있었으므로 "가진 것 중 가장 높은 등급"을 취한다
-- (owner/admin -> 관리자, member -> 정회원, guest만 있으면 준회원).
UPDATE "users" u SET "role" = COALESCE((
  SELECT CASE
    WHEN bool_or(tm."role" IN ('owner', 'admin')) THEN 'admin'
    WHEN bool_or(tm."role" = 'member') THEN 'member'
    ELSE 'guest'
  END
  FROM "team_members" tm WHERE tm."user_id" = u."id"
), 'guest');--> statement-breakpoint
-- 부서/직책을 계정 단위로 쓰는 설정으로 바꿀 수도 있으므로, 지금 팀에 들어있는 값을
-- 계정 쪽에도 한 번 복사해둔다(여러 팀에 값이 있으면 가장 먼저 들어간 팀 것을 쓴다).
UPDATE "users" u SET "department" = t."department", "position" = t."position"
FROM (
  SELECT DISTINCT ON ("user_id") "user_id", "department", "position"
  FROM "team_members"
  WHERE "department" IS NOT NULL OR "position" IS NOT NULL
  ORDER BY "user_id", "joined_at" ASC
) t WHERE t."user_id" = u."id";--> statement-breakpoint
-- team_members.role은 이제 소유자 여부만 나타낸다 — owner가 아닌 값은 전부 member로.
UPDATE "team_members" SET "role" = 'member' WHERE "role" <> 'owner';--> statement-breakpoint
-- 팀 생성 권한 설정값도 새 체계로 옮긴다('anyone' -> 정회원 이상, 'admin' -> 서버 운영자만).
UPDATE "server_settings" SET "team_creation" = CASE
  WHEN "team_creation" = 'admin' THEN 'serverAdmin'
  ELSE 'member'
END;
