package dm_snmp_constants;
use Exporter 'import';

# Define constants using `use constant`
use constant {
    SNMPERR_SUCCESS                      => 0,
    SNMPERR_GENERR                       => -1,
    SNMPERR_BAD_LOCPORT                  => -2,
    SNMPERR_BAD_ADDRESS                  => -3,
    SNMPERR_BAD_SESSION                  => -4,
    SNMPERR_TOO_LONG                     => -5,
    SNMPERR_NO_SOCKET                    => -6,
    SNMPERR_V2_IN_V1                     => -7,
    SNMPERR_V1_IN_V2                     => -8,
    SNMPERR_BAD_REPEATERS                => -9,
    SNMPERR_BAD_REPETITIONS              => -10,
    SNMPERR_BAD_ASN1_BUILD               => -11,
    SNMPERR_BAD_SENDTO                   => -12,
    SNMPERR_BAD_PARSE                    => -13,
    SNMPERR_BAD_VERSION                  => -14,
    SNMPERR_BAD_SRC_PARTY                => -15,
    SNMPERR_BAD_DST_PARTY                => -16,
    SNMPERR_BAD_CONTEXT                  => -17,
    SNMPERR_BAD_COMMUNITY                => -18,
    SNMPERR_NOAUTH_DESPRIV               => -19,
    SNMPERR_BAD_ACL                      => -20,
    SNMPERR_BAD_PARTY                    => -21,
    SNMPERR_ABORT                        => -22,
    SNMPERR_UNKNOWN_PDU                  => -23,
    SNMPERR_TIMEOUT                      => -24,
    SNMPERR_BAD_RECVFROM                 => -25,
    SNMPERR_BAD_ENG_ID                   => -26,
    SNMPERR_BAD_SEC_NAME                 => -27,
    SNMPERR_BAD_SEC_LEVEL                => -28,
    SNMPERR_ASN_PARSE_ERR                => -29,
    SNMPERR_UNKNOWN_SEC_MODEL            => -30,
    SNMPERR_INVALID_MSG                  => -31,
    SNMPERR_UNKNOWN_ENG_ID               => -32,
    SNMPERR_UNKNOWN_USER_NAME            => -33,
    SNMPERR_UNSUPPORTED_SEC_LEVEL        => -34,
    SNMPERR_AUTHENTICATION_FAILURE       => -35,
    SNMPERR_NOT_IN_TIME_WINDOW           => -36,
    SNMPERR_DECRYPTION_ERR               => -37,
    SNMPERR_SC_GENERAL_FAILURE           => -38,
    SNMPERR_SC_NOT_CONFIGURED            => -39,
    SNMPERR_KT_NOT_AVAILABLE             => -40,
    SNMPERR_UNKNOWN_REPORT               => -41,
    SNMPERR_USM_GENERICERROR             => -42,
    SNMPERR_USM_UNKNOWNSECURITYNAME      => -43,
    SNMPERR_USM_UNSUPPORTEDSECURITYLEVEL => -44,
    SNMPERR_USM_ENCRYPTIONERROR          => -45,
    SNMPERR_USM_AUTHENTICATIONFAILURE    => -46,
    SNMPERR_USM_PARSEERROR               => -47,
    SNMPERR_USM_UNKNOWNENGINEID          => -48,
    SNMPERR_USM_NOTINTIMEWINDOW          => -49,
    SNMPERR_USM_DECRYPTIONERROR          => -50,
    SNMPERR_NOMIB                        => -51,
    SNMPERR_RANGE                        => -52,
    SNMPERR_MAX_SUBID                    => -53,
    SNMPERR_BAD_SUBID                    => -54,
    SNMPERR_LONG_OID                     => -55,
    SNMPERR_BAD_NAME                     => -56,
    SNMPERR_VALUE                        => -57,
    SNMPERR_UNKNOWN_OBJID                => -58,
    SNMPERR_NULL_PDU                     => -59,
    SNMPERR_NO_VARS                      => -60,
    SNMPERR_VAR_TYPE                     => -61,
    SNMPERR_MALLOC                       => -62,
    SNMPERR_KRB5                         => -63,
    SNMPERR_PROTOCOL                     => -64,
    SNMPERR_OID_NONINCREASING            => -65,
    SNMPERR_JUST_A_CONTEXT_PROBE         => -66,
    SNMPERR_TRANSPORT_NO_CONFIG          => -67,
    SNMPERR_TRANSPORT_CONFIG_ERROR       => -68,
    SNMPERR_TLS_NO_CERTIFICATE           => -69,
};
use constant NET_SNMP_ERRNO_MESSAGES => {
    SNMPERR_SUCCESS()                      => "No error",
    SNMPERR_GENERR()                       => "Generic error",
    SNMPERR_BAD_LOCPORT()                  => "Invalid local port",
    SNMPERR_BAD_ADDRESS()                  => "Unknown host",
    SNMPERR_BAD_SESSION()                  => "Unknown session",
    SNMPERR_TOO_LONG()                     => "Too long",
    SNMPERR_NO_SOCKET()                    => "No socket",
    SNMPERR_V2_IN_V1()                     => "Cannot send V2 PDU on V1 session",
    SNMPERR_V1_IN_V2()                     => "Cannot send V1 PDU on V2 session",
    SNMPERR_BAD_REPEATERS()                => "Bad value for non-repeaters",
    SNMPERR_BAD_REPETITIONS()              => "Bad value for max-repetitions",
    SNMPERR_BAD_ASN1_BUILD()               => "Error building ASN.1 representation",
    SNMPERR_BAD_SENDTO()                   => "Failure in sendto",
    SNMPERR_BAD_PARSE()                    => "Bad parse of ASN.1 type",
    SNMPERR_BAD_VERSION()                  => "Bad version specified",
    SNMPERR_BAD_SRC_PARTY()                => "Bad source party specified",
    SNMPERR_BAD_DST_PARTY()                => "Bad destination party specified",
    SNMPERR_BAD_CONTEXT()                  => "Bad context specified",
    SNMPERR_BAD_COMMUNITY()                => "Bad community specified",
    SNMPERR_NOAUTH_DESPRIV()               => "Cannot send noAuth/Priv",
    SNMPERR_BAD_ACL()                      => "Bad ACL definition",
    SNMPERR_BAD_PARTY()                    => "Bad Party definition",
    SNMPERR_ABORT()                        => "Session abort failure",
    SNMPERR_UNKNOWN_PDU()                  => "Unknown PDU type",
    SNMPERR_TIMEOUT()                      => "Timeout",
    SNMPERR_BAD_RECVFROM()                 => "Failure in recvfrom",
    SNMPERR_BAD_ENG_ID()                   => "Unable to determine contextEngineID",
    SNMPERR_BAD_SEC_NAME()                 => "No securityName specified",
    SNMPERR_BAD_SEC_LEVEL()                => "Unable to determine securityLevel",
    SNMPERR_ASN_PARSE_ERR()                => "ASN.1 parse error in message",
    SNMPERR_UNKNOWN_SEC_MODEL()            => "Unknown security model in message",
    SNMPERR_INVALID_MSG()                  => "Invalid message (e.g. msgFlags)",
    SNMPERR_UNKNOWN_ENG_ID()               => "Unknown engine ID",
    SNMPERR_UNKNOWN_USER_NAME()            => "Unknown user name",
    SNMPERR_UNSUPPORTED_SEC_LEVEL()        => "Unsupported security level",
    SNMPERR_AUTHENTICATION_FAILURE()       => "Authentication failure (incorrect password, community or key)",
    SNMPERR_NOT_IN_TIME_WINDOW()           => "Not in time window",
    SNMPERR_DECRYPTION_ERR()               => "Decryption error",
    SNMPERR_SC_GENERAL_FAILURE()           => "SCAPI general failure",
    SNMPERR_SC_NOT_CONFIGURED()            => "SCAPI sub-system not configured",
    SNMPERR_KT_NOT_AVAILABLE()             => "Key tools not available",
    SNMPERR_UNKNOWN_REPORT()               => "Unknown Report message",
    SNMPERR_USM_GENERICERROR()             => "USM generic error",
    SNMPERR_USM_UNKNOWNSECURITYNAME()      => "USM unknown security name (no such user exists)",
    SNMPERR_USM_UNSUPPORTEDSECURITYLEVEL() => "USM unsupported security level",
    SNMPERR_USM_ENCRYPTIONERROR()          => "USM encryption error",
    SNMPERR_USM_AUTHENTICATIONFAILURE()    => "USM authentication failure",
    SNMPERR_USM_PARSEERROR()               => "USM parse error",
    SNMPERR_USM_UNKNOWNENGINEID()          => "USM unknown engineID",
    SNMPERR_USM_NOTINTIMEWINDOW()          => "USM not in time window",
    SNMPERR_USM_DECRYPTIONERROR()          => "USM decryption error",
    SNMPERR_NOMIB()                        => "MIB not initialized",
    SNMPERR_RANGE()                        => "Value out of range",
    SNMPERR_MAX_SUBID()                    => "Sub-id out of range",
    SNMPERR_BAD_SUBID()                    => "Bad sub-id in object identifier",
    SNMPERR_LONG_OID()                     => "Object identifier too long",
    SNMPERR_BAD_NAME()                     => "Bad value name",
    SNMPERR_VALUE()                        => "Bad value notation",
    SNMPERR_UNKNOWN_OBJID()                => "Unknown Object Identifier",
    SNMPERR_NULL_PDU()                     => "No PDU in snmp_send",
    SNMPERR_NO_VARS()                      => "Missing variables in PDU",
    SNMPERR_VAR_TYPE()                     => "Bad variable type",
    SNMPERR_MALLOC()                       => "Out of memory (malloc failure)",
    SNMPERR_KRB5()                         => "Kerberos related error",
    SNMPERR_PROTOCOL()                     => "Protocol error",
    SNMPERR_OID_NONINCREASING()            => "OID not increasing",
    SNMPERR_JUST_A_CONTEXT_PROBE()         => "Context probe",
    SNMPERR_TRANSPORT_NO_CONFIG()          => "Configuration data found but the transport can't be configured",
    SNMPERR_TRANSPORT_CONFIG_ERROR()       => "Transport configuration failed",
    SNMPERR_TLS_NO_CERTIFICATE()           => "TLS no certificate",
};

# Export all constants by default
our @EXPORT = qw(
    SNMPERR_SUCCESS
    SNMPERR_GENERR
    SNMPERR_BAD_LOCPORT
    SNMPERR_BAD_ADDRESS
    SNMPERR_BAD_SESSION
    SNMPERR_TOO_LONG
    SNMPERR_NO_SOCKET
    SNMPERR_V2_IN_V1
    SNMPERR_V1_IN_V2
    SNMPERR_BAD_REPEATERS
    SNMPERR_BAD_REPETITIONS
    SNMPERR_BAD_ASN1_BUILD
    SNMPERR_BAD_SENDTO
    SNMPERR_BAD_PARSE
    SNMPERR_BAD_VERSION
    SNMPERR_BAD_SRC_PARTY
    SNMPERR_BAD_DST_PARTY
    SNMPERR_BAD_CONTEXT
    SNMPERR_BAD_COMMUNITY
    SNMPERR_NOAUTH_DESPRIV
    SNMPERR_BAD_ACL
    SNMPERR_BAD_PARTY
    SNMPERR_ABORT
    SNMPERR_UNKNOWN_PDU
    SNMPERR_TIMEOUT
    SNMPERR_BAD_RECVFROM
    SNMPERR_BAD_ENG_ID
    SNMPERR_BAD_SEC_NAME
    SNMPERR_BAD_SEC_LEVEL
    SNMPERR_ASN_PARSE_ERR
    SNMPERR_UNKNOWN_SEC_MODEL
    SNMPERR_INVALID_MSG
    SNMPERR_UNKNOWN_ENG_ID
    SNMPERR_UNKNOWN_USER_NAME
    SNMPERR_UNSUPPORTED_SEC_LEVEL
    SNMPERR_AUTHENTICATION_FAILURE
    SNMPERR_NOT_IN_TIME_WINDOW
    SNMPERR_DECRYPTION_ERR
    SNMPERR_SC_GENERAL_FAILURE
    SNMPERR_SC_NOT_CONFIGURED
    SNMPERR_KT_NOT_AVAILABLE
    SNMPERR_UNKNOWN_REPORT
    SNMPERR_USM_GENERICERROR
    SNMPERR_USM_UNKNOWNSECURITYNAME
    SNMPERR_USM_UNSUPPORTEDSECURITYLEVEL
    SNMPERR_USM_ENCRYPTIONERROR
    SNMPERR_USM_AUTHENTICATIONFAILURE
    SNMPERR_USM_PARSEERROR
    SNMPERR_USM_UNKNOWNENGINEID
    SNMPERR_USM_NOTINTIMEWINDOW
    SNMPERR_USM_DECRYPTIONERROR
    SNMPERR_NOMIB
    SNMPERR_RANGE
    SNMPERR_MAX_SUBID
    SNMPERR_BAD_SUBID
    SNMPERR_LONG_OID
    SNMPERR_BAD_NAME
    SNMPERR_VALUE
    SNMPERR_UNKNOWN_OBJID
    SNMPERR_NULL_PDU
    SNMPERR_NO_VARS
    SNMPERR_VAR_TYPE
    SNMPERR_MALLOC
    SNMPERR_KRB5
    SNMPERR_PROTOCOL
    SNMPERR_OID_NONINCREASING
    SNMPERR_JUST_A_CONTEXT_PROBE
    SNMPERR_TRANSPORT_NO_CONFIG
    SNMPERR_TRANSPORT_CONFIG_ERROR
    SNMPERR_TLS_NO_CERTIFICATE
    NET_SNMP_ERRNO_MESSAGES
);
1;    # Return true to indicate successful loading of the module
