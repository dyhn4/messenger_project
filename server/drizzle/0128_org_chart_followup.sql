CREATE TABLE "approval_line_rules" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"scope_key" text NOT NULL,
	"kind" text NOT NULL,
	"template_id" uuid,
	"min_amount" bigint,
	"mode" text DEFAULT 'levels' NOT NULL,
	"levels" integer,
	"position_label" text,
	"extra_approver_ids" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"cc_ids" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "department_memberships" (
	"scope_key" text NOT NULL,
	"user_id" uuid NOT NULL,
	"department_id" uuid NOT NULL,
	"position" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "department_memberships_user_id_department_id_pk" PRIMARY KEY("user_id","department_id")
);
--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "ldap_org_source" text DEFAULT 'attribute' NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "ldap_org_base_dn" text;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "ldap_manager_sync" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "ldap_manager_attr" text DEFAULT 'manager' NOT NULL;--> statement-breakpoint
ALTER TABLE "approval_line_rules" ADD CONSTRAINT "approval_line_rules_template_id_approval_templates_id_fk" FOREIGN KEY ("template_id") REFERENCES "public"."approval_templates"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "department_memberships" ADD CONSTRAINT "department_memberships_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "department_memberships" ADD CONSTRAINT "department_memberships_department_id_departments_id_fk" FOREIGN KEY ("department_id") REFERENCES "public"."departments"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "approval_line_rules_scope_idx" ON "approval_line_rules" USING btree ("scope_key","kind");--> statement-breakpoint
CREATE INDEX "department_memberships_scope_idx" ON "department_memberships" USING btree ("scope_key");--> statement-breakpoint
CREATE INDEX "department_memberships_department_idx" ON "department_memberships" USING btree ("department_id");