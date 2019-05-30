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
use BER;
use Socket;
use IO::Handle;
use IO::Select;
use IO::Socket::INET;
use SNMP_Session;
use POSIX ":sys_wait_h";
use Math::BigInt;
use Storable qw(nfreeze thaw);
use dm_config;

# Our global variable hash
use vars qw(%g);
*g = \%dm_config::g;

my $max_pdu_len = 16384;  # default is 8000
# Set some of our global SNMP variables
$BER::pretty_print_timeticks = 0;
$SNMP_Session::suppress_warnings = $g{debug} ? 0 : 1;

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
   do_log("Getting device status from Xymon at " . $g{dispserv} . ":" . $g{dispport},1);
   %{$g{xymon_color}} = ();
   my $sock = IO::Socket::INET->new (
      PeerAddr => $g{dispserv},
      PeerPort => $g{dispport},
      Proto    => 'tcp',
      Timeout  => 10,
   );

   if(defined $sock) {
      print $sock "xymondboard test=^conn\$ fields=hostname,color,line1";
      shutdown($sock, 1);
      while(<$sock>) {
         my ($device,$color,$line1) = split /\|/;
         my ($l1col) = ($line1 =~ /^(\w+)/);
         do_log("DEBUG SNMP: $device has Xymon status $color ($l1col)",2) if $g{debug};
         $g{xymon_color}{$device} = $color ne "blue" && $color || $l1col;
      }
   }

   # Build our query hash
   QUERYHASH: for my $device (sort keys %{$g{dev_data}}) {

      # Skip this device if we werent able to reach it during update_indexes
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
      do_log("No vendor/model '$vendor/$model' templates for host " .
         "$device, skipping.", 0)
         and next QUERYHASH if !defined $g{templates}{$vendor}{$model};

      # If our tests = 'all', create a string with all the tests in it
      $tests = join ',', keys %{$g{templates}{$vendor}{$model}{tests}}
      if $tests eq 'all';

      $snmp_input{$device}{dev_ip}   = $g{dev_data}{$device}{ip};
      $snmp_input{$device}{cid}      = $g{dev_data}{$device}{cid};
      $snmp_input{$device}{port}     = $g{dev_data}{$device}{port};
      $snmp_input{$device}{dev}      = $device;

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
   # Start forks if needed
   fork_queries() if ((keys %{$g{forks}} < $g{numforks} && keys %{$g{forks}} < $g{numdevs}) or (keys %{$g{forks}} == 0 and $g{numdevs} > 2 )) ;

   # Now split up our data amongst our forks
   my @devices = keys %{$snmp_input};

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

               # We havent exceeded our poll time, but make sure its still live
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
                     do_log("Fork $fork didnt send an appropriate response, killing it",4) if $g{debug};
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
   while((keys %{$g{forks}} < $g{numforks} && keys %{$g{forks}} < $g{numdevs}) or (keys %{$g{forks}} == 0 and  $g{numdevs} > 2))  {
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

      # Get SNMP variables
      my $snmp_cid  = $data_in{cid};
      my $snmp_port = $data_in{port} || 161; # Default to 161 if not specified
      my $snmp_ver  = $data_in{ver};
      my $dev_ip    = $data_in{dev_ip};
      my $dev       = $data_in{dev};
      my $retries   = $data_in{retries};
      my $timeout   = $data_in{timeout};

      my $host = (defined $dev_ip and $dev_ip ne '') ? $dev_ip : $dev;

      # Establish SNMP session
      my $session;
      my $sess_err = 0;

      if(!defined $data_in{nonreps} and !defined $data_in{reps}) {
         my $error_str =
         "No oids to query for $dev, skipping";
         $data_out{error}{$error_str} = 1;
         send_data($sock, \%data_out);
         next DEVICE;
      } elsif(!defined $snmp_ver) {
         my $error_str =
         "No snmp version found for $dev";
         $data_out{error}{$error_str} = 1;
         send_data($sock, \%data_out);
         next DEVICE;
      } elsif($snmp_ver eq '1') {
         $session = SNMPv1_Session->open($host, $snmp_cid, $snmp_port,$max_pdu_len);
      } elsif($snmp_ver =~ /^2c?$/) {
         $session = SNMPv2c_Session->open($host, $snmp_cid, $snmp_port,$max_pdu_len);
         $session->{use_getbulk} = 1;

      # Whoa, we don't support this version of SNMP
      } else {
         my $error_str =
         "Unsupported SNMP version for $dev ($snmp_ver)";
         $data_out{error}{$error_str} = 1;
         send_data($sock, \%data_out);
         next DEVICE;
      }

      # Set our retries & timeouts
      SNMP_Session::set_retries($session, $retries);
      SNMP_Session::set_timeout($session, $timeout);

      # We can't recover from a failed snmp connect
      if($sess_err) {
         my $snmp_err;
         ($snmp_err = $SNMP_Session::errmsg) =~ s/\n.*//s;
         my $error_str =
         "Failed SNMP session to $dev ($snmp_err)";
         $data_out{error}{$error_str} = 1;
         send_data($sock, \%data_out);
         next DEVICE;
      }

      # Do SNMP gets
      my $failed_query = 0;
      my @nrep_oids;
      my @nrep_oids_my;
      my $oids_num = keys %{$data_in{nonreps}};
      my $ii = 0;

      do_log("DEBUG SNMP($fork_num): $oids_num",0) if $g{debug};
      for my $oid (keys  %{$data_in{nonreps}}) {
         do_log("DEBUG SNMP($fork_num): $ii => $oid ",0) if $g{debug};
         $ii++;
         push @nrep_oids_my, $oid;
         push @nrep_oids, encode_oid(split /\./, $oid);
      }

      my @nrep_oids_temp;
      my $nrep_oids_temp_cpt = 0;
      for (my $index = 0; $index < $oids_num; $index++) {
         ++$nrep_oids_temp_cpt;
         push @nrep_oids_temp, $nrep_oids[$index];
         do_log("DEBUG SNMP($fork_num): Adding ID => $nrep_oids_temp_cpt OID =>$nrep_oids_my[$index]",0) if $g{debug};

         #if ($nrep_oids_temp_cpt == 10) {
         do_log("DEBUG SNMP($fork_num): Pooling $nrep_oids_temp_cpt oids",0) if $g{debug};
         if(@nrep_oids_temp) {
            if($session->get_request_response(@nrep_oids_temp)) {
               my $response = $session->pdu_buffer;
               my ($bindings) = $session->decode_get_response($response);
               if(!defined $bindings or $bindings eq '') {
                  my $snmp_err;
                  do_log("DEBUG SNMP($fork_num): $SNMP_Session::errmsg",0) if $g{debug};
                  ($snmp_err = $SNMP_Session::errmsg) =~ s/\n.*//s;
                  my $error_str = "snmpget $dev ($snmp_err)";
                  $data_out{error}{$error_str} = 0;
                  ++$failed_query;
               }

               # Go through our results, decode them, and add to our return hash
               while ($bindings ne '') {
                  my $binding;
                  ($binding,$bindings) = decode_sequence($bindings);
                  my ($oid,$value) = decode_by_template($binding, "%O%@");
                  $oid   = pretty_print($oid);
                  $value = pretty_print($value);
                  $data_out{$oid}{val}  = $value;
                  $data_out{$oid}{time} = time;
               }
            } else {
               my $snmp_err;
               ($snmp_err = $SNMP_Session::errmsg) =~ s/\n.*//s;
               my $error_str = "snmpget $dev ($snmp_err)";
               $data_out{error}{$error_str} = 1;
               send_data($sock, \%data_out);
               next DEVICE;
            }
            $nrep_oids_temp_cpt = 0;
            @nrep_oids_temp = ();
         }
         #} # end if
      } # end for

      # Now do SNMP walks
      for my $oid (keys %{$data_in{reps}}) {
         my $max_reps = $data_in{reps}{$oid};
         $max_reps = $g{max_reps} if !defined $max_reps or $max_reps < 2;

         # Encode our oid and walk it
         my @oid_array = split /\./, $oid;
         my $num_reps = $session->map_table_4(
            [\@oid_array],
            sub {
               # Decode our result and add to our result hash
               my ($leaf, $value) = @_;
               $value = pretty_print($value);
               $data_out{$oid}{val}{$leaf} = $value;
               $data_out{$oid}{time}{$leaf} = time;
            },
            $max_reps
         );

         # Catch any failures
         if(!defined $num_reps or $num_reps == 0) {
            my $snmp_err;
            do_log("DEBUG SNMP($fork_num): $SNMP_Session::errmsg",0) if $g{debug};
            ($snmp_err = $SNMP_Session::errmsg) =~ s/\n.*//s;
            if ($snmp_err ne '') {
               my $error_str =
               "Error walking $oid for $dev ($snmp_err)";
               $data_out{error}{$error_str} = 0;
               ++$failed_query;
            }
         } else {
            # Record our maxrep value for our next poll cycle
            $data_out{maxrep}{$oid} = $num_reps + 1;
         }

         do_log("DEBUG SNMP($fork_num): Failed queries $failed_query",0) if ($g{debug} and $failed_query gt 0);
         # We don't want to do every table if we are failing alot of walks
         if($failed_query > 6) {
            my $error_str =
            "Failed too many queries on $dev, aborting query";
            $data_out{error}{$error_str} = 1;
            send_data($sock, \%data_out);
            $session->close();
            next DEVICE;
         }
      }

      # Now are done gathering data, close the session and return our hash
      $session->close();
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
