CREATE TABLE "audit_logs" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"actor_id" uuid,
	"actor_name" text NOT NULL,
	"action" text NOT NULL,
	"team_id" uuid,
	"team_name" text,
	"target_type" text,
	"target_id" text,
	"target_label" text,
	"detail" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "server_settings" (
	"id" integer PRIMARY KEY NOT NULL,
	"team_creation" text DEFAULT 'anyone' NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "is_server_admin" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "suspended_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "audit_logs" ADD CONSTRAINT "audit_logs_actor_id_users_id_fk" FOREIGN KEY ("actor_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "audit_logs" ADD CONSTRAINT "audit_logs_team_id_teams_id_fk" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "audit_logs_created_at_idx" ON "audit_logs" USING btree ("created_at");--> statement-breakpoint
CREATE INDEX "audit_logs_actor_id_idx" ON "audit_logs" USING btree ("actor_id");--> statement-breakpoint
-- 서버 운영자 부트스트랩: 가장 먼저 가입한 계정(= 1단계에서 PST 팀 소유자가 된 그 계정)에
-- 서버 운영자 표시를 찍는다. 이후에는 운영자가 관리자 콘솔에서 다른 사람을 지정한다.
-- 계정이 하나도 없는 새 서버라면 아무것도 안 하고, 첫 가입자가 auth.js에서 운영자가 된다.
UPDATE "users" SET "is_server_admin" = true
WHERE "id" = (SELECT "id" FROM "users" WHERE "deleted_at" IS NULL ORDER BY "created_at" ASC LIMIT 1);
