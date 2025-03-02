#!/usr/bin/perl
use strict;
use warnings;
use lib '.';

#use diagnostics;

use Carp;
use dm_ping;

my @check         = ("www.google.com", "gvatvauro3.ubiin.tranet.work", "172.26.0.1", "test", "pc_bruno");
my %stored_iphost =( 
   'mapping' => {'www.google.com' => {'216.58.215.228' => undef,
	                             },
				},
   'result' => {
      "216.58.215.228 www.google.com" => {
	      #         outs => [["216.58.215.228", "11.46 11.15 11.39"], ["2a00:1450:400a:803::2004", "- - -"]],    # not exist if parsed
	      #     errs => [["pc_bruno",       "Name or service not known"]],                                   # not exist if no errori, but should..
         ipv4_is_alive => 1,
         stats         => {
            '1' => ['11.46', '11.15', '11.39'],
            '2' => ['11.46', '11.15', '11.39'],
            '3' => ['11.46', '11.15', '11.39'],
            '4' => ['11.46', '11.15', '11.39'],
            '5' => ['11.46', '11.15', '11.39'],
         },

         #      alive_ips => {
         #   '216.58.215.228' => {
         #      'last_seen_gmt' => '1231232123',
         #      'ptr'           => 'www.google.com',
         #   },
         #},

         'ipv4_ips'             => ['216.58.215.228', '1.1.2.1'],    # implemented for host 0.0.0.0
         'ipv4_ips_last_change' => 1624891937,

         ip                           => '216.58.215.228',
         ipv4                         => '216.58.215.228',
         hostname                     => 'www.google.com',           # not implemented?
         is_ipv4                      => 1,
         dns_only                     => 0,                          # not implemented
         ipv4_anycast                 => 1,                          # not implemented
         ipv4_multihomed              => 1,
         ipv4_unreachable_max_allowed => 0,
         last_stats_cycle             => 1,

      },
      '2a00:1450:400a:803::2004 www.google.com' => {

         'last_stats_cycle' => 1,
         'ip'               => '2a00:1450:400a:803::2004',
         'is_ipv6'          => 1,
         'ipv6_is_alive'    => 0,
         'stats'            => {
            '1' => ['-', '-', '-']
         },
         'ipv6_unreachable_max_allowed' => 1,
         'ipv6'                         => '2a00:1450:400a:803::2004'
      },
   },
);



#my %stored_iphost = {};
my ($out_ref, $err_ref);

#Create ping object

#my $ping = dm_ping(\%storage);
my $ping = dm_ping(\%stored_iphost);

#my $ping = dm_ping();

$ping->ping_iphosts(\@check);

#ping_iphosts(\@check, \%storage);
#($out_ref, $err_ref) = pong_index(4, \@check, \%storage);
($out_ref, $err_ref) = $ping->pong_index(0, \@check);
print("Out: @{$out_ref}");
($out_ref, $err_ref) = $ping->pong_index(1, \@check);
print("Out: @{$out_ref}");
($out_ref, $err_ref) = $ping->pong_index(2, \@check);
print("Out: @{$out_ref}");
($out_ref, $err_ref) = $ping->pong_index(3, \@check);
print("Out: @{$out_ref}");

($out_ref, $err_ref) = $ping->pong_index(4, \@check);
print("Out: @{$out_ref}");

#($out_ref, $err_ref) = $ping->pong_iphost('www.google.com', \@check);
#print("Out: @{$out_ref}");
use Data::Dumper;
print Dumper(\%stored_iphost);

