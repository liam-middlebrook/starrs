/* api_management_create.sql
	2) create_site_configuration
*/

/* API - create_site_configuration
	1) Check privileges
	2) Create directive
*/
CREATE OR REPLACE FUNCTION "api"."create_site_configuration"(input_directive text, input_value text) RETURNS SETOF "management"."configuration" AS $$
	BEGIN

		-- Check privileges
		IF api.get_current_user_level() !~* 'ADMIN' THEN
			RAISE EXCEPTION 'Permission denied. Only admins can create site directives';
		END IF;

		-- Create directive
		INSERT INTO "management"."configuration" VALUES (input_directive, input_value);

		-- Done
		PERFORM api.syslog('create_site_configuration:"'||input_directive||'","'||input_value||'"');
		RETURN QUERY (SELECT * FROM "management"."configuration" WHERE "option" = input_directive AND "value" = input_value);
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."create_site_configuration"(text, text) IS 'Create a new site configuration directive';

CREATE OR REPLACE FUNCTION "api"."create_group"(input_group text, input_privilege text, input_comment text, input_interval interval) RETURNS SETOF "management"."groups" AS $$
	BEGIN
		IF api.get_current_user_level() !~* 'ADMIN' THEN
			RAISE EXCEPTION 'Permission denied. Only admins can create groups.';
		END IF;

		IF input_interval IS NULL THEN
			input_interval := api.get_site_configuration('DEFAULT_RENEW_INTERVAL');
		END IF;

		INSERT INTO "management"."groups" ("group","privilege","comment","renew_interval") 
		VALUES (input_group, input_privilege, input_comment, input_interval);

		PERFORM api.syslog('create_group:"'||input_group||'","'||input_privilege||'","'||input_interval||'"');
		RETURN QUERY (SELECT * FROM "management"."groups" WHERE "group" = input_group);
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."create_group"(text, text, text, interval) IS 'Create a user group';

CREATE OR REPLACE FUNCTION "api"."create_group_member"(input_group text, input_user text, input_privilege text) RETURNS SETOF "management"."group_members" AS $$
	BEGIN
		IF api.get_current_user_level() !~* 'ADMIN' THEN
			IF api.get_current_user() NOT IN (SELECT * FROM api.get_group_admins(input_group)) THEN
				RAISE EXCEPTION 'Permission denied. Only admins can create groups.';
			END IF;
		END IF;

		INSERT INTO "management"."group_members" ("group","user","privilege") 
		VALUES (input_group, input_user, input_privilege);
	
		PERFORM api.syslog('create_group_member:"'||input_group||'","'||input_user||'","'||input_privilege||'"');
		RETURN QUERY (SELECT * FROM "management"."group_members" WHERE "group" = input_group AND "user" = input_user);
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."create_group_member"(text, text, text) IS 'Assign a user to a group';
