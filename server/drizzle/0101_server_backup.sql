ALTER TABLE "server_settings" ADD COLUMN "backup_enabled" boolean DEFAULT true NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "backup_hour" integer DEFAULT 3 NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "backup_keep" integer DEFAULT 14 NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "backup_destination" text;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "backup_password" text;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "backup_mirror_key" text;