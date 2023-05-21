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
use diagnostics;

use Socket;
use IO::Handle;
use IO::Select;
use IO::Socket::INET;
use Data::Dumper;

use POSIX ":sys_wait_h";

# Get system error numbers for checking $!.
use POSIX qw(:errno_h);
use Math::BigInt;
use Storable qw(nfreeze thaw);
use Time::HiRes qw(time);

#use dm_config qw(oid_sort);
use dm_config qw(FATAL ERROR WARN INFO DEBUG TRACE);
use dm_config;

# Our global variable hash
use vars qw(%g);
*g = \%dm_config::g;

# Fiddle with some of our storable settings to correct byte order...
$Storable::interwork_56_64bit = 1;

# Add a wait for our dead forks
$SIG{CHLD} = \&REAPER;

# Sub that, given a hash of device data, will query specified oids for
# each device and return a hash of the snmp query results
sub poll_devices {

    # clear per-fork polled device counters
    foreach ( keys %{ $g{forks} } ) {
        $g{forks}{$_}{polled} = 0;
    }
    do_log( "Starting snmp queries", INFO );
    $g{snmppolltime} = time;
    my %snmp_input = ();
    %{ $g{snmp_data} } = ();

    # Query our Xymon server for device reachability status
    # we don't want to waste time querying devices that are down
    do_log( "Getting device status from Xymon at $g{dispserv}:$g{dispport}", INFO );
    %{ $g{xymon_color} } = ();
    my $sock = IO::Socket::INET->new(
        PeerAddr => $g{dispserv},
        PeerPort => $g{dispport},
        Proto    => 'tcp',
        Timeout  => 10,
    );
    if ( defined $sock ) {

        # Ask xymon for ssh, conn, http, telnet tests green on all devices
        print $sock "xymondboard test=conn|ssh|http|telnet color=green fields=hostname";
        shutdown( $sock, 1 );
        while ( my $device = <$sock> ) {
            chomp $device;

            #my ( $device, $color, $line1 ) = split /\|/;
            #chomp $line1; #and do_log( "DEBUG SNMP: $device has Xymon status $color and msg $line1", 4 ) if $g{debug};

            #if ( $line1 =~ /not ok/i and !defined $g{xymon_color}{device} ) {
            #    $g{xymon_color}{$device} = $color;
            #    do_log( "DEBUG SNMP: $device has Xymon status $color and msg $line1", 5 ) if $g{debug};
            #    next;
            #} elsif ( $line1 =~ /ok/i ) {
            $g{xymon_color}{$device} = 'green';

            #    do_log( "DEBUG SNMP: $device has Xymon status $color and msg $line1", 4 ) if $g{debug};
            #}
            #do_log("$line");
        }
    }

    # Build our query hash
    $g{numsnmpdevs} = $g{numdevs};
QUERYHASH: for my $device ( sort keys %{ $g{devices} } ) {

        # Skip this device if we weren't able to reach it during update_indexes
        # next unless $indexes->{$device}{reachable};

        # Skip this device if we are running a Xymon server and the
        # server thinks that it isn't reachable
        if ( !defined $g{xymon_color}{$device} ) {
            do_log( "$device hasn't any Xymon tests skipping SNMP: add at least one! conn, ssh,...", INFO );
            --$g{numsnmpdevs};
            next QUERYHASH;
        } elsif ( $g{xymon_color}{$device} ne 'green' ) {
            do_log( "$device has a non-green Xymon status, skipping SNMP.", INFO );
            --$g{numsnmpdevs};
            next QUERYHASH;
        }
        my $vendor = $g{devices}{$device}{vendor};
        my $model  = $g{devices}{$device}{model};
        my $tests  = $g{devices}{$device}{tests};

        # Make sure we have our device_type info
        do_log( "No vendor/model '$vendor/$model' templates for host $device, skipping.", INFO )
            and next QUERYHASH
            if !defined $g{templates}{$vendor}{$model};

        # If our tests = 'all', create a string with all the tests in it
        if ( $tests eq 'all' ) {
            $tests = join ',', keys %{ $g{templates}{$vendor}{$model}{tests} };
        }

        # If we have a !, remove tests from all tests
        elsif ( substr( $tests, 0, 1 ) eq '!' ) {
            my %valid_tests = %{ $g{templates}{$vendor}{$model}{tests} };
            foreach my $notest ( split /,/, substr( $tests, 1 ) ) {
                delete( $valid_tests{$notest} );
            }
            $tests = join ',', keys %valid_tests;
        }

        #$snmp_input{$device}{ip}       = $g{devices}{$device}{ip};
        #$snmp_input{$device}{cid}      = $g{devices}{$device}{cid};
        #$snmp_input{$device}{port}     = $g{devices}{$device}{port};
        #%{ $snmp_input{$device} } = %{ $g{devices}{$device} };
        #$snmp_input{$device}{dev} = $device;
        # copy only what is needed for the snmp query (the global hash is to high

        $snmp_input{$device}{authpass}  = $g{devices}{$device}{authpass};
        $snmp_input{$device}{authproto} = $g{devices}{$device}{authproto};
        $snmp_input{$device}{cid}       = $g{devices}{$device}{cid};
        $snmp_input{$device}{dev}       = $device;
        $snmp_input{$device}{ip}        = $g{devices}{$device}{ip};

        #  $snmp_input{$device}{model}         = $g{devices}{$device}{model};
        $snmp_input{$device}{port}      = $g{devices}{$device}{port};
        $snmp_input{$device}{privpass}  = $g{devices}{$device}{privpass};
        $snmp_input{$device}{privproto} = $g{devices}{$device}{privproto};

        #$snmp_input{$device}{reps}       = $g{devices}{$device}{reps};
        $snmp_input{$device}{resolution} = $g{devices}{$device}{resolution};
        $snmp_input{$device}{seclevel}   = $g{devices}{$device}{seclevel};
        $snmp_input{$device}{secname}    = $g{devices}{$device}{secname};
        $snmp_input{$device}{snmptries}  = $g{devices}{$device}{snmptries};
        $snmp_input{$device}{timeout}    = $g{devices}{$device}{timeout};
        $snmp_input{$device}{ver}        = $g{devices}{$device}{ver};

        do_log( "Querying snmp oids on $device for tests $tests", INFO );

        # Go through each of the tests and determine what their type is
    TESTTYPE: for my $test ( split /,/, $tests ) {

            # Make sure we have our device_type info
            do_log( "No test '$test' template found for host $device, skipping.", WARN )
                and next TESTTYPE
                if !defined $g{templates}{$vendor}{$model}{tests}{$test};

            # Create a shortcut
            my $tmpl = \%{ $g{templates}{$vendor}{$model}{tests}{$test} };

            # Go through our oids and add them to our repeater/non-repeater hashs
            for my $oid ( keys %{ $tmpl->{oids} } ) {
                my $number = $tmpl->{oids}{$oid}{number};

                # Skip oid without translation to dot number
                next if !defined $number;

                # If this is a repeater... (branch)
                if ( $tmpl->{oids}{$oid}{repeat} ) {
                    $snmp_input{$device}{reps}{$number} = 1;

                    # If we've queried this device before, use the previous number of
                    # repeats to populate our repeater value
                    $snmp_input{$device}{reps}{$number} = $g{max_rep_hist}{$device}{$number};

                    # Otherwise this is a nonrepeater (leaf)
                } else {
                    $snmp_input{$device}{nonreps}{$number} = 1;
                }
            }
        }
    }

    # Throw the query hash to the forked query processes
    snmp_query( \%snmp_input );

    # Record how much time this all took
    $g{snmppolltime} = time - $g{snmppolltime};

    # Dump some debug info if we need to
    if ( $g{debug} ) {
        for my $dev ( sort keys %{ $g{devices} } ) {
            my $expected
                = ( scalar keys %{ $snmp_input{$dev}{nonreps} } ) + ( scalar keys %{ $snmp_input{$dev}{reps} } );
            my $received = ( scalar keys %{ $g{snmp_data}{$dev} } );
            do_log( "Queried $dev: expected $expected, received $received", DEBUG )
                if ( $expected != $received );
        }
    }
}

# Query SNMP data on all devices
sub snmp_query {
    my ($snmp_input) = @_;
    my $active_forks = 0;

    # Check the status of any currently running forks
    &check_forks();

    # If we are in the readbbhost phase the numsnmpdev is not discoverd
    # the number of snmp device is normally the number of device that have at
    # least one successfull Xymon test. As we skip this discovering phase
    # we define it as the number of devices if it is not defined!
    $g{numsnmpdevs} = $g{numdevs} if ( !defined $g{numsnmpdevs} );

    # Start forks if needed
    fork_queries()
        if (   ( keys %{ $g{forks} } < $g{numforks} && keys %{ $g{forks} } < $g{numsnmpdevs} )
            or ( keys %{ $g{forks} } == 0 and $g{numsnmpdevs} < 2 ) );

    # Now split up our data amongst our forks
    my @devices = keys %{$snmp_input};

    while ( @devices or $active_forks ) {
        foreach my $fork ( sort { $a <=> $b } keys %{ $g{forks} } ) {

            # First lets see if our fork is working on a device
            if ( defined $g{forks}{$fork}{dev} ) {
                my $dev = $g{forks}{$fork}{dev};

                # It is, lets see if its ready to give us some data
                my $select = IO::Select->new( $g{forks}{$fork}{CS} );
                if ( $select->can_read(0.01) ) {

                    do_log( "Fork $fork has data for device $dev, reading it", DEBUG ) if $g{debug};

                    # Okay, we know we have something in the buffer, keep reading
                    # till we get an EOF
                    my $data_in = '';
                    eval {
                        local $SIG{ALRM} = sub { die "Timeout waiting for EOF from fork\n" };
                        alarm 15;
                        do {
                            my $read = $g{forks}{$fork}{CS}->getline();
                            if ( defined $read and $read ne '' ) {
                                $data_in .= $read;
                            } else {
                                select undef, undef, undef, 0.001;
                            }
                        } until $data_in =~ s/\nEOF\n$//s;
                        alarm 0;
                    };
                    if ($@) {
                        do_log( "Fork $g{forks}{$fork}, pid $g{forks}{$fork}{pid} stalled on device $dev: $@. Killing this fork.", ERROR );
                        kill 15, $g{forks}{$fork}{pid}
                            or do_log( "Sending $fork TERM signal failed: $!", ERROR );
                        close $g{forks}{$fork}{CS}
                            or do_log( "Closing socket to fork $fork failed: $!", ERROR );
                        delete $g{forks}{$fork};
                        next;
                    }
                    do_log( "Fork $fork returned complete message for device $dev", DEBUG ) if $g{debug};

                    # Looks like we got some data
                    my $hashref = thaw($data_in);
                    my %returned;
                    if ( defined $hashref ) {
                        do_log( "Dethawing data for $dev", DEBUG ) if $g{debug};
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
                    for my $error ( keys %{ $returned{error} } ) {
                        my $fatal = $returned{error}{$error};
                        do_log( "$error", ERROR );

                        # Increment our fail counter if the query died fatally
                        ++$g{fail}{$dev} if $fatal;
                    }
                    delete $returned{error};

                    # Go through and extract our maxrep values
                    for my $oid ( keys %{ $returned{maxrep} } ) {
                        my $val = $returned{maxrep}{$oid};
                        $g{max_rep_hist}{$dev}{$oid} = $val;
                        delete $returned{maxrep}{$oid};
                    }
                    delete $returned{maxrep};

                    # Now add the rest to our outgoing hash
                    %{ $g{snmp_data}{$dev} } = %returned;

                    # Now put our fork into an idle state
                    --$active_forks;
                    delete $g{forks}{$fork}{dev};

                    # No data, lets make sure we're not hung
                } else {
                    my $pid = $g{forks}{$fork}{pid};

                    # See if we've exceeded our max poll time
                    my $forktime = time - $g{forks}{$fork}{time};

                    #if ( ( time - $g{forks}{$fork}{time} ) > $g{maxpolltime} ) {
                    if ( $forktime > $g{maxpolltime} ) {
                        do_log( "Fork $fork ($pid) time exceed max poll time polling $g{maxpolltime} on device $dev", WARN );

                        # Kill it
                        kill 15, $pid or do_log( "Sending fork $fork TERM signal failed: $!", ERROR );
                        close $g{forks}{$fork}{CS} or do_log( "Closing socket to fork $fork failed: $!", ERROR );
                        delete $g{forks}{$fork};
                        --$active_forks;
                        fork_queries();

                        # Increment this hosts fail counter
                        # We could add it back to the queue, but that would be unwise
                        # as if thise host is causing snmp problems, it could wonk
                        # our poll time
                        ++$g{fail}{$dev};

                        # We haven't exceeded our poll time, but make sure its still live
                    } elsif ( !kill 0, $pid ) {

                        # Whoops, looks like our fork died somewhow
                        do_log( "Fork $fork ($pid) died polling $dev", ERROR );
                        close $g{forks}{$fork}{CS}
                            or do_log( "Closing socket to fork $fork failed: $!", ERROR );
                        delete $g{forks}{$fork};
                        --$active_forks;
                        fork_queries();

                        # See above comment
                        ++$g{fail}{$dev};
                    }
                }
            }

            # If our forks are idle, give them something to do
            if ( !defined $g{forks}{$fork}{dev} and @devices ) {
                my $dev = shift @devices;

                $g{forks}{$fork}{dev} = $dev;

                # Set our tries lower if this host has a bad history
                if ( defined $g{fail}{$dev} and $g{fail}{$dev} > 0 ) {
                    my $snmptries = $g{snmptries} - $g{fail}{$dev};
                    $snmptries = 1 if $snmptries < 1;
                    $snmp_input->{$dev}{snmptries} = $snmptries;
                } else {
                    $snmp_input->{$dev}{snmptries} = $g{snmptries};
                }

                # set out timeout
                $snmp_input->{$dev}{timeout} = $g{snmptimeout};

                # Now send our input to the fork
                my $serialized = nfreeze( $snmp_input->{$dev} );
                eval {
                    local $SIG{ALRM} = sub { die "Timeout sending polling task data to fork\n" };
                    alarm 15;
                    $g{forks}{$fork}{CS}->print("$serialized\nEOF\n");
                    alarm 0;
                };
                if ($@) {
                    do_log( "Fork $g{forks}{$fork}, pid $g{forks}{$fork}{pid} not responding: $@. Killing this fork.", ERROR );
                    kill 15, $g{forks}{$fork}{pid}
                        or do_log( "Sending TERM signal to fork $fork failed: $!", ERROR );
                    close $g{forks}{$fork}{CS} or do_log( "Closing socket to fork $fork failed: $!", ERROR );
                    delete $g{forks}{$fork};
                    next;
                }

                ++$active_forks;
                $g{forks}{$fork}{time} = time;
            }

            # If our fork is idle and has been for more than the cycle time
            #  make sure it is still alive
            if ( !defined $g{forks}{$fork}{dev} ) {
                my $idletime = time - $g{forks}{$fork}{time};
                next if ( $idletime <= $g{cycletime} );
                if ( defined $g{forks}{$fork}{pinging} ) {
                    do_log( "Fork $fork was pinged, checking for reply", DEBUG ) if $g{debug};
                    my $select = IO::Select->new( $g{forks}{$fork}{CS} );
                    if ( $select->can_read(0.01) ) {

                        do_log( "Fork $fork has data, reading it", DEBUG ) if $g{debug};

                        # Okay, we know we have something in the buffer, keep reading
                        # till we get an EOF
                        my $data_in = '';
                        eval {
                            local $SIG{ALRM} = sub { die "Timeout waiting for EOF from fork" };
                            alarm 5;
                            do {
                                my $read = $g{forks}{$fork}{CS}->getline();
                                if ( defined $read and $read ne '' ) {
                                    $data_in .= $read;
                                } else {
                                    select undef, undef, undef, 0.001;
                                }
                            } until $data_in =~ s/\nEOF\n$//s;
                            alarm 0;
                        };
                        if ($@) {
                            do_log( "Fork $fork, pid $g{forks}{$fork}{pid} stalled on reply to ping: $@. Killing this fork.", ERROR );
                            kill 15, $g{forks}{$fork}{pid}
                                or do_log( "Sending $fork TERM signal failed: $!", ERROR );
                            close $g{forks}{$fork}{CS}
                                or do_log( "Closing socket to fork $fork failed: $!", ERROR );
                            delete $g{forks}{$fork};
                            next;
                        }
                        do_log( "Fork $fork returned complete message for ping request", DEBUG ) if $g{debug};

                        my $hashref = thaw($data_in);
                        my %returned;
                        if ( defined $hashref ) {
                            do_log( "Dethawing data for ping of fork $fork", DEBUG ) if $g{debug};
                            %returned = %{ thaw($data_in) };
                        } else {
                            print "failed thaw for ping of fork $fork\n";
                            next;
                        }
                        if ( defined $returned{pong} ) {
                            $g{forks}{$fork}{time} = time;
                            do_log( "Fork $fork responded to ping request $returned{ping} with $returned{pong} at $g{forks}{$fork}{time}", DEBUG ) if $g{debug};
                            delete $g{forks}{$fork}{pinging};
                        } else {
                            do_log( "Fork $fork didn't send an appropriate response, killing it", DEBUG )
                                if $g{debug};
                            kill 15, $g{forks}{$fork}{pid}
                                or do_log( "Sending $fork TERM signal failed: $!", ERROR );
                            close $g{forks}{$fork}{CS}
                                or do_log( "Closing socket to fork $fork failed: $!", ERROR );
                            delete $g{forks}{$fork};
                            next;
                        }

                    } else {
                        do_log( "Fork $fork seems not to have replied to our ping, killing it", ERROR );
                        kill 15, $g{forks}{$fork}{pid} or do_log( "Sending $fork TERM signal failed: $!", ERROR );
                        close $g{forks}{$fork}{CS} or do_log( "Closing socket to fork $fork failed: $!", ERROR );
                        delete $g{forks}{$fork};
                        next;
                    }

                } else {
                    my %ping_input = ( 'ping' => time );
                    do_log( "Fork $fork has been idle for more than cycle time, pinging it at $ping_input{ping}", DEBUG ) if $g{debug};
                    my $serialized = nfreeze( \%ping_input );
                    eval {
                        local $SIG{ALRM} = sub { die "Timeout sending polling task data to fork\n" };
                        alarm 15;
                        $g{forks}{$fork}{CS}->print("$serialized\nEOF\n");
                        alarm 0;
                    };
                    if ($@) {
                        do_log( "Fork $g{forks}{$fork}, pid $g{forks}{$fork}{pid} not responding: $@. Killing this fork.", ERROR );
                        kill 15, $g{forks}{$fork}{pid}
                            or do_log( "Sending TERM signal to fork $fork failed: $!", ERROR );
                        close $g{forks}{$fork}{CS} or do_log( "Closing socket to fork $fork failed: $!", ERROR );
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
    while (( keys %{ $g{forks} } < $g{numforks} && keys %{ $g{forks} } < $g{numsnmpdevs} )
        or ( keys %{ $g{forks} } == 0 and $g{numsnmpdevs} < 2 ) )
    {
        my $num = 1;
        my $pid;

        # Find our next available placeholder
        for ( sort { $a <=> $b } keys %{ $g{forks} } ) {
            ++$num and next if defined $g{forks}{$num};
            last;
        }
        do_log( "Starting fork number $num", DEBUG ) if $g{debug};

        # Open up our communication sockets
        socketpair(
            $g{forks}{$num}{CS},    # Child socket
            $g{forks}{$num}{PS},    # Parent socket
            AF_UNIX,
            SOCK_STREAM,
            PF_UNSPEC
            )
            or do_log( "Unable to open forked socket pair ($!)", ERROR )
            and exit;

        $g{forks}{$num}{CS}->autoflush(1);
        $g{forks}{$num}{PS}->autoflush(1);

        if ( $pid = fork ) {

            # Parent code here
            do_log( "Fork number $num started with pid $pid", DEBUG ) if $g{debug};
            close $g{forks}{$num}{PS}
                or do_log( "Closing socket to ourself failed: $!\n", ERROR );    # don't need to communicate with ourself
            $g{forks}{$num}{pid}  = $pid;
            $g{forks}{$num}{time} = time;
            $g{forks}{$num}{CS}->blocking(0);
        } elsif ( defined $pid ) {

            # Child code here
            $g{parent} = 0;                                                      # We aren't the parent any more...
            do_log( "Fork $num using sockets $g{forks}{$num}{PS} <-> $g{forks}{$num}{CS} for IPC", DEBUG, $num )
                if $g{debug};
            foreach ( sort { $a <=> $b } keys %{ $g{forks} } ) {
                do_log( "Fork $num closing socket (child $_) $g{forks}{$_}{PS}", DEBUG, $num ) if $g{debug};
                $g{forks}{$_}{CS}->close
                    or do_log( "Closing socket for fork $_ failed: $!", ERROR );    # Same as above
            }
            $0 = "devmon-$num";                                                     # Remove our 'master' tag
            fork_sub($num);                                                         # Enter our neverending query loop
            exit;                                                                   # We should never get here, but just in case
        } else {
            do_log( "Spawning snmp worker fork ($!)", ERROR );
        }
    }

    # Now reconnect to the DB
    db_connect(1);
}

# Subroutine that the forked query processes "live" in
sub fork_sub {
    my ($fork_num) = @_;
    my $sock = $g{forks}{$fork_num}{PS};
    my %maxrep;

    #permanent variable storage for fast path with SNMP.pm
    my %snmp_persist_storage;

DEVICE: while (1) {    # We should never leave this loop
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
            if ($@) {
                do_log( "Fork $fork_num timed out waiting for data from parent: $@", WARN, $fork_num );
                if ( !kill 0, $g{mypid} ) {
                    do_log( "Parent is no longer running, fork $fork_num exiting", ERROR, $fork_num );
                    exit 1;
                }
                my $sleeptime = $g{cycletime} / 2;
                do_log( "Parent ($g{mypid}) seems to be running, fork $fork_num sleeping for $sleeptime", WARN, $fork_num );
                sleep $sleeptime;
            }

            $serialized .= $string_in if defined $string_in;

        } until $serialized =~ s/\nEOF\n$//s;
        do_log( "Got EOF in message, attempting to thaw", DEBUG, $fork_num ) if $g{debug};

        # Now decode our serialized data scalar
        my %data_in;
        eval { %data_in = %{ thaw($serialized) }; };
        if ($@) {
            do_log( "Thaw failed attempting to thaw $serialized: $@", DEBUG, $fork_num ) if $g{debug};
            do_log( "Replying to corrupt message with a pong",        DEBUG, $fork_num ) if $g{debug};
            $data_out{ping} = '0';
            $data_out{pong} = time;
            send_data( $sock, \%data_out );
            next DEVICE;
        }

        if ( defined $data_in{ping} ) {
            do_log( "Received ping from master $data_in{ping},replying", DEBUG, $fork_num ) if $g{debug};
            $data_out{ping} = $data_in{ping};
            $data_out{pong} = time;
            send_data( $sock, \%data_out );
            next DEVICE;
        }

        # Get SNMP variables
        #my $snmp_cid = $data_in{cid};
        my $snmp_ver = $data_in{ver};

        # Establish SNMP session
        my $session;
        my $sess_err = 0;

        if ( !defined $data_in{nonreps} and !defined $data_in{reps} ) {
            my $error_str = "No oids to query for $data_in{dev}, skipping";
            $data_out{error}{$error_str} = 1;
            send_data( $sock, \%data_out );
            next DEVICE;

        } elsif ( !defined $data_in{ver} ) {
            my $error_str = "No snmp version found for $data_in{dev}";
            $data_out{error}{$error_str} = 1;
            send_data( $sock, \%data_out );
            next DEVICE;

        } elsif ( ( ( $g{snmpeng} eq 'session' ) and ( $snmp_ver eq '2' or $snmp_ver eq '2c' ) ) or ( $snmp_ver eq '1' ) ) {
            use BER;
            use SNMP_Session;
            $BER::pretty_print_timeticks     = 0;
            $SNMP_Session::suppress_warnings = $g{debug} ? 0 : 1;
            my $max_pdu_len = 16384;    # default is 8000

            # Get SNMP variables
            my $snmp_cid  = $data_in{cid};
            my $snmp_port = $data_in{port};
            my $ip        = $data_in{ip};
            my $dev       = $data_in{dev};
            my $snmptries = $data_in{snmptries};
            my $timeout   = $data_in{timeout};
            my $host      = ( defined $ip and $ip ne '' ) ? $ip : $dev;

            if ( $snmp_ver eq '1' ) {
                $session = SNMPv1_Session->open( $host, $snmp_cid, $snmp_port, $max_pdu_len );
            } elsif ( $snmp_ver =~ /^2/ ) {
                $session = SNMPv2c_Session->open( $host, $snmp_cid, $snmp_port, $max_pdu_len );
                $session->{use_getbulk} = 1;
            }

            # Set our retries & timeouts (retries is a confusing name as it is the nb of tries)
            SNMP_Session::set_retries( $session, $snmptries );
            SNMP_Session::set_timeout( $session, $timeout );

            # We can't recover from a failed snmp connect
            if ($sess_err) {
                my $snmp_err;
                ( $snmp_err = $SNMP_Session::errmsg ) =~ s/\n.*//s;
                my $error_str = "Failed SNMP session to $dev ($snmp_err)";
                $data_out{error}{$error_str} = 1;
                send_data( $sock, \%data_out );
                next DEVICE;
            }

            # Do SNMP gets
            my $failed_query = 0;
            my @nrep_oids;
            my @nrep_oids_my;
            my $oids_num = keys %{ $data_in{nonreps} };
            my $ii       = 0;

            do_log( "OID: $oids_num", DEBUG, $fork_num ) if $g{debug};
            for my $oid ( keys %{ $data_in{nonreps} } ) {
                do_log( "$ii => $oid ", DEBUG, $fork_num ) if $g{debug};
                $ii++;
                push @nrep_oids_my, $oid;
                push @nrep_oids,    encode_oid( split /\./, $oid );
            }

            my @nrep_oids_temp;
            my $nrep_oids_temp_cpt = 0;
            for ( my $index = 0; $index < $oids_num; $index++ ) {
                ++$nrep_oids_temp_cpt;
                push @nrep_oids_temp, $nrep_oids[$index];
                do_log( "Adding ID => $nrep_oids_temp_cpt OID =>$nrep_oids_my[$index]", DEBUG, $fork_num )
                    if $g{debug};

                #if ($nrep_oids_temp_cpt == 10) {
                do_log( "Pooling $nrep_oids_temp_cpt oids", DEBUG, $fork_num ) if $g{debug};
                if (@nrep_oids_temp) {
                    if ( $session->get_request_response(@nrep_oids_temp) ) {
                        my $response = $session->pdu_buffer;
                        my ($bindings) = $session->decode_get_response($response);
                        if ( !defined $bindings or $bindings eq '' ) {
                            my $snmp_err;
                            do_log( "$SNMP_Session::errmsg", DEBUG, $fork_num ) if $g{debug};
                            ( $snmp_err = $SNMP_Session::errmsg ) =~ s/\n.*//s;
                            my $error_str = "snmpget $dev ($snmp_err)";
                            $data_out{error}{$error_str} = 0;
                            ++$failed_query;
                        }

                        # Go through our results, decode them, and add to our return hash
                        while ( $bindings ne '' ) {
                            my $binding;
                            ( $binding, $bindings ) = decode_sequence($bindings);
                            my ( $oid, $value ) = decode_by_template( $binding, "%O%@" );
                            $oid                  = pretty_print($oid);
                            $value                = pretty_print($value);
                            $data_out{$oid}{val}  = $value;
                            $data_out{$oid}{time} = time;
                        }
                    } else {
                        my $snmp_err;
                        ( $snmp_err = $SNMP_Session::errmsg ) =~ s/\n.*//s;
                        my $error_str = "snmpget2 $dev ($snmp_err)";
                        $data_out{error}{$error_str} = 1;
                        send_data( $sock, \%data_out );
                        next DEVICE;
                    }
                    $nrep_oids_temp_cpt = 0;
                    @nrep_oids_temp     = ();
                }
            }    # end for

            # Now do SNMP walks
            for my $oid ( keys %{ $data_in{reps} } ) {
                my $max_reps = $data_in{reps}{$oid};
                $max_reps = $g{max_reps} if !defined $max_reps or $max_reps < 2;

                # Encode our oid and walk it
                my @oid_array = split /\./, $oid;
                my $num_reps  = $session->map_table_4(
                    [ \@oid_array ],
                    sub {
                        # Decode our result and add to our result hash
                        my ( $leaf, $value ) = @_;
                        $value = pretty_print($value);
                        $data_out{$oid}{val}{$leaf} = $value;
                        do_log( "Oid:$oid leaf:$leaf val:$value", DEBUG, $fork_num );
                        $data_out{$oid}{time}{$leaf} = time;
                    },
                    $max_reps
                );

                # Catch any failures
                if ( !defined $num_reps or $num_reps == 0 ) {
                    my $snmp_err;
                    do_log( "$SNMP_Session::errmsg", DEBUG, $fork_num ) if $g{debug};
                    ( $snmp_err = $SNMP_Session::errmsg ) =~ s/\n.*//s;
                    if ( $snmp_err ne '' ) {
                        my $error_str = "Error walking $oid for $dev ($snmp_err)";
                        $data_out{error}{$error_str} = 0;
                        ++$failed_query;
                    }
                } else {

                    # Record our maxrep value for our next poll cycle
                    # WARNING: NO ! the next value is just send back to the main process
                    # But, a 20 line above $max_reps is defined as the number of oids of branch type???
                    # injected as last parameter of map_table_4
                    $data_out{maxrep}{$oid} = $num_reps + 1;
                }
                do_log( "Failed queries $failed_query", WARN, $fork_num )
                    if ( $g{debug} and $failed_query gt 0 );

                # We don't want to do every table if we are failing alot of walks
                if ( $failed_query > 6 ) {
                    my $error_str = "Failed too many queries on $dev, aborting query";
                    $data_out{error}{$error_str} = 1;
                    send_data( $sock, \%data_out );
                    $session->close();
                    next DEVICE;
                }
            }

            # Now are done gathering data, close the session and return our hash
            $session->close();
            send_data( $sock, \%data_out );

        } elsif ( ( ( ( $g{snmpeng} eq 'snmp' ) or ( $g{snmpeng} eq 'auto' ) ) and ( $snmp_ver eq '2' or $snmp_ver eq '2c' ) ) or $snmp_ver eq '3' ) {
            eval { require SNMP; };
            if ($@) {
                do_log( "SNMP is not installed: $@ yum install net-snmp or apt install snmp", WARN, $fork_num );
            } else {

                #create shortcut
                my $dev = $data_in{dev};

                # Get SNMP variables
                my %snmpvars;
                $snmpvars{Device}     = $dev;
                $snmpvars{RemotePort} = $data_in{port} || 161;                                                   # Default to 161 if not specified
                $snmpvars{DestHost}   = ( defined $data_in{ip} and $data_in{ip} ne '' ) ? $data_in{ip} : $dev;

                # The timeout logic
                if ( ( defined ${ $snmp_persist_storage{$dev}{run_count} } ) and ( ${ $snmp_persist_storage{$dev}{run_count} } > ( 86400 / $g{cycletime} ) ) ) {

                    # Optimize timeout after 1 day learing time
                    if ( ( ${ $snmp_persist_storage{$dev}{polling_time_min} } ) > 1 ) {

                        # Use default timer
                        $snmpvars{Timeout} = $data_in{timeout} * 1000000;
                    } elsif ( ${ $snmp_persist_storage{$dev}{polling_time_max} } <= 0.5 ) {

                        # Pollin is very quick but, let dont put it under 0.5 sec
                        $snmpvars{Timeout} = $data_in{timeout} * 0.5 * 1000000;
                    } else {

                        #between 0.5 and 1
                        $snmpvars{Timeout} = $data_in{timeout} * ${ $snmp_persist_storage{$dev}{polling_time_max} } * 1000000;
                    }
                    $snmpvars{Retries} = $data_in{snmptries} - 1;

                    #$snmpvars{Retries} = 2;
                } else {

                    # We are in a discovery so initial timer and retries
                    $snmpvars{Timeout} = $data_in{timeout} * 1000000;    # 5 sec initial timeout in ms
                    $snmpvars{Retries} = $data_in{snmptries} - 1;        # no retries
                }

                $snmpvars{UseNumeric}    = 1;
                $snmpvars{NonIncreasing} = 0;
                $snmpvars{Version}       = $snmp_ver;

                # We store the security name for v3 also in cid so we keep the same data format
                #$snmpvars{SecName}   = $data_in{cid}       if defined $data_in{cid};         #do we need this?
                $snmpvars{Community} = $data_in{cid}       if defined $data_in{cid};
                $snmpvars{SecName}   = $data_in{secname}   if defined $data_in{secname};
                $snmpvars{SecLevel}  = $data_in{seclevel}  if defined $data_in{seclevel};
                $snmpvars{AuthProto} = $data_in{authproto} if defined $data_in{authproto};
                $snmpvars{AuthPass}  = $data_in{authpass}  if defined $data_in{authpass};
                $snmpvars{PrivProto} = $data_in{privproto} if defined $data_in{privproto};
                $snmpvars{PrivPass}  = $data_in{privpass}  if defined $data_in{privpass};

                # Establish SNMP session
                #                $SNMP::debugging = 2;
                #
                # Net-SNMP BUG https://github.com/net-snmp/net-snmp/issues/133 (Unable to switch AuthProto/PrivProto in same Perl process)
                # Confirmed in v5.0702 from > 5.05.60? to 5.09? )
                # Affect SNNPv3 only
                # - Perl object session not cleared: should be cleared when going out of the scope the object is created
                # -> The Credentials and the security attributes are not updated: they should be if they change
                # This workaround can be completely removed then it will work...
                # This workaround affect only the discovery process onyl as the credential are tried to be discovered.

                if ( not defined $data_in{reps} ) {
                    if ( ( keys %{ $data_in{nonreps} } ) == 1 ) {
                        if ( $snmp_ver == 3 ) {
                            if ( ( keys %{ $data_in{nonreps} } )[0] eq "1.3.6.1.2.1.1.1.0" ) {
                                my $Community = $snmpvars{Community} // '';
                                my $SecName   = $snmpvars{SecName}   // '';
                                my $SecLevel  = $snmpvars{SecLevel}  // '';
                                my $AuthProto = $snmpvars{AuthProto} // '';
                                my $AuthPass  = $snmpvars{AuthPass}  // '';
                                my $PrivProto = $snmpvars{PrivProto} // '';
                                my $PrivPass  = $snmpvars{PrivPass}  // '';

                                my $snmp_disco = <<EOF;
perl -e '
use SNMP;
my \$sess = new SNMP::Session(Device => "$snmpvars{Device}", RemotePort => "$snmpvars{RemotePort}", DestHost => "$snmpvars{DestHost}", Timeout => "$snmpvars{Timeout}", Retries => "$snmpvars{Retries}", UseNumeric => "$snmpvars{UseNumeric}", NonIncreasing => "$snmpvars{NonIncreasing}", Version => "$snmpvars{Version}", Community => "$Community", SecName => "$SecName", SecLevel => "$SecLevel", AuthProto => "$AuthProto", AuthPass => "$AuthPass", PrivProto => "$PrivProto", PrivPass => "$PrivPass");
print \$sess->get(".1.3.6.1.2.1.1.1.0");
'
EOF
                                my $disco_result = `$snmp_disco`;
                                if ( $disco_result eq '' ) {
                                    my $error_str = "Empty or no answer from $dev";
                                    $data_out{error}{$error_str} = 1;
                                    send_data( $sock, \%data_out );
                                    next DEVICE;
                                } else {
                                    $data_out{'1.3.6.1.2.1.1.1.0'}{'val'}  = $disco_result;
                                    $data_out{'1.3.6.1.2.1.1.1.0'}{'time'} = time;
                                    send_data( $sock, \%data_out );
                                    next DEVICE;
                                }
                            }
                        }
                    }
                }    # end of the workaround

                $! = 0;    # Reset system errno before calling new() (?!)
                my @nonreps = ();
                my $session = new SNMP::Session(%snmpvars);

                if ( ( not defined $session ) or ( not $session ) ) {
                    do_log( "Undefined/existing Session on device $dev", INFO, $fork_num );
                    my $err;
                    unless ($!) {

                        # Couldn't look up the host, so set the error code
                        # especially for this.
                        $err = "Couldn't resolve hostname";

                    } else {

                        # Some system-level error occurred.  Handle a few simple
                        # resource problems by (hopefully) waiting for things to
                        # subside, and retry later.
                        #
                        # Copy error string, and force numeric errno
                        $err = "" . $!;
                        my $errno = $! + 0;
                        if (( $errno == EINTR )  ||    # Interrupted system call
                            ( $errno == EAGAIN ) ||    # Resource temp. unavailable
                            ( $errno == ENOMEM ) ||    # No memory (temporary)
                            ( $errno == ENFILE ) ||    # Out of file descriptors
                            ( $errno == EMFILE )
                            )                          # Too many open fd's
                        {
                            $err .= " (ressource busy)";

                        } else {
                            $err .= " (other problem)";

                        }
                    }

                    my $error_str = "SNMP session did not start for device $dev: ${SNMP::ErrorStr} : $err";
                    do_log( "${SNMP::ErrorStr} : $err", WARN, $fork_num );
                    $data_out{error}{$error_str} = 1;
                    send_data( $sock, \%data_out );
                    undef $session;
                    next DEVICE;

                } else {    # session is defined

                    if ( $g{debug} ) {
                        do_log( "SNMP session started: Device=$snmpvars{Device}, RemotePort=$snmpvars{RemotePort}, DestHost=$snmpvars{DestHost}, Version=$snmp_ver", DEBUG, $fork_num );
                        if ( $snmp_ver eq '3' ) {
                            do_log( "SecLevel=$snmpvars{SecLevel}, SecName=$snmpvars{SecName}, AuthProto=$snmpvars{AuthProto}, AuthPass=$snmpvars{AuthPass}, PrivProto=$snmpvars{PrivProto}, PrivPass=$snmpvars{PrivPass} ", TRACE, $fork_num );
                        } elsif ( $snmp_ver eq '2' ) {
                            do_log( "Cid=$snmpvars{Community}", TRACE, $fork_num );
                        }
                    }

                    # Use a block for our snmp bulkwalk pseudo-subroutine
                    {
                        # Start initializing variable for our bulkwalk
                        my %oid;

                        my $poll_oid           = \%{ $snmp_persist_storage{$dev}{'poll_oid'} };
                        my $uniq_rep_poll_oid  = \%{ $snmp_persist_storage{$dev}{'uniq_rep_poll_oid'} };
                        my $uniq_nrep_poll_oid = \%{ $snmp_persist_storage{$dev}{'uniq_nrep_poll_oid'} };
                        my $rep_count          = \${ $snmp_persist_storage{$dev}{'rep_count'} };
                        my $nrep_count         = \${ $snmp_persist_storage{$dev}{'nrep_count'} };
                        my $oid_count          = \${ $snmp_persist_storage{$dev}{'oid_count'} };
                        my $path_is_slow       = \${ $snmp_persist_storage{$dev}{'path_is_slow'} };
                        my $run_count          = \${ $snmp_persist_storage{$dev}{'run_count'} };
                        my $workaround         = \${ $snmp_persist_storage{$dev}{'workaround'} };
                        my $polling_time_cur   = \${ $snmp_persist_storage{$dev}{'polling_time_cur'} };
                        my $polling_time_max   = \${ $snmp_persist_storage{$dev}{'polling_time_max'} };
                        my $polling_time_min   = \${ $snmp_persist_storage{$dev}{'polling_time_min'} };
                        my $polling_time_avg   = \${ $snmp_persist_storage{$dev}{'polling_time_avg'} };

                        # Count the number of run
                        #do_log("toto: ${ $run_count } ");
                        ${$run_count} += 1;

                        # First we need to build an array containing the oids that need to be polled.
                        # We have 2 paths: a slow one to discover all the info that we need and the second on: a fast path.
                        # After the first polling cycle we should take the fast path and if we need to rediscover thing we
                        # can take the slow path again (TODO)

                        # The slow path:
                        # First step is to build a uniq array with the non-repeater follow by the repeaters
                        # To maximize the result and the perf, we have to find if the oid is really
                        # a repeater or not. Devmon leaf can be both: part of a repeter or a real non repeater
                        # in the snmp meaninging. As we dont know for each leaf, we will take its parent oid for
                        # the oid to be polled and consider it as a repeater. The list of all parent OIDs is deduplicated.

                        # For the polling with the SNMP lib, we have to prepare an array of array, with  right order
                        # Total number of varbinds in the response message is (N + M x R).
                        # N is the minimum of the value of the Non-Repeaters (a field of the request)
                        # The number of variable bindings in the request is M
                        # M is the Max-Repetitions (number of Repeaters, but not exactly) (a field of the request)
                        # R is the maximum of the number of variable bindings in the request

                        my @varlists;
                        my @repeaters;
                        my @non_repeaters;
                        my @remain_oids;
                        my $vbarr_counter = 0;
                        my $oid_found     = 0;

                        foreach my $oid ( keys %{ $data_in{'reps'} } ) {

                            $oid = "." . $oid;    # add a . as we dont have one and its needed later
                            if ( ( not defined $poll_oid->{$oid}{oid} ) or ( not exists $uniq_rep_poll_oid->{$oid} ) ) {

                                # Slow path
                                # As we dont know we suppose the oid that should be polled is the parent oid,
                                # but we suppose that it can also fail
                                ${$path_is_slow} = 1;
                                $poll_oid->{$oid}{oid} = \$oid;
                                $uniq_rep_poll_oid->{$oid} = undef;
                            }
                        }

                        foreach my $oid ( keys %{ $data_in{'nonreps'} } ) {

                            $oid = "." . $oid;    # add a . as we dont have one and its needed later
                                                  #test paretin?
                            if ( ( not defined $poll_oid->{$oid}{oid} ) ) {

                                ${$path_is_slow} = 1;

                                # if a leaf does end with .0 it is a real scalar so we count is as a non-repeater
                                # but if not it is branch so with take it parent oid for polling and count is as a repeater

                                if ( $oid =~ /\.0$/ ) {    # is an SNMP Scalar (end with .0) are real non-repeater
                                    my $polled_oid = $oid =~ s/\.\d*$//r;
                                    $poll_oid->{$oid}{oid} = \$polled_oid;
                                    $uniq_nrep_poll_oid->{$polled_oid} = undef;
                                } else {

                                    # We take the parent oid
                                    my $polled_oid = $oid =~ s/\.\d*$//r;
                                    $poll_oid->{$oid}{oid} = \$polled_oid;
                                    $uniq_rep_poll_oid->{$polled_oid} = undef;
                                }
                            }
                        }

                        # Now we pass a blow for any situation
                        # As devmon rep vs non-rep are diffent than snmp
                        # we have to compute them: we do that in a block
                        my @polled_oids;
                        {
                            @repeaters     = oid_sort( keys %{$uniq_rep_poll_oid} );
                            @non_repeaters = oid_sort( keys %{$uniq_nrep_poll_oid} );
                            @polled_oids   = ( @non_repeaters, @repeaters );
                            ${$rep_count}  = scalar @repeaters;
                            ${$nrep_count} = scalar @non_repeaters;

                        }

                        @varlists = map [$_], @polled_oids;

                        # The hash function is now populated with the parent oid and the array is prepared for the
                        # polling, so lets do this polling
                        my $nrvars = new SNMP::VarList(@varlists);
                        do_log( "Doing bulkwalk", INFO, $fork_num );

                        #mty @nrresp = $session->bulkwalk( ${$nrep_count}, ${$rep_count} + ${$nrep_count}, $nrvars );
                        my @nrresp;
                    SNMP_START:
                        my $begin_time = time();
                        if ( defined ${$workaround} ) {
                            if ( ${$workaround} == 1 ) {
                                @nrresp = $session->bulkwalk( ${$nrep_count}, 0, $nrvars );
                            }
                        } else {

                            # THE NORMAL CASE!
                            @nrresp = $session->bulkwalk( ${$nrep_count}, ${$rep_count}, $nrvars );
                        }

                        if ( $session->{ErrorNum} ) {

                            #do_log("$fork_num toto3");
                            if ( $session->{ErrorNum} == -24 ) {
                                do_log( "Bulkwalk timeout on device $dev: " . $session->{Timeout} * ( $session->{Retries} + 1 ) / 1000000 . "[sec] (Timeout=" . $session->{Timeout} / 1000000 . " * (1 + Retries=$session->{Retries}))", WARN, $fork_num );

                                # Several problem can occure: let maka some test if it is the first run (we try to discover)
                                #do_log("toto: ${ $run_count }");
                                if ( ${$run_count} == 1 ) {

                                    # try to see if bulwalk answer with sysdesc
                                    do_log( "Try snmp recovering from timeout: Try 'bulkwalk' work for sysdesc as varbind (1 value)", INFO, $fork_num );
                                    my $sdvars = new SNMP::VarList( ['.1.3.6.1.2.1.1.1.0'] );
                                    my @sdresp = $session->bulkwalk( 1, 0, $sdvars );
                                    if ( $session->{ErrorNum} == 0 ) {
                                        do_log( "Workaround #1 (Max repeater set to 0) successfully recover snmp polling", INFO, $fork_num );

                                        # TRY WORKAROUND #1: max-repeter set to 0, if sucessfull we will mark set this workaround (a just after all tests)
                                        #@nrresp = $session->bulkwalk( ${$nrep_count},  0 , $nrvars );
                                        ${$workaround} = 1;

                                        #${$rep_count} = 0;
                                        goto SNMP_START;
                                    } else {
                                        ${$workaround} = undef;
                                    }
                                }

                                # case1: no answe but alive and should answer
                                #
                            } elsif ( $session->{ErrorNum} == -58 ) {
                                do_log( "End of mib on device $dev: $session->{ErrorStr} ($session->{ErrorNum})", ERROR, $fork_num );
                            } elsif ( $session->{ErrorNum} == -35 ) {
                                do_log( "Auth Failure on device $dev: $session->{ErrorStr} ($session->{ErrorNum})", ERROR, $fork_num );
                            } else {
                                do_log( "Cannot do bulkwalk on device $dev: $session->{ErrorStr} ($session->{ErrorNum})", ERROR, $fork_num );
                            }
                            undef $session;

                        } elsif ( ( scalar @nrresp ) == 0 ) {
                            do_log( "Empty answer from device $dev without an error message", ERROR, $fork_num );
                            undef $session;

                        }

                        # Now that the polling is done and we have some the answers, first calc the time
                        ${$polling_time_cur} = time() - $begin_time;
                        if ( !defined ${$polling_time_avg} ) {
                            ${$polling_time_avg} = ${$polling_time_cur};
                            ${$polling_time_max} = ${$polling_time_cur};
                            ${$polling_time_min} = ${$polling_time_cur};
                        } else {
                            ${$polling_time_avg} = ( ( ${$polling_time_avg} * ( ${$run_count} - 1 ) ) + ${$polling_time_cur} ) / ${$run_count};
                            ${$polling_time_max} = ${$polling_time_cur} if ${$polling_time_max} < ${$polling_time_cur};
                            ${$polling_time_min} = ${$polling_time_cur} if ${$polling_time_min} > ${$polling_time_cur};
                        }

                        # Now that the polling is done we have to process the answers
                        my @oids = ( keys %{ $data_in{'reps'} }, keys %{ $data_in{'nonreps'} } );
                        ${$oid_count} = scalar @oids;

                        # Check first that we have some answer
                        $vbarr_counter = 0;
                        foreach my $vbarr (@nrresp) {
                            my $snmp_poll_oid = $$nrvars[$vbarr_counter]->tag();
                            if ( !scalar @{ $vbarr // [] } ) {    # there is no response (vbarr) or an undefined one #BUG74. TODO: Make it more explicit + Change error to warn if we can handle it properly
                                do_log( "Empty polled oid $snmp_poll_oid on device $dev", ERROR, $fork_num );
                            }
                            $vbarr_counter++;
                        }

                    OID: foreach my $oid_wo_dot (@oids) {         # INVERSING OID AND VBARR loop should increase perf)
                            my $found = 0;
                            my $oid   = "." . $oid_wo_dot;
                            $vbarr_counter = 0;
                        VBARR: foreach my $vbarr (@nrresp) {

                                # Same test as one above, can probably be optimzed
                                if ( !scalar @{ $vbarr // [] } ) {
                                    $vbarr_counter++;
                                    next;
                                }

                                # Determine which OID this request queried.  This is kept in the VarList
                                # reference passed to bulkwalk().
                                my $polled_oid          = ${ $poll_oid->{$oid}{oid} };    # Always the same as the SNMP POLLED OID: poid=spoid
                                my $stripped_oid        = substr $oid,        1;
                                my $stripped_polled_oid = substr $polled_oid, 1;
                                my $snmp_poll_oid       = $$nrvars[$vbarr_counter]->tag();
                                my $leaf_table_found    = 0;

                                if ( not defined $snmp_poll_oid ) {
                                    do_log( "$snmp_poll_oid not defined for device $dev, oid $oid", WARN, $fork_num );
                                    @remain_oids = push( @remain_oids, $oid );
                                    ${$path_is_slow} = 1;
                                    $vbarr_counter++;
                                    next;
                                }

                                foreach my $nrv (@$vbarr) {
                                    my $snmp_oid  = $nrv->name;
                                    my $snmp_val  = $nrv->val;
                                    my $snmp_type = $nrv->type;

                                    #do_log( "_DEBUG SNMP($fork_num): oid:$oid poid:$polled_oid soid:$snmp_oid spoid:$snmp_poll_oid svoid:$snmp_val stoid:$snmp_type", 5 ) if $g{debug};
                                    if ( $snmp_poll_oid eq $oid ) {

                                        do_log( "oid:$oid poid:$polled_oid soid:$snmp_oid spoid:$snmp_poll_oid svoid:$snmp_val stoid:$snmp_type", DEBUG, $fork_num ) if $g{debug};
                                        my $leaf = substr( $snmp_oid, length($oid) + 1 );
                                        $data_out{$stripped_oid}{'val'}{$leaf}  = $snmp_val;
                                        $data_out{$stripped_oid}{'time'}{$leaf} = time;
                                        $leaf_table_found++;

                                    } elsif ( $snmp_oid eq $oid ) {
                                        $found = 1;
                                        do_log( "oid:$oid poid:$polled_oid soid:$snmp_oid spoid:$snmp_poll_oid svoid:$snmp_val stoid:$snmp_type", TRACE, $fork_num ) if $g{debug};
                                        $data_out{$stripped_oid}{val}  = $snmp_val;
                                        $data_out{$stripped_oid}{time} = time;
                                        $oid_found++;
                                        next OID;
                                    }
                                }
                                if ( $leaf_table_found > 0 ) {
                                    $found = 1;
                                    $oid_found++;
                                    next OID;
                                }
                                $vbarr_counter++;
                            }
                            if ( !$found ) {
                                do_log( "No polled oid for $oid on device $dev", ERROR, $fork_num );

                            }
                        }

                        if ( $oid_found == ${$oid_count} ) {
                            do_log( "Found $oid_found/${$oid_count} oids for device $dev", DEBUG, $fork_num ) if $g{debug};

                        } else {

                            # houston we have a problem
                            do_log( "Found $oid_found/${$oid_count} oids for device $dev", ERROR, $fork_num );
                            ${$path_is_slow} = 1;

                            ############### do something to recover ##############START
                            foreach my $oid (@remain_oids) {
                                do_log( "Unable to poll $oid on device $dev", ERROR, $fork_num );
                            }
                            ############### do something to recover ##############END
                        }

                    }
                    send_data( $sock, \%data_out );
                    next DEVICE;
                }
                if (0) {    # previous code from S. Coene, we keep it as it is an implementation with getnext

                    foreach my $oid ( sort keys %{ $data_in{nonreps} } ) {
                        next if defined $data_out{error};

                        my $vb  = new SNMP::Varbind( [".$oid"] );
                        my $val = $session->get($vb);
                        if ($val) {
                            $data_out{$oid}{val}  = $val;
                            $data_out{$oid}{time} = time;
                        } else {
                            $data_out{error}{ $session->{ErrorStr} } = 1;
                            last;
                        }
                    }
                    foreach my $oid ( sort keys %{ $data_in{reps} } ) {
                        next if defined $data_out{error};

                        my $vb = new SNMP::Varbind( [".$oid"] );
                        my $val;

                        # for (INITIALIZE; TEST; STEP) {
                        for ( $val = $session->getnext($vb); $vb->tag eq ".$oid" and not $session->{ErrorNum}; $val = $session->getnext($vb) ) {
                            $data_out{$oid}{val}{ $vb->iid }  = $val;
                            $data_out{$oid}{time}{ $vb->iid } = time;
                            $data_out{maxrep}{$oid}++;
                        }
                    }

                    if ( $data_out{error} ) {
                        foreach my $error ( keys %{ $data_out{error} } ) {
                            do_log( "ERROR SNMP: $error", 1 );
                        }
                    }
                    send_data( $sock, \%data_out );

                    #} else {
                    #    my $error_str = "SNMP session did not start for device $snmpvars{Device}";
                    #    $data_out{error}{$error_str} = 1;
                    #    send_data( $sock, \%data_out );
                }
            }

            # Whoa, we don't support this version of SNMP
        } else {
            my $error_str = "Unsupported SNMP version for $data_in{dev} ($snmp_ver)";
            $data_out{error}{$error_str} = 1;
            send_data( $sock, \%data_out );
            next DEVICE;
        }
    }
}

# Make sure that forks are still alive
sub check_forks {
    for my $fork ( keys %{ $g{forks} } ) {
        my $pid = $g{forks}{$fork}{pid};
        if ( !kill 0, $pid ) {
            do_log( "Fork $fork with pid $pid died, cleaning up", INFO );
            close $g{forks}{$fork}{CS} or do_log( "Closing child socket failed: $!", 2 );
            delete $g{forks}{$fork};
        }
    }
}

# Subroutine to send an error message back to the parent process
sub send_data {
    my ( $sock, $data_out ) = @_;
    my $serialized = nfreeze($data_out);
    $sock->print("$serialized\nEOF\n");
}

# Reap dead forks
sub REAPER {
    my $fork;
    while ( ( $fork = waitpid( -1, WNOHANG ) ) > 0 ) { sleep 1 }
    $SIG{CHLD} = \&REAPER;
}

#sub oid_sort(@) {
#    return @_ unless ( @_ > 1 );
#    map { $_->[0] } sort { $a->[1] cmp $b->[1] } map {
#        my $oid = $_;
#        $oid =~ s/^\.//o;
#        $oid =~ s/ /\.0/og;
#        [ $_, pack( 'N*', split( '\.', $oid ) ) ]
#    } @_;
#}
