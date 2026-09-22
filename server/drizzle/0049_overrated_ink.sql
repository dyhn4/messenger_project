CREATE TABLE "project_notification_policies" (
	"project_id" uuid PRIMARY KEY NOT NULL,
	"on_status" boolean DEFAULT true NOT NULL,
	"on_priority" boolean DEFAULT true NOT NULL,
	"on_assigned" boolean DEFAULT true NOT NULL,
	"on_referenced" boolean DEFAULT true NOT NULL,
	"on_due_date" boolean DEFAULT true NOT NULL,
	"on_task_type" boolean DEFAULT true NOT NULL,
	"on_custom_field" boolean DEFAULT true NOT NULL,
	"on_created" boolean DEFAULT true NOT NULL,
	"on_comment" boolean DEFAULT true NOT NULL,
	"on_due" boolean DEFAULT true NOT NULL
);
--> statement-breakpoint
ALTER TABLE "project_notification_policies" ADD CONSTRAINT "project_notification_policies_project_id_projects_id_fk" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "project_notification_settings" DROP COLUMN "on_assigned";--> statement-breakpoint
ALTER TABLE "project_notification_settings" DROP COLUMN "on_referenced";--> statement-breakpoint
ALTER TABLE "project_notification_settings" DROP COLUMN "on_comment";--> statement-breakpoint
ALTER TABLE "project_notification_settings" DROP COLUMN "on_status";--> statement-breakpoint
ALTER TABLE "project_notification_settings" DROP COLUMN "on_due";