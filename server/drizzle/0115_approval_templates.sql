CREATE TABLE "approval_templates" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"scope_key" text NOT NULL,
	"builtin_key" text,
	"name" text NOT NULL,
	"description" text,
	"fields" jsonb NOT NULL,
	"allow_attachments" boolean DEFAULT false NOT NULL,
	"enabled" boolean DEFAULT true NOT NULL,
	"sort_order" integer DEFAULT 0 NOT NULL,
	"created_by" uuid,
	"created_by_name" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "approval_templates" ADD CONSTRAINT "approval_templates_created_by_users_id_fk" FOREIGN KEY ("created_by") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "approval_templates_scope_idx" ON "approval_templates" USING btree ("scope_key");--> statement-breakpoint
CREATE UNIQUE INDEX "approval_templates_builtin_idx" ON "approval_templates" USING btree ("scope_key","builtin_key");