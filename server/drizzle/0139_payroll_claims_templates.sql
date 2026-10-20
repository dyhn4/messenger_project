CREATE TABLE "payroll_year_end_claims" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"scope_key" text NOT NULL,
	"user_id" uuid NOT NULL,
	"year" integer NOT NULL,
	"data" text NOT NULL,
	"submitted_at" timestamp with time zone,
	"confirmed_at" timestamp with time zone,
	"confirmed_by_name" text,
	"updated_by_name" text NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "payroll_settings" ADD COLUMN "export_templates" jsonb DEFAULT '[]'::jsonb NOT NULL;--> statement-breakpoint
ALTER TABLE "payroll_year_end_claims" ADD CONSTRAINT "payroll_year_end_claims_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "payroll_year_end_claims_user_year_uq" ON "payroll_year_end_claims" USING btree ("scope_key","user_id","year");