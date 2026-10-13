ALTER TABLE "server_settings" ADD COLUMN "ddns_enabled" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "ddns_domains" text;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "ddns_token" text;