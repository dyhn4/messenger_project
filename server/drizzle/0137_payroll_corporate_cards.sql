CREATE TABLE "card_feed_keys" (
	"scope_key" text PRIMARY KEY NOT NULL,
	"token_hash" text NOT NULL,
	"token_hint" text NOT NULL,
	"team_id" uuid,
	"created_by_name" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"last_used_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "card_transactions" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"scope_key" text NOT NULL,
	"card_id" uuid NOT NULL,
	"used_at" timestamp with time zone NOT NULL,
	"used_on" date NOT NULL,
	"merchant" text NOT NULL,
	"merchant_biz_no" text,
	"amount" integer NOT NULL,
	"approval_no" text,
	"source" text NOT NULL,
	"dedupe_key" text NOT NULL,
	"user_id" uuid,
	"memo" text,
	"category" text,
	"receipts" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"receipt_scan" jsonb,
	"expense_doc_id" uuid,
	"excluded_at" timestamp with time zone,
	"excluded_reason" text,
	"excluded_by_name" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "corporate_cards" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"scope_key" text NOT NULL,
	"team_id" uuid,
	"name" text NOT NULL,
	"issuer" text DEFAULT '기타' NOT NULL,
	"last4" text NOT NULL,
	"holder_ids" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"monthly_limit" bigint,
	"memo" text,
	"enabled" boolean DEFAULT true NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "payroll_runs" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"scope_key" text NOT NULL,
	"team_id" uuid,
	"title" text NOT NULL,
	"pay_month" text NOT NULL,
	"pay_date" date NOT NULL,
	"note" text,
	"status" text DEFAULT 'draft' NOT NULL,
	"created_by" uuid,
	"created_by_name" text NOT NULL,
	"published_at" timestamp with time zone,
	"published_by_name" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "payroll_settings" (
	"scope_key" text PRIMARY KEY NOT NULL,
	"staff_ids" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"item_template" jsonb,
	"insurance" jsonb,
	"employee_nos" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"company_name" text,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "payslips" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"run_id" uuid NOT NULL,
	"scope_key" text NOT NULL,
	"user_id" uuid NOT NULL,
	"user_name" text NOT NULL,
	"employee_no" text,
	"department" text,
	"position" text,
	"data" text NOT NULL,
	"revision" integer DEFAULT 1 NOT NULL,
	"history" text,
	"corrected_at" timestamp with time zone,
	"viewed_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "receipt_scans" (
	"file_name" text PRIMARY KEY NOT NULL,
	"user_id" uuid,
	"engine" text NOT NULL,
	"result" jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "card_feed_keys" ADD CONSTRAINT "card_feed_keys_team_id_teams_id_fk" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "card_transactions" ADD CONSTRAINT "card_transactions_card_id_corporate_cards_id_fk" FOREIGN KEY ("card_id") REFERENCES "public"."corporate_cards"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "card_transactions" ADD CONSTRAINT "card_transactions_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "card_transactions" ADD CONSTRAINT "card_transactions_expense_doc_id_approval_documents_id_fk" FOREIGN KEY ("expense_doc_id") REFERENCES "public"."approval_documents"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "corporate_cards" ADD CONSTRAINT "corporate_cards_team_id_teams_id_fk" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "payroll_runs" ADD CONSTRAINT "payroll_runs_team_id_teams_id_fk" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "payroll_runs" ADD CONSTRAINT "payroll_runs_created_by_users_id_fk" FOREIGN KEY ("created_by") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "payslips" ADD CONSTRAINT "payslips_run_id_payroll_runs_id_fk" FOREIGN KEY ("run_id") REFERENCES "public"."payroll_runs"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "payslips" ADD CONSTRAINT "payslips_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "receipt_scans" ADD CONSTRAINT "receipt_scans_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "card_transactions_card_dedupe_uq" ON "card_transactions" USING btree ("card_id","dedupe_key");--> statement-breakpoint
CREATE INDEX "card_transactions_scope_used_idx" ON "card_transactions" USING btree ("scope_key","used_on");--> statement-breakpoint
CREATE INDEX "card_transactions_user_idx" ON "card_transactions" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "card_transactions_expense_idx" ON "card_transactions" USING btree ("expense_doc_id");--> statement-breakpoint
CREATE INDEX "corporate_cards_scope_idx" ON "corporate_cards" USING btree ("scope_key");--> statement-breakpoint
CREATE INDEX "payroll_runs_scope_month_idx" ON "payroll_runs" USING btree ("scope_key","pay_month");--> statement-breakpoint
CREATE UNIQUE INDEX "payslips_run_user_uq" ON "payslips" USING btree ("run_id","user_id");--> statement-breakpoint
CREATE INDEX "payslips_user_idx" ON "payslips" USING btree ("user_id","scope_key");