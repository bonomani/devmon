package dm_snmp_snmp_session;
use strict;
use warnings;
use lib '.';            # Ensure Perl can find custom modules
use BER;
use Data::Dumper;       # Import for debugging
use dm_snmp_utils qw(add_varbind_error add_error get_varbind_errors get_errors);
use dm_snmp_constants;
use File::Basename;
my $lib = "SNMP_Session";
eval "require $lib";    # This will load the package

if ($@) {
    die "Failed to load module $lib: $@";
}

sub set_timeout {
    no strict 'refs';    # Disable strict checking for symbolic references
    return &{"${lib}::set_timeout"}(@_);
}

sub set_retries {
    no strict 'refs';    # Disable strict checking for symbolic references
    return &{"${lib}::set_retries"}(@_);
}

sub set_backoff {
    no strict 'refs';    # Disable strict checking for symbolic references
    return &{"${lib}::set_backoff"}(@_);
}

sub snmp_errmsg {
    no strict 'refs';
    return ${"${lib}::errmsg"};
}

sub new {
    my ( $class, $params_ref ) = @_;

    # Set a default for the BER pretty print flag
    $BER::pretty_print_timeticks = 0;

    # Determine if the OID prefix should start with a dot
    my $oid_has_prefix_dot = 0;
    my $oid_prefix         = $oid_has_prefix_dot ? "." : "";
    my $self               = {
        host            => $params_ref->{host},
        community       => $params_ref->{community},
        port            => $params_ref->{port} // 161,
        max_pdu_len     => $params_ref->{max_pdu_len},
        local_port      => $params_ref->{local_port},
        max_repetitions => $params_ref->{max_repetitions},
        local_host      => $params_ref->{local_host},
        ipv4only        => $params_ref->{ipv4only},
        version         => $params_ref->{version},
        timeout         => $params_ref->{timeout},
        retries         => $params_ref->{retries},
        backoff         => $params_ref->{backoff},                                    # corrected from backogg
        debug           => defined $params_ref->{debug} ? $params_ref->{debug} : 0,
        oid_prefix      => $oid_prefix,
        errors          => [],                                                        # Array to store error hash references
        varbind_errors  => [],                                                        # Array to store varbind error array references
        session         => undef,
    };
    { no strict 'refs'; ${"${lib}::suppress_warnings"} = !$self->{debug}; }
    return bless $self, $class;
}

sub version {
    my ($self) = @_;
    return 2 if ref( $self->{session} ) eq "SNMPv2c_Session";
    return 1 if ref( $self->{session} ) eq "SNMPv1_Session";
    return undef;
}

# The update subroutine
sub update {
    my ( $self, $params_ref ) = @_;
    my $session = $self->{session};

    # Update object parameters from the hash reference
    $self->_update_params($params_ref);

    # Proceed only if session is defined
    if ( defined $session ) {
        my $current_version = $self->version();

        # Check if the session needs to be updated
        if ( !defined($current_version) || $self->{version} ne $current_version ) {

            # Recreate session based on the SNMP version
            $self->_create_session();
        }
        else {
            # Update session parameters if needed
            $self->_update_session_params( $session, $params_ref );
        }
    }
    return $self;
}

# The _ensure_session subroutine
sub _ensure_session {
    my ( $self, $params_ref ) = @_;

    # Update debug early and set the library's warning suppression flag
    $self->_update_debug($params_ref);

    # Reset error arrays and library error variables
    $self->_reset_errors();

    # Create session if none exists
    $self->_create_session unless defined $self->{session};

    # Refresh the local session variable in case it was just created
    my $session = $self->{session};

    # Update specific parameters if provided
    $self->_update_session_params( $session, $params_ref );

    # If session creation still failed, handle error and return undef
    unless ( defined $self->{session} ) {
        $self->_handle_snmp_error(SNMPERR_BAD_SESSION);
        return undef;
    }
    return $self->{session};
}

# Helper to update object parameters from the hash reference
sub _update_params {
    my ( $self, $params_ref ) = @_;
    $self->{$_} = $params_ref->{$_} for keys %{$params_ref};
}

# Helper to update debug flag and suppress warnings
sub _update_debug {
    my ( $self, $params_ref ) = @_;
    if ( defined $params_ref->{debug} ) {
        $self->{debug} = $params_ref->{debug};
        { no strict 'refs'; ${"${lib}::suppress_warnings"} = !$self->{debug}; }
    }
}

# Helper to reset error arrays and library error variables
sub _reset_errors {
    my $self = shift;
    $self->{errors}         = [];
    $self->{varbind_errors} = [];
    { no strict 'refs'; ${"${lib}::errmsg"} = undef; }
    $BER::errmsg = undef;
}

# Helper to create SNMP session if it does not exist
sub _create_session {
    my $self = shift;
    if ( $self->{version} == 2 ) {
        $self->{session} = SNMPv2c_Session->open(
            $self->{host},       $self->{community},       $self->{port},       $self->{max_pdu_len},
            $self->{local_port}, $self->{max_repetitions}, $self->{local_host}, $self->{ipv4only}
        );
    }
    elsif ( $self->{version} == 1 ) {
        $self->{session} = SNMPv1_Session->open(
            $self->{host},       $self->{community},       $self->{port},       $self->{max_pdu_len},
            $self->{local_port}, $self->{max_repetitions}, $self->{local_host}, $self->{ipv4only}
        );
    }
}

# Consolidated helper to update session parameters and apply configuration
sub _update_session_params {
    my ( $self, $session, $params_ref ) = @_;

    # Update session parameters if provided
    if ( defined $params_ref->{timeout} ) {
        $self->{timeout} = $params_ref->{timeout};
        set_timeout( $session, $self->{timeout} );
    }
    if ( defined $params_ref->{retries} ) {
        $self->{retries} = $params_ref->{retries};
        set_retries( $session, $self->{retries} + 1 );
    }
    if ( defined $params_ref->{backoff} ) {
        $self->{backoff} = $params_ref->{backoff};
        set_backoff( $session, $self->{backoff} );
    }

    # Update session-specific parameters (hostname, port, community, max_pdu_len)
    if ( defined $self->{host} && $self->{host} ne $session->{remote_hostname} ) {
        $session->{remote_hostname} = $self->{host};
    }
    if ( defined $self->{port} && ( $self->{port} // 161 ) ne ( $session->{port} // 161 ) ) {
        $session->{port} = $self->{port};
    }
    if ( defined $self->{community} && $self->{community} ne $session->{community} ) {
        $session->{community} = $self->{community};
    }
    if ( defined $self->{max_pdu_len} && $self->{max_pdu_len} ne $session->{max_pdu_len} ) {
        $session->{max_pdu_len} = $self->{max_pdu_len};
    }

    # No need to call _apply_session_config separately anymore
}

sub _handle_snmp_error {
    my ( $self, $code ) = @_;
    my ( $host, $ip, $community, $request_id, $max_pdu_len, $timeout, $retries, $backoff, $message, $version );
    my $session = $self->{session};
    my $oid;

    my $snmp_errmsg = snmp_errmsg();
    if ( defined $code ) {

        # If a code is provided, look up the error message from the object's error_messages hash.
        #$message = $self->{error_messages}->{$code} if defined $self->{error_messages}->{$code};
        #$message = NET_SNMP_ERRNO_MESSAGES()->{$code};
        #$extra = $errmsg_value if defined $errmsg_value;
    }
    elsif ( defined $snmp_errmsg ) {

        # Extract/ various parameters from the error message.
        ($host)        = $snmp_errmsg =~ /remote host: "([^"]+)"/;
        ($ip)          = $snmp_errmsg =~ /\[([0-9a-fA-F:]+)\]/;
        ($community)   = $snmp_errmsg =~ /community: "([^"]+)"/;
        ($request_id)  = $snmp_errmsg =~ /request ID: (-?\d+)/;
        ($max_pdu_len) = $snmp_errmsg =~ /PDU bufsize: (\d+)/;
        ($timeout)     = $snmp_errmsg =~ /timeout: (\d+)s/;
        ($retries)     = $snmp_errmsg =~ /retries: (\d+)/;
        ($backoff)     = $snmp_errmsg =~ /backoff: (\d+)/;
        ($message)     = $snmp_errmsg =~ /\s*(?:Received SNMP response with error code)?(.*?)\s+SNMPv\d+c?_Session/s;

        if ( $message =~ /error\s+status:\s+(\S+)\s+index\s+\d+\s+\(OID:\s+([^\)]+)\)/s ) {

            # For varbind-specific errors, add the error to varbind_errors and return undef
            $self->add_varbind_error( $2, $1 );
            return undef;
        }
        elsif ( $message eq "no response received" ) {
            $code        = SNMPERR_TIMEOUT;
            $snmp_errmsg = undef;
        }
        else {
            $snmp_errmsg =~ s/^\s+|\s+$//g;
            $snmp_errmsg =~ s/\n/, /g;
            $snmp_errmsg =~ s/\s+/ /g;
        }
    }

    # Determine session values either from the session or from the object
    if ( defined $session ) {
        $version     //= $self->version();
        $host        //= $session->{remote_hostname};
        $ip          //= $session->{remote_addr};
        $community   //= $session->{community};
        $request_id  //= $session->{request_id};
        $timeout     //= $session->{timeout};
        $max_pdu_len //= $session->{max_pdu_len};
        $retries     //= $session->{retries};
        $backoff     //= $session->{backoff};
    }
    else {
        $version     //= $self->{version};
        $host        //= $self->{host};
        $ip          //= $self->{ip};
        $community   //= $self->{community};
        $timeout     //= $self->{timeout};
        $max_pdu_len //= $self->{max_pdu_len};
        $retries     //= $self->{retries};
        $backoff     //= $self->{backoff};
    }
    my %error_data = (
        device => $host,

        #        ip          => $ip,
        community   => $community,
        request_id  => $request_id,
        timeout     => $timeout,
        max_pdu_len => $max_pdu_len,
        retries     => $retries,
        backoff     => $backoff,
        version     => $version,                          # No fallback value for version
        snmp_errmsg => $snmp_errmsg,
        file        => basename( ( caller(1) )[ 1 ] ),    # No fallback value for file
        line        => ( caller(1) )[ 2 ],                # No fallback value for line
        sub         => ( caller(1) )[ 3 ],                # No fallback value for function
    );

    # Add error to the object's error list with structured details
    $self->add_error( $code // $snmp_errmsg, %error_data );

    # Return the error code
    return $code;
}

# ✅ Perform SNMP GETBULK operation
sub getbulk_snmp {
    my ( $self, $query_params, $non_repeaters, $max_repetitions, @oids ) = @_;
    my $session = $self->_ensure_session($query_params);
    unless ( defined $session ) {
        return wantarray ? () : undef;
    }

    # Early return errors: No snmpv1 support for getbulk
    if ( $self->version() == 1 ) {    # 0 = SNMP version 1
        $self->_handle_snmp_error(SNMPERR_V2_IN_V1);
        return wantarray ? () : undef;
    }

    # Ensure @oids is correctly formatted (array reference)
    if ( @oids == 1 && ref $oids[ 0 ] eq 'ARRAY' ) {
        @oids = @{ $oids[ 0 ] };
    }

    # Encode OIDs for SNMP request
    my @encoded_oids = map { BER::encode_oid( split( /\./, $_ ) ) } grep { defined $_ && $_ ne '' } @oids;

    # Early return on no valid OIDs
    unless (@encoded_oids) {
        $self->_handle_snmp_error("No valid OIDs provided for SNMP GETBULK");
        return wantarray ? () : undef;
    }

    # Perform GETBULK request and decode the response
    if ( $session->getbulk_request_response( $non_repeaters, $max_repetitions, @encoded_oids ) ) {
        my @valid_oids;
        my ($bindings) = $session->decode_get_response( $session->pdu_buffer );

        #print Dumper($session);
        # Early return on failure
        unless ( defined $bindings ) {
            $self->_handle_snmp_error("Failed to decode SNMP response");
            return wantarray ? () : undef;
        }

        # Process non-repeaters first
        my $i = 0;
        while ( $bindings ne '' and $i < $non_repeaters ) {
            my ( $binding, $rest ) = BER::decode_sequence($bindings);
            $bindings = $rest;
            my ( $oid, $value ) = BER::decode_by_template( $binding, "%O%@" );

            # Temporarily save and reset BER::errmsg
            my $ber_last_errmsg = $BER::errmsg;
            $BER::errmsg = undef;
            my $ppo = BER::pretty_print($oid);
            my $ppv = BER::pretty_print($value);

            # Error handling based on $BER::errmsg
            my $ber_errmsg = $BER::errmsg;
            if ( defined $ber_errmsg ) {
                print "$ber_errmsg, $ppo";
                if ( $ber_errmsg eq 'Exception code: noSuchObject' ) {
                    $self->add_varbind_error( $ppo, 'NoSuchObject' );
                }
                elsif ( $ber_errmsg eq 'Exception code: noSuchInstance' ) {
                    $self->add_varbind_error( $ppo, 'NoSuchInstance' );
                }
                elsif ( $ber_errmsg eq 'Exception code: endOfMibView' ) {
                    $self->add_varbind_error( $ppo, 'EndOfMibView' );
                }
                else {
                    $self->add_varbind_error( $ppo, $ber_errmsg );
                }
            }
            else {
                push( @valid_oids, [ $ppo, $ppv ] );
            }
            $i++;
        }

        # Process remaining bindings
        while ( $bindings ne '' ) {
            my ( $binding, $rest ) = BER::decode_sequence($bindings);
            $bindings = $rest;
            my ( $oid, $value ) = BER::decode_by_template( $binding, "%O%@" );

            # Temporarily save and reset BER::errmsg
            my $ber_last_errmsg = $BER::errmsg;
            $BER::errmsg = undef;
            my $ppo = BER::pretty_print($oid);
            my $ppv = BER::pretty_print($value);

            # Error handling based on $BER::errmsg
            my $ber_errmsg = $BER::errmsg;
            if ( defined $ber_errmsg ) {
                print "$ber_errmsg, $ppo";
                if ( $ber_errmsg eq 'Exception code: noSuchObject' ) {
                    $self->add_varbind_error( $ppo, 'NoSuchObject' );
                }
                elsif ( $ber_errmsg eq 'Exception code: noSuchInstance' ) {
                    $self->add_varbind_error( $ppo, 'NoSuchInstance' );
                }
                elsif ( $ber_errmsg eq 'Exception code: endOfMibView' ) {
                    $self->add_varbind_error( $ppo, 'EndOfMibView' );
                }
                else {
                    $self->add_varbind_error( $ppo, $ber_errmsg );
                }
            }
            else {
                push( @valid_oids, [ $ppo, $ppv ] );
            }
            $i++;
        }

        # Return the valid OIDs (array or array reference depending on the context)
        return wantarray ? @valid_oids : \@valid_oids;
    }
    else {
        # Handle SNMP error if GETBULK fails
        $self->_handle_snmp_error();
        return wantarray ? () : undef;
    }
}

sub getnext_snmp {
    my ( $self, $query_params, @oids ) = @_;
    my $session = $self->_ensure_session($query_params);
    unless ( defined $session ) {
        return wantarray ? () : undef;
    }
    my @varbind_errors;

    # Ensure $oids is an array of oids
    if ( @oids == 1 && ref $oids[ 0 ] eq 'ARRAY' ) {
        @oids = @{ $oids[ 0 ] };
    }

    # Encode OIDs for SNMP reques
    my @encoded_oids = map { BER::encode_oid( split( /\./, $_ ) ) } @oids;

    # Early return on no valid OIDs
    unless (@encoded_oids) {
        $self->_handle_snmp_error("No valid OIDs provided for SNMP GETNEXT");
        return wantarray ? () : undef;
    }

    # Perform GETNEXT request and process the response
    if ( $session->getnext_request_response(@encoded_oids) ) {
        my ($bindings) = $session->decode_get_response( $session->pdu_buffer );

        # Early return on failure
        unless ( defined $bindings ) {
            $self->_handle_snmp_error("Failed to decode SNMP response");
            return wantarray ? () : undef;
        }
        my @valid_oids;
        my $i = 0;
        while ( $bindings ne '' ) {
            my ( $binding, $rest ) = BER::decode_sequence($bindings);
            $bindings = $rest;
            my ( $oid, $val ) = BER::decode_by_template( $binding, "%O%@" );
            my $ppo = BER::pretty_print($oid);

            # Temporarily save and reset BER::errmsg
            my $ber_last_errmsg = $BER::errmsg;
            $BER::errmsg = undef;
            my $ppv        = BER::pretty_print($val);
            my $ber_errmsg = $BER::errmsg;

            # Error handling based on $BER::errmsg
            if ( defined $ber_errmsg ) {
                if ( $ber_errmsg eq 'Exception code: noSuchObject' ) {
                    $self->add_varbind_error( $ppo, 'NoSuchObject' );
                }
                elsif ( $ber_errmsg eq 'Exception code: noSuchInstance' ) {
                    $self->add_varbind_error( $ppo, 'NoSuchInstance' );
                }
                elsif ( $ber_errmsg eq 'Exception code: endOfMibView' ) {
                    $self->add_varbind_error( $ppo, 'EndOfMibView' );
                }
                else {
                    $self->add_varbind_error( $ppo, $ber_errmsg );
                }
            }
            else {
                push( @valid_oids, [ $ppo, $ppv ] );
            }
            $i++;
        }
        return wantarray ? @valid_oids : \@valid_oids;
    }
    else {
        # Handle SNMP error if GETNEXT fails
        $self->_handle_snmp_error();
        return wantarray ? () : undef;
    }
}

# Perform SNMP GET request and process the response
sub get_snmp {
    my ( $self, $query_params, @oids ) = @_;
    my $session = $self->_ensure_session($query_params);
    unless ( defined $session ) {
        return wantarray ? () : undef;
    }

    # Ensure @oids is correctly formatted (array reference)
    if ( @oids == 1 && ref $oids[ 0 ] eq 'ARRAY' ) {
        @oids = @{ $oids[ 0 ] };
    }

    # Encode OIDs for SNMP request
    my @encoded_oids = map { BER::encode_oid( split( /\./, $_ ) ) } @oids;

    # Early return on no valid OIDs
    unless (@encoded_oids) {
        $self->_handle_snmp_error("No valid OIDs provided for SNMP GET");
        return wantarray ? () : undef;
    }

    # Perform GET request and process the response
    if ( $session->get_request_response(@encoded_oids) ) {

        # Decode SNMP response
        my $session = $self->{session};
        my @varbind_errors;
        my ($bindings) = $session->decode_get_response( $session->pdu_buffer );

        # Early return on failure
        unless ( defined $bindings ) {
            $self->_handle_snmp_error("Failed to decode SNMP response");
            return wantarray ? () : undef;
        }
        my @valid_oids;
        my $i = 0;
        while ( $bindings ne '' ) {
            my ( $binding, $rest ) = BER::decode_sequence($bindings);
            $bindings = $rest;
            my ( $oid, $val ) = BER::decode_by_template( $binding, "%O%@" );
            my $ppo = BER::pretty_print($oid);

            # Temporarily save and reset BER::errmsg
            my $ber_last_errmsg = $BER::errmsg;
            $BER::errmsg = undef;
            my $ppv        = BER::pretty_print($val);
            my $ber_errmsg = $BER::errmsg;

            # Error handling based on $BER::errmsg
            if ( defined $ber_errmsg ) {
                if ( $ber_errmsg eq 'Exception code: noSuchObject' ) {
                    $self->add_varbind_error( $ppo, 'NoSuchObject' );
                }
                elsif ( $ber_errmsg eq 'Exception code: noSuchInstance' ) {
                    $self->add_varbind_error( $ppo, 'NoSuchInstance' );
                }
                elsif ( $ber_errmsg eq 'Exception code: endOfMibView' ) {
                    $self->add_varbind_error( $ppo, 'EndOfMibView' );
                }
                else {
                    $self->add_varbind_error( $ppo, $ber_errmsg );
                }
            }
            else {
                push( @valid_oids, [ $ppo, $ppv ] );
            }
            $i++;
        }

        # Return valid OIDs as array or reference based on context
        return wantarray ? @valid_oids : \@valid_oids;
    }
    else {
        # Handle SNMP error if GET request fails
        $self->_handle_snmp_error();
        return wantarray ? () : undef;
    }
}

sub pretty_oid ($) {
    my ($oid) = shift;
    my ( $result, $subid, $next );
    my (@oid);
    $result = ord( substr( $oid, 0, 1 ) );
    return BER::error("Object ID expected") unless $result == BER::object_id_tag;
    ( $result, $oid ) = BER::decode_length( $oid, 1 );
    return BER::error("inconsistent length in OID") unless $result == length $oid;
    @oid   = ();
    $subid = ord( substr( $oid, 0, 1 ) );
    push @oid, int( $subid / 40 );
    push @oid, $subid % 40;
    $oid = substr( $oid, 1 );

    while ( $oid ne '' ) {
        $subid = ord( substr( $oid, 0, 1 ) );
        if ( $subid < 128 ) {
            $oid = substr( $oid, 1 );
            push @oid, $subid;
        }
        else {
            $next  = $subid;
            $subid = 0;
            while ( $next >= 128 ) {
                $subid = ( $subid << 7 ) + ( $next & 0x7f );
                $oid   = substr( $oid, 1 );
                $next  = ord( substr( $oid, 0, 1 ) );
            }
            $subid = ( $subid << 7 ) + $next;
            $oid   = substr( $oid, 1 );
            push @oid, $subid;
        }
    }
    '.' . join( '.', @oid );    # Before string a . is added
}
1;
