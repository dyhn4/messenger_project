CREATE TABLE "approval_cc" (
	"document_id" uuid NOT NULL,
	"user_id" uuid NOT NULL,
	CONSTRAINT "approval_cc_document_id_user_id_pk" PRIMARY KEY("document_id","user_id")
);
--> statement-breakpoint
CREATE TABLE "approval_documents" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"scope_key" text NOT NULL,
	"team_id" uuid,
	"kind" text NOT NULL,
	"author_id" uuid,
	"author_name" text NOT NULL,
	"title" text NOT NULL,
	"body" text,
	"payload" jsonb NOT NULL,
	"attachments" jsonb,
	"status" text DEFAULT 'pending' NOT NULL,
	"current_step" integer,
	"decided_at" timestamp with time zone,
	"cancel_reason" text,
	"canceled_by_name" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "approval_lines" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"owner_id" uuid NOT NULL,
	"scope_key" text NOT NULL,
	"name" text NOT NULL,
	"approver_ids" jsonb NOT NULL,
	"cc_ids" jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "approval_steps" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"document_id" uuid NOT NULL,
	"step_order" integer NOT NULL,
	"approver_id" uuid,
	"approver_name" text NOT NULL,
	"status" text DEFAULT 'waiting' NOT NULL,
	"comment" text,
	"decided_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "attendance_records" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"scope_key" text NOT NULL,
	"team_id" uuid,
	"user_id" uuid NOT NULL,
	"work_date" text NOT NULL,
	"clock_in_at" timestamp with time zone,
	"clock_out_at" timestamp with time zone,
	"clock_in_lan" boolean,
	"clock_out_lan" boolean,
	"note" text,
	"corrected_doc_id" uuid,
	"original_clock_in_at" timestamp with time zone,
	"original_clock_out_at" timestamp with time zone,
	"corrected" boolean DEFAULT false NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "leave_adjustments" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"scope_key" text NOT NULL,
	"user_id" uuid NOT NULL,
	"period_start" text NOT NULL,
	"half_days" integer NOT NULL,
	"reason" text NOT NULL,
	"created_by_name" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "groupware_scope" text DEFAULT 'org' NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "work_start_minutes" integer DEFAULT 540 NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "work_end_minutes" integer DEFAULT 1080 NOT NULL;--> statement-breakpoint
ALTER TABLE "team_members" ADD COLUMN "hire_date" text;--> statement-breakpoint
ALTER TABLE "teams" ADD COLUMN "work_start_minutes" integer;--> statement-breakpoint
ALTER TABLE "teams" ADD COLUMN "work_end_minutes" integer;--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "hire_date" text;--> statement-breakpoint
ALTER TABLE "approval_cc" ADD CONSTRAINT "approval_cc_document_id_approval_documents_id_fk" FOREIGN KEY ("document_id") REFERENCES "public"."approval_documents"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "approval_cc" ADD CONSTRAINT "approval_cc_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "approval_documents" ADD CONSTRAINT "approval_documents_team_id_teams_id_fk" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "approval_documents" ADD CONSTRAINT "approval_documents_author_id_users_id_fk" FOREIGN KEY ("author_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "approval_lines" ADD CONSTRAINT "approval_lines_owner_id_users_id_fk" FOREIGN KEY ("owner_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "approval_steps" ADD CONSTRAINT "approval_steps_document_id_approval_documents_id_fk" FOREIGN KEY ("document_id") REFERENCES "public"."approval_documents"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "approval_steps" ADD CONSTRAINT "approval_steps_approver_id_users_id_fk" FOREIGN KEY ("approver_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "attendance_records" ADD CONSTRAINT "attendance_records_team_id_teams_id_fk" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "attendance_records" ADD CONSTRAINT "attendance_records_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "attendance_records" ADD CONSTRAINT "attendance_records_corrected_doc_id_approval_documents_id_fk" FOREIGN KEY ("corrected_doc_id") REFERENCES "public"."approval_documents"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "leave_adjustments" ADD CONSTRAINT "leave_adjustments_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "approval_cc_user_idx" ON "approval_cc" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "approval_documents_scope_author_idx" ON "approval_documents" USING btree ("scope_key","author_id","created_at");--> statement-breakpoint
CREATE INDEX "approval_documents_scope_status_idx" ON "approval_documents" USING btree ("scope_key","status");--> statement-breakpoint
CREATE INDEX "approval_lines_owner_idx" ON "approval_lines" USING btree ("owner_id","scope_key");--> statement-breakpoint
CREATE INDEX "approval_steps_document_idx" ON "approval_steps" USING btree ("document_id","step_order");--> statement-breakpoint
CREATE INDEX "approval_steps_approver_status_idx" ON "approval_steps" USING btree ("approver_id","status");--> statement-breakpoint
CREATE UNIQUE INDEX "attendance_records_scope_user_date_uq" ON "attendance_records" USING btree ("scope_key","user_id","work_date");--> statement-breakpoint
CREATE INDEX "attendance_records_scope_date_idx" ON "attendance_records" USING btree ("scope_key","work_date");--> statement-breakpoint
CREATE INDEX "leave_adjustments_user_idx" ON "leave_adjustments" USING btree ("scope_key","user_id","period_start");