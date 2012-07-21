/* api_dns_utility.sql
	1) get_reverse_domain
	2) validate_domain
	3) validate_srv
*/

/* API - get_reverse_domain */
CREATE OR REPLACE FUNCTION "api"."get_reverse_domain"(INET) RETURNS TEXT AS $$
	use strict;
	use warnings;
	use Net::IP;
	use Net::IP qw(:PROC);

	# Return the rdns string for nsupdate from the given address. Automagically figures out IPv4 and IPv6.
	my $reverse_domain = new Net::IP ($_[0])->reverse_ip() or die (Net::IP::Error());
	$reverse_domain =~ s/\.$//;
	return $reverse_domain;

$$ LANGUAGE 'plperlu';
COMMENT ON FUNCTION "api"."get_reverse_domain"(inet) IS 'Use a convenient Perl module to generate and return the RDNS record for a given address';

/* API - validate_domain */
CREATE OR REPLACE FUNCTION "api"."validate_domain"(hostname text, domain text) RETURNS BOOLEAN AS $$
	use strict;
	use warnings;
	use Data::Validate::Domain qw(is_domain);
	# die("LOLZ");

	# Usage: PERFORM api.validate_domain([hostname OR NULL],[domain OR NULL]);

	# Declare the string to check later on
	my $domain;

	# This script can deal with just domain validation rather than host-domain. Note that the
	# module this depends on requires a valid TLD, so one is picked for this purpose.
	if (!$_[0])
	{
		# We are checking a domain name only
		$domain = $_[1];
	}
	elsif (!$_[1])
	{
		# We are checking a hostname only
		$domain = "$_[0].me";
	}
	else
	{
		# We have enough for a FQDN
		$domain = "$_[0].$_[1]";
	}

	# Return a boolean value of whether the input forms a valid domain
	if (is_domain($domain))
	{
		return 'TRUE';
	}
	else
	{
		# This module sucks and should be disabled
		#return 'TRUE';
		# Seems to be working normally... Keep an eye on your domain validation
		return 'FALSE';
	}
$$ LANGUAGE 'plperlu';
COMMENT ON FUNCTION "api"."validate_domain"(text, text) IS 'Validate hostname, domain, FQDN based on known rules. Requires Perl module';

/* API - validate_srv */
CREATE OR REPLACE FUNCTION "api"."validate_srv"(TEXT) RETURNS BOOLEAN AS $$
	my $srv = $_[0];
	my @parts = split('\.',$srv);

	# Check for two parts: the service and the transport
	if (scalar(@parts) ne 2)
	{
		die "Improper number of parts in record\n"
	}

	# Define parts of the record
	my $service = $parts[0];
	my $transport = $parts[1];

	# Check if transport is valid
	if ($transport !~ m/_tcp|_udp/i)
	{
		return "false";
	}

	# Check that service is valid
	if ($service !~ m/^_[\w-]+$/i)
	{
		return "false";
	}
	
	# Good!
	return "true";
$$ LANGUAGE 'plperl';
COMMENT ON FUNCTION "api"."validate_srv"(text) IS 'Validate SRV records';

/* API - dns_resolve */
CREATE OR REPLACE FUNCTION "api"."dns_resolve"(input_hostname text, input_zone text, input_family integer) RETURNS INET AS $$
	BEGIN
		IF input_family IS NULL THEN
			RETURN (SELECT "address" FROM "dns"."a" WHERE "hostname" = input_hostname AND "zone" = input_zone LIMIT 1);
		ELSE
			RETURN (SELECT "address" FROM "dns"."a" WHERE "hostname" = input_hostname AND "zone" = input_zone AND family("address") = input_family);
		END IF;
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."dns_resolve"(text, text, integer) IS 'Resolve a hostname/zone to its IP address';

CREATE OR REPLACE FUNCTION "api"."nsupdate"(zone text, keyname text, key text, server inet, action text, record text) RETURNS TEXT AS $$
	use strict;
	use warnings;
	use v5.10;
	use Net::DNS;
	no warnings('redefine');

	# Local variable information
	our $zone = shift(@_) or die("Invalid zone argument");
	our $keyname = shift(@_) or die("Invalid keyname argument");
	our $key = shift(@_) or die("Invalid key argument");
	our $server = shift(@_) or die("Invalid server argument");
	our $action = shift(@_) or die("Invalid action argument");
	our $record = shift(@_) or die("Invalid record argument");

	# DNS Server
	our $res = Net::DNS::Resolver->new;
	$res->nameservers($server);


	# Update packet
	our $update = Net::DNS::Update->new($zone);

	# Do something
	my $returnCode;
	if($action eq "DELETE") {
		$returnCode = &delete();
	}
	elsif($action eq "ADD") {
		$returnCode = &add();
	}
	else {
		$returnCode = "INVALID ACTION";
	}

	# Delete a record
	sub delete() {
		# The record must be there to delete it
		# $update->push(pre => yxrrset($record));

		# Delete the record
		$update->push(update => rr_del($record));

		# Sign it
		$update->sign_tsig($keyname, $key);

		# Send it
		&send();
	}

	# Add a record
	sub add() {
		# MX and TXT records will already exist. Otherwise the record you are 
		# creating should not already be in the zone. That would be silly.
		#
		# Frak it, you better be sure IMPULSE owns your DNS zone. Otherwise old records
		# WILL be overwriten.
		# 
		# if($record !~ m/\s(MX|TXT|NS)\s/) {
		# 	$update->push(pre => nxrrset($record));
		# }

		# Add the record
		$update->push(update => rr_add($record));

		# Sign it
		$update->sign_tsig($keyname, $key);

		# Send it
		&send();
	}

	# Send an update
	sub send() {
		my $reply = $res->send($update);
		if($reply) {
			if($reply->header->rcode eq 'NOERROR') {
				return 0;
			}
			else {
				return &interpret_error($reply->header->rcode);
			}
		}
		else {
			return &interpret_error($res->errorstring);
		}
	}

	# Interpret the error codes if any
	sub interpret_error() {
		my $error = shift(@_);

		given ($error) {
			when (/NXRRSET/) { return "Error $error: Name does not exist"; }
			when (/YXRRSET/) { return "Error $error: Name exists"; }
			when (/NOTAUTH/) { return "Error $error: Not authorized. Check system clocks and or key"; }
			default { return "$error unrecognized"; }
		}
	}

	return $returnCode;
$$ LANGUAGE 'plperlu';

/* API - check_dns_hostname */
CREATE OR REPLACE FUNCTION "api"."check_dns_hostname"(input_hostname text, input_zone text) RETURNS BOOLEAN AS $$
	DECLARE
		RowCount INTEGER := 0;
	BEGIN
		RowCount := RowCount + (SELECT COUNT(*) FROM "dns"."a" WHERE "hostname" = input_hostname AND "zone" = input_zone);
		RowCount := RowCount + (SELECT COUNT(*) FROM "dns"."srv" WHERE "alias" = input_hostname AND "zone" = input_zone);
		RowCount := RowCount + (SELECT COUNT(*) FROM "dns"."cname" WHERE "alias" = input_hostname AND "zone" = input_zone);

		IF RowCount = 0 THEN
			RETURN FALSE;
		ELSE
			RETURN TRUE;
		END IF;
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."check_dns_hostname"(text, text) IS 'Check if a hostname is available in a given zone';

/* API - nslookup*/
CREATE OR REPLACE FUNCTION "api"."nslookup"(input_address inet) RETURNS TABLE(fqdn TEXT) AS $$
	BEGIN
		RETURN QUERY (SELECT "hostname"||'.'||"zone" FROM "dns"."a" WHERE "address" = input_address);
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."nslookup"(inet) IS 'Get the DNS name of an IP address in the database';

CREATE OR REPLACE FUNCTION "api"."dns_forward_lookup"(text) RETURNS INET AS $$
	use Socket;

	my $hostname = $_[0];
	#my $ipaddr = `host $hostname | cut -d ' ' -f 4`;
	$packed_ip = gethostbyname("$hostname");
	if (defined $packed_ip) {
		$ip_address = inet_ntoa($packed_ip);
	}
	return $ip_address;
$$ LANGUAGE 'plperlu';

CREATE OR REPLACE FUNCTION "api"."query_address_reverse"(inet) RETURNS TEXT AS $$
	use strict;
	use warnings;
	use Net::DNS;
	use Net::IP;
	use Net::IP qw(:PROC);
	use v5.10;

	# Define some variables
	my $address = shift(@_) or die "Unable to get address";
	
	# Generate the reverse string (d.c.b.a.in-addr.arpa.)
	my $reverse = new Net::IP ($address)->reverse_ip() or die (Net::IP::Error());

	# Create the resolver
	my $res = Net::DNS::Resolver->new;

	# Run the query
	my $rr = $res->query($reverse,'PTR');

	# Check for a response
	if(!defined($rr)) {
		return;
	}

	# Parse the response
	my @answer = $rr->answer;
	foreach my $response(@answer) {
		return $response->ptrdname;
	}
$$ LANGUAGE 'plperlu';
COMMENT ON FUNCTION "api"."query_address_reverse"(inet) IS 'Print the forward host of a reverse lookup';

CREATE OR REPLACE FUNCTION "api"."query_axfr"(text, text) RETURNS SETOF "dns"."zone_audit_data" AS $$
	use strict;
	use warnings;
	use Net::DNS;
	use v5.10;
	use Data::Dumper;
	
	my $zone = shift(@_) or die "Unable to get zone";
	my $nameserver = shift(@_) or die "Unable to get nameserver for zone";

	my $res = Net::DNS::Resolver->new;
	$res->nameservers($nameserver);

	my @answer = $res->axfr($zone);

	foreach my $result (@answer) {
		&print_data($result);
	}

	sub print_data() {
		my $rr = $_[0];
		given($rr->type) {
			when (/^A|AAAA$/) {
				return_next({host=>$rr->name, ttl=>$rr->ttl, type=>$rr->type, address=>$rr->address});
			}
			when (/^CNAME$/) {
				return_next({host=>$rr->name,ttl=>$rr->ttl,type=>$rr->type,target=>$rr->cname});
			}
			when (/^SRV$/) {
				return_next({host=>$rr->name,ttl=>$rr->ttl,type=>$rr->type,priority=>$rr->priority,weight=>$rr->weight,port=>$rr->port,target=>$rr->target});
			}
			when (/^NS$/) {
				return_next({host=>$rr->nsdname, ttl=>$rr->ttl, type=>$rr->type});
			}
			when (/^MX$/) {
				return_next({host=>$rr->exchange, ttl=>$rr->ttl, type=>$rr->type, preference=>$rr->preference});
			}
			when (/^TXT$/) {
				return_next({host=>$rr->name, ttl=>$rr->ttl, type=>$rr->type, text=>$rr->char_str_list});
			}
			when (/^SOA$/) {
				return_next({host=>$rr->name, target=>$rr->mname, ttl=>$rr->ttl, contact=>$rr->rname, serial=>$rr->serial, refresh=>$rr->refresh, retry=>$rr->retry, expire=>$rr->expire, minimum=>$rr->minimum, type=>$rr->type});
			}
			when (/^PTR$/) {
				return_next({host=>$rr->name, target=>$rr->ptrdname, ttl=>$rr->ttl, type=>$rr->type});
			}
		}
	}
	return undef;
$$ LANGUAGE 'plperlu';
COMMENT ON FUNCTION "api"."query_axfr"(text, text) IS 'Query a nameserver for the DNS zone transfer to use for auditing';

CREATE OR REPLACE FUNCTION "api"."dns_zone_audit"(input_zone text) RETURNS SETOF "dns"."zone_audit_data" AS $$
       BEGIN
			-- Create a temporary table to store record data in
            DROP TABLE IF EXISTS "audit";
            CREATE TEMPORARY TABLE "audit" (
			host TEXT, ttl INTEGER, type TEXT, address INET, port INTEGER, weight INTEGER, priority INTEGER, preference INTEGER, target TEXT, text TEXT, contact TEXT, serial TEXT, refresh INTEGER, retry INTEGER, expire INTEGER, minimum INTEGER);
				   
			-- Put AXFR data into the table
			IF (SELECT "forward" FROM "dns"."zones" WHERE "zone" = input_zone) IS TRUE THEN
				INSERT INTO "audit"
				(SELECT * FROM "api"."query_axfr"(input_zone, (SELECT "nameserver" FROM "dns"."soa" WHERE "zone" = input_zone)));
			ELSE
				INSERT INTO "audit" (SELECT * FROM "api"."query_axfr"(input_zone, (SELECT "nameserver" FROM "dns"."soa" WHERE "zone" = (SELECT "zone" FROM "ip"."subnets" WHERE api.get_reverse_domain("subnet") = input_zone))));
			END IF;
			
			-- Update the SOA table with the latest serial
			PERFORM api.modify_dns_soa(input_zone,'serial',(SELECT "api"."query_zone_serial"(input_zone)));
			
			IF (SELECT "forward" FROM "dns"."zones" WHERE "zone" = input_zone) IS TRUE THEN
				-- Remove all records that IMPULSE contains
				DELETE FROM "audit" WHERE ("host","ttl","type","address") IN (SELECT "hostname"||'.'||"zone" AS "host","ttl","type","address" FROM "dns"."a");
				DELETE FROM "audit" WHERE ("host","ttl","type","target","port","weight","priority") IN (SELECT "alias"||'.'||"zone" AS "host","ttl","type","hostname"||'.'||"zone" as "target","port","weight","priority" FROM "dns"."srv");
				DELETE FROM "audit" WHERE ("host","ttl","type","target") IN (SELECT "alias"||'.'||"zone" AS "host","ttl","type","hostname"||'.'||"zone" as "target" FROM "dns"."cname");
				DELETE FROM "audit" WHERE ("host","ttl","type","preference") IN (SELECT "hostname"||'.'||"zone" AS "host","ttl","type","preference" FROM "dns"."mx");
				DELETE FROM "audit" WHERE ("host","ttl","type") IN (SELECT "nameserver" AS "host","ttl","type" FROM "dns"."ns");
				DELETE FROM "audit" WHERE ("host","ttl","type","text") IN (SELECT "hostname"||'.'||"zone" AS "host","ttl","type","text" FROM "dns"."txt");
				DELETE FROM "audit" WHERE ("host","ttl","type","target","contact","serial","refresh","retry","expire","minimum") IN 
				(SELECT "zone" as "host","ttl",'SOA'::text as "type","nameserver" as "target","contact","serial","refresh","retry","expire","minimum" FROM "dns"."soa");
				DELETE FROM "audit" WHERE ("host","ttl","type","text") IN (SELECT "hostname"||'.'||"zone" AS "host","ttl","type","text" FROM "dns"."zone_txt");
				DELETE FROM "audit" WHERE ("host","ttl","type","text") IN (SELECT "zone" AS "host","ttl","type","text" FROM "dns"."zone_txt");
				DELETE FROM "audit" WHERE ("host","ttl","type","address") IN (SELECT "zone" AS "host","ttl","type","address" FROM "dns"."zone_a");
				
				-- DynamicDNS records have TXT data placed by the DHCP server. Don't count those.
				DELETE FROM "audit" WHERE ("host") IN (SELECT "hostname"||'.'||"zone" AS "host" FROM "api"."get_dhcpd_dynamic_hosts"() WHERE "hostname" IS NOT NULL) AND "type" = 'TXT';
				-- So do DHCP'd records;
				DELETE FROM "audit" WHERE ("host") IN (SELECT "hostname"||'.'||"zone" AS "host" FROM "dns"."a" JOIN "systems"."interface_addresses" ON "systems"."interface_addresses"."address" = "dns"."a"."address" WHERE "config"='dhcp') AND "type"='TXT';
			ELSE
				-- Remove constant address records
				DELETE FROM "audit" WHERE ("host","target","type") IN (SELECT api.get_reverse_domain("address") as "host","hostname"||'.'||"zone" as "target",'PTR'::text AS "type" FROM "dns"."a");
				-- Remove Dynamics
				DELETE FROM "audit" WHERE ("target","type") IN (SELECT "hostname"||'.'||"zone" as "target",'PTR'::text AS "type" FROM "dns"."a" JOIN "systems"."interface_addresses" ON "systems"."interface_addresses"."address" = "dns"."a"."address" WHERE "config"='dhcp');
				-- Remove NS records;
				DELETE FROM "audit" WHERE ("host","ttl","type") IN (SELECT "nameserver" AS "host","ttl","type" FROM "dns"."ns");
				-- Remove SOA;
				DELETE FROM "audit" WHERE ("host","ttl","type","target","contact","serial","refresh","retry","expire","minimum") IN 
				(SELECT "zone" as "host","ttl",'SOA'::text as "type","nameserver" as "target","contact","serial","refresh","retry","expire","minimum" FROM "dns"."soa" WHERE "zone" = input_zone);
				-- Remove TXT
				DELETE FROM "audit" WHERE ("host","ttl","type","text") IN (SELECT "hostname"||'.'||"zone" AS "host","ttl","type","text" FROM "dns"."zone_txt");
				DELETE FROM "audit" WHERE ("host","ttl","type","text") IN (SELECT "zone" AS "host","ttl","type","text" FROM "dns"."zone_txt");
			END IF;
            
			-- What's left is data that IMPULSE has no idea of
            RETURN QUERY (SELECT * FROM "audit");
       END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."dns_zone_audit"(text) IS 'Perform an audit of IMPULSE zone data against server zone data';

CREATE OR REPLACE FUNCTION "api"."query_zone_serial"(text) RETURNS TEXT AS $$
	use strict;
	use warnings;
	use Net::DNS;
	
	# Get the zone
	my $zone = shift(@_) or die "Unable to get DNS zone to query";
	
	# Establish the resolver and make the query
	my $res = Net::DNS::Resolver->new;
	my $rr = $res->query($zone,'soa');

	# Check if it actually returned
	if(!defined($rr)) {
		die "Unable to find record for zone $zone";
	}
	
	# Spit out the serial
	my @answer = $rr->answer;
	return $answer[0]->serial;
$$ LANGUAGE 'plperlu';
COMMENT ON FUNCTION "api"."query_zone_serial"(text) IS 'Query this hosts resolver for the serial number of the zone.';

CREATE OR REPLACE FUNCTION "api"."dns_clean_zone_a"(input_zone text) RETURNS VOID AS $$
	DECLARE
		AuditData RECORD;
		DnsKeyName TEXT;
		DnsKey TEXT;
		DnsServer INET;
		DnsRecord TEXT;
		ReturnCode TEXT;
		
	BEGIN
		
		IF (api.get_current_user_level() !~* 'ADMIN') THEN
			RAISE EXCEPTION 'Non-admin users are not allowed to clean zones';
		END IF;
		
		SELECT "dns"."keys"."keyname","dns"."keys"."key","address" 
			INTO DnsKeyName, DnsKey, DnsServer
			FROM "dns"."ns" 
			JOIN "dns"."zones" ON "dns"."ns"."zone" = "dns"."zones"."zone" 
			JOIN "dns"."keys" ON "dns"."zones"."keyname" = "dns"."keys"."keyname"
			WHERE "dns"."ns"."zone" = input_zone AND "dns"."ns"."nameserver" IN (SELECT "nameserver" FROM "dns"."soa" WHERE "dns"."soa"."zone" = input_zone);
			
		FOR AuditData IN (
			SELECT 
				"audit_data"."address",
				"audit_data"."type",
				"host" AS "bind-forward", 
				"dns"."a"."hostname"||'.'||"dns"."a"."zone" AS "impulse-forward"
			FROM api.dns_zone_audit(input_zone) AS "audit_data" 
			LEFT JOIN "dns"."a" ON "dns"."a"."address" = "audit_data"."address" 
			WHERE "audit_data"."type" ~* '^A|AAAA$'
			ORDER BY "audit_data"."address"
		) LOOP
			-- Delete the forward
			DnsRecord := AuditData."bind-forward";
			ReturnCode := api.nsupdate(input_zone,DnsKeyName,DnsKey,DnsServer,'DELETE',DnsRecord);
			IF ReturnCode != '0' THEN
				RAISE EXCEPTION 'DNS Error: % when deleting forward %',ReturnCode,DnsRecord;
			END IF;
			
			-- If it's static, create the correct one
			IF (SELECT "config" FROM "systems"."interface_addresses" WHERE "address" = AuditData."address") ~* 'static' AND AuditData."impulse-forward" IS NOT NULL THEN
				-- Forward
				DnsRecord := AuditData."impulse-forward"||' '||AuditData."ttl"||' '||AuditData."type"||' '||host(AuditData."address");
				ReturnCode := api.nsupdate(input_zone,DnsKeyName,DnsKey,DnsServer,'ADD',DnsRecord);
				IF ReturnCode != '0' THEN
					RAISE EXCEPTION 'DNS Error: % when creating forward %',ReturnCode,DnsRecord;
				END IF;
			END IF;
		END LOOP;
		
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."dns_clean_zone_a"(text) IS 'Erase all non-IMPULSE controlled A records from a zone.';

CREATE OR REPLACE FUNCTION "api"."dns_clean_zone_ptr"(input_zone text) RETURNS VOID AS $$
	DECLARE
		AuditData RECORD;
		DnsKeyName TEXT;
		DnsKey TEXT;
		DnsServer INET;
		DnsRecord TEXT;
		ReturnCode TEXT;
		
	BEGIN
		
		IF (api.get_current_user_level() !~* 'ADMIN') THEN
			RAISE EXCEPTION 'Non-admin users are not allowed to clean zones';
		END IF;
		
		SELECT "dns"."keys"."keyname","dns"."keys"."key","dns"."ns"."address"
		INTO DnsKeyName, DnsKey, DnsServer
		FROM "dns"."ns"
		JOIN "dns"."zones" ON "dns"."ns"."zone" = "dns"."zones"."zone"
		JOIN "dns"."keys" ON "dns"."zones"."keyname" = "dns"."keys"."keyname"
		JOIN "dns"."soa" ON "dns"."soa"."zone" = "dns"."ns"."zone"
		WHERE "dns"."ns"."nameserver" = "dns"."soa"."nameserver"
		AND "dns"."ns"."zone" = (SELECT "ip"."subnets"."zone" FROM "ip"."subnets" WHERE api.get_reverse_domain("subnet") = input_zone);
	
		FOR AuditData IN (
			SELECT 
			"audit_data"."host",
			"audit_data"."target" AS "bind-reverse",
			"dns"."a"."hostname"||'.'||"dns"."a"."zone" AS "impulse-reverse",
			"dns"."a"."ttl" AS "ttl",
			"audit_data"."type" AS "type"
			FROM api.dns_zone_audit(input_zone) AS "audit_data"
			LEFT JOIN "dns"."a" ON api.get_reverse_domain("dns"."a"."address") = "audit_data"."host"
			WHERE "audit_data"."type"='PTR'
		) LOOP
			DnsRecord := AuditData."host";
			ReturnCode := api.nsupdate(input_zone,DnsKeyName,DnsKey,DnsServer,'DELETE',DnsRecord);
			IF ReturnCode != '0' THEN
				RAISE EXCEPTION 'DNS Error: % when deleting reverse %',ReturnCode,DnsRecord;
			END IF;
			
			IF (SELECT "config" FROM "systems"."interface_addresses" WHERE api.get_reverse_domain("address") = AuditData."host") ~* 'static' AND AuditData."impulse-reverse" IS NOT NULL THEN
				DnsRecord := AuditData."host"||' '||AuditData."ttl"||' '||AuditData."type"||' '||AuditData."impulse-reverse";
				ReturnCode := api.nsupdate(input_zone,DnsKeyName,DnsKey,DnsServer,'ADD',DnsRecord);
				IF ReturnCode != '0' THEN
					RAISE EXCEPTION 'DNS Error: % when creating reverse %',ReturnCode,DnsRecord;
				END IF;
			END IF;
			
		END LOOP;
	END;
$$ LANGUAGE 'plpgsql';
COMMENT ON FUNCTION "api"."dns_clean_zone_ptr"(text) IS 'Clean all incorrect pointer records in a reverse zone';

CREATE OR REPLACE FUNCTION "api"."resolve"(text) RETURNS INET AS $$
	use strict;
	use warnings;
	use Socket qw(inet_ntoa);
	
	my $hostname = shift() or die "Unable to get name argument";
	my ($name,$aliases,$addrtype,$length,@addrs) = gethostbyname($hostname);
	return inet_ntoa($addrs[0]);
$$ LANGUAGE 'plperlu';
