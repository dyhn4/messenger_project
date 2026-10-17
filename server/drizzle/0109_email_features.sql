CREATE TABLE "email_codes" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"purpose" text NOT NULL,
	"user_id" uuid,
	"email_lookup" text NOT NULL,
	"email_enc" text,
	"code_hash" text NOT NULL,
	"attempts" integer DEFAULT 0 NOT NULL,
	"expires_at" timestamp with time zone NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "notification_settings" ADD COLUMN "email_digest" boolean DEFAULT true NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "smtp_enabled" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "smtp_host" text;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "smtp_port" integer;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "smtp_security" text DEFAULT 'starttls' NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "smtp_username" text;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "smtp_password" text;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "smtp_from_address" text;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "smtp_from_name" text;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "smtp_tested_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "mention_digest_enabled" boolean DEFAULT true NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "mention_digest_days" integer DEFAULT 3 NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "mention_digest_preview" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "email_verified_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "last_seen_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "mention_digest_sent_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "email_codes" ADD CONSTRAINT "email_codes_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "email_codes_purpose_lookup_idx" ON "email_codes" USING btree ("purpose","email_lookup");