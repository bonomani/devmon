package dm_msg;
require Exporter;
@ISA    = qw(Exporter);
@EXPORT = qw(send_msgs);

#    Devmon: An SNMP data collector & page generator for the
#    Xymon network monitoring systems
#    Copyright (C) 2005-2006  Eric Schwimmer
#
#    $URL: svn://svn.code.sf.net/p/devmon/code/trunk/modules/dm_msg.pm $
#    $Revision: 235 $
#    $Id: dm_msg.pm 235 2012-08-03 10:32:02Z buchanmilne $
#
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.  Please see the file named
#    'COPYING' that was included with the distrubition for more details.

# Modules
use strict;
use Socket;
use POSIX qw/ strftime /;
use dm_config qw(FATAL ERROR WARN INFO DEBUG TRACE);
use dm_config;
use Time::HiRes qw(time);
use Data::Dumper;

# Our global variable hash
use vars qw(%g);
*g = \%dm_config::g;

# Send our test results to the Xymon server
sub send_msgs {
    do_log( 'Running send_msgs()', DEBUG ) if $g{debug};
    for my $output ( keys %{ $g{output} } ) {
        if ( $g{output}{$output}{protocol} eq 'xymon' ) {

            if ( $g{output}{$output}{target} eq 'stdout' ) {
                send_xymon_msgs_to_stdout();
            } else {
                send_xymon_msgs_to_host( $g{output}{$output}{target} );
            }
        } else {

            print $output. "\n";
        }
    }
}

sub send_xymon_msgs_to_stdout {
    $g{msgxfrtime} = time;
    my $nummsg = scalar @{ $g{test_results} };
    do_log( "Sending $nummsg messages to 'xymon://stdout'", INFO );
    if ( defined $g{test_results} ) {
        my $msg = join "\n", @{ $g{test_results} };
        $g{sentmsgsize} = length($msg);
        if ( $g{output}{'xymon://stdout'}{stat} ) {
            $g{msgxfrtime} = time - $g{msgxfrtime};
            $msg .= prepare_xymon_stat_msg('stdout');
        } else {
            $g{msgxfrtime} = time - $g{msgxfrtime};
        }

        # Honor rrd filtering if requested
        if ( not $g{output}{'xymon://stdout'}{rrd} ) {
            $msg =~ s/<!--.*?-->//sg;
        }
        print $msg;
    } else {
        $g{msgxfrtime} = time - $g{msgxfrtime};
    }
}

sub send_xymon_msgs_to_host {
    my $host = shift;
    $g{msgxfrtime}  = time;
    $g{sentmsgsize} = 0;

    #do_log( 'DEBUG MESG: running send_msgs()', 4 ) if $g{debug};
    my $nummsg = scalar @{ $g{test_results} };
    do_log( "Sending $nummsg messages to 'xymon://$host'", INFO );

    # Determine the address we are connecting to
    #my $host = $g{dispserv};
    my $addr = inet_aton($host)
        or do_log( "Can't resolve display server $host ($!)", ERROR )
        and return;
    my $p_addr = sockaddr_in( $g{dispport}, $addr );

    # Print messages to output if requested
    #if ( $g{output} eq 'STDOUT' and defined $g{test_results} ) {
    #    print join "\n", @{ $g{test_results} };

    #TO BE ADDED: PRINT STAT ONLY IF REQUESTED
    #$g{msgxfrtime} = time - $g{msgxfrtime};

    #print dm_stat_msg();
    #   return;
    #}

    my $msg_sent = 0;
    do_log( "Looping through messages for this socket", DEBUG ) if $g{debug};
    my $msg = join "\n", @{ $g{test_results} };
    if ( not $g{output}{ 'xymon://' . $host }{rrd} ) {
        $msg =~ s/<!--.*?-->//sg;
    }

    # Run until we are out of messages to send
SOCKLOOP: while ( @{ $g{test_results} } ) {

        # Rest for a moment so we don't overwhelm our display server
        select undef, undef, undef, $g{msgsleep} / 1000;

        # Open our socket to the host
        do_log( "Opening socket to $host:$g{dispport}", DEBUG ) if $g{debug};
        eval {
            local $SIG{ALRM} = sub { die "Socket timed out\n" };
            alarm 10;
            socket( SOCK, PF_INET, SOCK_STREAM, getprotobyname('tcp') )
                or do_log( "Failed to create socket ($!)", ERROR )
                and $g{msgxfrtime} = time - $g{msgxfrtime}
                and return;
            alarm 0;
            local $SIG{ALRM} = sub { die "Connect timed out\n" };
            alarm 10;
            if ( !connect( SOCK, $p_addr ) ) {
                do_log( "Can't connect to display server $host ($!)", ERROR );
                $g{msgxfrtime} = time - $g{msgxfrtime};
                close SOCK;
                return;
            }
            alarm 0;
        };
        if ($@) {
            do_log( "Timed out connecting to display server: $!", ERROR );
            return;
        }

        # Tell the display server that we are sending a combo msg
        eval {
            local $SIG{ALRM} = sub { die "Print timed out\n" };
            alarm 10;
            print SOCK "combo\n";
            alarm 0;
        };
        if ($@) {
            do_log( "Timed out printing to display server: $!", ERROR );
            close SOCK;
            return;
        }

        # Now print to this socket until we hit the max msg size
        do_log( "Looping through messages to build a combo", DEBUG ) if $g{debug};
        my $msg_size = 0;
    MSGLOOP: while ( $msg_size < $g{msgsize}
            and @{ $g{test_results} } )
        {
            my $msg = shift @{ $g{test_results} };
            $msg_sent++;

            # Make sure this is a valid message
            if ( !defined $msg or $msg eq '' ) {
                do_log( "Trying to send a blank message!", INFO );
                next MSGLOOP;
            }

            # Make sure the message itself isn't too big
            if ( length $msg > $g{msgsize} ) {

                # Nuts, this is a huge message, bigger than our msg size. Well want
                # to send it by itself to minimize how much it gets truncated
                if ( $msg_size == 0 ) {
                    $msg_size = length $msg;

                    # Okay, we are clear, send the message
                    eval {
                        local $SIG{ALRM} = sub { die "Printing message timed out\n" };
                        alarm 10;
                        do_log( "Printing single combo message ($msg_sent of $nummsg), size $msg_size", DEBUG )
                            if $g{debug};
                        print SOCK "$msg\n";
                        do_log( "Finished printing single combo message", DEBUG ) if $g{debug};
                        alarm 0;
                    };
                    if ($@) {
                        do_log( "Timed out printing to display server: $@ - $!", ERROR );
                        close SOCK;
                        return;
                    }

                    # Not an empty combo msg, wait till our new socket is open
                } else {
                    unshift @{ $g{test_results} }, $msg;
                    $msg_sent--;
                }

                # Either way, open a new socket
                $g{sentmsgsize} += $msg_size;
                do_log( "Closing socket, $msg_size sent", DEBUG ) if $g{debug};
                close SOCK;
                next SOCKLOOP;

                # Now make sure that this msg won't cause our current combo msg to
                # exceed the msgsize limit
            } elsif ( $msg_size + length $msg > $g{msgsize} ) {

                # Whoops, looks like it does;  wait for the next socket
                unshift @{ $g{test_results} }, $msg;
                $msg_sent--;
                $g{sentmsgsize} += $msg_size;
                do_log( "Closing socket, $msg_size sent", DEBUG ) if $g{debug};
                close SOCK;
                next SOCKLOOP;

                # Looks good, print the msg
            } else {
                my $thismsgsize = length $msg;
                do_log( "Printing message ($msg_sent of $nummsg), size $thismsgsize to existing combo", DEBUG )
                    if $g{debug};
                eval {
                    local $SIG{ALRM} = sub { die "Printing message timed out\n" };
                    alarm 10;
                    print SOCK "$msg\n";
                    alarm 0;
                };
                if ($@) {
                    do_log( "Timed out printing to display server: $!", ERROR );
                    close SOCK;
                    return;
                }
                $msg_size += length $msg;
                do_log( "Finished printing message to existing combo ($msg_size so far)", DEBUG )
                    if $g{debug};
            }

        }    # End MSGLOOP

        $g{sentmsgsize} += $msg_size;
        do_log( "Closing socket, $msg_size sent", DEBUG ) if $g{debug};
        close SOCK;
    }    # END SOCKLOOP

    $g{msgxfrtime} = time - $g{msgxfrtime};

    # Now send our dm status message !
    if ( $g{output}{"xymon://$host"}{stat} ) {
        my $dm_msg  = prepare_xymon_stat_msg($host);
        my $msgsize = length $dm_msg;
        do_log( "Connecting and sending dm message ($msgsize)", DEBUG ) if $g{debug};
        eval {
            local $SIG{ALRM} = sub { die "Connecting and sending dm message timed out\n" };
            alarm 10;
            socket( SOCK, PF_INET, SOCK_STREAM, getprotobyname('tcp') )
                or do_log( "Failed to create socket ($!)", ERROR )
                and return;
            connect( SOCK, $p_addr )
                or do_log( "Can't connect to display server ($!)", ERROR )
                and return;

            print SOCK "$dm_msg\n";
            close SOCK;
            alarm 0;
        };
        if ($@) {
            do_log( "Timed out connecting and sending dm: $!", ERROR );
            close SOCK;
            return;
        }
    }

    do_log( "Done sending messages", INFO );
}

# Spit out various data about our devmon process
sub prepare_xymon_stat_msg {
    my $host           = shift;
    my $color          = 'green';
    my $this_poll_time = $g{snmppolltime} + $g{testtime} + $g{msgxfrtime};

    #    $this_poll_time = 1 if ($this_poll_time == 0);

    # Show the fraction of the time spent in the various stages of this script,
    # but only if the runtime is long enough to show a meaningfull fraction.
    #
    my ( $snmp_poll_time, $test_time, $msg_xfr_time );
    $snmp_poll_time = sprintf( "%6.2f s %5.2f", $g{snmppolltime}, $g{snmppolltime} / $this_poll_time * 100 ) . ' %';
    $test_time      = sprintf( "%6.2f s %5.2f", $g{testtime},     $g{testtime} / $this_poll_time * 100 ) . ' %';
    $msg_xfr_time   = sprintf( "%6.2f s %5.2f", $g{msgxfrtime},   $g{msgxfrtime} / $this_poll_time * 100 ) . ' %';
    $this_poll_time = sprintf( "%6.2f s",       $this_poll_time );

    # Determine our number of clear msgs sent
    my $num_clear_branches = 0;
    my $num_clear_leaves   = 0;

    for my $dev ( keys %{ $g{devices} } ) {
        for my $oid ( keys %{ $g{devices}{$dev}{oids} } ) {
            if ( ( defined $g{devices}{$dev}{oids}{$oid}{color} ) and ( ref $g{devices}{$dev}{oids}{$oid}{color} ne 'HASH' ) and ( $g{devices}{$dev}{oids}{$oid}{color} eq "clear" ) ) {
                if ( $g{devices}{$dev}{oids}{$oid}{repeat} == 0 ) {
                    ++$num_clear_leaves;
                } else {
                    ++$num_clear_branches;
                }
            }
        }
    }

    my $message = "Devmon, version $g{version}\n\n";
    $message .= "Node name:           $g{nodename}\n";
    $message .= "Node number:         $g{my_nodenum}\n";
    $message .= "Process ID:          $g{mypid}\n\n";
    $message .= "Polled devices:      $g{numdevs}\n";
    $message .= "Polled tests:        $g{numtests}\n";
    $message .= "Avg tests/node:      $g{avgtestsnode}\n";
    $message .= "Clear branches:      $num_clear_branches\n";
    $message .= "Clear leaves:        $num_clear_leaves\n";
    $message .= "Xymon msg xfer size: $g{sentmsgsize}\n\n";
    $message .= "Cycle time:          " . sprintf( "%6.2f s\n",   $g{cycletime} );
    $message .= "Dead time:           " . sprintf( "%6.2f s\n\n", $g{deadtime} );
    $message .= "SNMP test time:      $snmp_poll_time\n";
    $message .= "Test logic time:     $test_time\n";
    $message .= "Xymon msg xfer time: $msg_xfr_time\n";
    $message .= "This poll period:    $this_poll_time\n";
    $message .= "Avg poll time:       ";

    # Calculate avg poll time over the last 5 poll cycles
    my $num_polls = scalar @{ $g{avgpolltime} };
    if ( $num_polls < 5 ) {
        $message .= "  wait\n";
    } else {
        my $avg_time;
        for my $time ( @{ $g{avgpolltime} } ) { $avg_time += $time }
        $avg_time /= $num_polls;
        $message .= sprintf( "%6.2f s\n\n", $avg_time ) . "Poll time averaged over 5 poll cycles.";
    }

    $message .= "\n\nFork summary\n";
    $message .= sprintf( "%8s %7s %16s %6s %25s\n", 'Number', 'PID', 'Last checked in', 'Polled', 'Current Activity' );
    my $stalledforks = 0;
    foreach my $fork ( sort { $a <=> $b } keys %{ $g{forks} } ) {
        my $activity
            = $g{forks}{$fork}{pinging} ? 'stalled'
            : $g{forks}{$fork}{dev}     ? "polling $g{forks}{$fork}{dev}"
            :                             'idle';
        $stalledforks++ if ( $activity eq 'stalled' );
        my $ftime  = time - $g{forks}{$fork}{time};
        my $polled = $g{forks}{$fork}{polled} ? $g{forks}{$fork}{polled} : '';
        if ( $ftime > ( 3 * $g{cycletime} ) ) {
            $color = 'yellow';
            $activity .= " for more than cycletime \&yellow";
        }
        $ftime = sprintf( "%.2f", $ftime ) . ' s ago';
        $message .= sprintf( "%8d %7d %16s %6s %25s\n", $fork, $g{forks}{$fork}{pid}, ${ftime}, $polled, $activity );
    }
    if ( $stalledforks gt $g{numforks} ) {
        $color = 'red';
        $message .= "&red $stalledforks forks of $g{numforks} are stalled\n";
    }

    # Replace each ":" and "=" by their equivalent HTML escape character, in
    # order not to confuse the Xymon NCV module. Write the polling time
    # (in HTML comment) for storage in an RRD.
    $message =~ s/:/&#58;/g;
    $message =~ s/=/&#61;/g;
    $message .= "<!--\n" . "PollTime : $this_poll_time\n" . "-->";

    # Add the header
    my $xymon_nodename = $g{nodename};
    $xymon_nodename =~ s/\./,/g;    # Don't forget our FQDN stuff
    my $now = $g{xymondateformat} ? strftime( $g{xymondateformat}, localtime ) : scalar(localtime);
    $message = "status $xymon_nodename.dm $color $now\n\n$message\n";

    return $message;
}
