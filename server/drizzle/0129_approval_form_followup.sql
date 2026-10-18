ALTER TABLE "approval_documents" ADD COLUMN "settles_id" uuid;--> statement-breakpoint
ALTER TABLE "approval_templates" ADD COLUMN "default_line" jsonb;--> statement-breakpoint
ALTER TABLE "approval_templates" ADD COLUMN "default_cc_ids" jsonb DEFAULT '[]'::jsonb NOT NULL;--> statement-breakpoint
ALTER TABLE "approval_documents" ADD CONSTRAINT "approval_documents_settles_id_approval_documents_id_fk" FOREIGN KEY ("settles_id") REFERENCES "public"."approval_documents"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "approval_documents_settles_idx" ON "approval_documents" USING btree ("settles_id");