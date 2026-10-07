ALTER TABLE "secret_rekeys" ADD COLUMN "proposer_context_signature" text;--> statement-breakpoint
ALTER TABLE "secret_rekeys" ADD COLUMN "responder_context_signature" text;--> statement-breakpoint
ALTER TABLE "secret_sessions" ADD COLUMN "initiator_context_signature" text;--> statement-breakpoint
ALTER TABLE "secret_sessions" ADD COLUMN "responder_context_signature" text;