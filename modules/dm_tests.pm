package dm_tests;
require Exporter;
@ISA    = qw(Exporter);
@EXPORT = qw(tests make_ifc_array);

#    Devmon: An SNMP data collector & page generator for the
#    Xymon network monitoring systems
#    Copyright (C) 2005-2006  Eric Schwimmer
#    Copyright (C) 2007 Francois Lacroix
#
#    $URL: svn://svn.code.sf.net/p/devmon/code/trunk/modules/dm_tests.pm $
#    $Revision: 251 $
#    $Id: dm_tests.pm 251 2015-06-02 15:28:36Z buchanmilne $
#
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.  Please see the file named
#    'COPYING' that was included with the distrubition for more details.

# Modules
use strict;
use dm_config qw(FATAL ERROR WARN INFO DEBUG TRACE);
use dm_config;

#use Math::BigInt::Calc;
use POSIX qw/ strftime /;
use Scalar::Util qw(looks_like_number);
use Data::Dumper;
use Time::HiRes qw(time);
use Storable qw(dclone);

# my $dump = Dumper(\$oids);

# Our global variable hash
use vars qw(%g);
*g = \%dm_config::g;

# Global array and hash by descending priority/severity
my %colors      = ( 'red' => 6, 'yellow' => 5, 'clear' => 4, 'purple' => 3, 'green' => 2, 'blue' => 1 );
my @color_order = sort { $colors{$b} <=> $colors{$a} } keys %colors;
my $color_list  = join '|', @color_order;

# Speed hash for trans_speed conversions
my %speeds = (
    1      => '[b/s]',
    10**3  => '[kb/s]',
    10**6  => '[Mb/s]',
    10**9  => '[Gb/s]',
    10**12 => '[Tb/s]',
    10**15 => '[Pb/s]'
);

# Main test subroutine; parse data and feed it to the individual
# test-specific subs
sub tests {
    @{ $g{test_results} } = ();    # Our outgoing message queue

    #    %{ $g{tmp_hist} }     = ();    # Temporary history hash

    # Timestamp
    $g{testtime} = time;

    do_log( 'Performing tests', INFO );

    # Now go through each device and perform the test logic it needs
    for my $device ( sort keys %{ $g{devices} } ) {

        #my $oids = {};
        my $oids = \%{ $g{devices}{$device}{oids} };

        # Check to see if this device was unreachable in xymon
        # If so skip device
        next if !defined $g{xymon_color}{$device} or $g{xymon_color}{$device} ne 'green';

        # Get template-specific variables
        my $vendor = $g{devices}{$device}{vendor};
        my $model  = $g{devices}{$device}{model};
        my $tests  = $g{devices}{$device}{tests};

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

        # Separate tests, perform individual test logic
        for my $test ( split /,/, $tests ) {

            do_log( "Starting test for $test on device $device", DEBUG ) if $g{debug};

            # Hash shortcut
            my $tmpl = \%{ $g{templates}{$vendor}{$model}{tests}{$test} };

            # custom threshold pointer
            my $thr = \%{ $g{devices}{$device}{thresh}{$test} };

            # Create our oids hash that will be populated by both snmp
            # data and transformed data.  This is done to keep me
            #
            # from going insane when we start doing transforms
            oid_hash( $oids, $device, $tmpl, $thr );

            # Perform the transform
            for my $oid ( @{ $tmpl->{sorted_oids} } ) {
                next if !$oids->{$oid}{transform};
                transform( $device, $oids, $oid, $thr );

                #do_log( "After trans: $oid" . Dumper( \$oids ) );

                # Do some debug if requested
                if ( $g{debug} ) {
                    my $oid_h = \%{ $oids->{$oid} };
                    if ( $oid_h->{repeat} and ( defined $oid_h->{val} and %{ $oid_h->{val} } ) ) {
                        my $line;
                    LEAF: for my $leaf ( sort keys %{ $oid_h->{val} } ) {

                            #$line .= "i:$leaf v:" . ( $oid_h->{val}{$leaf} // "undef" );
                            if ( $g{trace} ) {
                                $line = "i:$leaf v:" . ( $oid_h->{val}{$leaf} // "undef" );
                                $line .= " c:$oid_h->{color}{$leaf}" if defined $oid_h->{color}{$leaf};
                                $line .= " e:$oid_h->{error}{$leaf}" if defined $oid_h->{error}{$leaf};
                                $line .= " m:$oid_h->{msg}{$leaf}"   if defined $oid_h->{msg}{$leaf};
                                $line .= " t:$oid_h->{time}{$leaf}"  if defined $oid_h->{time}{$leaf};
                                do_log( "$line", TRACE );
                            } else {
                                $line .= "$leaf:" . ( $oid_h->{val}{$leaf} // "undef" ) . " ";
                            }
                        }
                        if ( not $g{trace} ) {
                            do_log( "$line", DEBUG );
                        }
                    } else {
                        my $line;
                        if ( $g{trace} ) {
                            $line = "v:" . ( $oid_h->{val} // "undef" );
                            $line .= " c:$oid_h->{color}" if defined $oid_h->{color};
                            $line .= " e:$oid_h->{error}" if defined $oid_h->{error};
                            $line .= " m:$oid_h->{msg}"   if defined $oid_h->{msg};
                            $line .= " t:$oid_h->{time}"  if defined $oid_h->{time};
                            do_log( "$line", TRACE );
                        } else {
                            $line = ( $oid_h->{val} // "undef" );
                            do_log( "$line", DEBUG );
                        }
                    }
                }
            }

            # Now crank out our message
            my $msg = render_msg( $device, $tmpl, $test, $oids );

            # Add the message to our outgoing queue!
            push @{ $g{test_results} }, $msg if defined $msg;

        }
    }

    # Finish timestamp
    $g{testtime} = time - $g{testtime};
}

# Create a oid hash ref that will eventually contain all gathered
# data (snmp or transformed)
sub oid_hash {
    my ( $oids, $device, $tmpl, $thr ) = @_;

    # Hash shortcuts
    my $snmp = \%{ $g{snmp_data}{$device} };

    if ( !%{$snmp} ) {
        do_log( "No SNMP data found on $device", WARN ) if ( $g{xymon_color}{$device} eq 'green' );
    }

    #First clean the hash: delete all but keep the val struct of repeater
    my %rep_val_keys;
    for my $oid ( keys %{ $tmpl->{oids} } ) {

        if ( $oids->{$oid}{repeat} ) {
            for my $rep_val_key ( keys %{ $oids->{$oid}{val} } ) {
                $rep_val_keys{$oid}{val}{$rep_val_key} = undef;
                $rep_val_keys{$oid}{repeat} = $oids->{$oid}{repeat};
            }
        }
        delete $oids->{$oid};
    }

    # For now we will copy the data from the template and snmp
    # Copy the data even if the OID is already cached during a preceeding test.
    # In the current test, the thresholds or the exceptions might be different.
    for my $oid ( keys %{ $tmpl->{oids} } ) {

        # Don't hash an OID more than once
        #next if defined $oids->{$oid}{val};
        next if exists $oids->{$oid};

        # Put all the info we got on the oid in (sans transform data)
        # in the oid/no s hash ref
        # First we do threshold data

        if ( defined $tmpl->{oids}{$oid}{threshold} ) {
            $oids->{$oid}{threshold} = $tmpl->{oids}{$oid}{threshold};
        } elsif ( defined $oids->{$oid}{threshold} ) {
            delete $oids->{$oid}{threshold};    # Remove old definition
        }

        # Then exceptions
        if ( defined $tmpl->{oids}{$oid}{exceptions} ) {
            $oids->{$oid}{except} = $tmpl->{oids}{$oids}{exceptions};
        } elsif ( defined $oids->{$oid}{except} ) {
            delete $oids->{$oid}{except};       # Remove old definition
        }

        # We don't have transform data yet, mark it for later and skip
        if ( defined $tmpl->{oids}{$oid}{trans_type} ) {
            $oids->{$oid}{transform}   = 1;
            $oids->{$oid}{trans_type}  = $tmpl->{oids}{$oid}{trans_type};
            $oids->{$oid}{trans_data}  = $tmpl->{oids}{$oid}{trans_data};
            $oids->{$oid}{trans_edata} = $tmpl->{oids}{$oid}{trans_edata} if defined $tmpl->{oids}{$oid}{trans_edata};

            # add to transform keys if something previoulsy discovered
            unless ( %{$snmp} ) {
                for my $oid_key ( keys %{ $rep_val_keys{$oid} } ) {
                    $oids->{$oid}{$oid_key} = $rep_val_keys{$oid}{$oid_key};
                }
            }
            next;
        }
        my $num    = $tmpl->{oids}{$oid}{number};    # this is the numerical oid (1.3.5...) ?!? we dont need it...
        my $repeat = $tmpl->{oids}{$oid}{repeat};

        $oids->{$oid}{transform} = 0;                #why?
        $oids->{$oid}{repeat}    = $repeat;

        # If this is a repeater, iterate through its leaves and assign values
        # Apply thresholds
        if ( %{$snmp} ) {
            if ( defined $snmp->{$num}{val} ) {
                if ($repeat) {
                    for my $leaf ( keys %{ $snmp->{$num}{val} } ) {

                        # If we have a non-numeric leaf, make sure to keep track of this!
                        # Store this as a type '2' repeater
                        $oids->{$oid}{repeat}      = 2 if $leaf !~ /^[+-]?(?:\d+\.?\d*|\d*\.\d+)$/;
                        $oids->{$oid}{val}{$leaf}  = $snmp->{$num}{val}{$leaf};
                        $oids->{$oid}{time}{$leaf} = $snmp->{$num}{time}{$leaf};
                    }
                    delete $oids->{$oid}{error};
                    delete $oids->{$oid}{color};
                    delete $oids->{$oid}{msg};

                } else {
                    $oids->{$oid}{val}  = $snmp->{$num}{val};
                    $oids->{$oid}{time} = $snmp->{$num}{time};
                    delete $oids->{$oid}{color};
                    delete $oids->{$oid}{msg};
                    delete $oids->{$oid}{error};

                }
            } else {
                do_log("No SNMP answer for '$oid' on '$device' (see notests) ", WARN);
                $oids->{$oid}{val}   = undef;
                $oids->{$oid}{color} = "clear";
                $oids->{$oid}{msg}   = "No SNMP answer for $oid";
                $oids->{$oid}{time}  = time;
            }
        } else {

            # No snmp answer
            if ($repeat) {
                if ( defined $rep_val_keys{$oid}{repeat} ) {
                    $oids->{$oid}{repeat} = $rep_val_keys{$oid}{repeat};

                    # Add keys if something previoulsy discovered
                    for my $leaf ( keys %{ $rep_val_keys{$oid}{val} } ) {
                        $oids->{$oid}{val}{$leaf} = undef;
                        delete $oids->{$oid}{time}{$leaf};
                        delete $oids->{$oid}{color}{$leaf};
                        delete $oids->{$oid}{error}{$leaf};    # not needed, just to be sure
                    }
                    $oids->{$oid}{time}  = time;
                    $oids->{$oid}{color} = "clear";
                    $oids->{$oid}{msg}   = "No SNMP answer";

                } else {

                    # nothing was previously defined, so we dont know any leaf, we treat it as nonrep
                    $oids->{$oid}{val}   = undef;              # already undef, but just to be sure!
                    $oids->{$oid}{time}  = time;
                    $oids->{$oid}{color} = "clear";
                    $oids->{$oid}{msg}   = "No SNMP answer";
                    delete $oids->{$oid}{error};

                }
            } else {
                $oids->{$oid}{val}   = undef;
                $oids->{$oid}{color} = "clear";
                $oids->{$oid}{time}  = time;
                $oids->{$oid}{msg}   = "No SNMP answer";
                delete $oids->{$oid}{error};

            }
        }

        apply_threshold( $oids, $thr, $oid );

    }

    return $oids;
}

# Transform data values
sub transform {
    my ( $device, $oids, $oid, $thr ) = @_;

    # Shortcut to our snmp data
    my $trans_type = $oids->{$oid}{trans_type};
    my $trans_data = $oids->{$oid}{trans_data};

    # Make sure we inherit repeatability from previous types
    my $trans_sub = "trans_" . $trans_type;
    no strict 'refs';
    do_log( "Doing $trans_type transform on $device/$oid", DEBUG ) if $g{debug};
    if ( defined &$trans_sub ) {
        eval {
            local $SIG{ALRM} = sub { die "Timeout\n" };
            alarm 5;
            &$trans_sub( $device, $oids, $oid, $thr );
            alarm 0;
        };

        if ($@) {
            if ( $@ eq "Timeout\n" ) {
                do_log( "Timed out waiting for $trans_type transform on oid $oid for $device to complete", ERROR );
            } else {
                do_log( "Got unexpected error while performing $trans_type transform on oid $oid for $device: $@", ERROR );
            }
        }
    } else {

        # Theoretically we should never get here, but whatever
        do_log( "Undefined transform type '$trans_type' found for $device", ERROR )
            and return;
    }
    use strict 'refs';
}

# Do data over time delta transformations ####################################
sub trans_delta {
    my ( $device, $oids, $oid, $thr ) = @_;

    # Hash shortcuts
    my $hist  = \%{ $g{hist}{$device} };
    my $oid_h = \%{ $oids->{$oid} };

    # Extract our transform options
    my ( $dep_oid, $limit ) = ( $1, $2 || 0 )
        if $oid_h->{trans_data} =~ /\{(.+)\}(?:\s+:\s*(\d+))?/;
    my $dep_oid_h = \%{ $oids->{$dep_oid} };

    # Initialize history
    my $keep_dep_hist_cycle = 1;    #number historical value to retain
    if ( $g{current_cycle} == 1 ) {

        if ( exists $hist->{oid}{$dep_oid}{keep_hist_count} ) {
            if ( $hist->{oid}{$dep_oid}{keep_hist_count} < $keep_dep_hist_cycle ) {
                $hist->{oid}{$dep_oid}{keep_hist_count} = $keep_dep_hist_cycle;
            }
        } else {
            $hist->{oid}{$dep_oid}{keep_hist_count} = $keep_dep_hist_cycle;
        }
    }
    if ( not define_pri_oid( $oids, $oid, [$dep_oid] ) ) {

        # We should always ave a primary oid with this transform, so make a fatal error
        log_fatal("FATAL TEST: Device '$device' do not have any defined primary oid for oid '$oid'");
    }

    # Check our parent oids for any errors
    if ( not validate_deps( $device, $oids, $oid, [$dep_oid], '^[-+]?\d+(\.\d+)?$' ) ) {
        do_log( "Delta transform on $device/$oid do not have valid dependencies: skipping", DEBUG ) if $g{debug};
        return;
    }

    # See if we are a repeating variable type datum
    # (such as that generated by snmpwalking a table)
    if ( $oid_h->{repeat} ) {

    LEAF: for my $leaf ( keys %{ $dep_oid_h->{val} } ) {

            # Skip if we got a dependency error for this leaf
            next if ( ( exists $oid_h->{error} ) and ( exists $oid_h->{error}{$leaf} ) and ( $oid_h->{error}{$leaf} ) );

            my $this_data = $dep_oid_h->{val}{$leaf};
            my $this_time = $dep_oid_h->{time}{$leaf};

            # Check if we have history, return delta if so
            if (( exists $hist->{oid}{$dep_oid}{hists}{$leaf} )
                and (  ( $hist->{oid}{$dep_oid}{hists}{$leaf}->[-1] != $g{current_cycle} )
                    or ( scalar @{ $hist->{oid}{$dep_oid}{hists}{$leaf} } > $keep_dep_hist_cycle ) )
                )
            {
                my $last_cycle;
                if ( $hist->{oid}{$dep_oid}{hists}{$leaf}->[-1] == $g{current_cycle} ) {

                    # the last history is the current cycle, take the next previous
                    $last_cycle = ${ $hist->{oid}{$dep_oid}{hists}{$leaf} }[-2];
                } else {

                    $last_cycle = ${ $hist->{oid}{$dep_oid}{hists}{$leaf} }[-1];
                }

                my $last_data = $hist->{oid}{$dep_oid}{hist}{$last_cycle}{val}{$leaf};
                my $last_time = $hist->{oid}{$dep_oid}{hist}{$last_cycle}{time}{$leaf};
                my $delta;

                # Check for counter wrap
                if ( $last_data > $this_data ) {

                    # Check for custom limit, first
                    if ($limit) {
                        $delta = ( $this_data + ( $limit - $last_data ) ) / ( $this_time - $last_time );

                        # If the last value was less than 2^32, assume the counter was 32bit
                    } elsif ( $last_data < 4294967296 ) {
                        $delta = ( $this_data + ( 4294967296 - $last_data ) ) / ( $this_time - $last_time );

                        # Otherwise the counter was 64bit...
                        # In this case, a counter wrap is highly unlikely. A reset of the
                        # counters is a much more likely reason for this (apparent) wrap.
                    } elsif ( $last_data < 18446744073709551616 ) {
                        $delta = $this_data / ( $this_time - $last_time );

                        # Otherwise something is seriously wrong
                    } else {
                        do_log( "Data type too large for leaf $leaf of $dep_oid on $device.", WARN );
                        $oid_h->{val}{$leaf}   = 'Too large';
                        $oid_h->{time}{$leaf}  = time;
                        $oid_h->{color}{$leaf} = 'yellow';
                        $oid_h->{error}{$leaf} = 1;
                        next LEAF;
                    }

                    do_log( "Counterwrap on $oid.$leaf on $device (this: $this_data last: $last_data delta: $delta", DEBUG ) if $g{debug};

                    # Otherwise do normal delta calc
                } else {
                    use bignum;
                    $delta = ( $this_data - $last_data ) / ( $this_time - $last_time );
                }

                # Round delta to two decimal places
                $delta                = sprintf "%.2f", $delta;
                $oid_h->{val}{$leaf}  = $delta;
                $oid_h->{time}{$leaf} = time;

            } else {

                # No history; throw wait message
                $oid_h->{val}{$leaf}   = 'wait';
                $oid_h->{time}{$leaf}  = time;
                $oid_h->{color}{$leaf} = 'clear';
                $oid_h->{msg}{$leaf}   = 'wait';

            }

            # Store history and delete expired
            if ( ( !exists $hist->{oid}{$dep_oid}{hists}{$leaf} ) or ( $hist->{oid}{$dep_oid}{hists}{$leaf}->[-1] != $g{current_cycle} ) ) {
                $hist->{oid}{$dep_oid}{hist}{ $g{current_cycle} }->{val}{$leaf}  = $this_data;
                $hist->{oid}{$dep_oid}{hist}{ $g{current_cycle} }->{time}{$leaf} = $this_time;
                push( @{ $hist->{oid}{$dep_oid}{hists}{$leaf} }, $g{current_cycle} );
                if ( (defined $hist->{oid}{$dep_oid}{keep_hist_count}) and ( scalar @{ $hist->{oid}{$dep_oid}{hists}{$leaf} } - 1 ) > $hist->{oid}{$dep_oid}{keep_hist_count} ) {
                    my $expired_hist_cycle = shift( @{ $hist->{oid}{$dep_oid}{hists}{$leaf} } );
                    delete( $hist->{oid}{$dep_oid}{hist}{$expired_hist_cycle} );
                }
            }
        }

        # Otherwise we are a single entry datum
    } else {
        my $this_data = $dep_oid_h->{val};
        my $this_time = $dep_oid_h->{time};

        # Check if we have history, return delta if so
        if (( exists $hist->{oid}{$dep_oid}{hists} )
            and (  ( $hist->{oid}{$dep_oid}{hists}->[-1] != $g{current_cycle} )
                or ( scalar @{ $hist->{oid}{$dep_oid}{hists} } > $keep_dep_hist_cycle ) )
            )
        {
            my $last_cycle;
            if ( $hist->{oid}{$dep_oid}{hists}->[-1] == $g{current_cycle} ) {

                # the last history is the current cycle, take the next previous
                $last_cycle = ${ $hist->{oid}{$dep_oid}{hists} }[-2];
            } else {

                $last_cycle = ${ $hist->{oid}{$dep_oid}{hists} }[-1];
            }
            my $last_data = $hist->{oid}{$dep_oid}{hist}{$last_cycle}{val};
            my $last_time = $hist->{oid}{$dep_oid}{hist}{$last_cycle}{time};
            my $delta;

            # Check for counter wrap
            if ( $last_data > $this_data ) {

                # If the value was less than 2^32, assume the counter was 32bit
                if ($limit) {
                    $delta = ( $this_data + ( $limit - $last_data ) ) / ( $this_time - $last_time );
                } elsif ( $last_data < 4294967296 ) {
                    $delta = ( $this_data + ( 4294967296 - $last_data ) ) / ( $this_time - $last_time );

                    # Otherwise the counter was 64bit...
                    # In this case, a counter wrap is highly unlikely. A reset of the
                    # counters is a much more likely reason for this (apparent) wrap.
                } elsif ( $last_data < 18446744073709551616 ) {
                    $delta = $this_data / ( $this_time - $last_time );

                    # Otherwise something is seriously wrong
                } else {
                    do_log( "Data type too large for $dep_oid on $device.", ERROR );

                    $oid_h->{val}   = undef;
                    $oid_h->{time}  = time;
                    $oid_h->{color} = 'clear';
                    $oid_h->{msg}   = 'Too large';
                    return;
                }

                do_log( "Counterwrap on $oid on $device (this: $this_data last: $last_data delta: $delta", DEBUG )
                    if $g{debug};

                # Otherwise do normal delta calc
            } else {
                $delta = ( $this_data - $last_data ) / ( $this_time - $last_time );
            }

            $delta         = sprintf "%.2f", $delta;
            $oid_h->{val}  = $delta;
            $oid_h->{time} = time;

        } else {

            # No history; throw wait message
            $oid_h->{val}   = 'wait';
            $oid_h->{time}  = time;
            $oid_h->{color} = 'clear';
            $oid_h->{msg}   = 'wait';

        }

        # Store history if needed
        if ( ( !exists $hist->{oid}{$dep_oid}{hists} ) or ( $hist->{oid}{$dep_oid}{hists}->[-1] != $g{current_cycle} ) ) {
            $hist->{oid}{$dep_oid}{hist}{ $g{current_cycle} }->{val}  = $this_data;
            $hist->{oid}{$dep_oid}{hist}{ $g{current_cycle} }->{time} = $this_time;
            push( @{ $hist->{oid}{$dep_oid}{hists} }, $g{current_cycle} );
            if ( ( scalar @{ $hist->{oid}{$dep_oid}{hists} } - 1 ) > $hist->{oid}{$dep_oid}{keep_hist_count} ) {
                my $expired_hist_cycle = shift( @{ $hist->{oid}{$dep_oid}{hists} } );
                delete( $hist->{oid}{$dep_oid}{hist}{$expired_hist_cycle} );
            }
        }
    }
    apply_threshold( $oids, $thr, $oid );
}

# Do mathmatical translations ###############################################
sub trans_math {
    my ( $device, $oids, $oid, $thr ) = @_;
    my $oid_h     = \%{ $oids->{$oid} };
    my $expr      = $oid_h->{trans_data};
    my $precision = 2;

    # Extract our optional precision argument
    $precision = $1 if $expr =~ s/\s*:\s*(\d+)$//;
    my $print_mask = '%.' . $precision . 'f';

    # Convert our math symbols to their perl equivalents
    $expr =~ s/\sx\s/ \* /g;    # Multiplication
    $expr =~ s/\^/**/g;         # Exponentiation

    # Extract all our our parent oids from the expression, first
    my @dep_oids = $expr =~ /\{(.+?)\}/g;

    # Define our primary oid
    define_pri_oid( $oids, $oid, \@dep_oids );

    # We have a primary set if the is one

    # Validate our dependencies
    if ( not validate_deps( $device, $oids, $oid, \@dep_oids, '^[-+]?\d+(\.\d+)?$' ) ) {

        #if ( not validate_deps($device, $oids, $oid, \@dep_oids ) ) {
        do_log( "Math transform on $device/$oid do not have valid dependencies: skipping", DEBUG ) if $g{debug};
        return;
    }

    # Also go through our non-repeaters and replace them in our
    # expression, since they are constant (i.e. not leaf dependent)
    my @repeaters;
    for my $dep_oid (@dep_oids) {
        push @repeaters, $dep_oid and next if $oids->{$dep_oid}{repeat};
        if ( ( defined $oids->{$dep_oid}{error} ) and ( $oids->{$dep_oid}{error} ) ) {
            $oid_h->{val}   = $oids->{$dep_oid}{val} if defined $oids->{$dep_oid}{val};
            $oid_h->{color} = $oids->{$dep_oid}{color};
            $oid_h->{msg}   = $oids->{$dep_oid}{msg} if defined $oids->{$dep_oid}{msg};
            $oid_h->{error} = 1;
            return;
        }
        $expr =~ s/\{$dep_oid\}/$oids->{$dep_oid}{val}/g;
    }

    # Handle repeater-type oids
    if ( $oid_h->{repeat} ) {
        my @dep_val;

        for ( my $i = 0; $i <= $#repeaters; $i++ ) {
            $expr =~ s/\{$repeaters[$i]\}/\$dep_val[$i]/g;
        }

        for my $leaf ( keys %{ $oids->{ $oid_h->{pri_oid} }{val} } ) {

            # Skip if we got a dependency error for this leaf
            next if ( ( exists $oid_h->{error} ) and ( exists $oid_h->{error}{$leaf} ) and ( $oid_h->{error}{$leaf} ) );

            # Update our dep_val values so that when we eval the expression it
            # will use the values of the proper leaf of the parent repeater oids
            undef @dep_val;
            for (@repeaters) { push @dep_val, $oids->{$_}{val}{$leaf} }

            # Do our eval and set our time
            my $result = eval($expr);
            $oid_h->{time}{$leaf} = time;

            if ($@) {
                chomp $@;
                if ( $@ =~ /^Illegal division by zero/ ) {
                    $oid_h->{val}{$leaf}   = 'NaN';
                    $oid_h->{color}{$leaf} = 'clear';
                    $oid_h->{msg}{$leaf}   = '';

                    #                    delete $oid_h->{msg}{$leaf};      # we propably do have to delete anything but as we would like to override non fatal error

                    #delete $oid_h->{error}{$leaf};    # we do it for now, but we could have an non fatal error: fatal = 2, non fatal = 1 ?
                    #delete $oid_h->{thresh}{$leaf};

                } else {
                    do_log( "Failed eval for TRANS_MATH on $oid.$leaf: $expr ($@)", ERROR );
                    $oid_h->{val}{$leaf}   = undef;
                    $oid_h->{color}{$leaf} = 'clear';
                    $oid_h->{msg}{$leaf}   = $@;

                    #delete $oid_h->{error}{$leaf};
                    #delete $oid_h->{thresh}{$leaf};
                }

                #  next;
            } else {
                $result = sprintf $print_mask, $result;
                $oid_h->{val}{$leaf} = $result;
            }
        }

        # Otherwise we are a single entry datum
    } else {

        # All of our non-reps were substituted earlier, so we can just eval
        my $result = eval $expr;

        #$oid_h->{time} = time;

        if ($@) {
            chomp $@;
            if ( $@ =~ /^Illegal division by zero/ ) {
                $oid_h->{val}   = 'NaN';
                $oid_h->{color} = 'clear';
                $oid_h->{msg}   = '';
            } else {
                do_log( "Failed eval for TRANS_MATH on $oid: $expr ($@)", ERROR );
                $oid_h->{val}   = undef;
                $oid_h->{color} = 'clear';
                $oid_h->{msg}   = $@;
            }
        } else {
            $result       = sprintf $print_mask, $result;
            $oid_h->{val} = $result;
        }
    }

    # Now apply our threshold to this data
    apply_threshold( $oids, $thr, $oid );
}

# Extract a statistic from a repeater OID ###################################
# Extract a statistic from a repeater-type oid, resulting in a leaf-type oid.
# The statistic is one of 'min', 'avg', 'max', 'cnt' or 'sum'.
#
sub trans_statistic {
    my ( $device, $oids, $oid, $thr ) = @_;
    my $oid_h = \%{ $oids->{$oid} };

    my ( $dep_oid,   $dep_oid_h, @leaf,   $leaf );
    my ( $statistic, $val,       $result, $count );

    # Define the computational step for each statistic. Scalar $result holds the
    # accumulator, while $val is the next value to handle. The number of values
    # is maintained outside these mini-functions in scalar $count.
    #
    my %comp = (
        sum => sub { $result += $val; },
        min => sub { $result = $val if $val < $result; },
        max => sub { $result = $val if $val > $result; },
        avg => sub { $result += $val; }
    );

    # Extract the parent oid from the expression.
    ( $dep_oid, $statistic ) = $oid_h->{trans_data} =~ /^\{(.+)\}\s+(\S+)$/;
    $statistic = lc $statistic;
    $dep_oid_h = \%{ $oids->{$dep_oid} };

    # Define our primary oid
    if ( not define_pri_oid( $oids, $oid, [$dep_oid] ) ) {

        # We should always ave a primary oid with this transform, so make a fatal error
        log_fatal("FATAL TEST: Device '$device' do not have any defined primary oid for oid '$oid'");
    }

    # Do not use function validate_deps. It will make this oid to be of the
    # repeater-type if the parent oid is of the repeater-type. The code section
    # below is inspired on the relevant parts of function validate_deps.
    #
    $oid_h->{repeat} = 0;       # Make a leaf-type oid
    $oid_h->{val}    = undef;

    # Check all the leaves of a repeater-type oid for an error condition. If
    # one is found, propagate the error condition to the result oid.
    #
    if ( $dep_oid_h->{repeat} ) {
        if ( scalar keys %{ $dep_oid_h->{val} } ) {
            for $leaf ( keys %{ $dep_oid_h->{val} } ) {
                $val = $dep_oid_h->{val}{$leaf};
                if ( !defined $val ) {
                    $oid_h->{val}   = 'parent value n/a';
                    $oid_h->{color} = 'clear';
                    last;
                } elsif ( $val eq 'wait' ) {
                    $oid_h->{val}   = 'wait';
                    $oid_h->{color} = 'clear';
                    $oid_h->{msg}   = 'msg';
                    last;
                } elsif ( $dep_oid_h->{error}{$leaf} ) {
                    $oid_h->{val}   = 'inherited';
                    $oid_h->{color} = 'clear';
                    last;
                } elsif ( $statistic ne 'cnt' and $val !~ m/^[-+]?\d+(?:\.\d+)?$/ ) {
                    $oid_h->{val}   = 'Regex mismatch';
                    $oid_h->{color} = 'clear';
                    last;
                }
            }
        } else {

            # there is no leaf, so they are undefined
            $oid_h->{val}   = 'parent value n/a';
            $oid_h->{color} = 'clear';
        }
    } else {
        if ( $dep_oid_h->{error} ) {
            $oid_h->{val}   = $dep_oid_h->{val};
            $oid_h->{color} = $dep_oid_h->{color};
        }
    }

    if ( defined $oid_h->{val} ) {
        $oid_h->{time}  = time;
        $oid_h->{error} = 1;
    }

    # bypass if we already have an error code
    if ( !defined $oid_h->{error} ) {

        # The parent oid is a repeater-type oid. Determine the requested statistic
        # from this list.

        if ( $dep_oid_h->{repeat} ) {
            @leaf  = keys %{ $dep_oid_h->{val} };
            $count = scalar @leaf;
            if ( $statistic eq 'cnt' ) {
                $result = $count;
            } elsif ( $count == 0 ) {
                $result = undef;
            } else {

                # Extract the first value of the list. This value is a nice starting
                # value to determine the minimum and the maximum.

                $leaf   = shift @leaf;
                $result = $dep_oid_h->{val}{$leaf};
                for $leaf (@leaf) {
                    $val = $dep_oid_h->{val}{$leaf};
                    &{ $comp{$statistic} };    # Perform statistical computation
                }
                $result = $result / $count if $statistic eq 'avg';
            }

            $oid_h->{val}  = $result;
            $oid_h->{time} = time;

            # The parent oid is a non-repeater-type oid. The computation of the
            # statistic is trivial in this case.
        } else {
            $oid_h->{val}  = $dep_oid_h->{val};
            $oid_h->{val}  = 1 if $statistic eq 'cnt';
            $oid_h->{time} = $dep_oid_h->{time};
            $oid_h->{msg}  = $dep_oid_h->{msg};
        }
    }
    apply_threshold( $oids, $thr, $oid );
}

# Get substring of dependent oid ############################################
sub trans_substr {
    my ( $device, $oids, $oid, $thr ) = @_;
    my $oid_h = \%{ $oids->{$oid} };

    my ( $dep_oid, $offset, $length ) = ( $1, $2, $3 )
        if $oid_h->{trans_data} =~ /^\{(.+)\}\s+(\d+)\s*(\d*)$/;
    my $dep_oid_h = \%{ $oids->{$dep_oid} };
    $length = undef if $length eq '';

    # Define our primary oid
    if ( not define_pri_oid( $oids, $oid, [$dep_oid] ) ) {

        # We should always ave a primary oid with this transform, so make a fatal error
        log_fatal("FATAL TEST: Device '$device' do not have any defined primary oid for oid '$oid'");
    }

    validate_deps( $device, $oids, $oid, [$dep_oid] ) or return;

    # See if we are a repeating variable type datum
    # (such as that generated by snmpwalking a table)
    if ( $oid_h->{repeat} ) {
        for my $leaf ( keys %{ $dep_oid_h->{val} } ) {

            # Skip if we got a dependency error for this leaf
            next if ( ( exists $oid_h->{error} ) and ( exists $oid_h->{error}{$leaf} ) and ( $oid_h->{error}{$leaf} ) );

            # Do string substitution
            my $string = $dep_oid_h->{val}{$leaf};
            if ( defined $length ) {
                $oid_h->{val}{$leaf} = substr $string, $offset, $length;
            } else {
                $oid_h->{val}{$leaf} = substr $string, $offset;
            }
        }

        # Otherwise we are a non-repeater oid
    } else {
        my $string = $dep_oid_h->{val};
        if ( defined $length ) {
            $oid_h->{val} = substr $string, $offset, $length;
        } else {
            $oid_h->{val} = substr $string, $offset;
        }

    }

    # Now apply our threshold to this data
    apply_threshold( $oids, $thr, $oid );
}

sub trans_pack {
    my ( $device, $oids, $oid, $thr ) = @_;
    my $oid_h = \%{ $oids->{$oid} };

    my ( $dep_oid, $type, $seperator ) = ( $1, $2, $3 || '' )
        if $oid_h->{trans_data} =~ /^\{(.+)\}\s+(\S+)(?:\s+"(.+)")?/;
    my $dep_oid_h = \%{ $oids->{$dep_oid} };

    # Define our primary oid
    if ( not define_pri_oid( $oids, $oid, [$dep_oid] ) ) {

        # We should always ave a primary oid with this transform, so make a fatal error
        log_fatal("FATAL TEST: Device '$device' do not have any defined primary oid for oid '$oid'");
    }

    # Validate our dependencies
    validate_deps( $device, $oids, $oid, [$dep_oid] ) or return;

    # See if we are a repeating variable type datum
    # (such as that generated by snmpwalking a table)
    if ( $oid_h->{repeat} ) {

        # Unpack ze data
        for my $leaf ( keys %{ $dep_oid_h->{val} } ) {

            # Skip if we got a dependency error for this leaf
            next if ( ( exists $oid_h->{error} ) and ( exists $oid_h->{error}{$leaf} ) and ( $oid_h->{error}{$leaf} ) );

            #next if $oid_h->{error}{$leaf};

            my @packed = split $seperator, $dep_oid_h->{val}{$leaf};
            my $val    = pack $type, @packed;

            do_log( "Transformed $dep_oid_h->{val}{$leaf}, first val $packed[0], to $val via pack transform type $type, seperator $seperator ", DEBUG ) if $g{debug};

            $oid_h->{val}{$leaf} = $val;
        }

        # Otherwise we are a single entry datum
    } else {
        my $packed = $dep_oid_h->{val};
        my @vars   = pack $type, $packed;

        $oid_h->{val} = join $seperator, @vars;

    }

    # Apply thresholds
    apply_threshold( $oids, $thr, $oid );
}

# Translate hex or octal data into decimal ##################################
sub trans_unpack {
    my ( $device, $oids, $oid, $thr ) = @_;
    my $oid_h = \%{ $oids->{$oid} };

    my ( $dep_oid, $type, $seperator ) = ( $1, $2, $3 || '' )
        if $oid_h->{trans_data} =~ /^\{(.+)\}\s+(\S+)(?:\s+"(.+)")?/;
    my $dep_oid_h = \%{ $oids->{$dep_oid} };

    # Define our primary oid
    if ( not define_pri_oid( $oids, $oid, [$dep_oid] ) ) {

        # We should always ave a primary oid with this transform, so make a fatal error
        log_fatal("FATAL TEST: Device '$device' do not have any defined primary oid for oid '$oid'");
    }

    # Validate our dependencies
    validate_deps( $device, $oids, $oid, [$dep_oid] ) or return;

    # See if we are a repeating variable type datum
    # (such as that generated by snmpwalking a table)
    if ( $oid_h->{repeat} ) {

        # Unpack ze data
        for my $leaf ( keys %{ $dep_oid_h->{val} } ) {

            # Skip if we got a dependency error for this leaf
            next if ( ( exists $oid_h->{error} ) and ( exists $oid_h->{error}{$leaf} ) and ( $oid_h->{error}{$leaf} ) );

            #next if $oid_h->{error}{$leaf};

            my $packed = $dep_oid_h->{val}{$leaf};
            my @vars   = unpack $type, $packed;

            $oid_h->{val}{$leaf} = join $seperator, @vars;
        }

        # Otherwise we are a single entry datum
    } else {
        my $packed = $dep_oid_h->{val};
        my @vars   = unpack $type, $packed;

        $oid_h->{val} = join $seperator, @vars;

    }

    # Apply thresholds
    apply_threshold( $oids, $thr, $oid );
}

# Translate hex or octal data into decimal ##################################
sub trans_convert {
    my ( $device, $oids, $oid, $thr ) = @_;
    my $oid_h = \%{ $oids->{$oid} };

    # Extract our translation options
    my ( $dep_oid, $type, $pad ) = ( $1, lc $2, $3 )
        if $oid_h->{trans_data} =~ /^\{(.+)\}\s+(hex|oct)\s*(\d*)$/i;
    my $dep_oid_h = \%{ $oids->{$dep_oid} };

    # Define our primary oid
    if ( not define_pri_oid( $oids, $oid, [$dep_oid] ) ) {

        # We should always ave a primary oid with this transform, so make a fatal error
        log_fatal("FATAL TEST: Device '$device' do not have any defined primary oid for oid '$oid'");
    }

    # Validate our dependencies
    validate_deps( $device, $oids, $oid, [$dep_oid] ) or return;

    # See if we are a repeating variable type datum
    # (such as that generated by snmpwalking a table)
    if ( $oid_h->{repeat} ) {

        # Do our conversions
        for my $leaf ( keys %{ $dep_oid_h->{val} } ) {

            # Skip if we got a dependency error for this leaf
            next if ( ( exists $oid_h->{error} ) and ( exists $oid_h->{error}{$leaf} ) and ( $oid_h->{error}{$leaf} ) );

            #next if $oid_h->{error}{$leaf};

            my $val = $dep_oid_h->{val}{$leaf};
            my $int;
            if   ( $type eq 'oct' ) { $int = oct $val }
            else                    { $int = hex $val }
            $int = sprintf '%' . "$pad.$pad" . 'd', $int if $pad ne '';
            $oid_h->{val}{$leaf} = $int;
        }

        # Otherwise we are a single entry datum
    } else {
        my $val = $dep_oid_h->{val};
        my $int;
        if ( $type eq 'oct' ) {
            $int = oct $val;
        } else {
            $int = hex $val;
        }
        $int = sprintf '%' . "$pad.$pad" . 'd', $int if $pad ne '';
        $oid_h->{val} = $int;

    }

    # Apply thresholds
    apply_threshold( $oids, $thr, $oid );
}

# Do String translations ###############################################
# WiP: Not used at alli, not working
sub trans_eval {
    my ( $device, $oids, $oid, $thr ) = @_;
    my $oid_h = \%{ $oids->{$oid} };
    my $expr  = $oid_h->{trans_data};

    # Extract all our our parent oids from the expression, first
    my @dep_oids = $expr =~ /\{(.+?)\}/g;

    # Validate our dependencies
    validate_deps( $device, $oids, $oid, \@dep_oids )
        or return;

    # Also go through our non-repeaters and replace them in our
    # expression, since they are constant (i.e. not leaf dependent)
    my @repeaters;
    for my $dep_oid (@dep_oids) {
        push @repeaters, $dep_oid and next if $oids->{$dep_oid}{repeat};
        $expr =~ s/\{$dep_oid\}/$oids->{$dep_oid}{val}/g;
    }

    # Handle repeater-type oids
    if ( $oid_h->{repeat} ) {

        for ( my $i = 0; $i <= $#repeaters; $i++ ) {
            $expr =~ s/\{$repeaters[$i]\}/\$dep_val[$i]/g;
        }

        for my $leaf ( keys %{ $oids->{ $oid_h->{pri_oid} }{val} } ) {

            # Skip if we got a dependency error for this leaf
            next if ( ( exists $oid_h->{error} ) and ( exists $oid_h->{error}{$leaf} ) and ( $oid_h->{error}{$leaf} ) );

            #next if $oid_h->{error}{$leaf};

            # Update our dep_val values so that when we eval the expression it
            # will use the values of the proper leaf of the parent repeater oids
            my @dep_val;
            for (@repeaters) { push @dep_val, $oids->{$_}{val}{$leaf} }

            # Do our eval and set our time
            my $result = eval($expr);
            $oid_h->{time}{$leaf} = time;
            if ( $@ =~ /^Undefined subroutine/ ) {
                $result = 0;
            } elsif ($@) {
                do_log("Failed eval for TRANS_EVAL on $oid.$leaf: $expr ($@)", WARN);
                $oid_h->{val}{$leaf}   = 'Failed eval';
                $oid_h->{color}{$leaf} = 'clear';
                $oid_h->{error}{$leaf} = 1;
                next;
            }

            $oid_h->{val}{$leaf} = $result;
        }

        # Otherwise we are a single entry datum
    } else {

        # All of our non-reps were substituted earlier, so we can just eval
        my $result = eval $expr;
        $oid_h->{time} = time;

        if ( $@ =~ /^Undefined subroutine/ ) {
            $result = 0;
        } elsif ($@) {
            do_log("Failed eval for TRANS_STR on $oid: $expr ($@)", WARN);
            $oid_h->{val}   = 'Failed eval';
            $oid_h->{color} = 'clear';
            $oid_h->{error} = 1;
        }

        $oid_h->{val} = $result;

    }

    # Now apply our threshold to this data
    apply_threshold( $oids, $thr, $oid );
}

# Get the best color of one or more oids ################################
sub trans_best {
    my ( $device, $oids, $oid, $thr ) = @_;
    my $oid_h = \%{ $oids->{$oid} };

    # Extract all our our parent oids from the expression, first
    my @dep_oids = $oid_h->{trans_data} =~ /\{(.+?)\}/g;

    # define primary oid
    my $pri_oid_is_defined = define_pri_oid( $oids, $oid, \@dep_oids );

    if ($pri_oid_is_defined) {

        # Use a non-repeater type if we havent set it yet
        $oid_h->{repeat} ||= 0;
        my $pri_oid = $oid_h->{pri_oid};

        # Do repeater-type oids
        if ( $oid_h->{repeat} ) {

            # check first if we have a global color (not HASH but set directly) as we should not or we have an globale error
            if ( ref $oids->{$pri_oid}{color} ne 'HASH' ) {
                $oid_h->{color} = $oids->{$pri_oid}{color};
                $oid_h->{msg}   = $oids->{$pri_oid}{msg} if defined $oids->{$pri_oid}{msg};
            } else {

                for my $leaf ( keys %{ $oids->{ $oid_h->{pri_oid} }{val} } ) {

                    # Go through each parent oid for this leaf
                    #my $all_dep_oid_error = 1;    # we can suppose that all dep oid are in error, to trap the case.
                    for my $dep_oid (@dep_oids) {

                        #($dep_oid, my $sub1, my $sub2) = split /\./,$dep_oid;  # extract sub oid ie .color if exists
                        my $dep_oid_h = \%{ $oids->{$dep_oid} };

                        #my $dep_oid_h_val;
                        #if (defined $sub1) {
                        #   if (defined $sub2) {
                        #      $dep_oid_h_val = $dep_oid_h->{$sub1}{$sub2};
                        #   } else {
                        #      $dep_oid_h_val = $dep_oid_h->{$sub1};
                        #   }
                        #} else {
                        #   $dep_oid_h_val = $dep_oid_h->{val};
                        #}

                        # Skip if there was a dependency error for this parent oid leaf
                        #if (!$dep_oid_h->{error}{$leaf}) {
                        #   $all_dep_oid_error = 0;    # All dep oid are not in error
                        # }
                        # Skip if it is disable
                        #  next if ($dep_oid_h->{color}{$leaf} eq 'blue');

                        if ( $dep_oid_h->{repeat} ) {
                            if ( !defined $oid_h->{color}{$leaf}
                                or $colors{ $dep_oid_h->{color}{$leaf} } < $colors{ $oid_h->{color}{$leaf} } )
                            {
                                $oid_h->{val}{$leaf}   = $dep_oid_h->{val}{$leaf};
                                $oid_h->{color}{$leaf} = $dep_oid_h->{color}{$leaf};
                                if ( ( exists $dep_oid_h->{msg} ) and ( defined $dep_oid_h->{msg}{$leaf} ) and ( $dep_oid_h->{msg}{$leaf} ne '' ) ) {
                                    $oid_h->{msg}{$leaf} = $dep_oid_h->{msg}{$leaf};
                                } else {
                                    if ( ( exists $oid_h->{msg} ) and ( exists $oid_h->{msg}{$leaf} ) ) {
                                        delete $oid_h->{msg}{$leaf};
                                        delete $oid_h->{msg} unless %{ $oid_h->{msg} };
                                    }
                                }
                                $oid_h->{time}{$leaf} = time;
                            } elsif ( $dep_oid_h->{color}{$leaf} eq $oid_h->{color}{$leaf} ) {

                                #$oid_h->{val}{$leaf} .= "|" . $dep_oid_h->{val}{$leaf};
                                if ( defined $dep_oid_h->{val}{$leaf} and ( $dep_oid_h->{val}{$leaf} ne '' ) ) {
                                    if ( ( defined $oid_h->{val}{$leaf} ) and ( $oid_h->{val}{$leaf} ne '' ) and $oid_h->{val}{$leaf} ne $dep_oid_h->{val}{$leaf} ) {
                                        $oid_h->{val}{$leaf} .= "|" . $dep_oid_h->{val}{$leaf};
                                    } else {
                                        $oid_h->{val}{$leaf} = $dep_oid_h->{val}{$leaf};
                                    }
                                }
                                if ( ( exists $dep_oid_h->{msg} ) and ( defined $dep_oid_h->{msg}{$leaf} ) and ( $dep_oid_h->{msg}{$leaf} ne '' ) ) {
                                    if ( ( exists $oid_h->{msg} ) and ( defined $oid_h->{msg}{$leaf} ) and ( $oid_h->{msg}{$leaf} ne '' ) ) {
                                        $oid_h->{msg}{$leaf} .= " & " . $dep_oid_h->{msg}{$leaf};
                                    } else {
                                        $oid_h->{msg}{$leaf} = $dep_oid_h->{msg}{$leaf};
                                    }
                                }
                                $oid_h->{time}{$leaf} = time;
                            }
                        } else {

                            if ( !defined $oid_h->{color}{$leaf}
                                or $colors{ $dep_oid_h->{color} } < $colors{ $oid_h->{color}{$leaf} } )
                            {
                                $oid_h->{val}{$leaf}   = $dep_oid_h->{val};
                                $oid_h->{color}{$leaf} = $dep_oid_h->{color};
                                if ( ( defined $dep_oid_h->{msg} and $dep_oid_h->{msg} ne '' ) ) {
                                    $oid_h->{msg}{$leaf} = $dep_oid_h->{msg};
                                } else {
                                    if ( ( exists $oid_h->{msg} ) and ( exists $oid_h->{msg}{$leaf} ) ) {
                                        delete $oid_h->{msg}{$leaf};
                                        delete $oid_h->{msg} unless %{ $oid_h->{msg} };
                                    }
                                }
                                $oid_h->{time}{$leaf} = time;
                            } elsif ( $dep_oid_h->{color} eq $oid_h->{color}{$leaf} ) {

                                #$oid_h->{val}{$leaf} .= "|" . $dep_oid_h->{val}{$leaf};

                                if ( defined $dep_oid_h->{val} and ( $dep_oid_h->{val} ne '' ) ) {
                                    if ( ( defined $oid_h->{val}{$leaf} ) and ( $oid_h->{val}{$leaf} ne '' ) and $oid_h->{val}{$leaf} ne $dep_oid_h->{val} ) {
                                        $oid_h->{val}{$leaf} .= "|" . $dep_oid_h->{val};
                                    } else {
                                        $oid_h->{val}{$leaf} = $dep_oid_h->{val};
                                    }
                                }

                                if ( ( defined $dep_oid_h->{msg} and $dep_oid_h->{msg} ne '' ) ) {
                                    if ( ( exists $oid_h->{msg} ) and ( defined $oid_h->{msg}{$leaf} ) and ( $oid_h->{msg}{$leaf} ne '' ) ) {
                                        $oid_h->{msg}{$leaf} .= " & " . $dep_oid_h->{msg};
                                    } else {
                                        $oid_h->{msg}{$leaf} = $dep_oid_h->{msg};
                                    }
                                }
                                $oid_h->{time}{$leaf} = time;
                            }
                        }
                    }

                    # Check for this leaf is all dep oid are in error
                    #if ($all_dep_oid_error) {
                    #    $oid_h->{error}{$leaf} = 1;
                    #}
                }
            }

            # Otherwise we are a single entry datum
        } else {

            #my $all_dep_oid_error = 1;

            for my $dep_oid (@dep_oids) {

                #($dep_oid, my $sub) = split /\./,$dep_oid;  #add sub oid value (like .color) as possible oid dependency
                #$sub //= 'val';
                my $dep_oid_h = \%{ $oids->{$dep_oid} };

                #my $dep_oid_h_val = $dep_oid_h->{$sub};

                # If there is no dependency error for this parent oid leaf, we have a value!
                #if (!$dep_oid_h->{error}) {
                #   $all_dep_oid_error = 0;
                #}

                # and if it is disable (blue)
                #next if ($dep_oid_h->{error} && $dep_oid_h->{color} eq 'blue');

                if ( !defined $oid_h->{color}
                    or $colors{ $dep_oid_h->{color} } < $colors{ $oid_h->{color} } )
                {
                    #$oid_h->{val}        = $dep_oid_h_val;
                    $oid_h->{val}   = $dep_oid_h->{val};
                    $oid_h->{color} = $dep_oid_h->{color};
                    $oid_h->{msg}   = $dep_oid_h->{msg};

                    #$oid_h->{error}      = $dep_oid_h->{error};
                    $oid_h->{time} = time;
                } elsif ( $dep_oid_h->{color} eq $oid_h->{color} ) {

                    #if ( defined $oid_h->{val} ) {
                    #    if ( defined $dep_oid_h->{val} ) {
                    #        $oid_h->{val} .= "|" . $dep_oid_h->{val};
                    #    }
                    #} elsif ( defined $dep_oid_h->{val} ) {
                    #    $oid_h->{val} = $dep_oid_h->{val};
                    #}

                    if ( defined $dep_oid_h->{val} and ( $dep_oid_h->{val} ne '' ) ) {
                        if ( ( defined $oid_h->{val} ) and ( $oid_h->{val} ne '' ) and $oid_h->{val} ne $dep_oid_h->{val} ) {
                            $oid_h->{val} .= "|" . $dep_oid_h->{val};
                        } else {
                            $oid_h->{val} = $dep_oid_h->{val};
                        }
                    }

                    if ( defined $dep_oid_h->{msg} and ( $dep_oid_h->{msg} ne '' ) ) {
                        if ( ( defined $oid_h->{msg} ) and ( $oid_h->{msg} ne '' ) and ( index( $oid_h->{msg}, $dep_oid_h->{msg} ) == -1 ) ) {
                            $oid_h->{msg} .= " & " . $dep_oid_h->{msg};
                        } else {
                            $oid_h->{msg} = $dep_oid_h->{msg};
                        }
                    }
                    $oid_h->{time} = time;
                }
            }
        }
    } else {
        $oid_h->{color} = "clear";
        $oid_h->{msg}   = "Primary OID not defined";
    }
    apply_threshold( $oids, $thr, $oid );
}

# Get the worst color of one or more oids ##################################
sub trans_worst {
    my ( $device, $oids, $oid, $thr ) = @_;
    my $oid_h = \%{ $oids->{$oid} };

    # Extract all our our parent oids from the expression, first
    my @dep_oids = $oid_h->{trans_data} =~ /\{(.+?)\}/g;

    # define primary oid
    my $pri_oid_is_defined = define_pri_oid( $oids, $oid, \@dep_oids );

    if ($pri_oid_is_defined) {

        # Use a non-repeater type if we havent set it yet
        $oid_h->{repeat} ||= 0;
        my $pri_oid = $oid_h->{pri_oid};

        # Do repeater-type oids
        if ( $oid_h->{repeat} ) {

            # check first if we have a global color (not HASH but set directly) as we should not or we have an globale error
            if ( ref $oids->{$pri_oid}{color} ne 'HASH' ) {
                $oid_h->{color} = $oids->{$pri_oid}{color};
                $oid_h->{msg}   = $oids->{$pri_oid}{msg} if defined $oids->{$pri_oid}{msg};
            } else {

                for my $leaf ( keys %{ $oids->{ $oid_h->{pri_oid} }{val} } ) {

                    # Go through each parent oid for this leaf
                    for my $dep_oid (@dep_oids) {
                        my $dep_oid_h = \%{ $oids->{$dep_oid} };

                        # Skip if there was a dependency error for this parent oid leaf
                        # and if it is disable (blue)
                        #next if ( (exists $dep_oid_h->{error}) and (exists $dep_oid_h->{error}{$leaf}) and ($dep_oid_h->{error}{$leaf}));
                        # and ($dep_oid_h->{color}{$leaf} eq 'blue') );
                        #$oid_h->{color}{$leaf} = 'blue' and next if $dep_oid_h->{color}{$leaf} eq 'blue' ;

                        if ( $dep_oid_h->{repeat} ) {
                            if ( !defined $oid_h->{color}{$leaf}
                                or $colors{ $dep_oid_h->{color}{$leaf} } > $colors{ $oid_h->{color}{$leaf} } )
                            {
                                $oid_h->{val}{$leaf}   = $dep_oid_h->{val}{$leaf};
                                $oid_h->{color}{$leaf} = $dep_oid_h->{color}{$leaf};
                                if ( ( exists $dep_oid_h->{msg} ) and ( defined $dep_oid_h->{msg}{$leaf} ) and ( $dep_oid_h->{msg}{$leaf} ne '' ) ) {
                                    $oid_h->{msg}{$leaf} = $dep_oid_h->{msg}{$leaf};
                                } else {
                                    if ( ( exists $oid_h->{msg} ) and ( exists $oid_h->{msg}{$leaf} ) ) {
                                        delete $oid_h->{msg}{$leaf};
                                        delete $oid_h->{msg} unless %{ $oid_h->{msg} };
                                    }
                                }
                                $oid_h->{time}{$leaf} = time;
                            } elsif ( $dep_oid_h->{color}{$leaf} eq $oid_h->{color}{$leaf} ) {

                                #$oid_h->{val}{$leaf} .= "|" . $dep_oid_h->{val}{$leaf};

                                if ( defined $dep_oid_h->{val}{$leaf} and ( $dep_oid_h->{val}{$leaf} ne '' ) ) {
                                    if ( ( defined $oid_h->{val}{$leaf} ) and ( $oid_h->{val}{$leaf} ne '' ) and $oid_h->{val}{$leaf} ne $dep_oid_h->{val}{$leaf} ) {
                                        $oid_h->{val}{$leaf} .= "|" . $dep_oid_h->{val}{$leaf};
                                    } else {
                                        $oid_h->{val}{$leaf} = $dep_oid_h->{val}{$leaf};
                                    }
                                }

                                if ( ( exists $dep_oid_h->{msg} ) and ( defined $dep_oid_h->{msg}{$leaf} ) and ( $dep_oid_h->{msg}{$leaf} ne '' ) ) {
                                    if ( ( exists $oid_h->{msg} ) and ( defined $oid_h->{msg}{$leaf} ) and ( $oid_h->{msg}{$leaf} ne '' ) ) {
                                        $oid_h->{msg}{$leaf} .= " & " . $dep_oid_h->{msg}{$leaf};
                                    } else {
                                        $oid_h->{msg}{$leaf} = $dep_oid_h->{msg}{$leaf};
                                    }
                                }
                                $oid_h->{time}{$leaf} = time;
                            }
                        } else {

                            if ( !defined $oid_h->{color}{$leaf}
                                or $colors{ $dep_oid_h->{color} } > $colors{ $oid_h->{color}{$leaf} } )
                            {
                                $oid_h->{val}{$leaf}   = $dep_oid_h->{val};
                                $oid_h->{color}{$leaf} = $dep_oid_h->{color};
                                if ( ( defined $dep_oid_h->{msg} and $dep_oid_h->{msg} ne '' ) ) {
                                    $oid_h->{msg}{$leaf} = $dep_oid_h->{msg};
                                } else {
                                    if ( ( exists $oid_h->{msg} ) and ( exists $oid_h->{msg}{$leaf} ) ) {
                                        delete $oid_h->{msg}{$leaf};
                                        delete $oid_h->{msg} unless %{ $oid_h->{msg} };
                                    }
                                }
                                $oid_h->{time}{$leaf} = time;
                            } elsif ( $dep_oid_h->{color} eq $oid_h->{color}{$leaf} ) {

                                if ( defined $dep_oid_h->{val} and ( $dep_oid_h->{val} ne '' ) ) {
                                    if ( ( defined $oid_h->{val}{$leaf} ) and ( $oid_h->{val}{$leaf} ne '' ) and $oid_h->{val}{$leaf} ne $dep_oid_h->{val} ) {
                                        $oid_h->{val}{$leaf} .= "|" . $dep_oid_h->{val};
                                    } else {
                                        $oid_h->{val}{$leaf} = $dep_oid_h->{val};
                                    }
                                }

                                if ( ( defined $dep_oid_h->{msg} and $dep_oid_h->{msg} ne '' ) ) {
                                    if ( ( exists $oid_h->{msg} ) and ( defined $oid_h->{msg}{$leaf} ) and ( $oid_h->{msg}{$leaf} ne '' ) ) {
                                        $oid_h->{msg}{$leaf} .= " & " . $dep_oid_h->{msg};
                                    } else {
                                        $oid_h->{msg}{$leaf} = $dep_oid_h->{msg};
                                    }
                                }
                                $oid_h->{time}{$leaf} = time;
                            }
                        }
                    }
                }
            }

            # Otherwise we are a single entry datum
        } else {
            for my $dep_oid (@dep_oids) {
                my $dep_oid_h = \%{ $oids->{$dep_oid} };

                # Skip if there was a dependency error for this parent oid leaf
                # and if it is disable (blue)
                next if ( $dep_oid_h->{error} && $dep_oid_h->{color} eq 'blue' );

                if ( !defined $oid_h->{color}
                    or $colors{ $dep_oid_h->{color} } > $colors{ $oid_h->{color} } )
                {
                    $oid_h->{val}   = $dep_oid_h->{val};
                    $oid_h->{color} = $dep_oid_h->{color};
                    $oid_h->{msg}   = $dep_oid_h->{msg};

                    #$oid_h->{error} = $dep_oid_h->{error};
                    $oid_h->{time} = time;
                } elsif ( $dep_oid_h->{color} eq $oid_h->{color} ) {

                    if ( defined $dep_oid_h->{val} and ( $dep_oid_h->{val} ne '' ) ) {
                        if ( ( defined $oid_h->{val} ) and ( $oid_h->{val} ne '' ) and $oid_h->{val} ne $dep_oid_h->{val} ) {
                            $oid_h->{val} .= "|" . $dep_oid_h->{val};
                        } else {
                            $oid_h->{val} = $dep_oid_h->{val};
                        }
                    }

                    if ( defined $dep_oid_h->{msg} and ( $dep_oid_h->{msg} ne '' ) ) {
                        if ( ( defined $oid_h->{msg} ) and ( $oid_h->{msg} ne '' ) and ( index( $oid_h->{msg}, $dep_oid_h->{msg} ) == -1 ) ) {
                            $oid_h->{msg} .= " & " . $dep_oid_h->{msg};
                        } else {
                            $oid_h->{msg} = $dep_oid_h->{msg};
                        }
                    }
                    $oid_h->{time} = time;

                }
            }
        }
    } else {
        $oid_h->{color} = "clear";
        $oid_h->{msg}   = "Primary OID not defined";
    }

    # Now apply our threshold to this data
    apply_threshold( $oids, $thr, $oid );
}

# Return an (x days,)? hh:mm:ss date timestamp ##############################
sub trans_elapsed {
    my ( $device, $oids, $oid, $thr ) = @_;
    my $oid_h = \%{ $oids->{$oid} };

    # Extract our transform options
    my $dep_oid   = $1 if $oid_h->{trans_data} =~ /^\{(.+)\}$/;
    my $dep_oid_h = \%{ $oids->{$dep_oid} };

    # Define our primary oid
    if ( not define_pri_oid( $oids, $oid, [$dep_oid] ) ) {

        # We should always ave a primary oid with this transform, so make a fatal error
        log_fatal("FATAL TEST: Device '$device' do not have any defined primary oid for oid '$oid'");
    }

    # Validate our dependencies
    validate_deps( $device, $oids, $oid, [$dep_oid], '^[+-]?\d+(\.\d+)?$' )
        or return;

    # See if we are a repeating variable type datum
    # (such as that generated by snmpwalking a table)
    if ( $oid_h->{repeat} ) {

        for my $leaf ( keys %{ $dep_oid_h->{val} } ) {

            # Skip if there was a dependency error for this leaf
            next if ( ( exists $oid_h->{error} ) and ( exists $oid_h->{error}{$leaf} ) and ( $oid_h->{error}{$leaf} ) );

            #next if $oid_h->{error}{$leaf};

            my $s = $dep_oid_h->{val}{$leaf};
            my $d = int( $s / 86400 );
            $s %= 86400;
            my $h = int( $s / 3600 );
            $s %= 3600;
            my $m = int( $s / 60 );
            $s %= 60;

            my $elapsed = sprintf "%s%-2.2d:%-2.2d:%-2.2d", ( $d ? ( $d == 1 ? '1 day, ' : "$d days, " ) : '' ), $h, $m, $s;

            $oid_h->{val}{$leaf} = $elapsed;
        }

        # Otherwise we are a single entry datum
    } else {

        my $s = $dep_oid_h->{val};
        my $d = int( $s / 86400 );
        $s %= 86400;
        my $h = int( $s / 3600 );
        $s %= 3600;
        my $m = int( $s / 60 );
        $s %= 60;

        my $elapsed = sprintf "%s%-2.2d:%-2.2d:%-2.2d", ( $d ? ( $d == 1 ? '1 day, ' : "$d days, " ) : '' ), $h, $m, $s;

        $oid_h->{val} = $elapsed;

    }
    apply_threshold( $oids, $thr, $oid );
}

# Return an yy-mm, hh:mm:ss date timestamp ###############################
# WIP Not Used at all, not working
sub trans_date {
    my ( $device, $oids, $oid, $thr ) = @_;
    my $oid_h = \%{ $oids->{$oid} };

    # Extract our transform options
    my $dep_oid   = $1 if $oid_h->{trans_data} =~ /^\{(.+)\}$/;
    my $dep_oid_h = \%{ $oids->{$dep_oid} };

    # Validate our dependencies
    validate_deps( $device, $oids, $oid, [$dep_oid], '^\d+(\.\d+)?$' )
        or return;

    # See if we are a repeating variable type datum
    # (such as that generated by snmpwalking a table)
    if ( $oid_h->{repeat} ) {

        for my $leaf ( keys %{ $dep_oid_h->{val} } ) {

            # Skip if there was a dependency error for this leaf
            next if ( ( exists $oid_h->{error} ) and ( exists $oid_h->{error}{$leaf} ) and ( $oid_h->{error}{$leaf} ) );

            #next if $oid_h->{error}{$leaf};

            my ( $s, $m, $h, $d, $o, $y ) = localtime( $dep_oid_h->{val}{$leaf} );

            my $date = sprintf "%d-%-2.2d-%-2.2d, %-2.2d:%-2.2d:%-2.2d", $y + 1900, $o + 1, $d, $h, $m, $s;

            $oid_h->{val}{$leaf}   = $date;
            $oid_h->{time}{$leaf}  = time;
            $oid_h->{color}{$leaf} = $dep_oid_h->{color}{$leaf};
            $oid_h->{msg}{$leaf}   = $dep_oid_h->{msg}{$leaf};

        }

        # Otherwise we are a single entry datum
    } else {

        my ( $s, $m, $h, $d, $o, $y ) = localtime( $dep_oid_h->{val} );

        my $date = sprintf "%d-%-2.2d-%-2.2d, %-2.2d:%-2.2d:%-2.2d", $y + 1900, $o + 1, $d, $h, $m, $s;

        $oid_h->{val}   = $date;
        $oid_h->{time}  = time;
        $oid_h->{color} = $dep_oid_h->{color};
        $oid_h->{msg}   = $dep_oid_h->{msg};
    }
}

# Set a repeater OID to a constant (vector) value ###########################
# Define a repeater OID filled with constant values. The leaf values  start
# at 1, and incremetn by 1.
sub trans_set {
    my ( $device, $oids, $oid, $thr ) = @_;
    my $oid_h = \%{ $oids->{$oid} };

    my ( @Fields, $leaf );

    # Do not use the functions define_pri_oid and validate_deps. As there are no parent OIDs, only
    # constant values, it will have nothing to define or validate and it will generate a
    # leaf-type OID.
    $oid_h->{repeat} = 1;     # Make a repeater-type OID
    $oid_h->{val}    = {};    # Empty set of leafes
    $oid_h->{time}   = {};

    @Fields = split( /\s*,\s*/, $oid_h->{trans_data} );
    for ( $leaf = 1; $leaf <= @Fields; $leaf++ ) {
        $oid_h->{val}{$leaf}  = $Fields[ $leaf - 1 ];
        $oid_h->{time}{$leaf} = time;
    }                         # of for

    apply_threshold( $oids, $thr, $oid );
}    # of trans_set

# Convert value to its appropriate bps-speed ################################
sub trans_speed {
    my ( $device, $oids, $oid, $thr ) = @_;
    my $oid_h = \%{ $oids->{$oid} };

    # Extract our single dependant oid
    my $dep_oid   = $1 if $oid_h->{trans_data} =~ /^\{(.+)\}$/;
    my $dep_oid_h = \%{ $oids->{$dep_oid} };

    # Define our primary oid
    if ( not define_pri_oid( $oids, $oid, [$dep_oid] ) ) {

        # We should always ave a primary oid with this transform, so make a fatal error
        log_fatal("FATAL TEST: Device '$device' do not have any defined primary oid for oid '$oid'");
    }

    # Validate our dependencies
    validate_deps( $device, $oids, $oid, [$dep_oid], '^[+-]?\d+([.]\d+)?$' )
        or return;

    # Handle repeater-type oids
    if ( $oid_h->{repeat} ) {

        for my $leaf ( keys %{ $dep_oid_h->{val} } ) {

            # Skip if there was a dependency error for this leaf
            next if ( ( exists $oid_h->{error} ) and ( exists $oid_h->{error}{$leaf} ) and ( $oid_h->{error}{$leaf} ) );

            my $bps = int $dep_oid_h->{val}{$leaf};

            # Get largest speed type
            my $speed = 1;    # Start low: 1 bps
            $speed *= 1000 while abs($bps) >= ( $speed * 1000 );
            my $unit = $speeds{$speed};

            # Measure to 2 decimal places
            my $new_speed = sprintf '%.2f %s', $bps / $speed, $unit;

            $oid_h->{val}{$leaf} = $new_speed;

        }

        # Otherwise we are a single entry datum
    } else {

        my $bps = $dep_oid_h->{val};

        # Get largest speed type
        my $speed = 1;    # Start low: 1 bps
        $speed *= 1000 while abs($bps) >= ( $speed * 1000 );
        my $unit = $speeds{$speed};

        # Measure to 2 decimal places
        my $new_speed = sprintf '%.2f %s', $bps / $speed, $unit;
        $oid_h->{val} = $new_speed;

    }
    apply_threshold( $oids, $thr, $oid );
}

# C-style 'case', with ranges ##############################################
sub trans_switch {
    my ( $device, $oids, $oid, $thr ) = @_;
    my $oid_h      = \%{ $oids->{$oid} };
    my $trans_data = \%{ $oid_h->{trans_edata} };
    my $dep_oid    = $trans_data->{dep_oid};
    my $dep_oid_h  = \%{ $oids->{$dep_oid} };
    my $cases      = \%{ $trans_data->{cases} };
    my $case_nums  = \@{ $trans_data->{case_nums} };
    my $default    = $trans_data->{default} if defined $trans_data->{default};

    # Define our primary oid
    if ( not define_pri_oid( $oids, $oid, [$dep_oid] ) ) {

        # We should always ave a primary oid with this transform, so make a fatal error
        log_fatal("FATAL TEST: Device '$device' do not have any defined primary oid for oid '$oid'");
    }

    # Validate our dependencies
    # We cannot validate globally all dependencies, but we can validate the first
    # one as this one is global, for the rest we should do it later
    # can be switch dependecies we have to do it for each leaf individually
    validate_deps( $device, $oids, $oid, [$dep_oid] ) or return;

    if ( $oid_h->{repeat} ) {
        for my $leaf ( keys %{ $dep_oid_h->{val} } ) {

            # Skip if there was a dependency error for this leaf
            next if ( ( exists $oid_h->{error} ) and ( exists $oid_h->{error}{$leaf} ) and ( $oid_h->{error}{$leaf} ) );

            my $val = $dep_oid_h->{val}{$leaf};
            my $num;
            for my $case (@$case_nums) {
                my $if   = $cases->{$case}{if};
                my $type = $cases->{$case}{type};
                if ( $type eq 'num' ) { $num = $case and last if $val == $if; next }
                if ( $type eq 'gt' )  { $num = $case and last if $val > $if;  next }
                if ( $type eq 'gte' ) { $num = $case and last if $val >= $if; next }
                if ( $type eq 'lt' )  { $num = $case and last if $val < $if;  next }
                if ( $type eq 'lte' ) { $num = $case and last if $val <= $if; next }
                if ( $type eq 'rng' ) {
                    my ( $ll, $ul ) = split /-/, $if;
                    $num = $case and last if $val >= $ll and $val <= $ul;
                    next;
                }
                if ( $type eq 'str' ) { $num = $case and last if $val eq $if;   next }
                if ( $type eq 'reg' ) { $num = $case and last if $val =~ /$if/; next }
            }

            my $then;
            my $then_default;
            if ( defined $num ) {
                $then         = $cases->{$num}{then};
                $then_default = $default;
            } elsif ( defined $default ) {
                $then = $default;
            }

            while ( $then =~ /\{(\S+)\}/g ) {
                my $dep_oid   = $1;
                my $dep_oid_h = \%{ $oids->{$dep_oid} };
                my $dep_val;
                my $dep_error;
                my $dep_color;
                my $dep_msg;
                if ( $oids->{$dep_oid}{repeat} ) {
                    $dep_val   = $dep_oid_h->{val}{$leaf};
                    $dep_color = $dep_oid_h->{color}{$leaf};
                    $dep_msg   = $dep_oid_h->{msg}{$leaf} if ( ( exists $dep_oid_h->{msg} ) and ( defined $dep_oid_h->{msg}{$leaf} ) );
                } else {
                    $dep_val   = $dep_oid_h->{val};
                    $dep_color = $dep_oid_h->{color};
                    $dep_msg   = $dep_oid_h->{msg} if ( ( exists $dep_oid_h->{msg} ) and ( defined $dep_oid_h->{msg}{$leaf} ) );
                }
                if ( !defined $dep_val ) {
                    if ( defined $then_default ) {
                        $then         = $then_default;
                        $then_default = undef;
                        next;
                    } else {

                        # We should never be here with an undef val as it
                        # should be alread treated: severity increase to yellow
                        $dep_val = undef;

                        #$oid_h->{color}{$leaf} = 'clear';
                        #$oid_h->{msg}{$leaf}   = 'parent value n/a';
                        last;
                    }
                } elsif ( $dep_val eq 'wait' ) {
                    $oid_h->{color}{$leaf} = 'clear';
                    $oid_h->{msg}{$leaf}   = 'wait';
                    last;
                } else {

                    # Find de worst color
                    if ( !defined $oid_h->{color}{$leaf}
                        or $colors{$dep_color} > $colors{ $oid_h->{color}{$leaf} } )
                    {
                        $oid_h->{color}{$leaf} = $dep_color;
                        $oid_h->{msg}{$leaf}   = $dep_msg;
                    } elsif ( $oid_h->{color}{$leaf} eq $dep_color ) {
                        if ( defined $dep_msg ) {
                            if ( defined $oid_h->{msg}{$leaf} and $oid_h->{msg}{$leaf} ne '' ) {
                                $oid_h->{msg}{$leaf} .= " & " . $dep_msg;
                            } else {
                                $oid_h->{msg}{$leaf} = $dep_msg;
                            }
                        }
                    }
                }
                $then =~ s/\{$dep_oid\}/$dep_val/g;
            }

            $oid_h->{val}{$leaf} = $then;

        }

        # Otherwise non repeater
    } else {
        my $val = $dep_oid_h->{val};
        my $num;
        for my $case (@$case_nums) {
            my $if   = $cases->{$case}{if};
            my $type = $cases->{$case}{type};
            if ( $type eq 'num' ) { $num = $case and last if $val == $if; next }
            if ( $type eq 'gt' )  { $num = $case and last if $val > $if;  next }
            if ( $type eq 'gte' ) { $num = $case and last if $val >= $if; next }
            if ( $type eq 'lt' )  { $num = $case and last if $val < $if;  next }
            if ( $type eq 'lte' ) { $num = $case and last if $val <= $if; next }
            if ( $type eq 'rng' ) {

                #my ($ll,$ul) = split /-/, $if;
                my ( $ll, $ul ) = $if =~ /([+-]?\d+(?:\.\d+)?)\s?(?:-|..)\s?([+-]?\d+(?:\.\d+)?)/;

                $num = $case and last if $val >= $ll and $val <= $ul;
                next;
            }
            if ( $type eq 'str' ) { $num = $case and last if $val eq $if;   next }
            if ( $type eq 'reg' ) { $num = $case and last if $val =~ /$if/; next }
        }

        my $then;
        my $then_default;
        if ( defined $num ) {
            $then         = $cases->{$num}{then};
            $then_default = $default;
        } elsif ( defined $default ) {
            $then = $default;
        }
        while ( $then =~ /\{(\S+)\}/g ) {
            my $dep_oid   = $1;
            my $dep_oid_h = \%{ $oids->{$dep_oid} };
            my $dep_val;
            my $dep_error;
            my $dep_color;
            my $dep_msg;
            if ( $oids->{$dep_oid}{repeat} ) {
                do_log( "Cant switch to a repeater OID when using a non-repeater source OID for trans_switch on $oid", WARN );
                $dep_val   = undef;
                $dep_error = 1;
                $dep_color = 'yellow';
                $dep_msg   = 'Wrong parent OID: it should not be a repeater';
            } else {
                $dep_val   = $dep_oid_h->{val};
                $dep_color = $dep_oid_h->{color};
                $dep_msg   = $dep_oid_h->{msg};
            }
            if ( !defined $dep_val ) {
                if ( defined $then_default ) {
                    $then         = $then_default;
                    $then_default = undef;
                    next;
                } else {

                    # We should never be here with an undef val as it
                    # should be alread treated: severity increase to yellow

                    #$dep_val        = undef;
                    #$oid_h->{color} = 'clear';
                    #$oid_h->{msg}   = 'parent value n/a';
                    last;
                }
            } elsif ( $dep_val eq 'wait' ) {
                $oid_h->{color} = 'clear';
                $oid_h->{msg}   = 'wait';
            } elsif ($dep_error) {

                # Find de worst color

                if ( !defined $oid_h->{color}
                    or $colors{$dep_color} > $colors{ $oid_h->{color} } )
                {
                    $oid_h->{color} = $dep_color;
                    $oid_h->{msg}   = $dep_msg;
                } elsif ( $oid_h->{color} eq $dep_color ) {
                    if ( defined $dep_msg ) {
                        if ( defined $oid_h->{msg} and $oid_h->{msg} ne '' ) {
                            $oid_h->{msg} .= " & " . $dep_msg;
                        } else {
                            $oid_h->{msg} = $dep_msg;
                        }
                    }
                }
            } else {

            }
            $then =~ s/\{$dep_oid\}/$dep_val/g;
        }

        $oid_h->{val} = $then;
    }
    apply_threshold( $oids, $thr, $oid );
}

# Regular expression substitutions #########################################
sub trans_regsub {
    my ( $device, $oids, $oid, $thr ) = @_;
    my $oid_h      = \%{ $oids->{$oid} };
    my $trans_data = $oid_h->{trans_data};
    my ( $main_oid, $expr ) = ( $1, $2, )
        if $trans_data =~ /^\{(.+)\}\s*(\/.+\/.*\/[eg]*)$/;

    #if $trans_data =~ /^\{(.+)\}\s*\/(.+)\/(.*)\/[eg]*)$/;
    my ( $src_expr, $trg_expr ) = ( $1, $2 )
        if $expr =~ /^(.+)\/(.*)/;

    # Extract all our our parent oids from the expression, first
    #    my @dep_oids = $trans_data =~ /\{(.+?)\}/g;
    my @dep_oids = $src_expr =~ /\{(.+?)\}/g;
    unshift @dep_oids, ($main_oid);

    # Define our primary oid
    if ( !define_pri_oid( $oids, $oid, \@dep_oids ) ) {

        # We should always ave a primary oid with this transform, so make a fatal error
        log_fatal("FATAL TEST: Device '$device' do not have any defined primary oid for oid '$oid'");
    }

    # Validate our dependencies
    if ( not validate_deps( $device, $oids, $oid, \@dep_oids ) ) {
        do_log( "Regsub transform on $device/$oid do not have valid dependencies: skipping", DEBUG ) if $g{debug};
        return;
    }

    # Also go through our non-repeaters and replace them in our
    # expression, since they are constant (i.e. not leaf dependent)
    my @repeaters;
    for my $dep_oid (@dep_oids) {
        push @repeaters, $dep_oid and next if $oids->{$dep_oid}{repeat};
        $expr =~ s/\{$dep_oid\}/$oids->{$dep_oid}{val}/g;
    }

    # See if we are a repeating variable type datum
    # (such as that generated by snmpwalking a table)
    if ( $oid_h->{repeat} ) {

        # Map the names of our repeater oids to a position on a placeholder array
        for ( my $i = 0; $i <= $#repeaters; $i++ ) {
            $expr =~ s/\{$repeaters[$i]\}/\$dep_val[$i]/g;
        }
        for my $leaf ( keys %{ $oids->{ $oid_h->{pri_oid} }{val} } ) {

            # Skip if there was a dependency error for this leaf
            next if ( ( exists $oid_h->{error} ) and ( exists $oid_h->{error}{$leaf} ) and ( $oid_h->{error}{$leaf} ) );

            #next if $oid_h->{error}{$leaf};

            # Update our dep_val values so that when we eval the expression it
            # will use the values of the proper leaf of the parent repeater oids
            my @dep_val;
            for (@repeaters) { push @dep_val, $oids->{$_}{val}{$leaf} }

            my $exp_val = $oids->{$main_oid}{val}{$leaf};
            my $result;
            $result = eval "\$exp_val =~ s$expr";
            if ($@) {
                do_log( "Failed eval for REGSUB transform on leaf $leaf of $oid on $device ($@)", ERROR );
                $oid_h->{val}{$leaf}   = 'Failed eval';
                $oid_h->{color}{$leaf} = 'clear';

                next;
            }
            $oid_h->{val}{$leaf} = $exp_val;
        }

        # Otherwise we are a single entry datum
    } else {

        # All of our non-reps were substituted earlier, so we can just eval
        my $exp_val = $oids->{$main_oid}{val};
        my $result  = eval "\$exp_val =~ s$expr";

        if ($@) {
            do_log( "Failed eval for REGSUB transform on $oid on $device ($@)", WARN );
            $oid_h->{val}   = 'Failed eval';
            $oid_h->{color} = 'clear';

            return;
        }
        $oid_h->{val} = $exp_val;

    }

    # Now apply our threshold to this data
    apply_threshold( $oids, $thr, $oid );
}

# Do oid chaining ###########################################################
# This entails taking the index from the source OID and using it as the
# new index for the target oid. The mapping between bot OID is done with
# the source OID values that should be a subset of the indexes of the target OID
sub trans_chain {
    my ( $device, $oids, $oid, $thr ) = @_;
    my $oid_h = \%{ $oids->{$oid} };

    # Extract all our our parent oids from the expression, first
    my ( $src_oid, $trg_oid ) = $oid_h->{trans_data} =~ /\{(.+?)\}/g;

    # Define our primary oid
    if ( not define_pri_oid( $oids, $oid, [$src_oid] ) ) {

        # We should always ave a primary oid with this transform, so make a fatal error
        log_fatal("FATAL TEST: Device '$device' do not have any defined primary oid for oid '$oid'");
    }

    # Validate our dependencies, have to do them seperately
    # Cannot validate the target oid has it has not the same hash keys as our result
    validate_deps( $device, $oids, $oid, [$src_oid] )
        or return;

    # Canvalidate_deps( $device, $oids, $oid, [$src_oid], '^\.?(\d+\.)*\d+$' )
    #    or return;

    my $src_h = \%{ $oids->{$src_oid} };
    my $trg_h = \%{ $oids->{$trg_oid} };

    # Our target MUST be a repeater type oid
    if ( !$trg_h->{repeat} ) {
        do_log( "Trying to chain a non-repeater target on $device ($@)", WARN );
        $oid_h->{repeat} = 0;
        $oid_h->{val}    = 'Failed chain';
        $oid_h->{time}   = time;
        $oid_h->{color}  = 'clear';

    }

    # If our target is a repeater, and our source is a non-repeater,
    # then our transform oid will consequently be a non-repeater
    if ( !$src_h->{repeat} ) {
        $oid_h->{repeat} = 0;
        my $sub_oid = $src_h->{val};
        my $trg_val = $trg_h->{val}{$sub_oid};
        if ( !defined $trg_val ) {
            $oid_h->{val}   = undef;
            $oid_h->{time}  = time;
            $oid_h->{color} = defined $trg_h->{color}         ? $trg_h->{color}         : "clear";
            $oid_h->{msg}   = defined $trg_h->{msg}{$sub_oid} ? $trg_h->{msg}{$sub_oid} : "Parent value n/a";
        }

        $oid_h->{val}   = $trg_val;
        $oid_h->{time}  = $trg_h->{time}{$sub_oid};
        $oid_h->{color} = $trg_h->{color}{$sub_oid};

        # Both source and target are repeaters.  Go go go!
    } else {
        for my $leaf ( keys %{ $src_h->{val} } ) {

            # Skip if our source oid is freaky-deaky
            next if ( ( exists $oid_h->{error} ) and ( exists $oid_h->{error}{$leaf} ) and ( $oid_h->{error}{$leaf} ) );

            # Our oid sub leaf
            my $sub_oid = $src_h->{val}{$leaf};
            my $trg_val = $trg_h->{val}{$sub_oid};
            if ( !defined $trg_val ) {
                $oid_h->{val}{$leaf}  = undef;
                $oid_h->{time}{$leaf} = time;
                if ( ref $oid_h->{color} eq 'HASH' ) {
                    $oid_h->{color}{$leaf} = defined $trg_h->{color}{$sub_oid} ? $trg_h->{color}{$sub_oid} : "clear";
                }
                if ( ref $oid_h->{msg} eq 'HASH' ) {
                    $oid_h->{msg}{$leaf} = defined $trg_h->{msg}{$sub_oid} ? $trg_h->{msg}{$sub_oid} : "";    # should be "parent n/a"
                }
                next;
            }
            $oid_h->{val}{$leaf}   = $trg_val;
            $oid_h->{time}{$leaf}  = $trg_h->{time}{$sub_oid};
            $oid_h->{color}{$leaf} = $trg_h->{color}{$sub_oid};
        }
        $oid_h->{repeat} = 1;
    }

    # Apply thresholds
    apply_threshold( $oids, $thr, $oid );
}

# Do coltre #########################################################
# Collect and accumulate data (=trg) in a tree (a tree structure is in a table)
# by using a pointer to a parent or child (=src) oid value : Each leaf look
# recursively until a non existing value. Optionnal args ...:arg1, arg2
# Arg1: Separate the accumulate data with separator string (default = '')
# Arg2: Pad data before accumulation. Example
#       r5( )  : pad from left with space to length of 5.
#       l{+}   : pad from right with + . Length is detected automatically
sub trans_coltre {
    my ( $device, $oids, $oid, $thr ) = @_;
    my $oid_h          = \%{ $oids->{$oid} };
    my $expr           = $oid_h->{trans_data};
    my $separator      = '';
    my $padding_type   = 'l';
    my $padding_length = 'auto';
    my $padding_char   = '';

    # Extract our optional arguments
    $padding_char   = $1 if $expr =~ s/[(<](.)[)>]$//;
    $padding_length = $1 if $expr =~ s/(\d+?)$//;
    $padding_type   = $1 if $expr =~ s/\s*[,:]\s*([rl])$//;
    $separator      = $1 if $expr =~ s/\s+:\s*(\S+)$//;

    # Extract all our our parent oids from the expression, first
    my ( $src_oid, $trg_oid ) = $expr =~ /\{(.+)\}\s+\{(.+)\}$/;

    # Define our primary oid
    if ( not define_pri_oid( $oids, $oid, [$src_oid] ) ) {

        # We should always ave a primary oid with this transform, so make a fatal error
        log_fatal("FATAL TEST: Device '$device' do not have any defined primary oid for oid '$oid'");
    }

    # Validate our dependencies, have to do them seperately
    validate_deps( $device, $oids, $oid, [$src_oid], '^\.?(\d+\.)*\d+' ) and validate_deps( $device, $oids, $oid, [$trg_oid] )
        or return;

    my $src_h = \%{ $oids->{$src_oid} };
    my $trg_h = \%{ $oids->{$trg_oid} };
    if ( $padding_char ne '' ) {
        if ( $padding_length eq 'auto' ) {
            my $maxlength = 0;
            my %value_length;
            while ( my ( $key, $value ) = each %{ $trg_h->{val} } ) {
                $value_length{$key} = length($value);
                if ( $maxlength < $value_length{$key} ) {
                    $maxlength = $value_length{$key};
                }
            }
            while ( my ( $key, $value ) = each %value_length ) {
                if ( $padding_type eq 'l' ) {
                    $trg_h->{val}{$key} = $padding_char x ( $maxlength - $value_length{$key} ) . $trg_h->{val}{$key};
                } else {
                    $trg_h->{val}{$key} .= $padding_char x ( $maxlength - $value_length{$key} );
                }
            }
        } else {
            while ( my ( $key, $value ) = each %{ $trg_h->{val} } ) {
                if ( $padding_type eq 'l' ) {
                    $trg_h->{val}{$key}
                        = $padding_char x ( $padding_length - length( $trg_h->{val}{$key} ) ) . $trg_h->{val}{$key};
                } else {
                    $trg_h->{val}{$key} .= $padding_char x ( $padding_length - length( $trg_h->{val}{$key} ) );
                }
            }
        }
    }

    # Our source MUST be a repeater type oid
    if ( !$trg_h->{repeat} ) {
        do_log( "Trying to COLTRE a non-repeater 1rst oid on $device ($@)", WARN );
        $oid_h->{repeat} = 0;
        $oid_h->{val}    = 'Failed coltre';
        $oid_h->{time}   = time;
        $oid_h->{color}  = 'clear';

        # Our target MUST be a repeater type oid
    } elsif ( !$trg_h->{repeat} ) {
        do_log( "Trying to COLTRE a non-repeater 2nd oid on $device ($@)", WARN );
        $oid_h->{repeat} = 0;
        $oid_h->{val}    = 'Failed coltre';
        $oid_h->{time}   = time;
        $oid_h->{color}  = 'yellow';

        # Both source and target are repeaters.  Go go go!
    } else {
        my $isfirst = 1;
        for my $leaf ( sort { $src_h->{val}{$a} <=> $src_h->{val}{$b} } keys %{ $src_h->{val} } ) {

            # Skip if our source oid is freaky-deaky
            next if ( ( exists $oid_h->{error} ) and ( exists $oid_h->{error}{$leaf} ) and ( $oid_h->{error}{$leaf} ) );

            #TODO CHECK $oid_h->{val}{$src_h}{val}{$leaf}} if it exist
            if ($isfirst) {
                $oid_h->{val}{$leaf} = $trg_h->{val}{$leaf};
                $isfirst = 0;
            } else {
                $oid_h->{val}{$leaf} = $oid_h->{val}{ $src_h->{val}{$leaf} } . $separator . $trg_h->{val}{$leaf};
            }
            $oid_h->{color}{$leaf} = $trg_h->{color}{$leaf};

        }

        # Apply thresholds
        $oid_h->{repeat} = 1;
    }

    # Apply thresholds
    apply_threshold( $oids, $thr, $oid );
}

# Do Sort Transform ######################################################
# Sort
# This operator schould be combined with the chain operator
sub trans_sort {
    my ( $device, $oids, $oid, $thr ) = @_;
    my $oid_h = \%{ $oids->{$oid} };
    my $expr  = $oid_h->{trans_data};
    my $sort  = 'txt';

    # Extract our optional arguments (NOT WORKING ONLY DEFAULT "TXT")
    $sort = $1 if $expr =~ s/\s+:\s*(num|txt)*//i;

    # Extract all our our parent oids from the expression, first
    my ($src_oid) = $expr =~ /^\{(.+)\}$/;

    # Define our primary oid
    if ( not define_pri_oid( $oids, $oid, [$src_oid] ) ) {

        # We should always ave a primary oid with this transform, so make a fatal error
        log_fatal("FATAL TEST: Device '$device' do not have any defined primary oid for oid '$oid'");
    }

    # We dont validate dep as it valid and value: we ony work on index
    #validate_deps( $device, $oids, $oid, [$src_oid] )
    #    or return;

    do_log( "Transforming $src_oid to $oid via 'sort' transform", DEBUG ) if $g{debug};

    # This transform should probably only work for repeater sources
    my $src_h = \%{ $oids->{$src_oid} };
    if ( !$src_h->{repeat} ) {
        do_log( "Trying to SORT a non-repeater source on $device ($@)", WARN );
        return;
    } else {

        # Tag the target as a repeater
        $oid_h->{repeat} = 2;
        if ( $sort eq 'txt' ) {
            my $pad        = 1;
            my @oid_sorted = defined $src_h->{val} ? oid_sort( keys %{ $src_h->{val} } ) : ();
            if (@oid_sorted) {
                for my $leaf (@oid_sorted) {

                    # Skip if our source oid is freaky-deaky
                    next if ( ( exists $oid_h->{error} ) and ( exists $oid_h->{error}{$leaf} ) and ( $oid_h->{error}{$leaf} ) );
                    $oid_h->{val}{$leaf} = $pad++;
                }

            } else {

                # The list is empty, treat it as a non repeater
                $oid_h->{val}   = undef;
                $oid_h->{time}  = $src_h->{time}  if defined $src_h->{time};
                $oid_h->{color} = $src_h->{color} if defined $src_h->{color};
                $oid_h->{msg}   = $src_h->{msg}   if defined $src_h->{msg};
            }
        } elsif ( $sort eq 'num' ) {
            my $pad = 1;
            for my $leaf ( sort { $src_h->{val}{$a} <=> $src_h->{val}{$b} } keys %{ $src_h->{val} } ) {

                # Skip if our source oid is freaky-deaky
                next if ( ( exists $oid_h->{error} ) and ( exists $oid_h->{error}{$leaf} ) and ( $oid_h->{error}{$leaf} ) );

                # Our oid sub leaf

                if ( !defined $leaf ) {
                    $oid_h->{val}{$leaf}   = 'SHOULD NEVER ARRIVE: CAN BE REMOVED';
                    $oid_h->{time}{$leaf}  = time;
                    $oid_h->{color}{$leaf} = 'yellow';
                    $oid_h->{error}{$leaf} = 1;
                    next;
                }

                $oid_h->{val}{$leaf}   = $pad++;
                $oid_h->{time}{$leaf}  = $src_h->{time}{$leaf};
                $oid_h->{color}{$leaf} = $src_h->{color}{$leaf};
                $oid_h->{error}{$leaf} = $src_h->{error}{$leaf};
            }
        } else {
            for my $leaf ( keys %{ $src_h->{val} } ) {

                # Skip if our source oid is freaky-deaky
                next if ( ( exists $oid_h->{error} ) and ( exists $oid_h->{error}{$leaf} ) and ( $oid_h->{error}{$leaf} ) );

                # Our oid sub leaf
                if ( !defined $leaf ) {
                    $oid_h->{val}{$leaf}   = 'SHOULD NEVER ARRIVE: CAN BE REMOVED';
                    $oid_h->{time}{$leaf}  = time;
                    $oid_h->{color}{$leaf} = 'yellow';
                    $oid_h->{error}{$leaf} = 1;
                    next;
                }

                $oid_h->{val}{$leaf}   = $leaf;
                $oid_h->{time}{$leaf}  = $src_h->{time}{$leaf};
                $oid_h->{color}{$leaf} = $src_h->{color}{$leaf};
                $oid_h->{error}{$leaf} = $src_h->{error}{$leaf};
            }
        }
    }

    # Apply thresholds
    apply_threshold( $oids, $thr, $oid );
}

# Return index values ######################################################
# In some cases, the index value in a repeating OID is useful data to have
# Examples of this are the index in the cdp table, which refer to the
# ifIndex (the only way to get the near side interface name), another
# example is some load balancer MIBs which include vserver/real server
# detail only in the index
# This is more or less the inverse of the chain operator
sub trans_index {
    my ( $device, $oids, $oid, $thr ) = @_;

    # As this transform onely work on hash keys (and has keys are keep between runs: save the current structure, before validation and recover it it validation fail: should be better to do this in the validation sub
    # my $oid_h = \%{ $oids->{$oid} };
    my $old_oid_h = dclone $oids->{$oid};    # we have to make a real copy (deep)

    # Extract our parent oids from the expression, first
    my ($src_oid) = $oids->{$oid}{trans_data} =~ /^\{(.+)\}$/;

    my $src_h = \%{ $oids->{$src_oid} };

    #Define our primary oid
    if ( not define_pri_oid( $oids, $oid, [$src_oid] ) ) {

        # We should always ave a primary oid with this transform, so make a fatal error
        log_fatal("FATAL TEST: Device '$device' do not have any defined primary oid for oid '$oid'");
    }

    # we do not validate our dependencies as we are  working ony on index
    if ( not validate_deps( $device, $oids, $oid, [$src_oid] ) ) {
        do_log( "Index transform on $device/$oid do not have valid dependencies: skipping", DEBUG ) if $g{debug};

        # We can use old keys of val stored in current oid, if they existi (inormally should)
        if ( defined $old_oid_h->{val} ) {
            do_log( "Recover index transform as it was previously defined", INFO );
            $src_h = $old_oid_h;           # use iteself as it has save its key and we dont have them from the dependent oid
            $oids->{$oid} = $old_oid_h;    # copy back the saved hash
        } else {
            return;
        }
    }
    my $oid_h = \%{ $oids->{$oid} };

    # This transform should probably only work for repeater sources
    if ( !$src_h->{repeat} ) {
        do_log( "Trying to index a non-repeater source on $device ($@)", ERROR );
        return;
    } else {

        # Tag the target as a repeater
        $oid_h->{repeat} = 2;
        if ( defined $src_h->{val} ) {
            for my $leaf ( keys %{ $src_h->{val} } ) {

                # Skip if our source oid is freaky-deaky
                next if ( ( exists $oid_h->{error} ) and ( exists $oid_h->{error}{$leaf} ) and ( $oid_h->{error}{$leaf} ) );

                # Our oid sub leaf

                if ( !defined $leaf ) {
                    $oid_h->{val}{$leaf}   = undef;
                    $oid_h->{time}{$leaf}  = $src_h->{time}{$leaf} if defined $src_h->{time}{$leaf};                                      # should always be defined, just to be sure
                    $oid_h->{color}{$leaf} = defined $src_h->{color}{$leaf} ? $src_h->{color}{$leaf} : 'clear';
                    $oid_h->{msg}{$leaf}   = $src_h->{msg}{$leaf} if ( ( exists $src_h->{msg} ) and ( defined $src_h->{msg}{$leaf} ) );
                    next;
                }

                $oid_h->{val}{$leaf}   = $leaf;
                $oid_h->{time}{$leaf}  = $src_h->{time}{$leaf} if defined $src_h->{time}{$leaf};                                      # should always be defined, just to be sure
                $oid_h->{color}{$leaf} = defined $src_h->{color}{$leaf} ? $src_h->{color}{$leaf} : 'green';
                $oid_h->{msg}{$leaf}   = $src_h->{msg}{$leaf} if ( ( exists $src_h->{msg} ) and ( defined $src_h->{msg}{$leaf} ) );
            }
        } else {

            $oid_h->{time}  = $src_h->{time} if defined $src_h->{time};
            $oid_h->{color} = defined $src_h->{color} ? $src_h->{color} : 'clear';
            $oid_h->{msg}   = $src_h->{msg} if defined $src_h->{msg};

        }
    }

    # Apply thresholds
    apply_threshold( $oids, $thr, $oid );
}

# Extract names and values from simple tables #############################
# Some MIBs just return a table of names and values, with rows that  have
# different data, types, meanings, units etc.
# This operator allows the creation of new columns for rows where the name
# column matches the provided regex
sub trans_match {
    my ( $device, $oids, $oid, $thr ) = @_;

    my $oid_h = \%{ $oids->{$oid} };

    # Extract our parent oids from the expression, first
    my $trans_data = $oid_h->{trans_data};
    my ( $src_oid, $expr ) = ( $1, $2 )
        if $trans_data =~ /^\{(\S+)\}\s+(\/.+\/)$/;

    # Define our primary oid
    if ( not define_pri_oid( $oids, $oid, [$src_oid] ) ) {

        # We should always ave a primary oid with this transform, so make a fatal error
        log_fatal("FATAL TEST: Device '$device' do not have any defined primary oid for oid '$oid'");
    }

    # Validate our dependencies
    # Cannot validate dependencies as it has not the same hash keys as our result dont have the same key
    #
    #validate_deps( $device, $oids, $oid, [$src_oid], '.*' )    # match
    #    or return;
    #do_log( "DEBUG TEST: Transforming $src_oid to $oid via match transform matching $expr", 4 ) if $g{debug};

    my $src_h = \%{ $oids->{$src_oid} };

    # This transform should probably only work for repeater sources
    if ( !$src_h->{repeat} ) {
        do_log( "Trying to index a non-repeater source on $device ($@)", WARN );
        return;
    } elsif ( defined $src_h->{error} and ( ref $src_h->{error} ne ref {} ) and $src_h->{error} == 1 ) {
        $oid_h->{color}  = $src_h->{color};
        $oid_h->{msg}    = $src_h->{msg};
        $oid_h->{time}   = $src_h->{time};
        $oid_h->{repeat} = $src_h->{repeat};

    } else {

        # Tag the target as a repeater
        $oid_h->{repeat} = 2;
        my $idx = 1;

        #for my $leaf ( sort { $a <=> $b } keys %{ $src_h->{val} } ) {
        my @sorted_leafs = oid_sort( keys %{ $src_h->{val} } );

        #    if (not @sorted_leafs) {
        #        $oid_h->{color} = $src_h->{color};
        #        $oid_h->{msg} = $src_h->{msg};
        #        $oid_h->{time} = $src_h->{time};
        #    }
        for my $leaf (@sorted_leafs) {

            # Skip if our source oid is freaky-deaky
            next if ( ( exists $oid_h->{error} ) and ( exists $oid_h->{error}{$leaf} ) and ( $oid_h->{error}{$leaf} ) );
            next if ( not defined $src_h->{val}{$leaf} );
            my $res;

            #next if ( not defined $src_h->{val}{$leaf} )
            #    $oid_h->{color}{$leaf} =  'yellow';
            #    $oid_h->{msg}{$leaf} = 'parent value n/a';
            #    $oid_h->{error}{$leaf} =  defined $src_h->{error}{$leaf} ? $src_h->{error}{$leaf} : 1;
            #    next;
            #}
            my $val = $src_h->{val}{$leaf};

            my $result = eval "\$res = \$val =~ m$expr";
            if ($@) {
                do_log( "Failed eval for MATCH transform on leaf $leaf of $oid on $device ($@)", WARN );
                $oid_h->{val}{$leaf}   = 'Failed eval';
                $oid_h->{time}{$leaf}  = time;
                $oid_h->{color}{$leaf} = 'clear';
                next;
            }
            do_log( "$val matched $expr, assigning new row $idx from old row $leaf", DEBUG )
                if $g{debug} and $res;
            next unless $res;

            if ( !defined $leaf ) {
                $oid_h->{val}{$idx}   = 'SHOULD NEVER ARRIVE: CAN BE REMOVED';
                $oid_h->{time}{$idx}  = time;
                $oid_h->{color}{$idx} = 'clear';

                #    $oid_h->{error}{$idx} = 1;
                next;
            }

            $oid_h->{val}{$idx}   = $leaf;
            $oid_h->{time}{$idx}  = $src_h->{time}{$leaf};
            $oid_h->{color}{$idx} = $src_h->{color}{$leaf};
            $idx++;
        }

        # Treat undefined leaf as error
        if ( defined $oid_h->{val} ) {
            for my $leaf ( keys %{ $oid_h->{val} } ) {
                if ( not defined $oid_h->{val}{$leaf} ) {
                    if ( $idx == 1 ) {
                        $oid_h->{color}{$leaf} = 'yellow';
                        $oid_h->{msg}{$leaf}   = 'parent value n/a';
                        $oid_h->{error}{$leaf} = 1;
                        $oid_h->{time}{$leaf}  = time;
                    } else {
                        delete $oid_h->{val}{$leaf};
                        delete $oid_h->{color}{$leaf};
                        delete $oid_h->{msg}{$leaf};
                        delete $oid_h->{time}{$leaf};
                        delete $oid_h->{error}{$leaf};
                    }
                }
            }
        }
    }

    # Apply thresholds
    apply_threshold( $oids, $thr, $oid );
}

# Create our outbound message ##############################################
sub render_msg {
    my ( $device, $tmpl, $test, $oids ) = @_;

    # Hash shortcut
    my $msg_template = $tmpl->{msg};
    my $dev          = \%{ $g{devices}{$device} };
    my $hostname     = $device;
    $hostname =~ s/\./,/g;

    do_log( "Rendering $test message for $device", DEBUG ) if $g{debug};

    # Build readable timestamp
    my $now = $g{xymondateformat} ? strftime( $g{xymondateformat}, localtime ) : scalar(localtime);

    # No message template?
    if ( !defined $msg_template ) {
        return "status $hostname.$test clear $now\n\nCould not locate template for this device.\nPlease check devmon logs.\n\n<a href='https://github.com/bonomani/devmon'>Devmon $g{version}</a> running on $g{nodename}\n";

        # Do we have a xymon color, and if so, is it green?
    } elsif ( defined $g{xymon_color}{$device}
        and $g{xymon_color}{$device} ne 'green' )
    {
        return "status $hostname.$test clear $now\n\nXymon reports this device is unreachable.\nSuspending this test until reachability is restored\n\n<a href='https://github.com/bonomani/devmon'>Devmon $g{version}</a> running on $g{nodename}\n";
    }

    # Our outbound message
    my $msg     = '';
    my $pri_val = '';
    my $errors  = '';
    my %errors;
    my $worst_color = 'green';
    my $table       = undef;
    my $extrastatus = '';
    my ( %t_opts, %rrd );

    # Find all oids that participate in the worst color computation
    # in a line
    my %alarm_oids;
    while ( $msg_template =~ /\{([a-zA-z0-9-_.]+?)\.(?:color|errors)\}/g ) {
        $alarm_oids{$1} = ();
    }

    # Loop over the alarm oid and best/worst dependency (the oid is used
    # in a best/worst transform) and if a best/worst transform exist on the same
    # line, the oid do not have to raise an alarm, so mark it with 'cwc'
    my %no_global_wcolor;

ALARM_OID: foreach my $alarm_oid ( keys %alarm_oids ) {
        $no_global_wcolor{$alarm_oid} = undef;

        # my $dep_tt_oids  = \%{$oids->{$alarm_oid}{ttrans}};

        foreach my $dep_tt_oid ( @{ $tmpl->{oids}{$alarm_oid}{sorted_oids_thresh_infls} } ) {
            if ( exists $alarm_oids{$dep_tt_oid} ) {

                # Mark this oid has not having to participate in the
                # worst color computation
                do_log( "$alarm_oid of $test on $device do not compute worst color ", TRACE ) if $g{debug};

                $no_global_wcolor{$alarm_oid} = 1;
                next ALARM_OID;
            }
        }
    }

    # Go through message template line by line
MSG_LINE: for my $line ( split /\n/, $msg_template ) {

        # First see if this is table data
        if ( $line =~ /^TABLE:\s*(.*)/o ) {
            %t_opts = ();
            %rrd    = ();
            my $opts = $1;
            if ( defined $opts ) {
                for my $optval ( split /\s*,\s*/, $opts ) {
                    my ( $opt, $val ) = ( $1, $2 ) if $optval =~ /(\w+)(?:\((.+)\))?/;
                    ( $opt, $val ) = ( $1, $2 ) if $optval =~ /^(\w+)=(\w+)$/;
                    $val = 1 if !defined $val;
                    push @{ $t_opts{$opt} }, $val;

                }
            }

            # Add our html header if necessary
            if ( defined $t_opts{nonhtml} || defined $t_opts{plain} ) {
                $table = '';
            } else {
                my $border = ( defined $t_opts{border} ) ? $t_opts{border}[0] : 1;
                my $pad    = ( defined $t_opts{pad} )    ? $t_opts{pad}[0]    : 5;
                $table = "<table border=$border cellpadding=$pad>\n";
            }

            # Check for rrd options
            if ( defined $t_opts{rrd} ) {
            RRDSET: for my $rrd_data ( @{ $t_opts{rrd} } ) {
                    my ( $header, $name, $all, $dir, $pri, $do_max );
                    my @datasets;
                    for my $rrd_opt ( split /\s*;\s*/, $rrd_data ) {
                        if ( $rrd_opt eq 'all' ) {
                            $all = 1;
                        } elsif ( $rrd_opt eq 'dir' ) {
                            $dir = 1;
                        } elsif ( $rrd_opt eq 'max' ) {
                            $do_max = 1;
                        } elsif ( $rrd_opt =~ /^name:(\S+)$/ ) {
                            $name = $1;
                        } elsif ( $rrd_opt =~ /^pri:(\S+)$/ ) {
                            $pri = $1;
                        } elsif ( $rrd_opt =~ /^DS:(\S+)$/ ) {
                            push @datasets, $1;
                        }
                    }

                    $name               = $test if !defined $name;
                    $rrd{$name}{pri}    = $pri    || 'pri';
                    $rrd{$name}{dir}    = $dir    || 0;
                    $rrd{$name}{all}    = $all    || 0;
                    $rrd{$name}{do_max} = $do_max || 0;

                    @{ $rrd{$name}{leaves} } = ();

                    for (@datasets) {
                        my ( $ds, $oid, $type, $time, $min, $max ) = split /:/;

                        $ds   = $oid    if !defined $ds;
                        $type = 'GAUGE' if !defined $type or $type eq '';
                        $time = 600     if !defined $time or $time eq '';
                        $min  = 0       if !defined $min  or $min eq '';
                        $max  = 'U'     if !defined $max  or $max eq '';
                        $header .= "DS:$ds:$type:$time:$min:$max ";

                        push @{ $rrd{$name}{oids} }, $oid;
                    }
                    chop $header;

                    $rrd{$name}{header} = $header;
                }
            }

            next;
        }

        # If we have seen a TABLE: placeholder, do table logic
        if ( defined $table ) {

            # First check and see if this is our table header
            if ( $line !~ /\{(.+?)\}/ ) {

                # Format the line accordingly
                if ( defined $t_opts{nonhtml} ) {
                    $table .= "$line\n";
                    $line =~ s/\|/:/g;
                } elsif ( defined $t_opts{plain} ) {
                    $table .= "$line\n";
                    $line =~ s/\|/ /g;
                } else {
                    $line =~ s/\|/<\/th><th>/g;
                    $table .= "<tr><th>$line</th></tr>\n";
                }
                next MSG_LINE;
            }

            # Otherwise its a table data line, we have to parse the oids
            my $alarm_ints = '';
            my %alarm1;

            # Replace our separaters with html
            if ( defined $t_opts{nonhtml} ) {
                $line =~ s/\|/:/g;
            } elsif ( defined $t_opts{plain} ) {
                $line =~ s/\|/ /g;
            } else {
                $line =~ s/\|/<\/td><td>/g;
            }

            # Make the first oid (from left to right) the primary one
            my $pri = $1 if $line =~ /\{(.+?)\}/;
            if ( !defined $pri ) {
                do_log( "No primary OID found for $test test for $device", WARN );
                $msg .= "&yellow No primary OID found.\n";
                $worst_color = 'yellow';
                next;
            }

            # Remove any flags the primary oid might have on it...
            $pri =~ s/\..*//;

            # Make sure we have leaf data for our primary oid
            #if ( !defined $oids->{$pri}{val} ) {
            #    do_log( "DEBUG TEST: Missing repeater data for $pri for $test msg on $device", 4 );
            #    $msg .= "&clear Missing repeater data for primary OID $pri\n";
            #    $worst_color = 'clear';
            #    next;
            #}

            # Make sure our primary OID is a repeater
            if ( !$oids->{$pri}{repeat} ) {
                do_log( "Primary OID $pri in $test table is a non-repeater", ERROR );
                $msg .= "&yellow primary OID $pri in table is a non-repeater\n";
                $worst_color = 'yellow';
                next;
            }

            # If table SORT option is set, sort the table by the oid provided
            # This condition should be included on previous ones to be optimized
            # but this is a WIP: it does not apply to rrd graphs which are sorted
            # numerically or alpha: try to make someting that match if graphs are used:
            # graph used the pri oid so this sort option do not feel weel when graphing
            my @table_leaves = ();

            if ( exists $t_opts{sort}[0] ) {
                if ( ( defined $t_opts{sort}[0] ) and ( defined $oids->{ $t_opts{sort}[0] }{val} ) ) {
                    my %temphash = %{ $oids->{ $t_opts{sort}[0] }{val} };
                    @table_leaves = sort { $temphash{$a} <=> $temphash{$b} } keys %temphash;
                }

                # If the primary oids leaves are non-numeric, then we can't sort it
                # numerically, we'll have to resort to a cmp
            } elsif ( $oids->{$pri}{repeat} == 2 ) {
                my @unsorted = keys %{ $oids->{$pri}{val} };
                @table_leaves = leaf_sort( \@unsorted );

                # Otherwise sort them numerically ascending
            } else {
                @table_leaves = sort { $a <=> $b } keys %{ $oids->{$pri}{val} };
            }

            # Now go through all oid vals, using the primary's leaves
            if ( !@table_leaves ) {
                @table_leaves = ('#');    # add a fake oid "#" to have at lease 1 row
            }

        T_LEAF: for my $leaf (@table_leaves) {

                my $row_data = $line;
                my $alarm_int;

                # Do some alarm logic
                my $pri_val = $leaf eq '#' ? 'undef' : $oids->{$pri}{val}{$leaf};
                my $alarm   = 1;                                                    # Alarm by default
                my $a_val
                    = $dev->{except}{$test}{$pri}{alarm}
                    || $dev->{except}{all}{$pri}{alarm}
                    || $tmpl->{oids}{$pri}{except}{alarm};
                $alarm = ( $pri_val =~ /^(?:$a_val)$/ ) ? 1 : 0 if defined $a_val;

                my $na_val
                    = $dev->{except}{$test}{$pri}{noalarm}
                    || $dev->{except}{all}{$pri}{noalarm}
                    || $tmpl->{oids}{$pri}{except}{noalarm};
                $alarm = 0 if ( defined $na_val ) and ( defined $pri_val ) and ( $pri_val =~ /^(?:$na_val)$/ );

                # Now go through all the oids in our table row and replace them
                for my $root ( $row_data =~ /\{(.+?)\}/g ) {

                    # Chop off any flags and store them for later
                    my $oid   = $root;
                    my $flag  = $1 if $oid =~ s/\.(.+)$//;
                    my $oid_h = \%{ $oids->{$oid} };

                    # Get our oid vars
                    my $val;
                    my $color;
                    if ( $leaf eq '#' ) {
                        $val   = 'NoOID';
                        $color = $oid_h->{color} if defined $oid_h->{color};
                    } elsif ( $oid_h->{repeat} ) {
                        $val = $oid_h->{val}{$leaf} if defined $oid_h->{val}{$leaf};
                        if ( not defined $oid_h->{color} ) {
                            $color = "";    # there is an error
                        } elsif ( $oid_h->{color} eq "red" or $oid_h->{color} eq "yellow" or $oid_h->{color} eq "green" or $oid_h->{color} eq "clear" or $oid_h->{color} eq "blue" ) {
                            $color = $oid_h->{color};
                        } elsif ( defined $oid_h->{color}{$leaf} ) {
                            $color = $oid_h->{color}{$leaf};
                        } else {
                            $color = "blue";
                        }

                    } else {
                        $val   = $oid_h->{val}   if defined $oid_h->{val};
                        $color = $oid_h->{color} if defined $oid_h->{color};
                    }

                    if ( !defined $val ) {
                        do_log( "Undefined value for $oid in test $test on $device, BREAKING CHANGE: Row is not ignore anymore", TRACE ) if $g{trace};
                        $val = 'NoOID';

                        #next T_LEAF;

                    }

                    # Check the exception types, if it is an 'ignore'
                    # don't include this leaf row if the data for this
                    # oid matches, if it is an 'only' type, ONLY include
                    # this leaf row if the data matches
                    my $ignore
                        = $dev->{except}{$test}{$oid}{ignore}
                        || $dev->{except}{all}{$oid}{ignore}
                        || $tmpl->{oids}{$oid}{except}{ignore};

                    my $only
                        = $dev->{except}{$test}{$oid}{only}
                        || $dev->{except}{all}{$oid}{only}
                        || $tmpl->{oids}{$oid}{except}{only};

                    next T_LEAF if defined $ignore and $val =~ /^(?:$ignore)$/;
                    next T_LEAF if defined $only   and $val !~ /^(?:$only)$/;

                    # If we aren't alarming on a value, its blue by default
                    $color = 'blue' if !$alarm;

                    # Keep track of our primary value
                    if ( ( $oid eq $pri ) and ( $leaf ne '#' ) ) {

                        # Add our primary key to our rrd set, if needed
                        for my $name ( keys %rrd ) {
                            $rrd{$name}{pri} = $oid if $rrd{$name}{pri} eq 'pri';

                            # This condition looks incorrect. We should not remove rrds if alerting
                            # is disabled for this leaf. If the user doesn't want a graph, they probably
                            # don't want this leaf in the table, they should set 'ignore' instead of 'noalarm'
                            #if ($rrd{$name}{all} or $alarm) {
                            # add to list, but check we're not pushing multiple times
                            push @{ $rrd{$name}{leaves} }, $leaf unless grep { $_ eq $leaf } @{ $rrd{$name}{leaves} };
                        }

                        # If this is our primary oid, and we are have an alarm
                        # variable defined, save it so we can add it later
                        $alarm_int = $val;
                    }

                    # See if we have a valid flag, if so, replace the
                    # place holder with flag data, if not, just replace
                    # it with the oid value.  Also modify the global color
                    # Display a Xymon color string (i.e. "&red ")
                    if ( defined $flag ) {

                        my $oid_msg;
                        if ( $leaf eq '#' ) {
                            $oid_msg = parse_deps( $oids, $oid_h->{msg}, $leaf ) if defined $oid_h->{msg};
                        } elsif ( $oid_h->{color} eq "red" or $oid_h->{color} eq "yellow" or $oid_h->{color} eq "green" or $oid_h->{color} eq "clear" or $oid_h->{color} eq "blue" ) {
                            $oid_msg = parse_deps( $oids, $oid_h->{msg}, $leaf ) if defined $oid_h->{msg};
                        } else {
                            $oid_msg = parse_deps( $oids, $oid_h->{msg}{$leaf}, $leaf ) if defined $oid_h->{msg}{$leaf};
                        }

                        if ( $flag eq 'color' ) {

                            # Honor the 'alarm' exceptions
                            $row_data =~ s/\{$root\}/&$color /;

                            # If this test has a worse color, use it for the global color
                            # but verify first that this test should compute the worst color
                            if ( ( defined $oid_msg ) and ( not $no_global_wcolor{$oid} ) and ( $oid_msg ne '' ) ) {

                                $worst_color = $color
                                    if !defined $worst_color
                                    or $colors{$worst_color} < $colors{$color};
                            }

                            # Display threshold messages if we get the msg flag
                        } elsif ( $flag eq 'msg' ) {

                            # Get oid msg and replace any inline oid dependencies
                            #$oid_msg = parse_deps($oids, $oid_msg, $leaf);
                            $row_data =~ s/\{$root\}/$oid_msg/;

                            # This flag only causes errors (with the color) to be displayed
                            # Will also modify global color type lag if it is alarming
                        } elsif ( $flag eq 'errors' or $flag eq 'error' ) {
                            $row_data =~ s/\{$root\}//;

                            next if $color eq 'green' or $color eq 'blue';

                            # If this test has a worse color, use it for the global color
                            # but verify first that this test should compute the worst color
                            if ( $no_global_wcolor{$oid} ) {
                                do_log( "$oid of $test on $device is overwritten by Worst/Best Transform: remove " . '{' . "$oid.errors" . '}' . " in 'message' template", DEBUG );

                                # Get oid msg and replace any inline oid dependencies
                            } else {

                                $oid_msg = parse_deps( $oids, $oid_msg, $leaf );

                                # If the message is an empty string it means that we dont want to raise an error
                                if ( ( defined $oid_msg ) and ( $oid_msg ne '' ) ) {

                                    $worst_color = $color
                                        if !defined $worst_color
                                        or $colors{$worst_color} < $colors{$color};

                                    # Now add it to our msg
                                    my $error_key = "&$color $oid_msg";
                                    $errors{$error_key} = undef;
                                }
                            }

                            # Display color threshold value
                        } elsif ( $flag =~ /^thresh$/i ) {
                            my $thresh = $oid_h->{thresh}{$leaf};

                            $thresh = 'Undef' if !defined $thresh;
                            $row_data =~ s/\{$root\}/$thresh/;

                            # Display color threshold template value
                        } elsif ( $flag =~ /^thresh\:(\w+)$/i or $flag =~ /^threshold\.(\w+)$/i ) {
                            my $threshold_color = lc $1;

                            #do_log ("RENDER WARNING: {thresh:color} is DEPRECATED, please use {threshold.color} syntax") if $flag =~ /^thresh\:(\w+)$/i;
                            my $threshold = '';
                            for my $limit ( keys %{ $oid_h->{threshold}{$threshold_color} } ) {
                                if ( $threshold eq '' ) {
                                    $threshold = $limit;
                                } else {
                                    $threshold .= ' or ' . $limit;
                                }
                            }

                            $threshold = 'Undef' if !defined $threshold;
                            $row_data =~ s/\{$root\}/$threshold/;

                            # Unknown flag
                        } else {
                            do_msg("Unknown flag ($flag) for $oid on $device\n");
                        }

                        # Otherwise just display the oid val
                    } else {

                        #my $substr = $oids->{$root}{repeat} ? $oids->{$root}{val}{$leaf} : $oids->{$root}{val};
                        #$substr = 'Undef' if !defined $substr;
                        #$row_data =~ s/\{$root\}/$substr/;
                        $row_data =~ s/\{$root\}/$val/;
                    }

                }

                # add the primary repeater to our alarm header if we are
                # alarming on it; Wrap our header at 60 chars
                if ( !defined $t_opts{noalarmsmsg} and $alarm and $leaf ne '#' and defined $alarm_int ) {

                    #$alarm_ints =~ s/(.{60,}),$/$1)\nAlarming on (/;
                    #$alarm_ints .= "$alarm_int,";
                    $alarm1{$alarm_int} = undef;

                }

                # Finished with this row (signified by the primary leaf id)
                if ( defined $t_opts{nonhtml} || defined $t_opts{plain} ) {
                    $table .= "$row_data\n";
                } else {
                    $table .= "<tr><td>$row_data</td></tr>\n";
                }
            }
            $table .= "</table>\n" if ( !defined $t_opts{nonhtml} && !defined $t_opts{plain} );
            $alarm_ints = '';
            if ( !defined $t_opts{noalarmsmsg} and %alarm1 ) {
                for my $alarm1_key ( sort { $a cmp $b } keys %alarm1 ) {
                    $alarm_ints =~ s/(.{60,}),$/$1)\nAlarming on (/;
                    $alarm_ints .= "$alarm1_key,";
                }
            }

            # If we are display alarms, fix the message up to look nice
            if ( !defined $t_opts{noalarmsmsg} ) {
                if ( $alarm_ints ne '' ) {
                    $alarm_ints =~ s/(.+),/Alarming on ($1)\n/s;
                } else {
                    $alarm_ints = "Not alarming on any values\n";
                }
            }

            # Put the alarm ints on bottom if requested to do so
            if ( defined $t_opts{alarmsonbottom} ) {
                $msg = join '', ( $msg, $table, $alarm_ints );
            } else {
                $msg = join '', ( $msg, $alarm_ints, $table );
            }

            # Add rrd data
            for my $name ( keys %rrd ) {

                my $set_data  = '';
                my $temp_data = '';
                my $dir       = $rrd{$name}{dir};
                my $pri       = $rrd{$name}{pri};
                my $do_max    = $rrd{$name}{do_max};

                do_log("Couldn't fetch primary oid for rrd set $name",WARN)
                    and next
                    if $pri eq 'pri';

                my $header = "<!--DEVMON RRD: $name $dir $do_max\n" . $rrd{$name}{header};

                for my $leaf ( @{ $rrd{$name}{leaves} } ) {
                    next if not defined $oids->{$pri}{val}{$leaf};
                    my $pri_val = $oids->{$pri}{val}{$leaf};

                    $pri_val =~ s/\s*//g;

                    $temp_data = '';
                    for my $oid ( @{ $rrd{$name}{oids} } ) {
                        my $val = $oids->{$oid}{val}{$leaf};
                        if ( defined $val ) {
                            $val = ( $val =~ /^[+-]?\d+(\.\d+)?/ ) ? int $val : 'U';
                        } else {
                            $val = 'U';
                        }
                        $temp_data .= "$val:";
                    }
                    if ( $temp_data =~ /^(U:)+/ ) {

                        do_log( "Text values in data for rrd repeater, dropping rrd for $pri_val", WARN )
                            if $g{debug};
                        next;
                    }
                    $set_data .= "$pri_val ";
                    $set_data .= "$temp_data";
                    $set_data =~ s/:$/\n/;

                }

                $set_data =~ s/[\/&+\$]/_/gs;
                $msg .= "$header\n$set_data-->\n";

            }

            # Clear our table status
            $table = undef;

            # Not table data, so it should be a non-repeater type variable
        } else {

            for my $root ( $line =~ /\{(.+?)\}/g ) {

                # Chop off any flags and store them for later
                my $oid   = $root;
                my $flag  = $1 if $oid =~ s/\.(.+)$//;
                my $oid_h = \%{ $oids->{$oid} };
                $flag = '' if !defined $flag;

                # Get our oid vars
                my $val   = $oid_h->{val};
                my $color = $oid_h->{color};
                $val   = 'Undef' if !defined $val;
                $color = 'clear' if !defined $color;

                # See if we have a valid flag, if so, replace the
                # place holder with flag data, if not, just replace
                # it with the oid value
                if ( $flag ne '' ) {

                    #my $oid_msg = $oid_h->{msg};
                    my $oid_msg = parse_deps( $oids, $oid_h->{msg}, undef );

                    if ( $flag eq 'color' ) {

                        # If this test has a worse color, use it for the global color
                        # but verify first that this test should compute the worst color

                        # Honor the 'alarm' exceptions
                        $line =~ s/\{$root\}/\&$color /;

                        # If this test has a worse color, use it for the global color
                        # but verify first that this test should compute the worst color
                        if ( ( defined $oid_msg ) and ( not $no_global_wcolor{$oid} ) and ( $oid_msg ne '' ) ) {

                            #if ( (not $no_global_wcolor{$oid}) and ($oid_msg ne '') ) {

                            $worst_color = $color
                                if !defined $worst_color
                                or $colors{$worst_color} < $colors{$color};
                        }

                        # Display threshold messages if we get the msg flag
                    } elsif ( $flag eq 'msg' ) {

                        # Get oid msg and replace any inline oid dependencies
                        $line =~ s/\{$root\}/$oid_msg/;

                        # This flag only causes errors (with the color) to be displayed
                        # Can also modifies global color
                    } elsif ( $flag eq 'errors' ) {
                        $line =~ s/\{$root\}//;

                        # Skip this value if it is green or blue
                        next if !defined $color or $color eq 'green' or $color eq 'blue';

                        # If this test has a worse color, use it for the global color
                        # but verify first that this test should compute the worst color
                        if ( $no_global_wcolor{$oid} ) {
                            do_log( "$oid of $test on $device is overwritten by Worst/Best Transform: remove " . '{' . "$oid.errors" . '}' . " in 'message' template", INFO );

                            # Get oid msg and replace any inline oid dependencies
                        } else {

                            if ( defined $oid_msg and $oid_msg ne '' ) {

                                $worst_color = $color
                                    if !defined $worst_color
                                    or $colors{$worst_color} < $colors{$color};

                                # Now add it to our msg
                                my $error_key = "&$color $oid_msg";
                                $errors{$error_key} = undef;

                            }
                        }

                        # Display color threshold value
                    } elsif ( $flag =~ /^thresh$/i ) {
                        my $thresh = $oid_h->{thresh};
                        $thresh = 'Undef' if !defined $thresh;
                        $line =~ s/\{$root\}/$thresh/;

                        # Display color threshold template value
                    } elsif ( $flag =~ /^thresh:($color_list)$/i or $flag =~ /^threshold\.(\w+)$/i ) {
                        my $threshold_color = lc $1;

                        #do_log ("RENDER WARNING: {thresh:color} is DEPRECATED, please use {threshold.color} syntax") if $flag =~ /^thresh\:(\w+)$/i;
                        my $threshold = '';
                        for my $limit ( keys %{ $oid_h->{threshold}{$threshold_color} } ) {
                            if ( $threshold eq '' ) {
                                $threshold = $limit;
                            } else {
                                $threshold .= ' or ' . $limit;
                            }
                        }
                        $threshold = 'Undef' if !defined $threshold;
                        $line =~ s/\{$root\}/$threshold/;

                        # Unknown flag
                    } else {
                        do_log("Unknown flag ($flag) for $oid on $device\n",ERROR);
                    }

                } else {
                    my $val = $oid_h->{val};
                    $val = "Undef" if !defined $val;

                    $line =~ s/\{$root\}/$val/;
                }

            }

            # Avoid blank error lines ? No needed anymore ?
            $line = ( $line eq '#ERRORONLY#' ) ? '' : "$line\n";
            if ( $line =~ /^STATUS:(.*)$/ ) {
                #
                $extrastatus = $1;
            } else {
                $msg .= $line;
            }
        }

    }

    # Xymon can currently graph only 1 table. The rrd info
    # should be at the end of the message, otherwise the
    # linecount is wrong and there are empty graphs
    # Pick the first RRD message and put it at the end
    # ref lib/htmllog.c : (the rendering is not ready to have multiple rrd)
    # > See if there is already a linecount in the report.
    # > * If there is, this overrides the calculation here.
    # Simply comment the 2 following lines to revert this workaround

    if ( $msg =~ s/(<!--DEVMON.*-->)//s ) {
        $msg .= $1;
    }

    # Add our errors
    $msg = join "\n", ( sort keys %errors, '', $msg ) if %errors;

    # Now add our header so xymon can determine the page color
    $msg = "status $hostname.$test $worst_color $now" . "$extrastatus\n\n$msg";

    # Add our oh-so-stylish devmon footer
    $msg .= "\n\n<a href='https://github.com/bonomani/devmon'>Devmon $g{version}</a> " . "running on $g{nodename}\n";

    # Now add a bit of logic to allow a 'cleartime' window, where a test on
    # a device can be clear for an interval without being reported as such
    #if ( $worst_color eq 'clear' ) {
    #    $g{numclears}{$device}{$test} = time
    #        if !defined $g{numclears}{$device}{$test};
    #} else {

    # Clear our clear counter if this message wasnt clear
    #    delete $g{numclears}{$device}{$test}
    #        if defined $g{numclears}{$device}
    #        and defined $g{numclears}{$device}{$test};
    #}

    # Now return null if we are in our 'cleartime' window
    #if (    defined $g{numclears}{$device}
    #    and defined $g{numclears}{$device}{$test} )
    #{
    #    my $start_clear = $g{numclears}{$device}{$test};
    #    if ( time - $start_clear < $g{cleartime} ) {
    #        do_log( "DEBUG TEST: $device had some clear errors " . "during test $test", 4 ) if $g{debug};
    #        return;
    #    }
    #}

    # Looks like we are good to return our completed message
    return $msg;
}

# Quick numeric ascending sort for OID leaves
# (some/all of which may be 1 or more levels deep)
sub leaf_sort {
    my %cache;
    my ($list) = @_;
    return sort { ( $cache{$a} ||= pack "w*", split /\./, $a ) cmp( $cache{$b} ||= pack "w*", split /\./, $b ) } @$list;
}

# Check alarm exceptions to see if a given oid should be
# alarmed against.  Return true if it should be ignored.
sub check_alarms {
    my ( $tmpl, $dev, $test, $oid, $val ) = @_;

    if ( defined $dev->{except}{$test}{$oid}{noalarm} ) {
        my $match = $dev->{except}{$test}{$oid}{noalarm};
        return 1 if $val =~ /^(?:$match)$/;
    } elsif ( defined $dev->{except}{all}{$oid}{noalarm} ) {
        my $match = $dev->{except}{all}{$oid}{noalarm};
        return 1 if $val =~ /^(?:$match)$/;
    } elsif ( defined $tmpl->{oids}{$oid}{except}{noalarm} ) {
        my $match = $tmpl->{oids}{$oid}{except}{noalarm};
        return 1 if $val =~ /^(?:$match)$/;
    }

    if ( defined $dev->{except}{$test}{$oid}{alarm} ) {
        my $match = $dev->{except}{$test}{$oid}{alarm};
        return 1 if $val !~ /^(?:$match)$/;
    } elsif ( defined $dev->{except}{all}{$oid}{alarm} ) {
        my $match = $dev->{except}{all}{$oid}{alarm};
        return 1 if $val !~ /^(?:$match)$/;
    } elsif ( defined $tmpl->{oids}{$oid}{except}{alarm} ) {
        my $match = $tmpl->{oids}{$oid}{except}{alarm};
        return 1 if $val !~ /^(?:$match)$/;
    }
}

# For an oid msg, convert all inline oid dependencies to their textual value
# Watch out for recursion loops here, as this sub can call itself recursively
sub parse_deps {
    my ( $oids, $msg, $leaf, $depth ) = @_;
    my $flags = 'color|msg';

    # Try to guard against recursion loops
    $depth = 1                         if !defined $depth;
    return "Recursion limit exceeded." if ++$depth > 10;

    # Make sure we have a message to parse!
    # return "Undef" if !defined $msg;
    return undef if !defined $msg;

    # Go through all the oids that we depend on
    for my $dep_oid ( $msg =~ /\{(.+?)\}/g ) {
        my $oid   = $dep_oid;
        my $oid_h = \%{ $oids->{$oid} };
        my $val;

        # See if our oid has any flags appended
        my $flag = '';
        $flag = $1 if $oid =~ s/\.($flags)$//;

        # Do repeater types if we have a leaf
        if ( defined $leaf ) {

            # Evaluate flag type
            if ( $flag eq 'color' ) {
                $val = "&" . $oid_h->{color}{$leaf} . " ";
            } elsif ( $flag eq 'msg' ) {
                my $depmsg = $oid_h->{msg}{$leaf};
                $val = parse_deps( $oids, $depmsg, $leaf, $depth );
            } else {
                $val = $oid_h->{val}{$leaf};
            }

            if ( !defined $val ) {
                do_log( "Missing msg data for $dep_oid on leaf $leaf", WARN );
                $val = 'Undef';
            }

            # Not a repeater
        } else {

            # Evaluate flag type
            if ( $flag eq 'color' ) {
                $val = "&" . $oid_h->{color} . " ";
            } elsif ( $flag eq 'msg' ) {
                my $depmsg = $oid_h->{msg};
                $val = parse_deps( $oids, $depmsg, undef, $depth );
            } else {
                $val = $oid_h->{val};
            }
            if ( !defined $val ) {
                do_log( "Missing msg data for $dep_oid", WARN );
                $val = 'Undef';
            }
        }

        $msg =~ s/\{$dep_oid\}/$val/g;
    }

    return $msg;
}

# Apply thresholds to a supplied repeater oid, save in the oids hash
sub apply_threshold {
    my ( $oids, $thr, $oid ) = @_;
    my $oid_h = \%{ $oids->{$oid} };
    #if ( $oid_h->{repeat} and defined $oid_h->{val} and not( defined $oid_h->{color} and $oid_h->{color} eq "clear" ) ) {
    if ( $oid_h->{repeat} and defined $oid_h->{val} and not (defined $oid_h->{color} and (ref $oid_h->{color} ne 'HASH'))) {


    APTHRLEAF: for my $leaf ( keys %{ $oid_h->{val} } ) {
            my %oid_r;
            $oid_r{val}    = \$oid_h->{val}{$leaf};
            $oid_r{color}  = \$oid_h->{color}{$leaf};
            $oid_r{msg}    = \$oid_h->{msg}{$leaf};
            $oid_r{error}  = \$oid_h->{error}{$leaf};
            $oid_r{thresh} = \$oid_h->{thresh}{$leaf};
            if ( !defined ${ $oid_r{color} } ) {
              ${ $oid_r{color} } = 'green';
            }

            # Skip to next if there is an error as color is already defined
            if ( defined ${ $oid_r{val} } ) {

                my $oid_val                 = ${ $oid_r{val} };
                my $thresh_confidence_level = 0;                  # 7 Exact match, 6 Interval match, 5 smart-match,
                                                                  # 4 Negative smart-match, 3 Negative match, 2 Colored_Automatch
                                                                  # 1 Automatch

                #if ( !defined ${ $oid_r{color} } ) {
                #    ${ $oid_r{color} } = 'green';
                #}
                #my $oid_color = ${ $oid_r{color} };

                #Apply custom thresholds (from xymon hosts.cfg)
                if ( exists $thr->{$oid} ) {
                    my $thresh_h = \%{ $thr->{$oid} };
                    #apply_thresh_element( $thresh_h, \%oid_r, \$oid_color, \$thresh_confidence_level );
                    apply_thresh_element( $thresh_h, \%oid_r, $oid_r{color}, \$thresh_confidence_level );
                }

                # Apply template thresholds (from file)
                if ( exists $oid_h->{threshold} ) {
                    my $thresh_h = \%{ $oid_h->{threshold} };
                    #apply_thresh_element( $thresh_h, \%oid_r, \$oid_color, \$thresh_confidence_level );
                    apply_thresh_element( $thresh_h, \%oid_r, $oid_r{color}, \$thresh_confidence_level );
                }
            }
            my $color = ${ $oid_r{color} };
            if ( $color eq 'green' ) {
            } elsif ( $color eq 'clear' ) {
                ${ $oid_r{error} } = 1;
            } elsif ( $color eq 'blue' ) {
            } elsif ( $color eq 'yellow' ) {
            } elsif ( $color eq 'red' ) {
            } else {
                do_log("Invalid color '${$oid_r{color}}' of '$oid'.'$leaf' ",ERROR);
            }
            delete $oid_h->{thresh}{$leaf} unless ( defined ${ $oid_r{thresh} } );
            delete $oid_h->{msg}{$leaf}    unless ( defined ${ $oid_r{msg} } );
            delete $oid_h->{error}{$leaf}  unless ( defined ${ $oid_r{error} } );

        }
        delete $oid_h->{thresh} unless ( %{ $oid_h->{thresh} } );
        delete $oid_h->{msg}    unless ( %{ $oid_h->{msg} } );
        delete $oid_h->{error}  unless ( %{ $oid_h->{error} } );
    } else {

        # Skip to next if there is an error as color is already defined
        my %oid_r;
        my $oid_val;
        $oid_r{val}    = \$oid_h->{val};
        $oid_r{color}  = \$oid_h->{color};
        $oid_r{msg}    = \$oid_h->{msg};
        $oid_r{error}  = \$oid_h->{error};
        $oid_r{thresh} = \$oid_h->{thresh};

        if ( ( not $oid_h->{repeat} ) and ( defined ${ $oid_r{val} } ) ) {

            #my $oid_val = $oid_h->{val};

            # more precise threshold means more confidence
            my $thresh_confidence_level = 0;    # 7 Exact match, 6 Interval match, 5 smart match,
                                                # 4 Negative smart match, 3 Negative match, 2 Colored_Automatch
                                                # 1 Automatch
                                                # default values
                                                #if ( !defined $oid_h->{color} ) {
            if ( !defined ${ $oid_r{color} } ) {
                ${ $oid_r{color} } = 'green';
            }

            # my $oid_color = $oid_h->{color};
            my $oid_color = ${ $oid_r{color} };

            #Apply custom thresholds (from xymon hosts.cfg)
            if ( exists $thr->{$oid} ) {
                my $thresh_h = \%{ $thr->{$oid} };
                apply_thresh_element( $thresh_h, \%oid_r, \$oid_color, \$thresh_confidence_level );
            }

            # Apply template thresholds (from file)
            if ( exists $oid_h->{threshold} ) {
                my $thresh_h = \%{ $oid_h->{threshold} };
                apply_thresh_element( $thresh_h, \%oid_r, \$oid_color, \$thresh_confidence_level );
            }
        }
        delete $oid_h->{thresh} unless ( defined ${ $oid_r{thresh} } );
        delete $oid_h->{msg}    unless ( defined ${ $oid_r{msg} } );
        delete $oid_h->{error}  unless ( defined ${ $oid_r{error} } );
        if ( $oid_h->{color} eq 'green' ) {
            return;
        } elsif ( $oid_h->{color} eq 'clear' ) {
            $oid_h->{error} = 1;
            return;
        } elsif ( $oid_h->{color} eq 'blue' ) {
            return;
        } elsif ( $oid_h->{color} eq 'yellow' ) {
            return;
        } elsif ( $oid_h->{color} eq 'red' ) {
            return;
        }
        do_log("Invalid color '$oid_h->{color}' of '$oid'",ERROR);
    }
}

sub apply_thresh_element {
    my ( $thresh_h, $oid_r_ref, $oid_color_ref, $thresh_confidence_level_ref ) = @_;
    my %oid_r                   = %{$oid_r_ref};
    my $oid_color               = ${$oid_color_ref};
    my $thresh_confidence_level = ${$thresh_confidence_level_ref};

COLOR: for my $color (@color_order) {
        next unless defined $thresh_h->{$color};
    TRH_LIST: for my $thresh_list ( keys %{ $thresh_h->{$color} } ) {
            my $thresh_msg;
            $thresh_msg = $thresh_h->{$color}{$thresh_list} if defined $thresh_h->{$color}{$thresh_list};

            # Split our comma-delimited thresholds up
            for my $thresh ( split /\s*,\s*/, $thresh_list ) {

                # check if the value to test is a num
                if ( ${ $oid_r{val} } ne 'NaN' and looks_like_number( ${ $oid_r{val} } ) ) {

                    # Look for a simple numeric threshold, without a comparison operator.
                    # This is the most common threshold definition and handling it separately
                    # results in a significant performance improvement.
                    if ( $thresh_confidence_level < 6 and looks_like_number($thresh) ) {
                        if ( ${ $oid_r{val} } >= $thresh ) {
                            ${ $oid_r{color} }  = $color;
                            ${ $oid_r{thresh} } = $thresh     if defined $thresh;
                            ${ $oid_r{msg} }    = $thresh_msg if defined $thresh_msg;
                            $thresh_confidence_level = 6;
                            next TRH_LIST;
                        }

                        # Look for a numeric threshold preceeded by a comparison operator.
                    } elsif ( $thresh =~ /^(>|<|>=|<=|=|!)\s*([+-]?\d+(?:\.\d+)?)$/ ) {
                        my ( $op, $limit ) = ( $1, $2 );
                        if (( $thresh_confidence_level < 6 )
                            and (  ( $op eq '>' and ${ $oid_r{val} } > $limit )
                                or ( $op eq '>=' and ${ $oid_r{val} } >= $limit )
                                or ( $op eq '<'  and ${ $oid_r{val} } < $limit )
                                or ( $op eq '<=' and ${ $oid_r{val} } <= $limit ) )
                            )
                        {
                            ${ $oid_r{color} }  = $color;
                            ${ $oid_r{thresh} } = $thresh     if defined $thresh;
                            ${ $oid_r{msg} }    = $thresh_msg if defined $thresh_msg;
                            $thresh_confidence_level = 6;
                            next TRH_LIST;
                        } elsif ( $thresh_confidence_level < 7 and $op eq '=' and ${ $oid_r{val} } == $limit ) {
                            ${ $oid_r{color} }  = $color;
                            ${ $oid_r{thresh} } = $thresh     if defined $thresh;
                            ${ $oid_r{msg} }    = $thresh_msg if defined $thresh_msg;
                            $thresh_confidence_level = 7;
                            last COLOR;
                        } elsif ( $thresh_confidence_level < 3 and $op eq '!' and ${ $oid_r{val} } != $limit ) {
                            ${ $oid_r{color} }  = $color;
                            ${ $oid_r{thresh} } = $thresh     if defined $thresh;
                            ${ $oid_r{msg} }    = $thresh_msg if defined $thresh_msg;
                            $thresh_confidence_level = 3;
                            next TRH_LIST;
                        }
                    } elsif ( $thresh eq '_AUTOMATCH_' ) {
                        if ( $thresh_confidence_level < 2 and $oid_color eq $color ) {
                            ${ $oid_r{color} }  = $color;
                            ${ $oid_r{thresh} } = $thresh     if defined $thresh;
                            ${ $oid_r{msg} }    = $thresh_msg if defined $thresh_msg;
                            $thresh_confidence_level = 2;
                            next TRH_LIST;
                        } elsif ( $thresh_confidence_level < 1 ) {
                            ${ $oid_r{color} }  = $color;
                            ${ $oid_r{thresh} } = $thresh     if defined $thresh;
                            ${ $oid_r{msg} }    = $thresh_msg if defined $thresh_msg;
                            $thresh_confidence_level = 1;
                            next TRH_LIST;
                        }
                    }

                    # Look for negated test, must be string based
                } elsif ( $thresh =~ /^!\s*(.+)/ ) {
                    my $neg_thresh = $1;
                    if ( $thresh_confidence_level < 4 and ${ $oid_r{val} } !~ /$neg_thresh/ ) {
                        ${ $oid_r{color} }  = $color;
                        ${ $oid_r{thresh} } = $thresh     if defined $thresh;
                        ${ $oid_r{msg} }    = $thresh_msg if defined $thresh_msg;
                        $thresh_confidence_level = 4;
                        next TRH_LIST;
                    } elsif ( $thresh_confidence_level < 3 and ${ $oid_r{val} } ne $neg_thresh ) {
                        ${ $oid_r{color} }  = $color;
                        ${ $oid_r{thresh} } = $thresh     if defined $thresh;
                        ${ $oid_r{msg} }    = $thresh_msg if defined $thresh_msg;
                        $thresh_confidence_level = 3;
                        next TRH_LIST;
                    }

                    # Its not numeric or negated, it must be string based
                } else {

                    # Do our automatching for blank thresholds
                    if ( $thresh eq '_AUTOMATCH_' ) {
                        if ( $thresh_confidence_level < 2 and $oid_color eq $color ) {
                            ${ $oid_r{color} }  = $color;
                            ${ $oid_r{thresh} } = $thresh     if defined $thresh;
                            ${ $oid_r{msg} }    = $thresh_msg if defined $thresh_msg;
                            $thresh_confidence_level = 2;
                            next TRH_LIST;
                        } elsif ( $thresh_confidence_level < 1 ) {
                            ${ $oid_r{color} }  = $color;
                            ${ $oid_r{thresh} } = $thresh     if defined $thresh;
                            ${ $oid_r{msg} }    = $thresh_msg if defined $thresh_msg;
                            $thresh_confidence_level = 1;
                            next TRH_LIST;
                        }
                    } elsif ( $thresh_confidence_level < 7 and ${ $oid_r{val} } eq $thresh ) {
                        ${ $oid_r{color} }  = $color;
                        ${ $oid_r{thresh} } = $thresh     if defined $thresh;
                        ${ $oid_r{msg} }    = $thresh_msg if defined $thresh_msg;
                        $thresh_confidence_level = 7;
                        next COLOR;
                    } elsif ( $thresh_confidence_level < 5 and ${ $oid_r{val} } =~ /$thresh/ ) {
                        ${ $oid_r{color} }  = $color;
                        ${ $oid_r{thresh} } = $thresh     if defined $thresh;
                        ${ $oid_r{msg} }    = $thresh_msg if defined $thresh_msg;
                        $thresh_confidence_level = 5;
                        next TRH_LIST;
                    }
                }
            }
        }
    }
}

# Convert # of seconds into an elapsed string
#sub elapsed {
#   my ($secs) = @_;
#
#   return $secs if $secs !~ /^\d+(\.\d+)?$/;
#
#   my $days  = int ($secs / 86400);    $secs -= ($days  * 86400);
#   my $hours = int ($secs / 3600);     $secs -= ($hours * 3600);
#   my $mins  = int ($secs / 60);       $secs -= ($mins  * 60);
#
#   my $out = sprintf "%-2.2d:%-2.2d:%-2.2d",
#   $hours, $mins, $secs;
#   $out = sprintf "%d day%s, %s", $days,
#   ($days == 1) ? "" : "s", $out if $days;
#
#   return $out;
#}

# Convert # of seconds into an elapsed string
#sub date {
#   my ($secs) = @_;
#
#   my ($sec, $min, $hour, $day, $mon, $year) = localtime($secs);
#   $year += 1900; ++$mon;
#
#   my $out = sprintf "%d-%-2.2d-%-2.2d, %-2.2d:%-2.2d:%-2.2d",
#   $year, $mon, $day, $hour, $min, $sec;
#   return $out;
#}
sub define_pri_oid {
    my ( $oids, $oid, $dep_arr ) = @_;
    my $oid_h = \%{ $oids->{$oid} };

    # Go through our parent oid array, if there are any repeaters
    # set the first one as the primary OID and set the repeat type
    # but very first that it is not already defined as a leaf
    my $pri_oid;
    for my $dep_oid (@$dep_arr) {
        if ( $oids->{$dep_oid}{repeat} ) {
            $pri_oid = $dep_oid;
            last;
        } else {
            $oid_h->{pri_oid} = $dep_oid if not defined $oid_h->{pri_oid};
            $pri_oid          = $dep_oid if not defined $pri_oid;
        }
    }
    if ( defined $pri_oid ) {
        $oid_h->{pri_oid} = $pri_oid;
        $oid_h->{repeat}  = $oids->{$pri_oid}{repeat};
        return 1;    # Success
    } else {
        return 0;    # Not defined
    }
}

# Validate oid dependencies
sub validate_deps {
    my ( $device, $oids, $oid, $dep_arr, $regex ) = @_;
    my $oid_h = \%{ $oids->{$oid} };

    # Return witout error if we do not have any dependant oids
    unless ( scalar @$dep_arr ) {
        $oid_h->{repeat} = 0;
        $oid_h->{time}   = time;
        return 1;
    }

    # if repeater type is not set, it because there are not any dependecies
    my $pri_oid = $oid_h->{pri_oid};
    if ( not defined $pri_oid ) {
        return 1;    # Success to validate nothing!
    }

    # Check first if we have a global error
    for my $dep_oid (@$dep_arr) {
        if ( ( ref $oids->{$dep_oid}{error} ne 'HASH' ) and ( defined $oids->{$dep_oid}{error} ) and $oids->{$dep_oid}{error} ) {
            $oid_h->{color} = 'clear';
            $oid_h->{msg}   = $oids->{$dep_oid}{msg}  if defined $oids->{$dep_oid}{msg};
            $oid_h->{time}  = $oids->{$dep_oid}{time} if defined $oids->{$dep_oid}{time};
            $oid_h->{error} = 1;
            return 0;
        }
    }

    my $deps_valid = 0;

    # repeater
    if ( $oid_h->{repeat} ) {

        # Parse our parent OIDs
    LEAF: for my $leaf ( keys %{ $oids->{$pri_oid}{val} } ) {
            my $leaf_deps_valid = 0;
            my $time;

            # The time is take from the pri_oid value, if it exist
            if ( exists $oid_h->{pri_oid} and $oid_h->{pri_oid} ) {
                $time = ref $oids->{$pri_oid}{time} eq ref {} ? $oids->{$pri_oid}{time}{$leaf} : $oids->{$pri_oid}{time};

            } else {

                $time = time;
            }
            $oid_h->{time}{$leaf} = $time;
            for my $dep_oid (@$dep_arr) {
                my $dep_oid_h = \%{ $oids->{$dep_oid} };
                my $dep_val;
                my $dep_error;
                my $dep_color;
                my $dep_msg;
                if ( $dep_oid_h->{repeat} ) {
                    if ( ( exists $dep_oid_h->{error} ) and ( defined $dep_oid_h->{error}{$leaf} ) and ( $dep_oid_h->{error}{$leaf} ) ) {
                        $dep_error = 1;
                    }
                    $dep_val   = $dep_oid_h->{val}{$leaf};
                    $dep_color = defined $dep_oid_h->{color}{$leaf} ? $dep_oid_h->{color}{$leaf} : "clear";
                    $dep_msg   = $dep_oid_h->{msg}{$leaf} if ( defined $dep_oid_h->{msg} ) and ( $dep_oid_h->{msg}{$leaf} );
                } else {
                    if ( ( defined $dep_oid_h->{error} ) and $dep_oid_h->{error} ) {
                        $dep_error = 1;
                    }
                    $dep_color = $dep_oid_h->{color};
                    $dep_msg   = $dep_oid_h->{msg} if defined $dep_oid_h->{msg};
                }

                if ( !defined $dep_val ) {

                    # We should never be here with an undef val as it
                    # should be alread treated: severity increase to yellow
                    $oid_h->{val}{$leaf}   = undef;
                    $oid_h->{color}{$leaf} = $dep_color;
                    $oid_h->{error}{$leaf} = 1;
                    $oid_h->{msg}{$leaf}   = $dep_msg if defined $dep_msg;
                    next LEAF;    #
                } elsif ( defined $dep_val and $dep_val eq 'wait' ) {
                    $oid_h->{val}{$leaf}   = 'wait';
                    $oid_h->{color}{$leaf} = 'clear';
                    $oid_h->{error}{$leaf} = 1;
                    $oid_h->{msg}{$leaf}   = 'wait';
                    next LEAF;
                } elsif ($dep_error) {

                    if ( !defined $oid_h->{color}{$leaf} or ( $colors{$dep_color} > $colors{ $oid_h->{color}{$leaf} } ) ) {
                        $oid_h->{val}{$leaf}   = $dep_val;
                        $oid_h->{color}{$leaf} = $dep_color;
                        $oid_h->{msg}{$leaf}   = $dep_msg if defined $dep_msg;
                    } elsif ( $oid_h->{color}{$leaf} eq $dep_color ) {

                        # in case of error we should have an undefined value but let it like that for now
                        # until we handle properly error info
                        if ( defined $dep_val and ( $dep_val ne '' ) ) {
                            if ( ( defined $oid_h->{val}{$leaf} ) and ( $oid_h->{val}{$leaf} ne '' ) and $oid_h->{val}{$leaf} ne $dep_val ) {
                                $oid_h->{val}{$leaf} .= "|" . $dep_val;
                            } else {
                                $oid_h->{val}{$leaf} = $dep_val;
                            }
                        }
                        if ( defined $dep_msg ) {
                            if ( defined $oid_h->{msg}{$leaf} and $oid_h->{msg}{$leaf} ne '' ) {
                                $oid_h->{msg}{$leaf} .= " & " . $dep_msg;
                            } else {
                                $oid_h->{msg}{$leaf} = $dep_msg;
                            }
                        }
                    }
                    $oid_h->{error}{$leaf} = 1;

                    next;

                } elsif ( defined $regex and $dep_val !~ /$regex/ ) {

                    do_log("$dep_val mismatch $regex for dependent oid $dep_oid, leaf $leaf}",ERROR);
                    $oid_h->{val}{$leaf}   = "$dep_val mismatch $regex";
                    $oid_h->{color}{$leaf} = 'yellow';
                    $oid_h->{error}{$leaf} = 1;
                    next LEAF;
                } else {
                    $leaf_deps_valid = 1;
                }
            }

            # Check if all leaf deps are valid if yes we have at least 1 leaf valid so the the validationn will succeed!
            if ($leaf_deps_valid) {
                $deps_valid = 1;
            } else {

                #Throw one error message per leaf, to prevent log bloat
                do_log( "'No valid dep for leaf '$leaf' on '$device'", DEBUG );
            }
        }

        # Non repeater or repaeter without a valid index of leaf for the (dependant) pri oid (so treated a non-repeater)
    } else {

        # preprocess time base on the pri oid
        my $time;
        if ( defined $oids->{$pri_oid}{time} ) {
            $time = $oids->{$pri_oid}{time};
        } else {

            $time = time;
        }

        # Parse our parent oids
        for my $dep_oid (@$dep_arr) {

            my $dep_val = $oids->{$dep_oid}{val};

            if ( !defined $oids->{$dep_oid}{val} ) {
                $oid_h->{val} = undef;
                if ( defined $oids->{$dep_oid}{color} ) {
                    $oid_h->{color} = $oids->{$dep_oid}{color};
                } else {
                    $oid_h->{color} = "clear";
                }
                if ( defined $oids->{$dep_oid}{msg} ) {
                    $oid_h->{msg} = $oids->{$dep_oid}{msg};
                } else {
                    $oid_h->{msg} = 'parent value n/a';
                }
                $oid_h->{error} = 1;
            } elsif ( $dep_val eq 'wait' ) {
                $oid_h->{val}   = 'wait';
                $oid_h->{color} = 'clear';
                $oid_h->{error} = 1;
                $oid_h->{msg}   = 'wait';
            } elsif ( $oids->{$dep_oid}{error} ) {

                # Find de worst color
                if ( !defined $oid_h->{color}
                    or $colors{ $oids->{$dep_oid}{color} } > $colors{ $oid_h->{color} } )
                {

                    $oid_h->{val}   = $oids->{$dep_oid}{val};
                    $oid_h->{color} = $oids->{$dep_oid}{color};
                    $oid_h->{msg}   = $oids->{$dep_oid}{msg};
                } elsif ( $oid_h->{color} eq $oids->{$dep_oid}{color} ) {

                    if ( defined $oids->{$dep_oid}{val} and ( $oids->{$dep_oid}{val} ne '' ) ) {
                        if ( ( defined $oid_h->{val} ) and ( $oid_h->{val} ne '' ) and $oid_h->{val} ne $oids->{$dep_oid}{val} ) {
                            $oid_h->{val} .= "|" . $oids->{$dep_oid}{val};
                        } else {
                            $oid_h->{val} = $oids->{$dep_oid}{val};
                        }
                    }
                    if ( defined $oids->{$dep_oid}{msg} ) {
                        if ( defined $oid_h->{msg} and $oid_h->{msg} ne '' ) {
                            $oid_h->{msg} .= " & " . $oids->{$dep_oid}{msg};
                        } else {
                            $oid_h->{msg} = $oids->{$dep_oid}{msg};
                        }
                    }
                }
                $oid_h->{error} = 1;
            } elsif ( defined $regex and $dep_val !~ /$regex/ ) {
                $oid_h->{val}   = "$dep_val mismatch(=~) $regex";
                $oid_h->{time}  = time;
                $oid_h->{color} = 'yellow';
                $oid_h->{error} = 1;
            } else {

                $deps_valid = 1;
            }
            unless ($deps_valid) {

                # Throw one error message
                do_log( "Dependency '$dep_oid' error for $oid on $device", TRACE );

                last;
            }
        }
    }
    return $deps_valid;
}
