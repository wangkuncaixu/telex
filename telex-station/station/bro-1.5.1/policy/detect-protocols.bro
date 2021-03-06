# $Id: detect-protocols.bro,v 1.1.4.4 2006/05/31 18:07:27 sommer Exp $
#
# Finds connections with protocols on non-standard ports using the DPM
# framework.

@load site

@load conn-id
@load notice

module ProtocolDetector;

export {
	redef enum Notice += {
		ProtocolFound,	# raised for each connection found
		ServerFound,	# raised once per dst host/port/protocol tuple
	};

	# Table of (protocol, resp_h, resp_p) tuples known to be uninteresting
	# in the given direction.  For all other protocols detected on
	# non-standard ports, we raise a ProtocolFound notice.  (More specific
	# filtering can then be done via notice_filters.)
	#
	# Use 0.0.0.0 for to wildcard-match any resp_h.

	type dir: enum { NONE, INCOMING, OUTGOING, BOTH };

	const valids: table[count, addr, port] of dir = {
		# A couple of ports commonly used for benign HTTP servers.

		# For now we want to see everything.

		# [ANALYZER_HTTP, 0.0.0.0, 81/tcp] = OUTGOING,
		# [ANALYZER_HTTP, 0.0.0.0, 82/tcp] = OUTGOING,
		# [ANALYZER_HTTP, 0.0.0.0, 83/tcp] = OUTGOING,
		# [ANALYZER_HTTP, 0.0.0.0, 88/tcp] = OUTGOING,
		# [ANALYZER_HTTP, 0.0.0.0, 8001/tcp] = OUTGOING,
		# [ANALYZER_HTTP, 0.0.0.0, 8090/tcp] = OUTGOING,
		# [ANALYZER_HTTP, 0.0.0.0, 8081/tcp] = OUTGOING,
		#
		# [ANALYZER_HTTP, 0.0.0.0, 6346/tcp] = BOTH, # Gnutella
		# [ANALYZER_HTTP, 0.0.0.0, 6347/tcp] = BOTH, # Gnutella
		# [ANALYZER_HTTP, 0.0.0.0, 6348/tcp] = BOTH, # Gnutella
	} &redef;

	# Set of analyzers for which we suppress ServerFound notices
	# (but not ProtocolFound).  Along with avoiding clutter in the
	# log files, this also saves memory because for these we don't
	# need to remember which servers we already have reported, which
	# for some can be a lot.
	const suppress_servers: set [count] = {
		# ANALYZER_HTTP
	} &redef;

	# We consider a connection to use a protocol X if the analyzer for X
	# is still active (i) after an interval of minimum_duration, or (ii)
	# after a payload volume of minimum_volume, or (iii) at the end of the
	# connection.
	const minimum_duration = 30 secs &redef;
	const minimum_volume = 4e3 &redef;	# bytes

	# How often to check the size of the connection.
	const check_interval = 5 secs;

	# Entry point for other analyzers to report that they recognized
	# a certain (sub-)protocol.
	global found_protocol: function(c: connection, analyzer: count,
					protocol: string);

	# Table keeping reported (server, port, analyzer) tuples (and their
	# reported sub-protocols).
	global servers: table[addr, port, string] of set[string]
				&read_expire = 14 days;
}

# Table that tracks currently active dynamic analyzers per connection.
global conns: table[conn_id] of set[count];

# Table of reports by other analyzers about the protocol used in a connection.
global protocols: table[conn_id] of set[string];

type protocol : record {
	a: string;	# analyzer name
	sub: string;	# "sub-protocols" reported by other sources
};

function get_protocol(c: connection, a: count) : protocol
	{
	local str = "";
	if ( c$id in protocols )
		{
		for ( p in protocols[c$id] )
			str = |str| > 0 ? fmt("%s/%s", str, p) : p;
		}

	return [$a=analyzer_name(a), $sub=str];
	}

function fmt_protocol(p: protocol) : string
	{
	return p$sub != "" ? fmt("%s (via %s)", p$sub, p$a) : p$a;
	}

function do_notice(c: connection, a: count, d: dir)
	{
	if ( d == BOTH )
		return;

	if ( d == INCOMING && is_local_addr(c$id$resp_h) )
		return;

	if ( d == OUTGOING && ! is_local_addr(c$id$resp_h) )
		return;

	local p = get_protocol(c, a);
	local s = fmt_protocol(p);

	NOTICE([$note=ProtocolFound,
		$msg=fmt("%s %s on port %s", id_string(c$id), s, c$id$resp_p),
		$sub=s, $conn=c, $n=a]);

	# We report multiple ServerFound's per host if we find a new
	# sub-protocol.
	local known = [c$id$resp_h, c$id$resp_p, p$a] in servers;

	local newsub = F;
	if ( known )
		newsub = (p$sub != "" &&
			  p$sub !in servers[c$id$resp_h, c$id$resp_p, p$a]);

	if ( (! known || newsub) && a !in suppress_servers )
		{
		NOTICE([$note=ServerFound,
			$msg=fmt("%s: %s server on port %s%s", c$id$resp_h, s,
				c$id$resp_p, (known ? " (update)" : "")),
			$p=c$id$resp_p, $sub=s, $conn=c, $src=c$id$resp_h, $n=a]);

		if ( ! known )
			servers[c$id$resp_h, c$id$resp_p, p$a] = set();

		add servers[c$id$resp_h, c$id$resp_p, p$a][p$sub];
		}
	}

function report_protocols(c: connection)
	{
	# We only report the connection if both sides have transferred data.
	if ( c$resp$size == 0 || c$orig$size == 0 )
		{
		delete conns[c$id];
		delete protocols[c$id];
		return;
		}

	local analyzers = conns[c$id];

	for ( a in analyzers )
		{
		if ( [a, c$id$resp_h, c$id$resp_p] in valids )
			do_notice(c, a, valids[a, c$id$resp_h, c$id$resp_p]);

		else if ( [a, 0.0.0.0, c$id$resp_p] in valids )
			do_notice(c, a, valids[a, 0.0.0.0, c$id$resp_p]);
		else
			do_notice(c, a, NONE);

		append_addl(c, analyzer_name(a));
		}

	delete conns[c$id];
	delete protocols[c$id];
	}

event ProtocolDetector::check_connection(c: connection)
	{
	if ( c$id !in conns )
		return;

	local duration = network_time() - c$start_time;
	local size = c$resp$size + c$orig$size;

	if ( duration >= minimum_duration || size >= minimum_volume )
		report_protocols(c);
	else
		{
		local delay = min_interval(minimum_duration - duration,
					   check_interval);
		schedule delay { ProtocolDetector::check_connection(c) };
		}
	}

event connection_state_remove(c: connection)
	{
	if ( c$id !in conns )
		{
		delete protocols[c$id];
		return;
		}

	# Reports all analyzers that have remained to the end.
	report_protocols(c);
	}

event protocol_confirmation(c: connection, atype: count, aid: count)
	{
	# Don't report anything running on a well-known port.
	if ( atype in dpd_config && c$id$resp_p in dpd_config[atype]$ports )
		return;

	if ( c$id in conns )
		{
		local analyzers = conns[c$id];
		add analyzers[atype];
		}
	else
		{
		conns[c$id] = set(atype);

		local delay = min_interval(minimum_duration, check_interval);
		schedule delay { ProtocolDetector::check_connection(c) };
		}
	}

# event connection_analyzer_disabled(c: connection, analyzer: count)
# 	{
# 	if ( c$id !in conns )
# 		return;
# 
# 	delete conns[c$id][analyzer];
# 	}

function append_proto_addl(c: connection)
	{
	for ( a in conns[c$id] )
		append_addl(c, fmt_protocol(get_protocol(c, a)));
	}

function found_protocol(c: connection, analyzer: count, protocol: string)
	{
	# Don't report anything running on a well-known port.
	if ( analyzer in dpd_config &&
	     c$id$resp_p in dpd_config[analyzer]$ports )
		return;

	if ( c$id !in protocols )
		protocols[c$id] = set();

	add protocols[c$id][protocol];
	}

event connection_state_remove(c: connection)
	{
	if ( c$id !in conns )
		return;

	append_proto_addl(c);
	}

