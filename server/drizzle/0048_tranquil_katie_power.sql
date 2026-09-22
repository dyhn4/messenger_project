CREATE TABLE "task_priorities" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"project_id" uuid NOT NULL,
	"name" text NOT NULL,
	"color" text DEFAULT '#94A3B8' NOT NULL,
	"level" text DEFAULT 'normal' NOT NULL,
	"position" integer DEFAULT 0 NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "tasks" ADD COLUMN "priority_id" uuid;--> statement-breakpoint
ALTER TABLE "task_priorities" ADD CONSTRAINT "task_priorities_project_id_projects_id_fk" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "task_priorities_project_name_idx" ON "task_priorities" USING btree ("project_id","name");--> statement-breakpoint
ALTER TABLE "tasks" ADD CONSTRAINT "tasks_priority_id_task_priorities_id_fk" FOREIGN KEY ("priority_id") REFERENCES "public"."task_priorities"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
INSERT INTO "task_priorities" ("project_id", "name", "color", "level", "position")
SELECT p."id", v.name, v.color, v.level, v.pos
FROM "projects" p
CROSS JOIN (VALUES ('낮음', '#94A3B8', 'low', 0), ('보통', '#5B8DEF', 'normal', 1), ('높음', '#EF4444', 'high', 2)) AS v(name, color, level, pos)
ON CONFLICT DO NOTHING;
--> statement-breakpoint
UPDATE "tasks" t SET "priority_id" = pr."id"
FROM "task_priorities" pr
WHERE pr."project_id" = t."project_id" AND pr."level" = t."priority" AND t."priority_id" IS NULL;
