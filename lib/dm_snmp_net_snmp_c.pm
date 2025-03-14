package dm_snmp_net_snmp_c;
use strict;
use warnings;
use lib '.';
use POSIX qw(strerror);
use SNMP;
use Data::Dumper;
use dm_snmp_utils qw(add_varbind_error add_error get_varbind_errors get_errors);
use File::Basename;

# ✅ Constructor: Create an SNMP object
sub new {
    my ( $class, $params_ref ) = @_;
    my $oid_has_prefix_dot = 0;
    my $oid_prefix;
    if ($oid_has_prefix_dot) {
        *_build_snmp_results = \&dm_snmp_net_snmp_c_w_dot::_build_snmp_results;
        $oid_prefix          = ".";
    }
    else {
        *_build_snmp_results = \&dm_snmp_net_snmp_c_wo_dot::_build_snmp_results;
        $oid_prefix          = "";
    }

    # Store the parameters needed for the session.
    my $self = {
        host         => $params_ref->{host},
        community    => $params_ref->{community},
        version      => $params_ref->{version},
        port         => $params_ref->{port},
        timeout      => $params_ref->{timeout},
        retries      => $params_ref->{retries},
        secname      => $params_ref->{secname},
        seclevel     => $params_ref->{seclevel},
        authproto    => $params_ref->{authproto},
        authpass     => $params_ref->{authpass},
        privproto    => $params_ref->{privproto},
        privpass     => $params_ref->{privpass},
        usenumeric   => 1,
        uselongnames => 0,
        oid_prefix   => $oid_prefix,
        session      => undef,                      # session will be created later
    };
    bless $self, $class;
    return $self;
}

sub update {
    my ( $self, $params_ref ) = @_;
    my $session = $self->{session};

    # Update object parameters from the hash reference
    $self->_update_params($params_ref);

    # Return the existing session if valid
    if ( defined $session and ref($session) eq "SNMP::Session" ) {

        # If session exists, use the existing session
        return $session;
    }

    # If no valid session exists, create a new session
    $session = $self->_create_new_session();

    # Assign the new session to the object
    $self->{session} = $session;
    return $self;
}

# Helper to update object parameters from the hash reference
sub _update_params {
    my ( $self, $params_ref ) = @_;
    $self->{$_} = $params_ref->{$_} for keys %{$params_ref};
}

sub _ensure_session {
    my ( $self, $params_ref ) = @_;

    # Initialize errors
    $self->_reset_errors();

    # Update object parameters from the hash reference
    $self->_update_params($params_ref);

    # Return existing session if valid
    my $session = $self->_get_existing_session();
    if ($session) {
        $session = $self->_update_session();
        return $session;
    }

    # Create a new session if none exists or if the existing session is invalid
    $session = $self->_create_new_session();

    # Assign the new session to the object
    $self->{session} = $session;

    # Check if the session is valid
    unless ( defined $self->{session} ) {
        $self->_handle_snmp_error( $session->{ErrorNum} // ( $! + 0 ) );
        return undef;
    }
    return $self->{session};
}

# Helper to reset errors
sub _reset_errors {
    my $self = shift;
    $self->{errors}         = [];
    $self->{varbind_errors} = [];
}

# Helper to get the existing session if valid
sub _get_existing_session {
    my $self    = shift;
    my $session = $self->{session};
    return $session if defined $session and ref($session) eq 'SNMP::Session';
    return undef;
}

# Helper to create a new SNMP session
sub _create_new_session {
    my $self = shift;
    return SNMP::Session->new(

        # Connection/Agent Parameters
        DestHost    => $self->{host},                 # Hostname or IP address of SNMP agent
        Community   => $self->{community},            # SNMP community string (v1/v2c)
        Version     => $self->{version},              # SNMP version: 1, 2, 2c, or 3
        RemotePort  => $self->{port},                 # Remote UDP port
        Timeout     => $self->{timeout} * 1000000,    # Timeout in microseconds
        Retries     => $self->{retries}      // 5,    # Number of retries before failure
        RetryNoSuch => $self->{retry_nosuch} // 0,    # Handle NOSUCH errors (v1 only)

        # SNMP v3 Security Parameters
        SecName          => $self->{secname},             # Security name (v3)
        SecLevel         => $self->{seclevel},            # Security level (v3)
        SecEngineId      => $self->{secengineid},         # Security engine ID (v3)
        ContextEngineId  => $self->{contextengineid},     # Context engine ID (v3)
        Context          => $self->{context} // '',       # Context name (v3)
        AuthProto        => $self->{authproto},           # Authentication protocol (v3)
        AuthPass         => $self->{authpass},            # Authentication passphrase (v3)
        PrivProto        => $self->{privproto},           # Privacy protocol (v3)
        PrivPass         => $self->{privpass},            # Privacy passphrase (v3)
        AuthMasterKey    => $self->{authmasterkey},       # SNMPv3 USM auth master key
        PrivMasterKey    => $self->{privmasterkey},       # SNMPv3 USM priv master key
        AuthLocalizedKey => $self->{authlocalizedkey},    # SNMPv3 USM auth localized key
        PrivLocalizedKey => $self->{privlocalizedkey},    # SNMPv3 USM priv localized key

        # Optional formatting options
        VarFormats     => $self->{varformats},                                   # Hash ref for variable-specific formatting
        TypeFormats    => $self->{typeformats},                                  # Hash ref for type-specific formatting
        UseLongNames   => $self->{uselongnames}   // $SNMP::use_long_names,      # Use long OID names
        UseSprintValue => $self->{usesprintvalue} // $SNMP::use_sprint_value,    # Format return values
        UseEnums       => $self->{useenums}       // $SNMP::use_enums,           # Convert integer return values to enums
        UseNumeric     => $self->{usenumeric}     // $SNMP::use_numeric,         # Return numeric OIDs

        # OID Parsing and Bulkwalk Options
        BestGuess     => $self->{bestguess}     // $SNMP::best_guess,            # Tag parsing behavior
        NonIncreasing => $self->{nonincreasing} // $SNMP::non_increasing,        # Non-increasing OIDs in bulkwalk
    );
}

sub _update_session {
    my $self = shift;

    # Special case for DestHost (IP + port)
    if ( defined $self->{session}->{DestHost} && defined $self->{host} ) {
        my ( $session_ip, $session_port ) = split /:/, $self->{session}->{DestHost};
        my ( $self_ip,    $self_port )    = split /:/, $self->{host};

        # Compare IP and port
        if ( $session_ip ne $self_ip || ( defined $session_port && defined $self_port && $session_port ne $self_port ) ) {

            #print "Mismatch found for DestHost IP: $session_ip != $self_ip\n";
            #print "Mismatch found for DestHost Port: $session_port != $self_port\n";
            $self->{session} = undef;               # Invalidate session if mismatch is found
            return $self->_create_new_session();    # Return new session immediately
        }
    }

    # Special case for Timeout (microseconds to seconds)
    if ( defined $self->{session}->{Timeout} && defined $self->{timeout} ) {
        my $session_timeout = $self->{session}->{Timeout} / 1000000;    # Convert microseconds to seconds
        if ( $session_timeout ne $self->{timeout} ) {

            #print "Mismatch found for Timeout: $session_timeout != $self->{timeout}\n";
            $self->{session} = undef;                                   # Invalidate session if mismatch is found
            return $self->_create_new_session();                        # Return new session immediately
        }
    }

    # Define the mapping of session keys to self keys for regular comparison
    my %key_mapping = (
        Community  => 'community',
        Retries    => 'retries',
        Version    => 'version',
        SecName    => 'secname',
        AuthProto  => 'authproto',
        AuthPass   => 'authpass',
        PrivProto  => 'privproto',
        PrivPass   => 'privpass',
        RemotePort => 'port',        # RemotePort to port
    );

    # Loop through each key and compare session value with the corresponding $self value
    while ( my ( $session_key, $self_key ) = each %key_mapping ) {

        # Skip comparison if $self->{$self_key} is not defined or does not exist
        next unless defined $self->{$self_key};
        if ( $self->{session}->{$session_key} ne $self->{$self_key} ) {

            #print "Mismatch found for $session_key: $self->{session}->{$session_key} != $self->{$self_key}\n";
            $self->{session} = undef;               # Invalidate session if mismatch is found
            return $self->_create_new_session();    # Return new session immediately
        }
    }

    # Return the existing session if no mismatch found
    return $self->{session};
}

sub _handle_snmp_error {
    my ( $self, $code, $oids_ref ) = @_;
    my $session = $self->{session};
    if ( $session->{ErrorNum} ) {
        if ( $session->{ErrorNum} == 2 && defined $session->{ErrorInd} && $session->{ErrorInd} > 0 ) {
            my $error_index = $self->{session}->{ErrorInd} - 1;
            $self->add_varbind_error( $oids_ref->[ $error_index ], "noSuchName" );
            return wantarray ? () : undef;
        }
    }
    elsif ( !$code ) {
        $code = -1;
    }
    my %error_data = (
        device    => $self->{session}->{DestHost}  // $self->{device},
        community => $self->{session}->{Community} // $self->{community},
        retries   => $self->{session}->{Retries}   // $self->{retries},
        timeout   => ( $self->{session}->{Timeout} // ( $self->{timeout} * 100000 ) ) / 100000,
        version   => $self->{session}->{Version} // $self->{version},
        secname   => $self->{session}->{SecName} // $self->{secname},

        #        seclevel  => $self->{session}->{SecLvel}   // $self->{seclevel},
        authproto => $self->{session}->{AuthProto} // $self->{authproto},
        authpass  => $self->{session}->{AuthPass}  // $self->{authpass},
        privproto => $self->{session}->{PrivProto} // $self->{privproto},
        privpass  => $self->{session}->{PrivPass}  // $self->{privpass},
        file      => basename( ( caller(1) )[ 1 ] ),
        line      => ( caller(1) )[ 2 ],
        sub       => ( caller(1) )[ 3 ],
    );
    $self->add_error( $code, %error_data );

    # Return the error code
    return $code;
}

# ✅ Perform SNMP GET Operation
sub get_snmp {
    my ( $self, $query_params, @oids ) = @_;
    my $session = $self->_ensure_session($query_params);
    unless ( defined $session and ref($session) eq "SNMP::Session" ) {
        return wantarray ? () : undef;
    }
    if ( @oids == 1 && ref $oids[ 0 ] eq 'ARRAY' ) {
        @oids = @{ $oids[ 0 ] };
    }

    # Create a VarList from the provided OIDs
    my $varlist = SNMP::VarList->new( map { [ $_ ] } @oids );

    # Execute SNMP GET directly (without capturing the response)
    $session->get($varlist);
    if ( $session->{ErrorNum} ) {
        $self->_handle_snmp_error( $session->{ErrorNum}, \@oids );
        return wantarray ? () : undef;
    }

    # Build and return the results from the helper subroutine
    return $self->_build_snmp_results($varlist);
}

sub getnext_snmp {
    my ( $self, $query_params, @oids ) = @_;
    my $session = $self->_ensure_session($query_params);
    unless ( defined $session and ref($session) eq "SNMP::Session" ) {
        return wantarray ? () : undef;
    }
    if ( @oids == 1 && ref $oids[ 0 ] eq 'ARRAY' ) {
        @oids = @{ $oids[ 0 ] };
    }

    # If there's only one OID and it's exactly '.1.3.6.1.2.1.1.1'
    if ( $session->{Version} eq 3 && @oids == 1 && $oids[ 0 ] eq '1.3.6.1.2.1.1.1' ) {

        # Special handling for '.1.3.6.1.2.1.1.1'
        # Construct the Perl script for SNMP getnext
        my $snmp_disco = <<EOF;
perl -e '
use SNMP;
my \$sess = new SNMP::Session(
    DestHost => "$session->{DestHost}", 
    Timeout => "$session->{Timeout}", 
    Retries => "$session->{Retries}", 
    UseNumeric => "$session->{UseNumeric}", 
    NonIncreasing => "$session->{NonIncreasing}", 
    Version => "$session->{Version}", 
    Community => "$session->{Community}", 
    SecName => "$session->{SecName}", 
    SecLevel => "$session->{SecLevel}", 
    AuthProto => "$session->{AuthProto}", 
    AuthPass => "$session->{AuthPass}", 
    PrivProto => "$session->{PrivProto}", 
    PrivPass => "$session->{PrivPass}"
);
print \$sess->getnext(".1.3.6.1.2.1.1.1");
'
EOF

        # Execute the Perl script and capture the result
        my $disco_result = `$snmp_disco`;
        if ( $disco_result eq '' ) {
            $self->_handle_snmp_error( -24, \@oids );
            return wantarray ? () : undef;
        }

        # You can process the result here if necessary
        # Example: return the result or log it
        return [ '1.3.6.1.2.1.1.1.0', $disco_result ];
    }

    # Normal handling for other OIDs
    my $varlist = SNMP::VarList->new( map { [ $_ ] } @oids );

    # Execute SNMP GETNEXT
    $session->getnext($varlist);
    if ( $session->{ErrorNum} ) {
        $self->_handle_snmp_error( $session->{ErrorNum}, \@oids );
        return wantarray ? () : undef;
    }

    # Build results and return
    return $self->_build_snmp_results($varlist);
}

# ✅ Perform SNMP GETNEXT Operation
sub getnext_snmp1 {
    my ( $self, $query_params, @oids ) = @_;
    my $session = $self->_ensure_session($query_params);
    unless ( defined $session and ref($session) eq "SNMP::Session" ) {
        return wantarray ? () : undef;
    }
    if ( @oids == 1 && ref $oids[ 0 ] eq 'ARRAY' ) {
        @oids = @{ $oids[ 0 ] };
    }

    # Create a VarList from the provided OIDs
    my $varlist = SNMP::VarList->new( map { [ $_ ] } @oids );

    # Execute SNMP GETNEXT
    $session->getnext($varlist);
    if ( $session->{ErrorNum} ) {
        $self->_handle_snmp_error( $session->{ErrorNum}, \@oids );
        return wantarray ? () : undef;
    }

    # Build results using the helper subroutine
    return $self->_build_snmp_results($varlist);
}

# ✅ Perform SNMP GETBULK Operation
sub getbulk_snmp {
    my ( $self, $query_params, $non_repeaters, $max_repetitions, @oids ) = @_;
    my $session = $self->_ensure_session($query_params);
    unless ( defined $session and ref($session) eq "SNMP::Session" ) {
        return wantarray ? () : undef;
    }
    if ( @oids == 1 && ref $oids[ 0 ] eq 'ARRAY' ) {
        @oids = @{ $oids[ 0 ] };
    }

    # Create a VarList object for SNMP request
    my $varlist = SNMP::VarList->new( map { [ $_ ] } @oids );

    # Execute SNMP GETBULK
    $session->getbulk(
        $non_repeaters,
        $max_repetitions,
        $varlist    # VarList
    );
    if ( $session->{ErrorNum} ) {
        $self->_handle_snmp_error( $session->{ErrorNum}, \@oids );
        return wantarray ? () : undef;
    }

    # Build and return the results from the helper subroutine
    return $self->_build_snmp_results($varlist);
}

package dm_snmp_net_snmp_c_wo_dot;
use strict;
use warnings;
use Data::Dumper;

sub _build_snmp_results {
    my ( $self, $varlist ) = @_;
    my @valid_oids;    # Array of valid OID/value pairs
                       # Iterate over each varbind in the varlist
    for my $varbind (@$varlist) {
        my $base_oid = $varbind->tag();
        my $iid      = $varbind->iid();
        my $val      = $varbind->val();
        my $type     = $varbind->type();

        # Construct the full OID by appending the instance identifier if defined
        my $full_oid = ( defined $iid && $iid ne "" ) ? "$base_oid.$iid" : $base_oid;
        $full_oid = substr( $full_oid, 1 );
        $val      = substr( $val,      1 ) if $type eq 'OBJECTID';

        # Check for error-indicating values and add them as varbind errors
        if ( $val eq "NOSUCHOBJECT" ) {
            $self->add_varbind_error( $full_oid, "NoSuchObject" );
            next;
        }
        elsif ( $val eq "NOSUCHINSTANCE" ) {
            $self->add_varbind_error( $full_oid, "NoSuchInstance" );
            next;
        }
        elsif ( $val eq "ENDOFMIBVIEW" ) {
            $self->add_varbind_error( $full_oid, "EndOfMibView" );
            next;
        }
        else {
            push @valid_oids, [ $full_oid, $val ];
        }
    }

    # Return a reference to the array of valid OIDs/value pairs
    return wantarray ? @valid_oids : \@valid_oids;
}

package dm_snmp_net_snmp_c_w_dot;
use strict;
use warnings;
use Data::Dumper;

sub _build_snmp_results {
    my ( $self, $varlist ) = @_;
    my @valid_oids;    # Array of valid OID/value pairs
    my %seen_oids;     # Track first seen full OIDs
                       # Iterate over each varbind in the varlist
    for my $varbind (@$varlist) {
        my $base_oid = $varbind->tag();
        my $iid      = $varbind->iid();
        my $val      = $varbind->val();

        # Construct the full OID by appending the instance identifier if defined
        my $full_oid = ( defined $iid && $iid ne "" ) ? "$base_oid.$iid" : $base_oid;

        # Check for error-indicating values and add them as varbind errors
        if ( $val eq "NOSUCHOBJECT" ) {
            $self->add_varbind_error( $full_oid, "NoSuchObject" );
            next;
        }
        elsif ( $val eq "NOSUCHINSTANCE" ) {
            $self->add_varbind_error( $full_oid, "NoSuchInstance" );
            next;
        }
        elsif ( $val eq "ENDOFMIBVIEW" ) {
            $self->add_varbind_error( $full_oid, "EndOfMibView" );
            next;
        }
        else {
            push @valid_oids, [ $full_oid, $val ];
        }
    }

    # Return a reference to the array of valid OIDs/value pairs
    return wantarray ? @valid_oids : \@valid_oids;
}
1;
