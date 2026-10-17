CREATE TABLE "attendance_reminders" (
	"scope_key" text NOT NULL,
	"user_id" uuid NOT NULL,
	"work_date" text NOT NULL,
	"kind" text NOT NULL,
	"sent_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "attendance_reminders_scope_key_user_id_work_date_kind_pk" PRIMARY KEY("scope_key","user_id","work_date","kind")
);
--> statement-breakpoint
CREATE TABLE "groupware_options" (
	"scope_key" text PRIMARY KEY NOT NULL,
	"leave_types" jsonb,
	"expense_categories" jsonb,
	"clock_in_reminder" boolean DEFAULT false NOT NULL,
	"clock_out_reminder" boolean DEFAULT false NOT NULL,
	"reminder_delay_minutes" integer DEFAULT 10 NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "leave_promotions" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"scope_key" text NOT NULL,
	"user_id" uuid NOT NULL,
	"period_start" text NOT NULL,
	"period_end" text NOT NULL,
	"stage" integer NOT NULL,
	"remaining_half_days" integer NOT NULL,
	"deadline" text NOT NULL,
	"message" text,
	"designated_dates" jsonb,
	"plan_dates" jsonb,
	"planned_at" timestamp with time zone,
	"sent_by_id" uuid,
	"sent_by_name" text,
	"sent_at" timestamp with time zone DEFAULT now() NOT NULL,
	"read_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "work_schedules" (
	"scope_key" text NOT NULL,
	"user_id" uuid NOT NULL,
	"mode" text NOT NULL,
	"start_minutes" integer,
	"end_minutes" integer,
	"core_start_minutes" integer,
	"core_end_minutes" integer,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "work_schedules_scope_key_user_id_pk" PRIMARY KEY("scope_key","user_id")
);
--> statement-breakpoint
ALTER TABLE "attendance_records" ADD COLUMN "clock_in_mode" text DEFAULT 'office' NOT NULL;--> statement-breakpoint
ALTER TABLE "attendance_reminders" ADD CONSTRAINT "attendance_reminders_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "leave_promotions" ADD CONSTRAINT "leave_promotions_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "leave_promotions" ADD CONSTRAINT "leave_promotions_sent_by_id_users_id_fk" FOREIGN KEY ("sent_by_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "work_schedules" ADD CONSTRAINT "work_schedules_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "leave_promotions_user_idx" ON "leave_promotions" USING btree ("scope_key","user_id","period_start");