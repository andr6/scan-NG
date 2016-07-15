### extention of bro-1.5.3 landmine and bro-2.x darknet.bro 

module Scan; 

@load base/protocols/conn
#@load site-subnets.bro 

export 
{ 
	global activate_LandMine = F &redef;

        const landmine_thresh_trigger = 5 &redef;
        const landmine_address: set[addr] &redef;

	redef enum Notice::Type += {
                LandMine,       # source touched a landmine destination
		LandMineSummary, # aggregate of landmine scanner

	}; 

	#global darknet_v6: set [subnet] = { [2001:400:613:18::]/64, }; 
	#global darknet_scanners: table [addr] of  set[addr] ; 
	#global known_scanners: table[addr] of count &create_expire=1 day &redef ; 

	
	global landmine_scan_summary:
                function(t: table[addr] of set[addr], orig: addr): interval;

        global landmine_distinct_peers: table[addr] of set[addr]
                &read_expire = 1 day &expire_func=landmine_scan_summary &redef;


	###	Expire functions that trigger summaries.
        global c_landmine_scan_summary:
                function(t: table[addr] of set[addr], orig: addr): interval;

	global c_landmine_distinct_peers: table[addr] of opaque of cardinality 
		&default = function(n: any): opaque of cardinality { return hll_cardinality_init(0.1, 0.99); }
                &read_expire = 1 days  &expire_func=c_landmine_scan_summary ; 

	global ignore_src_ports: set [port] = { 53/tcp, 53/udp} &redef ;

	# atleast these many subnets in the active subnets table 
	const MIN_SUBNET_CHECK=1 ; 

	global check_LandMine:function (cid: conn_id, established: bool, reversed: bool ): bool ; 
 	global filterate_LandMineScan: function(c: connection, darknet: bool ): string ; 
} 

function landmine_scan_summary(t: table[addr] of set[addr], orig: addr): interval
{
        return 0 secs;
}


function c_landmine_scan_summary(t: table[addr] of set[addr], orig: addr): interval
{
        return 0 secs;
}


function check_landmine_scan(orig: addr, d_port: port, resp: addr): bool 
{

	 if (gather_statistics)
                s_counters$c_land_core += 1  ;
	
	# prevent manager to keep firing events if already a scanner
        if (orig in known_scanners && Scan::known_scanners[orig]$status) 
        	{
                #local rmsg = fmt ("landmine: known_scanner T: for %s, %s, %s", orig, d_port, resp);
                #log_reporter(rmsg, 0);
                return F ;
        	}

	#local iplist = "" ; 

	local d_val = double_to_count(hll_cardinality_estimate(c_landmine_distinct_peers[orig])) ;

	if (d_val > landmine_thresh_trigger)
		return T ; 

#	if (|landmine_distinct_peers[orig]| > landmine_thresh_trigger )
#	{	
		#for (ip in landmine_distinct_peers[orig])
		#{
		  #iplist += fmt (" %s", ip); 
		#} 

#	       local msg = fmt("landmine address trigger %s [%s] %s", orig, d_port, iplist );
		#NOTICE([$note=LandMine, $src=orig, $src_peer=get_local_event_peer(), $msg=msg, $identifier=cat(orig)]);
		#log_reporter (fmt ("NOTICE: FOUND LandMine : %s", orig),0); 
#
		#add_to_known_scanners(orig, "LandMine");
		#Scan::known_scanners[orig]$detect_ts=network_time(); 
		#log_reporter(fmt("landmine scanner detected at %s, %s on %s", orig, Scan::known_scanners[orig]$detect_ts, peer_description),0);

#		return T ; 
#	} 

	return F ; 
} 

function check_LandMine(cid: conn_id, established: bool, reversed: bool ): bool 
{

	 if (gather_statistics)
                s_counters$c_land_checkscan += 1  ;

	local result  = F; 

	local orig=cid$orig_h ; 
	local resp=cid$resp_h ; 
	local d_port =cid$resp_p ; 	

	if (orig in known_scanners && Scan::known_scanners[orig]$status) 
		{ 	return F;   } 
	

	if (enable_big_tables) 
	{ 
		if ([orig] !in landmine_distinct_peers)
			landmine_distinct_peers[orig]=set() &mergeable;
			
		if([resp] !in landmine_distinct_peers[orig])
		{
			add landmine_distinct_peers[orig][resp]; 
			result = check_landmine_scan(orig, d_port, resp) ; 
		
			local iplist = "" ; 

			if (result)
			{ 
				for (ip in landmine_distinct_peers[orig])
				{
				  iplist += fmt (" %s", ip);
				}

			       local msg = fmt("landmine address trigger %s [%s] %s", orig, d_port, iplist );
				NOTICE([$note=LandMine, $src=orig, $src_peer=get_local_event_peer(), $msg=msg, $identifier=cat(orig)]);
				log_reporter (fmt ("NOTICE: FOUND LandMine : %s", orig),0);

				#add_to_known_scanners(orig, "LandMine");
				#Scan::known_scanners[orig]$detect_ts=network_time();

			} 
		} 
	} 

	################## 

	if ([orig] !in c_landmine_distinct_peers)
	{
		local cp: opaque of cardinality = hll_cardinality_init(0.1, 0.99); 
                c_landmine_distinct_peers[orig]=cp ; 
	} 

	hll_cardinality_add(c_landmine_distinct_peers[orig], resp);	

	result = check_landmine_scan(orig, d_port, resp) ;

	local d_val = double_to_count(hll_cardinality_estimate(c_landmine_distinct_peers[orig])) ;
	
	if (d_val  > landmine_thresh_trigger)  
	{	
		msg=fmt ("Landmine hit by %s", orig); 
		NOTICE([$note=LandMine, $src=orig, $src_peer=get_local_event_peer(), $msg=msg, $identifier=cat(orig)]);
		#add_to_known_scanners(orig, "LandMine");
		#Scan::known_scanners[orig]$detect_ts=network_time(); 
		#log_reporter(fmt("landmine scanner detected at %s, %s on %s", orig, Scan::known_scanners[orig]$detect_ts, peer_description),0);
		return T ; 

	}

	return result  ; 
}

function filterate_LandMineScan(c: connection, darknet: bool ): string 
{ 

	 if (gather_statistics)
                s_counters$c_land_filterate += 1  ;

        local orig = c$id$orig_h ; 
        local resp = c$id$resp_h ; 
	
	local orig_p = c$id$orig_p ;
        local resp_p = c$id$resp_p ;


	# prevent manager to keep firing events if already a scanner
        if (orig in Scan::known_scanners)
		if (Scan::known_scanners[orig]$status) 
		{
                #local rmsg = fmt ("landmine: known_scanner T: for %s, %s, %s", orig, resp_p, resp);
                #log_reporter(rmsg, 0);
		return "" ;
		}


	if (! darknet) 
	{ 

		# limita tion - works good only for tcp with minimal false positive 
		# for udp see  - udp-scan.bro 
		
		if (get_port_transport_proto(c$id$resp_p) != tcp) 
			return ""; 

		if (c?$conn && c$conn?$conn_state && /SF/ in c$conn$conn_state)
		{ return ""; } 
	} 

	### min membership check if subnets-txt file is loaded 	
	### TODO: raise an alarm or take corrective actions 
	### right now made failsafe - atleast 1 subnet needed 

	if (|Site::subnet_table| < MIN_SUBNET_CHECK) 
	{ 
		#local msg = fmt("Site::subnet_table is %d size which is below threshold. Deactivating LandMine Check", |Site::subnet_table|); 
		#event reporter_info(network_time(), msg, peer_description);
		return ""; 
	} 

	
	if (orig in distinct_backscatter_peers)
		if (orig_p in distinct_backscatter_peers[orig])
			if (|distinct_backscatter_peers[orig][orig_p]| < 2)
				return "" ;

	if (Site::is_local_addr(resp) && resp !in Site::subnet_table)
	{
		if ((is_failed(c) || is_reverse_failed(c) ) ) 
		{ 
			#add_to_landmine_cache(orig, resp_p, resp) ; 
			return "L" ; 
		}
	}

	return ""; 

	### TODO: for future - add liveNet identification for in case subnet or parts of subnet from darknet 
	### wakes up 
}


#@if ( ! Cluster::is_enabled())
#event connection_state_remove(c: connection)
#{
#	filterate_LandMine(c); 
#}
#@endif 


#const TCP_INACTIVE = 0; ##< Endpoint is still inactive.
#const TCP_SYN_SENT = 1; ##< Endpoint has sent SYN.
#const TCP_SYN_ACK_SENT = 2;     ##< Endpoint has sent SYN/ACK.
#const TCP_PARTIAL = 3;  ##< Endpoint has sent data but no initial SYN.
#const TCP_ESTABLISHED = 4;      ##< Endpoint has finished initial handshake regularly.
#const TCP_CLOSED = 5;   ##< Endpoint has closed connection.
#const TCP_RESET = 6;    ##< Endpoint has sent RST.

# UDP values for :bro:see:`endpoint` *state* field.
# todo:: these should go into an enum to make them autodoc'able.
#const UDP_INACTIVE = 0; ##< Endpoint is still inactive.
#const UDP_ACTIVE = 1;   ##< Endpoint has sent something.


# vern's original landline detector from 1.5.3 era 
# if ( activate_landmine_check &&
#     n >= landmine_thresh_trigger &&
#     mask_addr(resp, 24) in landmine_address )
#       {
#       local msg2 = fmt("landmine address trigger %s%s ", orig, svc);
#       NOTICE([$note=LandMine, $src=orig,
#               $p=service, $msg=msg2]);
#       }

