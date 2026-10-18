CREATE TABLE "local_mail_messages" (
	"uid" serial PRIMARY KEY NOT NULL,
	"account_id" uuid NOT NULL,
	"folder" text NOT NULL,
	"seen" boolean DEFAULT false NOT NULL,
	"flagged" boolean DEFAULT false NOT NULL,
	"answered" boolean DEFAULT false NOT NULL,
	"draft" boolean DEFAULT false NOT NULL,
	"subject" text,
	"from_name" text,
	"from_address" text,
	"to_list" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"cc_list" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"sent_at" timestamp with time zone,
	"received_at" timestamp with time zone DEFAULT now() NOT NULL,
	"trashed_at" timestamp with time zone,
	"size" integer DEFAULT 0 NOT NULL,
	"has_attachments" boolean DEFAULT false NOT NULL,
	"message_id" text,
	"search_text" text,
	"file_name" text NOT NULL
);
--> statement-breakpoint
CREATE TABLE "mail_contacts" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"address" text NOT NULL,
	"name" text,
	"use_count" integer DEFAULT 1 NOT NULL,
	"last_used_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "mail_rules" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"account_id" uuid NOT NULL,
	"user_id" uuid NOT NULL,
	"name" text NOT NULL,
	"enabled" boolean DEFAULT true NOT NULL,
	"position" integer DEFAULT 0 NOT NULL,
	"match" text DEFAULT 'all' NOT NULL,
	"conditions" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"actions" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"stop" boolean DEFAULT false NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "mail_accounts" DROP CONSTRAINT "mail_accounts_user_id_unique";--> statement-breakpoint
ALTER TABLE "mail_accounts" ALTER COLUMN "imap_host" DROP NOT NULL;--> statement-breakpoint
ALTER TABLE "mail_accounts" ALTER COLUMN "imap_port" DROP NOT NULL;--> statement-breakpoint
ALTER TABLE "mail_accounts" ALTER COLUMN "imap_security" DROP NOT NULL;--> statement-breakpoint
ALTER TABLE "mail_accounts" ALTER COLUMN "smtp_host" DROP NOT NULL;--> statement-breakpoint
ALTER TABLE "mail_accounts" ALTER COLUMN "smtp_port" DROP NOT NULL;--> statement-breakpoint
ALTER TABLE "mail_accounts" ALTER COLUMN "smtp_security" DROP NOT NULL;--> statement-breakpoint
ALTER TABLE "mail_accounts" ALTER COLUMN "username" DROP NOT NULL;--> statement-breakpoint
ALTER TABLE "mail_accounts" ALTER COLUMN "password_enc" DROP NOT NULL;--> statement-breakpoint
ALTER TABLE "mail_accounts" ADD COLUMN "position" integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "mail_accounts" ADD COLUMN "auth_type" text DEFAULT 'password' NOT NULL;--> statement-breakpoint
ALTER TABLE "mail_accounts" ADD COLUMN "oauth_provider" text;--> statement-breakpoint
ALTER TABLE "mail_accounts" ADD COLUMN "oauth_refresh_enc" text;--> statement-breakpoint
ALTER TABLE "mail_accounts" ADD COLUMN "oauth_access_enc" text;--> statement-breakpoint
ALTER TABLE "mail_accounts" ADD COLUMN "oauth_expires_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "mail_accounts" ADD COLUMN "signature" text;--> statement-breakpoint
ALTER TABLE "mail_accounts" ADD COLUMN "signature_on_new" boolean DEFAULT true NOT NULL;--> statement-breakpoint
ALTER TABLE "mail_accounts" ADD COLUMN "signature_on_reply" boolean DEFAULT true NOT NULL;--> statement-breakpoint
ALTER TABLE "mail_accounts" ADD COLUMN "trusted_senders" jsonb DEFAULT '[]'::jsonb NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "local_mail_enabled" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "local_mail_domains" text;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "local_mail_port" integer DEFAULT 25 NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "local_mail_max_message_mb" integer DEFAULT 25 NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "local_mail_quota_mb" integer DEFAULT 2048 NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "mail_oauth_google" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "mail_oauth_microsoft" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "local_mail_messages" ADD CONSTRAINT "local_mail_messages_account_id_mail_accounts_id_fk" FOREIGN KEY ("account_id") REFERENCES "public"."mail_accounts"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "mail_contacts" ADD CONSTRAINT "mail_contacts_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "mail_rules" ADD CONSTRAINT "mail_rules_account_id_mail_accounts_id_fk" FOREIGN KEY ("account_id") REFERENCES "public"."mail_accounts"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "mail_rules" ADD CONSTRAINT "mail_rules_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "local_mail_messages_folder_idx" ON "local_mail_messages" USING btree ("account_id","folder","uid");--> statement-breakpoint
CREATE UNIQUE INDEX "mail_contacts_user_address_uq" ON "mail_contacts" USING btree ("user_id","address");--> statement-breakpoint
CREATE INDEX "mail_rules_account_idx" ON "mail_rules" USING btree ("account_id","position");--> statement-breakpoint
CREATE INDEX "mail_accounts_user_idx" ON "mail_accounts" USING btree ("user_id","position");