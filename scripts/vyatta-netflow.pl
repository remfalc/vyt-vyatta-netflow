#!/usr/bin/perl
#
# Module: vyatta-netflow.pl
# 
# **** License ****
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
# 
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
# 
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2009 Vyatta, Inc.
# All Rights Reserved.
# 
# Author: Stig Thormodsrud
# Date: June 2009
# Description: Script to configure netflow/sflow (pmacct).
# 
# **** End License ****
#

use Getopt::Long;
use POSIX;

use lib '/opt/vyatta/share/perl5';
use Vyatta::Config;
use Vyatta::Netflow;
use Vyatta::Interface;

use warnings;
use strict;

# Default ports for netflow/sflow
my $def_nf_port = 2100;
my $def_sf_port = 6343;


sub acct_conf_globals {
    my ($intf) = @_;

    my $output = '';
    my $pid_file  = acct_get_pid_file($intf);
    my $pipe_file = acct_get_pipe_file($intf);

    $output .= "!\n! autogenerated by $0\n!\n";
    $output .= "daemonize: true\n";
    $output .= "promisc:   false\n";
    $output .= "pidfile:   $pid_file\n";
    $output .= "imt_path:  $pipe_file\n";
    $output .= "aggregate: src_host,dst_host,src_port,dst_port";
    $output .= ",proto,tos,flows\n";
    return $output;
}

my %timeout_hash = (
    'tcp-generic'     => 'tcp',
    'tcp-rst'         => 'tcp.rst',
    'tcp-fin'         => 'tcp.fin',
    'udp'             => 'udp',
    'icmp'            => 'icmp',
    'flow-generic'    => 'general',
    'max-active-life' => 'maxlife',
    'expiry-interval' => 'expint',
);

sub acct_get_netflow {
    my ($intf, $config) = @_;

    my $path   = 'system accounting';
    my $output = undef;

    $config->setLevel($path);
    return $output if ! $config->exists('netflow');

    $config->setLevel("$path netflow");   
    my $version = $config->returnValue('version');
    $output .= "nfprobe_version: $version\n" if defined $version;

    my $engine_id = $config->returnValue('engine-id');
    $engine_id = 0 if ! defined $engine_id;
    my $engine_type = `ip link show $intf | grep $intf | cut -d : -f 1`;
    chomp $engine_type;
    $output .= "nfprobe_engine: $engine_id:$engine_type\n";

    $config->setLevel("$path netflow server");   
    my @servers = $config->listNodes();
    if (scalar(@servers)) {
	foreach my $server (@servers) {
	    $config->setLevel("$path netflow server $server");   
	    my $port = $config->returnValue('port');
	    $port = $def_nf_port if ! defined $port;
	    $output .= "nfprobe_receiver: $server:$port\n";
	}
    }

    $config->setLevel("$path netflow timeout");   
    my $str = '';
    foreach my $timeout (keys %timeout_hash) {
	my $value = $config->returnValue($timeout);
	if ($value and $timeout_hash{$timeout}) {
	    $str .= ":" if $str ne '';
	    $str .= "$timeout_hash{$timeout}=$value";
	}
    }
    $output .= "nfprobe_timeouts: $str\n" if $str ne '';
    return $output;
} 

sub acct_get_sflow {
    my ($intf, $config) = @_;

    my $path   = 'system accounting';
    my $output = undef;

    $config->setLevel($path);
    return $output if ! $config->exists('sflow');

    $config->setLevel("$path sflow"); 
    my $agent = $config->returnValue('agentid');
    if ($agent) {
	$output .= "sfprobe_agentsubid: $agent\n";
    }

    $config->setLevel("$path sflow server");  
    my @servers = $config->listNodes();
    if (scalar(@servers)) {
	foreach my $server (@servers) {
	    $config->setLevel("$path sflow server $server");   
	    my $port = $config->returnValue('port');
	    $port = $def_sf_port if ! defined $port;
	    $output .= "sfprobe_receiver: $server:$port\n";
	}
    }
    return $output;
}

sub acct_get_output_filter {
    my ($intf) = @_;

    my $output = '';
    my $interface = new Vyatta::Interface($intf);
    my $hwaddr    = $interface->hw_address();
    if ($hwaddr) {
	# filter out output traffic
	$output .= "pcap_filter: !ether src $hwaddr\n";
    }
    return $output;
}

sub acct_get_config {
    my ($intf) = @_;
    
    my $config = new Vyatta::Config;
    my $output = '';
    my $path   = 'system accounting';

    $output .= acct_conf_globals($intf);
    $output .= "interface: $intf\n";

    $config->setLevel($path);
    my $facility = $config->returnValue('syslog-facility');
    $output .= "syslog: $facility\n" if defined $facility;
    
    $config->setLevel("$path interface $intf");
    my $sampling = $config->returnValue('sampling-rate');
    $output .= "sampling_rate: $sampling\n" if defined $sampling;

    $output .= acct_get_output_filter($intf);

    my $plugins = 'plugins: memory';
    my $netflow = acct_get_netflow($intf, $config);
    my $sflow   = acct_get_sflow($intf, $config);
    $plugins .= ',nfprobe' if defined $netflow;
    $plugins .= ',sfprobe' if defined $sflow;
    
    $output .= "$plugins\n";
    $output .= $netflow if defined $netflow;
    $output .= $sflow   if defined $sflow;
    return $output;
}


#
# main
#

my ($action, $intf);

GetOptions("action=s"      => \$action,
);

die "Undefined action" if ! $action;

if ($action eq 'update') { 
    acct_log("update");
    my $config = new Vyatta::Config;

    $config->setLevel('system accounting interface');
    my %intf_status = $config->listNodeStatus();

    foreach my $intf (keys %intf_status) {
	if ($intf_status{$intf} eq 'deleted') {
	    acct_log("stop [$intf]");
	    stop_daemon($intf);
	} else { 
	    acct_log("update [$intf]");
	    my $conf      = acct_get_config($intf);
	    my $conf_file = acct_get_conf_file($intf);
	    if (acct_write_file($conf_file, $conf)) {
		acct_log("conf file written [$intf]");
		restart_daemon($intf, $conf_file);
	    } else {
		acct_log("conf file not written [$intf]");
		# on reboot, the conf should match
		# but we still need to start it
		my $pid_file  = acct_get_pid_file($intf);		
		if (! is_running($pid_file)) {
		    start_daemon($intf, $conf_file);
		}
	    }
	}
    }
    exit 0;
}

if ($action eq 'list-intf') {
    my $config = new Vyatta::Config;
    my $path   = "system accounting interface";
    $config->setLevel($path);
    my @intfs = acct_get_intfs();
    print join("\n", @intfs);
    exit 0;
}

exit 1;

# end of file
