CREATE TABLE "task_references" (
	"task_id" uuid NOT NULL,
	"user_id" uuid NOT NULL,
	CONSTRAINT "task_references_task_id_user_id_pk" PRIMARY KEY("task_id","user_id")
);
--> statement-breakpoint
CREATE TABLE "task_types" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"project_id" uuid NOT NULL,
	"name" text NOT NULL,
	"color" text DEFAULT '#607D8B' NOT NULL,
	"position" integer DEFAULT 0 NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "tasks" ADD COLUMN "type_id" uuid;--> statement-breakpoint
ALTER TABLE "task_references" ADD CONSTRAINT "task_references_task_id_tasks_id_fk" FOREIGN KEY ("task_id") REFERENCES "public"."tasks"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "task_references" ADD CONSTRAINT "task_references_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "task_types" ADD CONSTRAINT "task_types_project_id_projects_id_fk" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "task_references_user_idx" ON "task_references" USING btree ("user_id");--> statement-breakpoint
CREATE UNIQUE INDEX "task_types_project_name_idx" ON "task_types" USING btree ("project_id","name");--> statement-breakpoint
ALTER TABLE "tasks" ADD CONSTRAINT "tasks_type_id_task_types_id_fk" FOREIGN KEY ("type_id") REFERENCES "public"."task_types"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
INSERT INTO "task_types" ("project_id", "name", "color", "position")
SELECT p."id", v.name, v.color, v.pos
FROM "projects" p
CROSS JOIN (VALUES ('Bug', '#E53935', 0), ('Feature', '#1E88E5', 1), ('Improvement', '#43A047', 2), ('기타', '#78909C', 3)) AS v(name, color, pos)
ON CONFLICT DO NOTHING;
