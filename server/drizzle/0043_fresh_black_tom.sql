CREATE TABLE "task_fields" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"project_id" uuid NOT NULL,
	"name" text NOT NULL,
	"kind" text DEFAULT 'text' NOT NULL,
	"options" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"position" integer DEFAULT 0 NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "task_statuses" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"project_id" uuid NOT NULL,
	"name" text NOT NULL,
	"color" text DEFAULT '#94A3B8' NOT NULL,
	"category" text DEFAULT 'todo' NOT NULL,
	"position" integer DEFAULT 0 NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "tasks" ADD COLUMN "status_id" uuid;--> statement-breakpoint
ALTER TABLE "tasks" ADD COLUMN "custom_values" jsonb DEFAULT '{}'::jsonb NOT NULL;--> statement-breakpoint
ALTER TABLE "task_fields" ADD CONSTRAINT "task_fields_project_id_projects_id_fk" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "task_statuses" ADD CONSTRAINT "task_statuses_project_id_projects_id_fk" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "task_fields_project_name_idx" ON "task_fields" USING btree ("project_id","name");--> statement-breakpoint
CREATE UNIQUE INDEX "task_statuses_project_name_idx" ON "task_statuses" USING btree ("project_id","name");--> statement-breakpoint
ALTER TABLE "tasks" ADD CONSTRAINT "tasks_status_id_task_statuses_id_fk" FOREIGN KEY ("status_id") REFERENCES "public"."task_statuses"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
INSERT INTO "task_statuses" ("project_id", "name", "color", "category", "position")
SELECT p."id", v.name, v.color, v.category, v.pos
FROM "projects" p
CROSS JOIN (VALUES ('할 일', '#94A3B8', 'todo', 0), ('진행 중', '#F59E0B', 'doing', 1), ('완료', '#10B981', 'done', 2)) AS v(name, color, category, pos)
ON CONFLICT DO NOTHING;
--> statement-breakpoint
UPDATE "tasks" t SET "status_id" = s."id"
FROM "task_statuses" s
WHERE s."project_id" = t."project_id" AND s."category" = t."status" AND t."status_id" IS NULL;
