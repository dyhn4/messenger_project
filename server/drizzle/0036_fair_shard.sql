ALTER TABLE "messages" ADD COLUMN "link_preview_url" text;--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "link_preview_title" text;--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "link_preview_description" text;--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "link_preview_image_url" text;--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "link_preview_site_name" text;--> statement-breakpoint
ALTER TABLE "rooms" ADD COLUMN "icon_type" text;--> statement-breakpoint
ALTER TABLE "rooms" ADD COLUMN "icon_emoji" text;--> statement-breakpoint
ALTER TABLE "rooms" ADD COLUMN "icon_color" text;