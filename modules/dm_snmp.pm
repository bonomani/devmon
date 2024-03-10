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

#use Math::BigInt;
use POSIX ":sys_wait_h";

# Get system error numbers for checking $!.
use POSIX qw(:errno_h);

use Storable qw(nfreeze thaw dclone);
use Time::HiRes qw(time);

use dm_config qw(FATAL ERROR WARN INFO DEBUG TRACE);
use dm_config;

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
    my %snmp_input   = ();
    my %snmp_try_max = ();
    %{ $g{oid}{snmp_polled} } = ();

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
            $g{xymon_color}{$device} = 'green';
        }
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
        } elsif ( $g{xymon_color}{$device} ne 'green' ) {
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

        $g{devices}{$device}{oids}{snmp_perm}{snmp_try_max}{val} = $g{snmp_try_max}           if not defined $g{devices}{$device}{oids}{snmp_perm}{snmp_try_max}{val};
        $g{devices}{$device}{discover}                           = ( $g{current_cycle} == 1 ) if not defined $g{discover};
        ${$snmp_input_device_ref}->{is_discover_cycle} = ( $g{current_cycle} == 1 ) if not defined $g{is_discover_cycle};
        ${$snmp_input_device_ref}->{current_cycle}     = $g{current_cycle};
        ${$snmp_input_device_ref}->{current_try}       = 0;

        # Set timeout
        ${$snmp_input_device_ref}->{snmptimeout} //= $g{snmptimeout};

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
            ${$snmp_input_device_ref}->{authpass}   = $g{devices}{$device}{authpass}   if defined $g{devices}{$device}{authpass}   and ( $g{devices}{$device}{authpass} ne '' );
            ${$snmp_input_device_ref}->{authproto}  = $g{devices}{$device}{authproto}  if defined $g{devices}{$device}{authproto}  and ( $g{devices}{$device}{authproto} ne '' );
            ${$snmp_input_device_ref}->{cid}        = $g{devices}{$device}{cid}        if defined $g{devices}{$device}{cid}        and ( $g{devices}{$device}{cid} ne '' );
            ${$snmp_input_device_ref}->{dev}        = $device;
            ${$snmp_input_device_ref}->{ip}         = $g{devices}{$device}{ip}         if defined $g{devices}{$device}{ip}         and ( $g{devices}{$device}{ip} ne '' );
            ${$snmp_input_device_ref}->{port}       = $g{devices}{$device}{port}       if defined $g{devices}{$device}{port}       and ( $g{devices}{$device}{port} ne '' );
            ${$snmp_input_device_ref}->{privpass}   = $g{devices}{$device}{privpass}   if defined $g{devices}{$device}{privpass}   and ( $g{devices}{$device}{privpass} ne '' );
            ${$snmp_input_device_ref}->{privproto}  = $g{devices}{$device}{privproto}  if defined $g{devices}{$device}{privproto}  and ( $g{devices}{$device}{privproto} ne '' );
            ${$snmp_input_device_ref}->{resolution} = $g{devices}{$device}{resolution} if defined $g{devices}{$device}{resolution} and ( $g{devices}{$device}{resolution} ne '' );
            ${$snmp_input_device_ref}->{seclevel}   = $g{devices}{$device}{seclevel}   if defined $g{devices}{$device}{seclevel}   and ( $g{devices}{$device}{seclevel} ne '' );
            ${$snmp_input_device_ref}->{secname}    = $g{devices}{$device}{secname}    if defined $g{devices}{$device}{secname}    and ( $g{devices}{$device}{secname} ne '' );
            ${$snmp_input_device_ref}->{ver}        = $g{devices}{$device}{ver};
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
                    } else {
                        ${$snmp_input_device_ref}->{nonreps}{$number} = 1;
                    }
                }
            }
        }
        $snmp_input{$device} = undef;
        $snmp_input{$device} = dclone $g{devices}{$device}{snmp_input};
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
                if ($discover_success) {
                    do_log( "Discovery cycle deletes oid:$expected_oid on device:$device from snmp query", WARN );
                    delete $g{devices}{$device}{snmp_input}{nonreps}{$expected_oid};
                    $expected--;
                }
            } else {
                $received++;
            }
            if ( not exists $g{devices}{$device}{snmp_input}{oids}{$expected_oid} or not exists $g{devices}{$device}{snmp_input}{oids}{$expected_oid}{nosuchobject} ) {
                $expected++;
            }
        }

        for my $expected_oid ( keys %{ $g{devices}{$device}{snmp_input}{reps} } ) {
            if ( not exists $g{devices}{$device}{oids}{snmp_polled}{$expected_oid} ) {
                do_log( "No answer for oid:$expected_oid on device:$device", WARN );
                if ($discover_success) {
                    do_log( "Discovery cycle deletes oid:$expected_oid on device:$device from snmp query", WARN );
                    delete $g{devices}{$device}{snmp_input}{reps}{$expected_oid};
                    $expected--;
                }
            } else {
                $received++;
            }
            if ( not exists $g{devices}{$device}{snmp_input}{oids}{$expected_oid} or not exists $g{devices}{$device}{snmp_input}{oids}{$expected_oid}{nosuchobject} ) {
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
            } else {
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
    $g{numsnmpdevs} = $g{numdevs} if ( !defined $g{numsnmpdevs} );

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
        $snmp_input->{$device}{snmptry_min_duration} //= 10;    # if does not exist put it to 10 sec
                                                                # Initialize max tries for read host discovery!
        if ( not exists $g{devices}{$device}{oids}{snmp_perm}{snmp_try_max} ) {
            $g{devices}{$device}{oids}{snmp_perm}{snmp_try_max}{val} = 1;
            $g{maxpolltime} = 7;    #(timeout is 3 so 2 retries + 1 sec
        }
    }

    # Order the polling to start with device that take takes longer
    for my $device ( reverse sort { $snmp_input->{$a}{snmptry_min_duration} <=> $snmp_input->{$b}{snmptry_min_duration} } keys %{$snmp_input} ) {
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
                    $g{devices}{$device}{oids}{snmp_temp}{snmp_tries}{val} = 1 if not exists $g{devices}{$device}{oids}{snmp_temp}{snmp_tries}{val};
                    do_log( "Fork:$fork has data for device:$device, reading it", DEBUG ) if $g{debug};

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
                                select undef, undef, undef, 0.05;
                            }
                        } until $data_in =~ s/\nEOF\n$//s;
                        alarm 0;
                    };
                    if ($@) {
                        do_log( "Fork:$fork pid:$g{forks}{$fork}{pid} stalled on device:$device: $@. Killing this fork.", ERROR );
                        if ( kill( 0, $g{forks}{$fork}{pid} ) ) {
                            kill 15, $g{forks}{$fork}{pid}
                                or do_log( "Sending $fork TERM signal failed: $!", ERROR );
                        }
                        close $g{forks}{$fork}{CS}
                            or do_log( "Closing socket to fork $fork failed: $!", ERROR );
                        delete $g{forks}{$fork};
                        --$active_forks;
                        fork_queries();
                        push @devices, $device;
                        $g{devices}{$device}{oids}{snmp_temp}{snmp_tries}{val} += 1;
                        do_log( "Device: $device Try:$g{devices}{$device}{oids}{snmp_temp}{snmp_tries}{val} Msg:snmp polling enqueue", INFO );
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
                    } else {
                        print "failed thaw on $device\n";
                        push @devices, $device;
                        next;
                    }
                    $g{devices}{$device}{oids}{snmp_temp}{snmp_tries}{val} = 1 if not exists $g{devices}{$device}{oids}{snmp_temp}{snmp_tries}{val};
                    if ( exists $returned{snmp_msg} ) {
                        my $snmp_msg_count = keys %{ $g{devices}{$device}{oids}{snmp_temp}{snmp_msg}{val} };
                        for my $snmp_msg_idx ( sort { $a <=> $b } keys %{ $returned{snmp_msg} } ) {
                            $snmp_msg_count++;
                            my $snmp_msg = "Try:$g{devices}{$device}{oids}{snmp_temp}{snmp_tries}{val}  Msg:$returned{snmp_msg}{$snmp_msg_idx}";
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
                                    $g{devices}{$device}{oids}{snmp_polled}{$k1}{$k3}{$k2} = $v3;    #swap order val <->leaf
                                }
                            } else {    #this is a nrep
                                $g{devices}{$device}{oids}{snmp_polled}{$k1}{$k2} = $v2;
                            }
                        }
                    }
                    if ( defined $returned{snmp_errornum} and $returned{snmp_errornum} == 0 ) {
                        my $snmp_errornum_count = keys %{ $g{devices}{$device}{oids}{snmp_temp}{snmp_errornum}{val} };
                        $g{devices}{$device}{oids}{snmp_temp}{snmp_errornum}{val}{ ++$snmp_errornum_count } = 0;
                        delete $returned{snmp_errornum};
                        delete $returned{snmp_errorstr};
                    } else {

                        # We have probably error
                        # Store and log all error info
                        my $snmp_errorstr_count = keys %{ $g{devices}{$device}{oids}{snmp_temp}{snmp_errorstr}{val} };
                        my $snmp_errornum_count = keys %{ $g{devices}{$device}{oids}{snmp_temp}{snmp_errornum}{val} };
                        my $snmp_error_count    = $snmp_errorstr_count > $snmp_errornum_count ? $snmp_errorstr_count : $snmp_errornum_count;
                        $g{devices}{$device}{oids}{snmp_temp}{snmp_errorstr}{val}{ ++$snmp_error_count } = $returned{snmp_errorstr};
                        $g{devices}{$device}{oids}{snmp_temp}{snmp_errornum}{val}{ ++$snmp_error_count } = $returned{snmp_errornum} if defined $returned{snmp_errornum} // 'Undef';
                        if ( ( defined $returned{snmp_errornum} ) and ( $returned{snmp_errornum} == -24 ) ) {
                            do_log( "Fork:$fork Device:$device Try:$g{devices}{$device}{oids}{snmp_temp}{snmp_tries}{val} Err:" . $returned{snmp_errorstr} . ( defined $returned{snmp_errornum} ? "(" . $returned{snmp_errornum} . ")" : '' ), INFO );
                        } else {
                            do_log( "Fork:$fork Device:$device Try:$g{devices}{$device}{oids}{snmp_temp}{snmp_tries}{val} Err:" . ( defined $returned{snmp_errorstr} ? $returned{snmp_errorstr} : '' ) . ( defined $returned{snmp_errornum} ? "(" . $returned{snmp_errornum} . ")" : '' ), ERROR );
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

                            #if (( ( time() - $polltime + $snmp_input->{$device}{snmptimeout} < $g{maxpolltime} ) and ( $g{devices}{$device}{oids}{snmp_temp}{snmp_tries}{val} < $g{devices}{$device}{oids}{snmp_perm}{snmp_try_max}{val} ) )
                            #    or ( time() - $polltime + $snmp_input->{$device}{snmptimeout} < $g{maxpolltime} / 2 )
                            if ( ( ( time() - $polltime + $snmp_input->{$device}{snmptimeout} ) < $g{maxpolltime} ) and ( $g{devices}{$device}{oids}{snmp_temp}{snmp_tries}{val} < $g{devices}{$device}{oids}{snmp_perm}{snmp_try_max}{val} ) ) {
                                push @devices, $device;
                                $g{devices}{$device}{oids}{snmp_temp}{snmp_tries}{val} += 1;
                                do_log( "Device: $device Try:$g{devices}{$device}{oids}{snmp_temp}{snmp_tries}{val} Msg:snmp polling enqueue", INFO );
                            } else {
                                do_log( "Device: $device Try:$g{devices}{$device}{oids}{snmp_temp}{snmp_tries}{val} Msg:No time left or snmp_try_max reached, polling fails", WARN );
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
                } else {
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
                    } elsif ( !kill 0, $pid ) {

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
                my $device = shift @devices;
                if ( ( time() - $polltime + $snmp_input->{$device}{snmptimeout} ) < $g{maxpolltime} ) {
                    $g{forks}{$fork}{dev} = $device;
                    ++$snmp_input->{$device}{current_try};
                    my $polltime_start = time();
                    $snmp_input->{$device}{snmptimeout_instant} = $polltime_start + $snmp_input->{$device}{snmptimeout};

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
    my $snmp_msg_count;
    my $snmp_errornum;
    my $snmp_errorstr;

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
                    exit 1;
                }
                my $sleeptime = $g{cycletime} / 2;
                do_log( "Parent ($g{mypid}) seems to be running, fork $fork_num sleeping for $sleeptime", WARN, $fork_num );

                sleep 1;
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
        my $snmp_ver      = $data_in{ver};
        my $timeout_count = exists $data_in{timeout_count} ? $data_in{timeout_count} : 0;
        my $discover      = exists $data_in{discover} ? $data_in{discover} : 0;

        # Establish SNMP session
        my $session;
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
        } elsif ( ( ( $g{snmpeng} eq 'session' or $g{snmpeng} eq 'auto' ) and ( $snmp_ver eq '2' or $snmp_ver eq '2c' ) ) or ( $snmp_ver eq '1' ) ) {

            # Formule: GLOBAL.SNMP.MAXPDUPACKETSIZE = (MAX-REPETITION * (OID_Length + )) + 80
            use BER;
            use SNMP_Session;

            $BER::pretty_print_timeticks     = 0;
            $SNMP_Session::max_pdu_len       = 16384;
            $SNMP_Session::suppress_warnings = $g{debug} ? 0 : 1;

            # Get SNMP variables
            my $snmp_cid     = $data_in{cid};
            my $snmp_port    = $data_in{port} // 161;
            my $ip           = $data_in{ip};
            my $device       = $data_in{dev};
            my $snmp_try_max = 1;

            # we substract 0.2 millisecond to timeout before the main process (to be ckecked if best value)
            my $snmptimeout_instant   = $data_in{snmptimeout_instant} - 0.2;
            my $hostip                = ( defined $ip and $ip ne '' ) ? $ip : $device;
            my $backoff               = '';
            my $max_getbulk_responses = $data_in{max_getbulk_responses};
            my $max_getbulk_repeaters = $data_in{max_getbulk_repeaters};
            my $use_getbulk           = $snmp_ver eq '1' ? 0 : 1;
            my $sgbmomr1              = $data_in{sgbmomr1} if exists $data_in{sgbmomr1};
            my $sgbmomr2              = $data_in{sgbmomr2} if exists $data_in{sgbmomr2};
            my $sgbmomr100            = $data_in{sgbmomr100} if exists $data_in{sgbmomr100};
            my $snmpwalk_mode         = $data_in{snmpwalk_mode} // 0;                          # 0 = default mode
            my $snmptry_min_duration  = $data_in{snmptry_min_duration};
            my $snmptry_max_duration  = $data_in{snmptry_max_duration};
            my $current_cycle         = $data_in{current_cycle};
            my $current_try           = $data_in{current_try};
            my $is_try1               = !( $current_try != 1 );

            $data_out{oids}{snmp_input}{stats} = $data_in{stats};

            my $nb_of_snmpwalk_mode = 6;
            $current_cycle //= 0;

            # we get stat 2 times for each mode at start and 1 time randomly each 100 cycle
            my $is_optim_cycle = ( ( $current_try == 1 ) and ( ( ( $current_cycle - 1 ) <= ( $nb_of_snmpwalk_mode * 2 ) ) or ( not int( rand(100) ) ) ) );

            # Stage: Not discovered = 0, initial discovery completed= 10, all discovery completed 20, 1,2,3,4i,,, = Step discoverd
            my $discover_stage    = exists $data_in{discover_stage} ? $data_in{discover_stage} : 0;
            my $is_discover_cycle = ( $discover_stage < 10 );

            # Special case for read host
            if ( not exists $data_in{reps} and ( scalar keys %{ $data_in{nonreps} } ) == 1 and $current_cycle == 0 ) {
                $is_discover_cycle = 0;
            }

            # Prepare our session paramater that have to stay open if possible
            my $host;    # = "$snmp_cid\@$hostip:$snmp_port:$timeout:$snmp_try_max:$backoff:$snmp_ver";

            # 'our' not really needed but need to refactor the sub that used them (todo)
            #our $session;
            #my $session;
            #our $session_host;
            #our $session_version;
            #our $session_lhost;
            #our $session_ipv4only;
            #our $session_return_array_refs = 0;
            #our $session_return_hash_refs  = 0;

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
                    # The oid or its a parent already exists!
                    # add it to its list !
                    $poll_rep_oid{$poid}{oids}{$oid} = undef;
                    $oid{$oid}{poll_oid} = $poid;    #
                } elsif ( scalar( keys %coid ) ) {

                    # The hash has alread child oid defined
                    # delete them and put them under our new oid
                    for my $coid ( keys %coid ) {
                        delete $poll_rep_oid{$coid}{oids}{$coid};    # We delete them in our poll hash
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
                        $poll_rep_defined_mr{$oid}                                                 = $data_in{snmp_retry}{$oid}{left_repetitions};
                        $poll_rep_mr_defined{ $data_in{snmp_retry}{$oid}{left_repetitions} }{$oid} = undef;
                        $poll_rep_oid{$oid}{start}                                                 = $oid . "." . $data_in{snmp_retry}{$oid}{start};    # a new start should be defined,
                    } elsif ( defined $data_in{oids}{$oid}{max_repetitions} ) {                                                                         # Max repetion is set
                        $poll_rep_defined_mr{$oid}                                          = $data_in{oids}{$oid}{max_repetitions};
                        $poll_rep_mr_defined{ $data_in{oids}{$oid}{max_repetitions} }{$oid} = undef;
                        $poll_rep_oid{$oid}{start}                                          = $oid . "." . $data_in{snmp_retry}{$oid}{start} if defined $data_in{snmp_retry}{$oid}{start};

                    } else {
                        $poll_rep_undefined_mr{$oid} = undef;
                    }

                } else {

                    # The normal case : just insert our oid
                    deeph_insert_oidkey_h( $oid, \%deep_rep );                                                                                          #mark the oid with 1 to say it exists
                    $poll_rep_oid{$oid}{oids}{$oid} = undef;
                    $poll_rep_oid{$oid}{start}      = $oid;
                    $poll_rep_oid{$oid}{cnt}        = 0;
                    $oid{$oid}{poll_oid}            = $oid;
                    if ( defined $data_in{snmp_retry}{$oid}{left_repetitions} ) {                                                                       #In case of Retry
                        $poll_rep_defined_mr{$oid}                                                 = $data_in{snmp_retry}{$oid}{left_repetitions};
                        $poll_rep_mr_defined{ $data_in{snmp_retry}{$oid}{left_repetitions} }{$oid} = undef;
                        $poll_rep_oid{$oid}{start}                                                 = $oid . "." . $data_in{snmp_retry}{$oid}{start};    # a new start should be defined,

                    } elsif ( defined $data_in{oids}{$oid}{max_repetitions} ) {                                                                         # Max repetion is set
                        $poll_rep_defined_mr{$oid}                                          = $data_in{oids}{$oid}{max_repetitions};
                        $poll_rep_mr_defined{ $data_in{oids}{$oid}{max_repetitions} }{$oid} = undef;
                        $poll_rep_oid{$oid}{start}                                          = $oid . "." . $data_in{snmp_retry}{$oid}{start} if defined $data_in{snmp_retry}{$oid}{start};
                    } else {
                        $poll_rep_undefined_mr{$oid} = undef;
                    }
                }
            }

            # Create the oid list of non-repeaters
            for my $oid ( keys %nrep ) {
                if ( $oid =~ /\.0$/ ) {                                                                                                                 # is an SNMP Scalar (end with .0) are real non-repeater
                    my $pvl_oid = $oid =~ s/\.0$//r;                                                                                                    # previous lex is the parent
                                                                                                                                                        # deeph_insert_oidkey_h( $oid, \%deep_rep );
                    $poll_nrep_oid{$pvl_oid} = $oid;
                    $oid{$oid}{poll_oid}     = $pvl_oid;
                    $poll_nrep{$pvl_oid}     = undef;
                } else {
                    my $poid = deeph_find_parent( $oid, \%deep_rep );
                    if ( defined $poid ) {

                        # The oid or its a parent already exists!
                        # add it to its list !
                        $poll_rep_oid{$poid}{oids}{$oid} = undef;
                    } else {

                        # If we dont have it, we take the parent as this is the best we can do.
                        my $pvl_oid;
                        $pvl_oid = $oid{$oid}{prev_lex_oid} if exists $oid{$oid}{prev_lex_oid};
                        if ( defined $pvl_oid ) {

                            $poll_nrep_oid{$pvl_oid} = $oid;
                            $oid{$oid}{poll_oid}     = $pvl_oid;
                            $poll_nrep{$pvl_oid}     = undef;
                        } else {

                            # TODO, Check for child and insert into deep_rep (if needed)
                            $pvl_oid                            = $oid =~ s/\.\d*$//r;    # we take the parent as previous lex
                            $poll_rep_oid{$pvl_oid}{start}      = $pvl_oid;
                            $poll_rep_oid{$pvl_oid}{oids}{$oid} = undef;
                            $poll_rep_oid{$pvl_oid}{cnt}        = 0;
                            if ( defined $data_in{snmp_retry}{$pvl_oid}{left_repetitions} ) {    #In case of Retry
                                $poll_rep_defined_mr{$pvl_oid}                                                     = $data_in{snmp_retry}{$pvl_oid}{left_repetitions};
                                $poll_rep_mr_defined{ $data_in{snmp_retry}{$pvl_oid}{left_repetitions} }{$pvl_oid} = undef;
                                $poll_rep_oid{$pvl_oid}{start}                                                     = $pvl_oid . "." . $data_in{snmp_retry}{$pvl_oid}{start};    # a new start should be defined,
                            } elsif ( defined $data_in{oids}{$pvl_oid}{max_repetitions} ) {                                                                                     # Max repetion is set
                                $poll_rep_defined_mr{$pvl_oid}                                              = $data_in{oids}{$pvl_oid}{max_repetitions};
                                $poll_rep_mr_defined{ $data_in{oids}{$pvl_oid}{max_repetitions} }{$pvl_oid} = undef;                                                                                                     # The reverse mapping
                                $poll_rep_oid{$pvl_oid}{start}                                              = $pvl_oid . "." . $data_in{snmp_retry}{$pvl_oid}{start} if defined $data_in{snmp_retry}{$pvl_oid}{start};
                            } else {
                                $poll_rep_undefined_mr{$pvl_oid} = undef;
                            }

                        }
                    }
                }
            }
            my @allrep_oids;
            @allrep_oids = keys %poll_rep_oid;

            #$session->{use_getbulk}    = 1;
            $SNMP_Session::use_getbulk = 1;
            $SNMP_Session::pdu_buffer  = 16384;

            my %deep_h;
            my @ret;

            # Discovery Stage
            if ($is_discover_cycle) {
                $host = "$snmp_cid\@$hostip:$snmp_port:5:1:$backoff:$snmp_ver";    # Set timeout to 5 sec and tries to 1
                my $snmp_timeout = 5;
                my $snmp_tries   = 1;

                if ( not $snmp_ver == 1 ) {

                    # We are in SNMPv2 (SNMPv3 not supported by now)
                    # Discovery Stage 1,2,3,4:
                    if ( $discover_stage < 10 ) {    # 1,2,3 have to be grouped as they reuse the discoverd oids
                        $data_out{oids}{snmp_input}{discover_stage} = 0;    # stage completed: 0 (reinitialized process)
                                                                            # Discovery Stage 1: The max getbulk responses
                                                                            # Try a huge query from the top of the tree (standard = 100)
                        my @ret1 = snmpgetbulk( $host, 0, 1000, '1.3.6.1' );    # if $sgbmo > 1;
                                                                                #my @ret1 = snmpgetbulk( $hostip, $snmp_cid, $snmp_port, $snmp_timeout, $snmp_tries, $backoff, $snmp_ver , 0, 1000, '1.3.6.1' );   # Set timeout to 5 sec and tries to 1
                        if ( $SNMP_Session::errmsg ne '' ) {
                            if ( $SNMP_Session::errmsg =~ /no response received/ ) {
                                $data_out{snmp_msg}{ ++$snmp_msg_count } = "Timeout at discovery stage:1, will retry until success";
                                $data_out{snmp_errorstr}                 = "Timeout";
                                $data_out{snmp_errornum}                 = -24;
                            } else {
                                $data_out{snmp_errorstr} = $SNMP_Session::errmsg;
                            }
                            $SNMP_Session::errmsg = '';
                            send_data( $sock, \%data_out );
                            next DEVICE;
                        }
                        $max_getbulk_responses = scalar @ret1;              # max_getbulk_responses is defined!
                        $data_out{oids}{snmp_input}{discover_stage} = 1;    # stage completed: 1

                        # Discovery Stage 2: The max getbulk repeaters
                        # The number of reapeter is always lower or equal (generaly equal) than the max_getbulk_responses
                        my @oids;

                        #First extract all oid from answer
                        for my $oidval (@ret1) {    # Used the previously return oids
                            my $i = index( $oidval, ":" );
                            push @oids, substr( $oidval, 0, $i );
                        }

                        my @ret2 = snmpgetbulk( $host, 0, 1, @oids );

                        #my @ret2 = snmpgetbulk( $hostip, $snmp_cid, $snmp_port, $snmp_timeout, $snmp_tries, $backoff, $snmp_ver, 0, 1, @oids );
                        if ( $SNMP_Session::errmsg ne '' ) {
                            if ( $SNMP_Session::errmsg =~ /no response received/ ) {
                                $data_out{snmp_msg}{ ++$snmp_msg_count } = "Timeout at discovery stage:2. will retry until success";
                                $data_out{snmp_errorstr}                 = "Timeout";
                                $data_out{snmp_errornum}                 = -24;
                            } else {
                                $data_out{snmp_errorstr} = $SNMP_Session::errmsg;
                            }
                            $sgbmomr1             = 0;
                            $SNMP_Session::errmsg = '';
                            send_data( $sock, \%data_out );
                            next DEVICE;
                        } else {
                            $sgbmomr1 = 1;    #snmpgetbulk multiple oid with max-retitions=1 is supported
                        }
                        $max_getbulk_repeaters = scalar @ret2;              # max_getbulk_responses is defined!
                        $data_out{oids}{snmp_input}{discover_stage} = 2;    # stage completed: 2

                        # Discovery Stage 3: Test if multiple oid (2), max-repotions (>1, =2) and workaroud
                        # This time this is quick unlikely to timout: for now we consider that as a read failur

                        @ret2 = snmpgetbulk( $host, 0, 2, $oids[0], $oids[1] );

                        #@ret2 = snmpgetbulk( $hostip, $snmp_cid, $snmp_port, $snmp_timeout, $snmp_tries, $backoff, $snmp_ver, 0, 2, $oids[0], $oids[1] );
                        if ( $SNMP_Session::errmsg ne '' ) {
                            if ( $SNMP_Session::errmsg =~ /no response received/ ) {
                                $SNMP_Session::errmsg                    = '';
                                $data_out{snmp_msg}{ ++$snmp_msg_count } = "Timeout at discovery stage:3, as unlikely, will consider as an agent failure";
                                $sgbmomr2                                = 0;
                                $data_out{snmp_msg}{ ++$snmp_msg_count } = "Try workaround with max-repetitions set to 100";
                                @ret2                                    = snmpgetbulk( $host, 0, 100, $oids[0], $oids[1] );

                                #@ret2                                    = snmpgetbulk( $hostip, $snmp_cid, $snmp_port, $snmp_timeout, $snmp_tries, $backoff, $snmp_ver, 0, 100, $oids[0], $oids[1] );
                                if ( $SNMP_Session::errmsg eq '' ) {
                                    $data_out{snmp_msg}{ ++$snmp_msg_count } = "Max-repetitions set to 100 works";
                                    $sgbmomr100 = 1;
                                } else {
                                    $data_out{snmp_msg}{ ++$snmp_msg_count } = "Max-repetitions set to 100 does not work, err:" . $SNMP_Session::errmsg;
                                    $SNMP_Session::errmsg                    = '';
                                    $sgbmomr100                              = 0;
                                }
                            } else {
                                $data_out{snmp_msg}{ ++$snmp_msg_count } = "SNMP non fatal error at discovery stage:3, err;" . $SNMP_Session::errmsg;
                                $SNMP_Session::errmsg = '';
                            }
                            $sgbmomr2 = 0;
                        } else {
                            $sgbmomr2 = 1;    #snmpgetbulk multiple oid with (at least) 2 repetitions
                        }
                    }
                    $data_out{oids}{snmp_input}{discover_stage} = 10;    # Initial discovery stage completed:
                                                                         # Check

                    # Store these discovery info for the non discovery cycles
                    $data_out{oids}{snmp_input}{max_getbulk_responses} = $max_getbulk_responses;
                    $data_out{oids}{snmp_input}{max_getbulk_repeaters} = $max_getbulk_repeaters;
                    $data_out{oids}{snmp_input}{sgbmomr1}              = $sgbmomr1 if defined $sgbmomr1;
                    $data_out{oids}{snmp_input}{sgbmomr2}              = $sgbmomr2 if defined $sgbmomr2;
                    $data_out{oids}{snmp_input}{sgbmomr100}            = $sgbmomr100 if defined $sgbmomr100;

                    # TODO: We could insert those result in our deep_h, not to poll them again
                }
            }
            @ret = ();
            my $has_timed_out = 0;
            $max_getbulk_responses //= 50;                        # for snmp v1 (no discovery)
            $max_getbulk_repeaters //= $max_getbulk_responses;    # for snmp v1 (no discovery)
            @allrep_oids = keys %poll_rep_oid;

            my $default_max_repetitions = 1;
            my $default_snmp_bulk_query_cnt;
            $default_snmp_bulk_query_cnt = int( ( ( scalar @allrep_oids ) * $default_max_repetitions / $max_getbulk_responses ) + 0.5 );
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

            # Only if we are a clean cycle
            if ($is_optim_cycle) {

                # Adjust modulo to start with 0 (1 first cycle do not count)
                $snmpwalk_mode                           = 0 if $current_cycle == 0;                            # The 0 cyc do not count (0 or 1)
                $snmpwalk_mode                           = ( $current_cycle - 1 ) % $nb_of_snmpwalk_mode;
                $data_out{snmp_msg}{ ++$snmp_msg_count } = "optim snmpwalk_mode:$snmpwalk_mode" if $g{debug};
            }

            if ( $snmpwalk_mode == 5 ) {
                $group_by_max_repetitions_by_col = 1;
                $group_by_max_repetitions_by_row = 0;
                $nreapeter_at_end                = 1;
            } elsif ( $snmpwalk_mode == 2 ) {
                $group_by_max_repetitions_by_col = 0;
                $group_by_max_repetitions_by_row = 1;
                $nreapeter_at_end                = 0;
            } elsif ( $snmpwalk_mode == 3 ) {
                $group_by_max_repetitions_by_col = 0;
                $group_by_max_repetitions_by_row = 1;
                $nreapeter_at_end                = 0;
            } elsif ( $snmpwalk_mode == 0 ) {

                # Not grouping by max repetition: Default discovery mode
                $group_by_max_repetitions_by_col = 0;
                $group_by_max_repetitions_by_row = 0;
                $nreapeter_at_end                = 0;
            } elsif ( $snmpwalk_mode == 4 ) {
                $group_by_max_repetitions_by_col = 0;
                $group_by_max_repetitions_by_row = 0;
                $nreapeter_at_end                = 1;
            } elsif ( $snmpwalk_mode == 1 ) {

                # Default mode: grouping by col as this correspond usually to an app in the device
                $group_by_max_repetitions_by_col = 1;
                $group_by_max_repetitions_by_row = 0;
                $nreapeter_at_end                = 0;
            } else {
                $data_out{snmp_msg}{ ++$snmp_msg_count } = "Err: undefined snmpwalk_mode";
            }

            exit if $group_by_max_repetitions_by_col and $group_by_max_repetitions_by_row;
            my $group_by_max_repetitions = ( $group_by_max_repetitions_by_col or $group_by_max_repetitions_by_row );    # optimization parameter (can be less optimized): TODO: Determine automatically for each device

        BULK_QUERY: while ( ( ( ( scalar keys %poll_rep_undefined_mr ) + ( scalar keys %poll_rep_defined_mr ) + ( scalar keys %poll_rep_as_nrepu ) + ( scalar keys %poll_rep_as_nrepd ) + ( scalar keys %poll_nrep ) ) != 0 ) and ( not $has_timed_out ) ) {
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

                if ( scalar keys %poll_rep_undefined_mr ) {

                    # Start to discover oid that dont have the max-repetition set yet (discovery phase)
                    if ( $left_repeater_to_query < $max_getbulk_repeaters ) {
                        $free_repeater_in_query   = $left_repeater_to_query;
                        $max_repetitions_in_query = ( $free_repeater_in_query == 0 ) ? 0 : int( $max_getbulk_responses / $free_repeater_in_query );
                        if ($nreapeter_at_end) {
                            $free_nrepeater_in_query = 0;
                        } else {
                            $free_nrepeater_in_query = $max_getbulk_responses - $max_repetitions_in_query * $free_repeater_in_query;
                            $free_nrepeater_in_query = $max_getbulk_repeaters - $free_repeater_in_query if ( $free_repeater_in_query + $free_nrepeater_in_query ) > $max_getbulk_repeaters;
                        }
                    } else {
                        $free_repeater_in_query   = $max_getbulk_repeaters;
                        $free_nrepeater_in_query  = 0;
                        $max_repetitions_in_query = int( $max_getbulk_responses / $free_repeater_in_query );
                    }
                } elsif ( scalar keys %poll_rep_defined_mr ) {

                    # All oid with undefined mr are discover let's do the same with oid with mr defined
                    # First calc the max of all max-repetition to regroup all oids that have the same mr
                    $max_max_repetitions = ( sort { $a <=> $b } ( keys %poll_rep_mr_defined ) )[-1];

                    my $max_max_repetitions_nb_of_query = scalar keys %{ $poll_rep_mr_defined{$max_max_repetitions} };

                    # not any grouping, same as oid with undefined mr
                    if ( not $group_by_max_repetitions ) {
                        if ( $left_repeater_to_query < $max_getbulk_repeaters ) {
                            $free_repeater_in_query   = $left_repeater_to_query;
                            $max_repetitions_in_query = ( $free_repeater_in_query == 0 ) ? 0 : int( $max_getbulk_responses / $free_repeater_in_query );
                            if ($nreapeter_at_end) {
                                $free_nrepeater_in_query = 0;
                            } else {
                                $free_nrepeater_in_query = $max_getbulk_responses - $max_repetitions_in_query * $free_repeater_in_query;
                                $free_nrepeater_in_query = $max_getbulk_repeaters - $free_repeater_in_query if ( $free_repeater_in_query + $free_nrepeater_in_query ) > $max_getbulk_repeaters;
                            }
                        } else {
                            $free_repeater_in_query   = $max_getbulk_repeaters;
                            $free_nrepeater_in_query  = 0;
                            $max_repetitions_in_query = int( $max_getbulk_responses / $free_repeater_in_query );
                        }
                    } elsif ($group_by_max_repetitions_by_col) {
                        $max_repetitions_in_query = $max_max_repetitions < $max_getbulk_responses ? $max_max_repetitions : $max_getbulk_responses;
                        $free_repeater_in_query   = int( $max_getbulk_responses / $max_repetitions_in_query );
                        $free_repeater_in_query   = $free_repeater_in_query > $max_getbulk_repeaters ? $max_getbulk_repeaters : $free_repeater_in_query;
                        if ($nreapeter_at_end) {
                            $free_nrepeater_in_query = 0;
                        } else {
                            $free_nrepeater_in_query = $max_getbulk_responses - $max_repetitions_in_query * $free_repeater_in_query;
                            $free_nrepeater_in_query = $max_getbulk_repeaters - $free_repeater_in_query if ( $free_repeater_in_query + $free_nrepeater_in_query ) > $max_getbulk_repeaters;
                        }
                    } else {    # group_by_max_repetitions_by_row
                        $free_repeater_in_query   = $max_max_repetitions_nb_of_query > $max_getbulk_repeaters ? $max_getbulk_repeaters : $max_max_repetitions_nb_of_query;
                        $max_repetitions_in_query = int( $max_getbulk_responses / $free_repeater_in_query );
                        if ($nreapeter_at_end) {
                            $free_nrepeater_in_query = 0;
                        } else {
                            $free_nrepeater_in_query = $max_getbulk_responses - $max_repetitions_in_query * $free_repeater_in_query;
                            $free_nrepeater_in_query = $max_getbulk_repeaters - $free_repeater_in_query if ( $free_repeater_in_query + $free_nrepeater_in_query ) > $max_getbulk_repeaters;
                        }
                    }
                    $max_repetitions_in_query = $max_max_repetitions if $max_max_repetitions < $max_repetitions_in_query;
                } else {
                    $free_repeater_in_query   = 0;
                    $free_nrepeater_in_query  = $max_getbulk_repeaters;
                    $max_repetitions_in_query = 0;
                }
                if ( $g{debug} ) {
                    $data_out{snmp_msg}{ ++$snmp_msg_count } = "Free rep:$free_repeater_in_query nrep:$free_nrepeater_in_query mr:$max_repetitions_in_query";
                    $data_out{snmp_msg}{ ++$snmp_msg_count } = "Todo rep:" . ( ( scalar keys %poll_rep_undefined_mr ) + ( scalar keys %poll_rep_defined_mr ) ) . " nrep:" . ( ( scalar keys %poll_rep_as_nrepu ) + ( scalar keys %poll_rep_as_nrepd ) + ( scalar keys %poll_nrep ) ) . " [rep(u|d):" . ( scalar keys %poll_rep_undefined_mr ) . "|" . ( scalar keys %poll_rep_defined_mr ) . " [rnrep(u|d):" . ( scalar keys %poll_rep_as_nrepu ) . "|" . ( scalar keys %poll_rep_as_nrepd ) . " nrep:" . ( scalar keys %poll_nrep ) . "]";
                }

                # Create the query
                my @oid_in_query;
                my @nrep_in_query;
                my @rep_as_nrepu_in_query;
                my @rep_as_nrepd_in_query;

                # First insert non repeaters
                # The 'normal' non repeaters
                my $used_nrepeater_in_query = 0;
                foreach my $oid ( oid_sort keys %poll_nrep ) {
                    last if $used_nrepeater_in_query == $free_nrepeater_in_query;
                    $used_nrepeater_in_query++;
                    push @nrep_in_query, $oid;
                }
                @oid_in_query = @nrep_in_query;

                # Insert the non repeaters that are in fact repeaters...
                foreach my $oid ( oid_sort keys %poll_rep_as_nrepu ) {
                    if ( not $sgbmomr2 and $sgbmomr100 ) {

                        # If we cant fix the max-repetition value and sgbmomr100 works,
                        # We will have a lot of rep_as_nrep. We have better to do them
                        # when we have have try all reps (resp in query =0), so at the end
                        last
                            if ( $used_nrepeater_in_query == $free_nrepeater_in_query )
                            or ( $free_repeater_in_query != 0 );
                    } else {

                        # the normal case
                        last if $used_nrepeater_in_query == $free_nrepeater_in_query;
                    }

                    $used_nrepeater_in_query++;
                    push @rep_as_nrepu_in_query, $oid;
                    push @oid_in_query,          $poll_rep_oid{$oid}{start};
                }
                foreach my $oid ( oid_sort keys %poll_rep_as_nrepd ) {
                    if ( not $sgbmomr2 and $sgbmomr100 ) {
                        last
                            if ( $used_nrepeater_in_query == $free_nrepeater_in_query )
                            or ( $free_repeater_in_query != 0 );
                    } else {
                        last if $used_nrepeater_in_query == $free_nrepeater_in_query;
                    }

                    $used_nrepeater_in_query++;
                    push @rep_as_nrepd_in_query, $oid;
                    push @oid_in_query,          $poll_rep_oid{$oid}{start};
                }

                # Add now the reperaters
                my $used_repeater_in_query = 0;
                my @rep_in_query;
                my %rep_def_mr_in_query;    #
                my %rep_undef_mr_in_query;
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
                } else {
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
                if ( $g{debug} ) {
                    $data_out{snmp_msg}{ ++$snmp_msg_count } = "Used rep:$used_repeater_in_query nrep:$used_nrepeater_in_query [rnrep:" . ( $used_nrepeater_in_query - @nrep_in_query ) . "|nrep:" . ( scalar @nrep_in_query ) . "]";
                }
                my $max_repetitions_in_query_ww = $max_repetitions_in_query;
                if ( not $sgbmomr2 ) {
                    if ( $max_repetitions_in_query_ww <= 1 ) {
                        if ($sgbmomr1) {

                            #Do nothing now
                        } elsif ($sgbmomr100) {
                            $max_repetitions_in_query_ww = 100;
                        }
                    } else {
                        if ($sgbmomr100) {
                            $max_repetitions_in_query_ww = 100;
                        } elsif ($sgbmomr1) {
                            $max_repetitions_in_query_ww = 1;
                        } else {
                        }
                    }
                }

                my @ret;
                my $snmp_query_start_time = time();
                my $query_timeout         = $snmptimeout_instant - $snmp_query_start_time;
                if ( $query_timeout < 0.3 ) {
                    $has_timed_out = 1;
                    last BULK_QUERY;
                }

                if ( $snmp_ver == 1 ) {
                    $host = "$snmp_cid\@$hostip:$snmp_port:$query_timeout:1:$backoff:$snmp_ver";
                    @ret  = snmpgetnext( $host, @oid_in_query );

                    #@ret  = snmpgetnext( $hostip, $snmp_cid, $snmp_port, $query_timeout, 1, $backoff, $snmp_ver, @oid_in_query );
                } else {

                    $host = "$snmp_cid\@$hostip:$snmp_port:$query_timeout:1:$backoff:$snmp_ver";
                    @ret  = snmpgetbulk( $host, $used_nrepeater_in_query, $max_repetitions_in_query_ww, @oid_in_query );

                    #@ret  = snmpgetbulk( $hostip, $snmp_cid, $snmp_port, $query_timeout, 1, $backoff, $snmp_ver, $used_nrepeater_in_query, $max_repetitions_in_query_ww, @oid_in_query );
                }

                my $snmpquery_timestamp = time();
                if ( defined $BER::errmsg and $BER::errmsg ne '' ) {
                    print $BER::errmsg;
                    $BER::errmsg = '';
                }
                if ( $SNMP_Session::errmsg ne '' ) {
                    if ( $SNMP_Session::errmsg eq 'Exception code: endOfMibView' ) {
                        my @filter_ret;
                        for my $oidval (@ret) {
                            my $i   = index( $oidval, ":" );
                            my $oid = substr( $oidval, 0, $i );
                            my $val = substr( $oidval, $i + 1 );
                            if ( $val eq 'endOfMibView' ) {
                                if ( not defined $end_of_mib_view_oid ) {
                                    $end_of_mib_view_oid = $oid;
                                } elsif ( $oid ne $end_of_mib_view_oid ) {
                                    print "error";
                                }
                            } else {
                                push @filter_ret, $oidval;
                            }
                        }
                        @ret = @filter_ret;
                    } elsif ( $SNMP_Session::errmsg =~ /no response received/ ) {
                        $has_timed_out        = 1;
                        $SNMP_Session::errmsg = '';
                        last BULK_QUERY;
                    } else {
                        $data_out{snmp_msg}{ ++$snmp_msg_count } = "SNMP error:" . $SNMP_Session::errmsg;
                        $SNMP_Session::errmsg = '';
                    }
                }

                for my $oidval (@ret) {
                    deeph_insert_oidval_h( $oidval, \%deep_h );
                }
                for my $poid (@nrep_in_query) {
                    my $oid       = $poid . ".0";
                    my $nonrepval = deeph_find_leaf( $oid, \%deep_h );
                    if ( not defined $nonrepval ) {
                        $data_out{snmp_msg}{ ++$snmp_msg_count } = "$oid = No Such Object available on this agent at this OID";
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
                        $poll_rep_oid{$oid}{start} = $branch_cnt ? $oid . "." . ( ( oid_sort( keys %branch_h ) )[-1] ) : $oid;
                    } else {

                        # No answer, we reach the end of the oid mib: check now that all children oid did have an answer or notify
                        for my $coid ( keys %{ $poll_rep_oid{$oid}{oids} } ) {    #eksf
                            if ( $oid eq $poll_rep_oid{$oid}{start} ) {
                                $data_out{oids}{snmp_input}{oids}{$coid}{nosuchobject} = undef;
                                $data_out{snmp_msg}{ ++$snmp_msg_count } = "$coid = No Such Object available on this agent at this OID";
                            }
                        }
                        if ( !$branch_cnt and $is_try1 and not exists $data_out{oids}{snmp_input}{oids}{$oid}{nosuchobject} ) {
                            $data_out{oids}{snmp_input}{oids}{$oid}{nosuchobject} = undef;
                            $data_out{snmp_msg}{ ++$snmp_msg_count } = "$oid = No Such Object available on this agent at this OID";
                        }
                    }

                    # As it was rebalance to normal oid or it was the end of its polling, we have delete this oid
                    delete $poll_rep_as_nrepu{$oid};
                }
                for my $oid (@rep_as_nrepd_in_query) {

                    # This is a final ch/eck for an oid as we have the max-repetition, we just try to see if there are new entries, but one by one
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
                        } else {
                            $branch_cnt = ( scalar keys %branch_h ) - $idx;
                        }
                    } else {
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
                            $poll_rep_oid{$oid}{start}                           = $oid . "." . $branch_keys_sorted[-1];
                        } else {
                            @branch_keys_sorted = oid_sort( keys %branch_h ) if $branch_keys_is_not_sorted;

                            # we have all repetition, but check for 1 new one, so just ask for a new nrep
                            $poll_rep_oid{$oid}{start} = $oid . "." . $branch_keys_sorted[-1];
                        }
                        $poll_rep_oid{$oid}{cnt} = $branch_cnt;
                    } else {

                        # no new entrie: this is end of the mib: done for this oid
                        delete $poll_rep_as_nrepd{$oid};
                        delete $poll_rep_defined_mr{$oid};

                        # Check if some oid did not have an answer, as we have to remove them
                        for my $coid ( keys %{ $poll_rep_oid{$oid}{oids} } ) {    #eksf
                            if ( $oid eq $poll_rep_oid{$oid}{start} ) {
                                $data_out{oids}{snmp_input}{oids}{$coid}{nosuchobject} = undef;
                                $data_out{snmp_msg}{ ++$snmp_msg_count } = "$coid = No Such Object available on this agent at this OID";
                            }
                        }
                        if ( !$branch_cnt and $is_try1 ) {                        # $branch_cnt =0 and $poll_rep_oid{$oid}{cnt} = 0
                            $data_out{oids}{snmp_input}{oids}{$oid}{nosuchobject} = undef;
                            $data_out{snmp_msg}{ ++$snmp_msg_count } = "$oid = No Such Object available on this agent at this OID";
                        }
                    }
                }
                for my $oid ( keys %rep_undef_mr_in_query ) {

                    my %branch_hml = deeph_find_branch_h( $oid, \%deep_h );
                    my %branch_h   = deeph_flatten_h( \%branch_hml );
                    my $branch_cnt = scalar keys %branch_h;
                    print "not defined cnt for $oid"       if ( not defined $branch_cnt );
                    print "not defined start cnt for $oid" if ( not defined $poll_rep_oid{$oid}{cnt} );
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
                        next if not defined $idx;    # The start oid is not found, so there are some leaf, but not the one we are looking for
                                                     #++$idx;
                    } else {
                        $idx = 0;
                    }

                    if ( $current_query_branch_cnt - $idx < $max_repetitions_in_query ) {

                        # Some agent dont honor max repetition for some oid so we have to confirm we got all
                        # We will try to get next value as a nrep to optimze the pooling.
                        # Case#1: They give 1 answer but not all
                        # Case#2: They do not support max-repetition completly
                        delete $poll_rep_undefined_mr{$oid};
                        if ( $current_query_branch_cnt - $idx != 0 ) {
                            $poll_rep_oid{$oid}{start} = $branch_cnt ? $oid . "." . ( ( oid_sort( keys %branch_h ) )[-1] ) : $oid;
                            $poll_rep_as_nrepu{$oid} = undef;
                        } elsif ( ( not $sgbmomr2 ) and $sgbmomr100 ) {
                            $poll_rep_as_nrepu{$oid} = undef;
                        } else {
                            $poll_rep_as_nrepu{$oid} = undef;
                        }
                    } else {
                        $poll_rep_oid{$oid}{start} = $oid . "." . ( ( oid_sort( keys %branch_h ) )[-1] );
                    }
                    $poll_rep_oid{$oid}{cnt} = $branch_cnt;
                }

                for my $oid ( keys %rep_def_mr_in_query ) {
                    my %branch_hml = deeph_find_branch_h( $oid, \%deep_h );
                    my %branch_h   = deeph_flatten_h( \%branch_hml );
                    if ( defined $end_of_mib_view_oid and $poll_rep_oid{$oid}{start} eq $end_of_mib_view_oid ) {
                        delete $poll_rep_mr_defined{ $poll_rep_defined_mr{$oid} }{$oid};
                        delete $poll_rep_mr_defined{ $poll_rep_defined_mr{$oid} } if not %{ $poll_rep_mr_defined{ $poll_rep_defined_mr{$oid} } };
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
                        } else {
                            $branch_cnt = ( scalar keys %branch_h ) - $idx;
                        }
                    } else {
                        $branch_cnt = scalar keys %branch_h;
                    }
                    my $current_query_branch_cnt = $branch_cnt - $poll_rep_oid{$oid}{cnt};

                    if ( $branch_cnt >= $poll_rep_defined_mr_initial{$oid} ) {
                        delete $poll_rep_mr_defined{ $poll_rep_defined_mr{$oid} }{$oid};
                        delete $poll_rep_mr_defined{ $poll_rep_defined_mr{$oid} } if not %{ $poll_rep_mr_defined{ $poll_rep_defined_mr{$oid} } };
                        delete $poll_rep_defined_mr{$oid};
                        @branch_keys_sorted        = oid_sort( keys %branch_h ) if $branch_keys_is_not_sorted;
                        $poll_rep_oid{$oid}{start} = $branch_cnt ? $oid . "." . $branch_keys_sorted[-1] : $oid;
                        $poll_rep_as_nrepd{$oid}   = undef;
                    } elsif ( $current_query_branch_cnt < $max_repetitions_in_query ) {
                        if ( ( not $sgbmomr2 ) and $sgbmomr100 and ( $branch_cnt == 0 ) ) {
                        } elsif ( $current_query_branch_cnt != 0 ) {
                            @branch_keys_sorted = oid_sort( keys %branch_h ) if $branch_keys_is_not_sorted;
                            $poll_rep_oid{$oid}{start} = $oid . "." . $branch_keys_sorted[-1];
                            delete $poll_rep_mr_defined{ $poll_rep_defined_mr{$oid} }{$oid};
                            delete $poll_rep_mr_defined{ $poll_rep_defined_mr{$oid} } if not %{ $poll_rep_mr_defined{ $poll_rep_defined_mr{$oid} } };
                            my $new_poll_rep_defined_mr = $poll_rep_defined_mr_initial{$oid} - $branch_cnt;
                            $poll_rep_defined_mr{$oid} = $new_poll_rep_defined_mr;
                            $poll_rep_mr_defined{$new_poll_rep_defined_mr}{$oid} = undef;
                        } else {

                            # $current_query_branch_cnt = 0
                            delete $poll_rep_mr_defined{ $poll_rep_defined_mr{$oid} }{$oid};
                            delete $poll_rep_mr_defined{ $poll_rep_defined_mr{$oid} } if not %{ $poll_rep_mr_defined{ $poll_rep_defined_mr{$oid} } };
                            delete $poll_rep_defined_mr{$oid};
                            $poll_rep_as_nrepd{$oid} = undef;
                        }
                    } else {
                        delete $poll_rep_mr_defined{ $poll_rep_defined_mr{$oid} }{$oid};
                        delete $poll_rep_mr_defined{ $poll_rep_defined_mr{$oid} } if not %{ $poll_rep_mr_defined{ $poll_rep_defined_mr{$oid} } };
                        my $new_poll_rep_defined_mr = $poll_rep_defined_mr_initial{$oid} - $branch_cnt;
                        $poll_rep_defined_mr{$oid}                           = $new_poll_rep_defined_mr;
                        $poll_rep_mr_defined{$new_poll_rep_defined_mr}{$oid} = undef;
                        @branch_keys_sorted                                  = oid_sort( keys %branch_h ) if $branch_keys_is_not_sorted;
                        $poll_rep_oid{$oid}{start}                           = $oid . "." . $branch_keys_sorted[-1];
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
            for my $oid (@allrep_oids) {
                my %branch_hml = deeph_find_branch_h( $oid, \%deep_h );
                my %branch_h   = deeph_flatten_h( \%branch_hml );

                if ( defined $poll_rep_undefined_mr{$oid} or defined $poll_rep_defined_mr{$oid} or defined $poll_rep_as_nrepd{$oid} ) {

                    if ( scalar %branch_h and ( scalar keys %branch_h < $poll_rep_defined_mr_initial{$oid} ) ) {

                        my @branch_key_sorted = oid_sort( keys %branch_h );
                        $data_out{oids}{snmp_retry}{$oid}{start} = $branch_key_sorted[-1];
                        if ( defined $data_in{snmp_retry}{$oid}{left_repetitions} ) {

                            my $idx = bigger_elem_idx( \@branch_key_sorted, $data_in{snmp_retry}{$oid}{start} );
                            if ( defined $idx ) {
                                $data_out{oids}{snmp_retry}{$oid}{left_repetitions} = $data_in{snmp_retry}{$oid}{left_repetitions} - ( scalar keys %branch_h ) + $idx;
                            } else {
                                $data_out{oids}{snmp_retry}{$oid}{left_repetitions} = $data_in{snmp_retry}{$oid}{left_repetitions};
                            }
                        } else {
                            $data_out{oids}{snmp_retry}{$oid}{left_repetitions} = ( $poll_rep_defined_mr_initial{$oid} - ( scalar keys %branch_h ) );
                        }
                    } elsif ( defined $data_in{snmp_retry}{$oid}{start} ) {
                        $data_out{oids}{snmp_retry}{$oid}{start}            = $data_in{snmp_retry}{$oid}{start};
                        $data_out{oids}{snmp_retry}{$oid}{left_repetitions} = $data_in{snmp_retry}{$oid}{left_repetitions} if defined $data_in{snmp_retry}{$oid}{left_repetitions};
                    }    # no else as if branch if empty this will be detected later

                }
            }

            # Walking is finished
            # But it has timed out, so it will probably retry
            $data_out{oids}{snmp_input}{stats}{snmptry_cur_duration} = time() - $snmpwalk_start_time;
            if ($has_timed_out) {
                $data_out{snmp_errorstr} = "Timeout";
                $data_out{snmp_errornum} = -24;
            } else {

                # defined min duration if not already
                $data_out{oids}{snmp_input}{stats}{snmptry_min_duration}{$snmpwalk_mode} //= $data_out{oids}{snmp_input}{stats}{snmptry_cur_duration};

                # Slowly increase the min duration by 0.01 sec
                $data_out{oids}{snmp_input}{stats}{snmptry_min_duration}{$snmpwalk_mode} += 0.01;

                # if 0 the smnpwalk is at it first try: the normal case
                if ($is_try1) {
                    if ($is_optim_cycle) {
                        if (   ( not defined $data_out{oids}{snmp_input}{stats}{snmptry_min_duration}{$snmpwalk_mode} )
                            or ( $data_out{oids}{snmp_input}{stats}{snmptry_min_duration}{$snmpwalk_mode} > $data_out{oids}{snmp_input}{stats}{snmptry_cur_duration} ) )
                        {
                            $data_out{oids}{snmp_input}{stats}{snmptry_min_duration}{$snmpwalk_mode} = $data_out{oids}{snmp_input}{stats}{snmptry_cur_duration};
                        }
                        @{ $data_out{oids}{snmp_input}{stats}{best_3_snmpwalk_modes} } = ();
                        my $i = 0;
                        for my $best_snmpwalk_mode ( sort { $data_out{oids}{snmp_input}{stats}{snmptry_min_duration}{$a} <=> $data_out{oids}{snmp_input}{stats}{snmptry_min_duration}{$b} } keys %{ $data_out{oids}{snmp_input}{stats}{snmptry_min_duration} } ) {
                            ++$i;
                            push @{ $data_out{oids}{snmp_input}{stats}{best_3_snmpwalk_modes} }, $best_snmpwalk_mode;    # epsf
                            $data_out{snmp_msg}{ ++$snmp_msg_count } = "Optim snmpwalk_mode:$best_snmpwalk_mode snmptry_min_duration: $data_out{oids}{snmp_input}{stats}{snmptry_min_duration}{$best_snmpwalk_mode}" if $g{debug};
                            last if $i == 3;

                        }

                        # Calc a timeout value: Timed out quickly
                        if ( $i == 3 ) {

                            # 2 x the worst value (or 2,3 time the best?)
                            $data_out{oids}{snmp_input}{snmptimeout} = $data_out{oids}{snmp_input}{stats}{snmptry_min_duration}{ $data_out{oids}{snmp_input}{stats}{best_3_snmpwalk_modes}[-1] } * 1.2;

                            # minimum 3 sec
                            if ( $data_out{oids}{snmp_input}{snmptimeout} < 3 ) {
                                $data_out{oids}{snmp_input}{snmptimeout} = 3;

                                # max global timeout
                            } elsif ( $data_out{oids}{snmp_input}{snmptimeout} > $g{snmptimeout} ) {
                                $data_out{oids}{snmp_input}{snmptimeout} = $g{timeout};
                            }
                        }
                    }

                    # Successfull Cycle in 1 try only
                    if ( $data_out{oids}{snmp_input}{stats}{snmptry_cur_duration} < $data_out{oids}{snmp_input}{stats}{snmptry_min_duration}{$snmpwalk_mode} ) {
                        $data_out{oids}{snmp_input}{stats}{snmptry_min_duration}{$snmpwalk_mode} = $data_out{oids}{snmp_input}{stats}{snmptry_cur_duration};
                        $data_out{oids}{snmp_input}{snmpwalk_mode} = $snmpwalk_mode;
                    }
                }
                $data_out{snmp_errornum} = 0;
            }

            # current cnt = max repetition if we car in successfully complete run in 1 try
            # 1. 1 first try
            # 2. There is no retry
            for my $oid (@allrep_oids) {
                if ( not( exists $data_out{oids}{snmp_retry}{$oid} and exists $data_out{oids}{snmp_retry}{$oid}{left_repetitions} ) and $is_try1 ) {
                    if ( defined $data_in{oids}{$oid}{max_repetitions} and $data_in{oids}{$oid}{max_repetitions} != $poll_rep_oid{$oid}{cnt} and $poll_rep_oid{$oid}{cnt} != 0 ) {
                        $data_out{snmp_msg}{ ++$snmp_msg_count } = "Oid: $oid max repeater changed old: $data_in{oids}{$oid}{max_repetitions} new: $poll_rep_oid{$oid}{cnt}";
                    }
                    $data_out{oids}{snmp_input}{oids}{$oid}{max_repetitions} = $poll_rep_oid{$oid}{cnt} if ( defined $poll_rep_oid{$oid}{cnt} ) and $poll_rep_oid{$oid}{cnt} > 0;
                }
            }
            for my $oid ( %{ $data_in{oids} } ) {
                if ( ( not exists $data_out{oids}{snmp_input}{oids}{$oid} ) or ( not exists $data_out{oids}{snmp_input}{oids}{$oid}{max_repetitions} ) ) {
                    if ( ( exists $data_in{oids}{$oid}{max_repetitions} ) and $data_in{oids}{$oid}{max_repetitions} > 0 ) {
                        $data_out{oids}{snmp_input}{oids}{$oid}{max_repetitions} = $data_in{oids}{$oid}{max_repetitions};
                    }
                }
            }
            send_data( $sock, \%data_out );
            next DEVICE;

        } elsif ( ( ( ( $g{snmpeng} eq 'snmp' ) or ( $g{snmpeng} eq 'auto' ) ) and ( $snmp_ver eq '2' or $snmp_ver eq '2c' ) ) or $snmp_ver eq '3' ) {
            eval { require SNMP; };
            if ($@) {
                do_log( "SNMP is not installed: $@ yum install net-snmp or apt install snmp", WARN, $fork_num );
            } else {

                #create shortcut
                my $device            = $data_in{dev};
                my $snmp_max_repeater = $data_in{snmp_max_repeater};

                # Get SNMP variables
                my %snmpvars;
                $snmpvars{Device}     = $device;
                $snmpvars{RemotePort} = $data_in{port} // 161;                                                      # Default to 161 if not specified
                $snmpvars{DestHost}   = ( defined $data_in{ip} and $data_in{ip} ne '' ) ? $data_in{ip} : $device;
                my $snmptimeout = $data_in{snmptimeout};
                $snmpvars{Timeout}       = $snmptimeout * 1000000;
                $snmpvars{Retries}       = 0;
                $snmpvars{UseNumeric}    = 1;
                $snmpvars{NonIncreasing} = 0;
                $snmpvars{Version}       = $snmp_ver;

                # We store the security name for v3 also in cid so we keep the same data format
                $snmpvars{Community} = $data_in{cid}       if defined $data_in{cid};
                $snmpvars{SecName}   = $data_in{secname}   if defined $data_in{secname};
                $snmpvars{SecLevel}  = $data_in{seclevel}  if defined $data_in{seclevel};
                $snmpvars{AuthProto} = $data_in{authproto} if defined $data_in{authproto};
                $snmpvars{AuthPass}  = $data_in{authpass}  if defined $data_in{authpass};
                $snmpvars{PrivProto} = $data_in{privproto} if defined $data_in{privproto};
                $snmpvars{PrivPass}  = $data_in{privpass}  if defined $data_in{privpass};

                # Establish SNMP session
                # $SNMP::debugging = 2;
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
                                    $snmp_errorstr = "Empty or no answer from $device";
                                    $data_out{snmp_errorstr} = $snmp_errorstr;
                                    send_data( $sock, \%data_out );
                                    next DEVICE;
                                } else {
                                    $data_out{oids}{snmp_polled}{'1.3.6.1.2.1.1.1.0'}{'val'}  = $disco_result;
                                    $data_out{oids}{snmp_polled}{'1.3.6.1.2.1.1.1.0'}{'time'} = time;
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

                if ( ( not defined $session ) ) {

                    unless ($!) {

                        # Couldn't look up the host, so set the error code
                        # especially for this.
                        $snmp_errorstr = "SNMP session not started and no system error";

                    } else {

                        # Some system-level error occurred.  Handle a few simple
                        # resource problems by (hopefully) waiting for things to
                        # subside, and retry later.
                        #
                        # Copy error string, and force numeric errno
                        $snmp_errorstr = '' . $!;
                        $snmp_errornum = $! + 0;
                        if (( $snmp_errornum == EINTR )  ||    # Interrupted system call
                            ( $snmp_errornum == EAGAIN ) ||    # Resource temp. unavailable
                            ( $snmp_errornum == ENOMEM ) ||    # No memory (temporary)
                            ( $snmp_errornum == ENFILE ) ||    # Out of file descriptors
                            ( $snmp_errornum == EMFILE )
                            )                                  # Too many open fd's
                        {
                            $snmp_errorstr .= "(Ressource busy)";

                        } else {
                            $snmp_errorstr .= "(?)";

                        }
                        $snmp_errorstr = "SNMP session not started sysErr: $snmp_errorstr";

                    }
                    $data_out{snmp_errorstr} = $snmp_errorstr;
                    $data_out{snmp_errornum} = $snmp_errornum;
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

                        my $poll_oid           = \%{ $snmp_persist_storage{$device}{'poll_oid'} };
                        my $uniq_rep_poll_oid  = \%{ $snmp_persist_storage{$device}{'uniq_rep_poll_oid'} };
                        my $uniq_nrep_poll_oid = \%{ $snmp_persist_storage{$device}{'uniq_nrep_poll_oid'} };
                        my $rep_count          = \${ $snmp_persist_storage{$device}{'rep_count'} };
                        my $nrep_count         = \${ $snmp_persist_storage{$device}{'nrep_count'} };
                        my $oid_count          = \${ $snmp_persist_storage{$device}{'oid_count'} };
                        my $path_is_slow       = \${ $snmp_persist_storage{$device}{'path_is_slow'} };
                        my $run_count          = \${ $snmp_persist_storage{$device}{'run_count'} };

                        #my $workaround         = \${ $snmp_persist_storage{$device}{'workaround'} };
                        my $workaround;
                        my $polling_time_cur = \${ $snmp_persist_storage{$device}{'polling_time_cur'} };
                        my $polling_time_max = \${ $snmp_persist_storage{$device}{'polling_time_max'} };
                        my $polling_time_min = \${ $snmp_persist_storage{$device}{'polling_time_min'} };
                        my $polling_time_avg = \${ $snmp_persist_storage{$device}{'polling_time_avg'} };

                        # Count the number of run
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
                        do_log( "Doing bulkwalk", DEBUG, $fork_num );
                        my @nrresp;

                    SNMP_START:
                        my $snmp_timestart = time();

                        # THE NORMAL CASE!
                        @nrresp = $session->bulkwalk( ${$nrep_count}, $snmp_max_repeater // ${$rep_count}, $nrvars );
                        if ( $session->{ErrorNum} ) {
                            if ( $session->{ErrorNum} == -24 ) {

                                # Timeout
                                if ($discover) {
                                    $data_out{snmp_msg}{ ++$snmp_msg_count } = "Discovery cycle: Trying to recover from timeout";
                                    $workaround                              = defined $workaround ? $workaround + 1 : 1;
                                    $snmp_max_repeater                       = undef;
                                    if ( $workaround == 1 ) {
                                        $snmp_max_repeater                              = 0;
                                        $data_out{snmp_msg}{ ++$snmp_msg_count }        = "Try workaround:$workaround, override max repeater value with 0";
                                        $data_out{data_out}{snmp_perm}{snmp_workaround} = 1;
                                        $session->{ErrorNum}                            = undef;
                                        $session->{ErrorStr}                            = undef;
                                        goto SNMP_START;
                                    }

                                    # cleanup workaround
                                    $data_out{oids}{snmp_perm}{snmp_workaround} = undef;
                                }

                                # case1: no answer but alive and should answer
                            } elsif ( $session->{ErrorNum} == -58 ) {
                                do_log( "End of mib on device $device: $session->{ErrorStr} ($session->{ErrorNum})", ERROR, $fork_num );
                            } elsif ( $session->{ErrorNum} == -35 ) {
                                do_log( "Auth Failure on device $device: $session->{ErrorStr} ($session->{ErrorNum})", ERROR, $fork_num );
                            } else {
                                do_log( "Cannot do bulkwalk on device $device: $session->{ErrorStr} ($session->{ErrorNum})", ERROR, $fork_num );
                            }
                            $data_out{snmp_errorstr} = $session->{ErrorStr};
                            $data_out{snmp_errornum} = $session->{ErrorNum};
                        } else {

                            # we havent any error, so it can be a success
                            $data_out{snmp_errornum} = 0;
                        }
                        if ( ( ( scalar @nrresp ) == 0 ) or ( ( ( scalar @nrresp ) == 1 ) and not( scalar @{ $nrresp[0] // [] } ) ) ) {
                            $data_out{oids}{snmp_input}{discover} = $discover if defined $discover;
                            if ( $data_out{snmp_errornum} != 0 ) {
                                undef $session;
                            } else {
                                $snmp_errorstr           = "Empty SNMP answer no error";
                                $data_out{snmp_errorstr} = $snmp_errorstr;
                                $data_out{snmp_errornum} = undef;
                                undef $session;
                            }

                        } else {

                            # Now that the polling is done we have to process the answers
                            my @oids = ( keys %{ $data_in{'reps'} }, keys %{ $data_in{'nonreps'} } );
                            ${$oid_count} = scalar @oids;

                            # Check first that we have some answer
                            $vbarr_counter = 0;

                        OID: foreach my $oid_wo_dot (@oids) {    # INVERSING OID AND VBARR loop should increase perf)
                                my $found = 0;
                                my $oid   = "." . $oid_wo_dot;
                                $vbarr_counter = 0;
                            VBARR: foreach my $vbarr (@nrresp) {

                                    # Check first that we have some answer or skip it
                                    if ( !scalar @{ $vbarr // [] } ) {
                                        $vbarr_counter++;
                                        next;
                                    }

                                    # Determine which OID this request queried.  This is kept in the VarList
                                    # reference passed to bulkwalk().
                                    my $polled_oid          = ${ $poll_oid->{$oid}{oid} };       # Always the same as the SNMP POLLED OID: poid=spoid
                                    my $stripped_oid        = substr $oid, 1;
                                    my $stripped_polled_oid = substr $polled_oid, 1;
                                    my $snmp_poll_oid       = $$nrvars[$vbarr_counter]->tag();
                                    my $leaf_table_found    = 0;

                                    if ( not defined $snmp_poll_oid ) {
                                        do_log( "$snmp_poll_oid not defined for device $device, oid $oid", WARN, $fork_num );
                                        @remain_oids = push( @remain_oids, $oid );
                                        ${$path_is_slow} = 1;
                                        $vbarr_counter++;
                                        next;
                                    }
                                    foreach my $nrv (@$vbarr) {
                                        my $snmp_oid  = $nrv->name;
                                        my $snmp_val  = $nrv->val;
                                        my $snmp_type = $nrv->type;
                                        if ( $snmp_poll_oid eq $oid ) {
                                            do_log( "oid:$oid poid:$polled_oid soid:$snmp_oid spoid:$snmp_poll_oid svoid:$snmp_val stoid:$snmp_type", DEBUG, $fork_num ) if $g{trace};
                                            my $leaf = substr( $snmp_oid, length($oid) + 1 );
                                            $data_out{oids}{snmp_polled}{$stripped_oid}{$leaf}{val}  = $snmp_val;
                                            $data_out{oids}{snmp_polled}{$stripped_oid}{$leaf}{time} = time;
                                            $leaf_table_found++;
                                        } elsif ( $snmp_oid eq $oid ) {
                                            $found = 1;
                                            do_log( "oid:$oid poid:$polled_oid soid:$snmp_oid spoid:$snmp_poll_oid svoid:$snmp_val stoid:$snmp_type", TRACE, $fork_num ) if $g{debug};
                                            $data_out{oids}{snmp_polled}{$stripped_oid}{val}  = $snmp_val;
                                            $data_out{oids}{snmp_polled}{$stripped_oid}{time} = time;
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
                            }

                            # Store permanently workaround value if any
                            if ( defined $snmp_max_repeater ) {

                                $data_out{oids}{snmp_input}{snmp_max_repeater} = $snmp_max_repeater;
                            }
                            if ( $oid_found == ${$oid_count} ) {

                                # We have all our answer cooooo!
                                $data_out{oids}{snmp_input}{snmpwalk_duration}    = time() - $snmp_timestart;
                                $data_out{oids}{snmp_input}{snmptry_min_duration} = $data_out{oids}{snmp_input}{snmpwalk_duration};    # Not really correct but enaugh for now to have a value
                                $data_out{oids}{snmp_input}{snmptimeout}          = $snmptimeout;

                            } else {

                                # houston we have a problem
                                ${$path_is_slow} = 1;
                                ############### do something to recover ##############START
                                foreach my $oid (@remain_oids) {
                                    do_log( "Unable to poll $oid on device $device", ERROR, $fork_num );
                                }
                                ############### do something to recover ##############END
                            }

                        }
                    }
                    send_data( $sock, \%data_out );
                    undef $session;
                    next DEVICE;
                }
            }

            # Whoa, we don't support this version of SNMP
        } else {
            $snmp_errorstr = "Unsupported SNMP version for $data_in{dev} ($snmp_ver)";
            $data_out{snmp_errorstr} = $snmp_errorstr;
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
    my $serialized = nfreeze($data_out) . "\nEOF\n";

    $sock->print($serialized);

    #syswrite( $sock, $serialized, length($serialized) ); # Seems to crash master
}

# Reap dead forks
sub REAPER {
    my $fork;
    while ( ( $fork = waitpid( -1, WNOHANG ) ) > 0 ) { sleep 1 }
    $SIG{CHLD} = \&REAPER;
}

sub deeph_insert_oidval_h {
    my ( $oidval, $deep_href ) = @_;
    $oidval = substr( $oidval, 1 ) if substr( $oidval, 0, 1 ) eq '.';
    my $i    = index( $oidval, ":" );
    my $oid  = substr( $oidval, 0, $i );
    my $val  = substr( $oidval, $i + 1 );
    my @keys = split /\./, $oid;
    push @keys, '';    # add a key (empty) that will store the value
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
        } else {
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
        } else {
            if ( ref $deep_href->{$key} ne 'HASH' ) {

                #  if (defined $deep_href) {
                return substr( $poid, 1 ) . "." . $key;
            } else {
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

#sub deeph_flatten_h {
#    return %{ deeph_flatten_href(@_) };
#}

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
        } else {
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

sub snmpgetbulk ($$$@) {
    my ( $host, $nr, $mr, @vars ) = @_;

    #my ($hostip, $snmp_cid, $snmp_port, $query_timeout, 1, $backoff, $snmp_ver, $nr, $mr, @vars ) = @_;
    my ( @enoid, $var, $response, $bindings, $binding );
    my ( $value, $upoid, $oid, @retvals );
    my ($noid);
    my $session;

    @retvals = ();
    $session = &snmpopen( $host, 0, \@vars );

    #$session = &snmpopen($hostip, $snmp_cid, $snmp_port, $query_timeout, 1, $backoff, $snmp_ver , 0, \@vars );
    if ( !defined($session) ) {
        carp "SNMPGETBULK Problem for $host\n"
            unless ( $SNMP_Session::suppress_warnings > 1 );
        return @retvals;
    }
    @enoid = &toOID(@vars);
    return @retvals if ( $#enoid < 0 );
    undef @vars;
    foreach $noid (@enoid) {
        $upoid = pretty_print($noid);
        push( @vars, $upoid );
    }
    if ( $session->getbulk_request_response( $nr, $mr, @enoid ) ) {
        $response = $session->pdu_buffer;
        ($bindings) = $session->decode_get_response($response);
        while ($bindings) {
            ( $binding, $bindings ) = decode_sequence($bindings);
            ( $oid,     $value )    = decode_by_template( $binding, "%O%@" );
            my $tempo = pretty_print($oid);
            $BER::errmsg = undef;
            my $tempv = pretty_print($value);
            if ( defined $BER::errmsg ) {

                # Not sur this is the way to do it.
                # The responding entity returns a response PDU with an error-status of genErr
                # and a value (did not find for now this value: TODO)
                # in the error-index field that is the index of the problem object in the variable-bindings field.
                if ( $BER::errmsg eq 'Exception code: endOfMibView' ) {
                    $tempv = "endOfMibView";
                }
                $SNMP_Session::errmsg = $BER::errmsg;
            }
            push @retvals, "$tempo:$tempv";
        }
        return @retvals;
    } else {
        return ();
    }
}
#
#  Given an OID in either ASN.1 or mixed text/ASN.1 notation, return an
#  encoded OID.
#
#  A simplified version of this function
sub toOID(@) {
    my (@vars) = @_;
    my @retvar;
    foreach my $var (@vars) {
        push( @retvar, encode_oid( split( /\./, $var ) ) );
    }
    return @retvar;
}
#
# A restricted snmpgetnext.
#
sub snmpgetnext ($@) {
    my ( $host, @vars ) = @_;
    my ( @enoid, $var, $response, $bindings, $binding );
    my ( $value, $upoid, $oid, @retvals );
    my ($noid);
    my $session;

    @retvals = ();
    $session = &snmpopen( $host, 0, \@vars );
    if ( !defined($session) ) {
        carp "SNMPGETNEXT Problem for $host\n"
            unless ( $SNMP_Session::suppress_warnings > 1 );
        return wantarray ? @retvals : undef;
    }

    @enoid = &toOID(@vars);
    if ( $#enoid < 0 ) {
        return wantarray ? @retvals : undef;
    }
    undef @vars;
    undef @retvals;
    foreach $noid (@enoid) {
        $upoid = pretty_print($noid);
        push( @vars, $upoid );
    }
    if ( $session->getnext_request_response(@enoid) ) {
        $response = $session->pdu_buffer;
        ($bindings) = $session->decode_get_response($response);
        while ($bindings) {
            ( $binding, $bindings ) = decode_sequence($bindings);
            ( $oid,     $value )    = decode_by_template( $binding, "%O%@" );
            my $tempo = pretty_print($oid);
            my $tempv = pretty_print($value);    # TODO: Add same test as bulk walk
            push @retvals, "$tempo:$tempv";
        }
        return wantarray ? @retvals : $retvals[0];
    } else {
        $var = join( ' ', @vars );
        carp "SNMPGETNEXT Problem for $var on $host\n"
            unless ( $SNMP_Session::suppress_warnings > 1 );
        return wantarray ? @retvals : undef;
    }
}
#
# Adapted with minimal changes
#
sub snmpopen ($$$) {
    my ( $host, $type, $vars ) = @_;
    my ( $nhost, $port, $community, $lhost, $lport, $nlhost );
    my ( $timeout, $retries, $backoff, $version );
    my $v4onlystr;

    $type      = 0 if ( !defined($type) );
    $community = "public";
    $nlhost    = "";

    ( $community, $host ) = ( $1, $2 ) if ( $host =~ /^(.*)@([^@]+)$/ );

    # We can't split on the : character because a numeric IPv6
    # address contains a variable number of :'s
    my $opts;
    if ( ( $host =~ /^(\[.*\]):(.*)$/ ) or ( $host =~ /^(\[.*\])$/ ) ) {

        # Numeric IPv6 address between [] (What about ipv6 not in bracket?)
        ( $host, $opts ) = ( $1, $2 );
    } else {

        # Hostname or numeric IPv4 address
        ( $host, $opts ) = split( ':', $host, 2 );
    }
    ( $port, $timeout, $retries, $backoff, $version, $v4onlystr ) = split( ':', $opts, 6 )
        if ( defined($opts) and ( length $opts > 0 ) );
    undef($version) if ( defined($version) and length($version) <= 0 );
    $v4onlystr = ""  unless defined $v4onlystr;
    $version   = '1' unless defined $version;
    if ( defined($port) and ( $port =~ /^([^!]*)!(.*)$/ ) ) {
        ( $port, $lhost ) = ( $1, $2 );
        $nlhost = $lhost;
        ( $lhost, $lport ) = ( $1, $2 ) if ( $lhost =~ /^(.*)!(.*)$/ );
        undef($lhost) if ( defined($lhost) and ( length($lhost) <= 0 ) );
        undef($lport) if ( defined($lport) and ( length($lport) <= 0 ) );
    }
    undef($port) if ( defined($port) and length($port) <= 0 );
    $port  = 162 if ( $type == 1 and !defined($port) );
    $nhost = "$community\@$host";
    $nhost .= ":" . $port if ( defined($port) );

    if (   ( !defined($::session) )
        or ( $::session_host ne $nhost )
        or ( $::session_version ne $version )
        or ( $::session_lhost ne $nlhost )
        or ( $::session_ipv4only ne $v4onlystr ) )
    {
        if ( defined($::session) ) {
            $::session->close();
            undef $::session;
            undef $::session_host;
            undef $::session_version;
            undef $::session_lhost;
            undef $::session_ipv4only;
        }
        $::session
            = ( $version =~ /^2c?$/i )
            ? SNMPv2c_Session->open( $host, $community, $port, $SNMP_Session::max_pdu_len, $lport, undef, $lhost, ( $v4onlystr eq 'v4only' ) ? 1 : 0 )
            : SNMP_Session->open( $host, $community, $port, $SNMP_Session::max_pdu_len, $lport, undef, $lhost, ( $v4onlystr eq 'v4only' )    ? 1 : 0 );
        ( $::session_host = $nhost, $::session_version = $version, $::session_lhost = $nlhost, $::session_ipv4only = $v4onlystr ) if defined($::session);
    }
    if ( defined($::session) ) {
        if ( ref $vars->[0] eq 'HASH' ) {
            my $opts = shift @$vars;
            foreach $type ( keys %$opts ) {
                do_log("type = $type");
                if ( $type eq 'return_array_refs' ) {
                    $::session_return_array_refs = $opts->{$type};
                } elsif ( $type eq 'return_hash_refs' ) {
                    $::session_return_hash_refs = $opts->{$type};
                } else {
                    if ( exists $::session->{$type} ) {
                        if ( $type eq 'timeout' ) {
                            $::session->set_timeout( $opts->{$type} );
                        } elsif ( $type eq 'retries' ) {
                            $::session->set_retries( $opts->{$type} );
                        } elsif ( $type eq 'backoff' ) {
                            $::session->set_backoff( $opts->{$type} );
                        } else {
                            $::session->{$type} = $opts->{$type};
                        }
                    } else {
                        carp "SNMPopen Unknown SNMP Option Key '$type'\n"
                            unless ( $SNMP_Session::suppress_warnings > 1 );
                    }
                }
            }
        }
        $::session->set_timeout($timeout)
            if ( defined($timeout) and ( length($timeout) > 0 ) );
        $::session->set_retries($retries)
            if ( defined($retries) and ( length($retries) > 0 ) );
        $::session->set_backoff($backoff)
            if ( defined($backoff) and ( length($backoff) > 0 ) );
    }
    return $::session;
}
#
# Adapted with minimal changes
#
sub snmpopen1 ($$$) {
    my ( $session, $session_host, $session_version, $session_lhost, $session_ipv4only, $host, $type, $vars ) = @_;
    my ( $session_return_array_refs, $session_return_hash_refs );
    my ( $nhost, $port, $community, $lhost, $lport, $nlhost );
    my ( $timeout, $retries, $backoff, $version );
    my $v4onlystr;

    $type      = 0 if ( !defined($type) );
    $community = "public";
    $nlhost    = "";

    ( $community, $host ) = ( $1, $2 ) if ( $host =~ /^(.*)@([^@]+)$/ );

    # We can't split on the : character because a numeric IPv6
    # address contains a variable number of :'s
    my $opts;
    if ( ( $host =~ /^(\[.*\]):(.*)$/ ) or ( $host =~ /^(\[.*\])$/ ) ) {

        # Numeric IPv6 address between []
        ( $host, $opts ) = ( $1, $2 );
    } else {

        # Hostname or numeric IPv4 address
        ( $host, $opts ) = split( ':', $host, 2 );
    }
    ( $port, $timeout, $retries, $backoff, $version, $v4onlystr ) = split( ':', $opts, 6 )
        if ( defined($opts) and ( length $opts > 0 ) );
    undef($version) if ( defined($version) and length($version) <= 0 );
    $v4onlystr = ""  unless defined $v4onlystr;
    $version   = '1' unless defined $version;
    if ( defined($port) and ( $port =~ /^([^!]*)!(.*)$/ ) ) {
        ( $port, $lhost ) = ( $1, $2 );
        $nlhost = $lhost;
        ( $lhost, $lport ) = ( $1, $2 ) if ( $lhost =~ /^(.*)!(.*)$/ );
        undef($lhost) if ( defined($lhost) and ( length($lhost) <= 0 ) );
        undef($lport) if ( defined($lport) and ( length($lport) <= 0 ) );
    }
    undef($port) if ( defined($port) and length($port) <= 0 );
    $port  = 162 if ( $type == 1 and !defined($port) );
    $nhost = "$community\@$host";
    $nhost .= ":" . $port if ( defined($port) );

    if (   ( !defined($session) )
        or ( $session_host ne $nhost )
        or ( $session_version ne $version )
        or ( $session_lhost ne $nlhost )
        or ( $session_ipv4only ne $v4onlystr ) )
    {
        if ( defined($session) ) {
            $session->close();
            undef $session;
            undef $session_host;
            undef $session_version;
            undef $session_lhost;
            undef $session_ipv4only;
        }
        $session
            = ( $version =~ /^2c?$/i )
            ? SNMPv2c_Session->open( $host, $community, $port, $SNMP_Session::max_pdu_len, $lport, undef, $lhost, ( $v4onlystr eq 'v4only' ) ? 1 : 0 )
            : SNMP_Session->open( $host, $community, $port, $SNMP_Session::max_pdu_len, $lport, undef, $lhost, ( $v4onlystr eq 'v4only' )    ? 1 : 0 );
        ( $session_host = $nhost, $session_version = $version, $session_lhost = $nlhost, $session_ipv4only = $v4onlystr ) if defined($session);
    }
    if ( defined($session) ) {
        if ( ref $vars->[0] eq 'HASH' ) {
            my $opts = shift @$vars;
            foreach $type ( keys %$opts ) {
                if ( $type eq 'return_array_refs' ) {
                    $session_return_array_refs = $opts->{$type};
                } elsif ( $type eq 'return_hash_refs' ) {
                    $session_return_hash_refs = $opts->{$type};
                } else {
                    if ( exists $session->{$type} ) {
                        if ( $type eq 'timeout' ) {
                            $session->set_timeout( $opts->{$type} );
                        } elsif ( $type eq 'retries' ) {
                            $session->set_retries( $opts->{$type} );
                        } elsif ( $type eq 'backoff' ) {
                            $session->set_backoff( $opts->{$type} );
                        } else {
                            $session->{$type} = $opts->{$type};
                        }
                    } else {
                        carp "SNMPopen Unknown SNMP Option Key '$type'\n"
                            unless ( $SNMP_Session::suppress_warnings > 1 );
                    }
                }
            }
        }
        $session->set_timeout($timeout)
            if ( defined($timeout) and ( length($timeout) > 0 ) );
        $session->set_retries($retries)
            if ( defined($retries) and ( length($retries) > 0 ) );
        $session->set_backoff($backoff)
            if ( defined($backoff) and ( length($backoff) > 0 ) );
    }
    return $session;
}
#
# A restricted snmpget.
#
sub snmpget ($@) {
    my ( $host, @vars ) = @_;
    my ( @enoid, $var, $response, $bindings, $binding, $value, $oid, @retvals );
    my $session;
    @retvals = ();
    $session = &snmpopen( $host, 0, \@vars );
    if ( !defined($session) ) {
        carp "SNMPGET Problem for $host\n"
            unless ( $SNMP_Session::suppress_warnings > 1 );
        return wantarray ? @retvals : undef;
    }
    @enoid = &toOID(@vars);
    if ( $#enoid < 0 ) {
        return wantarray ? @retvals : undef;
    }
    if ( $session->get_request_response(@enoid) ) {
        $response = $session->pdu_buffer;
        ($bindings) = $session->decode_get_response($response);
        while ($bindings) {
            ( $binding, $bindings ) = decode_sequence($bindings);
            ( $oid,     $value )    = decode_by_template( $binding, "%O%@" );
            my $tempo = pretty_print($value);
            push @retvals, $tempo;
        }
        return wantarray ? @retvals : $retvals[0];
    }
    $var = join( ' ', @vars );
    carp "SNMPGET Problem for $var on $host\n"
        unless ( $SNMP_Session::suppress_warnings > 1 );
    return wantarray ? @retvals : undef;
}

sub merge_h {    # Stolen from Mash Merge Simple, Thanks!
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
        } else {
            $merge{$key} = $right->{$key};
        }
    }
    return \%merge;
}

sub bigger_elem_idx {
    my ( $arr, $elem ) = @_;
    my $idx;
    for my $i ( 0 .. $#$arr ) {
        if ( $arr->[$i] > $elem ) {
            $idx = $i;
            last;
        }
    }
    return $idx;
}

