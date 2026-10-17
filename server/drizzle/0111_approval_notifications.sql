CREATE TABLE "approval_notifications" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"document_id" uuid NOT NULL,
	"team_id" uuid,
	"kind" text NOT NULL,
	"title" text NOT NULL,
	"body" text NOT NULL,
	"actor_id" uuid,
	"actor_name" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"read_at" timestamp with time zone
);
--> statement-breakpoint
ALTER TABLE "approval_notifications" ADD CONSTRAINT "approval_notifications_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "approval_notifications" ADD CONSTRAINT "approval_notifications_document_id_approval_documents_id_fk" FOREIGN KEY ("document_id") REFERENCES "public"."approval_documents"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "approval_notifications" ADD CONSTRAINT "approval_notifications_team_id_teams_id_fk" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "approval_notifications" ADD CONSTRAINT "approval_notifications_actor_id_users_id_fk" FOREIGN KEY ("actor_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "approval_notifications_user_idx" ON "approval_notifications" USING btree ("user_id","created_at");--> statement-breakpoint
CREATE INDEX "approval_notifications_document_idx" ON "approval_notifications" USING btree ("document_id");