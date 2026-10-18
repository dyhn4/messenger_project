CREATE TABLE "approval_final_rules" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"scope_key" text NOT NULL,
	"kind" text NOT NULL,
	"template_id" uuid,
	"min_amount" bigint,
	"position_label" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "approval_steps" ADD COLUMN "seal" text;--> statement-breakpoint
ALTER TABLE "approval_steps" ADD COLUMN "signature_hash" text;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "approval_seal_private_key_enc" text;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "approval_seal_public_key" text;--> statement-breakpoint
ALTER TABLE "approval_final_rules" ADD CONSTRAINT "approval_final_rules_template_id_approval_templates_id_fk" FOREIGN KEY ("template_id") REFERENCES "public"."approval_templates"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "approval_final_rules_scope_idx" ON "approval_final_rules" USING btree ("scope_key","kind");