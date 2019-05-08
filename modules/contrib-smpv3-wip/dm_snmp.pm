package dm_snmp;
require Exporter;
@ISA    = qw(Exporter);
@EXPORT = qw(poll_devices snmp_query);

#    Devmon: An SNMP data collector & page generator for the BigBrother &
#    Hobbit network monitoring systems
#    Copyright (C) 2005-2006  Eric Schwimmer
#    Copyright (C) 2007  Francois Lacroix
#    Copyright (C) 2018 Stef Coene <stef.coene@docum.org>, <stef.coene@axi.be>
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
  use POSIX ":sys_wait_h";
  use Math::BigInt;
  use Storable qw(nfreeze thaw);
  use dm_config;

  use Net::SNMP;

 # Our global variable hash
  use vars qw(%g);
  *g = \%dm_config::g;

 my $max_pdu_len = 16384;  # default is 8000
 # Set some of our global SNMP variables
  $BER::pretty_print_timeticks = 0;
  $SNMP_Session::suppress_warnings = $g{'debug'} ? 0 : 1;

 # Fiddle with some of our storable settings to correct byte order...
  $Storable::interwork_56_64bit = 1;

 # Add a wait for our dead forks
  $SIG{CHLD} = \&REAPER;

 # Sub that, given a hash of device data, will query specified oids for
 # each device and return a hash of the snmp query results
  sub poll_devices {
    # clear per-fork polled device counters
    foreach (keys %{$g{'forks'}} ) {
      $g{'forks'}{$_}{'polled'} = 0;
    }

    do_log("DEBUG SNMP: running poll_devices()",0) if $g{'debug'};
    do_log("Starting snmp queries",1);
    $g{'snmppolltime'} = time;

    my %snmp_input = ();
    %{$g{'snmp_data'}} = ();

   # Query our hobbit server for device reachability status
   # we dont want to waste time querying devices that are down
   # Note: this doesn't work for the original BigBrother server
    if($g{'bbtype'} eq 'hobbit' or $g{'bbtype'} eq 'xymon') {
      do_log("Getting device status from $g{'bbtype'} at " . $g{'dispserv'} . ":" . $g{'dispport'},1);
      %{$g{'hobbit_color'}} = ();
      my $sock = IO::Socket::INET->new (
        PeerAddr => $g{'dispserv'},
        PeerPort => $g{'dispport'},
        Proto    => 'tcp',
        Timeout  => 10,
      );

      if(defined $sock) {
        print $sock "hobbitdboard test=^conn\$ fields=hostname,color,line1";
        shutdown($sock, 1);
        while(<$sock>) {
          my ($device,$color,$line1) = split /\|/;
          my ($l1col) = ($line1 =~ /^(\w+)/);
          do_log("DEBUG SNMP: $device has $g{'bbtype'} status $color ($l1col)",2) if $g{debug};
          $g{'hobbit_color'}{$device} = $color ne "blue" && $color || $l1col;
        }
      }
    }

   # Build our query hash
    QUERYHASH: for my $device (sort keys %{$g{'dev_data'}}) {

     # Skip this device if we werent able to reach it during update_indexes
     # next unless $indexes->{$device}{'reachable'};

     # Skip this device if we are running a hobbit server and the
     # server thinks that it isnt reachable
      if(defined $g{'hobbit_color'}{$device} and
         $g{'hobbit_color'}{$device} ne 'green') {
        do_log("$device has a non-green $g{'bbtype'} status, skipping SNMP.", 2);
        next QUERYHASH;
      }

      my %non_repeaters = ();

      my %repeaters = ();
      my $vendor = $g{'dev_data'}{$device}{'vendor'};
      my $model  = $g{'dev_data'}{$device}{'model'};
      my $tests  = $g{'dev_data'}{$device}{'tests'};

     # Make sure we have our device_type info
      do_log("No vendor/model '$vendor/$model' templates for host " .
             "$device, skipping.", 0)
        and next QUERYHASH if !defined $g{'templates'}{$vendor}{$model};

     # If our tests = 'all', create a string with all the tests in it
      $tests = join ',', keys %{$g{'templates'}{$vendor}{$model}{'tests'}}
        if $tests eq 'all';

      $snmp_input{$device}{'dev_ip'} = $g{'dev_data'}{$device}{'ip'};
      $snmp_input{$device}{'cid'}    = $g{'dev_data'}{$device}{'cid'};
      $snmp_input{$device}{'port'}   = $g{'dev_data'}{$device}{'port'};
      $snmp_input{$device}{'dev'}    = $device;

      $snmp_input{$device}{'ver'}    = $g{'dev_data'}{$device}{'ver'};

      # SNMP v3 options
      $snmp_input{$device}{'USERNAME'}         = $g{'dev_data'}{$device}{'USERNAME'}         if defined $g{'dev_data'}{$device}{'USERNAME'} ;
      $snmp_input{$device}{'PASSPHRASE_AUTH'}  = $g{'dev_data'}{$device}{'PASSPHRASE_AUTH'}  if defined $g{'dev_data'}{$device}{'PASSPHRASE_AUTH'} ;
      $snmp_input{$device}{'PROTOCOL_AUTH'}    = $g{'dev_data'}{$device}{'PROTOCOL_AUTH'}    if defined $g{'dev_data'}{$device}{'PROTOCOL_AUTH'} ;
      $snmp_input{$device}{'PASSPHRASE_PRIV'}  = $g{'dev_data'}{$device}{'PASSPHRASE_PRIV'}  if defined $g{'dev_data'}{$device}{'PASSPHRASE_PRIV'} ;
      $snmp_input{$device}{'PROTOCOL_PRIV'}    = $g{'dev_data'}{$device}{'PROTOCOL_PRIV'}    if defined $g{'dev_data'}{$device}{'PROTOCOL_PRIV'} ;

      do_log("Querying $device for tests $tests", 3);

     # Go through each of the tests and determine what their type is
      TESTTYPE: for my $test (split /,/, $tests) {

       # Make sure we have our device_type info
        do_log("No test '$test' template found for host $device, skipping.", 0)
          and next TESTTYPE if
          !defined $g{'templates'}{$vendor}{$model}{'tests'}{$test};

       # Create a shortcut
        my $tmpl    = \%{$g{'templates'}{$vendor}{$model}{'tests'}{$test}};
        #my $snmpver = $g{'templates'}{$vendor}{$model}{'snmpver'}; 

       # Determine what type of snmp version we are using
       # Use the highest snmp variable type we find amongst all our tests
       # $snmp_input{$device}{'ver'} = $snmpver if
       #   !defined $snmp_input{$device}{'ver'} or
       #   $snmp_input{$device}{'ver'} < $snmpver;

       # Go through our oids and add them to our repeater/non-repeater hashs
        for my $oid (keys %{$tmpl->{'oids'}}) {
          my $number = $tmpl->{'oids'}{$oid}{'number'};

         # Skip translated oids
          next if !defined $number;

         # If this is a repeater... (branch)
          if($tmpl->{'oids'}{$oid}{'repeat'}) {
            $snmp_input{$device}{'reps'}{$number} = 1;

           # If we've queried this device before, use the previous number of
           # repeats to populate our repeater value
            $snmp_input{$device}{'reps'}{$number} =
              $g{'max_rep_hist'}{$device}{$number};
          }

         # Otherwise this is a nonrepeater (leaf)
          else {
            $snmp_input{$device}{'nonreps'}{$number} = 1;
          }
        }
      }
    }

   # Throw the query hash to the forked query processes
    snmp_query(\%snmp_input);

   # Record how much time this all took
    $g{'snmppolltime'} = time - $g{'snmppolltime'};

   # Dump some debug info if we need to
    if($g{'debug'}) {
      for my $dev (sort keys %{$g{'dev_data'}}) {
        my $expected = (scalar keys %{$snmp_input{$dev}{'nonreps'}}) +
          (scalar keys %{$snmp_input{$dev}{'reps'}});
        my $received = (scalar keys %{$g{'snmp_data'}{$dev}});
        do_log("SNMP: Queried $dev: expected $expected, received $received",0)
          if ($expected != $received);
      }
    }
  }

 # Query SNMP data on all devices
  sub snmp_query {
    my ($snmp_input) = @_;
    my $active_forks = 0;
    my $numdevices = scalar (keys %{$snmp_input});

   # Check the status of any currently running forks
    &check_forks();

   # Start forks if needed
    fork_queries($numdevices) if (keys %{$g{'forks'}} < $g{'numforks'} && keys %{$g{'forks'}} < $numdevices ) ;

   # Now split up our data amongst our forks
    my @devices = keys %{$snmp_input};

    while(@devices or $active_forks) {
      foreach my $fork (sort {$a <=> $b} keys %{$g{'forks'}}) {

       # First lets see if our fork is working on a device
        if(defined $g{'forks'}{$fork}{'dev'}) {
          my $dev = $g{'forks'}{$fork}{'dev'};
         # It is, lets see if its ready to give us some data
          my $select = IO::Select->new($g{'forks'}{$fork}{'CS'});
          if($select->can_read(0.01)) {

           do_log("DEBUG SNMP: Fork $fork has data for device $dev, reading it",3) if $g{'debug'};
           # Okay, we know we have something in the buffer, keep reading
           # till we get an EOF
            my $data_in = '';
            eval {
              local $SIG{ALRM} = sub { die "Timeout waiting for EOF from fork\n" };
              alarm 15;
              do {
                my $read = $g{'forks'}{$fork}{'CS'}->getline();
                if(defined $read and $read ne '') {$data_in .= $read}
                else {select undef, undef, undef, 0.001}
              } until $data_in =~ s/\nEOF\n$//s;
              alarm 0;
            };
            if($@) {
              do_log("Fork $g{'forks'}{$fork}, pid $g{'forks'}{$fork}{'pid'} stalled on device $dev: $@. Killing this fork.",1);
              kill 15, $g{'forks'}{$fork}{'pid'} or do_log("Sending $fork TERM signal failed: $!",2);
	      close $g{'forks'}{$fork}{'CS'} or do_log("Closing socket to fork $fork failed: $!",2);
	      delete $g{'forks'}{$fork};
	      next;
            }
            do_log("DEBUG SNMP: Fork $fork returned complete message for device $dev",3) if $g{'debug'};

           # Looks like we got some data
            my $hashref = thaw($data_in);
            my %returned;
            if (defined $hashref) {
              do_log("DEBUG SNMP: Dethawing data for $dev",0) if $g{'debug'};
              %returned = %{ thaw($data_in) };

             # If we got good data, reset the fail counter to 0
              $g{'fail'}{$dev} = 0;
	     # increment the per-fork polled device counter
	      $g{'forks'}{$fork}{'polled'}++;
            }
            else {
              print "failed thaw on $dev\n";
              next;
            } 

           # Sift through returned errors
            for my $error (keys %{$returned{'error'}}) {
              my $fatal = $returned{'error'}{$error};
              do_log("ERROR: $error", 2);

             # Incrememnt our fail counter if the query died fatally
              ++$g{'fail'}{$dev} if $fatal;
            }
            delete $returned{'error'}; 

           # Go through and extract our maxrep values
            for my $oid (keys %{$returned{'maxrep'}}) {
              my $val = $returned{'maxrep'}{$oid};
              $g{'max_rep_hist'}{$dev}{$oid} = $val;
              delete $returned{'maxrep'}{$oid};
            }
            delete $returned{'maxrep'};
           # Now add the rest to our outgoing hash
            %{$g{'snmp_data'}{$dev}} = %returned;

           # Now put our fork into an idle state
            --$active_forks;
            delete $g{'forks'}{$fork}{'dev'};
          }

         # No data, lets make sure we're not hung
          else {
            my $pid = $g{'forks'}{$fork}{'pid'};
           # See if we've exceeded our max poll time
            if((time - $g{'forks'}{$fork}{'time'}) > $g{'maxpolltime'}) {
              do_log("WARNING: Fork $fork ($pid) exceeded poll time polling $dev",0);
              # Kill it
               kill 15, $pid or do_log("WARNING: Sending fork $fork TERM signal failed: $!",0);
	       close $g{'forks'}{$fork}{'CS'} or do_log("WARNING: Closing socket to fork $fork failed: $!",1);
               delete $g{'forks'}{$fork};
               --$active_forks;
               fork_queries($numdevices);

              # Increment this hosts fail counter
              # We could add it back to the queue, but that would be unwise
              # as if thise host is causing snmp problems, it could wonk
              # our poll time
               ++$g{'fail'}{$dev};
            }

           # We havent exceeded our poll time, but make sure its still live
            elsif (!kill 0, $pid) {
              # Whoops, looks like our fork died somewhow
               do_log("Fork $fork ($pid) died polling $dev",0);
	       close $g{'forks'}{$fork}{'CS'} or do_log("Closing socket to fork $fork failed: $!",1);
               delete $g{'forks'}{$fork};
               --$active_forks;
               fork_queries($numdevices);

              # See above comment
               ++$g{'fail'}{$dev};
            }
          }
        }

       # If our forks are idle, give them something to do
        if(!defined $g{'forks'}{$fork}{'dev'} and @devices) {
          my $dev = shift @devices;

          $g{'forks'}{$fork}{'dev'} = $dev;

         # Set our retries lower if this host has a bad history
          if(defined $g{'fail'}{$dev} and $g{'fail'}{$dev} > 0) {
            my $retries = $g{'snmptries'} - $g{'fail'}{$dev};
            $retries = 1 if $retries < 1;
            $snmp_input->{$dev}{'retries'} = $retries;
          }
          else {
            $snmp_input->{$dev}{'retries'} = $g{'snmptries'};
          }
          
         # set out timeout
          $snmp_input->{$dev}{'timeout'} = $g{'snmptimeout'};

         # Now send our input to the fork
          my $serialized = nfreeze($snmp_input->{$dev});
          eval {
            local $SIG{ALRM} = sub { die "Timeout sending polling task data to fork\n" };
            alarm 15;
            $g{'forks'}{$fork}{'CS'}->print("$serialized\nEOF\n");
            alarm 0;
          };
          if($@) {
            do_log("Fork $g{'forks'}{$fork}, pid $g{'forks'}{$fork}{'pid'} not responding: $@. Killing this fork.",0);
            kill 15, $g{'forks'}{$fork}{'pid'} or do_log("Sending TERM signal to fork $fork failed: $!",0);
	    close $g{'forks'}{$fork}{'CS'} or do_log("Closing socket to fork $fork failed: $!",1);
	    delete $g{'forks'}{$fork};
	    next;
          }

          ++$active_forks;
          $g{'forks'}{$fork}{'time'} = time;
        }

        # If our fork is idle and has been for more than the cycle time
        #  make sure it is still alive
        if(!defined $g{'forks'}{$fork}{'dev'}) {
          my $idletime = time - $g{'forks'}{$fork}{'time'};
          next if ($idletime <= $g{'cycletime'});
          if (defined $g{'forks'}{$fork}{'pinging'}) {
            do_log("DEBUG SNMP: Fork $fork was pinged, checking for reply",4) if $g{'debug'};
            my $select = IO::Select->new($g{'forks'}{$fork}{'CS'});
            if($select->can_read(0.01)) {

           do_log("DEBUG SNMP: Fork $fork has data, reading it",4) if $g{'debug'};
           # Okay, we know we have something in the buffer, keep reading
           # till we get an EOF
            my $data_in = '';
            eval {
              local $SIG{ALRM} = sub { die "Timeout waiting for EOF from fork" };
              alarm 5;
              do {
                my $read = $g{'forks'}{$fork}{'CS'}->getline();
                if(defined $read and $read ne '') {$data_in .= $read}
                else {select undef, undef, undef, 0.001}
              } until $data_in =~ s/\nEOF\n$//s;
              alarm 0;
            };
            if($@) {
              do_log("Fork $fork, pid $g{'forks'}{$fork}{'pid'} stalled on reply to ping: $@. Killing this fork.");
              kill 15, $g{'forks'}{$fork}{'pid'} or do_log("Sending $fork TERM signal failed: $!");
              close $g{'forks'}{$fork}{'CS'} or do_log("Closing socket to fork $fork failed: $!");
              delete $g{'forks'}{$fork};
              next;
            }
            do_log("DEBUG SNMP: Fork $fork returned complete message for ping request",4) if $g{'debug'};

            my $hashref = thaw($data_in);
            my %returned;
            if (defined $hashref) {
              do_log("DEBUG SNMP: Dethawing data for ping of fork $fork",4) if $g{'debug'};
              %returned = %{ thaw($data_in) };
            }
            else {
              print "failed thaw for ping of fork $fork\n";
              next;
            } 
            if (defined $returned{'pong'}) {
              $g{'forks'}{$fork}{'time'} = time;
              do_log("Fork $fork responded to ping request $returned{'ping'} with $returned{'pong'} at $g{'forks'}{$fork}{'time'}",4) if $g{'debug'};
             delete $g{'forks'}{$fork}{'pinging'};
            } else {
              do_log("Fork $fork didnt send an appropriate response, killing it",4) if $g{'debug'};
              kill 15, $g{'forks'}{$fork}{'pid'} or do_log("Sending $fork TERM signal failed: $!");
              close $g{'forks'}{$fork}{'CS'} or do_log("Closing socket to fork $fork failed: $!");
              delete $g{'forks'}{$fork};
              next;
            }

          } else {
            do_log("DEBUG SNMP: Fork $fork seems not to have replied to our ping, killing it",4);
            kill 15, $g{'forks'}{$fork}{'pid'} or do_log("Sending $fork TERM signal failed: $!");
            close $g{'forks'}{$fork}{'CS'} or do_log("Closing socket to fork $fork failed: $!");
            delete $g{'forks'}{$fork};
            next;
          }

          } else {
            my %ping_input = ('ping' => time);
            do_log("Fork $fork has been idle for more than cycle time, pinging it at $ping_input{'ping'}",4) if $g{'debug'};
            my $serialized = nfreeze(\%ping_input);
            eval {
              local $SIG{ALRM} = sub { die "Timeout sending polling task data to fork\n" };
              alarm 15;
              $g{'forks'}{$fork}{'CS'}->print("$serialized\nEOF\n");
              alarm 0;
            };
            if($@) {
              do_log("Fork $g{'forks'}{$fork}, pid $g{'forks'}{$fork}{'pid'} not responding: $@. Killing this fork.");
              kill 15, $g{'forks'}{$fork}{'pid'} or do_log("Sending TERM signal to fork $fork failed: $!");
              close $g{'forks'}{$fork}{'CS'} or do_log("Closing socket to fork $fork failed: $!");
              delete $g{'forks'}{$fork};
              next;
            }
            $g{'forks'}{$fork}{'pinging'} = 1;
	  }
	}
      }
    }
  }


 # Start our forked query processes, if needed
  sub fork_queries {
   # we want to have the snmp incout count to not creat to much forks
    my ($numdevices) = @_;

   # Close our DB handle to avoid forked sneakiness
    $g{'dbh'}->disconnect() if defined $g{'dbh'} and $g{'dbh'} ne '';

   # We should only enter this loop if we are below numforks
    while(keys %{$g{'forks'}} < $g{'numforks'} && keys %{$g{'forks'}} < $numdevices ) {

      my $num = 1;
      my $pid;

     # Find our next available placeholder
      for (sort {$a <=> $b} keys %{$g{'forks'}}) 
        {++$num and next if defined $g{'forks'}{$num}; last}
      do_log("Starting fork number $num") if $g{'debug'};

     # Open up our communication sockets
      socketpair(
        $g{'forks'}{$num}{'CS'},     # Child socket
        $g{'forks'}{$num}{'PS'},     # Parent socket
        AF_UNIX,
        SOCK_STREAM,
        PF_UNSPEC)
        or do_log("Unable to open forked socket pair ($!)") and exit;

      $g{'forks'}{$num}{'CS'}->autoflush(1);
      $g{'forks'}{$num}{'PS'}->autoflush(1);

      if($pid = fork) {
       # Parent code here
        do_log("Fork number $num started with pid $pid") if $g{'debug'};
        close $g{'forks'}{$num}{'PS'} or do_log("Closing socket to ourself failed: $!\n"); # dont need to communicate with ourself
        $g{'forks'}{$num}{'pid'} = $pid;
        $g{'forks'}{$num}{'time'} = time;
        $g{'forks'}{$num}{'CS'}->blocking(0);
      }
      elsif(defined $pid) {
       # Child code here
        $g{'parent'} = 0;              # We arent the parent any more...
        do_log("DEBUG SNMP: Fork $num using sockets $g{'forks'}{$num}{'PS'} <-> $g{'forks'}{$num}{'CS'} for IPC") if $g{'debug'};
	foreach (sort {$a <=> $b} keys %{$g{'forks'}}) {
		do_log("DEBUG SNMP: Fork $num closing socket (child $_) $g{'forks'}{$_}{'PS'}") if $g{'debug'};
	  	$g{'forks'}{$_}{'CS'}->close or do_log("Closing socket for fork $_ failed: $!"); # Same as above
	}
        $0 = "devmon-$num";                 # Remove our 'master' tag
        fork_sub($num);                # Enter our neverending query loop
        exit;                   # We should never get here, but just in case
      }
      else {
        do_log("Error spawning snmp worker fork ($!)",0);
      }
    }

   # Now reconnect to the DB
    db_connect(1);
  }


 # Subroutine that the forked query processes "live" in
  sub fork_sub {
    my ($fork_num) = @_;
    my $sock = $g{'forks'}{$fork_num}{'PS'};

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
          alarm $g{'cycletime'} * 2;
          $string_in = $sock->getline();
          alarm 0;
        };

       # Our getline timed out, which means we haven't gotten any data
       # in a while.  Make sure our parent is still there
        if($@) {
	  do_log("Fork $fork_num timed out waiting for data from parent: $@",3);
          if (!kill 0, $g{'mypid'}) {
            do_log("Parent is no longer running, fork $fork_num exiting");
	    exit 1;
          }
          my $sleeptime = $g{'cycletime'} / 2;
          do_log("Parent ($g{'mypid'}) seems to be running, fork $fork_num sleeping for $sleeptime",3);
          sleep $sleeptime;

        }
        $serialized .= $string_in if defined $string_in;
        
      } until $serialized =~ s/\nEOF\n$//s;
      do_log("DEBUG SNMP($fork_num): Got EOF in message, attempting to thaw",4) if $g{'debug'};

     # Now decode our serialized data scalar
      my %data_in;
      eval {
        %data_in = %{thaw($serialized)};
      };
      if ($@) {
        do_log("DEBUG SNMP($fork_num): thaw failed attempting to thaw $serialized: $@",4) if $g{'debug'};
	do_log("DEBUG SNMP($fork_num): Replying to corrupt message with a pong",4) if $g{'debug'};
	$data_out{'ping'} = '0';
        $data_out{'pong'} = time;
        send_data($sock,\%data_out);
	next DEVICE;
      }

      if (defined $data_in{'ping'}) {
        do_log("DEBUG SNMP($fork_num): Received ping from master $data_in{'ping'},replying",4) if $g{'debug'};
	$data_out{'ping'} = $data_in{'ping'};
        $data_out{'pong'} = time;
        send_data($sock,\%data_out);
	next DEVICE;
      }

     # Get SNMP variables
      my $snmp_cid  = $data_in{'cid'};
      my $snmp_port = $data_in{'port'} || 161; # Default to 161 if not specified
      my $snmp_ver  = $data_in{'ver'};
      my $dev_ip    = $data_in{'dev_ip'};
      my $dev       = $data_in{'dev'};
      my $retries   = $data_in{'retries'};
      my $timeout   = $data_in{'timeout'};

      my $host = (defined $dev_ip and $dev_ip ne '') ? $dev_ip : $dev;

     # Establish SNMP session
      my $session; # NOT USE WITH SNMP V3?
      my $sess_err = 0;

      my ($SessionNew,$SessionNewError) ;

      if(!defined $data_in{'nonreps'} and !defined $data_in{'reps'}) {
        my $error_str = 
          "No oids to query for $dev, skipping";
        $data_out{'error'}{$error_str} = 1;
        send_data($sock, \%data_out);
        next DEVICE;
      }
      elsif(!defined $snmp_ver) {
        my $error_str = 
          "No snmp version found for $dev";
        $data_out{'error'}{$error_str} = 1;
        send_data($sock, \%data_out);
        next DEVICE;
      }
      elsif ( $snmp_ver eq '1' ) {
       my %options ;
         $options{hostname}     = $host ;
         $options{port}         = $snmp_port ;
         $options{version}      = 'v1';
         $options{community}    = $snmp_cid ;
         $options{maxmsgsize}   = 65535 ;
         $options{retries}      = $retries ;
         $options{timeout}      = $timeout ;
         $options{translate}    = "0" ;

        ($SessionNew,$SessionNewError) = Net::SNMP->session(%options) ;
      } 
      elsif ( $snmp_ver =~ /^2c?$/ ) {
         my %options ;
         $options{hostname}     = $host ;
         $options{port}         = $snmp_port ;
         $options{version}      = 'v2c';
         $options{community}    = $snmp_cid ;
         $options{maxmsgsize}   = 65535 ;
         $options{retries}      = $retries ;
         $options{timeout}      = $timeout ;
         $options{translate}    = "0" ;

        ($SessionNew,$SessionNewError) = Net::SNMP->session(%options) ;
      }
      elsif($snmp_ver eq "3" ) {
         my %options ;
         $options{hostname}     = $host ;
         $options{port}         = $snmp_port ;
         $options{version}      = 'v3' ;
         $options{username}     = $data_in{'USERNAME'} ;
         $options{authpassword} = $data_in{'PASSPHRASE_AUTH'} if defined $data_in{'PASSPHRASE_AUTH'};
         $options{authprotocol} = $data_in{'PROTOCOL_AUTH'}   if defined $data_in{'PROTOCOL_AUTH'} ;
         $options{privpassword} = $data_in{'PASSPHRASE_PRIV'} if defined $data_in{'PASSPHRASE_PRIV'} ;
         $options{privprotocol} = $data_in{'PROTOCOL_PRIV'}   if defined $data_in{'PROTOCOL_PRIV'} ;
         $options{retries}      = $retries ;
         $options{timeout}      = $timeout ;
         $options{translate}    = "0" ;

         ($SessionNew,$SessionNewError) = Net::SNMP->session(%options) ;
      }
     
     # Whoa, we dont support this version of SNMP
      else {
        my $error_str = 
          "Unsupported SNMP version for $dev ($snmp_ver)";
        $data_out{'error'}{$error_str} = 1;
        send_data($sock, \%data_out);
        next DEVICE;
      }

      # We cant recover from a failed snmp connect
      if ( ! defined $SessionNew ) {
        my $error_str = "Failed SNMP session to $dev ($SessionNewError)";
        if ( $SessionNewError =~ /SNMPv3 support is unavailable/ ) {
          do_log("$SessionNewError", 0);
        }
        $data_out{'error'}{$error_str} = 1;
         send_data($sock, \%data_out);
         next DEVICE;
      }

      # Set our retries & timeouts
      #$SessionNew->retries($retries) ;
      #$SessionNew->timeout($timeout) ;

      #$SessionNew->translate("0") ;

      # Query all non-repeat oid's
      foreach my $oid (sort keys %{$data_in{'nonreps'}} ) {
         my @oids = ($oid) ;
         my $req = $SessionNew->get_request(-varbindlist => \@oids);
         if ( $req ) {
            while (my ($key,$value) = each %{$req}) {
               #$value = pretty_print($value); #TODO = Wat doet dit?
               #print "$key = $value\n" ;
               $data_out{$key}{'val'}  = $value;
               $data_out{$key}{'time'} = time;
               do_log("DEBUG SNMP ver=$snmp_ver ($fork_num): get $oid : $key = $value",0) if $g{'debug'};
            }
         } else {
            my $error_str = "snmp get_request $dev, $oid";
            $data_out{'error'}{$error_str} = 1;
            do_log("DEBUG SNMP ver=$snmp_ver ($fork_num): $error_str $SessionNewError",0) if $g{'debug'};
            send_data($sock, \%data_out);
            #next DEVICE;
         }
         #my $val = $SessionNew->get(".$oid") ;
         #print "get $oid : $val\n" ;
         #$data_out{$oid}{'val'}  = $val;
         #$data_out{$oid}{'time'} = time;
      }
      # Now do SNMP walks on the repeat oid's
      foreach my $oid (sort keys %{$data_in{'reps'}}) {
         my @oids = ($oid) ;
         my $req = $SessionNew->get_table(-baseoid => $oid);
         if ( $req ) {
            while (my ($leaf,$value) = each %{$req}) {
               # $value = pretty_print($value); #TODO = Wat doet dit?
               $leaf =~ s/.*\.(\d+)$/$1/ ; # key = last number of oid
               #print "$oid   $leaf = $value\n" ;
               $data_out{$oid}{'val'}{$leaf} = $value;
               $data_out{$oid}{'time'}{$leaf} = time;
               do_log("DEBUG SNMP ver=$snmp_ver ($fork_num): get $oid : $leaf = $value",0) if $g{'debug'};
            }
         } else {
            my $error_str = "snmp get_table $dev, $oid";
            $data_out{'error'}{$error_str} = 1;
            do_log("DEBUG SNMP ver=$snmp_ver ($fork_num): $error_str $SessionNewError",0) if $g{'debug'};
            send_data($sock, \%data_out);
            #next DEVICE;
         }
         #print "Query .$oid\n" ;
         #my $table = $SessionNew->get_table(".$oid") ;
         #print Data::Dumper->Dump([\$table]);
         #foreach my $key (keys %{$table}) {
         #print "$key\n" ;
         #}
      }

     # Now are done gathering data, close the session and return our hash
      $SessionNew->close();
      send_data($sock, \%data_out);
    }
  }

 # Make sure that forks are still alive
  sub check_forks {
    for my $fork (keys %{$g{'forks'}}) {
      my $pid = $g{'forks'}{$fork}{'pid'};
      if (!kill 0, $pid) {
        do_log("Fork $fork with pid $pid died, cleaning up",3);
        close $g{'forks'}{$fork}{'CS'} or do_log("Closing child socket failed: $!",2);
        delete $g{'forks'}{$fork};
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

1;
