package dm_snmp;
require Exporter;
@ISA    = qw(Exporter);
@EXPORT = qw(poll_devices snmp_query);

#    Devmon: An SNMP data collector & page generator for the
#    Xymon network monitoring systems
#    Copyright (C) 2005-2006  Eric Schwimmer
#    Copyright (C) 2007  Francois Lacroix
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
use List::Util qw(min max);

#use Math::BigInt;
use POSIX       qw(:sys_wait_h :errno_h);
use Storable    qw(nfreeze thaw dclone);
use Time::HiRes qw(time usleep gettimeofday tv_interval);
use dm_config   qw(FATAL ERROR WARN INFO DEBUG TRACE);
use dm_config;
use dm_snmp_utils;
use dm_snmp_constants;

# Our global variable hash
use vars qw(%g);
*g = \%dm_config::g;

# Fiddle with some of our storable settings to correct byte order...
$Storable::interwork_56_64bit = 1;

# Add a wait for our dead forks
$SIG{CHLD} = \&REAPER;
use Carp;
sub snmpgetbulk ($$$@);
sub snmpopen ($$$);

# Sub that, given a hash of device data, will query specified oids for
# each device and return a hash of the snmp query results
sub poll_devices {

    # clear per-fork polled device counters
    foreach ( keys %{ $g{forks} } ) {
        $g{forks}{$_}{polled} = 0;
    }
    do_log( "Starting snmp queries", INFO );
    $g{snmppolltime} = time;
    my %snmp_input      = ();
    my %snmp_try_maxcnt = ();
    %{ $g{oid}{snmp_polled} } = ();

    # Query our Xymon server for device reachability status
    # we don't want to waste time querying devices that are down
    do_log( "Getting device status from Xymon at $g{dispserv}:$g{dispport}", INFO );
    %{ $g{xymon_color} } = ();
    my $sock = IO::Socket::INET->new(
        PeerAddr => $g{dispserv},
        PeerPort => $g{dispport},
        Proto    => 'tcp',
        Timeout  => 5,
    );
    if ( defined $sock ) {

        # Ask xymon for ssh, conn, http, telnet tests green on all devices
        print $sock "xymondboard test=conn|ssh|http|telnet color=green fields=hostname";
        shutdown( $sock, 1 );
        while ( my $device = <$sock> ) {
            chomp $device;
            $g{xymon_color}{$device} = 'green';
        }
        close($sock);
    }

    # Build our query hash
    $g{numsnmpdevs} = $g{numdevs};
QUERYHASH: for my $device ( sort keys %{ $g{devices} } ) {

        # Skip this device if we are running a Xymon server and the
        # server thinks that it isn't reachable
        if ( !defined $g{xymon_color}{$device} ) {
            do_log( "$device hasn't any Xymon tests skipping SNMP: add at least one! conn, ssh,...", INFO );
            --$g{numsnmpdevs};
            next QUERYHASH;
        }
        elsif ( $g{xymon_color}{$device} ne 'green' ) {
            do_log( "$device has a non-green Xymon status, skipping SNMP.", INFO );
            --$g{numsnmpdevs};
            next QUERYHASH;
        }

        # Prepare ou SNMP Query
        # Cleanup firts our oids
        # Do not clean snmp_perm (as it is a permanent store!)
        # 1. Old snmp polled should be removes
        # 2. Temporary/ephemeral should be removed
        # 3. Retry are also temporary and should be removed
        my $snmp_input_device_ref = \$g{devices}{$device}{snmp_input};
        $g{devices}{$device}{oids}{snmp_perm}{snmp_try_maxcnt}{val} = $g{snmp_try_maxcnt}
            if not defined $g{devices}{$device}{oids}{snmp_perm}{snmp_try_maxcnt}{val};
        $g{devices}{$device}{discover} = ( $g{current_cycle} == 1 ) if not defined $g{discover};
        ${$snmp_input_device_ref}->{is_discover_cycle} = ( $g{current_cycle} == 1 )
            if not defined $g{is_discover_cycle};
        ${$snmp_input_device_ref}->{current_cycle} = $g{current_cycle};
        ${$snmp_input_device_ref}->{current_try}   = 0;

        # Set timeout
        ${$snmp_input_device_ref}->{snmp_try_timeout}     //= $g{snmp_try_timeout};
        ${$snmp_input_device_ref}->{snmp_getbulk_timeout} //= $g{snmp_getbulk_timeout};

        #${$snmp_input_device_ref}->{snmp_try_timeout} //= $g{cycletime}*0.8; #Set de default timeout to 80% of the cycletime
        if ( $g{devices}{$device}{discover} ) {

            # (re)Discovering the device: prepare the SNMP query
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

            # copy only what is needed for the snmp query (the global hash is to high
            # Shortcut
            ${$snmp_input_device_ref}->{authpass} = $g{devices}{$device}{authpass}
                if defined $g{devices}{$device}{authpass} and ( $g{devices}{$device}{authpass} ne '' );
            ${$snmp_input_device_ref}->{authproto} = $g{devices}{$device}{authproto}
                if defined $g{devices}{$device}{authproto} and ( $g{devices}{$device}{authproto} ne '' );
            ${$snmp_input_device_ref}->{cid} = $g{devices}{$device}{cid}
                if defined $g{devices}{$device}{cid} and ( $g{devices}{$device}{cid} ne '' );
            ${$snmp_input_device_ref}->{dev} = $device;
            ${$snmp_input_device_ref}->{ip}  = $g{devices}{$device}{ip}
                if defined $g{devices}{$device}{ip} and ( $g{devices}{$device}{ip} ne '' );
            ${$snmp_input_device_ref}->{port} = $g{devices}{$device}{port}
                if defined $g{devices}{$device}{port} and ( $g{devices}{$device}{port} ne '' );
            ${$snmp_input_device_ref}->{privpass} = $g{devices}{$device}{privpass}
                if defined $g{devices}{$device}{privpass} and ( $g{devices}{$device}{privpass} ne '' );
            ${$snmp_input_device_ref}->{privproto} = $g{devices}{$device}{privproto}
                if defined $g{devices}{$device}{privproto} and ( $g{devices}{$device}{privproto} ne '' );
            ${$snmp_input_device_ref}->{resolution} = $g{devices}{$device}{resolution}
                if defined $g{devices}{$device}{resolution} and ( $g{devices}{$device}{resolution} ne '' );
            ${$snmp_input_device_ref}->{seclevel} = $g{devices}{$device}{seclevel}
                if defined $g{devices}{$device}{seclevel} and ( $g{devices}{$device}{seclevel} ne '' );
            ${$snmp_input_device_ref}->{secname} = $g{devices}{$device}{secname}
                if defined $g{devices}{$device}{secname} and ( $g{devices}{$device}{secname} ne '' );
            ${$snmp_input_device_ref}->{ver} = $g{devices}{$device}{ver};
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
                        ${$snmp_input_device_ref}->{reps}{$number} = 1;
                        ${$snmp_input_device_ref}->{reps}{$number} = $g{max_rep_hist}{$device}{$number};

                        # Otherwise this is a nonrepeater (leaf)
                    }
                    else {
                        ${$snmp_input_device_ref}->{nonreps}{$number} = 1;
                    }
                }
            }
        }
        $snmp_input{$device} = undef;
        $snmp_input{$device} = dclone $g{devices}{$device}{ snmp_input };
    }

    # Throw the query hash to the forked query processes
    snmp_query( \%snmp_input );

    # Final check!
    for my $device ( sort keys %{ $g{devices} } ) {
        my $expected         = 0;
        my $received         = 0;
        my $discover_success = 0;
        if ( $snmp_input{$device}{is_discover_cycle} ) {
            for my $snmp_errornum ( values %{ $g{devices}{$device}{oids}{snmp_temp}{snmp_errornum}{val} } ) {
                if ( defined $snmp_errornum and $snmp_errornum == 0 ) {
                    $discover_success = 1;
                    last;
                }
            }
        }
        for my $expected_oid ( keys %{ $g{devices}{$device}{snmp_input}{nonreps} } ) {
            if ( not exists $g{devices}{$device}{oids}{snmp_polled}{$expected_oid} ) {
                do_log( "No answer for oid:$expected_oid on device:$device", WARN );
                if ( exists $g{devices}{$device}{oids}{snmp_input}{oids}{val}{$expected_oid}{nosuchobject} ) {
                    do_log( "Discovery cycle deletes oid:$expected_oid on device:$device from snmp query", WARN );
                    delete $g{devices}{$device}{snmp_input}{nonreps}{$expected_oid};
                    $expected--;
                }
            }
            else {
                $received++;
            }
            if (   not exists $g{devices}{$device}{snmp_input}{oids}{$expected_oid}
                or not exists $g{devices}{$device}{snmp_input}{oids}{$expected_oid}{nosuchobject} )
            {
                $expected++;
            }
        }
        for my $expected_oid ( keys %{ $g{devices}{$device}{snmp_input}{reps} } ) {
            if ( not exists $g{devices}{$device}{oids}{snmp_polled}{$expected_oid} ) {
                do_log( "No answer for oid:$expected_oid on device:$device", WARN );
                if ( exists $g{devices}{$device}{oids}{snmp_input}{oids}{val}{$expected_oid}{nosuchobject} ) {
                    do_log( "Discovery cycle deletes oid:$expected_oid on device:$device from snmp query", WARN );
                    delete $g{devices}{$device}{snmp_input}{reps}{$expected_oid};
                    $expected--;
                }
            }
            else {
                $received++;
            }
            if (   not exists $g{devices}{$device}{snmp_input}{oids}{$expected_oid}
                or not exists $g{devices}{$device}{snmp_input}{oids}{$expected_oid}{nosuchobject} )
            {
                $expected++;
            }
        }
        if ( $expected != $received ) {
            do_log( "Received $received" . "/" . "$expected oid for device $device", WARN );
        }
        while ( my ( $k, $v ) = each( %{ $g{devices}{$device}{oids}{snmp_input} } ) ) {
            if ( ref $v->{val} eq 'HASH' ) {
                while ( my ( $k_hash, $v_hash ) = each( %{ $v->{val} } ) ) {
                    $g{devices}{$device}{snmp_input}{$k}{$k_hash} = $v_hash;
                }
            }
            else {
                $g{devices}{$device}{snmp_input}{$k} = $v->{val};
            }
        }
    }

    # Record how much time this all took
    $g{snmppolltime} = time - $g{snmppolltime};
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
    if ( $g{numsnmpdevs} == 0 ) {
        $g{maxpolltime} = $g{snmp_try_small_timeout} * $g{snmp_try_small_maxcnt} * ( scalar keys %{$snmp_input} );
    }

    # Start forks if needed
    fork_queries()
        if ( ( keys %{ $g{forks} } < $g{numforks} && keys %{ $g{forks} } < $g{numsnmpdevs} )
        or ( keys %{ $g{forks} } == 0 and $g{numsnmpdevs} < 2 ) );

    # Clean our hash and prepare it
    # to be splitten amongst our forks
    my @devices;
    for my $device ( keys %{$snmp_input} ) {
        delete $g{devices}{$device}{oids}{snmp_polled};
        delete $g{devices}{$device}{oids}{snmp_temp};

        # Initialize max tries for read host discovery!
        if ( not exists $g{devices}{$device}{oids}{snmp_perm}{snmp_try_maxcnt} ) {
            $g{devices}{$device}{oids}{snmp_perm}{snmp_try_maxcnt}{val} = 1;
        }
    }
    for my $device (
        reverse sort {

            # Get the minimum value or set it to $max if it doesn't exist
            my $min_a
                = exists $snmp_input->{$a}{stats}{snmptry_min_duration}
                ? min( values %{ $snmp_input->{$a}{stats}{snmptry_min_duration} } )
                : $g{maxpolltime};
            my $min_b
                = exists $snmp_input->{$b}{stats}{snmptry_min_duration}
                ? min( values %{ $snmp_input->{$b}{stats}{snmptry_min_duration} } )
                : $g{maxpolltime};
            $min_a <=> $min_b;
        } keys %{$snmp_input}
        )
    {
        push @devices, $device;
    }
    my $polltime = time();
    while ( @devices or $active_forks ) {
        foreach my $fork ( sort { $a <=> $b } keys %{ $g{forks} } ) {

            # First lets see if our fork is working on a device
            if ( defined $g{forks}{$fork}{dev} ) {
                my $device = $g{forks}{$fork}{dev};

                # It is, lets see if its ready to give us some data
                my $select = IO::Select->new( $g{forks}{$fork}{CS} );
                if ( $select->can_read(0.01) ) {
                    $g{devices}{$device}{oids}{snmp_temp}{snmp_try_cnt}{val} //= 1;
                    do_log( "Fork:$fork has data for device:$device, reading it", TRACE ) if $g{debug};

                    # Okay, we know we have something in the buffer, keep reading
                    # till we get an EOF
                    my $data_in = '';
                    eval {
                        local $SIG{ALRM} = sub { die "Timeout waiting for EOF from fork\n" };
                        alarm 15;

                        # Read data from the forked process
                        while (1) {
                            my $read = $g{forks}{$fork}{CS}->getline();
                            if ( defined $read ) {
                                $data_in .= $read;
                            }
                            else {
                                select undef, undef, undef, 0.05;    # Throttle the loop to avoid busy-waiting
                            }
                            last if $data_in =~ s/\nEOF\n$//s;       # Stop reading when EOF marker is found
                        }
                    };
                    alarm 0;
                    if ($@) {
                        do_log( "Fork:$fork pid:$g{forks}{$fork}{pid} stalled on device:$device: $@. Killing this fork.", ERROR );
                        if ( kill( 0, $g{forks}{$fork}{pid} ) ) {
                            kill 'TERM', $g{forks}{$fork}{pid};
                            sleep 1;                                 # Give it time to terminate
                            if ( kill( 0, $g{forks}{$fork}{pid} ) ) {
                                kill 'KILL', $g{forks}{$fork}{pid};    # Force kill if still alive
                            }
                        }
                        close $g{forks}{$fork}{CS}
                            or do_log( "Closing socket to fork $fork failed: $!", ERROR );
                        delete $g{forks}{$fork};
                        --$active_forks;
                        fork_queries();
                        push @devices, $device;
                        $g{devices}{$device}{oids}{snmp_temp}{snmp_try_cnt}{val} += 1;
                        do_log( "Device: $device Try:$g{devices}{$device}{oids}{snmp_temp}{snmp_try_cnt}{val} Msg:snmp polling enqueue",
                            INFO );
                        next;
                    }
                    do_log( "Fork $fork returned complete message for device $device", DEBUG ) if $g{debug};

                    # Looks like we got some data
                    my $hashref = thaw($data_in);
                    my %returned;
                    if ( defined $hashref ) {
                        do_log( "Dethawing data for $device", DEBUG ) if $g{debug};
                        %returned = %{$hashref};

                        # increment the per-fork polled device counter
                        $g{forks}{$fork}{polled}++;
                    }
                    else {
                        print "failed thaw on $device\n";
                        push @devices, $device;
                        next;
                    }
                    $g{devices}{$device}{oids}{snmp_temp}{snmp_try_cnt}{val} = 1
                        if not exists $g{devices}{$device}{oids}{snmp_temp}{snmp_try_cnt}{val};
                    if ( exists $returned{snmp_msg} ) {
                        my $snmp_msg_count = keys %{ $g{devices}{$device}{oids}{snmp_temp}{snmp_msg}{val} };
                        for my $snmp_msg_idx ( sort { $a <=> $b } keys %{ $returned{snmp_msg} } ) {
                            $snmp_msg_count++;
                            my $snmp_msg
                                = "Try:$g{devices}{$device}{oids}{snmp_temp}{snmp_try_cnt}{val} Msg:$returned{snmp_msg}{$snmp_msg_idx}";
                            $g{devices}{$device}{oids}{snmp_temp}{snmp_msg}{val}{$snmp_msg_count} = $snmp_msg;
                            $snmp_msg = "Device:$device $snmp_msg";
                            do_log( "Fork:$fork $snmp_msg", WARN );
                        }
                        delete $returned{snmp_msg};
                    }

                    # Reformat our polled oids results and insert them to the global hash
                    while ( my ( $k1, $v1 ) = each( %{ $returned{oids}{snmp_polled} } ) ) {
                        while ( my ( $k2, $v2 ) = each( %{$v1} ) ) {
                            if ( ref $v2 eq 'HASH' ) {    #this is a rep
                                while ( my ( $k3, $v3 ) = each( %{$v2} ) ) {
                                    $g{devices}{$device}{oids}{snmp_polled}{$k1}{$k3}{$k2}
                                        = $v3;            #swap order val <->leaf
                                }
                            }
                            else {                        #this is a nrep
                                $g{devices}{$device}{oids}{snmp_polled}{$k1}{$k2} = $v2;
                            }
                        }
                    }
                    if ( defined $returned{snmp_errornum} and $returned{snmp_errornum} == 0 ) {
                        my $snmp_errornum_count = keys %{ $g{devices}{$device}{oids}{snmp_temp}{snmp_errornum}{val} };
                        $g{devices}{$device}{oids}{snmp_temp}{snmp_errornum}{val}{ ++$snmp_errornum_count } = 0;
                        delete $returned{snmp_errornum};
                        delete $returned{snmp_errorstr};
                    }
                    else {
                        # We have probably error
                        # Store and log all error info
                        my $snmp_errorstr_count = keys %{ $g{devices}{$device}{oids}{snmp_temp}{snmp_errorstr}{val} };
                        my $snmp_errornum_count = keys %{ $g{devices}{$device}{oids}{snmp_temp}{snmp_errornum}{val} };
                        my $snmp_error_count    = $snmp_errorstr_count > $snmp_errornum_count ? $snmp_errorstr_count : $snmp_errornum_count;
                        $g{devices}{$device}{oids}{snmp_temp}{snmp_errorstr}{val}{ ++$snmp_error_count }
                            = $returned{snmp_errorstr};
                        $g{devices}{$device}{oids}{snmp_temp}{snmp_errornum}{val}{ ++$snmp_error_count } = $returned{snmp_errornum}
                            if defined $returned{snmp_errornum} // 'Undef';
                        if ( ( defined $returned{snmp_errornum} ) and ( $returned{snmp_errornum} == -24 ) ) {
                            do_log(
                                "Fork:$fork Device:$device Try:$g{devices}{$device}{oids}{snmp_temp}{snmp_try_cnt}{val} Err:"
                                    . $returned{snmp_errorstr}
                                    . ( defined $returned{snmp_errornum} ? "(" . $returned{snmp_errornum} . ")" : '' ),
                                INFO
                            );
                        }
                        else {
                            do_log(
                                "Fork:$fork Device:$device Try:$g{devices}{$device}{oids}{snmp_temp}{snmp_try_cnt}{val} Err:"
                                    . ( defined $returned{snmp_errorstr} ? $returned{snmp_errorstr}             : '' )
                                    . ( defined $returned{snmp_errornum} ? "(" . $returned{snmp_errornum} . ")" : '' ),
                                ERROR
                            );
                        }

                        # Store partial result if any and reduce next request
                        my $expected = 0;
                        my $received = 0;
                        for my $expected_oid ( keys %{ $snmp_input->{$device}{nonreps} } ) {
                            if ( defined $returned{oids}{snmp_polled}{$expected_oid} ) {
                                if ( not exists $returned{oids}{snmp_retry}{$expected_oid} ) {
                                    delete $snmp_input->{$device}{nonreps}{$expected_oid};
                                    $received++;
                                }
                            }
                            if ( not exists $returned{oids}{snmp_input}{oids}{$expected_oid}{nosuchobject} ) {
                                $expected++;
                            }
                        }
                        for my $expected_oid ( keys %{ $snmp_input->{$device}{reps} } ) {
                            if ( defined $returned{oids}{snmp_polled}{$expected_oid} ) {
                                if ( not exists $returned{oids}{snmp_retry}{$expected_oid} ) {
                                    delete $snmp_input->{$device}{reps}{$expected_oid};
                                    delete $snmp_input->{$device}{oids}{snmp_polled}{$expected_oid};
                                    $received++;
                                }
                            }
                            if ( not exists $returned{oids}{snmp_input}{oids}{$expected_oid}{nosuchobject} ) {
                                $expected++;
                            }
                        }
                        if ( $expected > $received ) {
                            if ( ( time() - $polltime + $snmp_input->{$device}{snmp_try_timeout} ) < $g{maxpolltime} ) {
                                if ( $g{devices}{$device}{oids}{snmp_temp}{snmp_try_cnt}{val}
                                    < $g{devices}{$device}{oids}{snmp_perm}{snmp_try_maxcnt}{val} )
                                {
                                    push @devices, $device;
                                    $g{devices}{$device}{oids}{snmp_temp}{snmp_try_cnt}{val} += 1;
                                    do_log(
"Device: $device Try:$g{devices}{$device}{oids}{snmp_temp}{snmp_try_cnt}{val} Msg:snmp polling enqueue",
                                        INFO
                                    );
                                }
                                else {
                                    do_log(
"Device: $device Try:$g{devices}{$device}{oids}{snmp_temp}{snmp_try_cnt}{val} Msg:snmp_try_maxcnt reached, snmp polling stops",
                                        WARN
                                    );
                                }
                            }
                            else {
                                do_log(
"Device: $device Try:$g{devices}{$device}{oids}{snmp_temp}{snmp_try_cnt}{val} Msg:No time left, snmp polling stops",
                                    WARN
                                );
                            }
                        }

                        # add other usefull info for retry
                        $snmp_input->{$device}{snmpwalk_duration} = $returned{snmp_perm}{snmpwalk_duration};
                    }
                    while ( my ( $k, $v ) = each( %{ $returned{snmp_perm} } ) ) {
                        $g{devices}{$device}{oids}{snmp_perm}{$k}{val} = $v;
                    }
                    while ( my ( $k, $v ) = each( %{ $returned{snmp_temp} } ) ) {
                        $g{devices}{$device}{oids}{snmp_temp}{$k}{val} = $v;
                    }
                    while ( my ( $k, $v ) = each( %{ $returned{oids}{snmp_input} } ) ) {
                        $g{devices}{$device}{oids}{snmp_input}{$k}{val} = $v;
                    }

                    # The retries are temp and should be reinjected in the imput
                    $snmp_input->{$device}{snmp_retry} = $returned{oids}{snmp_retry};

                    # Now put our fork into an idle state
                    --$active_forks;
                    delete $g{forks}{$fork}{dev};

                    # No data, lets make sure we're not hung
                }
                else {
                    my $pid = $g{forks}{$fork}{pid};

                    # See if we've exceeded our max poll time
                    my $forktime = time - $g{forks}{$fork}{time};
                    if ( $forktime > $g{maxpolltime} ) {
                        do_log( "Fork $fork ($pid) time exceed max poll time polling $g{maxpolltime} on device $device", WARN );

                        # Kill it
                        kill 15, $pid or do_log( "Sending fork $fork TERM signal failed: $!", ERROR );
                        close $g{forks}{$fork}{CS} or do_log( "Closing socket to fork $fork failed: $!", ERROR );
                        delete $g{forks}{$fork};
                        --$active_forks;
                        fork_queries();

                        # We haven't exceeded our poll time, but make sure its still live
                    }
                    elsif ( !kill 0, $pid ) {

                        # Whoops, looks like our fork died somewhow
                        do_log( "Fork $fork ($pid) died polling $device", ERROR );
                        close $g{forks}{$fork}{CS}
                            or do_log( "Closing socket to fork $fork failed: $!", ERROR );
                        delete $g{forks}{$fork};
                        --$active_forks;
                        fork_queries();
                    }
                }
            }

            # If our forks are idle, give them something to do
            if ( !defined $g{forks}{$fork}{dev} and @devices ) {
                my $device         = shift @devices;
                my $polltime_start = time();
                if ( ( $polltime_start - $polltime ) < $g{maxpolltime} ) {
                    $g{forks}{$fork}{dev} = $device;
                    ++$snmp_input->{$device}{current_try};

                    #my $polltime_start = time();
                    if ( ( $g{maxpolltime} - ( $polltime_start - $polltime ) ) < $snmp_input->{$device}{snmp_try_timeout} ) {
                        $snmp_input->{$device}{snmp_try_deadline} = $g{maxpolltime} + $polltime_start;
                    }
                    else {
                        $snmp_input->{$device}{snmp_try_deadline}
                            = $polltime_start + $snmp_input->{$device}{snmp_try_timeout};
                    }

                    # Now send our input to the fork
                    my $serialized = nfreeze( $snmp_input->{$device} );
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
                    $g{forks}{$fork}{time} = $polltime_start;
                }
            }

            # If our fork is idle and has been for more than the cycle time
            # make sure it is still alive
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
                                }
                                else {
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
                        }
                        else {
                            print "failed thaw for ping of fork $fork\n";
                            next;
                        }
                        if ( defined $returned{pong} ) {
                            $g{forks}{$fork}{time} = time;
                            do_log( "Fork $fork responded to ping request $returned{ping} with $returned{pong} at $g{forks}{$fork}{time}",
                                DEBUG )
                                if $g{debug};
                            delete $g{forks}{$fork}{pinging};
                        }
                        else {
                            do_log( "Fork $fork didn't send an appropriate response, killing it", DEBUG )
                                if $g{debug};
                            kill 15, $g{forks}{$fork}{pid}
                                or do_log( "Sending $fork TERM signal failed: $!", ERROR );
                            close $g{forks}{$fork}{CS}
                                or do_log( "Closing socket to fork $fork failed: $!", ERROR );
                            delete $g{forks}{$fork};
                            next;
                        }
                    }
                    else {
                        do_log( "Fork $fork seems not to have replied to our ping, killing it", ERROR );
                        kill 15, $g{forks}{$fork}{pid} or do_log( "Sending $fork TERM signal failed: $!", ERROR );
                        close $g{forks}{$fork}{CS} or do_log( "Closing socket to fork $fork failed: $!", ERROR );
                        delete $g{forks}{$fork};
                        next;
                    }
                }
                else {
                    my %ping_input = ( 'ping' => time );
                    do_log( "Fork $fork has been idle for more than cycle time, pinging it at $ping_input{ping}", DEBUG )
                        if $g{debug};
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
        }
        elsif ( defined $pid ) {

            # Child code here
            $g{parent} = 0;                                                      # We aren't the parent any more...
            do_log( "Fork $num using sockets $g{forks}{$num}{PS} <-> $g{forks}{$num}{CS} for IPC", TRACE, $num )
                if $g{debug};
            foreach ( sort { $a <=> $b } keys %{ $g{forks} } ) {
                do_log( "Fork $num closing socket (child $_) $g{forks}{$_}{PS}", TRACE, $num ) if $g{debug};
                $g{forks}{$_}{CS}->close
                    or do_log( "Closing socket for fork $_ failed: $!", ERROR );    # Same as above
            }
            $0 = "devmon-$num";                                                     # Remove our 'master' tag
            fork_sub($num);                                                         # Enter our neverending query loop
            exit;                                                                   # We should never get here, but just in case
        }
        else {
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
    my $snmp_msg_count;
    my $snmp_errornum;
    my $snmp_errorstr;
    my %session;

    # permanent variable storage for fast path with SNMP.pm
    my %snmp_persist_storage;
DEVICE: while (1) {    # We should never leave this loop
                       # Our outbound data hash
        my %data_out = ();
        $snmp_msg_count = 0;
        $snmp_errornum  = undef;
        $snmp_errorstr  = undef;

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

                    #exit 1;
                    exit 0;
                }
                my $sleeptime = $g{cycletime} / 2;
                do_log( "Parent ($g{mypid}) seems to be running, fork $fork_num sleeping for $sleeptime", WARN, $fork_num );
                sleep 1;
            }
            $serialized .= $string_in if defined $string_in;
        } until $serialized =~ s/\nEOF\n$//s;
        do_log( "Got EOF in message, attempting to thaw", TRACE, $fork_num ) if $g{debug};

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
        my $snmp_ver      = $data_in{ver};
        my $timeout_count = exists $data_in{timeout_count} ? $data_in{timeout_count} : 0;
        my $discover      = exists $data_in{discover}      ? $data_in{discover}      : 0;

        # Establish SNMP session
        my $session;
        my $snmp_lib;
        if ( !defined $data_in{nonreps} and !defined $data_in{reps} ) {
            my $error_str = "No oids to query for $data_in{dev}, skipping";
            $data_out{error}{$error_str} = 1;
            send_data( $sock, \%data_out );
            next DEVICE;
        }
        elsif ( !defined $data_in{ver} ) {
            my $error_str = "No snmp version found for $data_in{dev}";
            $data_out{error}{$error_str} = 1;
            send_data( $sock, \%data_out );
            next DEVICE;
        }
        my $device         = ( defined $data_in{ip} and $data_in{ip} ne '' ) ? $data_in{ip} : $data_in{dev};
        my %session_params = (

            #host          => ( defined $data_in{ip} and $data_in{ip} ne '' ) ? $data_in{ip} : $data_in{dev},
            host        => $device,
            community   => $data_in{cid},
            port        => $data_in{port} // 161,
            version     => $snmp_ver,
            timeout     => 1,
            retries     => 0,
            backoff     => 1.0,
            max_pdu_len => 16384,                   # Seems not to be configurable in lib SNMP.pm
            secname     => $data_in{secname},
            seclevel    => $data_in{seclevel},
            authproto   => $data_in{authproto},
            authpass    => $data_in{authpass},
            privproto   => $data_in{privproto},
            privpass    => $data_in{privpass},

            #                debug       => $g{debug},
            debug => 1,
        );

        #my $session;
        # Check SNMP engine and initialize session
        if ( $g{snmpeng} eq 'auto' || $g{snmpeng} eq 'SNMP' ) {

            # Use SNMP.pm if engine is 'auto' or 'SNMP'
            require dm_snmp_net_snmp_c;
            $snmp_lib = "SNMP";
            $session{$device} = init_session( $snmp_lib, \%session_params );
        }
        elsif ( $g{snmpeng} eq 'session' && $snmp_ver ne '3' ) {

            # Use SNMP_Session.pm if engine is 'session' and SNMP version is not '3'
            require dm_snmp_snmp_session;
            $snmp_lib = "SNMP_Session";
            $session{$device} = init_session( $snmp_lib, \%session_params );
        }
        else {
            # Skip the device if SNMP engine is not valid or SNMPv3 is selected with 'session'
            my $error_msg = "❌ Invalid SNMP engine or SNMPv3 selected for SNMP_Session. Skipping device $data_in{dev}.";
            do_log( $error_msg, WARN, $fork_num );
            send_data( $sock, \%data_out );
            next DEVICE;
        }
        $session = $session{$device};

        # Formule: GLOBAL.SNMP.MAXPDUPACKETSIZE = (MAX-REPETITION * (OID_Length + )) + 80
        my $snmp_try_maxcnt  = 1;
        my %query_get_params = ( timeout => $data_in{snmp_get_timeout} // $g{snmp_get_timeout}, retries => 0, );
        my %query_getnext_params
            = ( timeout => $data_in{snmp_getnext_timeout} // $g{snmp_getnext_timeout}, retries => 0, );
        my %query_getbulk_params
            = ( timeout => $data_in{snmp_getbulk_timeout} // $g{snmp_getbulk_timeout}, retries => 0, );
        my %query_get_params_disco = ( timeout => $data_in{snmp_get_timeout} // $g{snmp_get_timeout}, retries => $g{snmp_disco_retries}, );
        my %query_getnext_params_disco
            = ( timeout => $data_in{snmp_getnext_timeout} // $g{snmp_getnext_timeout}, retries => $g{snmp_disco_retries}, );
        my %query_getbulk_params_disco
            = ( timeout => $data_in{snmp_getbulk_timeout} // $g{snmp_getbulk_timeout}, retries => $g{snmp_disco_retries}, );

        # we substract 0.2 millisecond to timeout before the main process (to be ckecked if best value)
        my $snmp_try_deadline     = $data_in{snmp_try_deadline} - 0.2;
        my $max_getbulk_responses = $data_in{max_getbulk_responses};
        my $max_getnext_responses = $data_in{max_getnext_responses};
        my $max_getbulk_repeaters = $data_in{max_getbulk_repeaters};
        my $use_getnext           = $data_in{use_getnext} // ( $snmp_ver eq '1' ? 1 : 0 );
        my $sgbmomr1              = $data_in{sgbmomr1} if exists $data_in{sgbmomr1};
        my $sgbmomr2              = $data_in{sgbmomr2} if exists $data_in{sgbmomr2};
        my $snmptry_min_duration  = $data_in{snmptry_min_duration};
        my $snmptry_max_duration  = $data_in{snmptry_max_duration};
        my $snmp_getbulk_timeout  = $data_in{snmp_getbulk_timeout} // $g{snmp_getbulk_timeout};
        my $snmp_get_timeout      = $data_in{snmp_get_timeout}     // $g{snmp_get_timeout};
        my $snmp_getnext_timeout  = $data_in{snmp_getnext_timeout} // $g{snmp_getnext_timeout};
        my $current_cycle         = $data_in{current_cycle}        // 0;
        my $current_try           = $data_in{current_try};
        my $is_try1               = !( $current_try != 1 );
        $data_out{oids}{snmp_input}{stats} = $data_in{stats};
        my $snmpwalk_mode;
        my $nb_of_snmpwalk_mode = 6;

        # we get stat 2 times for each mode at start and 1 time randomly each 100 cycle
        my $is_optim_cycle
            = ( $current_try == 1 ) && ( ( $current_cycle - 1 ) <= ( $nb_of_snmpwalk_mode * 2 ) || !int( rand(100) ) );

        # Stage: Not discovered = 0, initial discovery completed= 10, all discovery completed 20, 1,2,3,4i,,, = Step discoverd
        my $discover_stage    = exists $data_in{discover_stage} ? $data_in{discover_stage} : 0;
        my $is_discover_cycle = ( $discover_stage < 10 );

        # Special case for read host
        if ( not exists $data_in{reps} and ( scalar keys %{ $data_in{nonreps} } ) == 1 and $current_cycle == 0 ) {
            $is_discover_cycle    = 0;
            $use_getnext          = 1;
            %query_getnext_params = %query_getnext_params_disco;
        }

        # Prepare our session paramater that have to stay open if possible
        my %rep;
        %rep = %{ $data_in{reps} } if exists $data_in{reps};
        my %nrep = %{ $data_in{nonreps} } if exists $data_in{nonreps};
        for my $oid ( keys %{ $data_in{oids} } ) {
            if ( exists $data_in{oids}{$oid}{nosuchobject} ) {
                delete $rep{$oid};
                delete $nrep{$oid};
            }
        }
        my %deep_rep;
        my %poll_rep_oid;
        my %poll_nrep_oid;
        my %oid;

        # Create our real oids list of repeater and non-repetears
        # We maintain 3 lists for max repetition
        my %poll_rep_defined_mr;
        my %poll_rep_mr_defined;    #  The reverse mapping
        my %poll_rep_undefined_mr;
        my %poll_nrep;

        # Create the oids list of repeters
        for my $oid ( oid_sort keys %rep ) {
            my $poid = deeph_find_parent( $oid, \%deep_rep );
            my %coid = deeph_find_branch_h( $oid, \%deep_rep );
            if ( defined $poid ) {

                # The oid or its a parent already exists!
                # add it to its list !
                $poll_rep_oid{$poid}{oids}{$oid} = undef;
                $oid{$oid}{poll_oid} = $poid;
            }
            elsif ( scalar( keys %coid ) ) {

                # The hash has alread child oid defined
                # delete them and put them under our new oid
                for my $coid ( keys %coid ) {
                    delete $poll_rep_oid{$coid}{oids}{$coid};      # We delete them in our poll hash
                    delete $poll_rep_defined_mr{$coid};
                    delete $poll_rep_undefined_mr{$coid};
                    delete $poll_rep_mr_defined{ $data_in{oids}{$coid}{max_repetitions} }{$coid};
                    $poll_rep_oid{$oid}{oids}{$coid} = undef;      # We add them under the new oid
                    deeph_delete_oidkey_h( $coid, \%deep_rep );    # we delete them in our deep_h
                    $oid{$coid}{poll_oid} = $oid;
                }
                deeph_insert_oidkey_h( $oid, \%deep_rep );
                $poll_rep_oid{$oid}{oids}{$oid} = undef;
                $poll_rep_oid{$oid}{start}      = $oid;
                $poll_rep_oid{$oid}{cnt}        = 0;
                $oid{$oid}{poll_oid}            = $oid;
                if ( defined $data_in{snmp_retry}{$oid}{left_repetitions} ) {    #In case of Retry
                    $poll_rep_defined_mr{$oid} = $data_in{snmp_retry}{$oid}{left_repetitions};
                    $poll_rep_mr_defined{ $data_in{snmp_retry}{$oid}{left_repetitions} }{$oid} = undef;
                    $poll_rep_oid{$oid}{start}
                        = $oid . "." . $data_in{snmp_retry}{$oid}{start};        # a new start should be defined,
                }
                elsif ( defined $data_in{oids}{$oid}{max_repetitions} ) {        # Max repetion is set
                    $poll_rep_defined_mr{$oid}                                          = $data_in{oids}{$oid}{max_repetitions};
                    $poll_rep_mr_defined{ $data_in{oids}{$oid}{max_repetitions} }{$oid} = undef;
                    $poll_rep_oid{$oid}{start}                                          = $oid . "." . $data_in{snmp_retry}{$oid}{start}
                        if defined $data_in{snmp_retry}{$oid}{start};
                }
                else {
                    $poll_rep_undefined_mr{$oid} = undef;
                }
            }
            else {
                # The normal case : just insert our oid
                deeph_insert_oidkey_h( $oid, \%deep_rep );                       #mark the oid with 1 to say it exists
                $poll_rep_oid{$oid}{oids}{$oid} = undef;
                $poll_rep_oid{$oid}{start}      = $oid;
                $poll_rep_oid{$oid}{cnt}        = 0;
                $oid{$oid}{poll_oid}            = $oid;
                if ( defined $data_in{snmp_retry}{$oid}{left_repetitions} ) {    #In case of Retry
                    $poll_rep_defined_mr{$oid} = $data_in{snmp_retry}{$oid}{left_repetitions};
                    $poll_rep_mr_defined{ $data_in{snmp_retry}{$oid}{left_repetitions} }{$oid} = undef;
                    $poll_rep_oid{$oid}{start}
                        = $oid . "." . $data_in{snmp_retry}{$oid}{start};        # a new start should be defined,
                }
                elsif ( defined $data_in{oids}{$oid}{max_repetitions} ) {        # Max repetion is set
                    $poll_rep_defined_mr{$oid}                                          = $data_in{oids}{$oid}{max_repetitions};
                    $poll_rep_mr_defined{ $data_in{oids}{$oid}{max_repetitions} }{$oid} = undef;
                    $poll_rep_oid{$oid}{start}                                          = $oid . "." . $data_in{snmp_retry}{$oid}{start}
                        if defined $data_in{snmp_retry}{$oid}{start};
                }
                else {
                    $poll_rep_undefined_mr{$oid} = undef;
                }
            }
        }

        # Create the oid list of non-repeaters
        for my $oid ( keys %nrep ) {
            if ( $oid =~ /\.0$/ ) {    # is an SNMP Scalar (end with .0) are real non-repeater
                my $pvl_oid = $oid =~ s/\.0$//r;    # previous lex is the parent
                                                    # deeph_insert_oidkey_h( $oid, \%deep_rep );
                $poll_nrep_oid{$pvl_oid} = $oid;
                $oid{$oid}{poll_oid}     = $pvl_oid;
                $poll_nrep{$pvl_oid}     = undef;
            }
            else {
                my $poid = deeph_find_parent( $oid, \%deep_rep );
                if ( defined $poid ) {

                    # The oid or its a parent already exists!
                    # add it to its list !
                    $poll_rep_oid{$poid}{oids}{$oid} = undef;
                }
                else {
                    # If we dont have it, we take the parent as this is the best we can do.
                    my $pvl_oid;
                    $pvl_oid = $oid{$oid}{prev_lex_oid} if exists $oid{$oid}{prev_lex_oid};    #this never match?
                    if ( defined $pvl_oid ) {
                        $poll_nrep_oid{$pvl_oid} = $oid;
                        $oid{$oid}{poll_oid}     = $pvl_oid;
                        $poll_nrep{$pvl_oid}     = undef;
                    }
                    else {
                        # TODO, Check for child and insert into deep_rep (if needed)
                        $pvl_oid                            = $oid =~ s/\.\d*$//r;           # we take the parent as previous lex
                        $poll_rep_oid{$pvl_oid}{start}      = $pvl_oid;
                        $poll_rep_oid{$pvl_oid}{oids}{$oid} = undef;
                        $poll_rep_oid{$pvl_oid}{cnt}        = 0;
                        if ( defined $data_in{snmp_retry}{$pvl_oid}{left_repetitions} ) {    #In case of Retry
                            $poll_rep_defined_mr{$pvl_oid} = $data_in{snmp_retry}{$pvl_oid}{left_repetitions};
                            $poll_rep_mr_defined{ $data_in{snmp_retry}{$pvl_oid}{left_repetitions} }{$pvl_oid} = undef;
                            $poll_rep_oid{$pvl_oid}{start}
                                = $pvl_oid . "." . $data_in{snmp_retry}{$pvl_oid}{start};    # a new start should be defined,
                        }
                        elsif ( defined $data_in{oids}{$pvl_oid}{max_repetitions} ) {        # Max repetion is set
                            $poll_rep_defined_mr{$pvl_oid} = $data_in{oids}{$pvl_oid}{max_repetitions};
                            $poll_rep_mr_defined{ $data_in{oids}{$pvl_oid}{max_repetitions} }{$pvl_oid}
                                = undef;                                                     # The reverse mapping
                            $poll_rep_oid{$pvl_oid}{start} = $pvl_oid . "." . $data_in{snmp_retry}{$pvl_oid}{start}
                                if defined $data_in{snmp_retry}{$pvl_oid}{start};
                        }
                        else {
                            $poll_rep_undefined_mr{$pvl_oid} = undef;
                        }
                    }
                }
            }
        }
        my @allrep_oids;
        @allrep_oids = keys %poll_rep_oid;
        my %deep_h;
        my @ret;

        #my $snmp_single_get_query_timeout = 2 + 2*$g{debug};
        #my $snmp_single_getbulk_query_timeout = 5 + 2*$g{debug};
        #my $agent_processing_time ;
        #my $agent_oid_processing_time ;
        #my $agent_max_oid_processing_time = 0.00001;
        #my $qrt; #Query Response Time
        #my $min_rtt = 0;  # Initialize min_rtt to an undefined value
        #my $start_time;
        # Discovery Stage
        if ($is_discover_cycle) {
            my $start_oid = "1.3.6.1";                      # Starting OID
            my $process   = 'Agent capability discovery';
            my $sub_process;
            my $task;
            if ( !$use_getnext ) {
                $sub_process = 'Test getbulk';

                # We are in SNMPv2 (SNMPv3 not supported by now)
                # Discovery Stage 1,2,3,4:
                if ( $discover_stage < 10 ) {    # 1,2,3 have to be grouped as they reuse the discoverd oids

                    # Test#1
                    # Try a huge query from the top of the tree
                    $data_out{oids}{snmp_input}{discover_stage} = 0;
                    $task = 'Test#1 oid=1.3.6.1 with max-repetition=1000';
                    my @ret1 = $session->getbulk_snmp( \%query_getbulk_params_disco, 0, 1000, $start_oid );
                    if ( !@ret1 || !grep { defined } @ret1 ) {
                        my $errors = $session->get_errors();    # Retrieve stored errors from session
                        if ( !@$errors ) {
                            $data_out{snmp_msg}{ ++$snmp_msg_count }
                                = build_snmp_log_message( undef, $process, $sub_process, $task );
                        }
                        for my $error (@$errors) {              # Loop through all errors
                            $data_out{snmp_msg}{ ++$snmp_msg_count }
                                = build_snmp_log_message( $error, $process, $sub_process, $task );
                            if ( $error->{code} == SNMPERR_TIMEOUT ) {    # Normally should not occurs...as tested by xymon
                                $data_out{snmp_errorstr} = $error->{message};
                                $data_out{snmp_errornum} = $error->{code};
                                send_data( $sock, \%data_out );
                                next DEVICE;
                            }
                        }
                        $use_getnext = 1;
                    }
                    else {
                        $max_getbulk_responses = scalar @ret1;                         # max_getbulk_responses is defined!
                        $data_out{oids}{snmp_input}{discover_stage} = 1;               # stage completed: 1

                        # Test#2
                        # The number of reapeter OID is normally equal than in the previous response:  exact same response is expected
                        $task = 'Test#2 getting max oids from previous answert with max-repetition=1';
                        my @oids;

                        # First, extract all OIDs from the answer
                        push @oids, $start_oid;
                        for my $entry (@ret1) {    # @ret1 is now an array of arrays (each entry contains [oid, val])
                            my $oid = $entry->[ 0 ];    # Extract the OID (first element of the sub-array)
                            push @oids, $oid;           # Store the extracted OID
                        }

                        # Remove the last element from @oids
                        pop @oids if @oids;                           # Ensures it only pops if @oids is not empty
                        my @ret2 = $session->getbulk_snmp( \%query_getbulk_params_disco, 0, 1, @oids );
                        if ( !@ret2 || !grep { defined } @ret2 ) {    # Ensure $result is an array reference and not empty
                            $use_getnext = 1;
                            my $errors = $session->get_errors();      # Retrieve stored errors from session
                            if ( !@$errors ) {
                                $data_out{snmp_msg}{ ++$snmp_msg_count }
                                    = build_snmp_log_message( undef, $process, $sub_process, $task );
                            }
                            for my $error (@$errors) {                # Loop through all errors
                                $data_out{snmp_msg}{ ++$snmp_msg_count }
                                    = build_snmp_log_message( $error, $process, $sub_process, $task );
                            }
                            $sgbmomr1    = 0;
                            $use_getnext = 1;
                        }
                        else {
                            $sgbmomr1              = 1;               #snmpgetbulk multiple oid with max-retitions=1 is supported
                            $max_getbulk_repeaters = scalar @ret2;    # max_getbulk_responses is defined!

                            # Test#3
                            # The 2 OIDis with max-repetition =2
                            $task = 'Test#3 2 OIDS with max-repetition=2';
                            $data_out{oids}{snmp_input}{discover_stage} = 2;                                       # stage completed: 2
                                # This time this is quick unlikely to timeout: for now we consider that as a read failure
                            @ret2
                                = $session->getbulk_snmp( \%query_getbulk_params_disco, 0, 2, $oids[ 0 ], $oids[ 1 ] );
                            if ( !@ret2 || !grep { defined } @ret2 ) {    # Ensure $result is an array reference and not empty
                                my $errors = $session->get_errors();
                                if ( not defined $errors or !@$errors ) {
                                    $data_out{snmp_msg}{ ++$snmp_msg_count }
                                        = build_snmp_log_message( undef, $process, $sub_process, $task );
                                }
                                for my $error (@$errors) {                # Loop through all errors
                                    $data_out{snmp_msg}{ ++$snmp_msg_count }
                                        = build_snmp_log_message( $error, $process, $sub_process, $task );
                                }
                                $sgbmomr2    = 0;
                                $use_getnext = 1;
                            }
                            else {
                                $sgbmomr2 = 1;                            #snmpgetbulk multiple oid with (at least) 2 repetitions
                            }
                        }
                        $data_out{oids}{snmp_input}{discover_stage} = 10;    # Initial discovery stage completed:
                    }    # Check
                }    # Store these discovery info for the non discovery cycles
                $data_out{oids}{snmp_input}{max_getbulk_responses} = $max_getbulk_responses;
                $data_out{oids}{snmp_input}{max_getbulk_repeaters} = $max_getbulk_repeaters;
                $data_out{oids}{snmp_input}{sgbmomr1}              = $sgbmomr1 if defined $sgbmomr1;
                $data_out{oids}{snmp_input}{sgbmomr2}              = $sgbmomr2 if defined $sgbmomr2;

                #                    $data_out{oids}{snmp_input}{sgbmomr100}            = $sgbmomr100 if defined $sgbmomr100;
                # TODO: We could insert those result in our deep_h, not to poll them again
            }
            if ($use_getnext) {
                my $sub_process = 'Test getnext';
                $task = 'Test#4 try a bigger and biggger query until it fails';
                my @current_oids    = ($start_oid);    # Current OIDs for the request
                my @discovered_oids = ();              # Store discovered OIDs

                # Discovery process using SNMP GETNEXT: Loop until a request fails
                while (1) {

                    # Prepare the current OID to query
                    my @oid_in_query = @current_oids;

                    # Perform SNMP GETNEXT request (using provided query params and OIDs)
                    my @ret = $session->getnext_snmp( \%query_getnext_params_disco, @oid_in_query );

                    # Check if the number of responses matches the number of OIDs queried
                    if ( @ret == @oid_in_query ) {
                        my $last_response = $ret[ -1 ];    # Get the last response from @ret
                        if ( $last_response && @$last_response ) {
                            my $next_oid = $last_response->[ 0 ];    # Get the next OID from the response
                            if ($next_oid) {

                                # Add the next OID to the discovered list and continue the process
                                push @discovered_oids, $next_oid;
                                push @current_oids,    $next_oid;    # Add next OID to the list for the next query
                            }
                            else {
                                # No next OID found (end of MIB or no more objects)
                                last;
                            }
                        }
                    }
                    else {
                        # If the size of @ret does not match @oid_in_query, stop the loop (request failed)
                        last;
                    }
                    if ( scalar @discovered_oids == 0 ) {
                        $data_out{snmp_msg}{ ++$snmp_msg_count }
                            = build_snmp_log_message( "SNMP_GETNEXT fails", $process, $sub_process, $task );
                        send_data( $sock, \%data_out );
                        next DEVICE;
                    }
                }
                $max_getnext_responses                             = @discovered_oids;
                $data_out{oids}{snmp_input}{max_getnext_responses} = $max_getnext_responses;
                $data_out{oids}{snmp_input}{discover_stage}        = 10;
                $data_out{oids}{snmp_input}{use_getnext}           = 1;
            }
        }
        @ret = ();
        my $has_timed_out = 0;
        $max_getbulk_responses //= 10;
        $max_getbulk_repeaters //= $max_getbulk_responses;
        $max_getnext_responses //= 10;
        @allrep_oids = keys %poll_rep_oid;
        my $default_max_repetitions = 1;
        my $default_snmp_bulk_query_cnt;
        $default_snmp_bulk_query_cnt
            = int( ( ( scalar @allrep_oids ) * $default_max_repetitions / $max_getbulk_responses ) + 0.5 );
        my $snmp_bulk_query_cnt = $default_snmp_bulk_query_cnt;
        my %poll_rep_as_nrepu;
        my %poll_rep_as_nrepd;
        my $end_of_mib_view_oid;
        my %poll_rep_defined_mr_initial = %poll_rep_defined_mr;    #find better name than initial
        my $nb_of_query                 = 0;
        my $snmpwalk_start_time         = time();

        # Optimize mode
        my $group_by_max_repetitions_by_col;                       # by repetear cnt (not really by col)
        my $group_by_max_repetitions_by_row;
        my $nreapeter_at_end;
        my $process;
        my $sub_process;
        my $task;

        # Only if we are a clean cycle
        if ($is_optim_cycle) {

            # Adjust modulo to start with 0 (1 first cycle do not count)
            $snmpwalk_mode                           = 0 if $current_cycle == 0;                           # The 0 cyc do not count (0 or 1)
            $snmpwalk_mode                           = ( $current_cycle - 1 ) % $nb_of_snmpwalk_mode;
            $data_out{snmp_msg}{ ++$snmp_msg_count } = "optim snmpwalk_mode:$snmpwalk_mode" if $g{trace};
        }
        elsif ( exists $data_in{stats}{snmptry_min_duration} && %{ $data_in{stats}{snmptry_min_duration} } ) {
            ($snmpwalk_mode) = sort { $data_in{stats}{snmptry_min_duration}{$a} <=> $data_in{stats}{snmptry_min_duration}{$b} }
                keys %{ $data_in{stats}{snmptry_min_duration} };
        }
        else {
            $snmpwalk_mode = 0;
        }
        if ( $snmpwalk_mode == 5 ) {
            $group_by_max_repetitions_by_col = 1;
            $group_by_max_repetitions_by_row = 0;
            $nreapeter_at_end                = 1;
        }
        elsif ( $snmpwalk_mode == 2 ) {
            $group_by_max_repetitions_by_col = 0;
            $group_by_max_repetitions_by_row = 1;
            $nreapeter_at_end                = 0;
        }
        elsif ( $snmpwalk_mode == 3 ) {
            $group_by_max_repetitions_by_col = 0;
            $group_by_max_repetitions_by_row = 1;
            $nreapeter_at_end                = 0;
        }
        elsif ( $snmpwalk_mode == 0 ) {

            # Not grouping by max repetition: Default discovery mode
            $group_by_max_repetitions_by_col = 0;
            $group_by_max_repetitions_by_row = 0;
            $nreapeter_at_end                = 0;
        }
        elsif ( $snmpwalk_mode == 4 ) {
            $group_by_max_repetitions_by_col = 0;
            $group_by_max_repetitions_by_row = 0;
            $nreapeter_at_end                = 1;
        }
        elsif ( $snmpwalk_mode == 1 ) {

            # Default mode: grouping by col as this correspond usually to an app in the device
            $group_by_max_repetitions_by_col = 1;
            $group_by_max_repetitions_by_row = 0;
            $nreapeter_at_end                = 0;
        }
        else {
            $data_out{snmp_msg}{ ++$snmp_msg_count } = "Err: undefined snmpwalk_mode";
        }
        exit if $group_by_max_repetitions_by_col and $group_by_max_repetitions_by_row;
        my $group_by_max_repetitions = ( $group_by_max_repetitions_by_col or $group_by_max_repetitions_by_row )
            ;    # optimization parameter (can be less optimized): TODO: Determine automatically for each device
    BULK_QUERY:
        while (
            (
                (
                      ( scalar keys %poll_rep_undefined_mr )
                    + ( scalar keys %poll_rep_defined_mr )
                    + ( scalar keys %poll_rep_as_nrepu )
                    + ( scalar keys %poll_rep_as_nrepd )
                    + ( scalar keys %poll_nrep )
                ) != 0
            )
            and ( not $has_timed_out )
            )
        {
            $nb_of_query++;
            my $ret_count = 0;
            my @parts     = ();
            my $i         = 0;

            # Calc the best max_repetitions that the agent can answer
            my $left_repeater_to_query = ( scalar keys %poll_rep_defined_mr ) + ( scalar keys %poll_rep_undefined_mr );
            my $free_repeater_in_query;
            my $free_nrepeater_in_query;
            my $max_repetitions_in_query;
            my $max_max_repetitions;
            my @oid_in_query;
            my $used_repeater_in_query  = 0;
            my $used_nrepeater_in_query = 0;
            my $max_repetitions_in_query_ww;
            my @nrep_in_query;
            my @rep_as_nrepu_in_query;
            my @rep_as_nrepd_in_query;
            my @rep_in_query;
            my %rep_def_mr_in_query;
            my %rep_undef_mr_in_query;

            if ($use_getnext) {
                $free_repeater_in_query   = 0;
                $free_nrepeater_in_query  = $max_getnext_responses;
                $max_repetitions_in_query = 1;                        # Could be zero
                if ( $g{trace} ) {
                    $data_out{snmp_msg}{ ++$snmp_msg_count }
                        = "Free rep:$free_repeater_in_query nrep:$free_nrepeater_in_query mr:$max_repetitions_in_query";
                    $data_out{snmp_msg}{ ++$snmp_msg_count }
                        = "Todo rep:0"
                        . " nrep:"
                        . ( ( scalar keys %poll_rep_undefined_mr )
                        + ( scalar keys %poll_rep_defined_mr )
                            + ( scalar keys %poll_rep_as_nrepu )
                            + ( scalar keys %poll_rep_as_nrepd )
                            + ( scalar keys %poll_nrep ) )
                        . " (rep[u|d]:0,0"
                        . " rnrep[u|d]:"
                        . ( scalar keys %poll_rep_undefined_mr ) . ","
                        . ( scalar keys %poll_rep_defined_mr )
                        . "|nrep:"
                        . ( scalar keys %poll_nrep ) . ")";
                }
                foreach my $oid ( oid_sort keys %poll_nrep ) {
                    last if $used_nrepeater_in_query == $free_nrepeater_in_query;
                    $used_nrepeater_in_query++;
                    push @nrep_in_query, $oid;
                }
                @oid_in_query = @nrep_in_query;

                # Insert the non repeaters that are in fact repeaters...
                foreach my $oid ( oid_sort keys %poll_rep_undefined_mr ) {

                    # the normal case
                    last if $used_nrepeater_in_query == $free_nrepeater_in_query;
                    $used_nrepeater_in_query++;
                    push @rep_as_nrepu_in_query, $oid;
                    push @oid_in_query,          $poll_rep_oid{$oid}{start};
                }
                foreach my $oid ( oid_sort keys %poll_rep_defined_mr ) {
                    last if $used_nrepeater_in_query == $free_nrepeater_in_query;
                    $used_nrepeater_in_query++;
                    push @rep_as_nrepd_in_query, $oid;
                    push @oid_in_query,          $poll_rep_oid{$oid}{start};
                }
                if ( $g{trace} ) {
                    $data_out{snmp_msg}{ ++$snmp_msg_count }
                        = "Used rep:0"
                        . " nrep:"
                        . $used_nrepeater_in_query
                        . " (rep:0"
                        . " nrep:"
                        . ( ( scalar keys %poll_nrep ) + ( scalar keys %poll_rep_undefined_mr ) + ( scalar keys %poll_rep_defined_mr ) )
                        . ")";
                }
            }
            else {
                if ( $max_getbulk_repeaters > $max_getbulk_responses ) {
                    $max_getbulk_repeaters = $max_getbulk_responses;
                }
                if ( scalar keys %poll_rep_undefined_mr ) {

                    # Start to discover oid that dont have the max-repetition set yet (discovery phase)
                    if ( $left_repeater_to_query < $max_getbulk_repeaters ) {
                        $free_repeater_in_query = $left_repeater_to_query;
                        $max_repetitions_in_query
                            = ( $free_repeater_in_query == 0 )
                            ? 0
                            : int( $max_getbulk_responses / $free_repeater_in_query );
                        if ($nreapeter_at_end) {
                            $free_nrepeater_in_query = 0;
                        }
                        else {
                            $free_nrepeater_in_query = $max_getbulk_responses - $max_repetitions_in_query * $free_repeater_in_query;
                            $free_nrepeater_in_query = $max_getbulk_repeaters - $free_repeater_in_query
                                if ( $free_repeater_in_query + $free_nrepeater_in_query ) > $max_getbulk_repeaters;
                        }
                    }
                    else {
                        $free_repeater_in_query   = $max_getbulk_repeaters;
                        $free_nrepeater_in_query  = 0;
                        $max_repetitions_in_query = int( $max_getbulk_responses / $free_repeater_in_query );

                #$max_repetitions_in_query = ( $free_repeater_in_query == 0 ) ? 0 : int( $max_getbulk_responses / $free_repeater_in_query );
                    }
                }
                elsif ( scalar keys %poll_rep_defined_mr ) {

                    # All oid with undefined mr are discover let's do the same with oid with mr defined
                    # First calc the max of all max-repetition to regroup all oids that have the same mr
                    $max_max_repetitions = ( sort { $a <=> $b } ( keys %poll_rep_mr_defined ) )[ -1 ];
                    my $max_max_repetitions_nb_of_query = scalar keys %{ $poll_rep_mr_defined{$max_max_repetitions} };

                    # not any grouping, same as oid with undefined mr
                    if ( not $group_by_max_repetitions ) {
                        if ( $left_repeater_to_query < $max_getbulk_repeaters ) {
                            $free_repeater_in_query = $left_repeater_to_query;
                            $max_repetitions_in_query
                                = ( $free_repeater_in_query == 0 )
                                ? 0
                                : int( $max_getbulk_responses / $free_repeater_in_query );
                            if ($nreapeter_at_end) {
                                $free_nrepeater_in_query = 0;
                            }
                            else {
                                $free_nrepeater_in_query = $max_getbulk_responses - $max_repetitions_in_query * $free_repeater_in_query;
                                $free_nrepeater_in_query = $max_getbulk_repeaters - $free_repeater_in_query
                                    if ( $free_repeater_in_query + $free_nrepeater_in_query ) > $max_getbulk_repeaters;
                            }
                        }
                        else {
                            $free_repeater_in_query  = $max_getbulk_repeaters;
                            $free_nrepeater_in_query = 0;

                #$max_repetitions_in_query = ( $free_repeater_in_query == 0 ) ? 0 : int( $max_getbulk_responses / $free_repeater_in_query );
                            $max_repetitions_in_query = int( $max_getbulk_responses / $free_repeater_in_query );
                        }
                    }
                    elsif ($group_by_max_repetitions_by_col) {
                        $max_repetitions_in_query
                            = $max_max_repetitions < $max_getbulk_responses
                            ? $max_max_repetitions
                            : $max_getbulk_responses;

                  #$free_repeater_in_query = ( $free_repeater_in_query == 0 ) ? 0 : int( $max_getbulk_responses / $free_repeater_in_query );
                        $free_repeater_in_query = int( $max_getbulk_responses / $max_repetitions_in_query );
                        $free_repeater_in_query
                            = $free_repeater_in_query > $max_getbulk_repeaters
                            ? $max_getbulk_repeaters
                            : $free_repeater_in_query;
                        if ($nreapeter_at_end) {
                            $free_nrepeater_in_query = 0;
                        }
                        else {
                            $free_nrepeater_in_query = $max_getbulk_responses - $max_repetitions_in_query * $free_repeater_in_query;
                            $free_nrepeater_in_query = $max_getbulk_repeaters - $free_repeater_in_query
                                if ( $free_repeater_in_query + $free_nrepeater_in_query ) > $max_getbulk_repeaters;
                        }
                    }
                    else {    # group_by_max_repetitions_by_row
                        $free_repeater_in_query
                            = $max_max_repetitions_nb_of_query > $max_getbulk_repeaters
                            ? $max_getbulk_repeaters
                            : $max_max_repetitions_nb_of_query;

#$max_repetitions_in_query = ( $free_repeater_in_query == 0 )                          ? 0                      : int( $max_getbulk_responses / $free_repeater_in_query );
                        $max_repetitions_in_query = int( $max_getbulk_responses / $free_repeater_in_query );
                        if ($nreapeter_at_end) {
                            $free_nrepeater_in_query = 0;
                        }
                        else {
                            $free_nrepeater_in_query = $max_getbulk_responses - $max_repetitions_in_query * $free_repeater_in_query;
                            $free_nrepeater_in_query = $max_getbulk_repeaters - $free_repeater_in_query
                                if ( $free_repeater_in_query + $free_nrepeater_in_query ) > $max_getbulk_repeaters;
                        }
                    }
                    $max_repetitions_in_query = $max_max_repetitions
                        if $max_max_repetitions < $max_repetitions_in_query;
                }
                else {
                    $free_repeater_in_query   = 0;
                    $free_nrepeater_in_query  = $max_getbulk_repeaters;
                    $max_repetitions_in_query = 0;
                }
                if ( $g{trace} ) {
                    $data_out{snmp_msg}{ ++$snmp_msg_count }
                        = "Free rep:$free_repeater_in_query nrep:$free_nrepeater_in_query mr:$max_repetitions_in_query";
                    $data_out{snmp_msg}{ ++$snmp_msg_count }
                        = "Todo rep:"
                        . ( ( scalar keys %poll_rep_undefined_mr ) + ( scalar keys %poll_rep_defined_mr ) )
                        . " nrep:"
                        . ( ( scalar keys %poll_rep_as_nrepu ) + ( scalar keys %poll_rep_as_nrepd ) + ( scalar keys %poll_nrep ) )
                        . " (rep[u|d]:"
                        . ( scalar keys %poll_rep_undefined_mr ) . ","
                        . ( scalar keys %poll_rep_defined_mr )
                        . " rnrep[u|d]:"
                        . ( scalar keys %poll_rep_as_nrepu ) . ","
                        . ( scalar keys %poll_rep_as_nrepd )
                        . "|nrep:"
                        . ( scalar keys %poll_nrep ) . ")";
                }

                # Create the query
                # First insert non repeaters
                # The 'normal' non repeaters
                foreach my $oid ( oid_sort keys %poll_nrep ) {
                    last if $used_nrepeater_in_query == $free_nrepeater_in_query;
                    $used_nrepeater_in_query++;
                    push @nrep_in_query, $oid;
                }
                @oid_in_query = @nrep_in_query;

                # Insert the non repeaters that are in fact repeaters...
                foreach my $oid ( oid_sort keys %poll_rep_as_nrepu ) {
                    last if $used_nrepeater_in_query == $free_nrepeater_in_query;
                    $used_nrepeater_in_query++;
                    push @rep_as_nrepu_in_query, $oid;
                    push @oid_in_query,          $poll_rep_oid{$oid}{start};
                }
                foreach my $oid ( oid_sort keys %poll_rep_as_nrepd ) {
                    last if $used_nrepeater_in_query == $free_nrepeater_in_query;
                    $used_nrepeater_in_query++;
                    push @rep_as_nrepd_in_query, $oid;
                    push @oid_in_query,          $poll_rep_oid{$oid}{start};
                }

                # Add now the reperaters
                my @rep_in_query;
                for my $oid ( oid_sort( keys %poll_rep_undefined_mr ) ) {
                    last if $used_repeater_in_query == $free_repeater_in_query;
                    $used_repeater_in_query++;
                    $rep_undef_mr_in_query{$oid} = undef;
                }
                if ( defined $max_max_repetitions and $group_by_max_repetitions ) {
                    for my $oid ( oid_sort( keys %{ $poll_rep_mr_defined{$max_max_repetitions} } ) ) {
                        last if $used_repeater_in_query == $free_repeater_in_query;
                        $used_repeater_in_query++;
                        $rep_def_mr_in_query{$oid} = undef;
                    }
                }
                else {
                    for my $oid ( oid_sort( keys %poll_rep_defined_mr ) ) {
                        last if $used_repeater_in_query == $free_repeater_in_query;
                        $used_repeater_in_query++;
                        $rep_def_mr_in_query{$oid} = undef;
                    }
                }
                @rep_in_query = oid_sort( keys %rep_undef_mr_in_query, keys %rep_def_mr_in_query );
                my @start_oid;
                for my $oid (@rep_in_query) {
                    push @start_oid, $poll_rep_oid{$oid}{start};
                }
                push @oid_in_query, @start_oid;
                $max_repetitions_in_query_ww = $max_repetitions_in_query;
                if ( $g{trace} ) {
                    $data_out{snmp_msg}{ ++$snmp_msg_count }
                        = "Used rep:"
                        . $used_repeater_in_query
                        . " nrep:"
                        . $used_nrepeater_in_query
                        . " (rep:"
                        . ( ( scalar keys %poll_rep_undefined_mr ) + ( scalar keys %poll_rep_defined_mr ) )
                        . " nrep:"
                        . ( scalar keys %poll_nrep ) . ")";
                }
            }
            my @ret;
            my $snmp_try_start_time = time();
            my $query_timeout       = $snmp_try_deadline - $snmp_try_start_time;
            if ( $query_timeout < 0.3 ) {
                $has_timed_out = 1;
                $data_out{snmp_msg}{ ++$snmp_msg_count } = "Try deadline reached: slow answer from device" if $g{debug};
                last BULK_QUERY;
            }
            last BULK_QUERY if not scalar(@oid_in_query);
            my $expected_response_count;
            if ($use_getnext) {
                $process                 = 'Polling with getnext';
                $expected_response_count = @oid_in_query;
                @ret                     = $session->getnext_snmp( \%query_getnext_params, @oid_in_query );
            }
            else {
                $process = 'Polling with getbulk';

                #$sub_process;
                #$task;
                $query_timeout = $snmp_getbulk_timeout if $query_timeout > $snmp_getbulk_timeout;
                $expected_response_count
                    = ( scalar(@oid_in_query) - $used_nrepeater_in_query ) * $max_repetitions_in_query_ww + $used_nrepeater_in_query;
                @ret = $session->getbulk_snmp( \%query_getbulk_params, $used_nrepeater_in_query,
                    $max_repetitions_in_query_ww, @oid_in_query );
            }
            my $snmpquery_timestamp = time();
            my $response_count      = scalar @ret + scalar @{ $session->{varbind_errors} };
            if ( $response_count != $expected_response_count ) {
                if ( $snmp_ver == 1 ) {
                    my @oidval = $session->get_varbind_errors();
                    if ( @oidval and @{ $oidval[ 0 ] } ) {
                        my $oid = $oidval[ 0 ][ 0 ];
                        my $val = $oidval[ 0 ][ 1 ];
                        $data_out{oids}{snmp_input}{oids}{$oid}{nosuchobject} = undef;
                    }
                }
                my $errors = $session->get_errors();
                for my $error (@$errors) {    # Loop through all errors
                    $data_out{snmp_msg}{ ++$snmp_msg_count }
                        = build_snmp_log_message( $error, $process, $sub_process, $task );
                    if ( defined $error->{code} && $error->{code} == SNMPERR_TIMEOUT ) {   # Normally should not occurs...as tested by xymon
                        $has_timed_out = 1;
                        last BULK_QUERY;
                    }
                }
                if ($use_getnext) {
                    if ( $response_count eq 0 ) {
                        my $message = "Empty getnext responses (=0)";
                        $data_out{snmp_msg}{ ++$snmp_msg_count }
                            = build_snmp_log_message( undef, $process, $sub_process, $task, $message );
                        last BULK_QUERY;
                    }
                    elsif ( $response_count < $expected_response_count ) {
                        my $message = "Decreasing max_getnext_responses from $max_getnext_responses to $response_count";
                        $data_out{snmp_msg}{ ++$snmp_msg_count }
                            = build_snmp_log_message( undef, $process, $sub_process, $task, $message );
                        $max_getnext_responses = $response_count;
                        $data_out{oids}{snmp_input}{max_getnext_responses} = $response_count;
                    }
                    else {
                        my $message = "More getnext responses:$response_count than expected $expected_response_count";
                        $data_out{snmp_msg}{ ++$snmp_msg_count }
                            = build_snmp_log_message( undef, $process, $sub_process, $task, $message );
                    }
                }
                else {
                    if ( $response_count eq 0 ) {
                        my $message = "Empty getbulk responses (=0)";
                        $data_out{snmp_msg}{ ++$snmp_msg_count }
                            = build_snmp_log_message( undef, $process, $sub_process, $task, $message );
                        last BULK_QUERY;
                    }
                    elsif ( $response_count < $expected_response_count ) {
                        my $message = "Decreasing max_getbulk_responses from $max_getbulk_responses to $response_count";
                        $data_out{snmp_msg}{ ++$snmp_msg_count }
                            = build_snmp_log_message( undef, $process, $sub_process, $task, $message );
                        $max_getbulk_responses = $response_count;
                        $data_out{oids}{snmp_input}{max_getbulk_responses} = $response_count;
                    }
                    else {
                        my $message = "More getbulk responses:$response_count than expected $expected_response_count";
                        $data_out{snmp_msg}{ ++$snmp_msg_count }
                            = build_snmp_log_message( undef, $process, $sub_process, $task, $message );
                    }
                }
            }

            #if ( $SNMP_Session::errmsg ne '' ) {
            #    if ( $SNMP_Session::errmsg eq 'Exception code: endOfMibView' ) {
            #        my @filter_ret;
            #        for my $oidval (@ret) {
            #            my $i   = index( $oidval, ":" );
            #            my $oid = substr( $oidval, 0, $i );
            #            my $val = substr( $oidval, $i + 1 );
            #            if ( $val eq 'endOfMibView' ) {
            #                if ( not defined $end_of_mib_view_oid ) {
            #                    $end_of_mib_view_oid = $oid;
            #                }
            #                elsif ( $oid ne $end_of_mib_view_oid ) {
            #                    print "error";
            #                }
            #            }
            #            else {
            #                push @filter_ret, $oidval;
            #            }
            #        }
            #        @ret = @filter_ret;
            #    }
            #    elsif ( $SNMP_Session::errmsg =~ /no response received/ ) {
            #        $has_timed_out        = 1;
            #        $SNMP_Session::errmsg = '';
            #        last BULK_QUERY;
            #    }
            #    else {
            #        $data_out{snmp_msg}{ ++$snmp_msg_count } = "SNMP error:" . $SNMP_Session::errmsg;
            #        $SNMP_Session::errmsg = '';
            #    }
            #}
            for my $oidval (@ret) {
                deeph_insert_oidval_h( $oidval, \%deep_h );
            }
            for my $poid (@nrep_in_query) {
                my $oid       = $poid . ".0";
                my $nonrepval = deeph_find_leaf( $oid, \%deep_h );
                if ( not defined $nonrepval ) {
                    $data_out{oids}{snmp_input}{oids}{$oid}{nosuchobject} = undef;
                    $data_out{snmp_msg}{ ++$snmp_msg_count } = "$oid = No1 Such Object available on this agent at this OID";
                }
                delete $poll_nrep{$poid};
            }
            for my $oid (@rep_as_nrepu_in_query) {
                my %branch_hml = deeph_find_branch_h( $oid, \%deep_h );
                my %branch_h   = deeph_flatten_h( \%branch_hml );
                my $branch_cnt = scalar keys %branch_h;
                if ( ( $branch_cnt - $poll_rep_oid{$oid}{cnt} ) != 0 ) {

                    # We have some answer: this mean that max-repetition was not honor or that we have new entries (todo)
                    # -> we re-add it to a normal undef mr repeater as we have may be a lot of value
                    $poll_rep_undefined_mr{$oid} = undef;
                    my $new_start = $branch_cnt ? $oid . "." . ( ( oid_sort( keys %branch_h ) )[ -1 ] ) : $oid;
                    if ( $poll_rep_oid{$oid}{start} ne $new_start ) {
                        $poll_rep_oid{$oid}{start} = $new_start;
                    }
                    elsif ($use_getnext) {
                        delete $poll_rep_undefined_mr{$oid};    # if $use_getnext;
                        $poll_rep_oid{$oid}{cnt} = $branch_cnt;
                    }
                }
                else {
                    # No answer, we reach the end of the oid mib: check now that all children oid did have an answer or notify
                    for my $coid ( keys %{ $poll_rep_oid{$oid}{oids} } ) {    #eksf
                        if ( $oid eq $poll_rep_oid{$oid}{start} ) {
                            $data_out{oids}{snmp_input}{oids}{$coid}{nosuchobject} = undef;
                            $data_out{snmp_msg}{ ++$snmp_msg_count } = "$coid = No2 Such Object available on this agent at this OID";
                            if ($use_getnext) {
                                delete $poll_rep_undefined_mr{$coid};
                            }
                        }
                    }
                    if (   !$branch_cnt
                        and $is_try1
                        and not exists $data_out{oids}{snmp_input}{oids}{$oid}{nosuchobject} )
                    {
                        $data_out{oids}{snmp_input}{oids}{$oid}{nosuchobject} = undef;
                        $data_out{snmp_msg}{ ++$snmp_msg_count } = "$oid = No3 Such Object available on this agent at this OID";
                    }
                }

                # As it was rebalance to normal oid or it was the end of its polling, we have delete this oid
                delete $poll_rep_as_nrepu{$oid};
            }
            for my $oid (@rep_as_nrepd_in_query) {

               # This is a final check for an oid as we have the max-repetition, we just try to see if there are new entries, but one by one
                my %branch_hml = deeph_find_branch_h( $oid, \%deep_h );
                my %branch_h   = deeph_flatten_h( \%branch_hml );
                my $branch_cnt;
                my @branch_keys_sorted;
                my $branch_keys_is_not_sorted = 1;
                if ( defined $data_in{snmp_retry}{$oid}{start} ) {
                    @branch_keys_sorted        = oid_sort( keys %branch_h );
                    $branch_keys_is_not_sorted = 0;
                    my $idx = bigger_elem_idx( \@branch_keys_sorted, $data_in{snmp_retry}{$oid}{start} );
                    if ( not defined $idx ) {    # The start oid is not found, so there are some leaf, but not the one we are looking for
                                                 #$branch_cnt = 0;
                        $branch_cnt = scalar keys %branch_h;
                    }
                    else {
                        $branch_cnt = ( scalar keys %branch_h ) - $idx;
                    }
                }
                else {
                    $branch_cnt = scalar keys %branch_h;
                }
                if ( ( $branch_cnt - $poll_rep_oid{$oid}{cnt} ) != 0 ) {

                    # The new entries count
                    my $new_poll_rep_defined_mr = $poll_rep_defined_mr_initial{$oid} - $branch_cnt;

                    # We have at least 1 new entry
                    if ( $new_poll_rep_defined_mr > 0 ) {

                        # 1 or more repetition are missing, rebalance to normal defined mr oid
                        delete $poll_rep_as_nrepd{$oid};
                        $poll_rep_defined_mr{$oid}                           = $new_poll_rep_defined_mr;
                        $poll_rep_mr_defined{$new_poll_rep_defined_mr}{$oid} = undef;
                        @branch_keys_sorted                                  = oid_sort( keys %branch_h ) if $branch_keys_is_not_sorted;

                        #$poll_rep_oid{$oid}{start}                           = $oid . "." . $branch_keys_sorted[ -1 ];
                        my $new_start = $oid . "." . $branch_keys_sorted[ -1 ];
                        if ( $poll_rep_oid{$oid}{start} ne $new_start ) {
                            $poll_rep_oid{$oid}{start} = $new_start;
                        }
                        elsif ($use_getnext) {
                            delete $poll_rep_defined_mr{$oid};    # if $use_getnext;
                            $poll_rep_oid{$oid}{cnt} = $branch_cnt;
                        }
                    }
                    else {
                        @branch_keys_sorted = oid_sort( keys %branch_h ) if $branch_keys_is_not_sorted;

                        # we have all repetition, but check for 1 new one, so just ask for a new nrep
                        $poll_rep_oid{$oid}{start} = $oid . "." . $branch_keys_sorted[ -1 ];
                    }
                    $poll_rep_oid{$oid}{cnt} = $branch_cnt;
                }
                else {
                    # no new entrie: this is end of the mib: done for this oid
                    delete $poll_rep_as_nrepd{$oid};
                    delete $poll_rep_defined_mr{$oid};

                    # Check if some oid did not have an answer, as we have to remove them
                    for my $coid ( keys %{ $poll_rep_oid{$oid}{oids} } ) {    #eksf
                        if ( $oid eq $poll_rep_oid{$oid}{start} ) {
                            $data_out{oids}{snmp_input}{oids}{$coid}{nosuchobject} = undef;
                            $data_out{snmp_msg}{ ++$snmp_msg_count } = "$coid = No4 Such Object available on this agent at this OID";
                        }
                    }
                    if ( !$branch_cnt and $is_try1 ) {                        # $branch_cnt =0 and $poll_rep_oid{$oid}{cnt} = 0
                        $data_out{oids}{snmp_input}{oids}{$oid}{nosuchobject} = undef;
                        $data_out{snmp_msg}{ ++$snmp_msg_count } = "$oid = No5 Such Object available on this agent at this OID";
                    }
                }
            }
            for my $oid ( keys %rep_undef_mr_in_query ) {
                my %branch_hml = deeph_find_branch_h( $oid, \%deep_h );
                my %branch_h   = deeph_flatten_h( \%branch_hml );
                my $branch_cnt = scalar keys %branch_h;

                #print "not defined cnt for $oid"       if ( not defined $branch_cnt );
                #print "not defined start cnt for $oid" if ( not defined $poll_rep_oid{$oid}{cnt} );
                my $current_query_branch_cnt = $branch_cnt - $poll_rep_oid{$oid}{cnt};
                if ( defined $end_of_mib_view_oid and $poll_rep_oid{$oid}{start} eq $end_of_mib_view_oid ) {

                    #we reach the end of the last oid, very rare case...
                    delete $poll_rep_undefined_mr{$oid};
                    next;
                }
                my @branch_keys_sorted = oid_sort( keys %branch_h );
                my $idx;
                if ( defined $data_in{snmp_retry}{$oid}{start} ) {
                    $idx = bigger_elem_idx( \@branch_keys_sorted, $data_in{snmp_retry}{$oid}{start} );
                    next
                        if not defined $idx;    # The start oid is not found, so there are some leaf, but not the one we are looking for
                                                #++$idx;
                }
                else {
                    $idx = 0;
                }

                #print "$current_query_branch_cnt $idx $max_repetitions_in_query\n";
                if ( $current_query_branch_cnt - $idx < $max_repetitions_in_query ) {

                    # Some agent dont honor max repetition for some oid so we have to confirm we got all
                    # We will try to get next value as a nrep to optimze the pooling.
                    # Case#1: They give 1 answer but not all
                    # Case#2: They do not support max-repetition completly
                    delete $poll_rep_undefined_mr{$oid};
                    if ( $current_query_branch_cnt - $idx != 0 ) {
                        $poll_rep_oid{$oid}{start}
                            = $branch_cnt ? $oid . "." . ( ( oid_sort( keys %branch_h ) )[ -1 ] ) : $oid;
                        $poll_rep_as_nrepu{$oid} = undef;
                    }
                    else {
                        $poll_rep_as_nrepu{$oid} = undef;
                    }
                }
                else {
                    $poll_rep_oid{$oid}{start} = $oid . "." . ( ( oid_sort( keys %branch_h ) )[ -1 ] );
                }
                $poll_rep_oid{$oid}{cnt} = $branch_cnt;
            }
            for my $oid ( keys %rep_def_mr_in_query ) {
                my %branch_hml = deeph_find_branch_h( $oid, \%deep_h );
                my %branch_h   = deeph_flatten_h( \%branch_hml );
                if ( defined $end_of_mib_view_oid and $poll_rep_oid{$oid}{start} eq $end_of_mib_view_oid ) {
                    delete $poll_rep_mr_defined{ $poll_rep_defined_mr{$oid} }{$oid};
                    delete $poll_rep_mr_defined{ $poll_rep_defined_mr{$oid} }
                        if not %{ $poll_rep_mr_defined{ $poll_rep_defined_mr{$oid} } };
                    next;
                }
                my $branch_cnt;
                my @branch_keys_sorted;
                my $branch_keys_is_not_sorted = 1;
                if ( defined $data_in{snmp_retry}{$oid}{start} ) {
                    @branch_keys_sorted        = oid_sort( keys %branch_h );
                    $branch_keys_is_not_sorted = 0;
                    my $idx = bigger_elem_idx( \@branch_keys_sorted, $data_in{snmp_retry}{$oid}{start} );
                    if ( not defined $idx ) {    # The start oid is not found, so there are some leaf, but not the one we are looking for
                                                 # $branch_cnt = 0;
                        $branch_cnt = scalar keys %branch_h;
                    }
                    else {
                        $branch_cnt = ( scalar keys %branch_h ) - $idx;
                    }
                }
                else {
                    $branch_cnt = scalar keys %branch_h;
                }
                my $current_query_branch_cnt = $branch_cnt - $poll_rep_oid{$oid}{cnt};
                if ( $branch_cnt >= $poll_rep_defined_mr_initial{$oid} ) {
                    delete $poll_rep_mr_defined{ $poll_rep_defined_mr{$oid} }{$oid};
                    delete $poll_rep_mr_defined{ $poll_rep_defined_mr{$oid} }
                        if not %{ $poll_rep_mr_defined{ $poll_rep_defined_mr{$oid} } };
                    delete $poll_rep_defined_mr{$oid};
                    @branch_keys_sorted        = oid_sort( keys %branch_h ) if $branch_keys_is_not_sorted;
                    $poll_rep_oid{$oid}{start} = $branch_cnt ? $oid . "." . $branch_keys_sorted[ -1 ] : $oid;
                    $poll_rep_as_nrepd{$oid}   = undef;
                }
                elsif ( $current_query_branch_cnt < $max_repetitions_in_query ) {
                    if ( $current_query_branch_cnt != 0 ) {
                        @branch_keys_sorted = oid_sort( keys %branch_h ) if $branch_keys_is_not_sorted;
                        $poll_rep_oid{$oid}{start} = $oid . "." . $branch_keys_sorted[ -1 ];
                        delete $poll_rep_mr_defined{ $poll_rep_defined_mr{$oid} }{$oid};
                        delete $poll_rep_mr_defined{ $poll_rep_defined_mr{$oid} }
                            if not %{ $poll_rep_mr_defined{ $poll_rep_defined_mr{$oid} } };
                        my $new_poll_rep_defined_mr = $poll_rep_defined_mr_initial{$oid} - $branch_cnt;
                        $poll_rep_defined_mr{$oid} = $new_poll_rep_defined_mr;
                        $poll_rep_mr_defined{$new_poll_rep_defined_mr}{$oid} = undef;
                    }
                    else {
                        # $current_query_branch_cnt = 0
                        delete $poll_rep_mr_defined{ $poll_rep_defined_mr{$oid} }{$oid};
                        delete $poll_rep_mr_defined{ $poll_rep_defined_mr{$oid} }
                            if not %{ $poll_rep_mr_defined{ $poll_rep_defined_mr{$oid} } };
                        delete $poll_rep_defined_mr{$oid};
                        $poll_rep_as_nrepd{$oid} = undef;
                    }
                }
                else {
                    delete $poll_rep_mr_defined{ $poll_rep_defined_mr{$oid} }{$oid};
                    delete $poll_rep_mr_defined{ $poll_rep_defined_mr{$oid} }
                        if not %{ $poll_rep_mr_defined{ $poll_rep_defined_mr{$oid} } };
                    my $new_poll_rep_defined_mr = $poll_rep_defined_mr_initial{$oid} - $branch_cnt;
                    $poll_rep_defined_mr{$oid}                           = $new_poll_rep_defined_mr;
                    $poll_rep_mr_defined{$new_poll_rep_defined_mr}{$oid} = undef;
                    @branch_keys_sorted                                  = oid_sort( keys %branch_h ) if $branch_keys_is_not_sorted;
                    $poll_rep_oid{$oid}{start}                           = $oid . "." . $branch_keys_sorted[ -1 ];
                }
                $poll_rep_oid{$oid}{cnt} = $branch_cnt;
            }
            for my $oid ( keys %nrep ) {
                my $nonrepval = deeph_find_leaf( $oid, \%deep_h );
                if ( ( defined $nonrepval ) and ( not defined $data_out{oids}{snmp_polled}{$oid}{time} ) ) {
                    $data_out{oids}{snmp_polled}{$oid}{val}  = $nonrepval;
                    $data_out{oids}{snmp_polled}{$oid}{time} = $snmpquery_timestamp;
                }
            }
            for my $oid ( keys %rep ) {
                my %branch_hml = deeph_find_branch_h( $oid, \%deep_h );
                my %branch_h   = deeph_flatten_h( \%branch_hml );
                if (%branch_h) {
                    for my $leaf ( keys %branch_h ) {
                        if ( not defined $data_out{oids}{snmp_polled}{$oid}{$leaf}{time} ) {
                            $data_out{oids}{snmp_polled}{$oid}{$leaf}{val}  = $branch_h{$leaf};
                            $data_out{oids}{snmp_polled}{$oid}{$leaf}{time} = $snmpquery_timestamp;
                        }
                    }
                }
            }
        }

        # For unfinished rep oid polling, we need to keep track of the last oid polled
        # and the current count
        if ($has_timed_out) {
            $data_out{snmp_errorstr} = "Timeout";
            $data_out{snmp_errornum} = SNMPERR_TIMEOUT;
            for my $oid (@allrep_oids) {
                my %branch_hml = deeph_find_branch_h( $oid, \%deep_h );
                my %branch_h   = deeph_flatten_h( \%branch_hml );
                if ( scalar %branch_h and defined $poll_rep_defined_mr_initial{$oid} ) {
                    my @branch_key_sorted = oid_sort( keys %branch_h );
                    $data_out{oids}{snmp_retry}{$oid}{start} = $branch_key_sorted[ -1 ];
                    if ( defined $data_in{snmp_retry}{$oid}{left_repetitions} ) {
                        my $idx = bigger_elem_idx( \@branch_key_sorted, $data_in{snmp_retry}{$oid}{start} );
                        if ( defined $idx ) {
                            $data_out{oids}{snmp_retry}{$oid}{left_repetitions}
                                = $data_in{snmp_retry}{$oid}{left_repetitions} - ( scalar keys %branch_h ) + $idx;
                            delete $data_out{oids}{snmp_retry}{$oid}
                                if $data_out{oids}{snmp_retry}{$oid}{left_repetitions} <= 0;
                        }
                        else {
                            $data_out{oids}{snmp_retry}{$oid}{left_repetitions}
                                = $data_in{snmp_retry}{$oid}{left_repetitions};
                            $data_out{oids}{snmp_retry}{$oid}{start} = $data_in{snmp_retry}{$oid}{start};
                        }
                    }
                    else {
                        $data_out{oids}{snmp_retry}{$oid}{left_repetitions}
                            = ( $poll_rep_defined_mr_initial{$oid} - ( scalar keys %branch_h ) );
                        delete $data_out{oids}{snmp_retry}{$oid}
                            if $data_out{oids}{snmp_retry}{$oid}{left_repetitions} <= 0;
                    }
                }
                elsif ( defined $data_in{snmp_retry}{$oid}{start} ) {
                    $data_out{oids}{snmp_retry}{$oid}{start}            = $data_in{snmp_retry}{$oid}{start};
                    $data_out{oids}{snmp_retry}{$oid}{left_repetitions} = $data_in{snmp_retry}{$oid}{left_repetitions}
                        if defined $data_in{snmp_retry}{$oid}{left_repetitions};
                }    # no else as if branch if empty this will be detected later
            }
        }
        else {
            # The snmp query is finished
            $data_out{oids}{snmp_input}{stats}{snmptry_cur_duration} = time() - $snmpwalk_start_time;
            if ($is_try1) {

                # Slowly increase the min duration by 0.01 sec
                $data_out{oids}{snmp_input}{stats}{snmptry_min_duration}{$snmpwalk_mode} += 0.05
                    if exists $data_out{oids}{snmp_input}{stats}{snmptry_min_duration}{$snmpwalk_mode};

                # As sucessfull at it first try (just the normal case), this smnp polling can be a reference for the optimisation algo
                if ($is_optim_cycle) {
                    if (
                        ( not defined $data_out{oids}{snmp_input}{stats}{snmptry_min_duration}{$snmpwalk_mode} )
                        or ( $data_out{oids}{snmp_input}{stats}{snmptry_min_duration}{$snmpwalk_mode}
                            > $data_out{oids}{snmp_input}{stats}{snmptry_cur_duration} )
                        )
                    {
                        $data_out{oids}{snmp_input}{stats}{snmptry_min_duration}{$snmpwalk_mode}
                            = $data_out{oids}{snmp_input}{stats}{snmptry_cur_duration};
                    }
                    my @sorted_values
                        = sort { $a <=> $b } values %{ $data_out{oids}{snmp_input}{stats}{snmptry_min_duration} };
                    $data_out{oids}{snmp_input}{snmp_try_timeout} = $sorted_values[ 2 ] // $sorted_values[ 1 ] // $sorted_values[ 0 ];
                    $data_out{oids}{snmp_input}{snmp_try_timeout} *= 2.5;

                    # minimum 5 sec
                    if ( $data_out{oids}{snmp_input}{snmp_try_timeout} < 5 ) {
                        $data_out{oids}{snmp_input}{snmp_try_timeout} = 5;

                        # max global timeout
                    }
                    elsif ( $data_out{oids}{snmp_input}{snmp_try_timeout} > $g{maxpolltime} ) {
                        $data_out{oids}{snmp_input}{snmp_try_timeout} = $g{maxpolltime};
                    }
                }

                # Successfull Cycle in 1 try only
                if ( $data_out{oids}{snmp_input}{stats}{snmptry_cur_duration}
                    < $data_out{oids}{snmp_input}{stats}{snmptry_min_duration}{$snmpwalk_mode} )
                {
                    $data_out{oids}{snmp_input}{stats}{snmptry_min_duration}{$snmpwalk_mode}
                        = $data_out{oids}{snmp_input}{stats}{snmptry_cur_duration};
                }
            }
            $data_out{snmp_errornum} = 0;
        }

        # current cnt = max repetition if we car in successfully complete run in 1 try
        # 1. 1 first try
        # 2. There is no retry
        if ($is_try1) {
            for my $oid (@allrep_oids) {
                if (   ( not exists $data_out{oids}{snmp_retry} )
                    or ( not exists $data_out{oids}{snmp_retry}{$oid} )
                    or ( not exists $data_out{oids}{snmp_retry}{$oid}{left_repetitions} ) )
                {
                    if (    defined $data_in{oids}{$oid}{max_repetitions}
                        and $data_in{oids}{$oid}{max_repetitions} != $poll_rep_oid{$oid}{cnt}
                        and $poll_rep_oid{$oid}{cnt} != 0 )
                    {
                        $data_out{snmp_msg}{ ++$snmp_msg_count }
                            = "Oid: $oid max repeater changed old: $data_in{oids}{$oid}{max_repetitions} new: $poll_rep_oid{$oid}{cnt}";
                    }
                    $data_out{oids}{snmp_input}{oids}{$oid}{max_repetitions} = $poll_rep_oid{$oid}{cnt}
                        if ( defined $poll_rep_oid{$oid}{cnt} )
                        and $poll_rep_oid{$oid}{cnt} != 0;
                }
            }
        }
        for my $oid ( keys %{ $data_in{oids} } ) {
            if (   ( exists $data_in{oids}{$oid}{max_repetitions} ) and ( not exists $data_out{oids}{snmp_input}{oids}{$oid} )
                or ( not exists $data_out{oids}{snmp_input}{oids}{$oid}{max_repetitions} ) )
            {
                if ( ( exists $data_in{oids}{$oid}{max_repetitions} ) and $data_in{oids}{$oid}{max_repetitions} > 0 ) {
                    $data_out{oids}{snmp_input}{oids}{$oid}{max_repetitions} = $data_in{oids}{$oid}{max_repetitions};
                }
            }
        }
        send_data( $sock, \%data_out );
        next DEVICE;
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

    # Serialize the data
    my $serialized = nfreeze($data_out) . "\nEOF\n";

    # Send the data
    my $bytes_written = 0;
    my $data_length   = length($serialized);
    while ( $bytes_written < $data_length ) {
        my $written = syswrite( $sock, $serialized, $data_length - $bytes_written, $bytes_written );
        if ( !defined $written ) {
            die "Error writing to socket: $!";
        }
        $bytes_written += $written;
    }
}

# Reap dead forks
sub REAPER {
    my $fork;
    while ( ( $fork = waitpid( -1, WNOHANG ) ) > 0 ) { sleep 1 }
    $SIG{CHLD} = \&REAPER;
}

sub deeph_insert_oidval_h {
    my ( $oidval, $deep_href ) = @_;

    # Extract OID and Value from the array reference
    my ( $oid, $val ) = @$oidval;

    # Remove leading dot from OID if present
    $oid = substr( $oid, 1 ) if substr( $oid, 0, 1 ) eq '.';

    # Split OID into keys (numeric parts)
    my @keys = split /\./, $oid;

    # Add an empty key at the end to store the value
    push @keys, '';

    # Ensure deep_href is defined and insert value
    dive_val( $deep_href //= {}, @keys ) = $val;
}

sub deeph_insert_oidkey_h {
    my ( $oidkey, $deep_href ) = @_;
    $oidkey = substr( $oidkey, 1 ) if substr( $oidkey, 0, 1 ) eq '.';
    my @keys = split /\./, $oidkey;
    dive_val( $deep_href //= {}, @keys ) = undef;
}

sub deeph_delete_oidkey_h {
    my ( $oidkey, $deep_href ) = @_;
    $oidkey = substr( $oidkey, 1 ) if substr( $oidkey, 0, 1 ) eq '.';
    my @keys     = split /\./, $oidkey;    # we take the
    my $last_key = pop @keys;
    for my $key (@keys) {
        if ( not exists $deep_href->{$key} ) {
            return 0;
        }
        else {
            $deep_href = $deep_href->{$key};
        }
    }
    delete $deep_href->{$last_key};
    return 1;
}

sub deeph_find_leaf {
    my ( $oid, $deep_href ) = @_;
    $oid = substr( $oid, 1 ) if substr( $oid, 0, 1 ) eq '.';
    my @keys = split /\./, $oid;
    $deep_href = $deep_href->{$_} for @keys;
    return exists $deep_href->{''} ? $deep_href->{''} : undef;
}

sub deeph_find_parent {

    # test if the oid or one of its parent are already defined in the hash and return it
    # As we dont want to poll a oid if it parent is already polled!
    my ( $oid, $deep_href ) = @_;
    $oid = substr( $oid, 1 ) if substr( $oid, 0, 1 ) eq '.';
    my @keys = split /\./, $oid;
    my $poid;
    for my $key (@keys) {
        if ( not exists $deep_href->{$key} ) {
            return undef;
        }
        else {
            if ( ref $deep_href->{$key} ne 'HASH' ) {

                #  if (defined $deep_href) {
                return substr( $poid, 1 ) . "." . $key;
            }
            else {
                $deep_href = $deep_href->{$key};
                $poid .= "." . $key;
            }
        }
    }
    return undef;
}

sub deeph_find_branch_h {
    my ( $oid, $deep_href ) = @_;
    $oid = substr( $oid, 1 ) if substr( $oid, 0, 1 ) eq '.';
    my @keys = split /\./, $oid;
    $deep_href = $deep_href->{$_} for @keys;
    return ( defined $deep_href ) ? %$deep_href : \();
}

sub deeph_flatten_h {
    my %flat;
    my %flatwdot = %{ deeph_flatten_href(@_) };
    for my $key ( keys %flatwdot ) {

        # Test if we have a '.' and strip it : we have a leaf value
        if ( ( substr $key, -1 ) eq '.' ) {
            my $keybutdot = substr( $key, 0, -1 );
            $flat{$keybutdot} = $flatwdot{$key};
        }
    }
    return %flat;
}

sub deeph_flatten_href {
    my %flat;
    my $delim = '.';
    my ( $deep_href, $prefix ) = @_;
    for my $key ( keys %{$deep_href} ) {    #eksf
        if ( ref $deep_href->{$key} ne 'HASH' ) {
            $flat{ ( defined $prefix ? $prefix . $delim . $key : $key ) } = $deep_href->{$key};
        }
        else {
            %flat = %{ { %flat, %{ deeph_flatten_href( $deep_href->{$key}, ( defined $prefix ? $prefix . $delim . $key : $key ) ) } } };
        }
    }
    return \%flat;
}

sub dive_val : lvalue {
    my $p = \shift;
    $p = \( ($$p)->{$_} ) for @_;
    $$p;
}
#
#  Given an OID in either ASN.1 or mixed text/ASN.1 notation, return an
#  encoded OID.
#
#  A simplified version of this function
sub toOID_old(@) {
    my (@vars) = @_;
    my @retvar;
    foreach my $var (@vars) {
        push( @retvar, encode_oid( split( /\./, $var ) ) );
    }
    return @retvar;
}

sub merge_h_old {    # Stolen from Mash Merge Simple, Thanks!
                     # shift unless ref $_[0]; # Take care of the case we're called like Hash::Merge::Simple->merge(...)
    my ( $left, @right ) = @_;
    return $left unless @right;
    return merge_h( $left, merge_h(@right) ) if @right > 1;
    my ($right) = @right;
    my %merge = %$left;
    for my $key ( keys %$right ) {
        my ( $hr, $hl ) = map { ref $_->{$key} eq 'HASH' } $right, $left;
        if ( $hr and $hl ) {
            $merge{$key} = merge_h( $left->{$key}, $right->{$key} );
        }
        else {
            $merge{$key} = $right->{$key};
        }
    }
    return \%merge;
}

sub bigger_elem_idx {
    my ( $arr, $oid ) = @_;
    my $idx;
    for my $i ( 0 .. $#$arr ) {

        # Compare OIDs lexicographically
        if ( compare_oids( $arr->[ $i ], $oid ) > 0 ) {
            $idx = $i;
            last;
        }
    }
    return $idx;
}

# Helper function to compare two OIDs lexicographically
sub compare_oids {
    my ( $oid1, $oid2 ) = @_;

    # Split OIDs into arrays of integers
    my @parts1 = split /\./, $oid1;
    my @parts2 = split /\./, $oid2;

    # Compare parts sequentially
    for my $i ( 0 .. $#parts1 ) {

        # If parts2 runs out of elements, oid1 is greater
        return 1 if $i > $#parts2;

        # Compare corresponding parts numerically
        if ( $parts1[ $i ] != $parts2[ $i ] ) {
            return $parts1[ $i ] <=> $parts2[ $i ];
        }
    }

    # If oid1 is shorter, it is less; if equal length, they are equal
    return @parts1 <=> @parts2;
}

sub build_snmp_log_message {
    my ( $error, $process, $sub_process, $task, $default_message, $default_code ) = @_;

    # Set defaults for message and code if undefined
    $default_message //= 'Undefined error';    # Default to 'Undefined error' if $default_message is not provided
    $default_code    //= -1;                   # Default to -1 if $default_code is not provided

    # Set the error message and code, using defaults if undefined
    my $error_message = $error->{message} // $default_message;
    my $error_code    = $error->{code}    // $default_code;

    # Construct the message
    my $message = "\"$error_message ($error_code)\"";    # Both message and code inside quotes

    # Add process, sub-process, and task if they are defined
    $message .= ', process:"' . $process . '"'         if defined $process;
    $message .= ', sub_process:"' . $sub_process . '"' if defined $sub_process;
    $message .= ', task:"' . $task . '"'               if defined $task;

    # Check if debugging is enabled (i.e., $g{debug} == 1) and convert details to string if necessary
    if ( $g{debug} == 1 && defined $error->{details} && ref( $error->{details} ) eq 'HASH' ) {
        my $details_str = '';
        foreach my $key ( keys %{ $error->{details} } ) {

            # Only add key-value pairs where the value is defined and non-empty
            if ( defined $error->{details}->{$key} && $error->{details}->{$key} ne '' ) {
                $details_str .= "$key:\"$error->{details}->{$key}\", ";
            }
        }

        # Trim the trailing comma and space
        $details_str =~ s/, $//;
        $message .= ', ' . $details_str;    # Append details without the "details:" label
    }
    return $message;                        # Return the constructed message
}
