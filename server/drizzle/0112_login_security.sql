CREATE TABLE "user_identities" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"provider" text NOT NULL,
	"subject" text NOT NULL,
	"email_enc" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"last_login_at" timestamp with time zone
);
--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "otp_policy" text DEFAULT 'optional' NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "sso_google_enabled" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "sso_google_client_id" text;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "sso_google_client_secret_enc" text;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "sso_google_domains" text;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "sso_microsoft_enabled" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "sso_microsoft_tenant_id" text;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "sso_microsoft_client_id" text;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "sso_microsoft_client_secret_enc" text;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "sso_auto_create" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "sso_default_role" text DEFAULT 'member' NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "sso_session_days" integer DEFAULT 7 NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "ldap_enabled" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "ldap_url" text;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "ldap_bind_dn" text;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "ldap_bind_password_enc" text;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "ldap_base_dn" text;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "ldap_user_filter" text DEFAULT '(&(objectClass=user)(sAMAccountName={username}))' NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "ldap_name_attr" text DEFAULT 'displayName' NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "ldap_email_attr" text DEFAULT 'mail' NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "ldap_department_attr" text DEFAULT 'department' NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "ldap_title_attr" text DEFAULT 'title' NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "ldap_tls_verify" boolean DEFAULT true NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "ldap_auto_create" boolean DEFAULT true NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "ldap_default_role" text DEFAULT 'member' NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "ldap_tested_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "auth_source" text DEFAULT 'local' NOT NULL;--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "totp_secret_enc" text;--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "totp_pending_enc" text;--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "totp_enabled_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "totp_last_step" integer;--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "totp_recovery_hashes" jsonb;--> statement-breakpoint
ALTER TABLE "user_identities" ADD CONSTRAINT "user_identities_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "user_identities_provider_subject_idx" ON "user_identities" USING btree ("provider","subject");--> statement-breakpoint
CREATE INDEX "user_identities_user_idx" ON "user_identities" USING btree ("user_id");