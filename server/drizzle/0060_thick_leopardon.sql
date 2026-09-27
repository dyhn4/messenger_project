ALTER TABLE "project_notes" ADD COLUMN "seq" integer;--> statement-breakpoint
ALTER TABLE "projects" ADD COLUMN "next_note_seq" integer DEFAULT 1 NOT NULL;--> statement-breakpoint
-- 이미 있던 노트에 프로젝트별로 만든 순서대로 번호를 매기고, 다음 번호를 맞춘다.
UPDATE "project_notes" AS n SET "seq" = s.rn FROM (SELECT "id", row_number() OVER (PARTITION BY "project_id" ORDER BY "created_at", "id") AS rn FROM "project_notes") AS s WHERE n."id" = s."id" AND n."seq" IS NULL;--> statement-breakpoint
UPDATE "projects" AS p SET "next_note_seq" = COALESCE((SELECT max("seq") FROM "project_notes" WHERE "project_id" = p."id"), 0) + 1;
