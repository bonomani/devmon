package dm_ping;
require Exporter;
our @ISA = qw(Exporter);

#our @EXPORT = qw(ping_iphosts pong_index pong_iphost, new, dm_ping);
our @EXPORT = qw(ping_iphosts pong_index pong_iphost, dm_ping);

#    Devmon: An SNMP data collector & page generator for the
#    Xymon network monitoring systems
#    Copyright (C) 2021 Bonomani
#
#    $URL: trunk/modules/dm_snmp.pm $
#    $Revision: 0.2021.06.24 $
#    $Id: dm_ping.pm 236 2021-06.24 12:00:00Z Bonomani $
#
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.  Please see the file named
#    'COPYING' that was included with the distrubition for more details.

use strict;
use warnings;

#use diagnostics;

use IPC::Open3;
use Symbol 'gensym';    # vivify a separate handle for STDERR
use IO::Select;
use threads;
use threads::shared;
use Carp;
use vars qw(%storage);
use Errno qw(ENOENT);
use Errno qw(:POSIX);

# Options:
#
my $debug              = 1;
my $nb_ping            = 3;       # 3 is good for stat, 1 is best for speed (but we could also have both: need refactoring
my $retain_stats_cycle = 5;       # keep ping stat for 5 min, not implemtented....
my $timeout            = 5000;    # in msyou can lower it but, it is used for stat: if unreachable stat=timeout!

# set vars
my $cmd             = 'fping';
my $max_unreachable = 1;          # we allow 1 timeout the firsttime, and we rearm if success, dont touch!

#my $is_first_polling = 1;  # In the first pooling we have to discover some parameters
my $round_robin_threshold = 43200;    # 43200 = 12h a change in less than 12h mean we have a round robin entry or it is just a normal change.

my $ipv4_regexp = "(?:25[0-5]|2[0-4][0-9]|[0-1]?[0-9]{1,2})[.](?:25[0-5]|2[0-4][0-9]|[0-1]?[0-9]{1,2})[.](?:25[0-5]|2[0-4][0-9]|[0-1]?[0-9]{1,2})[.](?:25[0-5]|2[0-4][0-9]|[0-1]?[0-9]{1,2})";
my $ipv6_regexp = "(?^::(?::[0-9a-f]{1,4}){0,5}(?:(?::[0-9a-f]{1,4}){1,2}|:(?:))|[0-9a-f]{1,4}:(?:[0-9a-f]{1,4}:(?:[0-9a-f]{1,4}:(?:[0-9a-f]{1,4}:(?:[0-9a-f]{1,4}:(?:[0-9a-f]{1,4}:(?:[0-9a-f]{1,4}:(?:[0-9a-f]{1,4}|:)|(?::(?:[0-9a-f]{1,4})?|(?:)))|:(?:(?:)|[0-9a-f]{1,4}(?::[0-9a-f]{1,4})?|))|(?::(?:)|:[0-9a-f]{1,4}(?::(?:)|(?::[0-9a-f]{1,4}){0,2})|:))|(?:(?::[0-9a-f]{1,4}){0,2}(?::(?:)|(?::[0-9a-f]{1,4}){1,2})|:))|(?:(?::[0-9a-f]{1,4}){0,3}(?::(?:)|(?::[0-9a-f]{1,4}){1,2})|:))|(?:(?::[0-9a-f]{1,4}){0,4}(?::(?:)|(?::[0-9a-f]{1,4}){1,2})|:)))";
my $ip_regexp   = "(?:$ipv4_regexp)|(?:$ipv6_regexp)";

sub dm_ping {
   my %local_store;
   my $store_ref;
   if (scalar @_) {
      $store_ref = shift;
   } else {
      carp "working in standalone mode: local_stored_iphost";
      $store_ref = \%local_store;
   }
   my $cmd_arg;
   my %input_fh;
   my %output_fh;
   my %error_fh;
   my %pid;
   my $polls_ref;
   my $mapping_ref         = \%{$store_ref->{mapping}};
   my $reverse_mapping_ref = \%{$store_ref->{reverse_mapping}};
   my $result_ref          = \%{$store_ref->{result}};
   my $self                = bless {

      #stored_iphost_ref => \${$store_ref}{results},
      #stored_iphost_ref => $results_ref,
      result          => $result_ref,
      mapping         => $mapping_ref,
      reverse_mapping => $reverse_mapping_ref,
      cmd_arg         => $cmd_arg,
      input_fh        => %input_fh,
      output_fh       => %output_fh,
      error_fh        => %error_fh,
      pid             => %pid,
      polls_ref       => $polls_ref,
   };

   use Data::Dumper;
   print Dumper($self->{stored_iphost_ref});

   #exit;
   #$self->_initialize(\%storage);
   bless $self;
   return $self;

}

#sub _initialize {
#     my $storage_ref = @_;
#}

# Minimal tests

sub ping_iphosts {
   my ($self, $iphosts_ref) = @_;
   my $arg     = "-A -m -C$nb_ping -q -r0 -t$timeout";
   my $cmd_arg = $cmd . " " . $arg;
   $self->{cmd_arg}   = $cmd_arg;
   $self->{polls_ref} = $iphosts_ref;    # add the iphosts array to our object
   $self->ping_iphosts_w_arg($iphosts_ref);
}

sub ping_iphosts_w_arg {

   my ($self, $iphosts_ref) = @_;
   my $cmd_arg = $self->{cmd_arg};

   #share($ping_out);

   foreach my $iphost (@{$iphosts_ref}) {

      my @cmd_line = split / /, $cmd_arg . " " . $iphost;

      #share(@{$ping_out->{$iphost}});
      #if (is_shared(@{$ping_out->{$iphost}})) {
      #   lock(@{$ping_out->{$iphost}});
      #   @{$ping_out->{$iphost}} = ();

      #}

      eval {$self->{pid}{$iphost} = &open3($self->{input}{$iphost}, $self->{output}{$iphost}, $self->{error}{$iphost} = gensym, "@cmd_line");};
      croak "$@" if $@;
      $self->{input}{$iphost}->close;
   }
}

sub pong_index {

   # Normal mode =0 (recovery mode =1)
   my ($self, $index, $iphosts_ref) = @_;
   my ($out_ref, $err_ref) = $self->pong_index_w_mode(0, $index, $iphosts_ref);
   return $out_ref, $err_ref;
}

sub pong_index_w_mode {

   my ($self, $mode_recovery, $index, $array) = @_;

   #my $iphost  = ${\@{$array}}[$index];
   my $iphost  = $array->[$index];
   my $cmd_arg = $self->{cmd_arg};
   my @out;
   my @err;

   #if (exists ${$storage}{$index}) {
   #   @out = @{${$storage}{$index}};
   #} else {

   #   while (not ${$output->{$iphost}}->eof) {
   #      push @out, ${$output->{$iphost}}->getline;
   #   }
   #${$storage}{$index} = [ @out ];
   #} else {
   my $select = new IO::Select;

   $select->add($self->{output}{$iphost}, $self->{error}{$iphost});
   while (my @fhs = $select->can_read(10)) {
      foreach my $fh (@fhs) {
         if ($fh == $self->{output}{$iphost}) {
            my $line = $fh->getline;
            if (defined $line) {
               $line =~ s/^\s$//;

               #print("out1: $line") if $line ne '';
               push(@out, $line) if $line ne '';
            }
         } elsif ($fh == $self->{error}{$iphost}) {
            my $line = $fh->getline;
            if (defined $line) {
               $line =~ s/^\s$//;

               # fping send stat to @err: correct it
               if ($line =~ /^$ip_regexp\s+:\s+[-\d\.]/) {

                  #  print("out2: $line") if $line ne '';
                  push(@out, $line) if $line ne '';
               } else {

                  #   print("err :$line") if $line ne '';
                  push(@err, $line) if $line ne '';
               }
            }
         } else {

            # we should never be here, as we test the 2 filehandles
            # In case, we mixed something
            croak "IO::Select hash not macth the filehandle?!";
         }

         # if we reach the end of file of our answer ($output or $error)
         # we remove the filehandle from our select
         $select->remove($fh) if $fh->eof;
      }
   }
   waitpid($self->{pid}{$iphost}, 0);
   my $child_exit_status = $? >> 8;
   # Test fping exit status 
   # Sucess: 0 if all the hosts are reachable, 1 if some hosts were unreachable,
   # Error : 2 if any IP addresses were not found, 3 for invalid command line arguments, and 4 for a system call failure.
   if ($child_exit_status > 1) {

      # Child as an error,
      # 2 if any IP addresses were not found, mean a DNS Resolution problem 
      if ($child_exit_status == 2) {

         # When fping C option is used no error is raised
         # so we miss an information. But we will fix it
         ##Not any more by requery the host with standard parameters
         ## As we reuse the current sub a guard is setup
         ## to avoid loop: mode_recovery = 1
         if (not scalar @err) {
            push(@err, 'Name or service not known');
            #carp "Failed to get the error msg for $cmd_arg $iphost";    # not if debug

            # verify if the mode recovery is enable for loop prvention
            #if (not $mode_recovery) {

               # There is no error message so we probably have a C option, as error message
               # are not sent with this option and we suspect a dns resolution problem (but it
               # can maybe  be something else )
               # So lets try to obtain a correct error message
               # by entering in "recovery mode for error message"
               #my ($out_ref, $err_ref) = pong_index_recover($index, $array, $storage);
               # # could also do 2 requests in parallel: a second on with an array with only ips...
               # or just send 1 request with ips...(but not sur it works like that)
               # ...may be later, (done a little bit later, with the complete array but is not
               # optimal for just dns changes...also lilely to occure than dns outage)
               #
             #  my ($out_ref, $err_ref) = $self->pong_index_recover($index, $array);

               #@out = @{$out_ref}; we have an error, so just ray to
               #@err = @{$err_ref};

            #} else {
            #   carp "Failed to recover an error msg for $cmd_arg $iphost" if $debug;
            #}
         #}
         #my $err_count = @err;
         #for (my $err_idx = 0; $err_idx < $err_count; $err_idx++) {

            #if we have a dns error we can try to recover it with the a previously stored ip!
            #this should prevent completly DNS outage! And improve stability
            #we do it for the complete array so we will we dont wait to much time
            #as we will modify the current loop we use a simple loop
          #  if ($err[$err_idx] =~ /Name or service not known/) {

               #my ($recov_out_ref, $recov_err_ref) = $self->pong_index_recover(0,[$array[$index]] );
               #if $err_id
               #chomp($err);
               #carp("DNS was bypassed : '" . ($err) . "' with '$cmd_arg $iphost'") if $debug;

           # }

            # if @err we receive no anser ?!?!?
            #carp "$cmd_arg $iphost returned with exit code $child_exit_status and no error msg";
         }
      } elsif ($child_exit_status >= 127) {
         carp "$cmd_arg $iphost returned with exit code $child_exit_status (probably died)";

      }
   }
   close($self->{output}{$iphost});
   close($self->{error}{$iphost});

   # Now we have all our information we can update or storage and provide the prefered ip (alive)
   # We would like to insert our info "raw" so we can always see the last result if needed
   # but we need to find the right key...
   #
   # so as first we need to find the entry key of our storage, but of course if we have entries
   if (scalar @out) {

      # prepare keys to look for:
      # normal (ipv4/v6)            : '2.2.2.2 dns.google'
      # anycast/mutihomed/dnsonly   : '0.0.0.0 www.google.com'
      # and we can test the normal case that should mostly happend
      #                               '$out[0] ${$self->{polls_ref}[$index]'

      # extract answer
      my $out_idx = 0;
      my $ipv4_first_alive_idx;
      my $ipv6_first_alive_idx;
      my @ipv4_ips;
      my @ipv6_ips;
      my @ip;
      my @hostname;
      my $ping_answer;
      my %iphost_mapping;

      for my $out (@out) {

         # we should test fo IPv4 or v6 and..... but now starting we common cas: "ipv4" and poll is "hostname"
         #
         #my $iphost_key = $out." ".$iphost; #should I test if poll is an ip or a host?
         #${$self->{stored_iphost_ref}}{$iphost_key}->{outs} = [@out];
         #push @{$self->{stored_iphost_ref}}{$iphost_key}{outs},   ($out);
         # ${$self->{stored_iphost_ref}}{$iphost_key}->{errs} = @err;
         # we can now extract the info
         #if ($out =~ /^(\S+)\s\((\S+)\):\s+(\S+.*\S+)\s*$/) { # to match:test (1.1.2.1) : 11.46 11.46 11.46
         #   $ip[$out_idx] = $1;    # the ip
         #   $hostname[$out_idx] = $2;
         #   $result = $3;       # list of stats  '11.46 11.15 11.39'
         #   This used the reverse dns, but we dont want it as it depends alway on dns and we try not to depend on it
         #   It can also over complexify all the process and finally can reveal things that should be masked.
         #   Nevertheless the next rexexp should support a hostname as it could be valuable in a discovery process

         if ($out =~ /^(\S+)\s+:\s+(\S+.*\S+)\s*$/) {    # to match: 1.1.2.1 : 11.46 11.46 11.46
                                                         #       or:    test : - - -
            $ip[$out_idx] = $1;                          # the ip
            $ping_answer = $2;                           # list of stats  '11.46 11.15 11.39'

            #my $iphost_key = $ip[$out_idx] . " " . $iphost; # this is make "1.1.1.2 dns.google"
            # we would lihe this result: "1.1.1.2 dns.google" for our entrie (same format as xymon)
            # but ip are unique so we create first:  "1.1.1.2 1.1.1.2" and we will expand the wit a mapping, reverserse mapping that
            # the mapping should contain:
            #     Normal case: 1. Probe the ip
            #     Undisovered: 2. Probe the hostname
            #     Multihomed : 3. Probe the ips
            my $iphost_key = $ip[$out_idx] . " " . $ip[$out_idx];    # this is "1.1.1.2 1.1.1.2" this is best as ip are unique
            $self->{mapping}{$iphost}{$ip[$out_idx]}         = undef;
            $self->{reverse_mapping}{$ip[$out_idx]}{$iphost} = undef;
            $iphost_mapping{$ip[$out_idx] . " " . $iphost}   = $iphost_key;    # our localhash  "1.1.1.2 dns.google" ->" 1.1.1.2 1.1.1.2" needed for the last step: the final extension

            #$probe_host

            #delete or not=
            #delete($self->{result}->{$iphost_key}->{outs}) if exists $self->{result}->{$iphost_key}->{outs};

            my $unreachable_count = () = $ping_answer =~ /\Q-/g;    # count the number "-" occurences
                                                                    #print "nb_of_unreachable: $unreachable_count";
            my $stats_cycle;
            if (defined $self->{result}->{$iphost_key}->{last_stats_cycle}) {
               $stats_cycle = ($self->{result}->{$iphost_key}->{last_stats_cycle} + 1) % $retain_stats_cycle;
            } else {
               $stats_cycle = 1;
            }

            $self->{result}->{$iphost_key}->{stats}->{$stats_cycle} = [split / /, $ping_answer];

            $self->{result}->{$iphost_key}->{last_stats_cycle} = $stats_cycle;

            $self->{result}->{$iphost_key}->{ip} = $ip[$out_idx];
            if ($ip[$out_idx] =~ /^$ipv4_regexp$/) {

               push @ipv4_ips, $ip[$out_idx];

               $self->{result}->{$iphost_key}->{ipv4}    = $ip[$out_idx];
               $self->{result}->{$iphost_key}->{is_ipv4} = 1;

               if (not defined $self->{result}->{$iphost_key}->{ipv4_unreachable_max_allowed}) {
                  $self->{result}->{$iphost_key}->{ipv4_unreachable_max_allowed} = $max_unreachable;
               }
               if ($unreachable_count > $self->{result}->{$iphost_key}->{ipv4_unreachable_max_allowed}) {
                  $self->{result}->{$iphost_key}->{ipv4_is_alive} = 0;
               } elsif ($unreachable_count > 0) {
                  $self->{result}->{$iphost_key}->{ipv4_is_alive} = 1;
                  $self->{result}{$iphost_key}->{ipv4_unreachable_max_allowed}--;
               } else {
                  $self->{result}->{$iphost_key}->{ipv4_is_alive} = 1;
                  if ($self->{result}->{$iphost_key}->{ipv4_unreachable_max_allowed} < $max_unreachable) {

                     # we can rearm the unreachable counti threshold by +1 if under the max
                     $self->{result}->{$iphost_key}->{ipv4_unreachable_max_allowed}++;
                  }
               }
               if ($self->{result}->{$iphost_key}->{ipv4_is_alive}) {
                  $ipv4_first_alive_idx = $ipv4_first_alive_idx // $out_idx;    # if defined
               }

            } elsif ($ip[$out_idx] =~ /^$ipv6_regexp$/) {

               push @ipv6_ips, $ip[$out_idx];
               $self->{result}->{$iphost_key}->{ipv6}    = $ip[$out_idx];
               $self->{result}->{$iphost_key}->{is_ipv6} = 1;

               if (not defined $self->{result}->{$iphost_key}->{ipv6_unreachable_max_allowed}) {
                  $self->{result}->{$iphost_key}->{ipv6_unreachable_max_allowed} = $max_unreachable;
               }
               if ($unreachable_count > $self->{result}->{$iphost_key}->{ipv6_unreachable_max_allowed}) {
                  $self->{result}->{$iphost_key}->{ipv6_is_alive} = 0;
               } elsif ($unreachable_count > 0) {
                  $self->{result}->{$iphost_key}->{ipv6_is_alive} = 1;
                  $self->{result}->{$iphost_key}->{ipv6_unreachable_max_allowed}--;
               } else {
                  $self->{result}->{$iphost_key}->{ipv6_is_alive} = 1;
                  if ($self->{result}->{$iphost_key}->{ipv6_unreachable_max_allowed} < $max_unreachable) {

                     # we can rearm the unreachable counti threshold by +1 if under the max
                     $self->{result}->{$iphost_key}->{ipv6_unreachable_max_allowed}++;
                  }
               }
               if ($self->{result}->{$iphost_key}->{ipv6_is_alive}) {
                  $ipv6_first_alive_idx = $ipv6_first_alive_idx // $out_idx;    # if defined
               }

            }

         } else {

            # we have an output but no ip: this should never arrive, but in cas it will we push it to our fake ip.
            my $iphost_key = "0.0.0.0 " . $iphost;
            if (exists $self->{result}->{$iphost_key}{outs}) {

               $self->{result}->{$iphost_key}{outs} = $out . ", " . $self->{result}->{$iphost_key}{outs};
            } else {
               $self->{result}->{$iphost_key}{outs} = $out;
            }
	    $self->{mapping}->{$iphost} = $iphost;

            carp "$cmd_arg $iphost produce an output that did not match our ip regexp: $out";
         }
         $out_idx++;
      }

      if (@ipv4_ips > 1) {    # we have a multihomed!
         my $iphost_key = "0.0.0.0 " . $iphost;
         $self->{result}->{$iphost_key}->{is_ipv4} = 1;
         if (not exists $self->{result}->{$iphost_key}->{ipv4_ips}) {
            $self->{result}->{$iphost_key}->{ipv4_ips_last_change} = time();
            $self->{result}->{$iphost_key}->{ipv4_ips}             = [@ipv4_ips];
            $self->{result}->{$iphost_key}->{ipv4_is_discovered}   = 1;

         } elsif (not arrays_are_equal($self->{result}->{$iphost_key}->{ipv4_ips}, \@ipv4_ips)) {

            # a lot more to test and to do, but a simple canevas for it with some ideas
            if (  (not exists $self->{result}->{$iphost_key}->{ipv4_is_discovered})
               || ($self->{result}->{$iphost_key}->{ipv4_is_discovered} = 0))
            {

               $self->{result}->{$iphost_key}->{ipv4_ips_last_change} = time();
            } elsif (($self->{result}->{$iphost_key}->{ipv4_ips_last_change} - time()) > $round_robin_threshold) {
               $self->{result}->{$iphost_key}->{ipv4_ips_last_change} = time();
               warn "ip address(es) change for multihome: $iphost was \$self->{result}->{$iphost_key}->{ipv4_ips}, is: @ipv4_ips";
               $self->{result}->{$iphost_key}->{ipv4_ips} = [@ipv4_ips];
            } else {    # the change occurd in less than $round_robin_threshold, this should be a round robin dns entry
               $self->{result}->{$iphost_key}->{ipv4_ips_last_change} = time();
               $self->{result}->{$iphost_key}->{ipv4_is_round_robin}  = 1;
            }
         }

         $self->{result}->{$iphost_key}->{ipv4_ips} = [@ipv4_ips];
         $self->{result}->{$iphost_key}->{errs}     = join ', ', @err if @err;
         if (defined $ipv4_first_alive_idx) {
            $self->{result}->{$iphost_key}->{ipv4_is_alive} = 1;

            #my $ipv4_first_alive_iphost_key = $ip[$ipv4_first_alive_idx] . " " . $iphost;
            my $ipv4_first_alive_iphost_key = $ip[$ipv4_first_alive_idx] . " " . $ip[$ipv4_first_alive_idx];

            $self->{result}->{$iphost_key}->{ipv4} = $self->{result}->{$ipv4_first_alive_iphost_key}{ipv4};
            $self->{result}->{$iphost_key}->{ip}   = $self->{result}->{$ipv4_first_alive_iphost_key}->{ip};

            my $stats_cycle;
            if (defined $self->{result}->{$iphost_key}->{last_stats_cycle}) {
               $stats_cycle = ($self->{result}->{$iphost_key}->{last_stats_cycle} + 1) % $retain_stats_cycle;
            } else {
               $stats_cycle = 1;
            }
            $self->{result}->{$iphost_key}->{stats}->{$stats_cycle} = $self->{result}->{$ipv4_first_alive_iphost_key}->{stats}->{$self->{result}->{$ipv4_first_alive_iphost_key}->{last_stats_cycle}};

         } else {

         }
         my $stats_cycle;
         if (defined $self->{result}->{$iphost_key}->{last_stats_cycle}) {
            $stats_cycle = ($self->{result}->{$iphost_key}->{last_stats_cycle} + 1) % $retain_stats_cycle;
         } else {
            $stats_cycle = 1;
         }
         my $ipv4_first_iphost_key = $ip[0] . " " . $ip[0];

         $self->{result}->{$iphost_key}->{stats}->{$stats_cycle} = $self->{result}->{$ipv4_first_iphost_key}->{stats}->{$self->{result}->{$ipv4_first_iphost_key}->{last_stats_cycle}};
         $self->{result}->{$iphost_key}->{ipv4_multihomed} = 1;
      }

      if (@ipv6_ips > 1) {
         my $iphost_key = "::0 " . $iphost;
         $self->{result}->{$iphost_key}->{ipv6_multihomed} = 1;
      }

      #the last step: the final expansion, with the mapping just created
      # we create a ref to the ip address only key: "1.1.1.1 dns.google" -> "1.1.1.1 1.1.1.1"
      foreach my $expand_iphost_key (keys %iphost_mapping) {
         $self->{result}->{$expand_iphost_key} = $self->{result}->{$iphost_mapping{$expand_iphost_key}};
      }

   } else {

      # we dont have any output nor ips...but maybe an error, any we store it
      if (@err) {
         my $iphost_key = "0.0.0.0 " . $iphost;
         $self->{result}->{$iphost_key} = undef;
         $self->{result}->{$iphost_key}->{errs} = join(', ', @err);
	 $self->{mapping}->{$iphost} = $iphost;
         $iphost_key                            = "::0 " . $iphost;
         $self->{result}->{$iphost_key}         = undef;
         $self->{result}->{$iphost_key}->{errs}     = join(', ', @err);
	 $self->{mapping}->{$iphost} = $iphost;

         carp "$cmd_arg $iphost report error: " . join(', ', @err);
      } else {
         carp "$cmd_arg $iphost did not produce ans outup, nor error... ;";
      }

   }

   return \@out, \@err;
}
#sub compute_result {

#	return \@out, \@err;
	
#}

sub pong_index_recover {
   carp("Enter 'recover error msg' mode") if $debug;
   my ($self, $index, $array_ref) = @_;
   my $arg     = "-A -m -r0";
   my $cmd_arg = $cmd . " " . $arg;
   $self->{cmd_arg} = $cmd_arg;

   my @array_of_1;
   $array_of_1[0] = @{$array_ref}[$index];
   $self->ping_iphosts_w_arg(\@array_of_1);

   # we
   my ($out_ref, $err_ref) = $self->pong_index_w_mode(1, $index, $array_ref);
   carp("Exit 'recovery error msg' mode") if $debug;
   return $out_ref, $err_ref;
}

sub pong_iphost {
   my ($self, $iphost, $iphosts_ref) = @_;

   my $index = first_index($iphost, @$iphosts_ref);
   my ($out_ref, $err_ref) = $self->pong_index($index, $iphosts_ref) if defined $index;
}

sub first_index {
   my ($iphost, @iphosts) = @_;
   for my $index (0 .. @iphosts) {
      if ($iphosts[$index] eq $iphost) {
         return $index;
      }
   }

   # We should never be here...
   carp "Did not find an matching iphost in our iphosts array?!";
   return undef;
}

sub is_ip {
   my $ip = shift;
   return (is_ipv4($ip) || is_ipv4($ip));
}

sub is_ipv4 {
   my $ip = shift;
   return ($ip =~ /^$ipv4_regexp$/);
}

sub is_ipv6 {

   # do not support ipv4 form nor uppercase
   my $ip = shift;
   return ($ip =~ /^$ipv6_regexp$/);
}

sub arrays_are_equal {
   my ($first, $second) = @_;

   #no warnings;  # silence spurious -w undef complaints
   return 0 unless @$first == @$second;
   for (my $i = 0; $i < @$first; $i++) {
      return 0 if $first->[$i] ne $second->[$i];
   }
   return 1;
}

