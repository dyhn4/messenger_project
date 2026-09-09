CREATE TABLE "teams" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"name" text NOT NULL,
	"icon_emoji" text,
	"icon_color" text,
	"created_by" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "team_members" (
	"team_id" uuid NOT NULL,
	"user_id" uuid NOT NULL,
	"role" text DEFAULT 'member' NOT NULL,
	"joined_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "team_members_team_id_user_id_pk" PRIMARY KEY("team_id","user_id")
);
--> statement-breakpoint
ALTER TABLE "teams" ADD CONSTRAINT "teams_created_by_users_id_fk" FOREIGN KEY ("created_by") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "team_members" ADD CONSTRAINT "team_members_team_id_teams_id_fk" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "team_members" ADD CONSTRAINT "team_members_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "team_members_user_id_idx" ON "team_members" USING btree ("user_id");--> statement-breakpoint

-- ── 기존 데이터 이전 ─────────────────────────────────────────────────
-- 지금까지는 팀 개념이 없는 단일 조직이었다. 이미 쓰던 서버라면(사용자나 방이 하나라도
-- 있으면) 기본 팀 'PST'를 하나 만들어서 기존 사용자·방을 전부 그 팀으로 옮긴다 — 그래야
-- 기존 대화가 그대로 이어진다. 소유자는 가장 먼저 가입한 계정(보통 서버를 깐 사람)으로 잡고,
-- 나머지는 정회원으로 넣는다. 완전히 새 설치(사용자도 방도 없음)라면 팀을 만들지 않는다 —
-- 첫 사용자가 직접 '팀 생성하기'로 만들면서 그 팀의 소유자가 된다.
INSERT INTO "teams" ("name", "icon_emoji", "icon_color", "created_by")
SELECT 'PST', '🏢', '#7E57C2', (SELECT "id" FROM "users" ORDER BY "created_at" ASC, "id" ASC LIMIT 1)
WHERE EXISTS (SELECT 1 FROM "users") OR EXISTS (SELECT 1 FROM "rooms");--> statement-breakpoint

INSERT INTO "team_members" ("team_id", "user_id", "role")
SELECT t."id", u."id", CASE WHEN u."id" = t."created_by" THEN 'owner' ELSE 'member' END
FROM "teams" t CROSS JOIN "users" u;--> statement-breakpoint

-- rooms.team_id는 NOT NULL이지만 기존 행이 있으므로, 널 허용으로 추가 → 채우기 → NOT NULL 순서로 간다.
ALTER TABLE "rooms" ADD COLUMN "team_id" uuid;--> statement-breakpoint
UPDATE "rooms" SET "team_id" = (SELECT "id" FROM "teams" ORDER BY "created_at" ASC LIMIT 1) WHERE "team_id" IS NULL;--> statement-breakpoint
ALTER TABLE "rooms" ALTER COLUMN "team_id" SET NOT NULL;--> statement-breakpoint

ALTER TABLE "rooms" ADD CONSTRAINT "rooms_team_id_teams_id_fk" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "rooms_team_id_idx" ON "rooms" USING btree ("team_id");--> statement-breakpoint
-- 같은 두 사람이 팀마다 각각 1:1 대화를 가질 수 있어야 하므로, dm_key 단독 unique를 버리고
-- (team_id, dm_key) 복합 unique로 바꾼다.
ALTER TABLE "rooms" DROP CONSTRAINT "rooms_dm_key_unique";--> statement-breakpoint
CREATE UNIQUE INDEX "rooms_team_id_dm_key_idx" ON "rooms" USING btree ("team_id","dm_key");
