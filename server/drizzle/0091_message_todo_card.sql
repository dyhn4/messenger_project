ALTER TABLE "messages" ADD COLUMN "todo_id" uuid;--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "todo_card" jsonb;--> statement-breakpoint
ALTER TABLE "messages" ADD CONSTRAINT "messages_todo_id_todos_id_fk" FOREIGN KEY ("todo_id") REFERENCES "public"."todos"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "messages_todo_id_idx" ON "messages" USING btree ("todo_id");