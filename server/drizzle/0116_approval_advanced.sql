CREATE TABLE "approval_counters" (
	"scope_key" text NOT NULL,
	"year" integer NOT NULL,
	"last_seq" integer DEFAULT 0 NOT NULL,
	CONSTRAINT "approval_counters_scope_key_year_pk" PRIMARY KEY("scope_key","year")
);
--> statement-breakpoint
CREATE TABLE "approval_delegations" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"scope_key" text NOT NULL,
	"user_id" uuid NOT NULL,
	"delegate_id" uuid NOT NULL,
	"start_date" text NOT NULL,
	"end_date" text NOT NULL,
	"reason" text,
	"created_by_id" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "approval_documents" ADD COLUMN "doc_number" text;--> statement-breakpoint
ALTER TABLE "approval_lines" ADD COLUMN "line" jsonb;--> statement-breakpoint
ALTER TABLE "approval_steps" ADD COLUMN "stage" integer;--> statement-breakpoint
ALTER TABLE "approval_steps" ADD COLUMN "role" text DEFAULT 'approve' NOT NULL;--> statement-breakpoint
ALTER TABLE "approval_steps" ADD COLUMN "acted_by_id" uuid;--> statement-breakpoint
ALTER TABLE "approval_steps" ADD COLUMN "acted_by_name" text;--> statement-breakpoint
ALTER TABLE "approval_steps" ADD COLUMN "signature_path" text;--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "signature_path" text;--> statement-breakpoint
ALTER TABLE "approval_delegations" ADD CONSTRAINT "approval_delegations_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "approval_delegations" ADD CONSTRAINT "approval_delegations_delegate_id_users_id_fk" FOREIGN KEY ("delegate_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "approval_delegations" ADD CONSTRAINT "approval_delegations_created_by_id_users_id_fk" FOREIGN KEY ("created_by_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "approval_delegations_user_idx" ON "approval_delegations" USING btree ("scope_key","user_id");--> statement-breakpoint
CREATE INDEX "approval_delegations_delegate_idx" ON "approval_delegations" USING btree ("delegate_id");--> statement-breakpoint
ALTER TABLE "approval_steps" ADD CONSTRAINT "approval_steps_acted_by_id_users_id_fk" FOREIGN KEY ("acted_by_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "approval_documents_number_idx" ON "approval_documents" USING btree ("scope_key","doc_number");