CREATE TABLE "directory_group_mappings" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"source" text DEFAULT 'any' NOT NULL,
	"group" text NOT NULL,
	"team_id" uuid,
	"account_role" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "group_sync_grants" (
	"user_id" uuid NOT NULL,
	"team_id" uuid NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "group_sync_grants_user_id_team_id_pk" PRIMARY KEY("user_id","team_id")
);
--> statement-breakpoint
CREATE TABLE "sso_sessions" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"provider" text NOT NULL,
	"idp_session_id" text,
	"name_id" text,
	"name_id_format" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"ended_at" timestamp with time zone,
	"end_reason" text
);
--> statement-breakpoint
CREATE TABLE "webauthn_credentials" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"credential_id" text NOT NULL,
	"public_key" text NOT NULL,
	"counter" bigint DEFAULT 0 NOT NULL,
	"transports" jsonb,
	"device_type" text,
	"backed_up" boolean DEFAULT false NOT NULL,
	"aaguid" text,
	"name" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"last_used_at" timestamp with time zone
);
--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "saml_enabled" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "saml_label" text;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "saml_entry_point" text;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "saml_idp_issuer" text;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "saml_idp_cert" text;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "saml_logout_url" text;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "saml_email_attr" text DEFAULT 'email' NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "saml_name_attr" text DEFAULT 'displayName' NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "saml_groups_attr" text DEFAULT 'groups' NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "saml_sp_private_key_enc" text;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "saml_sp_cert" text;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "group_sync_enabled" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "group_sync_remove" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "passkey_login_enabled" boolean DEFAULT true NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "sso_idp_logout" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "group_sync_role" text;--> statement-breakpoint
ALTER TABLE "directory_group_mappings" ADD CONSTRAINT "directory_group_mappings_team_id_teams_id_fk" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "group_sync_grants" ADD CONSTRAINT "group_sync_grants_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "group_sync_grants" ADD CONSTRAINT "group_sync_grants_team_id_teams_id_fk" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "sso_sessions" ADD CONSTRAINT "sso_sessions_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "webauthn_credentials" ADD CONSTRAINT "webauthn_credentials_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "directory_group_mappings_team_idx" ON "directory_group_mappings" USING btree ("team_id");--> statement-breakpoint
CREATE INDEX "sso_sessions_idp_session_idx" ON "sso_sessions" USING btree ("provider","idp_session_id");--> statement-breakpoint
CREATE INDEX "sso_sessions_name_id_idx" ON "sso_sessions" USING btree ("provider","name_id");--> statement-breakpoint
CREATE INDEX "sso_sessions_user_idx" ON "sso_sessions" USING btree ("user_id");--> statement-breakpoint
CREATE UNIQUE INDEX "webauthn_credentials_credential_idx" ON "webauthn_credentials" USING btree ("credential_id");--> statement-breakpoint
CREATE INDEX "webauthn_credentials_user_idx" ON "webauthn_credentials" USING btree ("user_id");