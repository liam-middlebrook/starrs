/* Trigger - interface_addresses_insert 
	1) Set address family
	2) Check if address is within a subnet
	3) Check if primary address exists
	4) Check for one DHCPable address per MAC
	5) Check family against config type
	6) Check for wacky names
	7) Check for IPv6 secondary name
	8) IPv6 Autoconfiguration
*/
CREATE OR REPLACE FUNCTION "systems"."interface_addresses_insert"() RETURNS TRIGGER AS $$
	DECLARE
		RowCount INTEGER;
		ConfigFamily INTEGER;
		PrimaryName TEXT;
		Owner TEXT;
	BEGIN
		-- Set address family
		NEW."family" := family(NEW."address");

		-- Check if address is within a subnet
		SELECT COUNT(*) INTO RowCount
		FROM "ip"."subnets" 
		WHERE NEW."address" << "ip"."subnets"."subnet";
		IF (RowCount < 1) THEN
			RAISE EXCEPTION 'IP address (%) must be within a managed subnet.',NEW."address";
		END IF;
		
		-- Check if primary address exists (it shouldnt)
		SELECT COUNT(*) INTO RowCount
		FROM "systems"."interface_addresses"
		WHERE "systems"."interface_addresses"."isprimary" = TRUE
		AND "systems"."interface_addresses"."family" = NEW."family"
		AND "systems"."interface_addresses"."mac" = NEW."mac";
		IF NEW."isprimary" IS TRUE AND RowCount > 0 THEN
			-- There is a primary address already registered and this was supposed to be one.
			RAISE EXCEPTION 'Primary address for this interface and family already exists';
		ELSIF NEW."isprimary" IS FALSE AND RowCount = 0 THEN
			-- There is no primary and this is set to not be one.
			RAISE EXCEPTION 'No primary address exists for this interface (%) and family (%).',NEW."mac",NEW."family";
		END IF;

		-- Check for one DHCPable address per MAC
		IF NEW."config" !~* 'static' THEN
			SELECT COUNT(*) INTO RowCount
			FROM "systems"."interface_addresses"
			WHERE "systems"."interface_addresses"."family" = NEW."family"
			AND "systems"."interface_addresses"."config" ~* 'dhcp'
			AND "systems"."interface_addresses"."mac" = NEW."mac";
			IF (RowCount > 0) THEN
				RAISE EXCEPTION 'Only one DHCP/Autoconfig-able address per MAC (%) is allowed',NEW."mac";
			END IF;
		END IF;

		-- Check address family against config type
		IF NEW."config" !~* 'static' THEN
			SELECT "family" INTO ConfigFamily
			FROM "dhcp"."config_types"
			WHERE "dhcp"."config_types"."config" = NEW."config";
			IF NEW."family" != ConfigFamily THEN
				RAISE EXCEPTION 'Invalid configuration type selected (%) for your address family (%)',NEW."config",NEW."family";
			END IF;
		END IF;
		
		-- IPv6 Autoconfiguration
		IF NEW."family" = 6 AND NEW."config" ~* 'autoconf|static' THEN
			SELECT "systems"."systems"."owner" INTO Owner
			FROM "systems"."interfaces"
			JOIN "systems"."systems" ON
			"systems"."systems"."system_name" = "systems"."interfaces"."system_name"
			WHERE "systems"."interfaces"."mac" = NEW."mac";

			SELECT COUNT(*) INTO RowCount
			FROM "ip"."addresses"
			WHERE "ip"."addresses"."address" = NEW."address";
			IF (RowCount = 0) THEN
				INSERT INTO "ip"."addresses" ("address","owner") VALUES (NEW."address",Owner);
			END IF;
			
		END IF;

		RETURN NEW;
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "systems"."interface_addresses_insert"() IS 'Create a new address based on a very complex ruleset';

/* TRIGGER - interface_addresses_update 
	1) Set family
	2) Check if IP is in controlled subnet
	3) Check primary existance
	4) Check DHCP
	5) Check address family against config type
	6) Autoconf
	7) Names
	8) Secondaries
*/
CREATE OR REPLACE FUNCTION "systems"."interface_addresses_update"() RETURNS TRIGGER AS $$
	DECLARE
		RowCount INTEGER;
		ConfigFamily INTEGER;
		PrimaryName TEXT;
		Owner TEXT;
	BEGIN
		IF NEW."address" != OLD."address" THEN
			-- Set family
			NEW."family" := family(NEW."address");

			-- Check if IP is within our controlled subnets
			SELECT COUNT(*) INTO RowCount
			FROM "ip"."subnets" 
			WHERE NEW."address" << "ip"."subnets"."subnet";
			IF (RowCount < 1) THEN
				RAISE EXCEPTION 'IP address (%) must be within a managed subnet.',NEW."address";
			END IF;
		END IF;
		
		-- Check if primary for the family already exists. It shouldnt.
		IF NEW."isprimary" != OLD."isprimary" THEN
			SELECT COUNT(*) INTO RowCount
			FROM "systems"."interface_addresses"
			WHERE "systems"."interface_addresses"."isprimary" = TRUE
			AND "systems"."interface_addresses"."family" = NEW."family"
			AND "systems"."interface_addresses"."mac" = NEW."mac";
			IF NEW."isprimary" IS TRUE AND RowCount > 0 THEN
				-- There is a primary address already registered and this was supposed to be one.
				RAISE EXCEPTION 'Primary address for this interface and family already exists';
			ELSIF NEW."isprimary" IS FALSE AND RowCount = 0 THEN
				-- There is no primary and this is set to not be one.
				RAISE EXCEPTION 'No primary address exists for this interface and family and this will not be one.';
			END IF;
		END IF;

		-- Check for only one DHCPable address per MAC address
		IF NEW."config" != OLD."config" THEN
			IF NEW."config" ~* '^dhcp$' THEN
				SELECT COUNT(*) INTO RowCount
				FROM "systems"."interface_addresses"
				WHERE "systems"."interface_addresses"."family" = NEW."family"
				AND "systems"."interface_addresses"."config" ~* 'dhcp'
				AND "systems"."interface_addresses"."mac" = NEW."mac";
				IF (RowCount > 0) THEN
					RAISE EXCEPTION 'Only one DHCP/Autoconfig-able address per MAC (%) is allowed',NEW."mac";
				END IF;
			END IF;

			-- Check address family against config type
			IF NEW."config" !~* 'static' THEN
				SELECT "family" INTO ConfigFamily
				FROM "dhcp"."config_types"
				WHERE "dhcp"."config_types"."config" = NEW."config";
				IF NEW."family" != ConfigFamily THEN
					RAISE EXCEPTION 'Invalid configuration type selected (%) for your address family (%)',NEW."config",NEW."family";
				END IF;
			END IF;
			
			-- IPv6 Autoconfiguration
			IF NEW."family" = 6 AND NEW."config" ~* 'autoconf' THEN
				SELECT COUNT(*) INTO RowCount
				FROM "ip"."addresses"
				WHERE "ip"."addresses"."address" = NEW."address";
				IF (RowCount > 0) THEN
					RAISE EXCEPTION 'Existing address (%) detected. Cannot continue.',NEW."address";
				END IF;
				
				SELECT "systems"."systems"."owner" INTO Owner
				FROM "systems"."interfaces"
				JOIN "systems"."systems" ON
				"systems"."systems"."system_name" = "systems"."interfaces"."system_name"
				WHERE "systems"."interfaces"."mac" = NEW."mac";

				INSERT INTO "ip"."addresses" ("address","owner") VALUES (NEW."address",Owner);
			END IF;
			
			-- Remove old autoconf addresses
			IF OLD."config" ~* 'autoconf' THEN
				DELETE FROM "ip"."addresses" WHERE "address" = OLD."address";
			END IF;
		END IF;
		
		-- Check for IPv6 secondary name
		/*
		IF NEW."family" = 6 AND NEW."isprimary" = FALSE THEN
			SELECT "name" INTO PrimaryName
			FROM "systems"."interface_addresses"
			WHERE "systems"."interface_addresses"."mac" = NEW."mac"
			AND "systems"."interface_addresses"."isprimary" = TRUE;
			IF NEW."name" != PrimaryName THEN
				RAISE EXCEPTION 'IPv6 secondaries must have the same interface name (%) as the primary (%)',NEW."name",PrimaryName;
			END IF;
		END IF;			
		*/
		RETURN NEW;
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "systems"."interface_addresses_update"() IS 'Modify an existing address based on a very complex ruleset';
