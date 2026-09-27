ALTER TABLE "projects" ALTER COLUMN "next_task_seq" SET DEFAULT 1001;--> statement-breakpoint
-- 업무 번호를 1001부터로 — 이미 1~999로 매겨진 업무는 1000을 더해 옮기고, 다음 번호도 맞춘다.
UPDATE "tasks" SET "seq" = "seq" + 1000 WHERE "seq" < 1000;--> statement-breakpoint
UPDATE "projects" SET "next_task_seq" = "next_task_seq" + 1000 WHERE "next_task_seq" < 1001;
