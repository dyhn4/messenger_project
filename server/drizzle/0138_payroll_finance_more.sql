CREATE TABLE "finance_settings" (
	"scope_key" text PRIMARY KEY NOT NULL,
	"team_id" uuid,
	"account_map" jsonb,
	"voucher_format" text DEFAULT 'generic' NOT NULL,
	"receipt_retention_years" integer DEFAULT 5 NOT NULL,
	"receipt_filing" text DEFAULT 'corporate' NOT NULL,
	"receipt_purge" boolean DEFAULT false NOT NULL,
	"codef_card_connected_id" text,
	"codef_hometax_connected_id" text,
	"codef_auto_sync" boolean DEFAULT false NOT NULL,
	"codef_last_sync_at" timestamp with time zone,
	"codef_last_result" jsonb,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "payroll_insurance_reports" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"scope_key" text NOT NULL,
	"user_id" uuid,
	"user_name" text NOT NULL,
	"kind" text NOT NULL,
	"event_date" date NOT NULL,
	"reason_code" text,
	"data" text,
	"filed_at" timestamp with time zone,
	"filed_by_name" text,
	"created_by_name" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "receipt_purges" (
	"file_name" text PRIMARY KEY NOT NULL,
	"scope_key" text NOT NULL,
	"used_on" date,
	"keep_until" date,
	"purged_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "tax_documents" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"scope_key" text NOT NULL,
	"kind" text NOT NULL,
	"direction" text DEFAULT 'purchase' NOT NULL,
	"issued_on" date NOT NULL,
	"approval_no" text,
	"supplier_name" text,
	"supplier_biz_no" text,
	"buyer_name" text,
	"buyer_biz_no" text,
	"supply_amount" bigint,
	"tax_amount" bigint,
	"total_amount" bigint NOT NULL,
	"item_name" text,
	"category" text,
	"memo" text,
	"source" text NOT NULL,
	"dedupe_key" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "corporate_cards" ADD COLUMN "codef_organization" text;--> statement-breakpoint
ALTER TABLE "payroll_settings" ADD COLUMN "tax_profiles" jsonb DEFAULT '{}'::jsonb NOT NULL;--> statement-breakpoint
ALTER TABLE "payroll_settings" ADD COLUMN "bank_accounts" text;--> statement-breakpoint
ALTER TABLE "payroll_settings" ADD COLUMN "require_reauth" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "finance_settings" ADD CONSTRAINT "finance_settings_team_id_teams_id_fk" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "payroll_insurance_reports" ADD CONSTRAINT "payroll_insurance_reports_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "payroll_insurance_reports_scope_idx" ON "payroll_insurance_reports" USING btree ("scope_key","event_date");--> statement-breakpoint
CREATE UNIQUE INDEX "tax_documents_scope_dedupe_uq" ON "tax_documents" USING btree ("scope_key","dedupe_key");--> statement-breakpoint
CREATE INDEX "tax_documents_scope_issued_idx" ON "tax_documents" USING btree ("scope_key","issued_on");