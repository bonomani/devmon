package dm_snmp_utils;
use strict;
use warnings;
use Exporter 'import';
use Data::Dumper;
use Scalar::Util 'looks_like_number';
use POSIX qw(strerror);
use dm_snmp_constants;

# List the subs you want to export on request
our @EXPORT = qw(init_session add_error add_varbind_error get_errors get_varbind_errors hash_to_str);

# Lexically scoped hash to store sessions per library type.
my %sessions;

sub init_session {
    my ( $lib, $session_params_ref ) = @_;

    #if ( exists $sessions{$lib} ) {
    if ( exists $sessions{ $session_params_ref->{host} } ) {
        $sessions{ $session_params_ref->{host} }->update($session_params_ref);
    }
    else {
        if ( $lib eq 'SNMP' ) {
            $sessions{ $session_params_ref->{host} } = dm_snmp_net_snmp_c->new($session_params_ref);
        }
        elsif ( $lib eq 'SNMP_Session' ) {
            $sessions{ $session_params_ref->{host} } = dm_snmp_snmp_session->new($session_params_ref);
        }
        else {
            die "❌ Invalid SNMP Library: $lib";
            return undef;
        }
    }
    return $sessions{ $session_params_ref->{host} };
}

# Méthode pour ajouter une erreur (sous forme de hash) dans errors
sub add_error {
    my ( $self, $code_or_message, %details ) = @_;

    # If the first argument is numeric, treat it as the error code
    my ( $code, $msg );
    if ( looks_like_number($code_or_message) ) {
        $code = $code_or_message;

        # Fetch message from predefined error messages or fall back to POSIX error message
        $msg = NET_SNMP_ERRNO_MESSAGES->{$code} // strerror($code) // "Unknown error";
    }
    else {
        # The first argument is the message and $code is undefined
        $code = undef;
        $msg  = $code_or_message;
    }

    # Ensure `errors` array exists and store the error
    $self->{errors} //= [];
    push @{ $self->{errors} }, {
        code    => $code,
        message => $msg,
        details => \%details,    # Stores additional details
    };
}

# Méthode pour ajouter une erreur varbind (sous forme de tableau) dans varbind_errors
sub add_varbind_error {
    my ( $self, @error_details ) = @_;
    push @{ $self->{varbind_errors} }, [ @error_details ];
}

# Renvoie une référence vers le tableau des erreurs (chaque élément est une référence de hash)
sub get_errors {
    my $self = shift;
    return $self->{errors};
}

# Renvoie une référence vers le tableau des erreurs varbind (chaque élément est une référence de tableau)
sub get_varbind_errors {
    my $self = shift;
    return $self->{varbind_errors};
}

sub hash_to_str {
    my ($hash) = @_;
    return '' unless $hash && %$hash;    # Return empty string if hash is empty or undefined
    return join( ", ", map { "$_: $hash->{$_}" } sort keys %$hash );
}
1;                                       # End of SNMPSessionFactory package
