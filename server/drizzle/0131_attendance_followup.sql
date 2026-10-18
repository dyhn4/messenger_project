CREATE TABLE "work_wages" (
	"scope_key" text NOT NULL,
	"user_id" uuid NOT NULL,
	"hourly_wage" integer NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "work_wages_scope_key_user_id_pk" PRIMARY KEY("scope_key","user_id")
);
--> statement-breakpoint
ALTER TABLE "leave_adjustments" ALTER COLUMN "half_days" SET DATA TYPE double precision;--> statement-breakpoint
ALTER TABLE "attendance_records" ADD COLUMN "breaks" jsonb DEFAULT '[]'::jsonb NOT NULL;--> statement-breakpoint
ALTER TABLE "attendance_records" ADD COLUMN "clock_in_location" jsonb;--> statement-breakpoint
ALTER TABLE "attendance_records" ADD COLUMN "clock_out_location" jsonb;--> statement-breakpoint
ALTER TABLE "groupware_options" ADD COLUMN "overtime_guard" text DEFAULT 'warn' NOT NULL;--> statement-breakpoint
ALTER TABLE "groupware_options" ADD COLUMN "leave_basis" text DEFAULT 'hire' NOT NULL;--> statement-breakpoint
ALTER TABLE "groupware_options" ADD COLUMN "fiscal_start_month" integer DEFAULT 1 NOT NULL;--> statement-breakpoint
ALTER TABLE "groupware_options" ADD COLUMN "carry_over_max_days" integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "groupware_options" ADD COLUMN "pay_rates" jsonb;--> statement-breakpoint
ALTER TABLE "groupware_options" ADD COLUMN "office_location" jsonb;--> statement-breakpoint
ALTER TABLE "groupware_options" ADD COLUMN "require_field_location" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "leave_adjustments" ADD COLUMN "kind" text DEFAULT 'manual' NOT NULL;--> statement-breakpoint
ALTER TABLE "work_schedules" ADD COLUMN "period_type" text;--> statement-breakpoint
ALTER TABLE "work_schedules" ADD COLUMN "period_start" text;--> statement-breakpoint
ALTER TABLE "work_schedules" ADD COLUMN "period_months" integer;--> statement-breakpoint
ALTER TABLE "work_wages" ADD CONSTRAINT "work_wages_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;