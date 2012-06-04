/* api_management_utility
	1) validate_nospecial
	2) validate_name
	3) renew_system
	4) lock_process
	5) unlock_process
	6) intialize
	7) deinitialize
	8) reset_database
	9) exec
*/

/* API - validate_nospecial */
CREATE OR REPLACE FUNCTION "api"."validate_nospecial"(input text) RETURNS TEXT AS $$
	DECLARE
		BadCrap TEXT;
	BEGIN
		BadCrap = regexp_replace(input, E'[a-z0-9]*', '', 'gi');
		IF BadCrap != '' THEN
			RAISE EXCEPTION 'Invalid characters detected in string "%"',input;
		END IF;
		RETURN input;
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."validate_nospecial"(text) IS 'Block all special characters';

/* API - validate_name */
CREATE OR REPLACE FUNCTION "api"."validate_name"(input text) RETURNS TEXT AS $$
	DECLARE
		BadCrap TEXT;
	BEGIN
		BadCrap = regexp_replace(input, E'[a-z0-9\:\_\/ ]*\-*', '', 'gi');
		IF BadCrap != '' THEN
			RAISE EXCEPTION 'Invalid characters detected in string "%"',input;
		END IF;
		IF input = '' THEN
			RAISE EXCEPTION 'Name cannot be blank';
		END IF;
		RETURN input;
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."validate_name"(text) IS 'Allow certain characters for names';

/* API - renew_system
	1) Check privileges
	2) Renew system
*/
CREATE OR REPLACE FUNCTION "api"."renew_system"(input_system_name text) RETURNS VOID AS $$
	BEGIN
		PERFORM api.create_log_entry('API','DEBUG','begin api.renew_system');

		-- Check privileges
		IF api.get_current_user_level() ~* 'PROGRAM|USER' THEN
			IF (SELECT "owner" FROM "systems"."systems" WHERE "system_name" = input_system_name) != api.get_current_user() THEN
				PERFORM api.create_log_entry('API','ERROR','Permission denied');
				RAISE EXCEPTION 'Permission denied. Only admins can create site directives';
			END IF;
		END IF;

		-- Renew system
		PERFORM api.create_log_entry('API','INFO','renewing system');
		UPDATE "systems"."systems" SET "renew_date" = date(current_date + interval '1 year');

		-- Done
		PERFORM api.create_log_entry('API','DEBUG','finish api.renew_system');
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."renew_system"(text) IS 'Renew a registered system for the next year';

/* API - lock_process
	1) Check privileges
	2) Get current status
	3) Update status
*/
CREATE OR REPLACE FUNCTION "api"."lock_process"(input_process text) RETURNS VOID AS $$
	DECLARE
		Status BOOLEAN;
	BEGIN
		PERFORM api.create_log_entry('API','DEBUG','begin api.lock_process');

		-- Check privileges
		IF api.get_current_user_level() !~* 'ADMIN' THEN
			PERFORM api.create_log_entry('API','ERROR','Permission denied');
			RAISE EXCEPTION 'Permission denied. Only admins can control processes';
		END IF;

		-- Get current status
		SELECT "locked" INTO Status
		FROM "management"."processes"
		WHERE "management"."processes"."process" = input_process;
		IF Status IS TRUE THEN
			RAISE EXCEPTION 'Process is locked';
		END IF;

		-- Update status
		PERFORM api.create_log_entry('API','INFO','locking process '||input_process);
		UPDATE "management"."processes" SET "locked" = TRUE WHERE "management"."processes"."process" = input_process;

		-- Done
		PERFORM api.create_log_entry('API','DEBUG','finish api.lock_process');
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."lock_process"(text) IS 'Lock a process for a job';

/* API - unlock_process
	1) Check privileges
	2) Update status
*/
CREATE OR REPLACE FUNCTION "api"."unlock_process"(input_process text) RETURNS VOID AS $$
	BEGIN
		PERFORM api.create_log_entry('API','DEBUG','begin api.unlock_process');

		-- Check privileges
		IF api.get_current_user_level() !~* 'ADMIN' THEN
			PERFORM api.create_log_entry('API','ERROR','Permission denied');
			RAISE EXCEPTION 'Permission denied. Only admins can control processes';
		END IF;

		-- Update status
		PERFORM api.create_log_entry('API','INFO','unlocking process '||input_process);
		UPDATE "management"."processes" SET "locked" = FALSE WHERE "management"."processes"."process" = input_process;

		-- Done
		PERFORM api.create_log_entry('API','DEBUG','finish api.unlock_process');
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."unlock_process"(text) IS 'Unlock a process for a job';

/* API - initialize
	1) Get level
	2) Create privilege table
	3) Populate privileges
	4) Set level
*/
CREATE OR REPLACE FUNCTION "api"."initialize"(input_username text) RETURNS TEXT AS $$
	DECLARE
		Level TEXT;
	BEGIN
		-- Get level
		SELECT api.get_ldap_user_level(input_username) INTO Level;
		--IF input_username ~* 'cohoe|clockfort|russ|dtyler|worr|benrr101' THEN
			--Level := 'ADMIN';
		--ELSE
			--Level := 'USER';
		--END IF;
		IF Level='NONE' THEN
			RAISE EXCEPTION 'Could not identify "%".',input_username;
		END IF;

		-- Create privilege table
		DROP TABLE IF EXISTS "user_privileges";

		CREATE TEMPORARY TABLE "user_privileges"
		(username text NOT NULL,privilege text NOT NULL,
		allow boolean NOT NULL DEFAULT false);

		-- Populate privileges
		INSERT INTO "user_privileges" VALUES (input_username,'USERNAME',TRUE);
		INSERT INTO "user_privileges" VALUES (input_username,'ADMIN',FALSE);
		INSERT INTO "user_privileges" VALUES (input_username,'PROGRAM',FALSE);
		INSERT INTO "user_privileges" VALUES (input_username,'USER',FALSE);
		ALTER TABLE "user_privileges" ALTER COLUMN "username" SET DEFAULT api.get_current_user();

		-- Set level
		UPDATE "user_privileges" SET "allow" = TRUE WHERE "privilege" = Level;

		PERFORM api.create_log_entry('API','INFO','User "'||input_username||'" ('||Level||') has successfully initialized.');
		RETURN 'Greetings '||lower(Level)||'!';
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."initialize"(text) IS 'Setup user access to the database';

/* API - deinitialize */
CREATE OR REPLACE FUNCTION "api"."deinitialize"() RETURNS VOID AS $$
	BEGIN
		DROP TABLE IF EXISTS "user_privileges";
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."deinitialize"() IS 'Reset user permissions to activate a new user';

/* API - reset_database */
CREATE OR REPLACE FUNCTION "api"."reset_database"() RETURNS VOID AS $$
	DECLARE
		tables RECORD;
	BEGIN
		FOR tables IN (SELECT "table_schema","table_name" 
		FROM "information_schema"."tables" 
		WHERE "table_schema" !~* 'information_schema|pg_catalog'
		AND "table_type" ~* 'BASE TABLE'
		ORDER BY "table_schema" ASC) LOOP
			PERFORM (SELECT api.exec('DROP TABLE '||tables.table_schema||'.'||tables.table_name||' CASCADE'));
		END LOOP;
	END;
$$ LANGUAGE 'plpgsql';
ALTER FUNCTION api.reset_database() OWNER TO impulse_admin;
GRANT EXECUTE ON FUNCTION api.initialize(text) TO impulse_admin;
REVOKE ALL PRIVILEGES ON FUNCTION api.reset_database() FROM public;

COMMENT ON FUNCTION "api"."reset_database"() IS 'Drop all tables to reset the database to only functions';

/* API - exec */
CREATE OR REPLACE FUNCTION "api"."exec"(text) RETURNS VOID AS $$
	BEGIN
		EXECUTE $1;
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."exec"(text) IS 'Execute a query in a plpgsql context';

/* API - change_username */
CREATE OR REPLACE FUNCTION "api"."change_username"(old_username text, new_username text) RETURNS VOID AS $$
	BEGIN
		PERFORM api.create_log_entry('API','DEBUG','Begin api.change_username');
		
		-- Check privileges
		IF api.get_current_user_level() !~* 'ADMIN' THEN
			PERFORM api.create_log_entry('API','ERROR','Permission denied to change username');
			RAISE EXCEPTION 'Only admins can change usernames';
		END IF;
		
		-- Perform update
		UPDATE "dhcp"."class_options" SET "last_modifier" = new_username WHERE "last_modifier" = old_username;
		UPDATE "dhcp"."range_options" SET "last_modifier" = new_username WHERE "last_modifier" = old_username;
		UPDATE "dhcp"."global_options" SET "last_modifier" = new_username WHERE "last_modifier" = old_username;
		UPDATE "dhcp"."classes" SET "last_modifier" = new_username WHERE "last_modifier" = old_username;
		UPDATE "dhcp"."subnet_options" SET "last_modifier" = new_username WHERE "last_modifier" = old_username;
		UPDATE "dhcp"."config_types" SET "last_modifier" = new_username WHERE "last_modifier" = old_username;
		UPDATE "dns"."types" SET "last_modifier" = new_username WHERE "last_modifier" = old_username;
		UPDATE "dns"."ns" SET "owner" = new_username WHERE "owner" = old_username;
		UPDATE "dns"."ns" SET "last_modifier" = new_username WHERE "last_modifier" = old_username;
		UPDATE "dns"."srv" SET "owner" = new_username WHERE "owner" = old_username;
		UPDATE "dns"."srv" SET "last_modifier" = new_username WHERE "last_modifier" = old_username;
		UPDATE "dns"."cname" SET "owner" = new_username WHERE "owner" = old_username;
		UPDATE "dns"."cname" SET "last_modifier" = new_username WHERE "last_modifier" = old_username;
		UPDATE "dns"."mx" SET "owner" = new_username WHERE "owner" = old_username;
		UPDATE "dns"."mx" SET "last_modifier" = new_username WHERE "last_modifier" = old_username;
		UPDATE "dns"."zones" SET "owner" = new_username WHERE "owner" = old_username;
		UPDATE "dns"."zones" SET "last_modifier" = new_username WHERE "last_modifier" = old_username;
		UPDATE "dns"."keys" SET "owner" = new_username WHERE "owner" = old_username;
		UPDATE "dns"."keys" SET "last_modifier" = new_username WHERE "last_modifier" = old_username;
		UPDATE "dns"."txt" SET "owner" = new_username WHERE "owner" = old_username;
		UPDATE "dns"."txt" SET "last_modifier" = new_username WHERE "last_modifier" = old_username;
		UPDATE "dns"."a" SET "owner" = new_username WHERE "owner" = old_username;
		UPDATE "dns"."a" SET "last_modifier" = new_username WHERE "last_modifier" = old_username;
		UPDATE "dns"."soa" SET "last_modifier" = new_username WHERE "last_modifier" = old_username;
		UPDATE "ip"."range_uses" SET "last_modifier" = new_username WHERE "last_modifier" = old_username;
		UPDATE "ip"."subnets" SET "owner" = new_username WHERE "owner" = old_username;
		UPDATE "ip"."subnets" SET "last_modifier" = new_username WHERE "last_modifier" = old_username;
		UPDATE "ip"."ranges" SET "last_modifier" = new_username WHERE "last_modifier" = old_username;
		UPDATE "ip"."addresses" SET "owner" = new_username WHERE "owner" = old_username;
		UPDATE "ip"."addresses" SET "last_modifier" = new_username WHERE "last_modifier" = old_username;
		UPDATE "systems"."device_types" SET "last_modifier" = new_username WHERE "last_modifier" = old_username;
		UPDATE "systems"."os_family" SET "last_modifier" = new_username WHERE "last_modifier" = old_username;
		UPDATE "systems"."interface_addresses" SET "last_modifier" = new_username WHERE "last_modifier" = old_username;
		UPDATE "systems"."systems" SET "owner" = new_username WHERE "owner" = old_username;
		UPDATE "systems"."systems" SET "last_modifier" = new_username WHERE "last_modifier" = old_username;
		UPDATE "systems"."os" SET "last_modifier" = new_username WHERE "last_modifier" = old_username;
		UPDATE "systems"."interfaces" SET "last_modifier" = new_username WHERE "last_modifier" = old_username;
		UPDATE "systems"."type_family" SET "last_modifier" = new_username WHERE "last_modifier" = old_username;
		UPDATE "network"."switchports" SET "last_modifier" = new_username WHERE "last_modifier" = old_username;
		UPDATE "network"."switchport_types" SET "last_modifier" = new_username WHERE "last_modifier" = old_username;
		UPDATE "management"."configuration" SET "last_modifier" = new_username WHERE "last_modifier" = old_username;
		UPDATE "management"."log_master" SET "user" = new_username WHERE "user" = old_username;
		PERFORM api.create_log_entry('API','INFO','Changed user '||old_username||' to '||new_username);
		
		-- Done
		PERFORM api.create_log_entry('API','DEBUG','End api.change_username');
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."change_username"(text, text) IS 'Change all references to an old username to a new one';

/* API - validate_soa_contact */
CREATE OR REPLACE FUNCTION "api"."validate_soa_contact"(input text) RETURNS BOOLEAN AS $$
	DECLARE
		BadCrap TEXT;
	BEGIN
		BadCrap = regexp_replace(input, E'[a-z0-9\.]*\-*', '', 'gi');
		IF BadCrap != '' THEN
			RAISE EXCEPTION 'Invalid characters detected in string "%"',input;
		END IF;
		IF input = '' THEN
		END IF;
			RAISE EXCEPTION 'Contact cannot be blank';
		RETURN TRUE;
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."validate_soa_contact"(text) IS 'Ensure that the SOA contact is properly formatted';

CREATE OR REPLACE FUNCTION "api"."clean_log"() RETURNS VOID AS $$
	BEGIN
		DELETE FROM "management"."log_master" WHERE "timestamp" < current_timestamp - interval '1 month';
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."clean_log"() IS 'Remove all log entries older than a month';