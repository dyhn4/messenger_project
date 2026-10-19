CREATE TABLE "local_mail_folders" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"account_id" uuid NOT NULL,
	"name" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "local_mail_messages" ADD COLUMN "in_reply_to" text;--> statement-breakpoint
ALTER TABLE "local_mail_messages" ADD COLUMN "references" jsonb DEFAULT '[]'::jsonb NOT NULL;--> statement-breakpoint
ALTER TABLE "local_mail_messages" ADD COLUMN "auth" jsonb;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "local_mail_spam_filter" boolean DEFAULT true NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "local_mail_dkim_enabled" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "local_mail_dkim_selector" text;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "local_mail_dkim_key" text;--> statement-breakpoint
ALTER TABLE "local_mail_folders" ADD CONSTRAINT "local_mail_folders_account_id_mail_accounts_id_fk" FOREIGN KEY ("account_id") REFERENCES "public"."mail_accounts"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "local_mail_folders_account_name_uq" ON "local_mail_folders" USING btree ("account_id",lower("name"));