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
use dm_config;
use Math::BigInt::Calc;
use POSIX qw/ strftime /;
use Scalar::Util qw(looks_like_number);
use Data::Dumper;

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
    %{ $g{tmp_hist} }     = ();    # Temporary history hash

    # Timestamp
    $g{testtime} = time;

    do_log( 'INFOR TEST: Performing tests', 3 );

    # Now go through each device and perform the test logic it needs
    for my $device ( sort keys %{ $g{dev_data} } ) {

        my $oids = {};

        # Check to see if this device was unreachable in xymon
        # If so skip device
        next if !defined $g{xymon_color}{$device} or $g{xymon_color}{$device} ne 'green';

        # Get template-specific variables
        my $vendor = $g{dev_data}{$device}{vendor};
        my $model  = $g{dev_data}{$device}{model};
        my $tests  = $g{dev_data}{$device}{tests};

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

            do_log( "DEBUG TEST: Starting test for $test on device $device", 4 ) if $g{debug};

            # Hash shortcut
            my $tmpl = \%{ $g{templates}{$vendor}{$model}{tests}{$test} };

            # custom threshold pointer
            my $thr = \%{ $g{dev_data}{$device}{thresh}{$test} };

            # Create our oids hash that will be populated by both snmp
            # data and transformed data.  This is done to keep me
            # from going insane when we start doing transforms
            oid_hash( $oids, $device, $tmpl, $thr );

            # Perform the transform
            for my $oid ( @{ $tmpl->{sorted_oids} } ) {
                next if !$oids->{$oid}{transform};

                transform( $device, $oids, $oid, $thr );

                # Do some debug if requested
                if ( $g{debug} ) {
                    my $oid_h = \%{ $oids->{$oid} };
                    if ( $oid_h->{repeat} ) {
                        my $line;
                    LEAF: for my $leaf ( keys %{ $oid_h->{val} } ) {
                            $line .= "i:$leaf v:$oid_h->{val}{$leaf}";
                            if ( $g{trace} ) {
                                $line .= " c:$oid_h->{color}{$leaf}" if defined $oid_h->{color}{$leaf};
                                $line .= " e:$oid_h->{error}{$leaf}" if defined $oid_h->{error}{$leaf};
                                $line .= " m:$oid_h->{msg}{$leaf}"   if defined $oid_h->{msg}{$leaf};
                                $line .= " t:$oid_h->{time}{$leaf}"  if defined $oid_h->{time}{$leaf};
                                do_log( "TRACE TEST: $line", 5 );
                                $line = '';
                            } else {
                                $line .= ' ';
                            }
                        }
                        unless ( $g{trace} ) {
                            do_log( "DEBUG TEST: $line", 4 );
                        }

                    } else {
                        my $line;
                        $line = "v:$oid_h->{val}";
                        if ( $g{trace} ) {
                            $line .= " c:$oid_h->{color}" if defined $oid_h->{color};
                            $line .= " e:$oid_h->{error}" if defined $oid_h->{error};
                            $line .= " m:$oid_h->{msg}"   if defined $oid_h->{msg};
                            $line .= " t:$oid_h->{time}"  if defined $oid_h->{time};
                            do_log( "TRACE TEST: $line", 5 );
                        } else {
                            do_log( "DEBUG TEST: $line", 4 );
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

    # Now store our historical data, if any
    # Do it device by device so we don't overwrite any data in the dev_hist
    # hash which may still be relevant but which didn't get updated
    # this test cycle
    for my $device ( keys %{ $g{tmp_hist} } ) {
        %{ $g{dev_hist}{$device} } = %{ $g{tmp_hist}{$device} };
    }

    # Finish timestamp
    $g{testtime} = time - $g{testtime};

    #    do_log( "INFOR TEST: Done with test logic", 3 );
}

# Create a oid hash ref that will eventually contain all gathered
# data (snmp or transformed)
sub oid_hash {
    my ( $oids, $device, $tmpl, $thr ) = @_;

    # Hash shortcuts
    my $snmp = \%{ $g{snmp_data}{$device} };

    # For now we will copy the data from the template and snmp
    # Copy the data even if the OID is already cached during a preceeding test.
    # In the current test, the thresholds or the exceptions might be different.
    for my $oid ( keys %{ $tmpl->{oids} } ) {

        # Don't hash an OID more than once
        next if defined $oids->{$oid}{val};

        # Put all the info we got on the oid in (sans transform data)
        # in the oids hash ref
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
            $oids->{$oid}{trans_edata} = $tmpl->{oids}{$oid}{trans_edata};
            next;
        }

        my $num    = $tmpl->{oids}{$oid}{number};    # this is the numerical oid (1.3.5...) ?!? we dont need it...
        my $repeat = $tmpl->{oids}{$oid}{repeat};

        $oids->{$oid}{transform} = 0;                #why?
        $oids->{$oid}{repeat}    = $repeat;

        if (   !defined $num
            or !defined $snmp->{$num}
            or !defined $snmp->{$num}{val} )
        {
            # log this problem if xymon_color (normally "conn" ping) is green
            do_log( "DEBUG TEST: No SNMP data found (Nil) for $oid on $device", 5 )
                if ( $g{xymon_color}{$device} eq 'green' );
        }

        # If this is a repeater, iterate through its leaves and assign values
        if ($repeat) {
            if ( scalar( keys %{ $snmp->{$num}{val} } ) ) {
                for my $leaf ( keys %{ $snmp->{$num}{val} } ) {

                    # If we have a non-numeric leaf, make sure to keep track of this!
                    # Store this as a type '2' repeater
                    #$oids->{$oid}{repeat} = 2  if $leaf !~ /^\d+$/;
                    $oids->{$oid}{repeat} = 2 if $leaf !~ /^[+-]?(?:\d+\.?\d*|\d*\.\d+)$/;
                    my $val  = $snmp->{$num}{val}{$leaf};
                    my $time = $snmp->{$num}{time}{$leaf};
                    $oids->{$oid}{val}{$leaf}  = $val;
                    $oids->{$oid}{time}{$leaf} = $time;
                }
                $oids->{$oid}{global_val}   = undef;
                $oids->{$oid}{global_error} = undef;
                $oids->{$oid}{global_color} = undef;
                $oids->{$oid}{global_msg}   = undef;

            } else {

                # NEW: NOT FULLY IMPLEMENTED: We need to set global error, not only on leafs, as sometime we dont know the leafs
                $oids->{$oid}{global_val}   = 'Nil';
                $oids->{$oid}{global_error} = 1;
                $oids->{$oid}{global_color} = 'clear';
                $oids->{$oid}{global_msg}   = "No SNMP answer for OID: $oid";

            }

            # Apply thresholds
            apply_thresh_rep( $oids, $thr, $oid );

            # Otherwise its just a normal non-repeater
        } else {
            if ( defined $snmp->{$num}{val} ) {
                $oids->{$oid}{val}   = $snmp->{$num}{val};
                $oids->{$oid}{error} = undef;
                $oids->{$oid}{color} = undef;
                $oids->{$oid}{msg}   = undef;
            } else {
                $oids->{$oid}{val}   = 'Nil';
                $oids->{$oid}{error} = 1;
                $oids->{$oid}{color} = "clear";
                $oids->{$oid}{msg}   = "No SNMP answer for OID: $oid";
            }
            $oids->{$oid}{time} = $snmp->{$num}{time};

            # Apply threshold
            apply_thresh( $oids, $thr, $oid );

        }
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
    do_log( "DEBUG TEST: Doing $trans_type transform on $device/$oid", 4 ) if $g{debug};
    if ( defined &$trans_sub ) {
        eval {
            local $SIG{ALRM} = sub { die "Timeout\n" };
            alarm 5;
            &$trans_sub( $device, $oids, $oid, $thr );
            alarm 0;
        };

        if ($@) {
            if ( $@ eq "Timeout\n" ) {
                do_log( "Timed out waiting for $trans_type transform " . "on oid $oid for $device to complete." );
            } else {
                do_log( "Got unexpected error while performing $trans_type " . "transform on oid $oid for $device: $@" );
            }
        }
    } else {

        # Theoretically we should never get here, but whatever
        do_log( "Undefined transform type '$trans_type' found for $device", 0 )
            and return;
    }
    use strict 'refs';
}

# Do data over time delta transformations ####################################
sub trans_delta {
    my ( $device, $oids, $oid, $thr ) = @_;

    # Hash shortcuts
    my $hist     = \%{ $g{dev_hist}{$device} };
    my $hist_tmp = \%{ $g{tmp_hist}{$device} };
    my $oid_h    = \%{ $oids->{$oid} };

    # Extract our transform options
    my ( $dep_oid, $limit ) = ( $1, $2 || 0 )
        if $oid_h->{trans_data} =~ /\{(.+)\}(?:\s+:\s*(\d+))?/;
    my $dep_oid_h = \%{ $oids->{$dep_oid} };

    # Check our parent oids for any errors
    if ( not validate_deps( $device, $oids, $oid, [$dep_oid], '^[-+]?\d+(\.\d+)?$' ) ) {
        do_log( "DEBUG TEST: Delta transform on $device/$oid do not have valid dependencies: skipping", 4 ) if $g{debug};
        return;
    }

    # See if we are a repeating variable type datum
    # (such as that generated by snmpwalking a table)
    if ( $oid_h->{repeat} ) {

    LEAF: for my $leaf ( keys %{ $dep_oid_h->{val} } ) {

            # Skip if we got a dependency error for this leaf
            next if $oid_h->{error}{$leaf};

            my $this_data = $dep_oid_h->{val}{$leaf};
            my $this_time = $dep_oid_h->{time}{$leaf};

            # Check if we have history, return delta if so
            if ( defined $hist->{$dep_oid}{val}{$leaf}
                and $this_time != $hist->{$dep_oid}{time}{$leaf} )
            {
                my $last_data = $hist->{$dep_oid}{val}{$leaf};
                my $last_time = $hist->{$dep_oid}{time}{$leaf};
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
                        do_log( "Data type too large for leaf $leaf of  " . "$dep_oid on $device.", 0 );
                        $oid_h->{val}{$leaf}   = 'Too large';
                        $oid_h->{time}{$leaf}  = time;
                        $oid_h->{color}{$leaf} = 'yellow';
                        $oid_h->{error}{$leaf} = 1;
                        next LEAF;
                    }

                    do_log( "Counterwrap on $oid.$leaf on $device (this: $this_data " . "last: $last_data delta: $delta", 4 ) if $g{debug};

                    # Otherwise do normal delta calc
                } else {
                    $delta = ( $this_data - $last_data ) / ( $this_time - $last_time );
                }

                # Round delta to two decimal places
                $delta = sprintf "%.2f", $delta;

                $oid_h->{val}{$leaf}  = $delta;
                $oid_h->{time}{$leaf} = time;

                # No history; throw wait message
            } else {
                $oid_h->{val}{$leaf}   = 'wait';
                $oid_h->{time}{$leaf}  = time;
                $oid_h->{color}{$leaf} = 'clear';

                #$oid_h->{error}{$leaf} = 1;
                #$oid_h->{msg}{$leaf}   = '';
            }

            # Store history in temp hash
            $hist_tmp->{$dep_oid}{val}{$leaf}  = $this_data;
            $hist_tmp->{$dep_oid}{time}{$leaf} = $this_time;
        }

        # Apply thresholds
        apply_thresh_rep( $oids, $thr, $oid );

        # Otherwise we are a single entry datum
    } else {

        my $this_data = $dep_oid_h->{val};
        my $this_time = $dep_oid_h->{time};

        # Check if we have history, return delta if so
        if ( defined $hist->{$dep_oid} ) {
            my $last_data = $hist->{$dep_oid}{val};
            my $last_time = $hist->{$dep_oid}{time};

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
                    do_log( "Data type too large for $dep_oid on $device.", 0 );
                    $oid_h->{val}   = 'Too large';
                    $oid_h->{time}  = time;
                    $oid_h->{color} = 'yellow';
                    $oid_h->{error} = 1;
                    return;
                }

                do_log( "Counterwrap on $oid on $device (this: $this_data " . "last: $last_data delta: $delta", 4 )
                    if $g{debug};

                # Otherwise do normal delta calc
            } else {
                $delta = ( $this_data - $last_data ) / ( $this_time - $last_time );
            }

            $delta         = sprintf "%.2f", $delta;
            $oid_h->{val}  = $delta;
            $oid_h->{time} = time;

            # Now apply our threshold to this data
            #apply_thresh($oids, $thr, $oid);

            # No history; throw wait message
        } else {
            $oid_h->{val}   = 'wait';
            $oid_h->{time}  = time;
            $oid_h->{color} = 'clear';

            #$oid_h->{error} = 1;
            #$oid_h->{msg} = '';
        }

        # Now apply our threshold to this data
        apply_thresh( $oids, $thr, $oid );

        # Set temporary history data
        $hist_tmp->{$dep_oid}{val}  = $this_data;
        $hist_tmp->{$dep_oid}{time} = $this_time;
    }
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

    # Validate our dependencies
    if ( not validate_deps( $device, $oids, $oid, \@dep_oids, '^[-+]?\d+(\.\d+)?$' ) ) {

        #if ( not validate_deps($device, $oids, $oid, \@dep_oids ) ) {
        do_log( "DEBUG TEST: Math transform on $device/$oid do not have valid dependencies: skipping", 4 ) if $g{debug};
        return;
    }

    # Also go through our non-repeaters and replace them in our
    # expression, since they are constant (i.e. not leaf dependent)
    my @repeaters;
    for my $dep_oid (@dep_oids) {
        push @repeaters, $dep_oid and next if $oids->{$dep_oid}{repeat};
        $expr =~ s/\{$dep_oid\}/$oids->{$dep_oid}{val}/g;
    }

    # Handle repeater-type oids
    if ( $oid_h->{repeat} ) {
        my @dep_val;

        # Map our oids in the expression to a position on the temp 'dep_val' array
        # Sure, we could just do a regsub for every dep_oid on every leaf, but
        # thats pretty expensive CPU-wise
        for ( my $i = 0; $i <= $#repeaters; $i++ ) {
            $expr =~ s/\{$repeaters[$i]\}/\$dep_val[$i]/g;
        }

        for my $leaf ( keys %{ $oids->{ $oid_h->{pri_oid} }{val} } ) {

            # Skip if we got a dependency error for this leaf
            next if $oid_h->{error}{$leaf};

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
                    $oid_h->{color}{$leaf} = 'yellow';
                    delete $oid_h->{msg}{$leaf};      # we propably do have to delete anything but as we would like to override non fatal error
                    delete $oid_h->{error}{$leaf};    # we do it for now, but we could have an non fatal error: fatal = 2, non fatal = 1 ?
                    delete $oid_h->{thresh}{$leaf};

                } else {
                    do_log( "ERROR TEST: Failed eval for TRANS_MATH on $oid.$leaf: $expr ($@)", 1 );
                    $oid_h->{val}{$leaf}   = $@;
                    $oid_h->{color}{$leaf} = 'yellow';
                    delete $oid_h->{msg}{$leaf};
                    delete $oid_h->{error}{$leaf};
                    delete $oid_h->{thresh}{$leaf};
                }

                #  next;
            } else {
                $result = sprintf $print_mask, $result;
                $oid_h->{val}{$leaf} = $result;
            }
        }

        # Apply thresholds
        apply_thresh_rep( $oids, $thr, $oid );

        # Otherwise we are a single entry datum
    } else {

        # All of our non-reps were substituted earlier, so we can just eval
        my $result = eval $expr;
        $oid_h->{time} = time;

        if ($@) {
            chomp $@;
            if ( $@ =~ /^Illegal division by zero/ ) {
                $oid_h->{val}   = 'NaN';
                $oid_h->{color} = 'yellow';
                delete $oid_h->{msg};
                delete $oid_h->{error};
                delete $oid_h->{thresh};
            } else {
                do_log( "ERROR TEST: Failed eval for TRANS_MATH on $oid: $expr ($@)", 1 );
                $oid_h->{val}   = $@;
                $oid_h->{color} = 'yellow';
                delete $oid_h->{msg};
                delete $oid_h->{error};
                delete $oid_h->{thresh};
            }
        } else {
            $result       = sprintf $print_mask, $result;
            $oid_h->{val} = $result;
        }

        # Now apply our threshold to this data
        apply_thresh( $oids, $thr, $oid );
    }
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

    # Do not use function validate_deps. It will make this oid to be of the
    # repeater-type if the parent oid is of the repeater-type. The code section
    # below is inspired on the relevant parts of function validate_deps.
    #
    $oid_h->{repeat} = 0;       # Make a leaf-type oid
    $oid_h->{val}    = undef;
    $oid_h->{color}  = undef;
    $oid_h->{msg}    = undef;
    $oid_h->{error}  = undef;

    # Check all the leaves of a repeater-type oid for an error condition. If
    # one is found, propagate the error condition to the result oid.
    #
    if ( $dep_oid_h->{repeat} ) {
        if ( scalar keys %{ $dep_oid_h->{val} } ) {
            for $leaf ( keys %{ $dep_oid_h->{val} } ) {
                $val = $dep_oid_h->{val}{$leaf};
                if ( !defined $val ) {
                    $oid_h->{val}   = 'parent value n/a';
                    $oid_h->{color} = 'yellow';
                    last;
                } elsif ( $val eq 'wait' ) {
                    $oid_h->{val}   = 'wait';
                    $oid_h->{color} = 'clear';
                    $oid_h->{msg}   = '';
                    last;
                } elsif ( $dep_oid_h->{error}{$leaf} ) {
                    $oid_h->{val}   = 'inherited';
                    $oid_h->{color} = 'clear';
                    last;
                } elsif ( $statistic ne 'cnt' and $val !~ m/^[-+]?\d+(?:\.\d+)?$/ ) {
                    $oid_h->{val}   = 'Regex mismatch';
                    $oid_h->{color} = 'yellow';
                    last;
                }
            }
        } else {

            # there is no leaf, so they are undefined
            $oid_h->{val}   = 'parent value n/a';
            $oid_h->{color} = 'yellow';
        }
    } else {
        if ( $dep_oid_h->{error} ) {
            $oid_h->{val}   = $dep_oid_h->{val};
            $oid_h->{color} = $dep_oid_h->{color};
        }    # of if
    }    # of else

    if ( defined $oid_h->{val} ) {
        $oid_h->{time}  = time;
        $oid_h->{error} = 1;
    }    # of if
         # bypass if we already have an error code
    if ( !defined $oid_h->{error} ) {

        # The parent oid is a repeater-type oid. Determine the requested statistic
        # from this list.
        #
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
                #
                $leaf   = shift @leaf;
                $result = $dep_oid_h->{val}{$leaf};
                for $leaf (@leaf) {
                    $val = $dep_oid_h->{val}{$leaf};
                    &{ $comp{$statistic} };    # Perform statistical computation
                }    # of for
                $result = $result / $count if $statistic eq 'avg';
            }    # of else

            $oid_h->{val}  = $result;
            $oid_h->{time} = time;

            # The parent oid is a non-repeater-type oid. The computation of the
            # statistic is trivial in this case.
        } else {
            $oid_h->{val}  = $dep_oid_h->{val};
            $oid_h->{val}  = 1 if $statistic eq 'cnt';
            $oid_h->{time} = $dep_oid_h->{time};
            $oid_h->{msg}  = $dep_oid_h->{msg};
        }    # of else
    }
    apply_thresh( $oids, $thr, $oid );
}    # of trans_statistic

# Get substring of dependent oid ############################################
sub trans_substr {
    my ( $device, $oids, $oid, $thr ) = @_;
    my $oid_h = \%{ $oids->{$oid} };

    my ( $dep_oid, $offset, $length ) = ( $1, $2, $3 )
        if $oid_h->{trans_data} =~ /^\{(.+)\}\s+(\d+)\s*(\d*)$/;
    my $dep_oid_h = \%{ $oids->{$dep_oid} };
    $length = undef if $length eq '';

    validate_deps( $device, $oids, $oid, [$dep_oid] ) or return;

    # See if we are a repeating variable type datum
    # (such as that generated by snmpwalking a table)
    if ( $oid_h->{repeat} ) {
        for my $leaf ( keys %{ $dep_oid_h->{val} } ) {

            # Skip if we got a dependency error for this leaf
            next if $oid_h->{error}{$leaf};

            # Do string substitution
            my $string = $dep_oid_h->{val}{$leaf};
            if ( defined $length ) {
                $oid_h->{val}{$leaf} = substr $string, $offset, $length;
            } else {
                $oid_h->{val}{$leaf} = substr $string, $offset;
            }

            $oid_h->{time}{$leaf} = time;

            # Apply thresholds
            apply_thresh_rep( $oids, $thr, $oid );
        }

        # Otherwise we are a non-repeater oid
    } else {
        my $string = $dep_oid_h->{val};
        if ( defined $length ) {
            $oid_h->{val} = substr $string, $offset, $length;
        } else {
            $oid_h->{val} = substr $string, $offset;
        }
        $oid_h->{time} = time;

        # Now apply our threshold to this data
        apply_thresh( $oids, $thr, $oid );
    }
}

# WIP : DO NOT USE
# Compute logical 'AND' of dependent oids' values ###########################
sub trans_and {
    my ( $device, $oids, $oid, $thr ) = @_;
    my $oid_h = \%{ $oids->{$oid} };

    # Extract all our our parent oids from the expression, first
    my @dep_oids = $oid_h->{trans_data} =~ /\{(.+?)\}/g;

    # Validate our dependencies
    validate_deps( $device, $oids, $oid, \@dep_oids, '^[-+]?\d+(\.\d+)?$' )
        or return;

    # See if we are a repeating variable type datum
    # (such as that generated by snmpwalking a table)
    if ( $oid_h->{repeat} ) {

        # Default values
        my $value   = 1;
        my $color   = 'blue';
        my $pri_oid = $oid_h->{pri_oid};
        my $msg     = $oids->{$pri_oid}{msg};

        for my $leaf ( keys %{ $oids->{$pri_oid}{val} } ) {

            # Skip if we got a dependency error for this leaf
            next if $oid_h->{error}{$leaf};

            my $val = 1;
            my $col = 'blue';
            my $msg = '';
            for my $dep_oid (@dep_oids) {
                my $dep_oid_h = \%{ $oids->{$dep_oid} };
                my ( $dep_val, $dep_col, $dep_msg );

                if ( $dep_oid_h->{repeat} ) {
                    $dep_val = $dep_oid_h->{val}{$leaf};
                    $dep_col = $dep_oid_h->{color}{$leaf};
                    $dep_msg = $dep_oid_h->{msg}{$leaf};
                } else {
                    $dep_val = $dep_oid_h->{val};
                    $dep_col = $dep_oid_h->{color};
                    $dep_msg = $dep_oid_h->{msg};
                }

                $col = $dep_col and $msg = $dep_msg
                    if $colors{$col} < $colors{$dep_col};
                $val = 0 if !$dep_val;
            }

            $oid_h->{val}{$leaf}  = $val;
            $oid_h->{time}{$leaf} = time;
        }

        # Apply thresholds
        apply_thresh_rep( $oids, $thr, $oid );

        # Otherwise we are a single entry datum
    } else {

        # Default values
        my $val = 1;
        my $col = 'blue';
        my $msg = '';

        for my $dep_oid (@dep_oids) {
            my $dep_oid_h = \%{ $oids->{$dep_oid} };
            my $dep_val   = $dep_oid_h->{val};
            my $dep_col   = $dep_oid_h->{color};
            my $dep_msg   = $dep_oid_h->{msg};

            $col = $dep_col and $msg = $dep_msg
                if $colors{$col} < $colors{$dep_col};
            $val = 0 if !$dep_val;
        }

        $oid_h->{val}  = $val;
        $oid_h->{time} = time;

        # Apply thresholds
        apply_thresh( $oids, $thr, $oid );
    }
}

# WIP: DO NOT USE
# Compute logical 'OR' of dependent oids' values ###########################
sub trans_or {
    my ( $device, $oids, $oid, $thr ) = @_;
    my $oid_h = \%{ $oids->{$oid} };

    # Extract all our our parent oids from the expression, first
    my @dep_oids = $oid_h->{trans_data} =~ /\{(.+?)\}/g;

    # Validate our dependencies
    validate_deps( $device, $oids, $oid, \@dep_oids, '^[-+]?\d+(\.\d+)?$' )
        or return;

    # See if we are a repeating variable type datum
    # (such as that generated by snmpwalking a table)
    if ( $oid_h->{repeat} ) {

        # Get our primary repeater oid
        my $pri_oid = $oid_h->{pri_oid};

        # Default values
        my $val = 0;
        my $col = 'blue';
        my $msg = $oids->{$pri_oid}{msg};

        for my $leaf ( keys %{ $oids->{$pri_oid}{val} } ) {

            # Skip if we got a dependency error for this leaf
            next if $oid_h->{error}{$leaf};

            my $val = 1;
            my $col = 'blue';
            my $msg = '';

            for my $dep_oid (@dep_oids) {
                my $dep_oid_h = \%{ $oids->{$dep_oid} };
                my ( $dep_val, $dep_col, $dep_msg );

                if ( $dep_oid_h->{repeat} ) {
                    $dep_val = $dep_oid_h->{val}{$leaf};
                    $dep_col = $dep_oid_h->{color}{$leaf};
                    $dep_msg = $dep_oid_h->{msg}{$leaf};
                } else {
                    $dep_val = $dep_oid_h->{val};
                    $dep_col = $dep_oid_h->{color};
                    $dep_msg = $dep_oid_h->{msg};
                }

                $col = $dep_col and $msg = $dep_msg
                    if $colors{$col} < $colors{$dep_col};
                $val = 1 if $dep_val;
            }

            $oid_h->{val}{$leaf}  = $val;
            $oid_h->{time}{$leaf} = time;
        }

        # Apply thresholds
        apply_thresh_rep( $oids, $thr, $oid );

        # Otherwise we are a single entry datum
    } else {

        # Default values
        my $val = 0;
        my $col = 'blue';
        my $msg = '';

        for my $dep_oid (@dep_oids) {
            my $dep_oid_h = \%{ $oids->{$dep_oid} };
            my $dep_val   = $dep_oid_h->{val};
            my $dep_col   = $dep_oid_h->{color};
            my $dep_msg   = $dep_oid_h->{msg};

            $col = $dep_col and $msg = $dep_msg
                if $colors{$col} < $colors{$dep_col};
            $val = 1 if $dep_val;
        }

        $oid_h->{val}  = $val;
        $oid_h->{time} = time;

        # Apply thresholds
        apply_thresh( $oids, $thr, $oid );
    }
}

sub trans_pack {
    my ( $device, $oids, $oid, $thr ) = @_;
    my $oid_h = \%{ $oids->{$oid} };

    my ( $dep_oid, $type, $seperator ) = ( $1, $2, $3 || '' )
        if $oid_h->{trans_data} =~ /^\{(.+)\}\s+(\S+)(?:\s+"(.+)")?/;
    my $dep_oid_h = \%{ $oids->{$dep_oid} };

    # Validate our dependencies
    validate_deps( $device, $oids, $oid, [$dep_oid] ) or return;

    # See if we are a repeating variable type datum
    # (such as that generated by snmpwalking a table)
    if ( $oid_h->{repeat} ) {

        # Unpack ze data
        for my $leaf ( keys %{ $dep_oid_h->{val} } ) {

            # Skip if we got a dependency error for this leaf
            next if $oid_h->{error}{$leaf};

            my @packed = split $seperator, $dep_oid_h->{val}{$leaf};
            my $val    = pack $type, @packed;

            do_log( "Transformed $dep_oid_h->{val}{$leaf}, first val $packed[0], to $val via pack transform type $type, seperator $seperator ", 4 ) if $g{debug};

            $oid_h->{val}{$leaf}  = $val;
            $oid_h->{time}{$leaf} = time;
        }

        # Apply thresholds
        apply_thresh_rep( $oids, $thr, $oid );

        # Otherwise we are a single entry datum
    } else {
        my $packed = $dep_oid_h->{val};
        my @vars   = pack $type, $packed;

        $oid_h->{val}  = join $seperator, @vars;
        $oid_h->{time} = time;

        # Apply thresholds
        apply_thresh( $oids, $thr, $oid );
    }
}

# Translate hex or octal data into decimal ##################################
sub trans_unpack {
    my ( $device, $oids, $oid, $thr ) = @_;
    my $oid_h = \%{ $oids->{$oid} };

    my ( $dep_oid, $type, $seperator ) = ( $1, $2, $3 || '' )
        if $oid_h->{trans_data} =~ /^\{(.+)\}\s+(\S+)(?:\s+"(.+)")?/;
    my $dep_oid_h = \%{ $oids->{$dep_oid} };

    # Validate our dependencies
    validate_deps( $device, $oids, $oid, [$dep_oid] ) or return;

    # See if we are a repeating variable type datum
    # (such as that generated by snmpwalking a table)
    if ( $oid_h->{repeat} ) {

        # Unpack ze data
        for my $leaf ( keys %{ $dep_oid_h->{val} } ) {

            # Skip if we got a dependency error for this leaf
            next if $oid_h->{error}{$leaf};

            my $packed = $dep_oid_h->{val}{$leaf};
            my @vars   = unpack $type, $packed;

            $oid_h->{val}{$leaf}  = join $seperator, @vars;
            $oid_h->{time}{$leaf} = time;
        }

        # Apply thresholds
        apply_thresh_rep( $oids, $thr, $oid );

        # Otherwise we are a single entry datum
    } else {
        my $packed = $dep_oid_h->{val};
        my @vars   = unpack $type, $packed;

        $oid_h->{val}  = join $seperator, @vars;
        $oid_h->{time} = time;

        # Apply thresholds
        apply_thresh( $oids, $thr, $oid );
    }
}

# Translate hex or octal data into decimal ##################################
sub trans_convert {
    my ( $device, $oids, $oid, $thr ) = @_;
    my $oid_h = \%{ $oids->{$oid} };

    # Extract our translation options
    my ( $dep_oid, $type, $pad ) = ( $1, lc $2, $3 )
        if $oid_h->{trans_data} =~ /^\{(.+)\}\s+(hex|oct)\s*(\d*)$/i;
    my $dep_oid_h = \%{ $oids->{$dep_oid} };

    # Validate our dependencies
    validate_deps( $device, $oids, $oid, [$dep_oid] ) or return;

    # See if we are a repeating variable type datum
    # (such as that generated by snmpwalking a table)
    if ( $oid_h->{repeat} ) {

        # Do our conversions
        for my $leaf ( keys %{ $dep_oid_h->{val} } ) {

            # Skip if we got a dependency error for this leaf
            next if $oid_h->{error}{$leaf};

            my $val = $dep_oid_h->{val}{$leaf};
            my $int;
            if   ( $type eq 'oct' ) { $int = oct $val }
            else                    { $int = hex $val }
            $int                  = sprintf '%' . "$pad.$pad" . 'd', $int if $pad ne '';
            $oid_h->{val}{$leaf}  = $int;
            $oid_h->{time}{$leaf} = time;
        }

        # Apply thresholds
        apply_thresh_rep( $oids, $thr, $oid );

        # Otherwise we are a single entry datum
    } else {
        my $val = $dep_oid_h->{val};
        my $int;
        if ( $type eq 'oct' ) {
            $int = oct $val;
        } else {
            $int = hex $val;
        }
        $int           = sprintf '%' . "$pad.$pad" . 'd', $int if $pad ne '';
        $oid_h->{val}  = $int;
        $oid_h->{time} = time;

        # Apply thresholds
        apply_thresh( $oids, $thr, $oid );
    }
}

# Do String translations ###############################################
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

        # Map our oids in the expression to a position on the temp 'dep_val' array
        # Sure, we could just do a regsub for every dep_oid on every leaf, but
        # thats pretty expensive CPU-wise
        for ( my $i = 0; $i <= $#repeaters; $i++ ) {
            $expr =~ s/\{$repeaters[$i]\}/\$dep_val[$i]/g;
        }

        for my $leaf ( keys %{ $oids->{ $oid_h->{pri_oid} }{val} } ) {

            # Skip if we got a dependency error for this leaf
            next if $oid_h->{error}{$leaf};

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
                do_log("Failed eval for TRANS_EVAL on $oid.$leaf: $expr ($@)");
                $oid_h->{val}{$leaf}   = 'Failed eval';
                $oid_h->{color}{$leaf} = 'clear';
                $oid_h->{error}{$leaf} = 1;
                next;
            }

            $oid_h->{val}{$leaf} = $result;
        }

        # Apply thresholds
        apply_thresh_rep( $oids, $thr, $oid );

        # Otherwise we are a single entry datum
    } else {

        # All of our non-reps were substituted earlier, so we can just eval
        my $result = eval $expr;
        $oid_h->{time} = time;

        if ( $@ =~ /^Undefined subroutine/ ) {
            $result = 0;
        } elsif ($@) {
            do_log("Failed eval for TRANS_STR on $oid: $expr ($@)");
            $oid_h->{val}   = 'Failed eval';
            $oid_h->{color} = 'clear';
            $oid_h->{error} = 1;
        }

        $oid_h->{val} = $result;

        # Now apply our threshold to this data
        apply_thresh( $oids, $thr, $oid );
    }
}

# Get the best color of one or more oids ################################
sub trans_best {
    my ( $device, $oids, $oid, $thr ) = @_;
    my $oid_h = \%{ $oids->{$oid} };

    # Extract all our our parent oids from the expression, first
    my @dep_oids = $oid_h->{trans_data} =~ /\{(.+?)\}/g;

    # Don't Validate our dependencies as this very similar function
    # but we will validate during the transform

    # Go through our parent oid array, if there are any repeaters
    # set the first one as the primary OID and set the repeat type
    for my $dep_oid (@dep_oids) {
        if ( $oids->{$dep_oid}{repeat} ) {
            $oid_h->{pri_oid} = $dep_oid;
            $oid_h->{repeat}  = $oids->{$dep_oid}{repeat};
            last;
        }
    }

    # Use a non-repeater type if we havent set it yet
    $oid_h->{repeat} ||= 0;

    # Do repeater-type oids
    if ( $oid_h->{repeat} ) {

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
                        #       or $dep_oid_h->{error}{$leaf}          < $oid_h->{error}{$leaf}          ) {

                        # OLD; WRONGNOW error is not copied as we want to apply threshold (heritate and  override if configureed)
                        # but their are set at the end of the theshold apply process
                        #oid_h->{val}{$leaf}         = $dep_oid_h_val->{$leaf};
                        $oid_h->{val}{$leaf}   = $dep_oid_h->{val}{$leaf};
                        $oid_h->{color}{$leaf} = $dep_oid_h->{color}{$leaf};
                        $oid_h->{msg}{$leaf}   = $dep_oid_h->{msg}{$leaf};

                        #          $oid_h->{error}{$leaf}      = $dep_oid_h->{error}{$leaf};
                        $oid_h->{time}{$leaf} = time;
                    } elsif ( $dep_oid_h->{color}{$leaf} eq $oid_h->{color}{$leaf} ) {

                        #              and $dep_oid_h->{error}{$leaf} ==  $oid_h->{error}{$leaf} ) {
                        #$oid_h->{val}{$leaf}       .= "|". $dep_oid_h_val->{$leaf};
                        $oid_h->{val}{$leaf} .= "|" . $dep_oid_h->{val}{$leaf};
                        if ( defined $dep_oid_h->{msg}{$leaf} ) {
                            if ( defined $oid_h->{msg}{$leaf} and $oid_h->{msg}{$leaf} ne '' ) {
                                $oid_h->{msg}{$leaf} .= " 1& " . $dep_oid_h->{msg}{$leaf};
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
                        #        or $dep_oid_h->{error}          < $oid_h->{error}{$leaf}          ) {
                        #$oid_h->{val}{$leaf}        = $dep_oid_h_val;
                        $oid_h->{val}{$leaf}   = $dep_oid_h->{val}{$leaf};
                        $oid_h->{color}{$leaf} = $dep_oid_h->{color};
                        $oid_h->{msg}{$leaf}   = $dep_oid_h->{msg};

                        #          $oid_h->{error}{$leaf}      = $dep_oid_h->{error};
                        $oid_h->{time}{$leaf} = time;
                    } elsif ( $dep_oid_h->{color} eq $oid_h->{color}{$leaf} ) {

                        #           and $dep_oid_h->{error} == $oid_h->{error}{$leaf} ) {
                        #$oid_h->{val}{$leaf}       .= "|". $dep_oid_h_val;
                        $oid_h->{val}{$leaf} .= "|" . $dep_oid_h->{val}{$leaf};
                        if ( defined $dep_oid_h->{msg} ) {
                            if ( defined $oid_h->{msg}{$leaf} and $oid_h->{msg} ne '' ) {
                                $oid_h->{msg}{$leaf} .= " 2& " . $dep_oid_h->{msg};
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

        # Now apply our threshold to this data
        apply_thresh_rep( $oids, $thr, $oid );

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

                #$oid_h->{val}       .= "|". $dep_oid_h_val;
                $oid_h->{val} .= "|" . $dep_oid_h->{val};
                if ( defined $dep_oid_h->{msg} ) {
                    if ( defined $oid_h->{msg} and $oid_h->{msg} ne '' ) {
                        $oid_h->{msg} .= " 2& " . $dep_oid_h->{msg};
                    } else {
                        $oid_h->{msg} = $dep_oid_h->{msg};
                    }
                }

                #$oid_h->{error}      = $dep_oid_h->{error} || $oid_h->{error};
                $oid_h->{time} = time;
            }
        }

        # Check for this leaf is all dep oid are in error
        #if ($all_dep_oid_error) {
        #   #$oid_h->{error}      = 1;
        #}

        # Now apply our threshold to this data
        apply_thresh( $oids, $thr, $oid );
    }
}

# Get the worst color of one or more oids ##################################
sub trans_worst {
    my ( $device, $oids, $oid, $thr ) = @_;
    my $oid_h = \%{ $oids->{$oid} };

    # Extract all our our parent oids from the expression, first
    my @dep_oids = $oid_h->{trans_data} =~ /\{(.+?)\}/g;

    # Don't Validate our dependencies as this very, very near function

    # Go through our parent oid array, if there are any repeaters
    # set the first one as the primary OID and set the repeat type
    for my $dep_oid (@dep_oids) {
        if ( $oids->{$dep_oid}{repeat} ) {
            $oid_h->{pri_oid} = $dep_oid;
            $oid_h->{repeat}  = $oids->{$dep_oid}{repeat};
            last;
        }
    }

    # Use a non-repeater type if we havent set it yet
    $oid_h->{repeat} ||= 0;

    # Do repeater-type oids
    if ( $oid_h->{repeat} ) {

        for my $leaf ( keys %{ $oids->{ $oid_h->{pri_oid} }{val} } ) {

            # Go through each parent oid for this leaf
            for my $dep_oid (@dep_oids) {
                my $dep_oid_h = \%{ $oids->{$dep_oid} };

                # Skip if there was a dependency error for this parent oid leaf
                # and if it is disable (blue)
                next if ( $dep_oid_h->{error}{$leaf} && $dep_oid_h->{color}{$leaf} eq 'blue' );

                if ( $dep_oid_h->{repeat} ) {
                    if ( !defined $oid_h->{color}{$leaf}
                        or $colors{ $dep_oid_h->{color}{$leaf} } > $colors{ $oid_h->{color}{$leaf} } )
                    {
                        $oid_h->{val}{$leaf}   = $dep_oid_h->{val}{$leaf};
                        $oid_h->{color}{$leaf} = $dep_oid_h->{color}{$leaf};
                        $oid_h->{msg}{$leaf}   = $dep_oid_h->{msg}{$leaf};
                        $oid_h->{error}{$leaf} = $dep_oid_h->{error}{$leaf};
                        $oid_h->{time}{$leaf}  = time;
                    } elsif ( $dep_oid_h->{color}{$leaf} eq $oid_h->{color}{$leaf} ) {
                        $oid_h->{val}{$leaf} .= "|" . $dep_oid_h->{val}{$leaf};
                        if ( defined $dep_oid_h->{msg}{$leaf} ) {
                            if ( defined $oid_h->{msg}{$leaf} and $oid_h->{msg}{$leaf} ne '' ) {
                                $oid_h->{msg}{$leaf} .= " & " . $dep_oid_h->{msg}{$leaf};
                            } else {
                                $oid_h->{msg}{$leaf} = $dep_oid_h->{msg}{$leaf};
                            }
                        }
                        $oid_h->{error}{$leaf} = $dep_oid_h->{error}{$leaf} || $oid_h->{error}{$leaf};
                        $oid_h->{time}{$leaf}  = time;
                    }
                } else {

                    if ( !defined $oid_h->{color}{$leaf}
                        or $colors{ $dep_oid_h->{color} } > $colors{ $oid_h->{color}{$leaf} } )
                    {
                        $oid_h->{val}{$leaf}   = $dep_oid_h->{val};
                        $oid_h->{color}{$leaf} = $dep_oid_h->{color};
                        $oid_h->{msg}{$leaf}   = $dep_oid_h->{msg};
                        $oid_h->{error}{$leaf} = $dep_oid_h->{error};
                        $oid_h->{time}{$leaf}  = time;
                    } elsif ( $dep_oid_h->{color} eq $oid_h->{color}{$leaf} ) {
                        $oid_h->{val}{$leaf} .= "|" . $dep_oid_h->{val};
                        if ( defined $dep_oid_h->{msg} ) {
                            if ( defined $oid_h->{msg}{$leaf} and $oid_h->{msg}{$leaf} ne '' ) {
                                $oid_h->{msg}{$leaf} .= " & " . $dep_oid_h->{msg};
                            } else {
                                $oid_h->{msg}{$leaf} = $dep_oid_h->{msg};
                            }
                        }
                        $oid_h->{error}{$leaf} = $dep_oid_h->{error} || $oid_h->{error}{$leaf};
                        $oid_h->{time}{$leaf}  = time;
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
                $oid_h->{error} = $dep_oid_h->{error};
                $oid_h->{time}  = time;
            } elsif ( $dep_oid_h->{color} eq $oid_h->{color} ) {
                $oid_h->{val} .= "|" . $dep_oid_h->{val};
                if ( defined $dep_oid_h->{msg} ) {
                    if ( defined $oid_h->{msg} and $oid_h->{msg} ne '' ) {
                        $oid_h->{msg} .= " & " . $dep_oid_h->{msg};
                    } else {
                        $oid_h->{msg} = $dep_oid_h->{msg};
                    }
                }
                $oid_h->{error} = $dep_oid_h->{error} || $oid_h->{error};
                $oid_h->{time}  = time;
            }
        }
    }

    # Now apply our threshold to this data
    apply_thresh( $oids, $thr, $oid );
}

# Return an (x days,)? hh:mm:ss date timestamp ##############################
sub trans_elapsed {
    my ( $device, $oids, $oid, $thr ) = @_;
    my $oid_h = \%{ $oids->{$oid} };

    # Extract our transform options
    my $dep_oid   = $1 if $oid_h->{trans_data} =~ /^\{(.+)\}$/;
    my $dep_oid_h = \%{ $oids->{$dep_oid} };

    # Validate our dependencies
    validate_deps( $device, $oids, $oid, [$dep_oid], '^[+-]?\d+(\.\d+)?$' )
        or return;

    # See if we are a repeating variable type datum
    # (such as that generated by snmpwalking a table)
    if ( $oid_h->{repeat} ) {

        for my $leaf ( keys %{ $dep_oid_h->{val} } ) {

            # Skip if there was a dependency error for this leaf
            next if $oid_h->{error}{$leaf};

            my $s = $dep_oid_h->{val}{$leaf};
            my $d = int( $s / 86400 );
            $s %= 86400;
            my $h = int( $s / 3600 );
            $s %= 3600;
            my $m = int( $s / 60 );
            $s %= 60;

            my $elapsed = sprintf "%s%-2.2d:%-2.2d:%-2.2d", ( $d ? ( $d == 1 ? '1 day, ' : "$d days, " ) : '' ), $h, $m, $s;

            $oid_h->{val}{$leaf}   = $elapsed;
            $oid_h->{time}{$leaf}  = time;
            $oid_h->{color}{$leaf} = $dep_oid_h->{color}{$leaf};
            $oid_h->{msg}{$leaf}   = $dep_oid_h->{msg}{$leaf};

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

        $oid_h->{val}   = $elapsed;
        $oid_h->{time}  = time;
        $oid_h->{color} = $dep_oid_h->{color};
        $oid_h->{msg}   = $dep_oid_h->{msg};
    }
}

# Return an yy-mm, hh:mm:ss date timestamp ###############################
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
            next if $oid_h->{error}{$leaf};

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

    # Do not use the function validate_deps. As there are no parent OIDs, only
    # constant values, it will have nothing to check and it will generate a
    # leaf-type OID.
    $oid_h->{repeat} = 1;     # Make a repeater-type OID
    $oid_h->{val}    = {};    # Empty set of leafes
    $oid_h->{time}   = {};

    @Fields = split( /\s*,\s*/, $oid_h->{trans_data} );
    for ( $leaf = 1; $leaf <= @Fields; $leaf++ ) {
        $oid_h->{val}{$leaf}  = $Fields[ $leaf - 1 ];
        $oid_h->{time}{$leaf} = time;
    }                         # of for

    apply_thresh_rep( $oids, $thr, $oid );
}    # of trans_set

# Convert value to its appropriate bps-speed ################################
sub trans_speed {
    my ( $device, $oids, $oid, $thr ) = @_;
    my $oid_h = \%{ $oids->{$oid} };

    # Extract our single dependant oid
    my $dep_oid   = $1 if $oid_h->{trans_data} =~ /^\{(.+)\}$/;
    my $dep_oid_h = \%{ $oids->{$dep_oid} };

    # Validate our dependencies
    validate_deps( $device, $oids, $oid, [$dep_oid], '^\d+(\.\d+)?$' )
        or return;

    # Handle repeater-type oids
    if ( $oid_h->{repeat} ) {

        for my $leaf ( keys %{ $dep_oid_h->{val} } ) {

            # Skip if there was a dependency error for this leaf
            next if $oid_h->{error}{$leaf};

            my $bps = int $dep_oid_h->{val}{$leaf};

            # Get largest speed type
            my $speed = 1;    # Start low: 1 bps
            $speed *= 1000 while $bps >= ( $speed * 1000 );
            my $unit = $speeds{$speed};

            # Measure to 2 decimal places
            my $new_speed = sprintf '%.2f %s', $bps / $speed, $unit;

            $oid_h->{val}{$leaf}   = $new_speed;
            $oid_h->{time}{$leaf}  = time;
            $oid_h->{color}{$leaf} = $dep_oid_h->{color}{$leaf};
            $oid_h->{msg}{$leaf}   = $dep_oid_h->{msg}{$leaf};
        }

        # Otherwise we are a single entry datum
    } else {

        my $bps = $dep_oid_h->{val};

        # Get largest speed type
        my $speed = 1;    # Start low: 1 bps
        $speed *= 1000 while $bps >= ( $speed * 1000 );
        my $unit = $speeds{$speed};

        # Measure to 2 decimal places
        my $new_speed = sprintf '%.2f %s', $bps / $speed, $unit;
        $oid_h->{val}   = $new_speed;
        $oid_h->{time}  = time;
        $oid_h->{color} = $dep_oid_h->{color};
        $oid_h->{msg}   = $dep_oid_h->{msg};
    }
}

# C-style 'case', with ranges ##############################################
sub trans_switch {
    my ( $device, $oids, $oid, $thr ) = @_;
    my $oid_h = \%{ $oids->{$oid} };

    my $trans_data = \%{ $oid_h->{trans_edata} };

    #my $trans_odata = \%{$oid_h->{trans_data}};
    my $dep_oid   = $trans_data->{dep_oid};
    my $dep_oid_h = \%{ $oids->{$dep_oid} };
    my $cases     = \%{ $trans_data->{cases} };
    my $case_nums = \@{ $trans_data->{case_nums} };
    my $default   = $trans_data->{default};

    # Validate our dependencies
    # We cannot validate globally all depencies, but we can validate the first
    # one as this one is global, for the rest we should do it later
    # can be switch dependecies we have to do it for each leaf individually
    validate_deps( $device, $oids, $oid, [$dep_oid] ) or return;

    # Defined the repeater type
    #$oid_h->{repeat} = $dep_oid_h->{repeat};

    if ( $oid_h->{repeat} ) {
        for my $leaf ( keys %{ $dep_oid_h->{val} } ) {

            # Skip if there was a dependency error for this leaf
            next if $oid_h->{error}{$leaf};

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
            if ( defined $num ) {
                $then = $cases->{$num}{then};
            } else {
                $then = $default;
            }
            while ( $then =~ /\{(\S+)\}/ ) {
                my $then_oid = $1;
                my $then_oid_val;
                if ( $oids->{$then_oid}{repeat} ) {
                    if ( defined $oids->{$then_oid}{error}{$leaf} or $oids->{$then_oid}{error}{$leaf} ) {
                        next;
                    }
                    $then_oid_val = $oids->{$then_oid}{val}{$leaf};
                    if ( !defined $oid_h->{color}{$leaf} ) {
                        $oid_h->{color}{$leaf} = $oids->{$then_oid}{color}{$leaf};
                        $oid_h->{msg}{$leaf}   = $oids->{$then_oid}{msg}{$leaf};
                    }
                } else {
                    $then_oid_val = $oids->{$then_oid}{val};
                }
                if ( !defined $then_oid_val ) {
                    do_log( "Missing repeater data for trans_switch on $oid on $device", 1 );
                    $then_oid_val = 'Undefined';
                    if ( !defined $oid_h->{color}{$leaf} ) {
                        $oid_h->{color}{$leaf} = $oids->{$then_oid}{color};
                        $oid_h->{msg}{$leaf}   = $oids->{$then_oid}{msg};
                    }
                }
                $then =~ s/\{$then_oid\}/$then_oid_val/g;
            }

            $oid_h->{val}{$leaf}  = $then;
            $oid_h->{time}{$leaf} = time;

        }

        apply_thresh_rep( $oids, $thr, $oid );

        # Otherwise we are a single entry datum
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
        if ( defined $num ) {
            $then = $cases->{$num}{then};
        } else {
            $then = $default;
        }

        while ( $then =~ /\{(\S+)\}/ ) {
            my $then_oid = $1;
            my $then_oid_val;
            if ( $oids->{$then_oid}{repeat} ) {
                do_log( "Cant switch to a repeater OID when using a non-repeater" . "source OID for trans_switch on $oid", 0 );
                $then_oid_val = 'Undefined';
            } else {
                $then_oid_val = $oids->{$then_oid}{val};
                if ( !defined $oid_h->{color} ) {
                    $oid_h->{color} = $oids->{$then_oid}{color};
                    $oid_h->{msg}   = $oids->{$then_oid}{msg};
                    $oid_h->{error} = $oids->{$then_oid}{error};
                }
            }
            if ( !defined $then_oid_val ) {
                do_log( "Missing repeater data for trans_switch on $oid on $device", 0 );
                $then_oid_val = 'Undefined';
            }
            $then =~ s/\{$then_oid\}/$then_oid_val/g;
        }

        $oid_h->{val}  = $then;
        $oid_h->{time} = time;

        apply_thresh( $oids, $thr, $oid );
    }
}

# C-style 'case', with ranges & threshold inheritance ######################
sub trans_tswitch {
    my ( $device, $oids, $oid, $thr ) = @_;
    my $oid_h      = \%{ $oids->{$oid} };
    my $trans_data = \%{ $oid_h->{trans_edata} };
    my $dep_oid    = $trans_data->{dep_oid};
    ( $dep_oid, my $dep_oid_sub ) = split /\./, $dep_oid;    # prepare sub oid
    my $dep_oid_h = \%{ $oids->{$dep_oid} };

    # treat sub oid (color|msg|error|repeat|time|val) :  the sub oid replace val )
    my $dep_oid_h_val;
    if ( defined($dep_oid_sub) ) {
        $dep_oid_h_val = $dep_oid_h->{$dep_oid_sub};
    } else {

        # if no sub oid (most cases), we use the  oid value aka val
        $dep_oid_h_val = $dep_oid_h->{val};
    }

    my $cases     = \%{ $trans_data->{cases} };
    my $case_nums = \@{ $trans_data->{case_nums} };
    my $default   = $trans_data->{default};

    # See if we are a repeating variable type datum
    # (such as that generated by snmpwalking a table)

    # Validate our dependencies
    validate_deps( $device, $oids, $oid, [$dep_oid] ) or return;

    if ( $oid_h->{repeat} ) {

        for my $leaf ( keys %{ $dep_oid_h->{val} } ) {

            # Skip if there was a dependency error for this leaf
            next if $oid_h->{error}{$leaf};

            #my $val = $dep_oid_h->{val}{$leaf};
            my $val = $dep_oid_h_val->{$leaf};    # sub oid modif

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
            if ( defined $num ) {
                $then = $cases->{$num}{then};
            } else {
                $then = $default;
            }
            while ( $then =~ /\{(\S+)\}/ ) {
                my $then_oid = $1;
                my $then_oid_val;
                if ( $oid_h->{repeat} ) {
                    $then_oid_val = $oids->{$then_oid}{val}{$leaf};
                    if ( !defined $oid_h->{color}{$leaf} ) {
                        $oid_h->{color}{$leaf} = $oids->{$then_oid}{color}{$leaf};
                        $oid_h->{msg}{$leaf}   = $oids->{$then_oid}{msg}{$leaf};
                    }
                } else {
                    $then_oid_val = $oid_h->{val};
                }
                if ( !defined $then_oid_val ) {
                    do_log( "Missing repeater data for trans_tswitch on $oid on $device", 0 );
                    $then_oid_val = 'Undefined';
                    if ( !defined $oid_h->{color}{$leaf} ) {
                        $oid_h->{color}{$leaf} = $oids->{$then_oid}{color};
                        $oid_h->{msg}{$leaf}   = $oids->{$then_oid}{msg};
                    }
                }
                $then =~ s/\{$then_oid\}/$then_oid_val/g;
            }

            $oid_h->{val}{$leaf}  = $then;
            $oid_h->{time}{$leaf} = time;

        }

        apply_thresh_rep( $oids, $thr, $oid );

        # Otherwise we are a single entry datum
    } else {

        #my $val = $dep_oid_h->{val};
        my $val = $dep_oid_h_val;
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
        if ( defined $num ) {
            $then = $cases->{$num}{then};
        } else {
            $then = $default;
        }
        while ( $then =~ /\{(\S+)\}/ ) {
            my $then_oid = $1;
            my $then_oid_val;
            if ( $oids->{$then_oid}{repeat} ) {
                do_log( "Cant switch to a repeater OID when using a non-repeater" . "source OID for trans_tswitch on $oid", 0 );
                $then_oid_val = 'Undefined';
            } else {
                $then_oid_val = $oids->{$then_oid}{val};
                if ( !defined $oid_h->{color} ) {
                    $oid_h->{color} = $oids->{$then_oid}{color};
                    $oid_h->{msg}   = $oids->{$then_oid}{msg};
                }
            }

            if ( !defined $then_oid_val ) {
                do_log( "Missing repeater data for trans_tswitch on $oid on $device", 0 );
                $then_oid_val = 'Undefined';
            }
            $then =~ s/\{$then_oid\}/$then_oid_val/g;
        }

        $oid_h->{val}  = $then;
        $oid_h->{time} = time;

        apply_thresh( $oids, $thr, $oid );
    }
}

# Regular expression substitutions #########################################
sub trans_regsub {
    my ( $device, $oids, $oid, $thr ) = @_;
    my $oid_h      = \%{ $oids->{$oid} };
    my $trans_data = $oid_h->{trans_data};
    my ( $main_oid, $expr ) = ( $1, $2 )
        if $trans_data =~ /^\{(.+)\}\s*(\/.+\/.*\/[eg]*)$/;

    # Extract all our our parent oids from the expression, first
    #    my @dep_oids = $trans_data =~ /\{(.+?)\}/g;
    my @dep_oids = $expr =~ /\{(.+?)\}/g;
    unshift @dep_oids, ($main_oid);

    # Validate our dependencies
    if ( not validate_deps( $device, $oids, $oid, \@dep_oids ) ) {
        do_log( "DEBUG TEST: Regsub transform on $device/$oid do not have valid dependencies: skipping", 4 ) if $g{debug};
        return;
    }

    # drop our main oid
    #    shift @dep_oids;

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
            next if $oid_h->{error}{$leaf};

            # Update our dep_val values so that when we eval the expression it
            # will use the values of the proper leaf of the parent repeater oids
            my @dep_val;
            for (@repeaters) { push @dep_val, $oids->{$_}{val}{$leaf} }

            my $exp_val = $oids->{$main_oid}{val}{$leaf};
            my $result;
            $result = eval "\$exp_val =~ s$expr";
            if ($@) {
                do_log( "Failed eval for REGSUB transform on leaf $leaf of " . "$oid on $device ($@)", 0 );
                $oid_h->{val}{$leaf}   = 'Failed eval';
                $oid_h->{time}{$leaf}  = time;
                $oid_h->{color}{$leaf} = 'yellow';
                $oid_h->{error}{$leaf} = 1;
                next;
            }
            $oid_h->{val}{$leaf}  = $exp_val;
            $oid_h->{time}{$leaf} = time;
        }

        # Now apply our threshold to this data
        apply_thresh_rep( $oids, $thr, $oid );

        # Otherwise we are a single entry datum
    } else {

        # All of our non-reps were substituted earlier, so we can just eval
        my $exp_val = $oids->{$main_oid}{val};
        my $result  = eval "\$exp_val =~ s$expr";

        if ($@) {
            do_log( "Failed eval for REGSUB transform on $oid on $device ($@)", 0 );
            $oid_h->{val}   = 'Failed eval';
            $oid_h->{time}  = time;
            $oid_h->{color} = 'yellow';
            $oid_h->{error} = 1;
            return;
        }
        $oid_h->{val}  = $exp_val;
        $oid_h->{time} = time;

        # Now apply our threshold to this data
        apply_thresh( $oids, $thr, $oid );
    }
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

    # Validate our dependencies, have to do them seperately
    validate_deps( $device, $oids, $oid, [$src_oid], '^\.?(\d+\.)*\d+$' )
        or return;

    validate_deps( $device, $oids, $oid, [$trg_oid] )
        or return;

    my $src_h = \%{ $oids->{$src_oid} };
    my $trg_h = \%{ $oids->{$trg_oid} };

    # Our target MUST be a repeater type oid
    if ( !$trg_h->{repeat} ) {
        do_log( "Trying to chain a non-repeater target on $device ($@)", 0 );
        $oid_h->{repeat} = 0;
        $oid_h->{val}    = 'Failed chain';
        $oid_h->{time}   = time;
        $oid_h->{color}  = 'yellow';
        $oid_h->{error}  = 1;
    }

    # If our target is a repeater, and our source is a non-repeater,
    # then our transform oid will consequently be a non-repeater
    if ( !$src_h->{repeat} ) {
        $oid_h->{repeat} = 0;
        my $sub_oid = $src_h->{val};
        my $trg_val = $trg_h->{val}{$sub_oid};
        if ( !defined $trg_val ) {
            $oid_h->{val}   = 'n/a';
            $oid_h->{val}   = $trg_oid . ' ' . $oid_h->{val} if $g{debug};
            $oid_h->{time}  = time;
            $oid_h->{color} = 'yellow';

            #$oid_h->{error}  = 1;
            return;
        }

        $oid_h->{val}   = $trg_val;
        $oid_h->{time}  = $trg_h->{time}{$sub_oid};
        $oid_h->{color} = $trg_h->{color}{$sub_oid};
        $oid_h->{error} = $trg_h->{error}{$sub_oid};

        # Apply threshold
        apply_thresh( $oids, $thr, $oid );

        return;

        # Both source and target are repeaters.  Go go go!
    } else {
        for my $leaf ( keys %{ $src_h->{val} } ) {

            # Skip if our source oid is freaky-deaky
            next if $oid_h->{error}{$leaf};

            # Our oid sub leaf
            my $sub_oid = $src_h->{val}{$leaf};

            my $trg_val = $trg_h->{val}{$sub_oid};
            if ( !defined $trg_val ) {
                $oid_h->{val}{$leaf}   = "n/a";
                $oid_h->{val}{$leaf}   = $trg_oid . ' ' . $oid_h->{val}{$leaf} if $g{debug};
                $oid_h->{time}{$leaf}  = time;
                $oid_h->{color}{$leaf} = 'yellow';

                #$oid_h->{error}{$leaf}  = 1;
                next;
            }

            $oid_h->{val}{$leaf}   = $trg_val;
            $oid_h->{time}{$leaf}  = $trg_h->{time}{$sub_oid};
            $oid_h->{color}{$leaf} = $trg_h->{color}{$sub_oid};
            $oid_h->{error}{$leaf} = $trg_h->{error}{$sub_oid};
        }

        # Apply thresholds
        apply_thresh_rep( $oids, $thr, $oid );
        $oid_h->{repeat} = 1;
    }
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
        do_log( "Trying to COLTRE a non-repeater 1rst oid on $device ($@)", 0 );
        $oid_h->{repeat} = 0;
        $oid_h->{val}    = 'Failed coltre';
        $oid_h->{time}   = time;
        $oid_h->{color}  = 'yellow';
        $oid_h->{error}  = 1;

        # Our target MUST be a repeater type oid
    } elsif ( !$trg_h->{repeat} ) {
        do_log( "Trying to COLTRE a non-repeater 2nd oid on $device ($@)", 0 );
        $oid_h->{repeat} = 0;
        $oid_h->{val}    = 'Failed coltre';
        $oid_h->{time}   = time;
        $oid_h->{color}  = 'yellow';
        $oid_h->{error}  = 1;

        # Both source and target are repeaters.  Go go go!
    } else {
        my $isfirst = 1;
        for my $leaf ( sort { $src_h->{val}{$a} <=> $src_h->{val}{$b} } keys %{ $src_h->{val} } ) {

            # Skip if our source oid is freaky-deaky
            next if $oid_h->{error}{$leaf};

            #TODO CHECK $oid_h->{val}{$src_h->{val}{$leaf}} if it exist
            if ($isfirst) {
                $oid_h->{val}{$leaf} = $trg_h->{val}{$leaf};
                $isfirst = 0;
            } else {
                $oid_h->{val}{$leaf} = $oid_h->{val}{ $src_h->{val}{$leaf} } . $separator . $trg_h->{val}{$leaf};
            }
            $oid_h->{time}{$leaf}  = time;
            $oid_h->{color}{$leaf} = $trg_h->{color}{$leaf};
            $oid_h->{error}{$leaf} = $trg_h->{error}{$leaf};
        }

        # Apply thresholds
        apply_thresh_rep( $oids, $thr, $oid );
        $oid_h->{repeat} = 1;
    }
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
    validate_deps( $device, $oids, $oid, [$src_oid] )
        or return;

    do_log( "DEBUG TEST: Transforming $src_oid to $oid via 'sort' transform", 5 ) if $g{debug};

    # This transform should probably only work for repeater sources
    my $src_h = \%{ $oids->{$src_oid} };
    if ( !$src_h->{repeat} ) {
        do_log( "Trying to SORT a non-repeater source on $device ($@)", 0 );
        return;
    } else {

        # Tag the target as a repeater
        $oid_h->{repeat} = 2;
        if ( $sort eq 'txt' ) {
            my $pad = 1;
            for my $leaf ( sort { $src_h->{val}{$a} cmp $src_h->{val}{$b} } keys %{ $src_h->{val} } ) {

                # Skip if our source oid is freaky-deaky
                next if $oid_h->{error}{$leaf};

                # Our oid sub leaf
                # my $oid_idx = $src_h->{val}{$leaf};

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
        } elsif ( $sort eq 'num' ) {
            my $pad = 1;
            for my $leaf ( sort { $src_h->{val}{$a} <=> $src_h->{val}{$b} } keys %{ $src_h->{val} } ) {

                # Skip if our source oid is freaky-deaky
                next if $oid_h->{error}{$leaf};

                # Our oid sub leaf
                # my $oid_idx = $src_h->{val}{$leaf};

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
                next if $oid_h->{error}{$leaf};

                # Our oid sub leaf
                # my $oid_idx = $src_h->{val}{$leaf};

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

        # Apply thresholds
        apply_thresh_rep( $oids, $thr, $oid );
    }
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

    my $oid_h = \%{ $oids->{$oid} };

    # Extract our parent oids from the expression, first
    my ($src_oid) = $oid_h->{trans_data} =~ /^\{(.+)\}$/;

    # Validate our dependencies
    if ( not validate_deps( $device, $oids, $oid, [$src_oid] ) ) {
        do_log( "DEBUG TEST: Index transform on $device/$oid do not have valid dependencies: skipping", 4 ) if $g{debug};
        return;
    }

    #do_log("DEBUG TEST: Transforming $src_oid to $oid via index transform",0) if $g{debug};

    my $src_h = \%{ $oids->{$src_oid} };

    # This transform should probably only work for repeater sources
    if ( !$src_h->{repeat} ) {
        do_log( "Trying to index a non-repeater source on $device ($@)", 0 );
        return;
    } else {

        # Tag the target as a repeater
        $oid_h->{repeat} = 2;
        for my $leaf ( keys %{ $src_h->{val} } ) {

            # Skip if our source oid is freaky-deaky
            next if $oid_h->{error}{$leaf};

            # Our oid sub leaf
            # my $oid_idx = $src_h->{val}{$leaf};

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

        # Apply thresholds
        apply_thresh_rep( $oids, $thr, $oid );
    }
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

    # Validate our dependencies
    validate_deps( $device, $oids, $oid, [$src_oid], '.*' )
        or return;

    do_log( "DEBUG TEST: Transforming $src_oid to $oid via match transform matching $expr", 4 ) if $g{debug};

    my $src_h = \%{ $oids->{$src_oid} };

    # This transform should probably only work for repeater sources
    if ( !$src_h->{repeat} ) {
        do_log( "Trying to index a non-repeater source on $device ($@)", 0 );
        return;
    } else {

        # Tag the target as a repeater
        $oid_h->{repeat} = 2;
        my $idx = 0;

        #for my $leaf ( sort { $a <=> $b } keys %{ $src_h->{val} } ) {
        my @sorted_leafs = oid_sort( keys %{ $src_h->{val} } );
        for my $leaf (@sorted_leafs) {

            # Skip if our source oid is freaky-deaky
            next if $oid_h->{error}{$leaf};

            my $res;
            my $val = $src_h->{val}{$leaf};

            #do_log("Testing value $val from against $expr",0) if $g{debug};
            my $result = eval "\$res = \$val =~ m$expr";
            if ($@) {
                do_log( "Failed eval for MATCH transform on leaf $leaf of " . "$oid on $device ($@)", 0 );
                $oid_h->{val}{$leaf}   = 'Failed eval';
                $oid_h->{time}{$leaf}  = time;
                $oid_h->{color}{$leaf} = 'yellow';
                $oid_h->{error}{$leaf} = 1;
                next;
            }
            do_log( "DEBUG TEST: $val matched $expr, assigning new row $idx from old row $leaf", 0 )
                if $g{debug} and $res;
            next unless $res;

            # Our oid sub leaf
            # my $oid_idx = $src_h->{val}{$leaf};

            if ( !defined $leaf ) {
                $oid_h->{val}{$idx}   = 'SHOULD NEVER ARRIVE: CAN BE REMOVED';
                $oid_h->{time}{$idx}  = time;
                $oid_h->{color}{$idx} = 'yellow';
                $oid_h->{error}{$idx} = 1;
                next;
            }

            $oid_h->{val}{$idx}   = $leaf;
            $oid_h->{time}{$idx}  = $src_h->{time}{$leaf};
            $oid_h->{color}{$idx} = $src_h->{color}{$leaf};
            $oid_h->{error}{$idx} = $src_h->{error}{$leaf};
            $idx++;
        }

        # Apply thresholds
        apply_thresh_rep( $oids, $thr, $oid );
    }
}

# Create our outbound message ##############################################
sub render_msg {
    my ( $device, $tmpl, $test, $oids ) = @_;

    # Hash shortcut
    my $msg_template = $tmpl->{msg};
    my $dev          = \%{ $g{dev_data}{$device} };
    my $hostname     = $device;
    $hostname =~ s/\./,/g;

    do_log( "DEBUG TEST: Rendering $test message for $device", 4 ) if $g{debug};

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
    my $msg         = '';
    my $pri_val     = '';
    my $errors      = '';
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

        # my $dep_tt_oids  = \%{$oids->{$alarm_oid}->{ttrans}};

        foreach my $dep_tt_oid ( @{ $tmpl->{oids}->{$alarm_oid}{sorted_oids_thresh_infls} } ) {
            if ( exists $alarm_oids{$dep_tt_oid} ) {

                # Mark this oid has not having to participate in the
                # worst color computation
                do_log( "DEBUG TEST: $alarm_oid of $test on $device do not compute worst color ", 5 ) if $g{debug};

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
                do_log( "No primary OID found for $test test for $device", 0 );
                $msg .= "&yellow No primary OID found.\n";
                $worst_color = 'yellow';
                next;
            }

            # Remove any flags the primary oid might have on it...
            $pri =~ s/\..*//;

            # Make sure we have leaf data for our primary oid
            if ( !defined $oids->{$pri}{val} ) {
                do_log( "DEBUG TEST: Missing repeater data for $pri for $test msg on $device", 4 );
                $msg .= "&clear Missing repeater data for primary OID $pri\n";
                $worst_color = 'clear';
                next;
            }

            # Make sure our primary OID is a repeater
            if ( !$oids->{$pri}{repeat} ) {
                do_log( "ERROR TEST: Primary OID $pri in $test table is a non-repeater", 1 );
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
                if ( defined $t_opts{sort}[0] ) {
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
        T_LEAF: for my $leaf (@table_leaves) {

                my $row_data = $line;
                my $alarm_int;

                # Do some alarm logic
                my $pri_val = $oids->{$pri}{val}{$leaf};
                my $alarm   = 1;                           # Alarm by default
                my $a_val
                    = $dev->{except}{$test}{$pri}{alarm}
                    || $dev->{except}{all}{$pri}{alarm}
                    || $tmpl->{oids}{$pri}{except}{alarm};
                $alarm = ( $pri_val =~ /^(?:$a_val)$/ ) ? 1 : 0 if defined $a_val;

                my $na_val
                    = $dev->{except}{$test}{$pri}{noalarm}
                    || $dev->{except}{all}{$pri}{noalarm}
                    || $tmpl->{oids}{$pri}{except}{noalarm};
                $alarm = 0 if defined $na_val and $pri_val =~ /^(?:$na_val)$/;

                # Now go through all the oids in our table row and replace them
                for my $root ( $row_data =~ /\{(.+?)\}/g ) {

                    # Chop off any flags and store them for later
                    my $oid   = $root;
                    my $flag  = $1 if $oid =~ s/\.(.+)$//;
                    my $oid_h = \%{ $oids->{$oid} };

                    # Get our oid vars
                    my $val   = $oid_h->{repeat} ? $oid_h->{val}{$leaf}   : $oid_h->{val};
                    my $color = $oid_h->{repeat} ? $oid_h->{color}{$leaf} : $oid_h->{color};
                    if ( !defined $val ) {
                        do_log( "WARNI TEST: Undefined value for $oid in test $test on $device, ignoring row for $pri_val", 4 ) if $g{debug};
                        next T_LEAF;
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
                    if ( $oid eq $pri ) {

                        # Add our primary key to our rrd set, if needed
                        for my $name ( keys %rrd ) {
                            $rrd{$name}{pri} = $oid if $rrd{$name}{pri} eq 'pri';

                            # This condition looks incorrect. We should not remove rrds if alerting
                            # is disabled for this leaf. If the user doesn't want a graph, they probably
                            # don't want this leaf in the table, they should set 'ignore' instead of 'noalarm'
                            #if ($rrd{$name}{all} or $alarm) {
                            # add to list, but check we're not pushing multiple times
                            push @{ $rrd{$name}{leaves} }, $leaf unless grep { $_ eq $leaf } @{ $rrd{$name}{leaves} };

                            #}
                        }

                        # If this is our primary oid, and we are have an alarm
                        # variable defined, save it so we can add it later
                        $alarm_int = $val;
                        #
                        #
                    }

                    # See if we have a valid flag, if so, replace the
                    # place holder with flag data, if not, just replace
                    # it with the oid value.  Also modify the global color
                    # Display a Xymon color string (i.e. "&red ")
                    if ( defined $flag ) {

                        #my $oid_msg = $oid_h->{msg}{$leaf};
                        #$oid_msg = 'Undefined' if !defined $oid_msg;
                        #$oid_msg = parse_deps($oids, $oid_msg, $leaf);
                        my $oid_msg = parse_deps( $oids, $oid_h->{msg}{$leaf}, $leaf );

                        if ( $flag eq 'color' ) {

                            # Honor the 'alarm' exceptions
                            $row_data =~ s/\{$root\}/&$color /;

                            # If this test has a worse color, use it for the global color
                            # but verify first that this test should compute the worst color
                            if ( !$no_global_wcolor{$oid} and $oid_msg ne '' ) {
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
                                do_log( "RENDER WARNING: $oid of $test on $device is overwritten by Worst/Best Transform: remove " . '{' . "$oid.errors" . '}' . " in 'message' template", 0 );

                                # Get oid msg and replace any inline oid dependencies
                            } else {

                                #my $oid_msg = $oid_h->{msg}{$leaf};
                                #$oid_msg = 'Undefined' if !defined $oid_msg;
                                $oid_msg = parse_deps( $oids, $oid_msg, $leaf );

                                # If the message is an empty string it means that we dont want to raise an error
                                if ( $oid_msg ne '' ) {

                                    $worst_color = $color
                                        if !defined $worst_color
                                        or $colors{$worst_color} < $colors{$color};

                                    # Now add it to our msg
                                    $errors .= "&$color $oid_msg\n";
                                }
                            }

                            # Display color threshold value
                        } elsif ( $flag =~ /^thresh$/i ) {
                            my $thresh = $oid_h->{thresh}{$leaf};

                            $thresh = 'Undefined' if !defined $thresh;
                            $row_data =~ s/\{$root\}/$thresh/;

                            # Display color threshold template value
                        } elsif ( $flag =~ /^thresh\:(\w+)$/i or $flag =~ /^threshold\.(\w+)$/i ) {
                            my $threshold_color = lc $1;

                            #do_log ("RENDER WARNING: {thresh:color} is DEPRECATED, please use {threshold.color} syntax") if $flag =~ /^thresh\:(\w+)$/i;
                            my $threshold = '';
                            for my $limit ( keys %{ $oid_h->{threshold}->{$threshold_color} } ) {
                                if ( $threshold eq '' ) {
                                    $threshold = $limit;
                                } else {
                                    $threshold .= ' or ' . $limit;
                                }
                            }

                            $threshold = 'Undefined' if !defined $threshold;
                            $row_data =~ s/\{$root\}/$threshold/;

                            # Unknown flag
                        } else {
                            do_msg("Unknown flag ($flag) for $oid on $device\n");
                        }

                        # Otherwise just display the oid val
                    } else {
                        my $substr = $oids->{$root}{repeat} ? $oids->{$root}{val}{$leaf} : $oids->{$root}{val};
                        $substr = 'Undefined' if !defined $substr;
                        $row_data =~ s/\{$root\}/$substr/;
                    }

                }

                # add the primary repeater to our alarm header if we are
                # alarming on it; Wrap our header at 60 chars
                if ( !defined $t_opts{noalarmsmsg} and $alarm ) {
                    $alarm_ints =~ s/(.{60,}),$/$1)\nAlarming on (/;
                    $alarm_ints .= "$alarm_int,";
                }

                # Finished with this row (signified by the primary leaf id)
                if ( defined $t_opts{nonhtml} || defined $t_opts{plain} ) {
                    $table .= "$row_data\n";
                } else {
                    $table .= "<tr><td>$row_data</td></tr>\n";
                }

            }

            $table .= "</table>\n" if ( !defined $t_opts{nonhtml} && !defined $t_opts{plain} );

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

                do_log("WARNI TESTS: Couldn't fetch primary oid for rrd set $name")
                    and next
                    if $pri eq 'pri';

                my $header = "<!--DEVMON RRD: $name $dir $do_max\n" . $rrd{$name}{header};

                for my $leaf ( @{ $rrd{$name}{leaves} } ) {
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

                        do_log( "WARNI TEST: Text values in data for rrd repeater, dropping rrd for $pri_val", 4 )
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
                $val   = 'Undefined' if !defined $val;
                $color = 'clear'     if !defined $color;

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
                        if ( !$no_global_wcolor{$oid} and $oid_msg ne '' ) {
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
                            do_log( "RENDER WARNING: $oid of $test on $device is overwritten by Worst/Best Transform: remove " . '{' . "$oid.errors" . '}' . " in 'message' template", 0 );

                            # Get oid msg and replace any inline oid dependencies
                        } else {

                            #my $oid_msg = $oid_h->{msg};
                            #$oid_msg = 'Undefined' if !defined $oid_msg;
                            #$oid_msg = parse_deps($oids, $oid_msg, undef);

                            # If the message is an empty string it means that we dont want to raise an error
                            if ( $oid_msg ne '' ) {

                                $worst_color = $color
                                    if !defined $worst_color
                                    or $colors{$worst_color} < $colors{$color};

                                # Now add it to our msg
                                $errors .= "&$color $oid_msg\n";
                            }
                        }

                        # Display color threshold value
                    } elsif ( $flag =~ /^thresh$/i ) {
                        my $thresh = $oid_h->{thresh};
                        $thresh = 'Undefined' if !defined $thresh;
                        $line =~ s/\{$root\}/$thresh/;

                        # Display color threshold template value
                    } elsif ( $flag =~ /^thresh:($color_list)$/i or $flag =~ /^threshold\.(\w+)$/i ) {
                        my $threshold_color = lc $1;

                        #do_log ("RENDER WARNING: {thresh:color} is DEPRECATED, please use {threshold.color} syntax") if $flag =~ /^thresh\:(\w+)$/i;
                        my $threshold = '';
                        for my $limit ( keys %{ $oid_h->{threshold}->{$threshold_color} } ) {
                            if ( $threshold eq '' ) {
                                $threshold = $limit;
                            } else {
                                $threshold .= ' or ' . $limit;
                            }
                        }
                        $threshold = 'Undefined' if !defined $threshold;
                        $line =~ s/\{$root\}/$threshold/;

                        # Unknown flag
                    } else {
                        do_log("Unknown flag ($flag) for $oid on $device\n");
                    }

                } else {
                    my $val = $oid_h->{val};
                    $val = "Unknown" if !defined $val;

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

    #my $rrdmsg  = $1 if $msg =~ s/(<!--DEVMON.*-->)//s;
    if ( $msg =~ s/(<!--DEVMON.*-->)//s ) {
        $msg .= $1;
    }

    # Add our errors
    $msg = join "\n", ( $errors, $msg ) if $errors ne '';

    # Now add our header so xymon can determine the page color
    $msg = "status $hostname.$test $worst_color $now" . "$extrastatus\n\n$msg";

    # Add our oh-so-stylish devmon footer
    $msg .= "\n\n<a href='https://github.com/bonomani/devmon'>Devmon $g{version}</a> " . "running on $g{nodename}\n";

    # Now add a bit of logic to allow a 'cleartime' window, where a test on
    # a device can be clear for an interval without being reported as such
    if ( $worst_color eq 'clear' ) {
        $g{numclears}{$device}{$test} = time
            if !defined $g{numclears}{$device}{$test};
    } else {

        # Clear our clear counter if this message wasnt clear
        delete $g{numclears}{$device}{$test}
            if defined $g{numclears}{$device}
            and defined $g{numclears}{$device}{$test};
    }

    # Now return null if we are in our 'cleartime' window
    if (    defined $g{numclears}{$device}
        and defined $g{numclears}{$device}{$test} )
    {
        my $start_clear = $g{numclears}{$device}{$test};
        if ( time - $start_clear < $g{cleartime} ) {
            do_log( "DEBUG TEST: $device had some clear errors " . "during test $test", 4 ) if $g{debug};
            return;
        }
    }

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
    return "Undefined" if !defined $msg;

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
                do_log( "Missing msg data for $dep_oid on leaf $leaf", 1 );
                $val = 'Undefined';
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
                do_log( "Missing msg data for $dep_oid", 1 );
                $val = 'Undefined';
            }
        }

        $msg =~ s/\{$dep_oid\}/$val/g;
    }

    return $msg;
}

# Apply thresholds to a supplied non-repeater oid, save in the oids hash
sub apply_thresh {
    my ( $oids, $thr, $oid ) = @_;

    my $oid_val = $oids->{$oid}{val};

    # Skip to next if there is an error as color is already defined
    return if $oids->{$oid}{error};

    # more precise threshold means more confidence
    my $thresh_confidence_level = 0;    # 7 Exact match, 6 Interval match, 5 smart match,
                                        # 4 Negative smart match, 3 Negative match, 2 Colored_Automatch
                                        # 1 Automatch
                                        # default values
    if ( !defined $oids->{$oid}{color} ) {
        $oids->{$oid}{color} = 'green';
        delete $oids->{$oid}{thresh};
        delete $oids->{$oid}{msg};
        delete $oids->{$oid}{error};
    }
    my $oid_color = $oids->{$oid}{color};

    # Sneakily sort our color array by color severity
COLOR: for my $color (@color_order) {

        # Determine if a custom thresholds (from hosts.cfg ) is defined
        if ( defined $thr ) {
            if ( exists $thr->{$oid} ) {
            TRH_LIST: for my $thresh_list ( keys %{ $thr->{$oid}{$color} } ) {
                    my $thresh_msg = $thr->{$oid}->{$color}->{$thresh_list};

                    # Split our comma-delimited thresholds up
                    for my $thresh ( split /\s*,\s*/, $thresh_list ) {

                        # check if the value to test is a num
                        if ( $oid_val ne 'NaN' and looks_like_number($oid_val) ) {

                            # Look for a simple numeric threshold, without a comparison operator.
                            # This is the most common threshold definition and handling it separately
                            # results in a significant performance improvement.
                            if ( $thresh_confidence_level < 6 and looks_like_number($thresh) ) {
                                if ( $oid_val >= $thresh ) {
                                    $oids->{$oid}{color}     = $color;
                                    $oids->{$oid}{thresh}    = $thresh;
                                    $oids->{$oid}{msg}       = $thresh_msg;
                                    $thresh_confidence_level = 6;
                                    next TRH_LIST;
                                }

                                # Look for a numeric threshold preceeded by a comparison operator.
                            } elsif ( $thresh =~ /^(>|<|>=|<=|=|!)\s*([+-]?\d+(?:\.\d+)?)$/ ) {
                                my ( $op, $limit ) = ( $1, $2 );
                                if (( $thresh_confidence_level < 6 )
                                    and (  ( $op eq '>' and $oid_val > $limit )
                                        or ( $op eq '>=' and $oid_val >= $limit )
                                        or ( $op eq '<'  and $oid_val < $limit )
                                        or ( $op eq '<=' and $oid_val <= $limit ) )
                                    )
                                {
                                    $oids->{$oid}{color}     = $color;
                                    $oids->{$oid}{thresh}    = $thresh;
                                    $oids->{$oid}{msg}       = $thresh_msg;
                                    $thresh_confidence_level = 6;
                                    next TRH_LIST;
                                } elsif ( $thresh_confidence_level < 7 and $op eq '=' and $oid_val == $limit ) {
                                    $oids->{$oid}{color}     = $color;
                                    $oids->{$oid}{thresh}    = $thresh;
                                    $oids->{$oid}{msg}       = $thresh_msg;
                                    $thresh_confidence_level = 7;
                                    last COLOR;
                                } elsif ( $thresh_confidence_level < 3 and $op eq '!' and $oid_val != $limit ) {
                                    $oids->{$oid}{color}     = $color;
                                    $oids->{$oid}{thresh}    = $thresh;
                                    $oids->{$oid}{msg}       = $thresh_msg;
                                    $thresh_confidence_level = 3;
                                    next TRH_LIST;
                                }
                            } elsif ( $thresh eq '_AUTOMATCH_' ) {
                                if ( $thresh_confidence_level < 2 and $oid_color eq $color ) {
                                    $oids->{$oid}{color}     = $color;
                                    $oids->{$oid}{thresh}    = $thresh;
                                    $oids->{$oid}{msg}       = $thresh_msg;
                                    $thresh_confidence_level = 2;
                                    next TRH_LIST;
                                } elsif ( $thresh_confidence_level < 1 ) {
                                    $oids->{$oid}{color}     = $color;
                                    $oids->{$oid}{thresh}    = $thresh;
                                    $oids->{$oid}{msg}       = $thresh_msg;
                                    $thresh_confidence_level = 1;
                                    next TRH_LIST;
                                }
                            }

                            # Look for negated test, must be string based
                        } elsif ( $thresh =~ /^!\s*(.+)/ ) {
                            my $neg_thresh = $1;
                            if ( $thresh_confidence_level < 4 and $oid_val !~ /$neg_thresh/ ) {
                                $oids->{$oid}{color}     = $color;
                                $oids->{$oid}{thresh}    = $thresh;
                                $oids->{$oid}{msg}       = $thresh_msg;
                                $thresh_confidence_level = 4;
                                next TRH_LIST;
                            } elsif ( $thresh_confidence_level < 3 and $oid_val ne $neg_thresh ) {
                                $oids->{$oid}{color}     = $color;
                                $oids->{$oid}{thresh}    = $thresh;
                                $oids->{$oid}{msg}       = $thresh_msg;
                                $thresh_confidence_level = 3;
                                next TRH_LIST;
                            }

                            # Its not numeric or negated, it must be string based
                        } else {

                            # Do our automatching for blank thresholds
                            if ( $thresh eq '_AUTOMATCH_' ) {
                                if ( $thresh_confidence_level < 2 and $oid_color eq $color ) {
                                    $oids->{$oid}{color}     = $color;
                                    $oids->{$oid}{thresh}    = $thresh;
                                    $oids->{$oid}{msg}       = $thresh_msg;
                                    $thresh_confidence_level = 2;
                                    next TRH_LIST;
                                } elsif ( $thresh_confidence_level < 1 ) {
                                    $oids->{$oid}{color}     = $color;
                                    $oids->{$oid}{thresh}    = $thresh;
                                    $oids->{$oid}{msg}       = $thresh_msg;
                                    $thresh_confidence_level = 1;
                                    next TRH_LIST;
                                }
                            } elsif ( $thresh_confidence_level < 7 and $oid_val eq $thresh ) {
                                $oids->{$oid}{color}     = $color;
                                $oids->{$oid}{thresh}    = $thresh;
                                $oids->{$oid}{msg}       = $thresh_msg;
                                $thresh_confidence_level = 7;
                                next COLOR;
                            } elsif ( $thresh_confidence_level < 5 and $oid_val =~ /$thresh/ ) {
                                $oids->{$oid}{color}     = $color;
                                $oids->{$oid}{thresh}    = $thresh;
                                $oids->{$oid}{msg}       = $thresh_msg;
                                $thresh_confidence_level = 5;
                                next TRH_LIST;
                            }
                        }
                    }
                }
            }
        }
    }

    # After custom thresholds (from hosts.cfg), apply template thresholds (from file)
COLOR: for my $color (@color_order) {

    TRH_LIST: for my $thresh_list ( keys %{ $oids->{$oid}->{threshold}->{$color} } ) {
            my $thresh_msg = $oids->{$oid}->{threshold}->{$color}->{$thresh_list};

            # Split our comma-delimited thresholds up
            for my $thresh ( split /\s*,\s*/, $thresh_list ) {

                # check if the value to test is a num
                if ( $oid_val ne 'NaN' and looks_like_number($oid_val) ) {

                    # Look for a simple numeric threshold, without a comparison operator.
                    # This is the most common threshold definition and handling it separately
                    # results in a significant performance improvement.
                    if ( $thresh_confidence_level < 6 and looks_like_number($thresh) ) {
                        if ( $oid_val >= $thresh ) {
                            $oids->{$oid}{color}     = $color;
                            $oids->{$oid}{thresh}    = $thresh;
                            $oids->{$oid}{msg}       = $thresh_msg;
                            $thresh_confidence_level = 6;
                            next TRH_LIST;
                        }

                        # Look for a numeric threshold preceeded by a comparison operator.
                    } elsif ( $thresh =~ /^(>|<|>=|<=|=|!)\s*([+-]?\d+(?:\.\d+)?)$/ ) {
                        my ( $op, $limit ) = ( $1, $2 );
                        if (( $thresh_confidence_level < 6 )
                            and (  ( $op eq '>' and $oid_val > $limit )
                                or ( $op eq '>=' and $oid_val >= $limit )
                                or ( $op eq '<'  and $oid_val < $limit )
                                or ( $op eq '<=' and $oid_val <= $limit ) )
                            )
                        {
                            $oids->{$oid}{color}     = $color;
                            $oids->{$oid}{thresh}    = $thresh;
                            $oids->{$oid}{msg}       = $thresh_msg;
                            $thresh_confidence_level = 6;
                            next TRH_LIST;
                        } elsif ( $thresh_confidence_level < 7 and $op eq '=' and $oid_val == $limit ) {
                            $oids->{$oid}{color}     = $color;
                            $oids->{$oid}{thresh}    = $thresh;
                            $oids->{$oid}{msg}       = $thresh_msg;
                            $thresh_confidence_level = 7;
                            last COLOR;
                        } elsif ( $thresh_confidence_level < 3 and $op eq '!' and $oid_val != $limit ) {
                            $oids->{$oid}{color}     = $color;
                            $oids->{$oid}{thresh}    = $thresh;
                            $oids->{$oid}{msg}       = $thresh_msg;
                            $thresh_confidence_level = 3;
                            next TRH_LIST;
                        }
                    } elsif ( $thresh eq '_AUTOMATCH_' ) {
                        if ( $thresh_confidence_level < 2 and $oid_color eq $color ) {
                            $oids->{$oid}{color}     = $color;
                            $oids->{$oid}{thresh}    = $thresh;
                            $oids->{$oid}{msg}       = $thresh_msg;
                            $thresh_confidence_level = 2;
                            next TRH_LIST;
                        } elsif ( $thresh_confidence_level < 1 ) {
                            $oids->{$oid}{color}     = $color;
                            $oids->{$oid}{thresh}    = $thresh;
                            $oids->{$oid}{msg}       = $thresh_msg;
                            $thresh_confidence_level = 1;
                            next TRH_LIST;
                        }
                    }

                    # Look for negated test, must be string based
                } elsif ( $thresh =~ /^!\s*(.+)/ ) {
                    my $neg_thresh = $1;
                    if ( $thresh_confidence_level < 4 and $oid_val !~ /$neg_thresh/ ) {
                        $oids->{$oid}{color}     = $color;
                        $oids->{$oid}{thresh}    = $thresh;
                        $oids->{$oid}{msg}       = $thresh_msg;
                        $thresh_confidence_level = 4;
                        next TRH_LIST;
                    } elsif ( $thresh_confidence_level < 3 and $oid_val ne $neg_thresh ) {
                        $oids->{$oid}{color}     = $color;
                        $oids->{$oid}{thresh}    = $thresh;
                        $oids->{$oid}{msg}       = $thresh_msg;
                        $thresh_confidence_level = 3;
                        next TRH_LIST;
                    }

                    # Its not numeric or negated, it must be string based
                } else {

                    # Do our automatching for blank thresholds
                    if ( $thresh eq '_AUTOMATCH_' ) {
                        if ( $thresh_confidence_level < 2 and $oid_color eq $color ) {
                            $oids->{$oid}{color}     = $color;
                            $oids->{$oid}{thresh}    = $thresh;
                            $oids->{$oid}{msg}       = $thresh_msg;
                            $thresh_confidence_level = 2;
                            next TRH_LIST;
                        } elsif ( $thresh_confidence_level < 1 ) {
                            $oids->{$oid}{color}     = $color;
                            $oids->{$oid}{thresh}    = $thresh;
                            $oids->{$oid}{msg}       = $thresh_msg;
                            $thresh_confidence_level = 1;
                            next TRH_LIST;
                        }
                    } elsif ( $thresh_confidence_level < 7 and $oid_val eq $thresh ) {
                        $oids->{$oid}{color}     = $color;
                        $oids->{$oid}{thresh}    = $thresh;
                        $oids->{$oid}{msg}       = $thresh_msg;
                        $thresh_confidence_level = 7;
                        next COLOR;
                    } elsif ( $thresh_confidence_level < 5 and $oid_val =~ /$thresh/ ) {
                        $oids->{$oid}{color}     = $color;
                        $oids->{$oid}{thresh}    = $thresh;
                        $oids->{$oid}{msg}       = $thresh_msg;
                        $thresh_confidence_level = 5;
                        next TRH_LIST;
                    }
                }
            }
        }
    }
    if ( $oids->{$oid}{color} eq 'green' ) {
        return;
    } elsif ( $oids->{$oid}{color} eq 'clear' ) {
        $oids->{$oid}{error} = 1;
        return;
    } elsif ( $oids->{$oid}{color} eq 'blue' ) {
        return;
    } elsif ( $oids->{$oid}{color} eq 'yellow' ) {
        $oids->{$oid}{error} = 1;
        return;
    } elsif ( $oids->{$oid}{color} eq 'red' ) {
        $oids->{$oid}{error} = 1;
        return;
    }
    do_log("APPLY_THRESH: Invalid Color $oids->{$oid}{color}");
}

# Apply thresholds to a supplied repeater oid, save in the oids hash
sub apply_thresh_rep {

    my ( $oids, $thr, $oid ) = @_;

APTHRLEAF: for my $leaf ( keys %{ $oids->{$oid}{val} } ) {

        # Skip to next if there is an error as color is already defined
        next if $oids->{$oid}{error}{$leaf};

        my $oid_val                 = $oids->{$oid}{val}{$leaf};
        my $thresh_confidence_level = 0;                           # 7 Exact match, 6 Interval match, 5 smart-match,
                                                                   # 4 Negative smart-match, 3 Negative match, 2 Colored_Automatch
                                                                   # 1 Automatch

        if ( !defined $oids->{$oid}{color}{$leaf} ) {
            $oids->{$oid}{color}{$leaf} = 'green';
            delete $oids->{$oid}{thresh}{$leaf};
            delete $oids->{$oid}{msg}{$leaf};
            delete $oids->{$oid}{error}{$leaf};
        }
        my $oid_color = $oids->{$oid}{color}{$leaf};
    COLOR: for my $color (@color_order) {

            # we have a custom thresholds
            if ( defined $thr ) {
                if ( exists $thr->{$oid} ) {
                TRH_LIST: for my $thresh_list ( keys %{ $thr->{$oid}->{$color} } ) {
                        my $thresh_msg = $thr->{$oid}->{$color}{$thresh_list};

                        # Split our comma-delimited thresholds up
                        for my $thresh ( split /\s*,\s*/, $thresh_list ) {

                            # check if the value to test is a num
                            if ( $oid_val ne 'NaN' and looks_like_number($oid_val) ) {

                                # Look for a simple numeric threshold, without a comparison operator.
                                # This is the most common threshold definition and handling it separately
                                # results in a significant performance improvement.
                                if ( $thresh_confidence_level < 6 and looks_like_number($thresh) ) {
                                    if ( $oid_val >= $thresh ) {
                                        $oids->{$oid}{color}{$leaf}  = $color;
                                        $oids->{$oid}{thresh}{$leaf} = $thresh;
                                        $oids->{$oid}{msg}{$leaf}    = $thresh_msg;
                                        $thresh_confidence_level     = 6;
                                        next TRH_LIST;
                                    }

                                    # Look for a numeric threshold preceeded by a comparison operator.
                                } elsif ( $thresh =~ /^(>|<|>=|<=|=|!)\s*([+-]?\d+(?:\.\d+)?)$/ ) {
                                    my ( $op, $limit ) = ( $1, $2 );
                                    if (( $thresh_confidence_level < 6 )
                                        and (  ( $op eq '>' and $oid_val > $limit )
                                            or ( $op eq '>=' and $oid_val >= $limit )
                                            or ( $op eq '<'  and $oid_val < $limit )
                                            or ( $op eq '<=' and $oid_val <= $limit ) )
                                        )
                                    {
                                        $oids->{$oid}{color}{$leaf}  = $color;
                                        $oids->{$oid}{thresh}{$leaf} = $thresh;
                                        $oids->{$oid}{msg}{$leaf}    = $thresh_msg;
                                        $thresh_confidence_level     = 6;
                                        next TRH_LIST;
                                    } elsif ( $thresh_confidence_level < 7 and $op eq '=' and $oid_val == $limit ) {
                                        $oids->{$oid}{color}{$leaf}  = $color;
                                        $oids->{$oid}{thresh}{$leaf} = $thresh;
                                        $oids->{$oid}{msg}{$leaf}    = $thresh_msg;
                                        $thresh_confidence_level     = 7;
                                        last COLOR;
                                    } elsif ( $thresh_confidence_level < 3 and $op eq '!' and $oid_val != $limit ) {
                                        $oids->{$oid}{color}{$leaf}  = $color;
                                        $oids->{$oid}{thresh}{$leaf} = $thresh;
                                        $oids->{$oid}{msg}{$leaf}    = $thresh_msg;
                                        $thresh_confidence_level     = 3;
                                        next TRH_LIST;
                                    }
                                } elsif ( $thresh eq '_AUTOMATCH_' ) {
                                    if ( $thresh_confidence_level < 2 and $oid_color eq $color ) {
                                        $oids->{$oid}{color}{$leaf}  = $color;
                                        $oids->{$oid}{thresh}{$leaf} = $thresh;
                                        $oids->{$oid}{msg}{$leaf}    = $thresh_msg;
                                        $thresh_confidence_level     = 2;
                                        next TRH_LIST;
                                    } elsif ( $thresh_confidence_level < 1 ) {
                                        $oids->{$oid}{color}{$leaf}  = $color;
                                        $oids->{$oid}{thresh}{$leaf} = $thresh;
                                        $oids->{$oid}{msg}{$leaf}    = $thresh_msg;
                                        $thresh_confidence_level     = 1;
                                        next TRH_LIST;
                                    }
                                }

                                # Look for negated test, must be string based
                            } elsif ( $thresh =~ /^!\s*(.+)/ ) {
                                my $neg_thresh = $1;
                                if ( $thresh_confidence_level < 4 and $oid_val !~ /$neg_thresh/ ) {
                                    $oids->{$oid}{color}{$leaf}  = $color;
                                    $oids->{$oid}{thresh}{$leaf} = $thresh;
                                    $oids->{$oid}{msg}{$leaf}    = $thresh_msg;
                                    $thresh_confidence_level     = 4;
                                    next TRH_LIST;
                                } elsif ( $thresh_confidence_level < 3 and $oid_val ne $neg_thresh ) {
                                    $oids->{$oid}{color}{$leaf}  = $color;
                                    $oids->{$oid}{thresh}{$leaf} = $thresh;
                                    $oids->{$oid}{msg}{$leaf}    = $thresh_msg;
                                    $thresh_confidence_level     = 3;
                                    next TRH_LIST;
                                }

                                # Its not numeric or negated, it must be string based
                            } else {

                                # Do our automatching for blank thresholds
                                if ( $thresh eq '_AUTOMATCH_' ) {
                                    if ( $thresh_confidence_level < 2 and $oid_color eq $color ) {
                                        $oids->{$oid}{color}{$leaf}  = $color;
                                        $oids->{$oid}{thresh}{$leaf} = $thresh;
                                        $oids->{$oid}{msg}{$leaf}    = $thresh_msg;
                                        $thresh_confidence_level     = 2;
                                        next TRH_LIST;
                                    } elsif ( $thresh_confidence_level < 1 ) {
                                        $oids->{$oid}{color}{$leaf}  = $color;
                                        $oids->{$oid}{thresh}{$leaf} = $thresh;
                                        $oids->{$oid}{msg}{$leaf}    = $thresh_msg;
                                        $thresh_confidence_level     = 1;
                                        next TRH_LIST;
                                    }
                                } elsif ( $thresh_confidence_level < 7 and $oid_val eq $thresh ) {
                                    $oids->{$oid}{color}{$leaf}  = $color;
                                    $oids->{$oid}{thresh}{$leaf} = $thresh;
                                    $oids->{$oid}{msg}{$leaf}    = $thresh_msg;
                                    $thresh_confidence_level     = 7;
                                    next COLOR;
                                } elsif ( $thresh_confidence_level < 5 and $oid_val =~ /$thresh/ ) {
                                    $oids->{$oid}{color}{$leaf}  = $color;
                                    $oids->{$oid}{thresh}{$leaf} = $thresh;
                                    $oids->{$oid}{msg}{$leaf}    = $thresh_msg;
                                    $thresh_confidence_level     = 5;
                                    next TRH_LIST;
                                }
                            }
                        }
                    }
                }
            }
        }

        # After custom thresholds (from hosts.cfg), apply template thresholds (from file)
    COLOR: for my $color (@color_order) {

            # we check our template threshold
        TRH_LIST: for my $thresh_list ( keys %{ $oids->{$oid}->{threshold}->{$color} } ) {
                my $thresh_msg = $oids->{$oid}->{threshold}->{$color}{$thresh_list};

                # Split our comma-delimited thresholds up
                for my $thresh ( split /\s*,\s*/, $thresh_list ) {

                    # check if the value to test is a num
                    if ( $oid_val ne 'NaN' and looks_like_number($oid_val) ) {

                        # Look for a simple numeric threshold, without a comparison operator.
                        # This is the most common threshold definition and handling it separately
                        # results in a significant performance improvement.
                        if ( $thresh_confidence_level < 6 and looks_like_number($thresh) ) {
                            if ( $oid_val >= $thresh ) {
                                $oids->{$oid}->{color}{$leaf}  = $color;
                                $oids->{$oid}->{thresh}{$leaf} = $thresh;
                                $oids->{$oid}->{msg}{$leaf}    = $thresh_msg;
                                $thresh_confidence_level       = 6;

                                next TRH_LIST;
                            }

                            # Look for a numeric threshold preceeded by a comparison operator.
                        } elsif ( $thresh =~ /^(>|<|>=|<=|=|!)\s*([+-]?\d+(?:\.\d+)?)$/ ) {
                            my ( $op, $limit ) = ( $1, $2 );
                            if (( $thresh_confidence_level < 6 )
                                and (  ( $op eq '>' and $oid_val > $limit )
                                    or ( $op eq '>=' and $oid_val >= $limit )
                                    or ( $op eq '<'  and $oid_val < $limit )
                                    or ( $op eq '<=' and $oid_val <= $limit ) )
                                )
                            {
                                $oids->{$oid}{color}{$leaf}  = $color;
                                $oids->{$oid}{thresh}{$leaf} = $thresh;
                                $oids->{$oid}{msg}{$leaf}    = $thresh_msg;
                                $thresh_confidence_level     = 6;
                                next TRH_LIST;
                            } elsif ( $thresh_confidence_level < 7 and $op eq '=' and $oid_val == $limit ) {
                                $oids->{$oid}{color}{$leaf}  = $color;
                                $oids->{$oid}{thresh}{$leaf} = $thresh;
                                $oids->{$oid}{msg}{$leaf}    = $thresh_msg;
                                $thresh_confidence_level     = 7;
                                last COLOR;
                            } elsif ( $thresh_confidence_level < 3 and $op eq '!' and $oid_val != $limit ) {
                                $oids->{$oid}{color}{$leaf}  = $color;
                                $oids->{$oid}{thresh}{$leaf} = $thresh;
                                $oids->{$oid}{msg}{$leaf}    = $thresh_msg;
                                $thresh_confidence_level     = 3;
                                next TRH_LIST;
                            }
                        } elsif ( $thresh eq '_AUTOMATCH_' ) {
                            if ( $thresh_confidence_level < 2 and $oid_color eq $color ) {
                                $oids->{$oid}{color}{$leaf}  = $color;
                                $oids->{$oid}{thresh}{$leaf} = $thresh;
                                $oids->{$oid}{msg}{$leaf}    = $thresh_msg;
                                $thresh_confidence_level     = 2;
                                next TRH_LIST;
                            } elsif ( $thresh_confidence_level < 1 ) {
                                $oids->{$oid}{color}{$leaf}  = $color;
                                $oids->{$oid}{thresh}{$leaf} = $thresh;
                                $oids->{$oid}{msg}{$leaf}    = $thresh_msg;
                                $thresh_confidence_level     = 1;
                                next TRH_LIST;
                            }
                        }

                        # Look for negated test, must be string based
                    } elsif ( $thresh =~ /^!\s*(.+)/ ) {
                        my $neg_thresh = $1;
                        if ( $thresh_confidence_level < 4 and $oid_val !~ /$neg_thresh/ ) {
                            $oids->{$oid}{color}{$leaf}  = $color;
                            $oids->{$oid}{thresh}{$leaf} = $thresh;
                            $oids->{$oid}{msg}{$leaf}    = $thresh_msg;
                            $thresh_confidence_level     = 4;
                            next TRH_LIST;
                        } elsif ( $thresh_confidence_level < 3 and $oid_val ne $neg_thresh ) {
                            $oids->{$oid}{color}{$leaf}  = $color;
                            $oids->{$oid}{thresh}{$leaf} = $thresh;
                            $oids->{$oid}{msg}{$leaf}    = $thresh_msg;
                            $thresh_confidence_level     = 3;
                            next TRH_LIST;
                        }

                        # Its not numeric or negated, it must be string based
                    } else {

                        # Do our automatching for blank thresholds
                        if ( $thresh eq '_AUTOMATCH_' ) {
                            if ( $thresh_confidence_level < 2 and $oid_color eq $color ) {
                                $oids->{$oid}{color}{$leaf}  = $color;
                                $oids->{$oid}{thresh}{$leaf} = $thresh;
                                $oids->{$oid}{msg}{$leaf}    = $thresh_msg;
                                $thresh_confidence_level     = 2;
                                next TRH_LIST;
                            } elsif ( $thresh_confidence_level < 1 ) {
                                $oids->{$oid}{color}{$leaf}  = $color;
                                $oids->{$oid}{thresh}{$leaf} = $thresh;
                                $oids->{$oid}{msg}{$leaf}    = $thresh_msg;
                                $thresh_confidence_level     = 1;
                                next TRH_LIST;
                            }
                        } elsif ( $thresh_confidence_level < 7 and $oid_val eq $thresh ) {
                            $oids->{$oid}{color}{$leaf}  = $color;
                            $oids->{$oid}{thresh}{$leaf} = $thresh;
                            $oids->{$oid}{msg}{$leaf}    = $thresh_msg;
                            $thresh_confidence_level     = 7;
                            next COLOR;
                        } elsif ( $thresh_confidence_level < 5 and $oid_val =~ /$thresh/ ) {
                            $oids->{$oid}{color}{$leaf}  = $color;
                            $oids->{$oid}{thresh}{$leaf} = $thresh;
                            $oids->{$oid}{msg}{$leaf}    = $thresh_msg;
                            $thresh_confidence_level     = 5;
                            next TRH_LIST;
                        }
                    }
                }
            }
        }
        if ( $oids->{$oid}{color}{$leaf} eq 'green' ) {
            next;
        } elsif ( $oids->{$oid}{color}{$leaf} eq 'clear' ) {
            $oids->{$oid}{error}{$leaf} = 1;
            next;
        } elsif ( $oids->{$oid}{color}{$leaf} eq 'blue' ) {
            next;
        } elsif ( $oids->{$oid}{color}{$leaf} eq 'yellow' ) {
            $oids->{$oid}{error}{$leaf} = 1;
            next;
        } elsif ( $oids->{$oid}{color}{$leaf} eq 'red' ) {
            $oids->{$oid}{error}{$leaf} = 1;
            next;
        }
        do_log("APPLY_THRESH: Invalid Color $oids->{$oid}{color}{$leaf}");
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

# Validate oid dependencies
sub validate_deps {
    my ( $device, $oids, $oid, $dep_arr, $regex ) = @_;
    my $oid_h = \%{ $oids->{$oid} };

    # Return witout error if we do not have any dependant oids
    return 1 unless scalar @$dep_arr;

    # Go through our parent oid array, if there are any repeaters
    # set the first one as the primary OID and set the repeat type
    # but very first that it is not already defined as a leaf
    for my $dep_oid (@$dep_arr) {
        if ( $oids->{$dep_oid}{repeat} ) {
            $oid_h->{pri_oid} = $dep_oid;
            $oid_h->{repeat}  = $oids->{$dep_oid}{repeat};
            last;
        }
    }

    # Use a non-repeater type if we havent set it yet
    $oid_h->{repeat} ||= 0;

    # Repeater type OIDs
    my $all_error = 1;

    if ( $oid_h->{repeat} ) {

        # Parse our parent OIDs
    LEAF: for my $leaf ( keys %{ $oids->{ $oid_h->{pri_oid} }{val} } ) {
            for my $dep_oid (@$dep_arr) {
                my $dep_oid_h = \%{ $oids->{$dep_oid} };
                my $val;
                my $error;
                my $color;
                my $msg;
                if ( $dep_oid_h->{repeat} ) {
                    if ( defined $dep_oid_h->{global_error} and $dep_oid_h->{global_error} ) {
                        $val   = $dep_oid_h->{global_val};
                        $error = $dep_oid_h->{global_error};
                        $color = $dep_oid_h->{global_color};
                        $msg   = $dep_oid_h->{global_msg};
                    } else {
                        $val   = $dep_oid_h->{val}{$leaf};
                        $error = $dep_oid_h->{error}{$leaf};
                        $color = $dep_oid_h->{color}{$leaf};
                        $msg   = $dep_oid_h->{msg}{$leaf};
                    }
                } else {
                    $val   = $dep_oid_h->{val};
                    $error = $dep_oid_h->{error};
                    $color = $dep_oid_h->{color};
                    $msg   = $dep_oid_h->{msg};
                }

                #my $val   = ($dep_oid_h->{repeat}) ? $dep_oid_h->{val}{$leaf}   : $dep_oid_h->{val};
                #my $error = ($dep_oid_h->{repeat}) ? $dep_oid_h->{error}{$leaf} : $dep_oid_h->{error};
                #my $color = ($dep_oid_h->{repeat}) ? $dep_oid_h->{color}{$leaf} : $dep_oid_h->{color};
                #my $msg   = ($dep_oid_h->{repeat}) ? $dep_oid_h->{msg}{$leaf}   : $dep_oid_h->{mgs};

                if ( !defined $val ) {

                    # We should never be here with an undef val as it
                    # should be alread treated: severity increase to yellow

                    $oid_h->{val}{$leaf}   = 'parent value n/a';
                    $oid_h->{time}{$leaf}  = time;
                    $oid_h->{color}{$leaf} = 'yellow';
                    $oid_h->{error}{$leaf} = 1;
                    next LEAF;
                } elsif ( $val eq 'wait' ) {
                    $oid_h->{val}{$leaf}   = 'wait';
                    $oid_h->{time}{$leaf}  = time;
                    $oid_h->{color}{$leaf} = 'clear';
                    $oid_h->{error}{$leaf} = 1;
                    $oid_h->{msg}{$leaf}   = '';
                    next LEAF;
                } elsif ($error) {

                    # Find de worst color
                    if ( !defined $oid_h->{color}{$leaf}
                        or $colors{ $dep_oid_h->{color}{$leaf} } > $colors{ $oid_h->{color}{$leaf} } )
                    {

                        # In debug mode the error is accumulated
                        if ( $g{debug} ) {
                            my ( $l, $r ) = split /<-/, $val, 2;
                            if ( !defined $r ) {
                                $oid_h->{val}{$leaf} = $l . "<-" . $dep_oid;
                            } else {
                                $oid_h->{val}{$leaf} = $l . "<-" . $dep_oid . "<-" . $r;
                            }

                            #$oid_h->{val}{$leaf}   = $val . "<-$dep_oid";
                        } else {
                            $oid_h->{val}{$leaf} = $val;
                        }
                        $oid_h->{color}{$leaf} = $color;
                        $oid_h->{msg}{$leaf}   = $msg;
                    } elsif ( $oid_h->{color}{$leaf} eq $color ) {
                        if ( $g{debug} ) {
                            my ( $l, $r ) = split /<-/, $val, 2;
                            if ( !defined $r ) {
                                $oid_h->{val}{$leaf} .= "|" . $l . "<-" . $dep_oid;
                            } else {
                                $oid_h->{val}{$leaf} .= "|" . $l . "<-" . $dep_oid . "<-" . $r;
                            }

                            #$oid_h->{val}{$leaf}  .= "|". $val . "<-$dep_oid";
                        } else {
                            $oid_h->{val}{$leaf} .= "|" . $val;
                        }
                        if ( defined $msg ) {
                            if ( defined $oid_h->{msg}{$leaf} and $oid_h->{msg}{$leaf} ne '' ) {
                                $oid_h->{msg}{$leaf} .= " 1& " . $msg;
                            } else {
                                $oid_h->{msg}{$leaf} = $msg;
                            }
                        }
                    }
                    $oid_h->{error}{$leaf} = 1;
                    $oid_h->{time}{$leaf}  = time;

                    #   next;
                } elsif ( defined $regex and $val !~ /$regex/ ) {
                    $oid_h->{val}{$leaf}   = "$val mismatch $regex";
                    $oid_h->{time}{$leaf}  = time;
                    $oid_h->{color}{$leaf} = 'yellow';
                    $oid_h->{error}{$leaf} = 1;

                    #   next LEAF;
                } else {

                    # No errors.  Over the line! Mark it zero, dude
                    $oid_h->{error}{$leaf} = 0;

                    # Record the fact that we got at least 1 good data value
                    $all_error = 0;
                }

                # Throw one error message
                do_log( "DEBUG TEST: '$oid_h->{val}{$leaf}' while parsing '$dep_oid' for '$leaf' on $device", 5 )
                    if $oid_h->{error}{$leaf};
            }

            # Throw one error message per leaf, to prevent log bloat
            do_log( "DEBUG TEST: '$oid_h->{val}{$leaf}' while parsing '$leaf' on $device", 4 )
                if $oid_h->{error}{$leaf};

            # Only return an error value all of the dependent oids leaves failed
            #return 0 if $all_error;
        }

        # Non repeater
    } else {

        # Parse our parent oids
        for my $dep_oid (@$dep_arr) {
            my $val = $oids->{$dep_oid}{val};

            if ( !defined $val ) {

                # We should never be here with an undef val as it
                # should be alread treated: severity increase to yellow
                $oid_h->{val}   = 'parent value n/a';
                $oid_h->{time}  = time;
                $oid_h->{color} = 'yellow';
                $oid_h->{error} = 1;
                next;
            } elsif ( $val eq 'wait' ) {
                $oid_h->{val}   = 'wait';
                $oid_h->{time}  = time;
                $oid_h->{color} = 'clear';
                $oid_h->{error} = 1;
                $oid_h->{msg}   = '';
            } elsif ( $oids->{$dep_oid}{error} ) {

                # Find de worst color
                if ( !defined $oid_h->{color}
                    or $colors{ $oids->{$dep_oid}{color} } > $colors{ $oid_h->{color} } )
                {

                    # In debug mode the error is accumulated
                    if ( $g{debug} ) {
                        my ( $l, $r ) = split /<-/, $oids->{$dep_oid}{val}, 2;
                        if ( !defined $r ) {
                            $oid_h->{val} = $l . "<-" . $dep_oid;
                        } else {
                            $oid_h->{val} = $l . "<-" . $dep_oid . "<-" . $r;
                        }

                        #$oid_h->{val}  = $oids->{$dep_oid}{val} . "<-$dep_oid";
                    } else {
                        $oid_h->{val} = $oids->{$dep_oid}{val};
                    }
                    $oid_h->{color} = $oids->{$dep_oid}{color};
                    $oid_h->{msg}   = $oids->{$dep_oid}{msg};
                } elsif ( $oid_h->{color} eq $oids->{$dep_oid}{color} ) {
                    if ( $g{debug} ) {
                        my ( $l, $r ) = split /<-/, $oids->{$dep_oid}{val}, 2;
                        if ( !defined $r ) {
                            $oid_h->{val} .= "|" . $l . "<-" . $dep_oid;
                        } else {
                            $oid_h->{val} .= "|" . $l . "<-" . $dep_oid . "<-" . $r;
                        }

                        #$oid_h->{val} .= "|". $oids->{$dep_oid}{val} . "<-$dep_oid";
                    } else {
                        $oid_h->{val} .= "|" . $oids->{$dep_oid}{val};
                    }
                    if ( defined $oids->{$dep_oid}{msg} ) {
                        if ( defined $oid_h->{msg} and $oid_h->{msg} ne '' ) {
                            $oid_h->{msg} .= " 2& " . $oids->{$dep_oid}{msg};
                        } else {
                            $oid_h->{msg} = $oids->{$dep_oid}{msg};
                        }
                    }
                }
                $oid_h->{error} = 1;
                $oid_h->{time}  = time;

                #   next;
            } elsif ( defined $regex and $val !~ /$regex/ ) {
                $oid_h->{val}   = "$val mismatch(=~) $regex";
                $oid_h->{time}  = time;
                $oid_h->{color} = 'yellow';
                $oid_h->{error} = 1;

                #   next;
            } else {

                # No errors.  Over the line! Mark it zero, dude
                $oid_h->{error} = 0;

                # Record the fact that we got at least 1 good data value
                $all_error = 0;
            }

            # Throw one error message
            do_log( "DEBUG TEST: '$oid_h->{val}' while parsing '$dep_oid' on $device", 4 ) if $oid_h->{error};
            return 0                                                                       if $oid_h->{error};
        }
    }
    $all_error ? return 0 : return 1;
}
