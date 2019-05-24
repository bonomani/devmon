package dm_snmp;
require Exporter;
@ISA    = qw(Exporter);
@EXPORT = qw(poll_devices snmp_query);

#    Devmon: An SNMP data collector & page generator for the
#    Xymon network monitoring systems
#    Copyright (C) 2005-2006  Eric Schwimmer
#    Copyright (C) 2007  Francois Lacroix
#
#    $URL: svn://svn.code.sf.net/p/devmon/code/trunk/modules/dm_snmp.pm $
#    $Revision: 236 $
#    $Id: dm_snmp.pm 236 2012-08-03 10:36:23Z buchanmilne $
#
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.  Please see the file named
#    'COPYING' that was included with the distrubition for more details.

# Modules
use strict;
#use BER;
use Socket;
use IO::Handle;
use IO::Select;
use IO::Socket::INET;
#use SNMP_Session;
use POSIX ":sys_wait_h";
use Math::BigInt;
use Storable qw(nfreeze thaw);
use dm_config;

use SNMP;

# Our global variable hash
use vars qw(%g);
*g = \%dm_config::g;

#my $max_pdu_len = 16384;  # default is 8000
# Set some of our global SNMP variables
#$BER::pretty_print_timeticks = 0;
#$SNMP_Session::suppress_warnings = $g{debug} ? 0 : 1;

# Fiddle with some of our storable settings to correct byte order...
$Storable::interwork_56_64bit = 1;

# Add a wait for our dead forks
$SIG{CHLD} = \&REAPER;

# Sub that, given a hash of device data, will query specified oids for
# each device and return a hash of the snmp query results
sub poll_devices {
   # clear per-fork polled device counters
   foreach (keys %{$g{forks}} ) {
      $g{forks}{$_}{polled} = 0;
   }

   do_log("DEBUG SNMP: running poll_devices()",0) if $g{debug};
   do_log("Starting snmp queries",1);
   $g{snmppolltime} = time;

   my %snmp_input = ();
   %{$g{snmp_data}} = ();

   # Query our Xymon server for device reachability status
   # we don't want to waste time querying devices that are down
   do_log("Getting device status from Xymon at $g{dispserv}",1);
   %{$g{xymon_color}} = ();
   foreach (`$ENV{XYMON} $g{dispserv} "xymondboard test=^$g{pingcolumn}\$ fields=hostname,color,line1"`) {
      my ($device,$color,$line1) = split /\|/;
      my ($l1col) = ($line1 =~ /^(\w+)/);
      do_log("DEBUG SNMP: $device has Xymon status $color ($l1col)",2) if $g{debug};
      $g{xymon_color}{$device} = $color ne "blue" && $color || $l1col;
   }

   # Build our query hash
   QUERYHASH: for my $device (sort keys %{$g{dev_data}}) {

      # Skip this device if we weren't able to reach it during update_indexes
      # next unless $indexes->{$device}{reachable};

      # Skip this device if we are running a Xymon server and the
      # server thinks that it isn't reachable
      if(defined $g{xymon_color}{$device} and
         $g{xymon_color}{$device} ne 'green') {
         do_log("$device has a non-green Xymon status, skipping SNMP.", 2);
         next QUERYHASH;
      }

      my $vendor = $g{dev_data}{$device}{vendor};
      my $model  = $g{dev_data}{$device}{model};
      my $tests  = $g{dev_data}{$device}{tests};

      # Make sure we have our device_type info
      do_log("No vendor/model '$vendor/$model' templates for host $device, skipping.", 0)
         and next QUERYHASH if !defined $g{templates}{$vendor}{$model};

      # If our tests = 'all', create a string with all the tests in it
      if ( $tests eq 'all' ) {
         $tests = join ',', keys %{$g{templates}{$vendor}{$model}{tests}} ;
      }

      $snmp_input{$device}{ip}   = $g{dev_data}{$device}{ip};
      $snmp_input{$device}{ver}  = $g{dev_data}{$device}{ver};
      $snmp_input{$device}{cid}  = $g{dev_data}{$device}{cid};
      $snmp_input{$device}{port} = $g{dev_data}{$device}{port};
      $snmp_input{$device}{dev}  = $device;

      do_log("Querying $device for tests $tests", 3);

      # Go through each of the tests and determine what their type is
      TESTTYPE: for my $test (split /,/, $tests) {

         # Make sure we have our device_type info
         do_log("No test '$test' template found for host $device, skipping.", 0)
            and next TESTTYPE if
         !defined $g{templates}{$vendor}{$model}{tests}{$test};

         # Create a shortcut
         my $tmpl    = \%{$g{templates}{$vendor}{$model}{tests}{$test}};
         my $snmpver = $g{templates}{$vendor}{$model}{snmpver};

         # Determine what type of snmp version we are using
         # Use the highest snmp variable type we find amongst all our tests
         $snmp_input{$device}{ver} = $snmpver if
            !defined $snmp_input{$device}{ver} or
            $snmp_input{$device}{ver} < $snmpver;

         # Go through our oids and add them to our repeater/non-repeater hashs
         for my $oid (keys %{$tmpl->{oids}}) {
            my $number = $tmpl->{oids}{$oid}{number};

            # Skip translated oids
            next if !defined $number;

            # If this is a repeater... (branch)
            if($tmpl->{oids}{$oid}{repeat}) {
               $snmp_input{$device}{reps}{$number} = 1;

               # If we've queried this device before, use the previous number of
               # repeats to populate our repeater value
               $snmp_input{$device}{reps}{$number} =
               $g{max_rep_hist}{$device}{$number};

            # Otherwise this is a nonrepeater (leaf)
            } else {
               $snmp_input{$device}{nonreps}{$number} = 1;
            }
         }
      }
   }

   # Throw the query hash to the forked query processes
   snmp_query(\%snmp_input);

   # Record how much time this all took
   $g{snmppolltime} = time - $g{snmppolltime};

   # Dump some debug info if we need to
   if($g{debug}) {
      for my $dev (sort keys %{$g{dev_data}}) {
         my $expected = (scalar keys %{$snmp_input{$dev}{nonreps}}) +
         (scalar keys %{$snmp_input{$dev}{reps}});
         my $received = (scalar keys %{$g{snmp_data}{$dev}});
         do_log("SNMP: Queried $dev: expected $expected, received $received",0)
         if ($expected != $received);
      }
   }
}

# Query SNMP data on all devices
sub snmp_query {
   my ($snmp_input) = @_;
   my $active_forks = 0;

   # Check the status of any currently running forks
   &check_forks();

   my @devices = keys %{$snmp_input};

   # Make sure $g{numdevs} is not 0
   if ( $g{numdevs} eq "0" ) {
      $g{numdevs} = $#devices ;
   }

   # Start forks if needed
   #fork_queries() if keys %{$g{forks}} < $g{numforks};
   fork_queries() if (keys %{$g{forks}} < $g{numforks} && keys %{$g{forks}} < $g{numdevs} ) ;

   # Now split up our data amongst our forks
   while(@devices or $active_forks) {
      foreach my $fork (sort {$a <=> $b} keys %{$g{forks}}) {
         # First lets see if our fork is working on a device
         if(defined $g{forks}{$fork}{dev}) {
            my $dev = $g{forks}{$fork}{dev};

            # It is, lets see if its ready to give us some data
            my $select = IO::Select->new($g{forks}{$fork}{CS});
            if($select->can_read(0.01)) {

               do_log("DEBUG SNMP: Fork $fork has data for device $dev, reading it",3) if $g{debug};
               # Okay, we know we have something in the buffer, keep reading
               # till we get an EOF
               my $data_in = '';
               eval {
                  local $SIG{ALRM} = sub { die "Timeout waiting for EOF from fork\n" };
                  alarm 15;
                  do {
                     my $read = $g{forks}{$fork}{CS}->getline();
                     if (defined $read and $read ne '') {
                        $data_in .= $read;
                     } else {
                        select undef, undef, undef, 0.001;
                     }
                  } until $data_in =~ s/\nEOF\n$//s;
                  alarm 0;
               };
               if($@) {
                  do_log("Fork $g{forks}{$fork}, pid $g{forks}{$fork}{pid} stalled on device $dev: $@. Killing this fork.",1);
                  kill 15, $g{forks}{$fork}{pid} or do_log("Sending $fork TERM signal failed: $!",2);
                  close $g{forks}{$fork}{CS} or do_log("Closing socket to fork $fork failed: $!",2);
                  delete $g{forks}{$fork};
                  next;
               }
               do_log("DEBUG SNMP: Fork $fork returned complete message for device $dev",3) if $g{debug};

               # Looks like we got some data
               my $hashref = thaw($data_in);
               my %returned;
               if (defined $hashref) {
                  do_log("DEBUG SNMP: Dethawing data for $dev",0) if $g{debug};
                  %returned = %{ thaw($data_in) };

                  # If we got good data, reset the fail counter to 0
                  $g{fail}{$dev} = 0;
                  # increment the per-fork polled device counter
                  $g{forks}{$fork}{polled}++;
               } else {
                  print "failed thaw on $dev\n";
                  next;
               }

               # Sift through returned errors
               for my $error (keys %{$returned{error}}) {
                  my $fatal = $returned{error}{$error};
                  do_log("ERROR: $error", 2);

                  # Incrememnt our fail counter if the query died fatally
                  ++$g{fail}{$dev} if $fatal;
               }
               delete $returned{error};

               # Go through and extract our maxrep values
               for my $oid (keys %{$returned{maxrep}}) {
                  my $val = $returned{maxrep}{$oid};
                  $g{max_rep_hist}{$dev}{$oid} = $val;
                  delete $returned{maxrep}{$oid};
               }
               delete $returned{maxrep};
               # Now add the rest to our outgoing hash
               %{$g{snmp_data}{$dev}} = %returned;

               # Now put our fork into an idle state
               --$active_forks;
               delete $g{forks}{$fork}{dev};

            # No data, lets make sure we're not hung
            } else {
               my $pid = $g{forks}{$fork}{pid};
               # See if we've exceeded our max poll time
               if((time - $g{forks}{$fork}{time}) > $g{maxpolltime}) {
                  do_log("WARNING: Fork $fork ($pid) exceeded poll time polling $dev",0);
                  # Kill it
                  kill 15, $pid or do_log("WARNING: Sending fork $fork TERM signal failed: $!",0);
                  close $g{forks}{$fork}{CS} or do_log("WARNING: Closing socket to fork $fork failed: $!",1);
                  delete $g{forks}{$fork};
                  --$active_forks;
                  fork_queries();

                  # Increment this hosts fail counter
                  # We could add it back to the queue, but that would be unwise
                  # as if thise host is causing snmp problems, it could wonk
                  # our poll time
                  ++$g{fail}{$dev};

               # We haven't exceeded our poll time, but make sure its still live
               } elsif (!kill 0, $pid) {
                  # Whoops, looks like our fork died somewhow
                  do_log("Fork $fork ($pid) died polling $dev",0);
                  close $g{forks}{$fork}{CS} or do_log("Closing socket to fork $fork failed: $!",1);
                  delete $g{forks}{$fork};
                  --$active_forks;
                  fork_queries();

                  # See above comment
                  ++$g{fail}{$dev};
               }
            }
         }

         # If our forks are idle, give them something to do
         if(!defined $g{forks}{$fork}{dev} and @devices) {
            my $dev = shift @devices;

            $g{forks}{$fork}{dev} = $dev;

            # Set our retries lower if this host has a bad history
            if(defined $g{fail}{$dev} and $g{fail}{$dev} > 0) {
               my $retries = $g{snmptries} - $g{fail}{$dev};
               $retries = 1 if $retries < 1;
               $snmp_input->{$dev}{retries} = $retries;
            } else {
               $snmp_input->{$dev}{retries} = $g{snmptries};
            }

            # set out timeout
            $snmp_input->{$dev}{timeout} = $g{snmptimeout};

            # Now send our input to the fork
            my $serialized = nfreeze($snmp_input->{$dev});
            eval {
               local $SIG{ALRM} = sub { die "Timeout sending polling task data to fork\n" };
               alarm 15;
               $g{forks}{$fork}{CS}->print("$serialized\nEOF\n");
               alarm 0;
            };
            if($@) {
               do_log("Fork $g{forks}{$fork}, pid $g{forks}{$fork}{pid} not responding: $@. Killing this fork.",0);
               kill 15, $g{forks}{$fork}{pid} or do_log("Sending TERM signal to fork $fork failed: $!",0);
               close $g{forks}{$fork}{CS} or do_log("Closing socket to fork $fork failed: $!",1);
               delete $g{forks}{$fork};
               next;
            }

            ++$active_forks;
            $g{forks}{$fork}{time} = time;
         }

         # If our fork is idle and has been for more than the cycle time
         #  make sure it is still alive
         if(!defined $g{forks}{$fork}{dev}) {
            my $idletime = time - $g{forks}{$fork}{time};
            next if ($idletime <= $g{cycletime});
            if (defined $g{forks}{$fork}{pinging}) {
               do_log("DEBUG SNMP: Fork $fork was pinged, checking for reply",4) if $g{debug};
               my $select = IO::Select->new($g{forks}{$fork}{CS});
               if($select->can_read(0.01)) {

                  do_log("DEBUG SNMP: Fork $fork has data, reading it",4) if $g{debug};
                  # Okay, we know we have something in the buffer, keep reading
                  # till we get an EOF
                  my $data_in = '';
                  eval {
                     local $SIG{ALRM} = sub { die "Timeout waiting for EOF from fork" };
                     alarm 5;
                     do {
                        my $read = $g{forks}{$fork}{CS}->getline();
                        if(defined $read and $read ne '') {
                           $data_in .= $read ;
                        } else {
                           select undef, undef, undef, 0.001 ;
                        }
                     } until $data_in =~ s/\nEOF\n$//s;
                     alarm 0;
                  };
                  if($@) {
                     do_log("Fork $fork, pid $g{forks}{$fork}{pid} stalled on reply to ping: $@. Killing this fork.");
                     kill 15, $g{forks}{$fork}{pid} or do_log("Sending $fork TERM signal failed: $!");
                     close $g{forks}{$fork}{CS} or do_log("Closing socket to fork $fork failed: $!");
                     delete $g{forks}{$fork};
                     next;
                  }
                  do_log("DEBUG SNMP: Fork $fork returned complete message for ping request",4) if $g{debug};

                  my $hashref = thaw($data_in);
                  my %returned;
                  if (defined $hashref) {
                     do_log("DEBUG SNMP: Dethawing data for ping of fork $fork",4) if $g{debug};
                     %returned = %{ thaw($data_in) };
                  } else {
                     print "failed thaw for ping of fork $fork\n";
                     next;
                  }
                  if (defined $returned{pong}) {
                     $g{forks}{$fork}{time} = time;
                     do_log("Fork $fork responded to ping request $returned{ping} with $returned{pong} at $g{forks}{$fork}{time}",4) if $g{debug};
                     delete $g{forks}{$fork}{pinging};
                  } else {
                     do_log("Fork $fork didn't send an appropriate response, killing it",4) if $g{debug};
                     kill 15, $g{forks}{$fork}{pid} or do_log("Sending $fork TERM signal failed: $!");
                     close $g{forks}{$fork}{CS} or do_log("Closing socket to fork $fork failed: $!");
                     delete $g{forks}{$fork};
                     next;
                  }

               } else {
                  do_log("DEBUG SNMP: Fork $fork seems not to have replied to our ping, killing it",4);
                  kill 15, $g{forks}{$fork}{pid} or do_log("Sending $fork TERM signal failed: $!");
                  close $g{forks}{$fork}{CS} or do_log("Closing socket to fork $fork failed: $!");
                  delete $g{forks}{$fork};
                  next;
               }

            } else {
               my %ping_input = ('ping' => time);
               do_log("Fork $fork has been idle for more than cycle time, pinging it at $ping_input{ping}",4) if $g{debug};
               my $serialized = nfreeze(\%ping_input);
               eval {
                  local $SIG{ALRM} = sub { die "Timeout sending polling task data to fork\n" };
                  alarm 15;
                  $g{forks}{$fork}{CS}->print("$serialized\nEOF\n");
                  alarm 0;
               };
               if($@) {
                  do_log("Fork $g{forks}{$fork}, pid $g{forks}{$fork}{pid} not responding: $@. Killing this fork.");
                  kill 15, $g{forks}{$fork}{pid} or do_log("Sending TERM signal to fork $fork failed: $!");
                  close $g{forks}{$fork}{CS} or do_log("Closing socket to fork $fork failed: $!");
                  delete $g{forks}{$fork};
                  next;
               }
               $g{forks}{$fork}{pinging} = 1;
            }
         }
      }
   }
}

# Start our forked query processes, if needed
sub fork_queries {
   # Close our DB handle to avoid forked sneakiness
   $g{dbh}->disconnect() if defined $g{dbh} and $g{dbh} ne '';

   # We should only enter this loop if we are below numforks
   #    while(keys %{$g{forks}} < $g{numforks}) {
   while(keys %{$g{forks}} < $g{numforks} && keys %{$g{forks}} < $g{numdevs}) {
      my $num = 1;
      my $pid;

      # Find our next available placeholder
      for (sort {$a <=> $b} keys %{$g{forks}})
      {++$num and next if defined $g{forks}{$num}; last}
      do_log("Starting fork number $num") if $g{debug};

      # Open up our communication sockets
      socketpair(
         $g{forks}{$num}{CS},     # Child socket
         $g{forks}{$num}{PS},     # Parent socket
         AF_UNIX,
         SOCK_STREAM,
         PF_UNSPEC)
         or do_log("Unable to open forked socket pair ($!)") and exit;

      $g{forks}{$num}{CS}->autoflush(1);
      $g{forks}{$num}{PS}->autoflush(1);

      if($pid = fork) {
         # Parent code here
         do_log("Fork number $num started with pid $pid") if $g{debug};
         close $g{forks}{$num}{PS} or do_log("Closing socket to ourself failed: $!\n"); # don't need to communicate with ourself
         $g{forks}{$num}{pid} = $pid;
         $g{forks}{$num}{time} = time;
         $g{forks}{$num}{CS}->blocking(0);
      } elsif(defined $pid) {
         # Child code here
         $g{parent} = 0;              # We aren't the parent any more...
         do_log("DEBUG SNMP: Fork $num using sockets $g{forks}{$num}{PS} <-> $g{forks}{$num}{CS} for IPC") if $g{debug};
         foreach (sort {$a <=> $b} keys %{$g{forks}}) {
            do_log("DEBUG SNMP: Fork $num closing socket (child $_) $g{forks}{$_}{PS}") if $g{debug};
            $g{forks}{$_}{CS}->close or do_log("Closing socket for fork $_ failed: $!"); # Same as above
         }
         $0 = "devmon-$num";                 # Remove our 'master' tag
         fork_sub($num);                # Enter our neverending query loop
         exit;                   # We should never get here, but just in case
      } else {
         do_log("Error spawning snmp worker fork ($!)",0);
      }
   }

   # Now reconnect to the DB
   db_connect(1);
}

# Subroutine that the forked query processes "live" in
sub fork_sub {
   my ($fork_num) = @_;
   my $sock = $g{forks}{$fork_num}{PS};

   DEVICE: while(1) { # We should never leave this loop
      # Our outbound data hash
      my %data_out = ();

      # Heres a blocking call
      my $serialized = '';
      my $string_in;
      do {
         $string_in = undef;

         # Wrap our getline in alarm code to make sure our parent doesn't die
         # messily and leave us hanging around
         eval {
            local $SIG{ALRM} = sub { die "Timeout" };
            alarm $g{cycletime} * 2;
            $string_in = $sock->getline();
            alarm 0;
         };

         # Our getline timed out, which means we haven't gotten any data
         # in a while.  Make sure our parent is still there
         if($@) {
            do_log("Fork $fork_num timed out waiting for data from parent: $@",3);
            if (!kill 0, $g{mypid}) {
               do_log("Parent is no longer running, fork $fork_num exiting");
               exit 1;
            }
            my $sleeptime = $g{cycletime} / 2;
            do_log("Parent ($g{mypid}) seems to be running, fork $fork_num sleeping for $sleeptime",3);
            sleep $sleeptime;
         }

         $serialized .= $string_in if defined $string_in;

      } until $serialized =~ s/\nEOF\n$//s;
      do_log("DEBUG SNMP($fork_num): Got EOF in message, attempting to thaw",4) if $g{debug};

      # Now decode our serialized data scalar
      my %data_in;
      eval {
         %data_in = %{thaw($serialized)};
      };
      if ($@) {
         do_log("DEBUG SNMP($fork_num): thaw failed attempting to thaw $serialized: $@",4) if $g{debug};
         do_log("DEBUG SNMP($fork_num): Replying to corrupt message with a pong",4) if $g{debug};
         $data_out{ping} = '0';
         $data_out{pong} = time;
         send_data($sock,\%data_out);
         next DEVICE;
      }

      if (defined $data_in{ping}) {
         do_log("DEBUG SNMP($fork_num): Received ping from master $data_in{ping},replying",4) if $g{debug};
         $data_out{ping} = $data_in{ping};
         $data_out{pong} = time;
         send_data($sock,\%data_out);
         next DEVICE;
      }

      # Do some basic checking
      if(!defined $data_in{nonreps} and !defined $data_in{reps}) {
         my $error_str =
         "No oids to query for $data_in{dev}, skipping";
         $data_out{error}{$error_str} = 1;
         send_data($sock, \%data_out);
         next DEVICE;
      } elsif(!defined $data_in{ver}) {
         my $error_str =
         "No snmp version found for $data_in{dev}";
         $data_out{error}{$error_str} = 1;
         send_data($sock, \%data_out);
         next DEVICE;
      }

      #print "%data_in:\n" ;print Data::Dumper->Dumper(\%data_in) ;
      #
      # Get SNMP variables
      my %snmpvars ;
      $snmpvars{RemotePort} = $data_in{port} || 161; # Default to 161 if not specified
      $snmpvars{DestHost}   = (defined $data_in{ip} and $data_in{ip} ne '') ? $data_in{ip} : $data_in{dev} ;
      $snmpvars{Timeout}    = $data_in{timeout} * 1000000 ;
      $snmpvars{Retries}    = $data_in{retries} ;

      $snmpvars{UseNumeric} = 1 ;

      # Establish SNMP session
      my $session;

      if($data_in{ver} eq '1') {
         $snmpvars{Version} = 1 ;
         $snmpvars{Community}  = $data_in{cid} if defined $data_in{cid} ;

      } elsif($data_in{ver} =~ /^2c?$/) {
         $snmpvars{Version} = 2 ;
         $snmpvars{Community}  = $data_in{cid} if defined $data_in{cid} ;

      } elsif($data_in{ver} eq '3') {
         $snmpvars{Version} = 3 ;
         # We store the security name for v3 als in cid so we keep the same data format
         $snmpvars{SecName}    = $data_in{cid} if defined $data_in{cid} ;

      # Whoa, we don't support this version of SNMP
      } else {
         my $error_str =
         "Unsupported SNMP version for $data_in{dev} ($data_in{ver})";
         $data_out{error}{$error_str} = 1;
         send_data($sock, \%data_out);
         next DEVICE;
      }

      #print "%snmpvars:\n" ;print Data::Dumper->Dumper(\%snmpvars) ;
      $session = new SNMP::Session(%snmpvars) ;

      foreach my $oid (sort keys %{$data_in{nonreps}}) {
         next if defined $data_out{error} ;

         my $vb = new SNMP::Varbind([".$oid"]);
         my $val = $session->get($vb);
         if ( $val ) {
            $data_out{$oid}{val}  = $val;
            $data_out{$oid}{time} = time;
         } else {
            $data_out{error}{$session->{ErrorStr}} = 1;
            last ;
         }
      }

      foreach my $oid (sort keys %{$data_in{reps}}) {
         next if defined $data_out{error} ;

         my $vb = new SNMP::Varbind([".$oid"]);
         my $val ;
         # for (INITIALIZE; TEST; STEP) {
         for ( $val = $session->getnext($vb);
               $vb->tag eq ".$oid" and not $session->{ErrorNum} ;
               $val = $session->getnext($vb)
            ) {
            $data_out{$oid}{val}{$vb->iid} = $val;
            $data_out{$oid}{time}{$vb->iid} = time;
            $data_out{maxrep}{$oid} ++ ;
         }
      }

      #print "%data_out:\n" ;print Data::Dumper->Dumper(\%data_out) ;
      #
      send_data($sock, \%data_out);
   }
}

# Make sure that forks are still alive
sub check_forks {
   for my $fork (keys %{$g{forks}}) {
      my $pid = $g{forks}{$fork}{pid};
      if (!kill 0, $pid) {
         do_log("Fork $fork with pid $pid died, cleaning up",3);
         close $g{forks}{$fork}{CS} or do_log("Closing child socket failed: $!",2);
         delete $g{forks}{$fork};
      }
   }
}

# Subroutine to send an error message back to the parent process
sub send_data {
   my ($sock, $data_out) = @_;
   my $serialized = nfreeze ($data_out);
   $sock->print("$serialized\nEOF\n");
}

# Reap dead forks
sub REAPER {
   my $fork;
   while (($fork = waitpid(-1, WNOHANG)) > 0) {sleep 1}
   $SIG{CHLD} = \&REAPER;
}
