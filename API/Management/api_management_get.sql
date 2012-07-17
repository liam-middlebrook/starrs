/* api_management_get.sql
	1) get_current_user
	2) get_current_user_level
	3) get_ldap_user_level
	4) get_site_configuration
*/

/* API - get_current_user_level */
CREATE OR REPLACE FUNCTION "api"."get_current_user_level"() RETURNS TEXT AS $$
	BEGIN
		RETURN (SELECT "privilege"
		FROM "user_privileges"
		WHERE "allow" = TRUE
		AND "privilege" ~* '^admin|program|user$');
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."get_current_user_level"() IS 'Get the level of the current session user';

/* API - get_ldap_user_level
	1) Load configuration
	2) Bind to the LDAP server
	3) Figure out permission level
	4) Unbind from LDAP server
*/
CREATE OR REPLACE FUNCTION "api"."get_ldap_user_level"(TEXT) RETURNS TEXT AS $$
	use strict;
	use warnings;
	use Net::LDAP;
	
	# Get the current authenticated username
	my $username = $_[0] or die "Need to give a username";
	
	# If this is the installer, we dont need to query the server
	if ($username eq "root")
	{
		return "ADMIN";
	}
	
	# Get LDAP connection information
	my $host = spi_exec_query("SELECT api.get_site_configuration('LDAP_HOST')")->{rows}[0]->{"get_site_configuration"};
	my $binddn = spi_exec_query("SELECT api.get_site_configuration('LDAP_BINDDN')")->{rows}[0]->{"get_site_configuration"};
	my $password = spi_exec_query("SELECT api.get_site_configuration('LDAP_PASSWORD')")->{rows}[0]->{"get_site_configuration"};
	my $admin_filter = spi_exec_query("SELECT api.get_site_configuration('LDAP_ADMIN_FILTER')")->{rows}[0]->{"get_site_configuration"};
	my $admin_basedn = spi_exec_query("SELECT api.get_site_configuration('LDAP_ADMIN_BASEDN')")->{rows}[0]->{"get_site_configuration"};
	my $program_filter = spi_exec_query("SELECT api.get_site_configuration('LDAP_PROGRAM_FILTER')")->{rows}[0]->{"get_site_configuration"};
	my $program_basedn = spi_exec_query("SELECT api.get_site_configuration('LDAP_PROGRAM_BASEDN')")->{rows}[0]->{"get_site_configuration"};
	my $user_filter = spi_exec_query("SELECT api.get_site_configuration('LDAP_USER_FILTER')")->{rows}[0]->{"get_site_configuration"};
	my $user_basedn = spi_exec_query("SELECT api.get_site_configuration('LDAP_USER_BASEDN')")->{rows}[0]->{"get_site_configuration"};

	# The lowest status. Build from here.
	my $status = "NONE";

	# Bind to the LDAP server
	my $srv = Net::LDAP->new ($host) or die "Could not connect to LDAP server ($host)\n";
	my $mesg = $srv->bind($binddn,password=>$password) or die "Could not bind to LDAP server at $host\n";
	
	# Go through the directory and see if this user is a user account
	$mesg = $srv->search(filter=>"($user_filter=$username)",base=>$user_basedn,attrs=>[$user_filter]);
	foreach my $entry ($mesg->entries)
	{
		my @users = $entry->get_value($user_filter);
		foreach my $user (@users)
		{
			$user =~ s/^uid=(.*?)\,(.*?)$/$1/;
			if ($user eq $username)
			{
				$status = "USER";
			}
		}
	}

	# Go through the directory and see if this user is a program account
	$mesg = $srv->search(filter=>"($program_filter=$username)",base=>$program_basedn,attrs=>[$program_filter]);
	foreach my $entry ($mesg->entries)
	{
		my @programs = $entry->get_value($program_filter);
		foreach my $program (@programs)
		{
			if ($program eq $username)
			{
				$status = "PROGRAM";
			}
		}
	}
	
	# Go through the directory and see if this user is an admin
	# Fancy hacks to allow for less hardcoding of attributes
	my $admin_filter_atr = $admin_filter;
	$admin_filter_atr =~ s/^(.*?)[^a-zA-Z0-9]+$/$1/;
	$mesg = $srv->search(filter=>"($admin_filter)",base=>$admin_basedn,attrs=>[$admin_filter_atr]);
	foreach my $entry ($mesg->entries)
	{
		my @admins = $entry->get_value($admin_filter_atr);
		foreach my $admin (@admins)
		{
			$admin =~ s/^uid=(.*?)\,(.*?)$/$1/;
			if ($admin eq $username)
			{
				$status = "ADMIN";
			}
		}
	}

	# Unbind from the LDAP server
	$srv->unbind;

	# Done
	return $status;

#	if($_[0] eq 'root')
#	{
#		return "ADMIN"
#	}
#	else
#	{
#		return "USER";
#	}
$$ LANGUAGE 'plperlu';
COMMENT ON FUNCTION "api"."get_ldap_user_level"(text) IS 'Get the level of access for the authenticated user';

CREATE OR REPLACE FUNCTION "api"."get_site_configuration_all"() RETURNS SETOF "management"."configuration" AS $$
	BEGIN
		RETURN QUERY (SELECT * FROM "management"."configuration" ORDER BY "option" ASC);
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."get_site_configuration_all"() IS 'Get all site configuration directives';

CREATE OR REPLACE FUNCTION "api"."get_search_data"() RETURNS SETOF "management"."search_data" AS $$
	BEGIN
		RETURN QUERY (SELECT
	"systems"."systems"."datacenter",
	(SELECT "zone" FROM "ip"."ranges" WHERE "name" =  "api"."get_address_range"("systems"."interface_addresses"."address")) AS "availability_zone",
	"systems"."systems"."system_name",
	"systems"."systems"."asset",
	"systems"."systems"."group",
	"systems"."systems"."platform_name",
	"systems"."interfaces"."mac",
	"systems"."interface_addresses"."address",
	"systems"."systems"."owner" AS "system_owner",
	"systems"."systems"."last_modifier" AS "system_last_modifier",
	"api"."get_address_range"("systems"."interface_addresses"."address") AS "range",
	"dns"."a"."hostname",
	"dns"."a"."zone",
	"dns"."a"."owner" AS "dns_owner",
	"dns"."a"."last_modifier" AS "dns_last_modifier"
FROM 	"systems"."systems"
LEFT JOIN	"systems"."interfaces" ON "systems"."interfaces"."system_name" = "systems"."systems"."system_name"
LEFT JOIN	"systems"."interface_addresses" ON "systems"."interface_addresses"."mac" = "systems"."interfaces"."mac"
LEFT JOIN	"dns"."a" ON "dns"."a"."address" = "systems"."interface_addresses"."address"
ORDER BY "systems"."interface_addresses"."address","systems"."interfaces"."mac");
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."get_search_data"() IS 'Get search data to parse';

CREATE OR REPLACE FUNCTION "api"."get_function_counts"(input_schema TEXT) RETURNS TABLE("function" TEXT, calls INTEGER) AS $$
	BEGIN
		RETURN QUERY(
			SELECT "information_schema"."routines"."routine_name"::text,"pg_stat_user_functions"."calls"::integer 
			FROM "information_schema"."routines" 
			LEFT JOIN "pg_stat_user_functions" ON "pg_stat_user_functions"."funcname" = "information_schema"."routines"."routine_name" 
			WHERE "information_schema"."routines"."routine_schema" = input_schema
		);
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."get_function_counts"(TEXT) IS 'Get statistics on number of calls to each function in a schema';

CREATE OR REPLACE FUNCTION "api"."get_current_user_groups"() RETURNS SETOF TEXT AS $$
	BEGIN
		RETURN QUERY(SELECT "group" FROM "management"."group_members" WHERE "user" = api.get_current_user());
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."get_current_user_groups"() IS 'Get the groups of the current user';

CREATE OR REPLACE FUNCTION "api"."get_group_admins"(input_group text) RETURNS SETOF TEXT AS $$
	BEGIN
		RETURN QUERY(SELECT "user" FROM "management"."group_members" WHERE "group" = input_group AND "privilege" = 'ADMIN');
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."get_group_admins"(text) IS 'Get a list of all admins for a group';

CREATE OR REPLACE FUNCTION "api"."get_system_permissions"(input_system_name text) RETURNS TABLE(read boolean, write boolean) AS $$
	DECLARE
		read BOOLEAN;
		write BOOLEAN;
		sysowner TEXT;
		sysgroup TEXT;
	BEGIN
		SELECT "owner","group" INTO sysowner, sysgroup
		FROM "systems"."systems"
		WHERE "system_name" = input_system_name;

		IF sysowner IS NULL THEN
			RAISE EXCEPTION 'System % not found!',input_system_name;
		END IF;
		
		IF sysgroup IN (SELECT * FROM api.get_current_user_groups()) THEN
			IF api.get_current_user() IN (SELECT * FROM api.get_group_admins(sysgroup)) THEN
				read := TRUE;
				write := TRUE;
			ELSE
				read := TRUE;
				write := FALSE;
			END IF;
		ELSE
			read := TRUE;
			write := FALSE;
		END IF;

		IF sysowner = api.get_current_user() THEN
			read := TRUE;
			write := TRUE;
			
		END IF;

		IF api.get_current_user_level() ~* 'ADMIN' THEN
			read := TRUE;
			write := TRUE;
		END IF;
		RETURN QUERY (SELECT read, write);
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."get_system_permissions"(text) IS 'Get the current user permissions on a system';

CREATE OR REPLACE FUNCTION "api"."get_groups"() RETURNS SETOF "management"."groups" AS $$
	BEGIN
		RETURN QUERY (SELECT * FROM "management"."groups" ORDER BY "group");
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."get_groups"() IS 'Get all of the configured groups';

CREATE OR REPLACE FUNCTION "api"."get_group_members"(input_group text) RETURNS SETOF "management"."group_members" AS $$
	BEGIN
		RETURN QUERY (SELECT * FROM "management"."group_members" WHERE "group" = input_group ORDER BY "user");
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."get_group_members"(text) IS 'Get all members of a group';

CREATE OR REPLACE FUNCTION "api"."get_local_user_level"(input_user text) RETURNS TEXT AS $$
	BEGIN
		IF input_user = 'root' THEN
			RETURN 'admin';
		END IF;

		IF input_user IN (SELECT "user" FROM api.get_group_members(api.get_site_configuration('DEFAULT_LOCAL_ADMIN_GROUP'))) THEN
			RETURN 'ADMIN';
		END IF;

		IF input_user IN (SELECT "user" FROM "management"."group_members" JOIN "management"."groups" ON "management"."groups"."group" = "management"."group_members"."group" WHERE "management"."groups"."privilege" = 'USER') THEN
			RETURN 'USER';
		END IF;

		IF input_user IN (SELECT "user" FROM "management"."group_members" JOIN "management"."groups" ON "management"."groups"."group" = "management"."group_members"."group" WHERE "management"."groups"."privilege" = 'PROGRAM') THEN
			RETURN 'PROGRAM';
		END IF;
		
		IF input_user IN (SELECT "user" FROM api.get_group_members(api.get_site_configuration('DEFAULT_LOCAL_USER_GROUP'))) THEN
			RETURN 'USER';
		END IF;
		
		RETURN 'NONE';
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."get_local_user_level"(text) IS 'Get the users privilege level based on local tables';
