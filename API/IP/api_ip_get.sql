/* api_ip_get.sql
	1) get_address_from_range
	2) get_subnet_addresses
	3) get_range_addresses
*/

/* API - get_address_from_range
	1) Dynamic addressing for ipv4
	2) Get range bounds
	3) Get address from range
	4) Check if range was full
*/
CREATE OR REPLACE FUNCTION "api"."get_address_from_range"(input_range_name text) RETURNS INET AS $$
	DECLARE
		LowerBound INET;
		UpperBound INET;
		AddressToUse INET;
	BEGIN
		-- Dynamic Addressing for ipv4
		IF (SELECT "use" FROM "ip"."ranges" WHERE "name" = input_range_name) = 'ROAM' 
		AND (SELECT family("subnet") FROM "ip"."ranges" WHERE "name" = input_range_name) = 4 THEN
			SELECT "address" INTO AddressToUse FROM "ip"."addresses" 
			WHERE "address" << cidr(api.get_site_configuration('DYNAMIC_SUBNET'))
			AND "address" NOT IN (SELECT "address" FROM "systems"."interface_addresses") ORDER BY "address" ASC LIMIT 1;
			RETURN AddressToUse;
		END IF;

		-- Get range bounds
		SELECT "first_ip","last_ip" INTO LowerBound,UpperBound
		FROM "ip"."ranges"
		WHERE "ip"."ranges"."name" = input_range_name;

		-- Get address from range
		SELECT "address" FROM "ip"."addresses" INTO AddressToUse
		WHERE "address" <= UpperBound AND "address" >= LowerBound
		AND "address" NOT IN (SELECT "address" FROM "systems"."interface_addresses") ORDER BY "address" ASC LIMIT 1;

		-- Check if range was full (AddressToUse will be NULL)
		IF AddressToUse IS NULL THEN
			RAISE EXCEPTION 'All addresses in range % are in use',input_range_name;
		END IF;

		-- Done
		RETURN AddressToUse;
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."get_address_from_range"(text) IS 'get the first available address in a range';


/* API - get_address_range */
CREATE OR REPLACE FUNCTION "api"."get_address_range"(input_address inet) RETURNS TEXT AS $$
	BEGIN
		RETURN (SELECT "name" FROM "ip"."ranges" WHERE "first_ip" <= input_address AND "last_ip" >= input_address);
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."get_address_range"(inet) IS 'Get the name of the range an address is in';

/* API - get_ip_ranges */
CREATE OR REPLACE FUNCTION "api"."get_ip_ranges"() RETURNS SETOF "ip"."ranges" AS $$
	BEGIN
		RETURN QUERY (SELECT * FROM "ip"."ranges" ORDER BY "first_ip");
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."get_ip_ranges"() IS 'Get all configured IP ranges';

/* API - get_ip_subnets */
CREATE OR REPLACE FUNCTION "api"."get_ip_subnets"(input_username text) RETURNS SETOF "ip"."subnets" AS $$
	BEGIN
		IF input_username IS NULL THEN
			RETURN QUERY (SELECT * FROM "ip"."subnets" ORDER BY "subnet");
		ELSE
			RETURN QUERY (SELECT * FROM "ip"."subnets" WHERE "owner" = input_username ORDER BY "subnet");
		END IF;
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."get_ip_subnets"(text) IS 'Get all IP subnet data';

/* API - get_ip_range_uses */
CREATE OR REPLACE FUNCTION "api"."get_ip_range_uses"() RETURNS SETOF TEXT AS $$
	BEGIN
		RETURN QUERY (SELECT text("use") FROM "ip"."range_uses");
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."get_ip_range_uses"() IS 'Get a list of all use codes';

/* API - get_ip_range_total */
CREATE OR REPLACE FUNCTION "api"."get_ip_range_total"(input_range text) RETURNS integer AS $$
	BEGIN
		RETURN (SELECT COUNT(api.get_address_range("address"))
		FROM "ip"."addresses"
		WHERE api.get_address_range("address") ~* input_range);
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."get_ip_range_total"(text) IS 'Get the number of possible addresses in a particiular range';

CREATE OR REPLACE FUNCTION api.get_range_utilization(input_range text) RETURNS TABLE(inuse integer, free integer, total integer) AS $$
	BEGIN
		RETURN QUERY (
			SELECT COUNT("systems"."interface_addresses"."address")::integer AS "inuse",
			(api.get_ip_range_total(input_range) - COUNT("systems"."interface_addresses"."address"))::integer AS "free",
			api.get_ip_range_total(input_range)::integer AS "total"
			FROM "systems"."interface_addresses" 
			WHERE api.get_address_range("address") = input_range);
	END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION api.get_range_utilization(text) IS 'Get statistics on range utilization';

CREATE OR REPLACE FUNCTION api.get_subnet_utilization(input_subnet cidr) RETURNS TABLE(inuse integer, free integer, total integer) AS $$
	DECLARE
		addrcount INTEGER;
	BEGIN
		-- Total
		SELECT COUNT("address")::integer INTO addrcount
		FROM "ip"."addresses" WHERE "address" << input_subnet;
		
		RETURN QUERY (
			SELECT COUNT("systems"."interface_addresses"."address"):: integer AS "inuse",
			addrcount - COUNT("systems"."interface_addresses"."address"):: integer as "free",
			addrcount AS "total"
			FROM "systems"."interface_addresses"
			WHERE "address" << input_subnet
		);
	END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION api.get_subnet_utilization(cidr) IS 'Get statistics on subnet utilization';

CREATE OR REPLACE FUNCTION "api"."get_group_ranges"(input_group text) RETURNS SETOF "ip"."ranges" AS $$
	BEGIN
		RETURN QUERY (SELECT * FROM "ip"."ranges" WHERE "name" IN (SELECT "range_name" FROM "ip"."range_groups" WHERE "group_name" = input_group) ORDER BY "name");
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."get_group_ranges"(text) IS 'Get group range information';

CREATE OR REPLACE FUNCTION "api"."get_range_groups"(input_name text) RETURNS SETOF "management"."groups" AS $$
    BEGIN
        RETURN QUERY (SELECT * FROM "management"."groups" WHERE "group" IN (SELECT "group_name" FROM "ip"."range_groups" WHERE "range_name" = input_name) ORDER BY "group");
    END;
$$ LANGUAGE 'plpgsql';

CREATE OR REPLACE FUNCTION "api"."get_user_ranges"(input_user text) RETURNS SETOF "ip"."ranges" AS $$
	DECLARE
		UserGroups RECORD;
		GroupRanges RECORD;
		RangeData RECORD;
	BEGIN
		--IF api.get_current_user_level() ~* 'ADMIN' THEN
		--	RETURN QUERY (SELECT * FROM "ip"."ranges" ORDER BY "name");
		--END IF;

		FOR UserGroups IN (SELECT "group" FROM "management"."group_members" WHERE "user" = input_user) LOOP
			FOR RangeData IN (SELECT * FROM api.get_group_ranges(UserGroups."group")) LOOP
				RETURN NEXT RangeData;
			END LOOP;
		END LOOP;

		RETURN;
	END;
$$ LANGUAGE 'plpgsql';

CREATE OR REPLACE FUNCTION "api"."get_range_top_users"(input_name text) RETURNS TABLE ("user" text, "count" integer) AS $$
	BEGIN
		RETURN QUERY(
			 SELECT 
			 	api.get_interface_address_owner(address),
			 	count(api.get_interface_address_owner(address))::integer
			 FROM
			 	systems.interface_addresses
			 WHERE api.get_address_range(address) = input_name
			 GROUP BY api.get_interface_address_owner(address)
			 ORDER BY count(api.get_interface_address_owner(address))
			 DESC limit 10
		);
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."get_range_top_users"(text) IS 'Get the top 10 users of range addresses';

-- Adapted from functions written by Stephen Clark of NetWolves from the PostgreSQL community forums
CREATE OR REPLACE FUNCTION "api"."get_ip_mask_bits"(input_subnet inet) RETURNS INTEGER AS $$
    DECLARE
        t1 TEXT;
        t2 TEXT;
        t3 TEXT;
        t4 TEXT;
        i BIGINT;
        n INTEGER;
    BEGIN
        IF family(input_subnet) != 4 THEN
            RAISE EXCEPTION 'Can only get mask bits of an IPv4 address';
        END IF;

        t1 := SPLIT_PART(HOST(input_subnet), '.',1);
        t2 := SPLIT_PART(HOST(input_subnet), '.',2);
        t3 := SPLIT_PART(HOST(input_subnet), '.',3);
        t4 := SPLIT_PART(HOST(input_subnet), '.',4);
        i := (t1::BIGINT << 24) + (t2::BIGINT << 16) +
                (t3::BIGINT << 8) + t4::BIGINT;
        n := (32-log(2, 4294967296 - i ))::integer;

        RETURN n;
    END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."get_ip_mask_bits"(inet) IS 'Get the number of bits in a subnet mask';
