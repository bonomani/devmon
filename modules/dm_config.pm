package dm_config;
require Exporter;
@ISA    = qw(Exporter);
@EXPORT = qw(initialize sync_servers time_test do_log db_connect
    na nd db_get db_get_array db_do log_fatal oid_sort);
@EXPORT_OK = qw(%c FATAL ERROR WARN INFO DEBUG TRACE);

#    Devmon: An SNMP data collector & page generator for the
#    Xymon network monitoring systems
#    Copyright (C) 2005-2006  Eric Schwimmer
#    Copyright (C) 2007  Francois Lacroix
#
#    $URL: svn://svn.code.sf.net/p/devmon/code/trunk/modules/dm_config.pm $
#    $Revision: 254 $
#    $Id: dm_config.pm 254 2016-03-11 11:45:44Z buchanmilne $
#
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.  Please see the file named
#    'COPYING' that was included with the distrubition for more details.

# The global option hash. Be afraid!
use vars qw(%g);
use constant {
    FATAL => 0,
    ERROR => 1,
    WARN  => 2,
    INFO  => 3,
    DEBUG => 4,
    TRACE => 5,
};

# Modules
use strict;
use warnings;
require dm_tests;
require dm_templates;
use IO::File;
use FindBin;
use Getopt::Long;
use Net::Domain qw(hostfqdn);
use Time::HiRes qw(time gettimeofday);
use POSIX qw(strftime);

use Data::Dumper;
$Data::Dumper::Sortkeys = 1;    # Sort the keys in the output
$Data::Dumper::Deepcopy = 1;    # Enable deep copies of structures
$Data::Dumper::Indent   = 1;    # Output in a reasonable style (but no array indexes)

# Load initial program values; only called once at program init
sub initialize {
    autoflush STDOUT 1;
    %g = (

        # General variables
        'version'    => $_[0],                        # set in main script now
        'homedir'    => $FindBin::Bin,
        'configfile' => "$FindBin::Bin/devmon.cfg",
        'dbfile'     => "$FindBin::Bin/hosts.db",

        #        'daemonize'     => 1,
        'foreground'    => 0,
        'initialized'   => 0,
        'mypid'         => 0,
        'verbose'       => 2,
        'debug'         => 0,
        'oneshot'       => undef,
        'current_cycle' => 0,
        'output'        => undef,
        'shutting_down' => 0,
        'active'        => '',
        'pidfile'       => '',
        'logfile'       => '',
        'hostscfg'      => '',
        'xymontag'      => '',
        'XYMONNETWORK'  => '',
        'nodename'      => '',
        'log'           => '',

        # DB variables
        'dbhost' => '',
        'dbname' => '',
        'dbuser' => '',
        'dbpass' => '',
        'dsn'    => '',
        'dbh'    => '',

        # Xymon combo variables
        'dispserv' => '',
        'msgsize'  => 0,
        'msgsleep' => 0,

        # Control variables
        'my_nodenum'  => 0,
        'cycletime'   => 0,
        'deadtime'    => 0,
        'parent'      => 1,
        'numforks'    => 0,
        'forks'       => {},
        'maxpolltime' => 30,
        'maxreps'     => 10,

        # Statistical vars
        'numdevs'      => 0,
        'numsnmpdevs'  => 0,
        'numtests'     => 0,
        'avgtestsnode' => 0,
        'snmppolltime' => 0,
        'testtime'     => 0,
        'msgxfrtime'   => 0,
        'numclears'    => {},
        'avgpolltime'  => [],

        # SNMP variables
        'snmptimeout'    => 0,
        'snmp_max_tries' => 0,
        'snmpcids'       => '',
        'secnames'       => '',
        'seclevels'      => '',
        'authprotos'     => '',
        'authpasss'      => '',
        'privprotos'     => '',
        'privpasss'      => '',

        # Now our global data subhashes
        'templates'    => {},
        'devices'      => {},
        'dev_hist'     => {},
        'tmp_hist'     => {},
        'hist'         => {},
        'clear_data'   => {},
        'oid'          => {},
        'fails'        => {},
        'max_rep_hist' => {},
        'node_status'  => {},
        'xymon_color'  => {},
        'test_results' => [],

        # User-definable variable controls
        'globals' => {},
        'locals'  => {}
    );

    # Logging
    $g{log_level}[FATAL] = "FATAL";
    $g{log_level}[ERROR] = "ERROR";
    $g{log_level}[WARN]  = "WARN";
    $g{log_level}[INFO]  = "INFO";
    $g{log_level}[DEBUG] = "DEBUG";
    $g{log_level}[TRACE] = "TRACE";

    # Our local options
    # 'set' indicates that the option is a local or a global option, first initialize all value to 0
    # 'case' indicates that the option is sensible to the case, if not it is converted to lower case
    %{ $g{locals} } = (
        'multinode' => {
            'default' => 'no',
            'regex'   => 'yes|no',
            'set'     => 0,
            'case'    => 0
        },
        'hostscfg' => {
            'default' => ( defined $ENV{HOSTSCFG} and $ENV{HOSTSCFG} ne '' ) ? $ENV{HOSTSCFG} : '/home/xymon/server/etc/hosts.cfg',
            'regex'   => '.+',
            'set'     => 0,
            'case'    => 1
        },
        'XYMONNETWORK' => {
            'default' => ( defined $ENV{XYMONNETWORK} and $ENV{XYMONNETWORK} ne '' ) ? $ENV{XYMONNETWORK} : '',
            'regex'   => '\w+',
            'set'     => 0,
            'case'    => 1
        },
        'xymontag' => {
            'default' => 'DEVMON',
            'regex'   => '\w+',
            'set'     => 0,
            'case'    => 1
        },
        'snmpcids' => {
            'default' => 'public,private',
            'regex'   => '\S+',
            'set'     => 0,
            'case'    => 1
        },
        'secnames' => {
            'default' => '',
            'regex'   => '\S+',
            'set'     => 0,
            'case'    => 1
        },
        'seclevels' => {
            'default' => 'noAuthNoPriv,authNoPriv,authPriv',
            'regex'   => '(?:\s*,\s*|\b(?:noAuthNoPriv|authNoPriv|authPriv)\b)+',
            'set'     => 0,
            'case'    => 1
        },
        'authprotos' => {
            'default' => ',MD5,SHA',
            'regex'   => '(?:\s*,\s*||\b(?:MD5|SHA)\b)+',
            'set'     => 0,
            'case'    => 1
        },
        'authpasss' => {
            'default' => '',
            'regex'   => '\S+',
            'set'     => 0,
            'case'    => 1
        },
        'privprotos' => {
            'default' => ',DES,AES',
            'regex'   => '\S+',
            'set'     => 0,
            'case'    => 1
        },
        'privpasss' => {
            'default' => '',
            'regex'   => '\S+',
            'set'     => 0,
            'case'    => 1
        },
        'nodename' => {
            'default' => 'HOSTNAME',
            'regex'   => '[\w\.-]+',
            'set'     => 0,
            'case'    => 1
        },
        'pidfile' => {
            'default' => '/var/run/devmon/devmon.pid',
            'regex'   => '.+',
            'set'     => 0,
            'case'    => 1
        },
        'logfile' => {
            'default' => '/var/log/devmon.log',
            'regex'   => '.*',
            'set'     => 0,
            'case'    => 1
        },
        'dbhost' => {
            'default' => 'localhost',
            'regex'   => '\S+',
            'set'     => 0,
            'case'    => 0
        },
        'dbname' => {
            'default' => 'devmon',
            'regex'   => '\w+',
            'set'     => 0,
            'case'    => 1
        },
        'dbuser' => {
            'default' => 'devmon',
            'regex'   => '\w+',
            'set'     => 0,
            'case'    => 1
        },
        'dbpass' => {
            'default' => 'devmon',
            'regex'   => '\S+',
            'set'     => 0,
            'case'    => 1
        },
        'snmpeng' => {
            'default' => 'auto',    # new: 'snmp' , old: 'session', auto: 'snmp' if available, fallback to 'session'
            'regex'   => '\S+',
            'set'     => 0,
            'case'    => 1
        }
    );

    # Our global options
    %{ $g{globals} } = (
        'dispserv' => {
            'default' => ( defined $ENV{XYMSRV} and $ENV{XYMSRV} ne '' ) ? $ENV{XYMSRV} : 'localhost',
            'regex'   => '\S+',
            'set'     => 0,
            'case'    => 0
        },
        'dispport' => {
            'default' => ( defined $ENV{XYMONDPORT} and $ENV{XYMONDPORT} ne '' ) ? $ENV{XYMONDPORT} : 1984,
            'regex'   => '\d+',
            'set'     => 0,
            'case'    => 0
        },
        'xymondateformat' => {
            'default' => ( defined $ENV{XYMONDATEFORMAT} and $ENV{XYMONDATEFORMAT} ne '' )
            ? $ENV{XYMONDATEFORMAT}
            : '',
            'regex' => '.+',
            'set'   => 0,
            'case'  => 1
        },
        'msgsize' => {
            'default' => 8096,
            'regex'   => '\d+',
            'set'     => 0,
            'case'    => 0
        },
        'msgsleep' => {
            'default' => 10,
            'regex'   => '\d+',
            'set'     => 0,
            'case'    => 0
        },
        'cycletime' => {
            'default' => 60,
            'regex'   => '\d+',
            'set'     => 0,
            'case'    => 0
        },
        'cleartime' => {
            'default' => 0,
            'regex'   => '\d+',
            'set'     => 0,
            'case'    => 0
        },
        'deadtime' => {
            'default' => 60,
            'regex'   => '\d+',
            'set'     => 0,
            'case'    => 0
        },
        'numforks' => {
            'default' => 10,
            'regex'   => '\d+',
            'set'     => 0,
            'case'    => 0
        },
        'maxpolltime' => {
            'default' => 55,
            'regex'   => '\d+',
            'set'     => 0,
            'case'    => 0
        },
        'snmptimeout' => {
            'default' => 15,      # 2 Seems the very mininum, 4 if you use ilo
            'regex'   => '\d+',
            'set'     => 0,
            'case'    => 0
        },
        'snmp_max_tries' => {     # 6 time should be enough
            'default' => 6,
            'regex'   => '\d+',
            'set'     => 0,
            'case'    => 0
        },
    );

    # Set up our signal handlers
    $SIG{INT} = $SIG{QUIT} = $SIG{TERM} = \&quit;
    $SIG{HUP} = \&reopen_log;

    # Parse command line options
    my ( $syncconfig, $synctemps, $resetowner, $readhosts, );
    $syncconfig = $synctemps = $resetowner = $readhosts = 0;
    my ( %match, $hostonly, $poll, $outputs_ref, $logger_ref );

    GetOptions(
        "help|?"                   => \&help,
        "v"                        => sub { $g{verbose} = 1 },
        "vv"                       => sub { $g{verbose} = 2 },
        "vvv"                      => sub { $g{verbose} = 3 },
        "vvvv"                     => sub { $g{verbose} = 4 },
        "vvvvv"                    => sub { $g{verbose} = 5 },
        "noverbose"                => sub { $g{verbose} = 0 },
        "configfile=s"             => \$g{configfile},
        "dbfile=s"                 => \$g{dbfile},
        "foreground"               => \$g{foreground},
        "output:s@"                => \$outputs_ref,
        "1!"                       => \$g{oneshot},
        "match=s%"                 => sub { push( @{ $match{ $_[1] } }, $_[2] ) },
        "hostonly=s"               => \$hostonly,
        "poll=s"                   => \$poll,
        "debug"                    => \$g{debug},
        "log_match:s@"             => \$g{log_match_ref},
        "log_filter:s@"            => \$g{log_filter_ref},
        "trace"                    => \$g{trace},
        "syncconfig"               => \$syncconfig,
        "synctemplates"            => \$synctemps,
        "resetowners"              => \$resetowner,
        "readhostscfg|readbbhosts" => \$readhosts
    ) or usage();

    # Check for non-option args
    if (@ARGV) {
        usage("Non-option arguments are not accepted '@ARGV'");
    }

    # Debug mode
    if ( $g{debug} or $g{verbose} == 4 ) {
        $g{debug}      = 1;
        $g{verbose}    = 4;
        $g{foreground} = 1;
    }

    # Trace mode (a very verbose debug)
    if ( $g{trace} or $g{verbose} == 5 ) {
        $g{debug}      = 1;    # We should a "if debug condition" to speed up treatement
                               # when not in debug mode: so when log level is 4 or 5
        $g{verbose}    = 5;
        $g{foreground} = 1;
    }

    # Check mutually exclusive option
    if ( $syncconfig + $synctemps + $resetowner + $readhosts > 1 ) {
        print "Can't have more than one mutually exclusive option\n\n";
        usage();
    }

    # Now read in our local config info from our file
    read_local_config();

    # Open the log file
    open_log();

    # Autodetect our nodename on user request
    if ( $g{nodename} eq 'HOSTNAME' ) {

        # Remove domain info, if any: NO
        # Xymon best practice is to use fqdn, if the user doesn't want it
        # we assume they have set NODENAME correctly in devmon.cfg
        # $hostname =~ s/\..*//;
        $g{nodename} = hostfqdn();
        do_log( "Nodename autodetected as $g{nodename}", INFO );
    }

    # Make sure we have a nodename
    die "Unable to determine nodename!\n" if !defined $g{nodename} and $g{nodename} =~ /^\S+$/;

    # Set up DB handle
    db_connect(1);

    # Connect to the cluster
    cluster_connect();

    # Read our global variables
    read_global_config();

    # Check our global config
    check_global_config();

    # Check output options
    if ( ( not defined $outputs_ref ) and ( $hostonly or $poll or %match ) ) {    # set -o for options that need it
        ${$outputs_ref}[0] = '';
    }
    if ( not defined $outputs_ref ) {                                             # no -o
        for my $dispsrv ( split /,/, $g{dispserv} ) {
            $g{output}{"xymon://$dispsrv"}{protocol} = 'xymon';
            $g{output}{"xymon://$dispsrv"}{target}   = "$dispsrv";
            $g{output}{"xymon://$dispsrv"}{rrd}      = 1;
            $g{output}{"xymon://$dispsrv"}{stat}     = 1;
        }

    } elsif ( scalar @{$outputs_ref} == 1 and ${$outputs_ref}[0] eq '' ) {        #shortform (no options) -o only
        for my $dispsrv ( split /,/, $g{dispserv} ) {
            $g{output}{"xymon://$dispsrv"}{protocol} = 'xymon';
            $g{output}{"xymon://$dispsrv"}{target}   = "$dispsrv";
            $g{output}{"xymon://$dispsrv"}{rrd}      = 0;
            $g{output}{"xymon://$dispsrv"}{stat}     = 0;
        }
        $g{output}{'xymon://stdout'}{protocol} = 'xymon';
        $g{output}{'xymon://stdout'}{target}   = 'stdout';
        $g{output}{'xymon://stdout'}{rrd}      = 0;
        $g{output}{'xymon://stdout'}{stat}     = 1;
        $g{foreground}                         = 1;
        $g{oneshot}                            = 1 if not defined $g{oneshot};
    } else {
        @{$outputs_ref} = split( /,/, join( ',', @{$outputs_ref} ) );
        my $idx = 0;
        for my $output ( @{$outputs_ref} ) {
            usage( "Duplicate output '" . $output . "'" ) if ( exists $g{output}{$output} );
            ( $g{output}{$output}{protocol}, $g{output}{$output}{target} ) = split '://', $output;
            usage("Invalid output -o (only)")                           if not defined $g{output}{$output}{protocol};
            usage("Unknown protocol '$g{output}{ $output }{protocol}'") if $g{output}{$output}{protocol} !~ '^xymon$';
            usage( "Invalid target in '" . $output . "'" )              if not defined $g{output}{$output}{target};
            if ( $g{output}{$output}{target} eq 'stdout' ) {
            }
        }
    }

    # hostonly mode (deprecated by poll)
    if ($hostonly) {
        do_log( "hostonly is deprecated use '-p[oll]' instead", ERROR );
        if ( defined $poll or %match ) {
            usage("hostonly cannot be set with poll or match, use '-p[oll]' or '-m[atch] only");
        } else {
            $poll = $hostonly if not defined $poll;
        }
    }

    #  Poll mode
    if ($poll) {
        ( my $match_iphost, my $match_test ) = split '=', $poll;
        if ( exists $match{$match_iphost} ) {
            usage("Conflit o=$poll -m iphost=$match_iphost");
        } else {
            push @{ $match{iphost} }, $match_iphost;
        }
        if ( defined $match_test ) {
            if ( exists $match{$match_test} ) {
                usage("Conflit o=$poll -m test=$match_test");
            } else {
                push @{ $match{test} }, $match_test;
            }
        }

    }

    #  Match filter mode
    if (%match) {
        foreach my $match_key ( keys %match ) {
            if ( $match_key eq 'ip' ) {
                $g{match_ip} = join( '|', map {"(?:$_)"} @{ $match{ip} } );
            } elsif ( $match_key eq 'host' ) {
                $g{match_host} = join( '|', map {"(?:$_)"} @{ $match{host} } );
            } elsif ( $match_key eq 'iphost' ) {
                $g{match_iphost} = join( '|', map {"(?:$_)"} @{ $match{iphost} } );
            } elsif ( $match_key eq 'test' ) {
                $g{match_test} = join( '|', map {"(?:$_)"} @{ $match{test} } );
            } elsif ( $match_key eq 'rrd' ) {
                for my $output ( @{ $match{rrd} } ) {
                    if ( exists $g{output}{$output} ) {
                        if ( defined $g{output}{$output}{rrd} ) {
                            usage("Duplicate -m rrd=$output");
                        } else {
                            $g{output}{$output}{rrd} = 1;
                        }
                    } else {
                        usage("$output is not a defined output, set it with -o=$output");
                    }
                }
            } elsif ( $match_key eq 'stat' ) {
                for my $output ( @{ $match{stat} } ) {
                    if ( exists $g{output}{$output} ) {
                        if ( defined $g{output}{$output}{stat} ) {
                            usage("Duplicate -m stat=$output");
                        } else {
                            $g{output}{$output}{stat} = 1;
                        }
                    } else {
                        usage("$output is not a defined output, set it with -o=$output");
                    }
                }
            } else {
                usage( 'Option match, unkown key "' . $match_key . '"' );
            }
        }
    }

    # Debug
    if ( $g{debug} ) {
        for my $output ( keys %{ $g{output} } ) {
            my $cmd_line = "devmon -o=$output";
            if ( $g{output}{$output}{stat} ) {
                $cmd_line .= " -m stat=$output";
            }
            if ( $g{output}{$output}{rrd} ) {
                $cmd_line .= " -m rrd=$output";
            }
            for my $match_iphost ( @{ $match{iphost} } ) {
                $cmd_line .= " -m iphost=$match_iphost";
            }
            for my $match_ip ( @{ $match{ip} } ) {
                $cmd_line .= " -m ip=$match_ip";
            }
            for my $match_host ( @{ $match{host} } ) {
                $cmd_line .= " -m host=$match_host";
            }
            for my $match_test ( @{ $match{test} } ) {
                $cmd_line .= " -m test=$match_test";
            }
            if ( $g{foreground} ) {
                $cmd_line .= " -f";
            }
            if ( $g{trace} ) {
                $cmd_line .= " -t";
            } elsif ( $g{debug} ) {
                $cmd_line .= " -de";
            }
            if ( $g{oneshot} ) {
                $cmd_line .= " -1";
            }
            do_log( "$cmd_line", DEBUG );
        }
    }

    # Check mutual exclusions (run-and-die options)
    sync_global_config()           if $syncconfig;
    dm_templates::sync_templates() if $synctemps;
    reset_ownerships()             if $resetowner;

    # check snmp config before snmp discovery
    check_snmp_config();
    read_hosts_cfg() if $readhosts;    #  (run-and-die options)

    # Daemonize if need be
    daemonize();

    # Set our pid
    $g{mypid} = $$;

    # PID file handling
    if ( !$g{foreground} ) {

        # Check to see if a pid file exists
        if ( -e $g{pidfile} ) {

            # One exists, let see if its stale
            my $pid_handle = new IO::File $g{pidfile}, 'r'
                or log_fatal( "Can't read from pid file '$g{pidfile}' ($!).", 0 );

            # Read in the old PID
            my ($old_pid) = <$pid_handle>;
            chomp $old_pid;
            $pid_handle->close;

            # If it exists, die silently
            log_fatal( "Devmon already running, quitting.", 1 ) if kill 0, $old_pid;
        }

        # Now write our pid to the pidfile
        my $pid_handle = new IO::File $g{pidfile}, 'w'
            or log_fatal( "Can't write to pidfile $g{pidfile} ($!)", 0 );
        $pid_handle->print( $g{mypid} );
        $pid_handle->close;
    }

    # Throw out a little info to the log
    do_log( "---Initializing Devmon v$g{version}, pid=$g{mypid}, log level=$g{verbose}---", $g{verbose} );
    do_log( "Logging to $g{logfile}",                                                       WARN ) unless $g{logfile} =~ /^\s*$/ or $g{foreground};
    do_log( "Node#$g{my_nodenum}",                                                          INFO );

    # Dump some configs in debug mode
    if ( $g{debug} ) {
        foreach ( keys %{ $g{globals} } ) {
            do_log( sprintf( "Global %s: %s", $_, $g{$_} ), DEBUG );
        }
        foreach ( keys %{ $g{locals} } ) {
            do_log( sprintf( "Local %s: %s", $_, $g{$_} ), DEBUG );
        }
    }

    # We are now initialized
    $g{initialized} = 1;
}

sub check_snmp_config {

    #$g{maxpolltime} = $g{cycletime} - 10;    # try to optimize (remove completly if it works

    # Check consistency
    # snmptimeout * snmp_max_tries <  maxpolltime
    #if ( $g{snmptimeout} * $g{snmp_max_tries} >= $g{maxpolltime} ) {
    #    do_log( "Consistency check failed: snmptimeout($g{snmptimeout}) * snmp_max_tries($g{snmp_max_tries}) <  maxpolltime($g{maxpolltime}) ", ERROR );
    #}

    # Check SNMP Engine: auto, snmp(first), session(fallback)
    if ( $g{snmpeng} eq 'auto' ) {
        eval { require SNMP; };
        if ($@) {
            do_log( "Net-SNMP is not installed: $@ yum install net-snmp or apt install snmp, trying to fallback to SNMP_Session", WARN );
            eval { require SNMP_Session; };
            if ($@) {
                log_fatal( "ERROR CONF: SNMP_Session is not installed: $@ yum install perl-SNMP_Session.noarch or apt install libsnmp-session-perl, exiting...", 1 );
            } else {
                $g{snmpeng} = 'session';
                do_log( "SNMP_Session $SNMP_Session::VERSION is installed and provides SNMPv1 SNMPv2c ", INFO );
            }

        } else {
            do_log( "Net-SNMP $SNMP::VERSION is installed and provides SNMPv2c and SNMPv3", INFO );
            eval { require SNMP_Session; };
            if ($@) {
                do_log( "SNMP_Session is not installed: $@ yum install perl-SNMP_Session.noarch or apt install libsnmp-session-perl, exiting...", ERROR );
                $g{snmpeng} = 'snmp';
            } else {
                do_log( "SNMP_Session $SNMP_Session::VERSION is installed and provides SNMPv1", INFO );
            }
        }
    } elsif ( $g{snmpeng} eq 'snmp' ) {
        eval { require SNMP; };
        if ($@) {
            log_fatal( "ERROR CONF: Net-SNMP is not installed: $@ yum install net-snmp or apt install snmp, exiting...", 1 );
        } else {
            do_log( "Net-SNMP $SNMP::VERSION is installed and provides SNMPv2c and SNMPv3", INFO );
        }
    } elsif ( $g{snmpeng} eq 'session' ) {
        eval { require SNMP_Session; };
        if ($@) {
            log_fatal( "ERROR CONF: SNMP_Session is not installed: $@ yum install perl-SNMP_Session.noarch or apt install libsnmp-session-perl, exiting...", 1 );
        } else {
            do_log( "SNMP_Session $SNMP_Session::VERSION is installed and provides SNMPv1 and SNMPv2c", INFO );
        }
    } else {
        do_log( "Bad option for snmpeng, should be: 'auto', 'snmp' (Net-SNMP, in C), 'session' (SNMP_Session, pure perl), exiting...", ERROR );
    }
}

sub check_global_config {

    # Check consistency
    # maxpolltime < cycletime
    if ( $g{maxpolltime} >= $g{cycletime} ) {
        do_log( "Consistency check failed: maxpolltime($g{maxpolltime}) < cycletime($g{cycletime}) ", ERROR );
    }
}

# Determine the amount of time we spent doing tests
sub time_test {
    do_log( "Running time_test()", DEBUG ) if $g{debug};

    my $poll_time = $g{snmppolltime} + $g{testtime} + $g{msgxfrtime};

    # Add our current poll time to our history array
    push @{ $g{avgpolltime} }, $poll_time;
    while ( @{ $g{avgpolltime} } > 5 ) {
        shift @{ $g{avgpolltime} }    # Only preserve 5 entries
    }

    # Squak if we went over our poll time
    my $exceeded = $poll_time - $g{cycletime};
    if ( $exceeded > 1 ) {
        do_log( "Exceeded cycle time ($poll_time seconds).", WARN );
        $g{sleep_time} = 0;
        quit(0) if $g{oneshot};

        # Otherwise calculate our sleep time
    } else {
        quit(0) if $g{oneshot};
        $g{sleep_time} = -$exceeded;
        $g{sleep_time} = 0 if $g{sleep_time} < 0;    # just in case!
        do_log( "Sleeping for $g{sleep_time} seconds.", INFO );
        sleep $g{sleep_time} if $g{sleep_time};
    }
}

# Subroutine to reload test data when needed and handle fail-over
sub sync_servers {
    my %device_hash;
    my %available_devices;
    my %test_count;
    my %custom_threshs;
    my %custom_excepts;
    my ( $total_tests, $my_num_tests, $need_init );

    # If we are multinode='no', just load our tests and return
    if ( $g{multinode} ne 'yes' ) {

        my %devices = read_hosts();
        if (%devices) {
            for my $device ( keys %devices ) {
                for my $device_h_key ( keys %{ $devices{$device} } ) {
                    $g{devices}{$device}{$device_h_key} = $devices{$device}{$device_h_key};
                }
            }
        } else {
            usage("Cannot find any machting host in local db '$g{dbfile}'");
        }

        #%{ $g{devices} } = read_hosts();

        # test if there are some hosts
        #if ( not %{ $g{devices} } ) {
        #    usage("Cannot find any machting host in local db '$g{dbfile}'");
        #}
        return;
    }

    # First things first, update heartbeat info
    db_do( "update nodes set heartbeat='" . time . "' where node_num=" . $g{my_nodenum} );

    # Reload our global config
    read_global_config();

    # Read in all node configuration data
    update_nodes();

    # If someone has set our flag to inactive, quietly die
    if ( $g{node_status}{nodes}{ $g{my_nodenum} }{active} ne 'y' ) {
        do_log( "Active flag has been set to a non-true value.  Exiting.", INFO );
        exit 0;
    }

    # See if we need to read our templates
    if ( $g{node_status}{nodes}{ $g{my_nodenum} }{read_temps} eq 'y' ) {
        dm_templates::read_templates();
        $g{node_status}{nodes}{ $g{my_nodenum} }{read_temps} = 'n';
    }

    # We need an init by default, but if anybody has any tests, set to 0
    $need_init = 1;

    %{ $g{devices} } = ();

    # Assume we have 0 tests to begin with
    $my_num_tests = 0;
    $total_tests  = 0;

    # Read in all custom thresholds
    my @threshs = db_get_array('host,test,oid,color,val from custom_threshs');
    for my $this_thresh (@threshs) {
        my ( $host, $test, $oid, $color, $val ) = @$this_thresh;
        $custom_threshs{$host}{$test}{$oid}{$color} = $val;
    }

    # Read in all custom exceptions
    my @excepts = db_get_array('host,test,oid,type,data from custom_excepts');
    for my $this_except (@excepts) {
        my ( $host, $test, $oid, $type, $data ) = @$this_except;
        $custom_excepts{$host}{$test}{$oid}{$type} = $data;
    }

    # Read in all tests for all nodes
    my @tests = db_get_array('name,ip,vendor,model,tests,cid,owner from devices');
    for my $this_test (@tests) {
        my ( $device, $ip, $vendor, $model, $tests, $cid, $owner ) = @$this_test;

        # Make sure we disable our init if someone already has a test
        if ( $owner != 0 ) { $need_init = 0 }

        $device_hash{$device}{ip}     = $ip;
        $device_hash{$device}{vendor} = $vendor;
        $device_hash{$device}{model}  = $model;
        $device_hash{$device}{tests}  = $tests;
        $device_hash{$device}{cid}    = $cid;
        $device_hash{$device}{owner}  = $owner;

        # Do some numerical accounting that we use to load-balance later

        # Determine the number of tests that this host has
        my $dev_tests;
        if ( $tests eq 'all' ) {
            $dev_tests = scalar keys %{ $g{templates}{$vendor}{$model}{tests} };
        } else {
            $dev_tests = ( $tests =~ tr/,/,/ ) + 1;
        }

        $total_tests += $dev_tests;
        $test_count{$device} = $dev_tests;

        # If this test is ours, claim it!
        if ( $owner == $g{my_nodenum} ) {
            $my_num_tests += $dev_tests;
            $g{devices}{$device} = $device_hash{$device};
            %{ $g{devices}{$device}{thresh} } = %{ $custom_threshs{$device} }
                if defined $custom_threshs{$device};
            %{ $g{devices}{$device}{except} } = %{ $custom_excepts{$device} }
                if defined $custom_excepts{$device};
        }

        # If this test doesn't have an owner, lets add it to the available pool
        if ( $owner == 0 or not defined $g{node_status}{active}{$owner} ) {
            push @{ $available_devices{$dev_tests} }, $device;
        }
    }

    # Determine our number of active nodes
    my @active_nodes     = sort na keys %{ $g{node_status}{active} };
    my $num_active_nodes = @active_nodes + 0;

    # Determine the avg number of tests/node
    my $avg_tests_node = $num_active_nodes ? int $total_tests / $num_active_nodes : 0;

    # Now lets see if we need tests
    if ( $my_num_tests < $avg_tests_node ) {

        # First, let evertbody know that we need tests
        my $num_tests_needed = $avg_tests_node - $my_num_tests;
        db_do( "update nodes set need_tests=$num_tests_needed " . "where node_num=$g{my_nodenum}" );

        # Lets see if we need to init, along with the other nodes
        if ($need_init) {
            do_log( "Initializing test database", INFO );

            # Now we need all other nodes waiting for init before we can proceed
            do_log( "Waiting for all nodes to synchronize", INFO );
        INIT_WAIT: while (1) {

                # Make sure our heart beats while we wait
                db_do( "update nodes set heartbeat='" . time . "' where node_num='$g{my_nodenum}'" );

                for my $node ( keys %{ $g{node_status}{active} } ) {
                    next if $node == $g{my_nodenum};
                    if ( $g{node_status}{nodes}{$node}{need_tests} != $avg_tests_node ) {
                        my $name = $g{node_status}{nodes}{$node}{name};

                        # This node isn't ready for init; sleep then try again
                        do_log( "Waiting for node $node($name)", INFO );
                        sleep 2;
                        update_nodes();
                        next INIT_WAIT;
                    }
                }

                # Looks like all nodes are ready, exit the loop
                sleep 2;
                last;
            }
            do_log( "Done waiting", INFO );

            # Now assign all tests using a round-robin technique;  this should
            # synchronize the tests between all servers
            my @available;
            for my $count ( sort nd keys %available_devices ) {
                push @available, @{ $available_devices{$count} };
            }

            @active_nodes     = sort na keys %{ $g{node_status}{active} };
            $num_active_nodes = @active_nodes + 0;
            $avg_tests_node   = int $total_tests / $num_active_nodes;

            my $this_node = 0;
            for my $device (@available) {

                # Skip any test unless the count falls on our node num
                if ( $active_nodes[ $this_node++ ] == $g{my_nodenum} ) {

                    # Make it ours, baby!
                    my $result = db_do("update devices set owner=$g{my_nodenum} where name='$device' and owner=0");

                    # Make sure out DB update went through
                    next if !$result;

                    # Now stick the pertinent data in our variables
                    $my_num_tests += $test_count{$device};
                    $g{devices}{$device} = $device_hash{$device};
                    %{ $g{devices}{$device}{thresh} } = %{ $custom_threshs{$device} }
                        if defined $custom_threshs{$device};
                    %{ $g{devices}{$device}{except} } = %{ $custom_excepts{$device} }
                        if defined $custom_excepts{$device};
                }

                # Make sure we aren't out of bounds
                $this_node = 0 if $this_node > $#active_nodes;
            }

            do_log( "Init complete: $my_num_tests tests loaded, avg $avg_tests_node tests per node", INFO );

            # Okay, we're not at init, so lets see if we can find any available tests
        } else {

            for my $count ( sort nd keys %available_devices ) {

                # Go through all the devices for this test count
                for my $device ( @{ $available_devices{$count} } ) {

                    # Make sure we haven't hit our limit
                    last if $my_num_tests > $avg_tests_node;

                    # Lets try and take this test
                    my $result = db_do("update devices set owner=$g{my_nodenum} where name='$device'");
                    next if !$result;

                    # We got it!  Lets add it to our test_data hash
                    $my_num_tests += $count;
                    my $old_owner = $device_hash{$device}{owner};

                    # Add data to our hashes
                    $g{devices}{$device} = $device_hash{$device};
                    %{ $g{devices}{$device}{thresh} } = %{ $custom_threshs{$device} }
                        if defined $custom_threshs{$device};
                    %{ $g{devices}{$device}{except} } = %{ $custom_excepts{$device} }
                        if defined $custom_excepts{$device};

                    # Log where this device came from
                    if ( $old_owner == 0 ) {
                        do_log( "Got $device ($my_num_tests/$avg_tests_node tests)", INFO );
                    } else {
                        my $old_name = $g{node_status}{nodes}{$old_owner}{name};
                        $old_name = "unknown" if !defined $old_name;
                        do_log( "Recovered $device from node $old_owner($old_name) " . "($my_num_tests/$avg_tests_node tests)", INFO );
                    }

                    # Now lets try and get the history for it, if it exists
                    my @hist_arr = db_get_array( 'ifc,test,time,val from test_data ' . "where host='$device'" );
                    for my $hist (@hist_arr) {
                        my ( $ifc, $test, $time, $val ) = @$hist;
                        $g{dev_hist}{$device}{$ifc}{$test}{val}  = $val;
                        $g{dev_hist}{$device}{$ifc}{$test}{time} = $time;
                    }

                    # Now delete it from the history table
                    db_do("delete from test_data where host='$device'");
                }
            }
        }

        # Now lets update the DB with how many tests we still need
        $num_tests_needed = $avg_tests_node - $my_num_tests;
        $num_tests_needed = 0 if $num_tests_needed < 0;
        db_do( "update nodes set need_tests=$num_tests_needed " . "where node_num=$g{my_nodenum}" );

        # If we don't need any tests, lets see if we can donate any tests
    } elsif ( $my_num_tests > $avg_tests_node ) {

        my $tests_they_need;
        my $biggest_test_needed = 0;

        # Read in the number of needy nodes
        for my $this_node (@active_nodes) {
            next if $this_node == $g{my_nodenum};
            my $this_node_needs = $g{node_status}{nodes}{$this_node}{need_tests};
            $tests_they_need += $this_node_needs;
            $biggest_test_needed = $this_node_needs
                if $this_node_needs > $biggest_test_needed;
        }

        # Now go through the devices and assign any I can
        for my $device ( keys %{ $g{devices} } ) {

            # Make sure this test isn't too big
            next if $test_count{$device} > $biggest_test_needed

                # Now make sure that it won't put us under the avg_nodes
                or $my_num_tests - $test_count{$device} <= $avg_tests_node;

            # Okay, lets assign it to the open pool, then
            my $result = db_do( "update devices set owner=0 where " . "name='$device' and owner=$g{my_nodenum}" );

            # We really shouldn't fail this, but just in case
            next if !$result;
            $my_num_tests -= $test_count{$device};
            do_log( "Dropped $device ($my_num_tests/$avg_tests_node tests)", INFO );

            # Now stick the history for the device in the DB for the recipient
            #        for my $ifc (keys %{$g{dev_hist}{$device}}) {
            #          for my $test (keys %{$g{dev_hist}{$device}{$ifc}}) {
            #            my $val  = $g{dev_hist}{$device}{$ifc}{$test}{val};
            #            my $time = 0;
            #            if(defined $g{dev_hist}{$device}{$ifc}{$test}{time}) {
            #              $time = $g{dev_hist}{$device}{$ifc}{$test}{time};
            #            }
            #
            #            db_do("insert into test_data (host,ifc,test,time,val) " .
            #              "values ('$device','$ifc','$test',$time,'$val')");
            #          }
            #        }

            # Now delete the test from our hash
            delete $g{devices}{$device};
        }
    }

    # Record some statistics
    $g{numtests}     = $my_num_tests;
    $g{avgtestsnode} = $avg_tests_node;
    $g{numdevs}      = scalar keys %{ $g{devices} };
}

# Sub to update node status & configuration
sub update_nodes {

    # Make a copy of our node status
    my %old_status = %{ $g{node_status} };

    %{ $g{node_status} } = ();
    my @nodes = db_get_array( 'name,node_num,active,heartbeat,need_tests,' . 'read_temps from nodes' );

NODE: for my $node (@nodes) {
        my ( $name, $node_num, $active, $heartbeat, $need_tests, $read_temps ) = @$node;
        $g{node_status}{nodes}{$node_num} = {
            'name'       => $name,
            'active'     => $active,
            'heartbeat'  => $heartbeat,
            'need_tests' => $need_tests,
            'read_temps' => $read_temps
        };

        # Check to see if its inactive
        if ( $active ne 'y' ) {
            $g{node_status}{inactive}{$node_num} = 1;
            next NODE;

            # Check to see if this host has died (i.e. exceeded deadtime)
        } elsif ( $heartbeat + $g{deadtime} < time ) {
            do_log( "Node $node_num($name) has died!", INFO )
                if !defined $old_status{dead}{$node_num};
            $g{node_status}{dead}{$node_num} = time;

            # Now check and see if it was previously dead and has returned
        } elsif ( defined $old_status{dead}{$node_num} ) {
            my $up_duration = time - $old_status{dead}{$node_num};
            if ( $up_duration > ( $g{deadtime} * 2 ) ) {
                $g{node_status}{active}{$node_num} = 1;
                do_log( "Node $node_num($name) has returned! " . "Up $up_duration secs", WARN );
            } else {
                $g{node_status}{dead}{$node_num}
                    = $old_status{dead}{$node_num};
            }

            # If it passed, add it to the active sub-hash
        } else {
            $g{node_status}{active}{$node_num} = 1;
        }
    }
}

# Connect our node to the cluster
# Basically this means just updated the nodes table in the database
# So that our node is listed as active and we have a current heartbeat
sub cluster_connect {

    # Don't bother if we aren't multinode
    return if $g{multinode} ne 'yes';

    my $now = time;
    my $nodenum;
    my $nodename = $g{nodename};
    my %nodes;

    # First pull down all our node info to make sure we exist in the table
    my @nodeinfo = db_get_array("name,node_num from nodes");

    for my $row (@nodeinfo) {
        my ( $name, $num ) = @$row;
        $nodes{$num} = $name;
        $nodenum = $num if $name eq $nodename;
    }

    # If we aren't in the table, lets add ourself
    if ( !defined $nodenum ) {

        # Find the next available num
        my $ptr;
        while ( !defined $nodenum ) {
            $nodenum = $ptr if !defined $nodes{ ++$ptr };
        }

        # Do the db add
        db_do("insert into nodes values ('$nodename',$nodenum,'y',$now,0,'n')");

        # If we are in the table, update our activity and heartbeat columns
    } else {
        db_do( "update nodes set active='y', heartbeat=$now " . "where node_num=$nodenum" );
    }

    # Set our global nodenum
    $g{my_nodenum} = $nodenum;
}

# Sub to load/reload global configuration data
sub read_global_config {
    if ( $g{multinode} eq 'yes' ) {
        read_global_config_db();
    } else {
        read_global_config_file();
    }
}

# Read in the local config parameters from the config file
sub read_local_config {

    # Open config file (assuming we can find it)
    my $file = $g{configfile};
    &usage if !defined $file;    # WHY USAGE, WHY OTHER Test next 3!

    if ( $file !~ /^\/.+/ and !-e $file ) {
        my $local_file = $FindBin::Bin . "/$file";
        $file = $local_file if -e $local_file;
    }

    log_fatal( "Can't find config file $file ($!)", 0 ) if !-e $file;
    open FILE, $file or log_fatal( "Can't read config file $file ($!)", 0 );

    do_log( "Reading local options from '$file'", DEBUG ) if $g{debug};

    # Parse file text
    for my $line (<FILE>) {

        # Skip empty lines and comments
        next if $line =~ /^\s*(#.*)?$/;
        chomp $line;
        my ( $option, $value ) = split /\s*=\s*/, $line, 2;

        # Make sure we have option and value
        log_fatal( "Syntax error in config file at line $.", 0 )
            if !defined $option or !defined $value;

        # Options are case insensitive
        $option = lc $option;

        # Skip global options
        next if defined $g{globals}{$option};

        # Croak if this option is unknown
        log_fatal( "Unknown option '$option' in config file, line $.", 0 )
            if !defined $g{locals}{$option};

        # If this option isn't case sensitive, lowercase it
        $value = lc $value if !$g{locals}{$option}{case};

        # Compare to regex, make sure value is valid
        log_fatal( "Invalid value '$value' for '$option' in config file, " . "line $.", 0 )
            if $value !~ /^$g{locals}{$option}{regex}$/;

        # Assign the value to our option
        $g{$option} = $value;
        $g{locals}{$option}{set} = 1;
    }
    close FILE;

    # Log any options not set
    for my $opt ( sort keys %{ $g{locals} } ) {
        if ( $g{locals}{$opt}{set} == 1 ) {
            do_log( "Option '$opt' locally set to: $g{$opt}", DEBUG ) if $g{debug};
            next;
        } else {
            do_log( "Option '$opt' defaulting to: $g{locals}{$opt}{default}", DEBUG ) if $g{debug};
            $g{$opt} = $g{locals}{$opt}{default};
            $g{locals}{$opt}{set} = 1;
        }
    }

    # Set DSN
    $g{dsn} = 'DBI:mysql:' . $g{dbname} . ':' . $g{dbhost};
}

# Read global config from file (as oppsed to db)
sub read_global_config_file {

    # Open config file (assuming we can find it)
    my $file = $g{configfile};
    log_fatal( "Can't find config file $file ($!)", 0 ) if !-e $file;

    open FILE, $file or log_fatal( "Can't read config file $file ($!)", 0 );

    do_log( "Reading global options from '$file'", DEBUG ) if $g{debug};

    # Parse file text
    for my $line (<FILE>) {

        # Skip empty lines and comments
        next if $line =~ /^\s*(#.*)?$/;

        chomp $line;
        my ( $option, $value ) = split /\s*=\s*/, $line, 2;

        # Make sure we have option and value
        log_fatal( "Syntax error in config file at line $.", 0 )
            if !defined $option or !defined $value;

        # Options are case insensitive
        $option = lc $option;

        # Skip local options
        next if defined $g{locals}{$option};

        # Croak if this option is unknown
        log_fatal( "Unknown option '$option' in config file, line $.", 0 )
            if !defined $g{globals}{$option};

        # If this option isn't case sensitive, lowercase it
        $value = lc $value if !$g{globals}{$option}{case};

        # Compare to regex, make sure value is valid
        log_fatal( "Invalid value '$value' for '$option' in config file, " . "line $.", 0 )
            if $value !~ /^$g{globals}{$option}{regex}$/;

        # Assign the value to our option
        $g{$option} = $value;
        $g{globals}{$option}{set} = 1;
    }

    # Log any options not set
    for my $opt ( sort keys %{ $g{globals} } ) {
        next if $g{globals}{$opt}{set};
        do_log( "Option '$opt' defaulting to: $g{globals}{$opt}{default}", DEBUG );
        $g{$opt} = $g{globals}{$opt}{default};
        $g{globals}{$opt}{set} = 1;
    }

    close FILE;
}

# Read global configuration from the DB
sub read_global_config_db {
    my %old_globals;

    # Store our old variables, then unset them
    for my $opt ( keys %{ $g{globals} } ) {
        $old_globals{$opt} = $g{$opt};
        $g{globals}{$opt}{set} = 0;
    }

    my @variable_arr = db_get_array('name,val from global_config');
    for my $variable (@variable_arr) {
        my ( $opt, $val ) = @$variable;
        do_log( "Unknown option '$opt' read from global DB", WARN ) and next
            if !defined $g{globals}{$opt};
        do_log( "Invalid value '$val' for '$opt' in global DB", ERROR ) and next
            if $val !~ /$g{globals}{$opt}{regex}/;

        $g{globals}{$opt}{set} = 1;
        $g{$opt} = $val;
    }

    # If we have any variables whose values have changed, write to DB
    my $rewrite_config = 0;
    if ( $g{initialized} ) {
        for my $opt ( keys %{ $g{globals} } ) {
            $rewrite_config = 1 if $g{$opt} ne $old_globals{$opt};
        }
    }
    rewrite_config() if $rewrite_config;

    # Make sure nothing was missed
    for my $opt ( keys %{ $g{globals} } ) {
        next if $g{globals}{$opt}{set};
        do_log( "Option '$opt' defaulting to: $g{globals}{$opt}{default}.", INFO );
        $g{$opt} = $g{globals}{$opt}{default};
        $g{globals}{$opt}{set} = 1;
    }
}

# Rewrite the config file if we have seen a change in the global DB
sub rewrite_config {
    my @text_out;

    # Open config file (assuming we can find it)
    my $file = $g{configfile};
    log_fatal( "Can't find config file $file ($!)", 0 ) if !-e $file;

    open FILE, $file or log_fatal( "Can't read config file $file ($!)", 0 );
    my @file_text = <FILE>;
    close FILE;

    for my $line (@file_text) {
        next if $line !~ /^\s*(\S+)=(.+)$/;
        my ( $opt, $val ) = split '=', $line;
        my $new_val = $g{$opt};
        $line =~ s/=$val/=$new_val/;
        push @text_out, $line;
    }

    open FILE, ">$file"
        or log_fatal( "Can't write to config file $file ($!)", 0 )
        if !-e $file;
    for my $line (@text_out) { print FILE $line }
    close FILE;
}

# Open log file
sub open_log {

    # Don't open the log if we are not in daemon mode
    #    return if $g{logfile} =~ /^\s*$/ or !$g{daemonize};
    return if $g{logfile} =~ /^\s*$/ or $g{foreground};

    $g{log} = new IO::File $g{logfile}, 'a'
        or log_fatal( "ERROR: Unable to open logfile $g{logfile} ($!)", 1 );
    $g{log}->autoflush(1);
}

# Allow Rotation of log files
sub reopen_log {
    my ($signal) = @_;
    if ( $g{parent} ) {
        do_log( "Sending signal $signal to forks", DEBUG ) if $g{debug};
        for my $fork ( keys %{ $g{forks} } ) {
            my $pid = $g{forks}{$fork}{pid};
            kill $signal, $pid if defined $pid;
        }
    }

    do_log( "Received signal $signal, closing and re-opening log file", DEBUG ) if $g{debug};
    if ( defined $g{log} ) {
        undef $g{log};
        &open_log;
    }
    do_log( "Re-opened log file $g{logfile}", DEBUG ) if $g{debug};
    return 1;
}

# Sub to log data to a logfile and print to screen if verbose
sub do_log {
    my ( $msg, $verbosity, $fork_num ) = @_;
    $verbosity = 2 if !defined $verbosity;
    if ( $g{verbose} >= $verbosity ) {
        my ( $package, $filename, $line ) = caller;
        if ( $package ne 'main' ) {

            $package = substr $package, 3;
            $package = $package . "($fork_num)" if defined $fork_num;
        }
        my ( $sec, $frac ) = gettimeofday;

        #$frac = sprintf( "%03d", $frac / 1000 );
        my $dateISO8601 = strftime( '%Y-%m-%dT%H:%M:%S.' . ( sprintf "%03d", $frac / 1000 ) . '%z', localtime($sec) );
        $msg = $dateISO8601 . "|" . ( sprintf "%-5s", $g{log_level}[$verbosity] ) . '|' . ( sprintf "%-9s", $package ) . '|' . ( sprintf "%5s", $$ ) . '|' . ( sprintf "%4s", $line ) . "|" . $msg;
        my $matched = 1;
        if ( $g{log_match_ref} and not( @{ $g{log_match_ref} } == 1 and $g{log_match_ref}->[0] eq '' ) ) {
            $matched = 0;
            for my $match ( @{ $g{log_match_ref} } ) {
                if ( index( $msg, $match ) != -1 ) {
                    $matched = 1;
                    last;
                }
            }
        }
        if ( $g{log_filter_ref} and not( @{ $g{log_filter_ref} } == 1 and $g{log_filter_ref}->[0] eq '' ) ) {
            for my $match ( @{ $g{log_filter_ref} } ) {
                if ( index( $msg, $match ) != -1 ) {
                    $matched = 0;
                    last;
                }
            }
        }
        if ($matched) {
            if ( defined $g{log} and $g{log} ne '' ) {
                $g{log}->print("$msg\n") if $g{verbose} >= $verbosity;
            } else {
                print "$msg\n" if $g{verbose} >= $verbosity;
            }
        }
    }
    return 1;
}

# Log and die
sub log_fatal {
    my ( $msg, $verbosity, $exitcode ) = @_;

    do_log( $msg, $verbosity );
    quit(1);
}

# Sub to make a nice timestamp
sub ts {
    my ( $sec, $min, $hour, $day, $mon, $year ) = localtime;
    sprintf '[%-2.2d-%-2.2d-%-2.2d@%-2.2d:%-2.2d:%-2.2d]', $year - 100, $mon + 1, $day, $hour, $min, $sec,;
}

# Connect/recover DB connection
sub db_connect {
    my ($silent) = @_;

    # Don't need this if we are not in multinode mode
    return if $g{multinode} ne 'yes';

    # Load the DBI module if we haven't initiliazed yet
    if ( !$g{initiliazed} ) {
        require DBI if !$g{initiliazed};
        DBI->import();
    }

    do_log( "Connecting to DB", INFO ) if !defined $silent;
    $g{dbh}->disconnect()              if defined $g{dbh} and $g{dbh} ne '';

    # 5 connect attempts
    my $try;
    for ( 1 .. 5 ) {
        $g{dbh} = DBI->connect( $g{dsn}, $g{dbuser}, $g{dbpass}, { AutoCommit => 1, RaiseError => 0, PrintError => 1 } )
            and return;

        # Sleep 12 seconds
        sleep 12;

        do_log( "Failed to connect to DB, attempt " . ++$try . " of 5", WARN );
    }
    print "Verbose: ", $g{verbose}, "\n";
    do_log( "Unable to connect to DB ($!)", ERROR );
}

# Sub to query DB, return results, die if error
sub db_get {
    my ($query) = @_;
    do_log( "DEBUG CONF DB: select $query", 4 ) if $g{debug};
    my @results;
    my $a = $g{dbh}->selectall_arrayref("select $query")
        or do_log( "DB query '$query' failed; reconnecting", ERROR )
        and db_connect()
        and return db_get($query);

    for my $b (@$a) {
        for my $c (@$b) {
            push @results, $c;
        }
    }

    return @results;
}

# Sub to query DB, return resulting array, die if error
sub db_get_array {
    my ($query) = @_;
    do_log( "Select $query", DEBUG ) if $g{debug};
    my $results = $g{dbh}->selectall_arrayref("select $query")
        or do_log( "DB query '$query' failed; reconnecting", WARN )
        and db_connect()
        and return db_get_array($query);

    return @$results;
}

# Sub to write to db, die if error
sub db_do {
    my ($cmd) = @_;

    # Make special characters mysql safe
    $cmd =~ s/\\/\\\\/g;

    do_log( "DB $cmd", DEBUG ) if $g{debug};
    my $result = $g{dbh}->do("$cmd")
        or do_log( "DB write '$cmd' failed; reconnecting", ERROR )
        and db_connect()
        and return db_do($cmd);

    return $result;
}

# Reset owners
sub reset_ownerships {
    log_fatal( "--initialized only valid when multinode='YES'", 0 )
        if $g{multinode} ne 'yes';

    db_connect();
    db_do('update devices set owner=0');
    db_do( 'update nodes set heartbeat=4294967295,need_tests=0 ' . 'where active="y"' );
    db_do('delete from test_data');

    die "Database ownerships reset.  Please run all active nodes.\n\n";
}

# Sync the global config on this node to the global config in the db
sub sync_global_config {

    # Make sure we are in multinode mode
    die "--syncglobal flag on applies if you have the local 'MULTINODE' " . "option set to 'YES'\n"
        if $g{multinode} ne 'yes';

    # Connect to db
    db_connect();

    # Read in our config file
    read_global_config_file();

    do_log( "Updating global config", INFO );

    # Clear our global config
    db_do("delete from global_config");

    # Now go through our options and write them to the DB
    for my $opt ( sort keys %{ $g{globals} } ) {
        my $val = $g{$opt};
        db_do("insert into global_config values ('$opt','$val')");
    }

    do_log( "Done", INFO );

    # Now quit
    &quit(0);
}

# Read in from the hosts.cfg file, snmp query hosts to discover their
# vendor and model type, then add them to the DB
sub read_hosts_cfg {
    my %hosts_cfg;
    my %new_hosts;
    my $sysdesc_oid = '1.3.6.1.2.1.1.1.0';
    my $custom_cids = 0;
    my $custom_ver  = 0;
    my $hosts_left  = 0;

    # Hashes containing textual shortcuts for Xymon exception & thresholds
    my %thr_sc = ( 'r' => 'red',    'y' => 'yellow', 'g'  => 'green', 'c'  => 'clear', 'p' => 'purple', 'b' => 'blue' );
    my %exc_sc = ( 'i' => 'ignore', 'o' => 'only',   'ao' => 'alarm', 'na' => 'noalarm' );

    # Read in templates, cause we'll need them
    db_connect();
    dm_templates::read_templates();

    # Spew some debug info
    if ( $g{debug} ) {
        my $num_vendor = 0;
        my $num_model  = 0;
        my $num_temps  = 0;
        my $num_descs  = 0;
        for my $vendor ( keys %{ $g{templates} } ) {
            ++$num_vendor;
            for my $model ( keys %{ $g{templates}{$vendor} } ) {
                ++$num_model;
                my $desc = $g{templates}{$vendor}{$model}{sysdesc};
                $num_descs++ if defined $desc and $desc ne '';
                $num_temps += scalar keys %{ $g{templates}{$vendor}{$model} };
            }
        }

        do_log( "Saw $num_vendor vendors, $num_model models, $num_descs sysdescs & $num_temps templates", DEBUG );
    }

    do_log( "Reading hosts.cfg ", INFO );

    # Now open the hosts.cfg file and read it in
    # Also read in any other host files that are included in the hosts.cfg
    my @hostscfg = ( $g{hostscfg} );
    log_fatal( "FATAL CONF: No hosts.cfg file", 0 ) unless @hostscfg;

    my $etcdir = $1 if $g{hostscfg} =~ /^(.+)\/.+?$/;
    $etcdir = $g{homedir} if !defined $etcdir;
    my $loop_idx = 0;

FILEREAD: while (@hostscfg) {
        ++$loop_idx;
        my $hostscfg = shift @hostscfg;
        next if !defined $hostscfg;    # In case next FILEREAD bypasses the while

        # Die if we fail to open our Xymon root file, warn for all others
        if ( $loop_idx == 1 ) {
            open HOSTSCFG, $hostscfg
                or log_fatal( "Unable to open hosts.cfg file '$g{hostscfg}' ($!)", 0 );
        } elsif ( $hostscfg ne $g{hostscfg} ) {
            open HOSTSCFG, $hostscfg
                or do_log( "Unable to open file '$hostscfg' ($!)", 1 )
                and next FILEREAD;
        }

        # Now interate through our file and suck out the juicy bits
    FILELINE: while ( my $line = <HOSTSCFG> ) {
            next if $line =~ /^\s*#/;
            chomp $line;

            while ( $line =~ s/\\$// and !eof(HOSTSCFG) ) {
                $line .= <HOSTSCFG>;    # Merge with next line
                chomp $line;
            }    # of while

            # First see if this is an include statement
            if ( $line =~ /^\s*(?:disp|net)?include\s+(.+)$/i ) {
                my $file = $1;

                # Tack on our etc dir if this isn't an absolute path
                $file = "$etcdir/$file" if $file !~ /^\//;

                # Add the file to our read array
                push @hostscfg, $file;
            }

            # Similarly, but different, for directory
            if ( $line =~ /^\s*directory\s+(\S+)$/i ) {
                require File::Find;
                import File::Find;
                my $dir = $1;
                do_log( "Looking for hosts.cfg files in $dir", DEBUG ) if $g{debug};
                find( sub { push @hostscfg, $File::Find::name }, $dir );

                # Else see if this line matches the ip/host hosts.cfg format
            } elsif ( $line =~ /^\s*(\d+\.\d+\.\d+\.\d+)\s+(\S+)(.*)$/i ) {
                my ( $ip, $host, $xymonopts ) = ( $1, $2, $3 );

                # Skip if the NET tag does not match this site
                do_log( "Checking if $xymonopts matches NET:" . $g{XYMONNETWORK} . ".", DEBUG ) if $g{debug};
                if ( $g{XYMONNETWORK} ne '' ) {
                    if ( $xymonopts !~ / NET:$g{XYMONNETWORK}/ ) {
                        do_log( "The NET for $host is not $g{XYMONNETWORK}. Skipping.", DEBUG );
                        next;
                    }
                }

                # See if we can find our xymontag to let us know this is a devmon host
                if ( $xymonopts =~ /$g{xymontag}(:\S+|\s+|$)/ ) {
                    my $options = $1;
                    $options = '' if !defined $options or $options =~ /^\s+$/;
                    $options =~ s/,\s+/,/;    # Remove spaces in a comma-delimited list
                    $options =~ s/^://;

                    # Skip the .default. host, defined
                    do_log( "Can't use Devmon on the .default. host, sorry.", WARN )
                        and next
                        if $host eq '.default.';

                    # Make sure we don't have duplicates
                    if ( defined $hosts_cfg{$host} ) {
                        my $old = $hosts_cfg{$host}{ip};
                        do_log( "Refusing to redefine $host from '$old' to '$ip'", WARN );
                        next;
                    }

                    # If this IP is 0.0.0.0, try and get IP from DNS
                    if ( $ip eq '0.0.0.0' ) {
                        $hosts_cfg{$host}{resolution} = 'dns';
                        my ( undef, undef, undef, undef, @addrs ) = gethostbyname $host;
                        if (@addrs) {
                            $ip = join '.', unpack( 'C4', $addrs[0] );    # Use first address
                        } else {

                            # we were not able resoled the hostname but maybe we have already
                            # resolved it in a previous process. We dont skip at this level anymore
                            # and we will look in hosts.db (old_host) if there is an ip for this
                            # hostname. But log it as there is a problem (may be a dns outage only)
                            $ip = undef;
                            do_log( "Unable to resolve DNS name for host '$host'", INFO );
                        }
                    } else {
                        $hosts_cfg{$host}{resolution} = 'xymon_host';
                    }

                    # See if we have a custom cid
                    if ( $options =~ s/(?:,|^)cid\((\S+?)\),?// ) {
                        $hosts_cfg{$host}{cid} = $1;
                        $custom_cids = 1;
                    }

                    # See if we have a custom version
                    if ( $options =~ s/(?:,|^)v([1,3]|(?:2c?)),?// ) {
                        $hosts_cfg{$host}{ver} = substr $1, 0, 1;
                        $custom_ver            = 1;
                    }

                    # See if we have a custom IP
                    if ( $options =~ s/(?:,|^)ip\((\d+\.\d+\.\d+\.\d+)\),?// ) {
                        $ip = $1;
                    }

                    # See if we have a custom port
                    if ( $options =~ s/(?:,|^)port\((\d+?)\),?// ) {
                        $hosts_cfg{$host}{port} = $1;
                    }

                    # Look for vendor/model override
                    if ( $options =~ s/(?:,|^)model\((\S+?)\),?// ) {
                        my ( $vendor, $model ) = split /;/, $1, 2;
                        do_log( "Syntax error in model() option for $host", ERROR ) and next
                            if !defined $vendor or !defined $model;
                        do_log( "Unknown vendor in model() option for $host", WARN ) and next
                            if !defined $g{templates}{$vendor};
                        do_log( "Unknown model in model() option for $host", INFO ) and next
                            if !defined $g{templates}{$vendor}{$model};
                        $hosts_cfg{$host}{vendor} = $vendor;
                        $hosts_cfg{$host}{model}  = $model;
                    }

                    # Read custom exceptions
                    if ( $options =~ s/(?:,|^)except\((\S+?)\)// ) {
                        for my $except ( split /,/, $1 ) {
                            my @args = split /;/, $except;
                            do_log( "Invalid exception clause for $host", ERROR ) and next
                                if scalar @args < 3;
                            my $test = shift @args;
                            my $oid  = shift @args;
                            for my $valpair (@args) {
                                my ( $sc, $val ) = split /:/, $valpair, 2;
                                my $type = $exc_sc{$sc};    # Process shortcut text
                                do_log( "Unknown exception shortcut '$sc' for $host", ERROR ) and next
                                    if !defined $type;
                                $hosts_cfg{$host}{except}{$test}{$oid}{$type} = $val;
                            }
                        }
                    }

                    # Read custom thresholds
                    if ( $options =~ s/(?:,|^)thresh\((\S+?)\)// ) {
                        for my $thresholds ( split /,/, $1 ) {
                            my @args = split /;/, $thresholds;
                            do_log( "Invalid threshold clause for $host", ERROR ) and next
                                if scalar @args < 3;
                            my $test = shift @args;
                            my $oid  = shift @args;
                            for my $valpair (@args) {
                                my ( $sc, $thresh_list, $thresh_msg ) = split /:/, $valpair, 3;
                                my $color = $thr_sc{$sc};    # Process shortcut text
                                do_log( "Unknown exception shortcut '$sc' for $host", ERROR ) and next if !defined $color;
                                $hosts_cfg{$host}{thresh}{$test}{$oid}{$color}{$thresh_list} = undef;
                                $hosts_cfg{$host}{thresh}{$test}{$oid}{$color}{$thresh_list} = $thresh_msg
                                    if defined $thresh_msg;
                            }
                        }
                    }

                    # Default to all tests if they aren't defined
                    if ( $options =~ s/(?:,|^)tests\((\S+?)\)// ) {
                        $hosts_cfg{$host}{tests} = $1;
                    } elsif ( $options =~ s/(?:,|^)notests\((\S+?)\)// ) {
                        $hosts_cfg{$host}{tests} = '!' . $1;
                    } else {
                        $hosts_cfg{$host}{tests} = 'all';
                    }
                    do_log( "Unknown devmon option ($options) on line $. of $hostscfg", ERROR ) and next
                        if $options ne '';

                    $hosts_cfg{$host}{ip} = $ip;

                    #$hosts_cfg{$host}{tests} = $tests;

                    # Incremement our host counter, used to tell if we should bother
                    # trying to query for new hosts...
                    ++$hosts_left;
                }
            }
        }
        close HOSTSCFG;

    }    # End of while loop

    # Gather our existing hosts
    my %old_hosts = read_hosts();

    # Put together our query hash
    my %snmp_input;
    my %snmp_max_tries;

    # Get snmp query params from global conf
    read_global_config();

    # First go through our existing hosts and see if they answer snmp
    do_log( "Querying pre-existing hosts", INFO ) if %old_hosts;

    for my $host ( keys %old_hosts ) {

        # If they don't exist in the new hostscfg, skip 'em
        next if !defined $hosts_cfg{$host};

        my $vendor = $old_hosts{$host}{vendor};
        my $model  = $old_hosts{$host}{model};

        # If their template doesn't exist any more, skip 'em
        next if !defined $g{templates}{$vendor}{$model};

        # Now set snmp security variable and check if consistent
        #     my $ver       = $g{templates}{$vendor}{$model}{snmpver};
        my $ver = exists $hosts_cfg{$host}{ver} ? $hosts_cfg{$host}{ver} : undef;
        $ver = $old_hosts{$host}{ver} if !defined $ver;
        my $cid = exists $hosts_cfg{$host}{cid} ? $hosts_cfg{$host}{cid} : undef;
        $cid = $old_hosts{$host}{cid} if !defined $cid;
        my $secname = exists $hosts_cfg{$host}{secname} ? $hosts_cfg{$host}{secname} : undef;
        $secname = $old_hosts{$host}{secname} if !defined $secname;
        my $seclevel = exists $hosts_cfg{$host}{seclevel} ? $hosts_cfg{$host}{seclevel} : undef;
        $seclevel = $old_hosts{$host}{seclevel} if !defined $seclevel;
        my $authproto = exists $hosts_cfg{$host}{authproto} ? $hosts_cfg{$host}{authproto} : undef;
        $authproto = $old_hosts{$host}{authproto} if !defined $authproto;
        my $authpass = exists $hosts_cfg{$host}{authpass} ? $hosts_cfg{$host}{authpass} : undef;
        $authpass = $old_hosts{$host}{authpass} if !defined $authpass;
        my $privproto = exists $hosts_cfg{$host}{privproto} ? $hosts_cfg{$host}{privproto} : undef;
        $privproto = $old_hosts{$host}{privproto} if !defined $privproto;
        my $privpass = exists $hosts_cfg{$host}{privpass} ? $hosts_cfg{$host}{privpass} : undef;
        $privpass = $old_hosts{$host}{privpass} if !defined $privpass;

        # If SNMP v1 or v2 we should have a cid
        if ( ( $ver eq '1' or $ver eq '2' ) and ( $cid eq '' ) ) {
            next;

            # If SNMP v3 we should have something complex
        } elsif ( $ver eq '3' ) {
            if ( $seclevel eq 'noAuthNoPriv' ) {
                next if ( $secname eq '' );
            } elsif ( $seclevel eq 'authNoPriv' ) {
                next if ( $secname eq '' or $authproto eq '' or $authpass eq '' );
            } elsif ( $seclevel eq 'authPriv' ) {
                next
                    if (   $secname eq ''
                        or $authproto eq ''
                        or $authpass eq ''
                        or $privproto eq ''
                        or length($privpass) < 8 );
            }
        }

        # We were unable to make a name resolution so far but maybe we have the
        # temporary name resolution failure. We ca try to keep a previously discovered
        # value. If it is not a valid value or if we do not have any skip the SNMP discovery
        if ( not defined $hosts_cfg{$host}{ip} ) {
            if ( ( exists $old_hosts{$host}{ip} ) and ( defined $old_hosts{$host}{ip} ) and ( $old_hosts{$host}{ip} ne '0.0.0.0' ) ) {
                $snmp_input{$host}{ip} = $old_hosts{$host}{ip};
            } else {
                next;    #skip this host has we dont have an ip
            }
        } else {
            $snmp_input{$host}{ip} = $hosts_cfg{$host}{ip};
        }

        $snmp_input{$host}{authpass}   = $authpass;
        $snmp_input{$host}{authproto}  = $authproto;
        $snmp_input{$host}{cid}        = $cid;
        $snmp_input{$host}{dev}        = $host;
        $snmp_input{$host}{port}       = exists $hosts_cfg{$host}{port} ? $hosts_cfg{$host}{port} : 161;
        $snmp_input{$host}{privpass}   = $privpass;
        $snmp_input{$host}{privproto}  = $privproto;
        $snmp_input{$host}{resolution} = $hosts_cfg{$host}{resolution};
        $snmp_input{$host}{seclevel}   = $seclevel;
        $snmp_input{$host}{secname}    = $secname;
        $snmp_max_tries{$host}         = 1;

        #$snmp_input{$host}{snmptimeout}= $g{snmptimeout};
        $snmp_input{$host}{snmptimeout} = 3;
        $snmp_input{$host}{ver}         = $ver;

        # Add our sysdesc oid
        $snmp_input{$host}{nonreps}{$sysdesc_oid} = 1;
    }

    # Throw data to our query forks
    dm_snmp::snmp_query( \%snmp_input, \%snmp_max_tries );

    # Now go through our resulting snmp-data
    #OLDHOST: for my $host ( keys %{ $g{oid}{snmp_polled} } ) {
OLDHOST: for my $host ( keys %{ $g{devices} } ) {
        my $sysdesc = $g{devices}{$host}{oids}{snmp_polled}{$sysdesc_oid}{val};

        if ( not defined $sysdesc ) {
            $sysdesc = 'UNDEFINED';
            do_log( "$host sysdesc = UNDEFINED", DEBUG ) if $g{debug};
            next OLDHOST;
        }

        # add vendor/models override with the model() option
        if ( defined $hosts_cfg{$host}{vendor} ) {
            %{ $new_hosts{$host} } = %{ $hosts_cfg{$host} };
            $new_hosts{$host}{vendor}    = $hosts_cfg{$host}{vendor};
            $new_hosts{$host}{model}     = $hosts_cfg{$host}{model};
            $new_hosts{$host}{ver}       = $snmp_input{$host}{ver};
            $new_hosts{$host}{cid}       = $snmp_input{$host}{cid};
            $new_hosts{$host}{port}      = $snmp_input{$host}{port};
            $new_hosts{$host}{secname}   = $snmp_input{$host}{secname};
            $new_hosts{$host}{seclevel}  = $snmp_input{$host}{seclevel};
            $new_hosts{$host}{authproto} = $snmp_input{$host}{authproto};
            $new_hosts{$host}{authpass}  = $snmp_input{$host}{authpass};
            $new_hosts{$host}{privproto} = $snmp_input{$host}{privproto};
            $new_hosts{$host}{privpass}  = $snmp_input{$host}{privpass};
            --$hosts_left;
            do_log( "Discovered $host as a $hosts_cfg{$host}{vendor} / $hosts_cfg{$host}{model} with sysdesc=$sysdesc", INFO );
            next OLDHOST;
        }

        # Okay, we have a sysdesc, lets see if it matches any of our templates
    OLDVENDOR: for my $vendor ( keys %{ $g{templates} } ) {
        OLDMODEL: for my $model ( keys %{ $g{templates}{$vendor} } ) {
                my $regex = $g{templates}{$vendor}{$model}{sysdesc};

                # Careful /w those empty regexs
                do_log( "Regex for $vendor/$model appears to be empty.", WARN )
                    and next
                    if !defined $regex;

                # Skip if this host doesn't match the regex
                if ( $sysdesc !~ /$regex/ ) {
                    do_log( "$host did not match $vendor / $model : $regex", DEBUG ) if $g{debug};
                    next OLDMODEL;
                }

                # We got a match, assign the pertinent data
                %{ $new_hosts{$host} } = %{ $hosts_cfg{$host} };
                $new_hosts{$host}{vendor}    = $vendor;
                $new_hosts{$host}{model}     = $model;
                $new_hosts{$host}{ver}       = $snmp_input{$host}{ver};
                $new_hosts{$host}{cid}       = $snmp_input{$host}{cid};
                $new_hosts{$host}{port}      = $snmp_input{$host}{port};
                $new_hosts{$host}{secname}   = $snmp_input{$host}{secname};
                $new_hosts{$host}{seclevel}  = $snmp_input{$host}{seclevel};
                $new_hosts{$host}{authproto} = $snmp_input{$host}{authproto};
                $new_hosts{$host}{authpass}  = $snmp_input{$host}{authpass};
                $new_hosts{$host}{privproto} = $snmp_input{$host}{privproto};
                $new_hosts{$host}{privpass}  = $snmp_input{$host}{privpass};
                --$hosts_left;
                do_log( "Discovered $host as a $vendor $model with sysdesc=$sysdesc", INFO );
                last OLDVENDOR;
            }
        }
    }

    # Now go into a discovery process: try each version from the least secure to the most with fallback to v1 which do not support some mibs
    my @snmpvers = ( 2, 3, 1 );
    for my $snmpver (@snmpvers) {

        # Quit if we don't have any hosts left to query
        last if $hosts_left < 1;

        # First query hosts with custom cids
        if ( $custom_cids and $snmpver < 3 ) {

            do_log( "$hosts_left host(s) left and $custom_cids custom cid(s) trying using snmp v$snmpver", INFO );

            # Zero out our data in and data out hashes
            #%{ $g{oid}{snmp_polled} } = (); # to be removed

            %snmp_input = ();

            for my $host ( sort keys %hosts_cfg ) {

                # Zero out our data in and data out hashes
                %{ $g{devices}{$host}{oids}{snmp_polled} } = ();

                # Skip if they have already been succesfully queried
                next if defined $new_hosts{$host};

                # Skip if ip is not defined (name resolution)
                next if !defined $hosts_cfg{$host}{ip};

                # Skip if they don't have a custom cid
                next if !defined $hosts_cfg{$host}{cid};
                do_log( "Trying valid host:$host with custom cid:'$hosts_cfg{$host}{cid}' trying snmp v$snmpver", INFO );

                # Throw together our query data
                $snmp_input{$host}{cid}  = $hosts_cfg{$host}{cid};
                $snmp_input{$host}{dev}  = $host;
                $snmp_input{$host}{ip}   = $hosts_cfg{$host}{ip};
                $snmp_input{$host}{port} = $hosts_cfg{$host}{port} if defined $hosts_cfg{$host}{port};

                #$snmp_input{$host}{resolution} = $hosts_cfg{$host}{resolution};
                $snmp_max_tries{$host} = 1;

                #$snmp_input{$host}{snmptimeout} = $g{snmptimeout};
                $snmp_input{$host}{snmptimeout} = 3;
                $snmp_input{$host}{ver}         = $snmpver;

                # Add our sysdesc oid
                $snmp_input{$host}{nonreps}{$sysdesc_oid} = 1;
            }

            # Reset our failed hosts
            $g{fail} = {};

            # Throw data to our query forks
            dm_snmp::snmp_query( \%snmp_input, \%snmp_max_tries );

            # Now go through our resulting snmp-data
            #NEWHOST: for my $host ( keys %{ $g{oid}{snmp_polled} } ) {
        NEWHOST: for my $host ( keys %{ $g{devices} } ) {
                my $sysdesc = $g{devices}{$host}{oids}{snmp_polled}{$sysdesc_oid}{val};
                if ( not defined $sysdesc ) {
                    $sysdesc = 'UNDEFINED';
                    do_log( "$host sysdesc = UNDEFINED", DEBUG ) if $g{debug};
                    next NEWHOST;
                }

                # Catch vendor/models override with the model() option
                if ( defined $hosts_cfg{$host}{vendor} ) {
                    %{ $new_hosts{$host} } = %{ $hosts_cfg{$host} };
                    $new_hosts{$host}{cid} = $snmp_input{$host}{cid};
                    $new_hosts{$host}{ver} = $snmpver;

                    --$hosts_left;

                    do_log( "Discovered $host as a $hosts_cfg{$host}{vendor} / $hosts_cfg{$host}{model}", INFO );

                    #   last NEWHOST;
                    next NEWHOST;
                }

                # Try and match sysdesc
            NEWVENDOR: for my $vendor ( keys %{ $g{templates} } ) {
                NEWMODEL: for my $model ( keys %{ $g{templates}{$vendor} } ) {

                        # Skip if this host doesn't match the regex
                        my $regex = $g{templates}{$vendor}{$model}{sysdesc};
                        if ( $sysdesc !~ /$regex/ ) {
                            do_log( "$host did not match $vendor / $model : $regex", DEBUG ) if $g{debug};
                            next NEWMODEL;
                        }

                        # We got a match, assign the pertinent data
                        %{ $new_hosts{$host} } = %{ $hosts_cfg{$host} };
                        $new_hosts{$host}{vendor} = $vendor;
                        $new_hosts{$host}{model}  = $model;
                        $new_hosts{$host}{ver}    = $snmpver;
                        --$hosts_left;

                        # If they are an old host, they probably changed models...
                        if ( defined $old_hosts{$host} ) {
                            my $old_vendor = $old_hosts{$host}{vendor};
                            my $old_model  = $old_hosts{$host}{model};
                            if ( $vendor ne $old_vendor or $model ne $old_model ) {
                                do_log( "$host changed from a $old_vendor / $old_model to a $vendor / $model", INFO );
                            }
                        } else {
                            do_log( "Discovered $host as a $vendor $model with sysdesc=$sysdesc", INFO );
                        }
                        last NEWVENDOR;
                    }
                }

                # Make sure we were able to get a match
                if ( !defined $new_hosts{$host} ) {
                    do_log( "No matching templates for device: $host", WARN );

                    # Delete the hostscfg key so we don't throw another error later
                    delete $hosts_cfg{$host};
                }
            }
        }
        if ( $snmpver < 3 ) {

            # Now query hosts with default cids
            for my $cid ( split /,/, $g{snmpcids} ) {

                # Don't bother if we don't have any hosts left to query
                next if $hosts_left < 1;

                do_log( "$hosts_left host(s) left, trying cid:'$cid' and snmp v$snmpver", INFO );

                # Zero out our data in and data out hashes
                #%{ $g{oid}{snmp_polled} } = (); #to be removed!
                %snmp_input = ();

                # And query the devices that haven't yet responded to previous cids
                for my $host ( sort keys %hosts_cfg ) {

                    # Zero out our data in and data out hashes
                    %{ $g{devices}{$host}{oids}{snmp_polled} } = ();

                    # Don't query this host if it has a custom snmp version that do not match
                    if ( exists $hosts_cfg{$host}{ver} ) {
                        next if $snmpver != $hosts_cfg{$host}{ver};
                    }

                    # Don't query this host if we already have succesfully done so
                    next if defined $new_hosts{$host};

                    # Skip if ip is not defined (name resolution)
                    next if !defined $hosts_cfg{$host}{ip};

                    do_log( "Trying valid host:$host with cid:'$cid' using snmp v$snmpver", INFO );

                    $snmp_input{$host}{cid}  = $cid;
                    $snmp_input{$host}{dev}  = $host;
                    $snmp_input{$host}{ip}   = $hosts_cfg{$host}{ip};
                    $snmp_input{$host}{port} = $hosts_cfg{$host}{port} if defined $hosts_cfg{$host}{port};

                    #$snmp_input{$host}{resolution} = $hosts_cfg{$host}{resolution};
                    $snmp_max_tries{$host} = 1;

                    #$snmp_input{$host}{snmptimeout} = $g{snmptimeout};
                    $snmp_input{$host}{snmptimeout} = 3;
                    $snmp_input{$host}{ver}         = $snmpver;

                    # Add our sysdesc oid
                    $snmp_input{$host}{nonreps}{$sysdesc_oid} = 1;
                }

                # Reset our failed hosts
                $g{fail} = {};

                # If there is some valid hosts, query them
                if ( keys %snmp_input ) {
                    do_log( "Sending data to SNMP", DEBUG ) if $g{debug};
                    dm_snmp::snmp_query( \%snmp_input, \%snmp_max_tries );
                }

                # Now go through our resulting snmp-data
                #CUSTOMHOST: for my $host ( keys %{ $g{oid}{snmp_polled} } ) {
            CUSTOMHOST: for my $host ( keys %{ $g{devices} } ) {

                    #my $sysdesc = $g{oid}{snmp_polled}{$host}{$sysdesc_oid}{val};
                    my $sysdesc = $g{devices}{$host}{oids}{snmp_polled}{$sysdesc_oid}{val};
                    if ( not defined $sysdesc ) {
                        $sysdesc = 'UNDEFINED';
                        do_log( "$host sysdesc = UNDEFINED", DEBUG ) if $g{debug};
                        next CUSTOMHOST;
                    }

                    # Catch vendor/models override with the model() option
                    if ( defined $hosts_cfg{$host}{vendor} ) {
                        %{ $new_hosts{$host} } = %{ $hosts_cfg{$host} };
                        $new_hosts{$host}{cid} = $cid;
                        $new_hosts{$host}{ver} = $snmpver;
                        --$hosts_left;

                        do_log( "Discovered $host as a $hosts_cfg{$host}{vendor} $hosts_cfg{$host}{model} with sysdesc=$sysdesc", INFO );
                        next CUSTOMHOST;
                    }

                    # Try and match sysdesc
                CUSTOMVENDOR: for my $vendor ( keys %{ $g{templates} } ) {
                    CUSTOMMODEL: for my $model ( keys %{ $g{templates}{$vendor} } ) {

                            # Skip if this host doesn't match the regex
                            my $regex = $g{templates}{$vendor}{$model}{sysdesc};
                            if ( $sysdesc !~ /$regex/ ) {
                                do_log( "$host did not match $vendor / $model : $regex", INFO )
                                    if $g{debug};
                                next CUSTOMMODEL;
                            }

                            # We got a match, assign the pertinent data
                            %{ $new_hosts{$host} } = %{ $hosts_cfg{$host} };
                            $new_hosts{$host}{cid}    = $cid;
                            $new_hosts{$host}{vendor} = $vendor;
                            $new_hosts{$host}{model}  = $model;
                            $new_hosts{$host}{ver}    = $snmpver;

                            --$hosts_left;

                            # If they are an old host, the host is updated
                            if ( defined $old_hosts{$host} ) {
                                do_log( "$host updated with new settings",                               INFO );
                                do_log( "OLD: $old_hosts{$host}{vendor}, $old_hosts{$host}{model}, ...", INFO );
                                do_log( "NEW: $vendor, $model, ...",                                     INFO );

                            } else {
                                do_log( "Discovered $host as a $vendor $model with sysdesc=$sysdesc", INFO );
                            }
                            last CUSTOMVENDOR;
                        }
                    }

                    # Make sure we were able to get a match
                    if ( !defined $new_hosts{$host} ) {
                        do_log( "No matching templates for device: $host", WARN );

                        # Delete the hostscfg key so we don't throw another error later
                        delete $hosts_cfg{$host};
                    }
                }
            }
        } elsif ( $g{snmpeng} eq 'auto' or $g{snmpeng} eq 'snmp' ) {

            # Now query hosts with snmpv3
            #for my $secname ( split /,/, $g{secnames} ) {
            for my $seclevel ( split /,/, $g{seclevels} ) {
            SECNAME: for my $secname ( split /,/, $g{secnames} ) {
                AUTHPROTO: for my $authproto ( split /,/, $g{authprotos} ) {
                    AUTHPASS: for my $authpass ( split /,/, $g{authpasss} ) {
                        PRIVPROTO: for my $privproto ( split /,/, $g{privprotos} ) {
                            PRIVPASS: for my $privpass ( split /,/, $g{privpasss} ) {

                                    #Discard impossible combination
                                    next SECNAME if ( $secname eq '' );

                                    #if ( $seclevel eq 'noAuthNoPriv' or  ) {
                                    #    next SECNAME if ( $secname eq '' );
                                    if ( ( $seclevel eq 'authNoPriv' ) or ( $seclevel eq 'authPriv' ) ) {
                                        next AUTHPROTO if $authproto eq '';
                                        next AUTHPASS  if $authpass eq '';
                                    }
                                    if ( $seclevel eq 'authPriv' ) {
                                        next PRIVPROTO if $privproto eq '';
                                        next PRIVPASS  if length($privpass) < 8;

                                    }

                                    # Don't bother if we don't have any hosts left to query
                                    next if $hosts_left < 1;

                                    do_log( "$hosts_left host(s) left, trying secname:'$secname', seclevel:'$seclevel', authproto:'$authproto', authpass:'$authpass', privproto:'$privproto', privpass:'$privpass' and snmp:v$snmpver", INFO );

                                    # Zero out our data in and data out hashes
                                    #%{ $g{oid}{snmp_polled} } = ();
                                    %snmp_input = ();

                                    # And query the devices that haven't yet responded
                                    # to previous cids or snmpv3 security policies
                                    for my $host ( sort keys %hosts_cfg ) {

                                        # Zero out our data in and data out hashes
                                        %{ $g{devices}{$host}{oids}{snmp_polled} } = ();

                                        # Don't query this host if we already have succesfully done so
                                        next if defined $new_hosts{$host};

                                        # Skip if ip is not defined (name resolution)
                                        next if !defined $hosts_cfg{$host}{ip};

                                        do_log( "Trying valid host:$host, trying secname:'$secname', seclevel:'$seclevel', authproto:'$authproto', authpass:'$authpass', privproto:'$privproto', privpass:'$privpass' and snmp:v$snmpver", INFO );

                                        $snmp_input{$host}{authpass}  = $authpass;
                                        $snmp_input{$host}{authproto} = $authproto;
                                        $snmp_input{$host}{cid}       = '';                        ##############
                                        $snmp_input{$host}{dev}       = $host;
                                        $snmp_input{$host}{ip}        = $hosts_cfg{$host}{ip};
                                        $snmp_input{$host}{port}      = $hosts_cfg{$host}{port};
                                        $snmp_input{$host}{privpass}  = $privpass;
                                        $snmp_input{$host}{privproto} = $privproto;
                                        $snmp_input{$host}{seclevel}  = $seclevel;
                                        $snmp_input{$host}{secname}   = $secname;
                                        $snmp_max_tries{$host}        = 1;

                                        #$snmp_input{$host}{snmptimeout}   = $g{snmptimeout};
                                        $snmp_input{$host}{snmptimeout} = 3;
                                        $snmp_input{$host}{ver}         = $snmpver;

                                        # Add our sysdesc oid
                                        $snmp_input{$host}{nonreps}{$sysdesc_oid} = 1;
                                    }

                                    # Reset our failed hosts
                                    $g{fail} = {};

                                    # If there is some valid hosts, query them
                                    if ( keys %snmp_input ) {
                                        do_log( "Sending data to SNMP", DEBUG ) if $g{debug};
                                        dm_snmp::snmp_query( \%snmp_input, \%snmp_max_tries );
                                    }

                                    # Now go through our resulting snmp-data
                                    #CUSTOMHOST: for my $host ( keys %{ $g{oid}{snmp_polled} } ) {
                                CUSTOMHOST: for my $host ( keys %{ $g{devices} } ) {

                                        #my $sysdesc = $g{oid}{snmp_polled}{$host}{$sysdesc_oid}{val};
                                        my $sysdesc = $g{devices}{$host}{oids}{snmp_polled}{$sysdesc_oid}{val};
                                        if ( not defined $sysdesc ) {
                                            $sysdesc = 'UNDEFINED';
                                            do_log( "$host sysdesc = UNDEFINED", DEBUG ) if $g{debug};
                                            next CUSTOMHOST;
                                        }

                                        # Catch vendor/models override with the model() option
                                        if ( defined $hosts_cfg{$host}{vendor} ) {
                                            %{ $new_hosts{$host} } = %{ $hosts_cfg{$host} };
                                            $new_hosts{$host}{ver}       = $snmpver;
                                            $new_hosts{$host}{cid}       = '';           #################
                                            $new_hosts{$host}{secname}   = $secname;
                                            $new_hosts{$host}{seclevel}  = $seclevel;
                                            $new_hosts{$host}{authproto} = $authproto;
                                            $new_hosts{$host}{authpass}  = $authpass;
                                            $new_hosts{$host}{privproto} = $privproto;
                                            $new_hosts{$host}{privpass}  = $privpass;
                                            --$hosts_left;

                                            do_log( "Discovered $host as a $hosts_cfg{$host}{vendor} $hosts_cfg{$host}{model} with sysdesc=$sysdesc", INFO );
                                            next CUSTOMHOST;
                                        }

                                        # Try and match sysdesc
                                    CUSTOMVENDOR: for my $vendor ( keys %{ $g{templates} } ) {
                                        CUSTOMMODEL: for my $model ( keys %{ $g{templates}{$vendor} } ) {

                                                # Skip if this host doesn't match the regex
                                                my $regex = $g{templates}{$vendor}{$model}{sysdesc};
                                                if ( $sysdesc !~ /$regex/ ) {
                                                    do_log( "$host did not match $vendor / $model : $regex", DEBUG )
                                                        if $g{debug};
                                                    next CUSTOMMODEL;
                                                }

                                                # We got a match, assign the pertinent data
                                                %{ $new_hosts{$host} } = %{ $hosts_cfg{$host} };
                                                $new_hosts{$host}{ver}       = $snmpver;
                                                $new_hosts{$host}{cid}       = '';           ################
                                                $new_hosts{$host}{secname}   = $secname;
                                                $new_hosts{$host}{seclevel}  = $seclevel;
                                                $new_hosts{$host}{authproto} = $authproto;
                                                $new_hosts{$host}{authpass}  = $authpass;
                                                $new_hosts{$host}{privproto} = $privproto;
                                                $new_hosts{$host}{privpass}  = $privpass;
                                                $new_hosts{$host}{vendor}    = $vendor;
                                                $new_hosts{$host}{model}     = $model;
                                                --$hosts_left;

                                                # If they are an old host, the host is updated
                                                if ( defined $old_hosts{$host} ) {
                                                    do_log( "$host updated with new settings",                               INFO );
                                                    do_log( "OLD: $old_hosts{$host}{vendor}, $old_hosts{$host}{model}, ...", INFO );
                                                    do_log( "NEW: $vendor, $model, ...",                                     INFO );
                                                } else {
                                                    do_log( "Discovered $host as a $vendor $model with sysdesc=$sysdesc", INFO );
                                                }
                                                last CUSTOMVENDOR;
                                            }
                                        }

                                        # Make sure we were able to get a match
                                        if ( !defined $new_hosts{$host} ) {
                                            do_log( "No matching templates for device: $host", WARN );

                                            # Delete the hostscfg key so we don't throw another error later
                                            delete $hosts_cfg{$host};
                                        }
                                    }
                                    if ( $seclevel eq 'noAuthNoPriv' ) {
                                        next SECNAME;
                                    } elsif ( $seclevel eq 'authNoPriv' ) {
                                        next AUTHPASS;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    # Go through our hosts.cfg and see if we failed any queries on the
    # devices;  if they were previously defined, just leave them be
    # at let them go clear.  If they are new, drop a log message
    for my $host ( keys %hosts_cfg ) {
        $new_hosts{$host}{tests} = $hosts_cfg{$host}{tests} and next if defined $new_hosts{$host};

        if ( defined $old_hosts{$host} ) {

            # Couldn't query pre-existing host, maybe temporarily unresponsive?
            %{ $new_hosts{$host} } = %{ $old_hosts{$host} };
        } else {

            # Throw a log message complaining
            do_log( "Could not query device: $host", WARN );
        }
    }

    # All done, now we just need to write our hosts to the DB
    if ( $g{multinode} eq 'yes' ) {

        do_log( "Updating database", INFO );

        # Update database
        for my $host ( keys %new_hosts ) {
            my $ip     = $new_hosts{$host}{ip};
            my $vendor = $new_hosts{$host}{vendor};
            my $model  = $new_hosts{$host}{model};
            my $tests  = $new_hosts{$host}{tests};
            my $cid    = $new_hosts{$host}{cid};
            my $port   = $new_hosts{$host}{port};

            $cid .= "::$port" if defined $port;

            # Update any pre-existing hosts
            if ( defined $old_hosts{$host} ) {
                my $changes = '';
                $changes .= "ip='$ip'," if $ip ne $old_hosts{$host}{ip};
                $changes .= "vendor='$vendor',"
                    if $vendor ne $old_hosts{$host}{vendor};
                $changes .= "model='$model',"
                    if $model ne $old_hosts{$host}{model};
                $changes .= "tests='$tests',"
                    if $tests ne $old_hosts{$host}{tests};
                $changes .= "cid='$cid'," if $cid ne $old_hosts{$host}{cid};

                # Only update if something changed
                if ( $changes ne '' ) {
                    chop $changes;
                    db_do("update devices set $changes where name='$host'");
                }

                # Go through our custom threshes and exceptions, update as needed
                for my $test ( keys %{ $new_hosts{$host}{thresh} } ) {
                    for my $oid ( keys %{ $new_hosts{$host}{thresh}{$test} } ) {
                        for my $color ( keys %{ $new_hosts{$host}{thresh}{$test}{$oid} } ) {
                            my $val     = $new_hosts{$host}{thresh}{$test}{$oid}{$color};
                            my $old_val = $old_hosts{$host}{thresh}{$test}{$oid}{$color};

                            if ( defined $val and defined $old_val and $val ne $old_val ) {
                                db_do( "update custom_threshs set val='$val' where " . "host='$host' and test='$test' and color='$color'" );
                            } elsif ( defined $val and !defined $old_val ) {
                                db_do( "delete from custom_threshs where " . "host='$host' and test='$test' and color='$color'" );
                                db_do( "insert into custom_threshs values " . "('$host','$test','$oid','$color','$val')" );
                            } elsif ( !defined $val and defined $old_val ) {
                                db_do( "delete from custom_threshs where " . "host='$host' and test='$test' and color='$color'" );
                            }
                        }
                    }
                }

                # Exceptions
                for my $test ( keys %{ $new_hosts{$host}{except} } ) {
                    for my $oid ( keys %{ $new_hosts{$host}{except}{$test} } ) {
                        for my $type ( keys %{ $new_hosts{$host}{except}{$test}{$oid} } ) {
                            my $val     = $new_hosts{$host}{except}{$test}{$oid}{$type};
                            my $old_val = $old_hosts{$host}{except}{$test}{$oid}{$type};

                            if ( defined $val and defined $old_val and $val ne $old_val ) {
                                db_do( "update custom_excepts set data='$val' where " . "host='$host' and test='$test' and type='$type'" );
                            } elsif ( defined $val and !defined $old_val ) {
                                db_do( "delete from custom_excepts where " . "host='$host' and test='$test' and type='$type'" );
                                db_do( "insert into custom_excepts values " . "('$host','$test','$oid','$type','$val')" );
                            } elsif ( !defined $val and defined $old_val ) {
                                db_do( "delete from custom_excepts where " . "host='$host' and test='$test' and type='$type'" );
                            }
                        }

                        # Clean up exception types that may have been present in the past
                        foreach ( keys %{ $old_hosts{$host}{except}{$test}{$oid} } ) {
                            do_log( "Checking for stale exception types $_ on host $host test $test oid $oid", DEBUG )
                                if $g{debug};
                            if ( not defined $new_hosts{$host}{except}{$test}{$oid}{$_} ) {
                                db_do("delete from custom_excepts where host='$host' and test='$test' and type='$_' and oid='$oid'");
                            }
                        }
                    }
                }

                # If it wasn't pre-existing, go ahead and insert it
            } else {
                db_do("delete from devices where name='$host'");
                db_do("insert into devices values ('$host','$ip','$vendor','$model','$tests','$cid',0)");

                # Insert new thresholds
                for my $test ( keys %{ $new_hosts{$host}{thresh} } ) {
                    for my $oid ( keys %{ $new_hosts{$host}{thresh}{$test} } ) {
                        for my $color ( keys %{ $new_hosts{$host}{thresh}{$test}{$oid} } ) {
                            my $val = $new_hosts{$host}{thresh}{$test}{$oid}{$color};
                            db_do("insert into custom_threshs values ('$host','$test','$oid','$color','$val')");
                        }
                    }
                }

                # Insert new exceptions
                for my $test ( keys %{ $new_hosts{$host}{except} } ) {
                    for my $oid ( keys %{ $new_hosts{$host}{except}{$test} } ) {
                        for my $type ( keys %{ $new_hosts{$host}{except}{$test}{$oid} } ) {
                            my $val = $new_hosts{$host}{except}{$test}{$oid}{$type};
                            db_do("insert into custom_excepts values ('$host','$test','$oid','$type','$val')");
                        }
                    }
                }
            }
        }

        # Delete any hosts not in the xymon hosts.cfg file
        for my $host ( keys %old_hosts ) {
            next if defined $new_hosts{$host};
            do_log( "Removing stale host '$host' from DB", INFO );
            db_do("delete from devices where name='$host'");
            db_do("delete from custom_threshs where host='$host'");
            db_do("delete from custom_excepts where host='$host'");
        }

        # Or write it to our dbfile if we aren't in multinode mode
    } else {

        # Textual abbreviations
        my %thr_sc = ( 'red'    => 'r', 'yellow' => 'y', 'green' => 'g',  'clear'   => 'c', 'purple' => 'p', 'blue' => 'b' );
        my %exc_sc = ( 'ignore' => 'i', 'only'   => 'o', 'alarm' => 'ao', 'noalarm' => 'na' );
        do_log( "DBFILE: $g{dbfile}", INFO );
        open HOSTFILE, ">$g{dbfile}"
            or log_fatal( "Unable to write to dbfile '$g{dbfile}' ($!)", 1 );

        for my $host ( sort keys %new_hosts ) {
            my $ip         = $new_hosts{$host}{ip};
            my $port       = exists $new_hosts{$host}{port} ? $new_hosts{$host}{port} : 161;
            my $resolution = $new_hosts{$host}{resolution};
            my $vendor     = $new_hosts{$host}{vendor};
            my $model      = $new_hosts{$host}{model};
            my $tests      = $new_hosts{$host}{tests};
            my $ver        = exists $new_hosts{$host}{ver}       ? $new_hosts{$host}{ver}       : '';
            my $cid        = exists $new_hosts{$host}{cid}       ? $new_hosts{$host}{cid}       : '';
            my $secname    = exists $new_hosts{$host}{secname}   ? $new_hosts{$host}{secname}   : '';
            my $seclevel   = exists $new_hosts{$host}{seclevel}  ? $new_hosts{$host}{seclevel}  : '';
            my $authproto  = exists $new_hosts{$host}{authproto} ? $new_hosts{$host}{authproto} : '';
            my $authpass   = exists $new_hosts{$host}{authpass}  ? $new_hosts{$host}{authpass}  : '';
            my $privproto  = exists $new_hosts{$host}{privproto} ? $new_hosts{$host}{privproto} : '';
            my $privpass   = exists $new_hosts{$host}{privpass}  ? $new_hosts{$host}{privpass}  : '';

            #default port from config?
            #my $port = 161;
            #$port = $new_hosts{$host}{port} if ( exists $new_hosts{$host}{port} );

            # Custom thresholds
            my $thresholds = '';
            for my $test ( keys %{ $new_hosts{$host}{thresh} } ) {
                for my $oid ( keys %{ $new_hosts{$host}{thresh}{$test} } ) {
                    $thresholds .= "$test;$oid";
                    for my $color ( keys %{ $new_hosts{$host}{thresh}{$test}{$oid} } ) {
                        $thresholds .= ";" . $thr_sc{$color};
                        for my $threshes ( keys %{ $new_hosts{$host}{thresh}{$test}{$oid}{$color} } ) {
                            $thresholds .= ":" . $threshes;
                            my $threshes_msg = $new_hosts{$host}{thresh}{$test}{$oid}{$color}{$threshes};
                            $thresholds .= ":" . $threshes_msg if defined $threshes_msg;
                        }
                    }
                    $thresholds .= ',';
                }
                $thresholds .= ',' if ( $thresholds !~ /,$/ );
            }
            $thresholds =~ s/,$//;

            # Custom exceptions
            my $excepts = '';
            for my $test ( keys %{ $new_hosts{$host}{except} } ) {
                for my $oid ( keys %{ $new_hosts{$host}{except}{$test} } ) {
                    $excepts .= "$test;$oid";
                    for my $type ( keys %{ $new_hosts{$host}{except}{$test}{$oid} } ) {
                        my $val = $new_hosts{$host}{except}{$test}{$oid}{$type};
                        my $sc  = $exc_sc{$type};
                        $excepts .= ";$sc:$val";
                    }
                    $excepts .= ',';
                }
                $excepts .= ',' if ( $excepts !~ /,$/ );
            }
            $excepts =~ s/,$//;
            do_log( "$host $ip $port $resolution $vendor $model $ver $cid $secname $seclevel $authproto $authpass $privproto $privpass $tests $thresholds $excepts", DEBUG ) if $g{debug};
            print HOSTFILE "$host\e$ip\e$port\e$resolution\e$vendor\e$model\e$ver\e$cid\e$secname\e$seclevel\e$authproto\e$authpass\e$privproto\e$privpass\e$tests\e$thresholds\e$excepts\n";
        }

        close HOSTFILE;
    }

    # Now quit
    &quit(0);
}

# Read hosts.cfg in from mysql DB in multinode mode, or else from disk
sub read_hosts {
    my %hosts = ();

    do_log( "DB running read_hosts", DEBUG ) if $g{debug};

    # Multinode
    if ( $g{multinode} eq 'yes' ) {
        do_log( "DB Multimode server", DEBUG ) if $g{debug};
        my @arr = db_get_array("name,ip,vendor,model,tests,cid from devices");
        for my $host (@arr) {
            my ( $name, $ip, $vendor, $model, $tests, $cid ) = @$host;

            # Filter if requested
            # Honor 'poll' command line
            if ( defined $g{match_iphost} and not( ( $name =~ /$g{match_iphost}/ ) or ( $ip =~ /$g{match_iphost}/ ) ) ) {
                next;
            }

            # Honor 'match' command line
            if ( ( defined $g{match_host} ) and ( $name !~ /$g{match_host}/ ) ) {
                if ( ( defined $g{match_ip} ) and ( $ip !~ /$g{match_ip}/ ) ) {
                    next;
                }
                next;
            } else {
                if ( ( defined $g{match_ip} ) and ( $ip !~ /$g{match_ip}/ ) ) {
                    next;
                }
            }
            my $port = $1 if $cid =~ s/::(\d+)$//;

            $hosts{$name}{ip}     = $ip;
            $hosts{$name}{vendor} = $vendor;
            $hosts{$name}{model}  = $model;
            $hosts{$name}{tests}  = $tests;
            $hosts{$name}{cid}    = $cid;
            $hosts{$name}{port}   = $port;
            do_log( "Host in DB $ip $vendor $model $tests $cid $port", DEBUG ) if $g{debug};
        }

        @arr = db_get_array("host,test,oid,type,data from custom_excepts");
        for my $except (@arr) {
            my ( $name, $test, $oid, $type, $data ) = @$except;
            $hosts{$name}{except}{$test}{$oid}{$type} = $data
                if defined $hosts{$name};
        }

        @arr = db_get_array("host,test,oid,color,val from custom_threshs");
        for my $thresh (@arr) {
            my ( $name, $test, $oid, $color, $val ) = @$thresh;
            $hosts{$name}{thresh}{$test}{$oid}{$color} = $val
                if defined $hosts{$name};
        }

        # Singlenode
    } else {
        do_log( "DB Single mode server", DEBUG ) if $g{debug};

        # Check if the hosts file even exists
        return %hosts if !-e $g{dbfile};

        # Hashes containing textual shortcuts for Xymon exception & thresholds
        my %thr_sc = ( 'r' => 'red',    'y' => 'yellow', 'g'  => 'green', 'c'  => 'clear', 'p' => 'purple', 'b' => 'blue' );
        my %exc_sc = ( 'i' => 'ignore', 'o' => 'only',   'ao' => 'alarm', 'na' => 'noalarm' );

        # Statistic variables (done here in singlenode, instead of syncservers)
        my $numdevs  = 0;
        my $numtests = 0;

        # Open and read in data
        open DBFILE, $g{dbfile}
            or log_fatal( "Unable to open host file: $g{dbfile} ($!)", 0 );

        my $linenumber = 0;
    FILELINE: for my $line (<DBFILE>) {
            chomp $line;
            my ( $name, $ip, $port, $resolution, $vendor, $model, $ver, $cid, $secname, $seclevel, $authproto, $authpass, $privproto, $privpass, $tests, $thresholds, $excepts ) = split /\e/, $line;
            do_log( "DB $name $ip $port $resolution $vendor $model $ver $cid $secname $seclevel $authproto $authpass $privproto $privpass $tests $thresholds $excepts", DEBUG ) if $g{debug};

            ++$linenumber;

            # Filter if requested
            # Honor 'poll' command line
            if ( defined $g{match_iphost} and not( ( $name =~ /$g{match_iphost}/ ) or ( $ip =~ /$g{match_iphost}/ ) ) ) {
                next;
            }

            # Honor 'match' command line
            if ( ( defined $g{match_host} ) and ( $name !~ /$g{match_host}/ ) ) {
                if ( ( defined $g{match_ip} ) and ( $ip !~ /$g{match_ip}/ ) ) {
                    next;
                }
                next;
            } else {
                if ( ( defined $g{match_ip} ) and ( $ip !~ /$g{match_ip}/ ) ) {
                    next;
                }
            }

            $hosts{$name}{ip}         = $ip;
            $hosts{$name}{port}       = $port;
            $hosts{$name}{resolution} = $resolution;
            $hosts{$name}{vendor}     = $vendor;
            $hosts{$name}{model}      = $model;
            $hosts{$name}{ver}        = $ver;
            $hosts{$name}{cid}        = $cid;
            $hosts{$name}{secname}    = $secname;
            $hosts{$name}{seclevel}   = $seclevel;
            $hosts{$name}{authproto}  = $authproto;
            $hosts{$name}{authpass}   = $authpass;
            $hosts{$name}{privproto}  = $privproto;
            $hosts{$name}{privpass}   = $privpass;
            $hosts{$name}{tests}      = $tests;

            if ( defined $thresholds and $thresholds ne '' ) {
                for my $threshes ( split ',', $thresholds ) {
                    my @args = split /;/, $threshes, 4;
                    my $test = shift @args;
                    my $oid  = shift @args;
                    for my $valpair (@args) {
                        my ( $sc, $thresh_list, $thresh_msg ) = split /:/, $valpair, 3;
                        my $color = $thr_sc{$sc};
                        $hosts{$name}{thresh}{$test}{$oid}{$color}{$thresh_list} = undef;
                        $hosts{$name}{thresh}{$test}{$oid}{$color}{$thresh_list} = $thresh_msg if defined $thresh_msg;
                    }
                }
            }

            if ( defined $excepts and $excepts ne '' ) {
                for my $except ( split ',', $excepts ) {
                    my @args = split /;/, $except, 4;
                    my $test = shift @args;
                    my $oid  = shift @args;
                    for my $valpair (@args) {
                        my ( $sc, $val ) = split /:/, $valpair, 2;
                        my $type = $exc_sc{$sc};
                        $hosts{$name}{except}{$test}{$oid}{$type} = $val;
                    }
                }
            }

            # Statistics
            ++$numdevs;
            $numtests += ( $tests =~ tr/,/,/ ) + 1;
        }
        close DBFILE;
        do_log( "$numdevs devices in DB", DEBUG ) if $g{debug};

        $g{numdevs}      = $numdevs;
        $g{numtests}     = $numtests;
        $g{avgtestsnode} = 'n/a';
    }

    return %hosts;
}

# Daemonize: go to daemon mode and fork into background
# Much code shamelessly stolen from Proc::Daemon by Earl Hood
sub daemonize {

    #return if !$g{daemonize};
    return if $g{foreground};

    # Now fork our child process off
    if ( my $pid = do_fork() ) {

        # Parent process, we should die
        do_log( "Forking to background process $pid", INFO );
        exit 0;
    }

    # Child process; make sure we disconnect from TTY completely
    POSIX::setsid();

    # Prevent possibility of acquiring a controling terminal
    $SIG{HUP} = 'IGNORE';
    exit 0 if do_fork();

    # Clear file creation mask
    umask 0;

    # Close open file descriptors
    my $openmax = POSIX::sysconf(&POSIX::_SC_OPEN_MAX);
    $openmax = 64 if !defined $openmax or $openmax < 0;
    for my $i ( 0 .. $openmax ) { POSIX::close($i) }

    # Reopen stderr, stdout, stdin to /dev/null
    open( STDIN,  "+>/dev/null" );
    open( STDOUT, "+>&STDIN" );
    open( STDERR, "+>&STDIN" );

    # Define ourselves as the master
    $0 = 'devmon[master]';

    # Set up our signal handlers again, just to be sure
    $SIG{INT} = $SIG{QUIT} = $SIG{TERM} = \&quit;
    $SIG{HUP} = \&reopen_log;

    # Re-open the log file to ensure file descriptors are right
    reopen_log();
}

# Fork with retries.
sub do_fork {
    my ( $pid, $tries );
FORK: {
        if ( defined( $pid = fork ) ) {
            return $pid;

            # If we are out of process space, wait 1 second, then try 4 more times
        } elsif ( $! =~ /No more process/ and ++$tries < 5 ) {
            sleep 1;
            redo FORK;
        } elsif ( $! ne '' ) {
            log_fatal( "Can't fork: $!", 0 );
        }
    }
}

# Sub called by sort, returns results numerically ascending
sub na { $a <=> $b }

# Sub called by sort, returns results numerically descending
sub nd { $b <=> $a }

# Print help
sub usage {
    use File::Basename;
    if (@_) {
        my ($msg) = @_;
        chomp($msg);
        say STDERR "Devmon v$g{version}: $msg";
    }

    my $prog = basename($0);
    say STDERR "Try '$prog -?' for more information.";
    exit(1);
}

sub help {
    use File::Basename;
    my $prog = basename($0);
    print <<"EOF";
Devmon v$g{version}, a device monitor for Xymon
Usage:
  $prog [options]
  $prog -? -he[lp] 

Template development:
  $prog -p iphost=test                           run devmon for only 1 test on 1 host
  $prog -p iphost=test -de                       debug 
  $prog -p iphost=test -t                        trace
  $prog -p iphost=test -m rrd=xymon://localhost  send rrd data to xymon only for graph rendering 

 -c[onfigfile]     Specify config file location  
 -db[file]         Specify database file location  
 -de[bug] -t[race] Print debug or trace 
 -v -vv -nov       Verbose mode: 0 -> quiet, 1 -> error, 2 -> warning(default), 3 -> info, 4 -> debug, 5 -> trace            

 -f[oreground]     Run in foreground (fg). Prevents running in daemon mode  
 -o[utput]         Send message to defined output(s)  
                    Format             : -o=protocol1://target1 -o=protocol2://target2 (or short format -o only, see below) 
                    Default            : -o=xymon://localhost 
                    Short: -o (alone)  : -o=xymon://localhost -o=xymon://stdout
 -1                Oneshot: run only 1 times and exit (default: -no1)

Template building facility options:
 -p[oll]           Poll iphost(s) for test(s) that match host and test regexp,
                    Same as            : -m iphost={ip|hostname} -m test={test}   
 -m[atch]          Poll multiple pattern and report that match:
                    Format by keyword : -m host=host1 -m host=host2
                                      : -m ip=1.1.1.1
                                      : -m iphost=2.2.2.2
                                      : -m test=fan
                                      : -m stat=xymon://localhost (default: no stat)
                                      : -m rrd=xymon://localhost  (default: rrd=xymon://stdout), if set overides default)  
                    Imply: -1 -o
                    Warning: if ip(s) and host(s) are used together, both should match (different that iphost)
-log_m[atch]       Log only if keywords match
                    Format            : -log_m="|snmp" -log_m="|test" -log_m=ERROR -log_m=WARN
-log_f[ilter]      Filter keywords from log (after log_match)
                    Format            : -log_m="| 123" -log_m="|msg"

Mutually exclusive options:  
 -rea[dhostscfg]   Read in data from the Xymon hosts.cfg file  
 -syncc[onfig]     Update multinode DB with the global config options configured on this local node  
 -synct[emplates]  Update multinode device templates with the template data on this local node  
 -res[etowners]    Reset multinode device ownership data.  This will
                   cause all nodes to recalculate ownership data
EOF
    exit(1);
}

# Sub to call when we quit, be it normally or not
sub quit {
    my ($retcode) = @_;
    $retcode = 0 if ( !defined $retcode );
    if ( $retcode !~ /^\d*$/ ) {
        if ( $g{parent} ) {
            do_log( "Master received signal $retcode, shutting down with return code 0", INFO );
        } else {
            do_log( "Fork with pid $$ received signal $retcode, shutting down with return code 0", INFO );
        }
        $retcode = 0;
    }

    $g{shutting_down} = 1;

    # Only run this if we are the parent process
    if ( $g{parent} ) {
        do_log( "Shutting down", INFO ) if $g{initialized};
        unlink $g{pidfile}              if $g{initialized} and -e $g{pidfile};
        $g{log}->close                  if defined $g{log} and $g{log} ne '';
        $g{dbh}->disconnect()           if defined $g{dbh} and $g{dbh} ne '';

        # Clean up our forks if we left any behind, first by killing them nicely
        for my $fork ( keys %{ $g{forks} } ) {
            my $pid = $g{forks}{$fork}{pid};
            kill 15, $pid if defined $pid;
        }
        sleep 1;

        # Then, if they are still hanging around...
        for my $fork ( keys %{ $g{forks} } ) {
            my $pid = $g{forks}{$fork}{pid};
            kill 9, $pid if defined $pid and kill 0, $pid;    # Kick their asses
        }

    }

    exit $retcode;
}

sub oid_sort(@) {
    return @_ unless ( @_ > 1 );
    map { $_->[0] } sort { $a->[1] cmp $b->[1] } map {
        my $oid = $_;
        $oid =~ s/^\.//o;
        $oid =~ s/ /\.0/og;
        [ $_, pack( 'N*', split( '\.', $oid ) ) ]
    } @_;
}

END {
    &quit if !$g{shutting_down};
}
