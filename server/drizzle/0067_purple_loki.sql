ALTER TABLE "projects" ADD COLUMN "template_id" uuid;--> statement-breakpoint
ALTER TABLE "projects" ADD COLUMN "note_edit_permission" text DEFAULT 'all' NOT NULL;--> statement-breakpoint
ALTER TABLE "projects" ADD COLUMN "note_delete_permission" text DEFAULT 'all' NOT NULL;--> statement-breakpoint
ALTER TABLE "projects" ADD CONSTRAINT "projects_template_id_project_templates_id_fk" FOREIGN KEY ("template_id") REFERENCES "public"."project_templates"("id") ON DELETE set null ON UPDATE no action;