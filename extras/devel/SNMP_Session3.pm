package SNMP_Session3;
require 5.014;
use strict;
use Exporter;
use vars qw(@ISA $VERSION @EXPORT $errmsg
            $suppress_warnings
            $default_avoid_negative_request_ids
            $default_use_16bit_request_ids);
use warnings;
use Socket ;
use Socket qw(getaddrinfo inet_ntop AF_INET AF_INET6);  # Import necessary constants
use Socket6 qw(inet_pton);
use BER '1.05';
use Carp;
use SNMP_Config;
#use SNMP_Error;
use Data::Dumper;
use IO::Socket::IP;
use SNMP_Config qw(set_timeout set_retries set_backoff);

$VERSION = '0.90';

@ISA = qw(Exporter);
@EXPORT = qw(errmsg suppress_warnings recycle_socket ipv6available);

use constant {
    GET_REQUEST      => 0 | context_flag(),
    GETNEXT_REQUEST  => 1 | context_flag(),
    GET_RESPONSE     => 2 | context_flag(),
    GETBULK_REQUEST  => 5 | context_flag(),
    STANDARD_UDP_PORT => 161 ,
};

my $ipv6_addr_len = length(Socket6::pack_sockaddr_in6(161, inet_pton(AF_INET6(), "::1")));

# Default configuration for SNMP session
my $default_debug = 1000;
my $default_timeout = 2.0;
my $default_retries = 5;
my $default_backoff = 1.0;
my $default_max_repetitions = 12;

$SNMP_Session3::default_avoid_negative_request_ids = 0;
$SNMP_Session3::default_use_16bit_request_ids = 0;
$SNMP_Session3::recycle_socket = 0;

# Aliases for old function names (for backward compatibility)
#*get_request_response = \&send_get_request_and_receive_response;
#*getnext_request_response = \&send_getnext_request_and_receive_response;
#*getbulk_request_response = \&send_getbulk_request_and_receive_response;
#*encode_request = \&encode_snmp_request;
#*encode_get_request = \&encode_snmp_get_request;
#*encode_getnext_request = \&encode_snmp_getnext_request;
#*encode_getbulk_request = \&encode_snmp_getbulk_request;
#*decode_get_response = \&decode_snmp_get_response;
#*wait_for_response = \&wait_for_snmp_response;
#*request_response_5 = \&send_request_and_receive_response_with_retries;
#*pretty_address = \&format_ip_address;
#*error = \&handle_snmp_error;
#*error_return = \&return_snmp_error;
#*ber_error = \&handle_ber_error;
#*wrap_request = \&wrap_snmp_request;
#*unwrap_response_5b = \&unwrap_snmp_response;
#*send_query = \&send_snmp_query;
#*sa_equal_p = \&addresses_equal;
#*receive_request = \&receive_snmp_request;
#*decode_request = \&decode_snmp_request;
#*receive_response_3 = \&receive_snmp_response;
#*describe = \&describe_snmp_session;
#*to_string = \&snmp_session_to_string;

# 1. General SNMP Functions
sub encode_request {
    my ($this, $reqtype, $encoded_oids_or_pairs, $i1, $i2) = @_;

    $this->{request_id} = ($this->{request_id} == 0x7fffffff) ? -0x80000000 : $this->{request_id} + 1;
    $this->{request_id} += 0x80000000 if $this->{avoid_negative_request_ids} && $this->{request_id} < 0;
    $this->{request_id} &= 0x0000ffff if $this->{use_16bit_request_ids};

    for my $pair (@{$encoded_oids_or_pairs}) {
        $pair = ref($pair) eq 'ARRAY' ? encode_sequence($pair->[0], $pair->[1]) : encode_sequence($pair, encode_null())
            || return $this->ber_error("encoding error");
    }

    return $this->wrap_request(encode_tagged_sequence($reqtype,
                                                      encode_int($this->{request_id}),
                                                      encode_int($i1 // 0),
                                                      encode_int($i2 // 0),
                                                      encode_sequence(@{$encoded_oids_or_pairs})))
        || return $this->ber_error("encoding request PDU");
}

sub encode_get_request {
    my ($this, @oids) = @_;
    return encode_request($this, GET_REQUEST, \@oids);
}

sub encode_getnext_request {
    my ($this, @oids) = @_;
    return encode_request($this, GETNEXT_REQUEST, \@oids);
}

sub encode_getbulk_request {
    my ($this, $non_repeaters, $max_repetitions, @oids) = @_;
    return encode_request($this, GETBULK_REQUEST, \@oids, $non_repeaters, $max_repetitions);
}

sub decode_get_response {
    my($this, $response) = @_;
    my @rest;
    @{$this->{'unwrapped'}};
}

sub wait_for_response {
    my($this, $timeout) = @_;
    $timeout ||= 10.0;
    my($rin,$win,$ein) = ('','','');
    vec($rin,$this->sockfileno,1) = 1;
    select($rin,$win,$ein,$timeout);
}

# 2. Request-Response Handling
sub get_request_response {
    my($this, @oids) = @_;
    return $this->request_response_5 ($this->encode_get_request (@oids), GET_RESPONSE, \@oids, 1);
}

sub getnext_request_response {
    my($this,@oids) = @_;
    return $this->request_response_5 ($this->encode_getnext_request (@oids), GET_RESPONSE, \@oids, 1);
}

sub getbulk_request_response {
    my($this,$non_repeaters,$max_repetitions,@oids) = @_;
    return $this->request_response_5 ($this->encode_getbulk_request ($non_repeaters,$max_repetitions,@oids), GET_RESPONSE, \@oids, 1);
}

sub request_response_5 {
    my ($this, $req, $response_tag, $oids, $errorp) = @_;
    my $retries = $this->retries;
    my $timeout = $this->timeout;
    my ($nfound, $timeleft);
    return undef unless defined $req;
    $timeleft = $timeout;
    while ($retries > 0) {
        $this->send_query ($req)
            || return $this->error ("send1_query: $!");
        push @{$this->{'capture_buffer'}}, $req
                      if (defined $this->{'capture_buffer'}
                              and ref $this->{'capture_buffer'} eq 'ARRAY');
    wait_for_response:
        ($nfound, $timeleft) = $this->wait_for_response($timeleft);
        if ($nfound > 0) {
            my($response_length);
            $response_length = $this->receive_response_3 ($response_tag, $oids, $errorp, 1);
            if ($response_length) {
                push (@{$this->{'capture_buffer'}},
                      substr($this->{'pdu_buffer'}, 0, $response_length)
                      )
                      if (defined $this->{'capture_buffer'}
                          and ref $this->{'capture_buffer'} eq 'ARRAY');
                return $response_length;
            } elsif (defined ($response_length)) {
                goto wait_for_response;
            } else {
                return undef;
            }
        } else {
            --$retries;
            $timeout *= $this->backoff;
            $timeleft = $timeout;
        }
    }
    push @{$this->{'capture_buffer'}}, ""
        if (defined $this->{'capture_buffer'}
            and ref $this->{'capture_buffer'} eq 'ARRAY');
    return $this->error ("no response received");
}

# 3. Utility Functions
sub pretty_address {
    my($addr) = shift;
    my($port, $addrunpack, $addrstr);

    if( (defined $ipv6_addr_len) && (length $addr == $ipv6_addr_len)) {
        ($port,$addrunpack) = Socket6::unpack_sockaddr_in6 ($addr);
        $addrstr = inet_ntop (AF_INET6(), $addrunpack);
    } else {
        ($port,$addrunpack) = unpack_sockaddr_in ($addr);
        $addrstr = inet_ntoa ($addrunpack);
    }

    return sprintf ("[%s].%d", $addrstr, $port);
}

# 4. Session Management Functions
sub open {
    my (
        $this, $remote_hostname, $community, $port, $max_pdu_len, $local_port,
        $max_repetitions, $local_hostname, $ipv4only
    ) = @_;

    $ipv4only = 1 unless defined $ipv4only;
    $community = 'public' unless defined $community;
    $port = STANDARD_UDP_PORT unless defined $port;
    $max_pdu_len = 8000 unless defined $max_pdu_len;
    $max_repetitions = $default_max_repetitions unless defined $max_repetitions;

    my $family = $ipv4only ? AF_INET : ($SNMP_Session3::ipv6available ? AF_UNSPEC : AF_INET);

    my ($err, @res) = getaddrinfo($remote_hostname, $port, { family => $family, socktype => SOCK_DGRAM });
    die "Cannot getaddrinfo - $err" if $err;

    my ($sockfamily, $remote_addr, $socket);
    foreach my $ai (@res) {
        $sockfamily = $ai->{family};
        $remote_addr = $ai->{addr};

        $socket = IO::Socket->new(
            Domain    => $sockfamily,
            Proto     => 17,
            Type      => SOCK_DGRAM,
            LocalAddr => $local_hostname,
            LocalPort => $local_port
        ) or return error_return("creating socket: $!");

        $socket->connect($remote_addr) or next;
        last;
    }

    return error_return("Can't resolve $remote_hostname") unless $socket;

    return bless {
        'sock' => $socket,
        'sockfileno' => fileno($socket),
        'community' => $community,
        'remote_hostname' => $remote_hostname,
        'remote_addr' => $remote_addr,
        'sockfamily' => $sockfamily,
        'max_pdu_len' => $max_pdu_len,
        'pdu_buffer' => '\0' x $max_pdu_len,
        'request_id' => (int(rand 0x10000) << 16) + int(rand 0x10000) - 0x80000000,
        'timeout' => $default_timeout,
        'retries' => $default_retries,
        'backoff' => $default_backoff,
        'debug' => $default_debug,
        'error_status' => 0,
        'error_index' => 0,
        'default_max_repetitions' => $max_repetitions,
        'capture_buffer' => undef,
    };
}

# 5. Error Handling
sub error { return SNMP_Error::error(@_) }
sub error_return { return SNMP_Error::error_return(@_) }
sub ber_error { return SNMP_Error::ber_error(@_) }

# 6. Socket Handling
sub send_query ($$) {
    my ($this,$query) = @_;
    send ($this->sock,$query,0);
}

sub sa_equal_p ($$$) {
    my ($this, $sa1, $sa2) = @_;
    my ($p1,$a1,$p2,$a2);

    if($this->{'sockfamily'} == AF_INET) {
        ($p1,$a1) = unpack_sockaddr_in ($sa1);
        ($p2,$a2) = unpack_sockaddr_in ($sa2);
    } elsif($this->{'sockfamily'} == AF_INET6()) {
        ($p1,$a1) = Socket6::unpack_sockaddr_in6 ($sa1);
        ($p2,$a2) = Socket6::unpack_sockaddr_in6 ($sa2);
    } else {
        return 0;
    }
    use strict "subs";

    if (! $this->{'lenient_source_address_matching'}) {
        return 0 if $a1 ne $a2;
    }
    if (! $this->{'lenient_source_port_matching'}) {
        return 0 if $p1 != $p2;
    }
    return 1;
}

my $dont_wait_flags;
$dont_wait_flags = MSG_DONTWAIT();
$dont_wait_flags = 0;
my %the_socket = ();
$SNMP_Session3::errmsg = '';
#$SNMP_Session3::suppress_warnings = 0;
sub timeout { $_[0]->{timeout} }
sub retries { $_[0]->{retries} }
sub backoff { $_[0]->{backoff} }
sub version { $VERSION; }
sub wrap_request {
    my($this) = shift;
    my($request) = shift;
    encode_sequence (encode_int ($this->snmp_version),
                     encode_string ($this->{community}),
                     $request)
      || return $this->ber_error ("wrapping up request PDU");
}

my @error_status_code = qw(noError tooBig noSuchName badValue readOnly
                           genErr noAccess wrongType wrongLength
                           wrongEncoding wrongValue noCreation
                           inconsistentValue resourceUnavailable
                           commitFailed undoFailed authorizationError
                           notWritable inconsistentName);

sub unwrap_response_5b {
    my ($this,$response,$tag,$oids,$errorp) = @_;
    my ($community,$request_id,@rest,$snmpver);

    ($snmpver,$community,$request_id,
     $this->{error_status},
     $this->{error_index},
     @rest)
        = decode_by_template ($response, "%{%i%s%*{%i%i%i%{%@",
                              $tag);
    return $this->ber_error ("Error decoding response PDU")
      unless defined $snmpver;
    return $this->error ("Received SNMP response with unknown snmp-version field $snmpver")
        unless $snmpver == $this->snmp_version;
    if ($this->{error_status} != 0) {
      if ($errorp) {
        my ($oid, $errmsg);
        $errmsg = $error_status_code[$this->{error_status}] || $this->{error_status};
        $oid = $oids->[$this->{error_index}-1]
          if $this->{error_index} > 0 && $this->{error_index}-1 <= $#{$oids};
        $oid = $oid->[0]
          if ref($oid) eq 'ARRAY';
        return ($community, $request_id,
                $this->error ("Received SNMP response with error code\n"
                              ."  error status: $errmsg\n"
                              ."  index ".$this->{error_index}
                              .(defined $oid
                                ? " (OID: ".&BER::pretty_oid($oid).")"
                                : "")));
      } else {
        if ($this->{error_index} == 1) {
          @rest[$this->{error_index}-1..$this->{error_index}] = ();
        }
      }
    }
    ($community, $request_id, @rest);
}

# New function names
sub receive_response_3 {
    my ($this, $response_tag, $oids, $errorp, $dont_block_p) = @_;
    my ($remote_addr);
    my $flags = 0;
    $flags = $dont_wait_flags if defined $dont_block_p and $dont_block_p;
    $remote_addr = recv ($this->sock, $this->{'pdu_buffer'}, $this->max_pdu_len, $flags);
    return $this->error ("receiving response PDU: $!")
        unless defined $remote_addr;
    return $this->error ("short (".length $this->{'pdu_buffer'}
                                      ." bytes) response PDU")
        unless length $this->{'pdu_buffer'} > 2;

    my $response = $this->{'pdu_buffer'};

    if (defined $this->{'remote_addr'}) {
        if (! $this->sa_equal_p ($remote_addr, $this->{'remote_addr'})) {
            if ($this->{'debug'} && !$SNMP_Session3::recycle_socket) {
                carp ("Response came from ".&SNMP_Session3::pretty_address($remote_addr)
                      .", not ".&SNMP_Session3::pretty_address($this->{'remote_addr'}))
                        unless $SNMP_Session3::suppress_warnings;
            }
            return 0;
        }
    }

    $this->{'last_sender_addr'} = $remote_addr;
    my ($response_community, $response_id, @unwrapped)
        = $this->unwrap_response_5b($response, $response_tag, $oids, $errorp);

    if ($response_community ne $this->{community} || $response_id ne $this->{request_id}) {
        if ($this->{'debug'}) {
            carp ("$response_community != $this->{community}")
                unless $SNMP_Session3::suppress_warnings || $response_community eq $this->{community};
            carp ("$response_id != $this->{request_id}")
                unless $SNMP_Session3::suppress_warnings || $response_id == $this->{request_id};
        }
        return 0;
    }

    if (!defined $unwrapped[0]) {
        $this->{'unwrapped'} = undef;
        return undef;
    }
    $this->{'unwrapped'} = \@unwrapped;
    return length $this->pdu_buffer;
}

sub describe {
    my ($this) = shift;
    print $this->to_string(), "\n";
}

sub to_string {
    my ($this) = shift;
    my ($class, $prefix);
    $class = ref($this);
    $prefix = ' ' x (length ($class) + 2);

    return $class
           .(defined $this->{remote_hostname}
             ? " (remote host: \"".$this->{remote_hostname}."\""
             ." ".&SNMP_Session3::pretty_address($this->remote_addr).")"
             : " (no remote host specified)")
           ."\n"
           .$prefix."  community: \"".$this->{'community'}."\"\n"
           .$prefix." request ID: ".$this->{'request_id'}."\n"
           .$prefix."PDU bufsize: ".$this->{'max_pdu_len'}." bytes\n"
           .$prefix."    timeout: ".$this->{timeout}."s\n"
           .$prefix."    retries: ".$this->{retries}."\n"
           .$prefix."    backoff: ".$this->{backoff}.")";
}

#sub snmp_version { 0 } # for v1
sub snmp_version { 1 } # for v2

sub sock { $_[0]->{sock} }
sub sockfileno { $_[0]->{sockfileno} }
sub remote_addr { $_[0]->{remote_addr} }
sub pdu_buffer { $_[0]->{pdu_buffer} }
sub max_pdu_len { $_[0]->{max_pdu_len} }
sub default_max_repetitions {
    defined $_[1]
        ? $_[0]->{default_max_repetitions} = $_[1]
        : $_[0]->{default_max_repetitions}
}
sub debug { defined $_[1] ? $_[0]->{debug} = $_[1] : $_[0]->{debug} }

sub close {
    my($this) = shift;
    # Avoid closing the socket if it may be shared with other session objects.
    if (! exists $the_socket{$this->{sockfamily}}
        or $this->sock ne $the_socket{$this->{sockfamily}}) {
        close ($this->sock) || $this->error ("close: $!");
    }
}
package SNMPv1_Session;
use strict;
use warnings;
use Data::Dumper;
use parent 'SNMP_Session3';  # Inherit from SNMP_Session3


# Override the SNMP version for SNMPv2c (Version 1 for SNMPv2c)
sub snmp_version {
    return 0;  # Return version 1 for SNMPv2c
}

# Overriding the open method to create an SNMP session
sub open {
    SNMP_Session3::version(0);
    my $session = SNMP_Session3::open(@_);  # Call the open method from SNMP_Session3
    return bless $session;  # Bless the session and return it

}


package SNMPv2c_Session;
use strict;
use warnings;
use Data::Dumper;
use parent 'SNMP_Session3';  # Inherit from SNMP_Session3


# Override the SNMP version for SNMPv2c (Version 1 for SNMPv2c)
sub snmp_version {
    return 1;  # Return version 1 for SNMPv2c
}

# Overriding the open method to create an SNMP session
sub open {
    SNMP_Session3::version(1);
    my $session = SNMP_Session3::open(@_);  # Call the open method from SNMP_Session3
    return bless $session;  # Bless the session and return it

}

