my %snmp_type_map = (
    'INTEGER'               => { perl_type => 'int',       description => 'Signed 32-bit integer.' },
    'Counter32'             => { perl_type => 'int',       description => '32-bit unsigned integer for counting events.' },
    'Gauge32'               => { perl_type => 'int',       description => 'Unsigned integer that can increase or decrease.' },
    'TimeTicks'             => { perl_type => 'int',       description => 'Unsigned integer representing time in hundredths of a second since device startup.' },
    'Counter64'             => { perl_type => 'Math::BigInt', description => '64-bit unsigned integer for counting events (requires Math::BigInt).' },
    'Opaque'                => { perl_type => 'string',    description => 'Arbitrary byte string with structure defined by the MIB module.' },
    'NsapAddress'           => { perl_type => 'string',    description => 'Network service access point (NSAP) address.' },
    'IpAddress'             => { perl_type => 'string',    description => 'IPv4 or IPv6 network address.' },
    'NetworkAddress'        => { perl_type => 'string',    description => 'Network address (IPv4 or IPv6).' },
    'BITS'                  => { perl_type => 'string',    description => 'Bit field represented as a series of named bits.' },
    'DateAndTime'           => { perl_type => 'string',    description => 'Date and time value.' },
    'CounterBasedGauge64'   => { perl_type => 'Math::BigInt', description => '64-bit unsigned integer for gauging (requires Math::BigInt).' },
    'Unsigned32'            => { perl_type => 'int',       description => 'Unsigned 32-bit integer.' },
    'Unsigned64'            => { perl_type => 'Math::BigInt', description => 'Unsigned 64-bit integer (requires Math::BigInt).' },
    'Null'                  => { perl_type => 'undef',     description => 'Null or non-existent value.' },
    'OBJECT IDENTIFIER'     => { perl_type => 'string',    description => 'Object identifier.' },
    'Counter'               => { perl_type => 'int',       description => 'Deprecated alias for Counter32.' },
    'Counter64'             => { perl_type => 'Math::BigInt', description => 'Deprecated alias for Counter64 (requires Math::BigInt).' },
    'Opaque'                => { perl_type => 'string',    description => 'Deprecated alias for Opaque.' },
    'IpAddress'             => { perl_type => 'string',    description => 'Deprecated alias for NetworkAddress.' },
);


my %oid_to_snmp_type = (
    '1.3.6.1.2.1.1.1.0'  => 'OCTET STRING',       # sysDescr
    '1.3.6.1.2.1.1.2.0'  => 'OBJECT IDENTIFIER',  # sysObjectID
    '1.3.6.1.2.1.1.3.0'  => 'TimeTicks',          # sysUpTime
    '1.3.6.1.2.1.1.4.0'  => 'OCTET STRING',       # sysContact
    '1.3.6.1.2.1.1.5.0'  => 'OCTET STRING',       # sysName
    '1.3.6.1.2.1.1.6.0'  => 'OCTET STRING',       # sysLocation
    '1.3.6.1.2.1.1.7.0'  => 'INTEGER',            # sysServices
    '1.3.6.1.2.1.2.2.1.1' => 'INTEGER',           # ifIndex
    '1.3.6.1.2.1.2.2.1.2' => 'OCTET STRING',      # ifDescr
    '1.3.6.1.2.1.2.2.1.3' => 'INTEGER',           # ifType
    '1.3.6.1.2.1.2.2.1.4' => 'INTEGER',           # ifMtu
    '1.3.6.1.2.1.2.2.1.5' => 'Gauge32',           # ifSpeed
    '1.3.6.1.2.1.2.2.1.6' => 'OCTET STRING',      # ifPhysAddress
    '1.3.6.1.2.1.2.2.1.7' => 'INTEGER',           # ifAdminStatus
    '1.3.6.1.2.1.2.2.1.8' => 'INTEGER',           # ifOperStatus
    '1.3.6.1.2.1.2.2.1.9' => 'TimeTicks',         # ifLastChange
    '1.3.6.1.2.1.2.2.1.10' => 'Counter32',        # ifInOctets
    '1.3.6.1.2.1.2.2.1.11' => 'Counter32',        # ifInUcastPkts
    '1.3.6.1.2.1.2.2.1.12' => 'Counter32',        # ifInNUcastPkts
    '1.3.6.1.2.1.2.2.1.13' => 'Counter32',        # ifInDiscards
    '1.3.6.1.2.1.2.2.1.14' => 'Counter32',        # ifInErrors
    '1.3.6.1.2.1.2.2.1.15' => 'Counter32',        # ifInUnknownProtos
    '1.3.6.1.2.1.2.2.1.16' => 'Counter32',        # ifOutOctets
    '1.3.6.1.2.1.2.2.1.17' => 'Counter32',        # ifOutUcastPkts
    '1.3.6.1.2.1.2.2.1.18' => 'Counter32',        # ifOutNUcastPkts
    '1.3.6.1.2.1.2.2.1.19' => 'Counter32',        # ifOutDiscards
    '1.3.6.1.2.1.2.2.1.20' => 'Counter32',        # ifOutErrors
    '1.3.6.1.2.1.2.2.1.21' => 'Gauge32',          # ifOutQLen
    '1.3.6.1.2.1.31.1.1.1.1' => 'INTEGER',        # ifName
    '1.3.6.1.2.1.31.1.1.1.2' => 'OCTET STRING',   # ifInMulticastPkts
    '1.3.6.1.2.1.31.1.1.1.3' => 'OCTET STRING',   # ifInBroadcastPkts
    '1.3.6.1.2.1.31.1.1.1.4' => 'OCTET STRING',   # ifOutMulticastPkts
    '1.3.6.1.2.1.31.1.1.1.5' => 'OCTET STRING',   # ifOutBroadcastPkts
    '1.3.6.1.2.1.31.1.1.1.6' => 'Counter32',       # ifHCInOctets
    '1.3.6.1.2.1.31.1.1.1.7' => 'Counter32',       # ifHCInUcastPkts
    '1.3.6.1.2.1.31.1.1.1.8' => 'Counter32',       # ifHCInMulticastPkts
    '1.3.6.1.2.1.31.1.1.1.9' => 'Counter32',       # ifHCInBroadcastPkts
    '1.3.6.1.2.1.31.1.1.1.10' => 'Counter32',      # ifHCOutOctets
    '1.3.6.1.2.1.31.1.1.1.11' => 'Counter32',      # ifHCOutUcastPkts
    '1.3.6.1.2.1.31.1.1.1.12' => 'Counter32',      # ifHCOutMulticastPkts
    '1.3.6.1.2.1.31.1.1.1.13' => 'Counter32',      # ifHCOutBroadcastPkts
    '1.3.6.1.2.1.31.1.1.1.14' => 'Gauge32',        # ifHighSpeed
    '1.3.6.1.2.1.31.1.1.1.15' => 'Counter64',      # ifPromiscuousMode
    '1.3.6.1.4.1.2021.4.3.0' => 'OCTET STRING',    # hrSystemUptime
    '1.3.6.1.4.1.2021.10.1.3.1' => 'INTEGER',      # laLoadInt
    '1.3.6.1.4.1.2021.10.1.3.2' => 'INTEGER',      # laLoadFloat
    '1.3.6.1.4.1.2021.10.1.3.3' => 'INTEGER',      # laLoadFloat5
    '1.3.6.1.4.1.2021.10.1.3.4' => 'INTEGER',      # laLoadFloat15
    '1.3.6.1.4.1.2021.4.5.0' => 'OCTET STRING',    # hrSWRunName
    '1.3.6.1.4.1.2021.4.6.0' => 'OCTET STRING',    # hrSWRunPath
    '1.3.6.1.4.1.2021.4.15.0' => 'OCTET STRING',   # hrSWInstalledName
    '1.3.6.1.4.1.2021.4.16.0' => 'OCTET STRING',   # hrSWInstalledID
);

