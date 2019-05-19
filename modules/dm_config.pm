package dm_config;
require Exporter;
@ISA	   = qw(Exporter);
@EXPORT    = qw(initialize sync_servers time_test do_log db_connect
bin_path na nd db_get db_get_array db_do log_fatal);
@EXPORT_OK = qw(%c);

#    Devmon: An SNMP data collector & page generator for the BigBrother &
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

# Modules
use strict;
require dm_tests;
require dm_templates;
use IO::File;
use FindBin;

use Getopt::Long ;

# Load initial program values; only called once at program init
sub initialize {
   autoflush STDOUT 1;

   %g = (
      # General variables
      'version'       => $_[0], # set in main script now
      'homedir'       => $FindBin::Bin,
      'configfile'    => "$FindBin::Bin/devmon.cfg",
      'dbfile'        => "$FindBin::Bin/hosts.db",
      'daemonize'     => 1,
      'initialized'   => 0,
      'mypid'         => 0,
      'verbose'       => 0,
      'debug'         => 0,
      'oneshot'       => 0,
      'print_msg'     => 0,
      'hostonly'      => '',
      'shutting_down' => 0,
      'active'        => '',
      'pidfile'       => '',
      'logfile'       => '',
      'hostscfg'       => '',
      'xymontag'         => '',
      'XYMONNETWORK'    => '',
      'nodename'      => '',
      'log'           => '',

      # DB variables
      'dbhost'        => '',
      'dbname'        => '',
      'dbuser'        => '',
      'dbpass'        => '',
      'dsn'           => '',
      'dbh'           => '',

      # Xymon combo variables
      'dispserv'      => '',
      'msgsize'       => 0,
      'msgsleep'      => 0,

      # Control variables
      'my_nodenum'    => 0,
      'cycletime'     => 0,
      'deadtime'      => 0,
      'parent'        => 1,
      'numforks'      => 0,
      'forks'         => {},
      'maxpolltime'   => 30,
      'maxreps'       => 10,

      # Statistical vars
      'numdevs'       => 0,
      'numtests'      => 0,
      'avgtestsnode'  => 0,
      'snmppolltime'  => 0,
      'testtime'      => 0,
      'msgxfrtime'    => 0,
      'numclears'     => {},
      'avgpolltime'   => [],

      # SNMP variables
      'snmptimeout'   => 0,
      'snmptries'     => 0,
      'snmpcids'      => '',

      # Now our global data subhashes
      'templates'     => {},
      'dev_data'      => {},
      'dev_hist'      => {},
      'tmp_hist'      => {},
      'clear_data'    => {},
      'snmp_data'     => {},
      'fails'         => {},
      'max_rep_hist'  => {},
      'node_status'   => {},
      'xymon_color'  => {},
      'test_results'  => [],

      # User-definable variable controls
      'globals'       => {},
      'locals'        => {}
   );

   # Our local options
   %{$g{locals}} = (
      'multinode' => { 'default' => 'no',
         'regex'   => 'yes|no',
         'set'     => 0,
         'case'    => 0 },
      'hostscfg'   => { 'default' => (defined $ENV{HOSTSCFG} and $ENV{HOSTSCFG} ne '') ? $ENV{HOSTSCFG} :(defined $ENV{HOSTSCFG} and $ENV{HOSTSCFG} ne '') ? $ENV{HOSTSCFG} : '/home/xymon/server/etc/hosts.cfg',
         'regex'   => '.+',
         'set'     => 0,
         'case'    => 1 },
      'XYMONNETWORK'     => { 'default' => (defined $ENV{XYMONNETWORK} and $ENV{XYMONNETWORK} ne '') ? $ENV{XYMONNETWORK} : '',
         'regex'   => '\w+',
         'set'     => 0,
         'case'    => 1 },
      'xymontag'     => { 'default' => 'DEVMON',
         'regex'   => '\w+',
         'set'     => 0,
         'case'    => 1 },
      'snmpcids'  => { 'default' => 'public,private',
         'regex'   => '\S+',
         'set'     => 0,
         'case'    => 1 },
      'nodename'  => { 'default' => 'HOSTNAME',
         'regex'   => '[\w\.-]+',
         'set'     => 0,
         'case'    => 1 },
      'pidfile'   => { 'default' => '/var/run/devmon.pid',
         'regex'   => '.+',
         'set'     => 0,
         'case'    => 1 },
      'logfile'   => { 'default' => '/var/log/devmon.log',
         'regex'   => '.*',
         'set'     => 0,
         'case'    => 1 },
      'dbhost'    => { 'default' => 'localhost',
         'regex'   => '\S+',
         'set'     => 0,
         'case'    => 0 },
      'dbname'    => { 'default' => 'devmon',
         'regex'   => '\w+',
         'set'     => 0,
         'case'    => 1 },
      'dbuser'    => { 'default' => 'devmon',
         'regex'   => '\w+',
         'set'     => 0,
         'case'    => 1 },
      'dbpass'    => { 'default' => 'devmon',
         'regex'   => '\S+',
         'set'     => 0,
         'case'    => 1 }
   );

   # Our global options
   %{$g{globals}} = (
      'dispserv'    => { 'default' => (defined $ENV{XYMSRV} and $ENV{XYMSRV} ne '' ) ? $ENV{XYMSRV} : 'localhost',
         'regex'   => '\S+',
         'set'     => 0,
         'case'    => 0 },
      'dispport'    => { 'default' => (defined $ENV{XYMONDPORT} and $ENV{XYMONDPORT} ne '') ? $ENV{XYMONDPORT} : 1984,
         'regex'   => '\d+',
         'set'     => 0,
         'case'    => 0 },
      'xymondateformat' => { 'default' => (defined $ENV{XYMONDATEFORMAT} and $ENV{XYMONDATEFORMAT} ne '') ? $ENV{XYMONDATEFORMAT} : '',
         'regex'   => '.+',
         'set'     => 0,
         'case'    => 1 },
      'msgsize'     => { 'default' => 8096,
         'regex'   => '\d+',
         'set'     => 0,
         'case'    => 0 },
      'msgsleep'    => { 'default' => 10,
         'regex'   => '\d+',
         'set'     => 0,
         'case'    => 0 },
      'cycletime'   => { 'default' => 60,
         'regex'   => '\d+',
         'set'     => 0,
         'case'    => 0 },
      'cleartime'   => { 'default' => 180,
         'regex'   => '\d+',
         'set'     => 0,
         'case'    => 0 },
      'deadtime'    => { 'default' => 60,
         'regex'   => '\d+',
         'set'     => 0,
         'case'    => 0 },
      'numforks'    => { 'default' => 10,
         'regex'   => '\d+',
         'set'     => 0,
         'case'    => 0 },
      'maxpolltime' => { 'default' => 30,
         'regex'   => '\d+',
         'set'     => 0,
         'case'    => 0 },
      'snmptimeout' => { 'default' => 2,
         'regex'   => '\d+',
         'set'     => 0,
         'case'    => 0 },
      'snmptries'   => { 'default' => 5,
         'regex'   => '\d+',
         'set'     => 0,
         'case'    => 0 },
   );

   # Set up our signal handlers
   $SIG{INT} = $SIG{QUIT} = $SIG{TERM} = \&quit;
   $SIG{HUP} = \&reopen_log;

   # Parse command line options
   my($syncconfig,$synctemps,$resetowner,$readhosts,$oneshot);
	$syncconfig = $synctemps = $resetowner = $readhosts = 0;

   GetOptions (
         "verbose+"        => \$g{verbose},
         "configfile=s"    => \$g{configfile},
         "dbfile=s"        => \$g{dbfile},
         "foreground"      => \$g{foreground},
         "print_msg"       => \$g{print_msg},
         "1"               => \$oneshot ,
         "hostonly=s"      => \$g{hostonly} ,
         "debug"           => \$g{debug},
         "syncconfig"      => \$syncconfig,
         "synctemplates"   => \$synctemps,
         "resetowners"     => \$resetowner,
         "readhostscfg"     => \$readhosts
      ) or usage () ;

	# Check / fix command line options
	# The original code used -f to set daemonize=0
	if ( $g{foreground} ) {
		$g{daemonize} = 0 ;
	}
	# If we check only 1 host, do not daemonize
	if ( $g{hostonly} ) {
		$g{daemonize} = 0 ;
	}
	# Undocumented option.
	if ( $oneshot ) {
    	$g{verbose}   = 2 ;
     	$g{debug}     = 1 ;
     	$g{oneshot}   = 1 ;
	}
   # Dont daemonize if we are printing messages
	if ( $g{print_msg} ) {
   	$g{daemonize} = 0 ;
	}

   # Now read in our local config info from our file
   read_local_config();

   # Prevent multiple mutually exclusives
   if($syncconfig + $synctemps + $resetowner + $readhosts > 1) {
      print "Can't have more than one mutually exclusive option\n\n";
      usage();
   }

   # Check mutual exclusions (run-and-die options)
   sync_global_config()           if $syncconfig;
   dm_templates::sync_templates() if $synctemps;
   reset_ownerships()             if $resetowner;
   read_hosts_cfg()               if $readhosts;

   # Open the log file
   open_log();

   # Daemonize if need be
   daemonize();

   # Set our pid
   $g{mypid} = $$;

   # PID file handling
   if($g{daemonize}) {
      # Check to see if a pid file exists
      if(-e $g{pidfile}) {
         # One exists, let see if its stale
         my $pid_handle = new IO::File $g{pidfile}, 'r'
            or log_fatal("Can't read from pid file '$g{pidfile}' ($!).", 0);

         # Read in the old PID
         my ($old_pid) = <$pid_handle>;
         chomp $old_pid;
         $pid_handle->close;

         # If it exists, die silently
         log_fatal("Devmon already running, quitting.", 1) if kill 0, $old_pid;
      }

      # Now write our pid to the pidfile
      my $pid_handle = new IO::File $g{pidfile}, 'w'
         or log_fatal("Cant write to pidfile $g{pidfile} ($!)",0);
      $pid_handle->print($g{mypid});
      $pid_handle->close;
   }

   # Autodetect our nodename on user request
   if($g{nodename} eq 'HOSTNAME') {
      my $hostname_bin = bin_path('hostname');

      die "Unable to find 'hostname' command!\n" if !defined $hostname_bin;
      my $nodename = `$hostname_bin`;
      chomp $nodename;
      die "Error executing $hostname_bin"
      if $nodename =~ /not found|permission denied/i;

      # Remove domain info, if any
      # Xymon best practice is to use fqdn, if the user doesnt want it
      # we assume they have set NODENAME correctly in devmon.cfg
      # $nodename =~ s/\..*//;
      chomp $nodename;

      $g{nodename} = $nodename;

      do_log("Nodename autodetected as $nodename", 2);
   }

   # Make sure we have a nodename
   die "Unable to determine nodename!\n" if !defined $g{nodename}
      and $g{nodename} =~ /^\S+$/;

   # Set up DB handle
   db_connect(1);

   # Connect to the cluster
   cluster_connect();

   # Read our global variables
   read_global_config();

   # Throw out a little info to the log
   do_log("---Initilizing devmon...",0);
   do_log("Verbosity level: $g{verbose}",1);
   do_log("Logging to $g{logfile}",1);
   do_log("Node $g{my_nodenum} reporting to Xymon at $g{dispserv}",0);
   do_log("Running under process id: $g{mypid}",0);

   # Dump some configs in debug mode
   if ($g{debug}) {
      foreach (keys %{$g{globals}}) {
         do_log(sprintf("DEBUG CONFIG: global %s: %s",$_,$g{$_}));
      }
      foreach (keys %{$g{locals}}) {
         do_log(sprintf("DEBUG CONFIG: local %s: %s",$_,$g{$_}));
      }
   }

   # We are now initialized
   $g{initialized} = 1;
}

# Determine the amount of time we spent doing tests
sub time_test {
   do_log("DEBUG CFG: running time_test()",0) if $g{debug};

   my $poll_time = $g{snmppolltime} + $g{testtime} + $g{msgxfrtime};

   # Add our current poll time to our history array
   push @{$g{avgpolltime}}, $poll_time;
   while (@{$g{avgpolltime}} > 5)  {
      shift @{$g{avgpolltime}} # Only preserve 5 entries
   }

   # Squak if we went over our poll time
   my $exceeded = $poll_time - $g{cycletime};
   if($exceeded > 1) {
      do_log("Exceeded cycle time ($poll_time seconds).", 0);
      $g{sleep_time} = 0;
      quit(0) if $g{oneshot};

   # Otherwise calculate our sleep time
   } else {
      quit(0) if $g{oneshot};
      $g{sleep_time} = -$exceeded;
      $g{sleep_time} = 0 if $g{sleep_time} < 0;  # just in case!
      do_log("Sleeping for $g{sleep_time} seconds.", 1);
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
   my ($total_tests, $my_num_tests, $need_init);

   # If we are multinode='no', just load our tests and return
   if($g{multinode} ne 'yes') {
      %{$g{dev_data}} = read_hosts();
      return;

   }

   # First things first, update heartbeat info
   db_do("update nodes set heartbeat='" . time .
      "' where node_num=" . $g{my_nodenum});

   # Reload our global config
   read_global_config();

   # Read in all node configuration data
   update_nodes();

   # If someone has set our flag to inactive, quietly die
   if($g{node_status}{nodes}{$g{my_nodenum}}{active} ne 'y') {
      do_log("Active flag has been set to a non-true value.  Exiting.", 0);
      exit 0;
   }

   # See if we need to read our templates
   if($g{node_status}{nodes}{$g{my_nodenum}}{read_temps} eq 'y') {
      dm_templates::read_templates();
      $g{node_status}{nodes}{$g{my_nodenum}}{read_temps}  = 'n';
   }

   # We need an init by default, but if anybody has any tests, set to 0
   $need_init = 1;

   %{$g{dev_data}} = ();

   # Assume we have 0 tests to begin with
   $my_num_tests = 0;
   $total_tests  = 0;

   # Read in all custom thresholds
   my @threshs
   = db_get_array('host,test,oid,color,val from custom_threshs');
   for my $this_thresh (@threshs) {
      my ($host, $test, $oid, $color, $val) = @$this_thresh;
      $custom_threshs{$host}{$test}{$oid}{$color} = $val;
   }

   # Read in all custom exceptions
   my @excepts
   = db_get_array('host,test,oid,type,data from custom_excepts');
   for my $this_except (@excepts) {
      my ($host, $test, $oid, $type, $data) = @$this_except;
      $custom_excepts{$host}{$test}{$oid}{$type} = $data;
   }

   # Read in all tests for all nodes
   my @tests
   = db_get_array('name,ip,vendor,model,tests,cid,owner from devices');
   for my $this_test (@tests) {
      my ($device, $ip, $vendor, $model, $tests, $cid, $owner) = @$this_test;

      # Make sure we disable our init if someone already has a test
      if($owner != 0) {$need_init = 0}

      $device_hash{$device}{ip}          = $ip;
      $device_hash{$device}{vendor}      = $vendor;
      $device_hash{$device}{model}       = $model;
      $device_hash{$device}{tests}       = $tests;
      $device_hash{$device}{cid}         = $cid;
      $device_hash{$device}{owner}       = $owner;

      # Do some numerical accounting that we use to load-balance later

      # Determine the number of tests that this host has
      my $dev_tests;
      if($tests eq 'all') {
         $dev_tests = scalar keys %{$g{templates}{$vendor}{$model}{tests}};
      } else {
         $dev_tests = ($tests =~ tr/,/,/) + 1;
      }

      $total_tests  += $dev_tests;
      $test_count{$device} = $dev_tests;

      # If this test is ours, claim it!
      if ($owner == $g{my_nodenum}) {
         $my_num_tests += $dev_tests;
         $g{dev_data}{$device} = $device_hash{$device};
         %{$g{dev_data}{$device}{thresh}} = %{$custom_threshs{$device}}
         if defined $custom_threshs{$device};
         %{$g{dev_data}{$device}{except}} = %{$custom_excepts{$device}}
         if defined $custom_excepts{$device};
      }

      # If this test doesnt have an owner, lets add it to the available pool
      if($owner == 0 or not defined $g{node_status}{active}{$owner}) {
         push @{$available_devices{$dev_tests}}, $device;
      }
   }

   # Determine our number of active nodes
   my @active_nodes  = sort na keys %{$g{node_status}{active}};
   my $num_active_nodes = @active_nodes + 0;

   # Determine the avg number of tests/node
   my $avg_tests_node = $num_active_nodes ? int $total_tests / $num_active_nodes : 0;

   # Now lets see if we need tests
   if($my_num_tests < $avg_tests_node) {

      # First, let evertbody know that we need tests
      my $num_tests_needed = $avg_tests_node - $my_num_tests;
      db_do("update nodes set need_tests=$num_tests_needed " .
         "where node_num=$g{my_nodenum}");

      # Lets see if we need to init, along with the other nodes
      if($need_init) {
         do_log("Initializing test database",0);
         # Now we need all other nodes waiting for init before we can proceed
         do_log("Waiting for all nodes to synchronize",0);
         INIT_WAIT: while(1) {

            # Make sure our heart beats while we wait
            db_do("update nodes set heartbeat='" . time .
               "' where node_num='$g{my_nodenum}'");

            for my $node (keys %{$g{node_status}{active}}) {
               next if $node == $g{my_nodenum};
               if ($g{node_status}{nodes}{$node}{need_tests}
                  != $avg_tests_node) {
                  my $name = $g{node_status}{nodes}{$node}{name};
                  # This node isnt ready for init; sleep then try again
                  do_log("Waiting for node $node($name)",0);
                  sleep 2;
                  update_nodes();
                  next INIT_WAIT;
               }
            }

            # Looks like all nodes are ready, exit the loop
            sleep 2;
            last;
         }
         do_log("Done waiting",0);

         # Now assign all tests using a round-robin technique;  this should
         # synchronize the tests between all servers
         my @available;
         for my $count (sort nd keys %available_devices) {
            push @available, @{$available_devices{$count}};
         }

         @active_nodes  = sort na keys %{$g{node_status}{active}};
         $num_active_nodes = @active_nodes + 0;
         $avg_tests_node = int $total_tests / $num_active_nodes;

         my $this_node = 0;
         for my $device (@available) {
            # Skip any test unless the count falls on our node num
            if($active_nodes[$this_node++] == $g{my_nodenum}) {
               # Make it ours, baby!
               my $result = db_do("update devices set " .
                  "owner=$g{my_nodenum} where name='$device' and owner=0");
               # Make sure out DB update went through
               next if !$result;
               # Now stick the pertinent data in our variables
               $my_num_tests += $test_count{$device};
               $g{dev_data}{$device} = $device_hash{$device};
               %{$g{dev_data}{$device}{thresh}} = %{$custom_threshs{$device}}
               if defined $custom_threshs{$device};
               %{$g{dev_data}{$device}{except}} = %{$custom_excepts{$device}}
               if defined $custom_excepts{$device};
            }

            # Make sure we arent out of bounds
            $this_node = 0 if $this_node > $#active_nodes;
         }

         do_log("Init complete: $my_num_tests tests loaded, " .
            "avg $avg_tests_node tests per node", 0);

      # Okay, we're not at init, so lets see if we can find any available tests
      } else {

         for my $count (sort nd keys %available_devices) {

            # Go through all the devices for this test count
            for my $device (@{$available_devices{$count}}) {

               # Make sure we havent hit our limit
               last if $my_num_tests > $avg_tests_node;

               # Lets try and take this test
               my $result = db_do("update devices set " .
                  "owner=$g{my_nodenum} where name='$device'");
               next if !$result;

               # We got it!  Lets add it to our test_data hash
               $my_num_tests += $count;
               my $old_owner = $device_hash{$device}{owner};

               # Add data to our hashes
               $g{dev_data}{$device} = $device_hash{$device};
               %{$g{dev_data}{$device}{thresh}} = %{$custom_threshs{$device}}
               if defined $custom_threshs{$device};
               %{$g{dev_data}{$device}{except}} = %{$custom_excepts{$device}}
               if defined $custom_excepts{$device};

               # Log where this device came from
               if($old_owner == 0) {
                  do_log("Got $device ($my_num_tests/$avg_tests_node tests)");
               } else {
                  my $old_name = $g{node_status}{nodes}{$old_owner}{name};
                  $old_name = "unknown" if !defined $old_name;
                  do_log("Recovered $device from node $old_owner($old_name) " .
                     "($my_num_tests/$avg_tests_node tests)",0);
               }

               # Now lets try and get the history for it, if it exists
               my @hist_arr =
               db_get_array('ifc,test,time,val from test_data ' .
                  "where host='$device'");
               for my $hist (@hist_arr) {
                  my ($ifc,$test,$time,$val) = @$hist;
                  $g{dev_hist}{$device}{$ifc}{$test}{val} = $val;
                  $g{dev_hist}{$device}{$ifc}{$test}{time}  = $time;
               }

               # Now delete it from the history table
               db_do("delete from test_data where host='$device'");
            }
         }
      }

      # Now lets update the DB with how many tests we still need
      $num_tests_needed = $avg_tests_node - $my_num_tests;
      $num_tests_needed = 0 if $num_tests_needed < 0;
      db_do("update nodes set need_tests=$num_tests_needed " .
         "where node_num=$g{my_nodenum}");

   # If we dont need any tests, lets see if we can donate any tests
   } elsif ($my_num_tests > $avg_tests_node) {

      my $tests_they_need;
      my $biggest_test_needed = 0;

      # Read in the number of needy nodes
      for my $this_node (@active_nodes) {
         next if $this_node == $g{my_nodenum};
         my $this_node_needs =
         $g{node_status}{nodes}{$this_node}{need_tests};
         $tests_they_need += $this_node_needs;
         $biggest_test_needed = $this_node_needs
         if $this_node_needs > $biggest_test_needed;
      }

      # Now go through the devices and assign any I can
      for my $device (keys %{$g{dev_data}}) {
         # Make sure this test isnt too big
         next if $test_count{$device} > $biggest_test_needed

         # Now make sure that it wont put us under the avg_nodes
            or $my_num_tests - $test_count{$device} <= $avg_tests_node;

         # Okay, lets assign it to the open pool, then
         my $result = db_do("update devices set owner=0 where " .
            "name='$device' and owner=$g{my_nodenum}");

         # We really shouldnt fail this, but just in case
         next if !$result;
         $my_num_tests -= $test_count{$device};
         do_log("Dropped $device ($my_num_tests/$avg_tests_node tests)", 0);

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
         delete $g{dev_data}{$device};
      }
   }

   # Record some statistics
   $g{numtests}       = $my_num_tests;
   $g{avgtestsnode}   = $avg_tests_node;
   $g{numdevs}        = scalar keys %{$g{dev_data}};
}

# Sub to update node status & configuration
sub update_nodes {
   # Make a copy of our node status
   my %old_status = %{$g{node_status}};

   %{$g{node_status}} = ();
   my @nodes = db_get_array('name,node_num,active,heartbeat,need_tests,' .
      'read_temps from nodes');

   NODE: for my $node (@nodes) {
      my ($name, $node_num, $active, $heartbeat, $need_tests,
         $read_temps) = @$node;
      $g{node_status}{nodes}{$node_num} = {
         'name'          => $name,
         'active'        => $active,
         'heartbeat'     => $heartbeat,
         'need_tests'    => $need_tests,
         'read_temps'    => $read_temps
      };

      # Check to see if its inactive
      if($active ne 'y') {
         $g{node_status}{inactive}{$node_num} = 1;
         next NODE;

      # Check to see if this host has died (i.e. exceeded deadtime)
      } elsif($heartbeat + $g{deadtime} < time) {
         do_log("Node $node_num($name) has died!")
         if !defined $old_status{dead}{$node_num};
         $g{node_status}{dead}{$node_num} = time;

      # Now check and see if it was previously dead and has returned
      } elsif(defined $old_status{dead}{$node_num}) {
         my $up_duration = time - $old_status{dead}{$node_num};
         if ($up_duration > ($g{deadtime} * 2)) {
            $g{node_status}{active}{$node_num} = 1;
            do_log("Node $node_num($name) has returned! " .
               "Up $up_duration secs",0);
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
   # Dont bother if we arent multinode
   return if $g{multinode} ne 'yes';

   my $now = time;
   my $nodenum;
   my $nodename = $g{nodename};
   my %nodes;

   # First pull down all our node info to make sure we exist in the table
   my @nodeinfo = db_get_array("name,node_num from nodes");

   for my $row (@nodeinfo) {
      my ($name, $num) = @$row;
      $nodes{$num}  = $name;
      $nodenum = $num if $name eq $nodename;
   }

   # If we arent in the table, lets add ourself
   if(!defined $nodenum) {

      # Find the next available num
      my $ptr;
      while (!defined $nodenum) {
         $nodenum = $ptr if !defined $nodes{++$ptr};
      }

      # Do the db add
      db_do("insert into nodes values ('$nodename',$nodenum,'y',$now,0,'n')");

   # If we are in the table, update our activity and heartbeat columns
   } else {
      db_do("update nodes set active='y', heartbeat=$now " .
         "where node_num=$nodenum" );
   }

   # Set our global nodenum
   $g{my_nodenum} = $nodenum;
}

# Sub to load/reload global configuration data
sub read_global_config {
   if($g{multinode} eq 'yes') {
      read_global_config_db();
   } else {
      read_global_config_file();
   }
}

# Read in the local config parameters from the config file
sub read_local_config {
   # Open config file (assuming we can find it)
   my $file = $g{configfile};
   &usage if !defined $file;

   if ($file !~ /^\/.+/ and !-e $file) {
      my $local_file = $FindBin::Bin . "/$file";
      $file = $local_file if -e $local_file;
   }

   log_fatal("Can't find config file $file ($!)",0) if !-e $file;
   open FILE, $file or log_fatal("Can't read config file $file ($!)",0);

   # Parse file text
   for my $line (<FILE>) {

      # Skip empty lines and comments
      next if $line =~ /^\s*(#.*)?$/;

      chomp $line;
      my ($option, $value) = split /\s*=\s*/, $line, 2;

      # Make sure we have option and value
      log_fatal("Syntax error in config file at line $.",0)
      if !defined $option or !defined $value;

      # Options are case insensitive
      $option = lc $option;

      # Skip global options
      next if defined $g{globals}{$option};

      # Croak if this option is unknown
      log_fatal("Unknown option '$option' in config file, line $.",0)
      if !defined $g{locals}{$option};

      # If this option isnt case sensitive, lowercase it
      $value = lc $value if !$g{locals}{$option}{case};

      # Compare to regex, make sure value is valid
      log_fatal("Invalid value '$value' for '$option' in config file, " .
         "line $.",0)
      if $value !~ /^$g{locals}{$option}{regex}$/;

      # Assign the value to our option
      $g{$option} = $value;
      $g{locals}{$option}{set} = 1;
   }
   close FILE;

   # Log any options not set
   for my $opt (sort keys %{$g{locals}}) {
      next if $g{locals}{$opt}{set};
      do_log("Option '$opt' defaulting to: $g{locals}{$opt}{default}",2);
      $g{$opt} = $g{locals}{$opt}{default};
      $g{locals}{$opt}{set} = 1;
   }

   # Set DSN
   $g{dsn} = 'DBI:mysql:' . $g{dbname} . ':' . $g{dbhost};
}

# Read global config from file (as oppsed to db)
sub read_global_config_file {
   # Open config file (assuming we can find it)
   my $file = $g{configfile};
   log_fatal("Can't find config file $file ($!)",0) if !-e $file;

   open FILE, $file or log_fatal("Can't read config file $file ($!)", 0);

   # Parse file text
   for my $line (<FILE>) {

      # Skip empty lines and comments
      next if $line =~ /^\s*(#.*)?$/;

      chomp $line;
      my ($option, $value) = split /\s*=\s*/, $line, 2;

      # Make sure we have option and value
      log_fatal("Syntax error in config file at line $.",0)
      if !defined $option or !defined $value;

      # Options are case insensitive
      $option = lc $option;

      # Skip local options
      next if defined $g{locals}{$option};

      # Croak if this option is unknown
      log_fatal("Unknown option '$option' in config file, line $.",0)
      if !defined $g{globals}{$option};

      # If this option isnt case sensitive, lowercase it
      $value = lc $value if !$g{globals}{$option}{case};

      # Compare to regex, make sure value is valid
      log_fatal("Invalid value '$value' for '$option' in config file, " .
         "line $.", 0)
      if $value !~ /^$g{globals}{$option}{regex}$/;

      # Assign the value to our option
      $g{$option} = $value;
      $g{globals}{$option}{set} = 1;
   }

   # Log any options not set
   for my $opt (sort keys %{$g{globals}}) {
      next if $g{globals}{$opt}{set};
      do_log("Option '$opt' defaulting to: $g{globals}{$opt}{default}.",2);
      $g{$opt} = $g{globals}{$opt}{default};
      $g{globals}{$opt}{set} = 1;
   }

   close FILE;
}

# Read global configuration from the DB
sub read_global_config_db {
   my %old_globals;

   # Store our old variables, then unset them
   for my $opt (keys %{$g{globals}}) {
      $old_globals{$opt} = $g{$opt};
      $g{globals}{$opt}{set} = 0;
   }

   my @variable_arr = db_get_array('name,val from global_config');
   for my $variable (@variable_arr) {
      my ($opt,$val) = @$variable;
      do_log("Unknown option '$opt' read from global DB") and next
      if !defined $g{globals}{$opt};
      do_log("Invalid value '$val' for '$opt' in global DB") and next
      if $val !~ /$g{globals}{$opt}{regex}/;

      $g{globals}{$opt}{set} = 1;
      $g{$opt} = $val;
   }

   # If we have any variables whose values have changed, write to DB
   my $rewrite_config = 0;
   if($g{initialized}) {
      for my $opt (keys %{$g{globals}}) {
         $rewrite_config = 1 if $g{$opt} ne $old_globals{$opt};
      }
   }
   rewrite_config() if $rewrite_config;

   # Make sure nothing was missed
   for my $opt (keys %{$g{globals}}) {
      next if $g{globals}{$opt}{set};
      do_log("Option '$opt' defaulting to: $g{globals}{$opt}{default}.",2);
      $g{$opt} = $g{globals}{$opt}{default};
      $g{globals}{$opt}{set} = 1;
   }
}

# Rewrite the config file if we have seen a change in the global DB
sub rewrite_config {
   my @text_out;

   # Open config file (assuming we can find it)
   my $file = $g{configfile};
   log_fatal("Can't find config file $file ($!)",0) if !-e $file;

   open FILE, $file or log_fatal("Can't read config file $file ($!)", 0);
   my @file_text = <FILE>;
   close FILE;

   for my $line (@file_text) {
      next if $line !~ /^\s*(\S+)=(.+)$/;
      my ($opt, $val) = split '=', $line;
      my $new_val = $g{$opt};
      $line =~ s/=$val/=$new_val/;
      push @text_out, $line;
   }

   open FILE, ">$file" or
   log_fatal("Can't write to config file $file ($!)",0) if !-e $file;
   for my $line (@text_out) {print FILE $line}
   close FILE;
}

# Open log file
sub open_log {
   # Dont open the log if we are not in daemon mode
   return if $g{logfile} =~ /^\s*$/ or !$g{daemonize};

   $g{log} = new IO::File $g{logfile}, 'a'
      or log_fatal("ERROR: Unable to open logfile $g{logfile} ($!)",0);
   $g{log}->autoflush(1);
}

# Allow Rotation of log files
sub reopen_log {
   my ($signal) = @_;
   if ($g{parent}) {
      do_log("Sending signal $signal to forks",3) if $g{debug};
      for my $fork (keys %{$g{forks}}) {
         my $pid = $g{forks}{$fork}{pid};
         kill $signal, $pid if defined $pid;
      }
   }

   do_log("Received signal $signal, closing and re-opening log file",3) if $g{debug};
   if (defined $g{log}) {
      undef $g{log};
      &open_log;
   }
   do_log("Re-opened log file $g{logfile}",3) if $g{debug};
   return 1;
}

# Sub to log data to a logfile and print to screen if verbose
sub do_log {
   my ($msg, $verbosity) = @_;

   $verbosity = 0 if !defined $verbosity;
   my $ts = ts();
   if (defined $g{log} and $g{log} ne '') {
      $g{log}->print("$ts $msg\n") if $g{verbose} >= $verbosity;;
   } else {
      print "$ts $msg\n" if $g{verbose} >= $verbosity;;
      return 1;
   }

   print "$ts $msg\n" if $g{verbose} > $verbosity;

   return 1;
}

# Log and die
sub log_fatal {
   my ($msg, $verbosity,$exitcode) = @_;

   do_log($msg, $verbosity);
   quit(1);
}

# Sub to make a nice timestamp
sub ts {
   my ($sec,$min,$hour,$day,$mon,$year) = localtime;
   sprintf '[%-2.2d-%-2.2d-%-2.2d@%-2.2d:%-2.2d:%-2.2d]', $year-100, $mon+1,
   $day, $hour, $min, $sec,
}

# Connect/recover DB connection
sub db_connect {
   my ($silent) = @_;

   # Dont need this if we are not in multinode mode
   return if $g{multinode} ne 'yes';

   # Load the DBI module if we havent initilized yet
   if(!$g{initilized}) {
      require DBI if !$g{initilized};
      DBI->import();
   }

   do_log("Connecting to DB",2) if !defined $silent;
   $g{dbh}->disconnect() if defined $g{dbh} and $g{dbh} ne '';

   # 5 connect attempts
   my $try;
   for (1 .. 5) {
      $g{dbh} = DBI->connect(
         $g{dsn},
         $g{dbuser},
         $g{dbpass},
         {AutoCommit => 1, RaiseError => 0, PrintError => 1}
      ) and return;

      # Sleep 12 seconds
      sleep 12;

      do_log("Failed to connect to DB, attempt ".++$try." of 5",0);
   }
   print "Verbose: ", $g{verbose}, "\n";
   do_log("ERROR: Unable to connect to DB ($!)",0);
}

# Sub to query DB, return results, die if error
sub db_get {
   my ($query) = @_;
   do_log("DEBUG DB: select $query") if $g{debug};
   my @results;
   my $a = $g{dbh}->selectall_arrayref("select $query") or
   do_log("DB query '$query' failed; reconnecting",0)
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
   do_log("DEBUG DB: select $query") if $g{debug};
   my $results = $g{dbh}->selectall_arrayref("select $query") or
   do_log("DB query '$query' failed; reconnecting",0)
      and db_connect()
      and return db_get_array($query);

   return @$results;
}

# Sub to write to db, die if error
sub db_do {
   my ($cmd) = @_;

   # Make special characters mysql safe
   $cmd =~ s/\\/\\\\/g;

   do_log("DEBUG DB: $cmd") if $g{debug};
   my $result = $g{dbh}->do("$cmd") or
   do_log("DB write '$cmd' failed; reconnecting",0)
      and db_connect()
      and return db_do($cmd);

   return $result;
}

# Reset owners
sub reset_ownerships {
   log_fatal("--initialized only valid when multinode='YES'",0)
   if $g{multinode} ne 'yes';

   db_connect();
   db_do('update devices set owner=0');
   db_do('update nodes set heartbeat=4294967295,need_tests=0 '.
      'where active="y"');
   db_do('delete from test_data');

   die "Database ownerships reset.  Please run all active nodes.\n\n";
}

# Sync the global config on this node to the global config in the db
sub sync_global_config {
   # Make sure we are in multinode mode
   die "--syncglobal flag on applies if you have the local 'MULTINODE' " .
   "option set to 'YES'\n" if $g{multinode} ne 'yes';

   # Connect to db
   db_connect();

   # Read in our config file
   read_global_config_file();

   do_log("Updating global config",0);
   # Clear our global config
   db_do("delete from global_config");

   # Now go through our options and write them to the DB
   for my $opt (sort keys %{$g{globals}}) {
      my $val = $g{$opt};
      db_do("insert into global_config values ('$opt','$val')");
   }

   do_log("Done",0);

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
   my $hosts_left  = 0;

   # Hashes containing textual shortcuts for Xymon exception & thresholds
   my %thr_sc = ( 'r' => 'red', 'y' => 'yellow', 'g' => 'green', 'c' => 'clear', 'p' => 'purple', 'b' => 'blue' );
   my %exc_sc = ( 'i' => 'ignore', 'o' => 'only', 'ao' => 'alarm',
      'na' => 'noalarm' );

   # Read in templates, cause we'll need them
   db_connect();
   dm_templates::read_templates();

   # Spew some debug info
   if($g{debug}) {
      my $num_vendor = 0; my $num_model  = 0;
      my $num_temps  = 0; my $num_descs  = 0;
      for my $vendor (keys %{$g{templates}}) {
         ++$num_vendor;
         for my $model (keys %{$g{templates}{$vendor}}) {
            ++$num_model;
            my $desc = $g{templates}{$vendor}{$model}{sysdesc};
            $num_descs++ if defined $desc and $desc ne '';
            $num_temps += scalar keys %{$g{templates}{$vendor}{$model}};
         }
      }

      do_log("Saw $num_vendor vendors, $num_model models, " .
         "$num_descs sysdescs & $num_temps templates",0);
   }

   do_log("SNMP querying all hosts in hosts.cfg file, please wait...",1);

   # Now open the hosts.cfg file and read it in
   # Also read in any other host files that are included in the hosts.cfg
   my @hostscfg = ($g{hostscfg});
   my $etcdir  = $1 if $g{hostscfg} =~ /^(.+)\/.+?$/;
   $etcdir = $g{homedir} if !defined $etcdir;

   FILEREAD: do {
      my $hostscfg = shift @hostscfg;
      next if !defined $hostscfg; # In case next FILEREAD bypasses the while

      # Die if we fail to open our Xymon root file, warn for all others
      if($hostscfg eq $g{hostscfg}) {
         open HOSTSCFG, $hostscfg or
         log_fatal("Unable to open hosts.cfg file '$g{hostscfg}' ($!)", 0);
      } else {
         open HOSTSCFG, $hostscfg or
         do_log("Unable to open file '$g{hostscfg}' ($!)", 0) and
         next FILEREAD;
      }

      # Now interate through our file and suck out the juicy bits
      FILELINE: while ( my $line= <HOSTSCFG> ) {
         chomp $line;

         while ( $line=~ s/\\$//  and  ! eof(HOSTSCFG) ) {
            $line.= <HOSTSCFG> ;            # Merge with next line
            chomp $line ;
         }  # of while

         # First see if this is an include statement
         if($line =~ /^\s*(?:disp|net)?include\s+(.+)$/i) {
            my $file = $1;
            # Tack on our etc dir if this isnt an absolute path
            $file = "$etcdir/$file" if $file !~ /^\//;
            # Add the file to our read array
            push @hostscfg, $file;
         }

         # Similarly, but different, for directory
         if($line =~ /^\s*directory\s+(\S+)$/i) {
            require File::Find;
            import File::Find;
            my $dir = $1;
            do_log("Looking for hosts.cfg files in $dir",3) if $g{debug};
            find(sub {push @hostscfg,$File::Find::name},$dir);

         # Else see if this line matches the ip/host hosts.cfg format
         } elsif($line =~ /^\s*(\d+\.\d+\.\d+\.\d+)\s+(\S+)(.*)$/i) {
            my ($ip, $host, $xymonopts) = ($1, $2, $3);

            # Skip if the NET tag does not match this site
            do_log("Checking if $xymonopts matches NET:" . $g{XYMONNETWORK} . ".",5) if $g{debug};
            if ($g{XYMONNETWORK} ne '') {
               if ($xymonopts !~ / NET:$g{XYMONNETWORK}/) {
                  do_log("The NET for $host is not $g{XYMONNETWORK}. Skipping.",3);
                  next;
               }
            }

            # See if we can find our xymontag to let us know this is a devmon host
            if($xymonopts =~ /$g{xymontag}(:\S+|\s+|$)/) {
               my $options = $1;
               $options = '' if !defined $options or $options =~ /^\s+$/;
               $options =~ s/,\s+/,/; # Remove spaces in a comma-delimited list
               $options =~ s/^://;

               # Skip the .default. host, defined
               do_log("Can't use Devmon on the .default. host, sorry.",0)
                  and next if $host eq '.default.';

               # If this IP is 0.0.0.0, try and get IP from DNS
               if($ip eq '0.0.0.0') {
                  my (undef, undef, undef, undef, @addrs) = gethostbyname $host;
                  do_log("Unable to resolve DNS name for host '$host'",0)
                     and next FILELINE if !@addrs;
                  $ip = join '.', unpack('C4', $addrs[0]);
               }

               # Make sure we dont have duplicates
               if(defined $hosts_cfg{$host}) {
                  my $old = $hosts_cfg{$host}{ip};
                  do_log("Refusing to redefine $host from '$old' to '$ip'",0);
                  next;
               }

               # See if we have a custom cid
               if($options =~ s/(?:,|^)cid\((\S+?)\),?//) {
                  $hosts_cfg{$host}{cid} = $1;
                  $custom_cids = 1;
               }

               # See if we have a custom IP
               if($options =~ s/(?:,|^)ip\((\d+\.\d+\.\d+\.\d+)\),?//) {
                  $ip = $1;
               }

               # See if we have a custom port
               if($options =~ s/(?:,|^)port\((\d+?)\),?//) {
                  $hosts_cfg{$host}{port} = $1;
               }

               # Look for vendor/model override
               if($options =~ s/(?:,|^)model\((\S+?)\),?//) {
                  my ($vendor, $model) = split /;/, $1, 2;
                  do_log("Syntax error in model() option for $host",0) and next
                  if !defined $vendor or !defined $model;
                  do_log("Unknown vendor in model() option for $host",0) and next
                  if !defined $g{templates}{$vendor};
                  do_log("Unknown model in model() option for $host",0) and next
                  if !defined $g{templates}{$vendor}{$model};
                  $hosts_cfg{$host}{vendor} = $vendor;
                  $hosts_cfg{$host}{model}  = $model;
               }

               # Read custom exceptions
               if($options =~ s/(?:,|^)except\((\S+?)\)//) {
                  for my $except (split /,/, $1) {
                     my @args = split /;/, $except;
                     do_log("Invalid exception clause for $host",0) and next
                     if scalar @args < 3;
                     my $test = shift @args;
                     my $oid  = shift @args;
                     for my $valpair (@args) {
                        my ($sc, $val) = split /:/, $valpair, 2;
                        my $type = $exc_sc{$sc}; # Process shortcut text
                        do_log("Unknown exception shortcut '$sc' for $host") and next
                        if !defined $type;
                        $hosts_cfg{$host}{except}{$test}{$oid}{$type} = $val;
                     }
                  }
               }

               # Read custom thresholds
               if($options =~ s/(?:,|^)thresh\((\S+?)\)//) {
                  for my $thresh (split /,/, $1) {
                     my @args = split /;/, $thresh;
                     do_log("Invalid threshold clause for $host",0) and next
                     if scalar @args < 3;
                     my $test = shift @args;
                     my $oid  = shift @args;
                     for my $valpair (@args) {
                        my ($sc, $val) = split /:/, $valpair, 2;
                        my $type = $thr_sc{$sc}; # Process shortcut text
                        do_log("Unknown exception shortcut '$sc' for $host") and next
                        if !defined $type;
                        $hosts_cfg{$host}{thresh}{$test}{$oid}{$type} = $val;
                     }
                  }
               }

               # Default to all tests if they arent defined
               my $tests = $1 if $options =~ s/(?:,|^)tests\((\S+?)\)//;
               $tests = 'all' if !defined $tests;

               do_log("Unknown devmon option ($options) on line " .
                  "$. of $hostscfg",0) and next if $options ne '';

               $hosts_cfg{$host}{ip}    = $ip;
               $hosts_cfg{$host}{tests} = $tests;

               # Incremement our host counter, used to tell if we should bother
               # trying to query for new hosts...
               ++$hosts_left;
            }
         }
      }
      close HOSTSCFG;

   } while @hostscfg; # End of do {} loop

   # Gather our existing hosts
   my %old_hosts = read_hosts();

   # Put together our query hash
   my %snmp_input;

   # Get snmp query params from global conf
   read_global_config();

   # First go through our existing hosts and see if they answer snmp
   do_log("Querying pre-existing hosts",1) if %old_hosts;

   for my $host (keys %old_hosts) {
      # If they dont exist in the new hostscfg, skip 'em
      next if !defined $hosts_cfg{$host};

      my $vendor  = $old_hosts{$host}{vendor};
      my $model   = $old_hosts{$host}{model};

      # If their template doesnt exist any more, skip 'em
      next if !defined $g{templates}{$vendor}{$model};

      my $snmpver = $g{templates}{$vendor}{$model}{snmpver};
      $snmp_input{$host}{dev_ip} = $hosts_cfg{$host}{ip};
      $snmp_input{$host}{cid}    = $old_hosts{$host}{cid};
      $snmp_input{$host}{port}   = $old_hosts{$host}{port};
      $snmp_input{$host}{dev}    = $host;
      $snmp_input{$host}{ver}    = $snmpver;

      # Add our sysdesc oid
      $snmp_input{$host}{nonreps}{$sysdesc_oid} = 1;
   }

   # Throw data to our query forks
   dm_snmp::snmp_query(\%snmp_input);

   # Now go through our resulting snmp-data
   OLDHOST: for my $host (keys %{$g{snmp_data}}) {
      my $sysdesc = $g{snmp_data}{$host}{$sysdesc_oid}{val};
      $sysdesc = 'UNDEFINED' if !defined $sysdesc;
      do_log("$host sysdesc = ::: $sysdesc :::",0) if $g{debug};
      next OLDHOST if $sysdesc eq 'UNDEFINED';

      # Catch vendor/models override with the model() option
      if(defined $hosts_cfg{$host}{vendor}) {
         %{$new_hosts{$host}}        = %{$hosts_cfg{$host}};
         $new_hosts{$host}{cid}    = $old_hosts{$host}{cid};
         $new_hosts{$host}{port}   = $old_hosts{$host}{port};

         --$hosts_left;
         do_log("Discovered $host as a $hosts_cfg{$host}{vendor} " .
            "$hosts_cfg{$host}{model}",2);
         next OLDHOST;
      }

      # Okay, we have a sysdesc, lets see if it matches any of our templates
      OLDMATCH: for my $vendor (keys %{$g{templates}}) {
         OLDMODEL: for my $model (keys %{$g{templates}{$vendor}}) {
            my $regex = $g{templates}{$vendor}{$model}{sysdesc};

            # Careful /w those empty regexs
            do_log("Regex for $vendor/$model appears to be empty.",0)
               and next if !defined $regex;

            # Skip if this host doesnt match the regex
            if ($sysdesc !~ /$regex/) {
               do_log("$host did not match $vendor : $model : $regex", 4)
               if $g{debug};
               next OLDMODEL;
            }

            # We got a match, assign the pertinent data
            %{$new_hosts{$host}}        = %{$hosts_cfg{$host}};
            $new_hosts{$host}{cid}    = $old_hosts{$host}{cid};
            $new_hosts{$host}{port}   = $old_hosts{$host}{port};
            $new_hosts{$host}{vendor} = $vendor;
            $new_hosts{$host}{model}  = $model;

            --$hosts_left;
            do_log("Discovered $host as a $vendor $model",2);
            last OLDMATCH;
         }
      }
   }

   # Now go through each cid from most common to least
   my @snmpvers = (2, 1);

   # For our new hosts, query them first with snmp v2, then v1 if v2 fails
   for my $snmpver (@snmpvers) {

      # Dont bother if we dont have any hosts left to query
      next if $hosts_left < 1;

      # First query hosts with custom cids
      if($custom_cids) {
         do_log("Querying new hosts /w custom cids using snmp v$snmpver",1);

         # Zero out our data in and data out hashes
         %{$g{snmp_data}} = ();
         %snmp_input = ();

         for my $host (sort keys %hosts_cfg) {
            # Skip if they dont have a custom cid
            next if !defined $hosts_cfg{$host}{cid};
            # Skip if they have already been succesfully queried
            next if defined $new_hosts{$host};

            # Throw together our query data
            $snmp_input{$host}{dev_ip} = $hosts_cfg{$host}{ip};
            $snmp_input{$host}{cid}    = $hosts_cfg{$host}{cid};
            $snmp_input{$host}{port}   = $hosts_cfg{$host}{port};
            $snmp_input{$host}{dev}    = $host;
            $snmp_input{$host}{ver}    = $snmpver;

            # Add our sysdesc oid
            $snmp_input{$host}{nonreps}{$sysdesc_oid} = 1;
         }

         # Reset our failed hosts
         $g{fail} = {};

         # Throw data to our query forks
         dm_snmp::snmp_query(\%snmp_input);

         # Now go through our resulting snmp-data
         NEWHOST: for my $host (keys %{$g{snmp_data}}) {
            my $sysdesc = $g{snmp_data}{$host}{$sysdesc_oid}{val};
            $sysdesc = 'UNDEFINED' if !defined $sysdesc;
            do_log("$host sysdesc = ::: $sysdesc :::",0) if $g{debug};
            next NEWHOST if $sysdesc eq 'UNDEFINED';

            # Catch vendor/models override with the model() option
            if(defined $hosts_cfg{$host}{vendor}) {
               %{$new_hosts{$host}}        = %{$hosts_cfg{$host}};
               --$hosts_left;

               do_log("Discovered $host as a $hosts_cfg{$host}{vendor} " .
                  "$hosts_cfg{$host}{model}",2);
               last NEWHOST;
            }

            # Try and match sysdesc
            NEWMATCH: for my $vendor (keys %{$g{templates}}) {
               NEWMODEL: for my $model (keys %{$g{templates}{$vendor}}) {

                  # Skip if this host doesnt match the regex
                  my $regex = $g{templates}{$vendor}{$model}{sysdesc};
                  if ($sysdesc !~ /$regex/) {
                     do_log("$host did not match $vendor : $model : $regex", 0) if $g{debug};
                     next NEWMODEL;
                  }

                  # We got a match, assign the pertinent data
                  %{$new_hosts{$host}}        = %{$hosts_cfg{$host}};
                  $new_hosts{$host}{vendor} = $vendor;
                  $new_hosts{$host}{model}  = $model;
                  --$hosts_left;

                  # If they are an old host, they probably changes models...
                  if(defined $old_hosts{$host}) {
                     my $old_vendor = $old_hosts{$host}{vendor};
                     my $old_model  = $old_hosts{$host}{model};
                     if($vendor ne $old_vendor or $model ne $old_model) {
                        do_log("$host changed from a $old_vendor $old_model " .
                           "to a $vendor $model",1);
                     }
                  } else {
                     do_log("Discovered $host as a $vendor $model",1);
                  }
                  last NEWMATCH;
               }
            }

            # Make sure we were able to get a match
            if(!defined $new_hosts{$host}) {
               do_log("No matching templates for device: $host",0);
               # Delete the hostscfg key so we dont throw another error later
               delete $hosts_cfg{$host};
            }
         }
      }

      # Now query hosts without custom cids
      for my $cid (split /,/, $g{snmpcids}) {

         # Dont bother if we dont have any hosts left to query
         next if $hosts_left < 1;

         do_log("Querying new hosts using cid '$cid' and snmp v$snmpver",1);

         # Zero out our data in and data out hashes
         %{$g{snmp_data}} = ();
         %snmp_input = ();

         # And query the devices that havent yet responded to previous cids
         for my $host (sort keys %hosts_cfg) {

            # Dont query this host if we already have succesfully done so
            next if defined $new_hosts{$host};

            $snmp_input{$host}{dev_ip} = $hosts_cfg{$host}{ip};
            $snmp_input{$host}{port}   = $hosts_cfg{$host}{port};
            $snmp_input{$host}{cid}    = $cid;
            $snmp_input{$host}{dev}    = $host;
            $snmp_input{$host}{ver}    = $snmpver;

            # Add our sysdesc oid
            $snmp_input{$host}{nonreps}{$sysdesc_oid} = 1;
         }

         # Reset our failed hosts
         $g{fail} = {};

         # Throw data to our query forks
         dm_snmp::snmp_query(\%snmp_input);

         # Now go through our resulting snmp-data
         CUSTOMHOST: for my $host (keys %{$g{snmp_data}}) {
            my $sysdesc = $g{snmp_data}{$host}{$sysdesc_oid}{val};
            $sysdesc = 'UNDEFINED' if !defined $sysdesc;
            do_log("$host sysdesc = ::: $sysdesc :::",0) if $g{debug};
            next CUSTOMHOST if $sysdesc eq 'UNDEFINED';

            # Catch vendor/models override with the model() option
            if(defined $hosts_cfg{$host}{vendor}) {
               %{$new_hosts{$host}}        = %{$hosts_cfg{$host}};
               $new_hosts{$host}{cid}    = $cid;
               --$hosts_left;

               do_log("Discovered $host as a $hosts_cfg{$host}{vendor} " .
                  "$hosts_cfg{$host}{model}",2);
               next CUSTOMHOST;
            }

            # Try and match sysdesc
            CUSTOMMATCH: for my $vendor (keys %{$g{templates}}) {
               CUSTOMMODEL: for my $model (keys %{$g{templates}{$vendor}}) {

                  # Skip if this host doesnt match the regex
                  my $regex = $g{templates}{$vendor}{$model}{sysdesc};
                  if ($sysdesc !~ /$regex/) {
                     do_log("$host did not match $vendor : $model : $regex", 0)
                     if $g{debug};
                     next CUSTOMMODEL;
                  }

                  # We got a match, assign the pertinent data
                  %{$new_hosts{$host}}        = %{$hosts_cfg{$host}};
                  $new_hosts{$host}{cid}    = $cid;
                  $new_hosts{$host}{vendor} = $vendor;
                  $new_hosts{$host}{model}  = $model;
                  --$hosts_left;

                  # If they are an old host, they probably changed models...
                  if(defined $old_hosts{$host}) {
                     my $old_vendor = $old_hosts{$host}{vendor};
                     my $old_model  = $old_hosts{$host}{model};
                     if($vendor ne $old_vendor or $model ne $old_model) {
                        do_log("$host changed from a $old_vendor $old_model " .
                           "to a $vendor $model",1);
                     }
                  } else {
                     do_log("Discovered $host as a $vendor $model",1);
                  }
                  last CUSTOMMATCH;
               }
            }

            # Make sure we were able to get a match
            if(!defined $new_hosts{$host}) {
               do_log("No matching templates for device: $host",0);
               # Delete the hostscfg key so we dont throw another error later
               delete $hosts_cfg{$host};
            }
         }
      }
   }

   # Go through our hosts.cfg and see if we failed any queries on the
   # devices;  if they were previously defined, just leave them be
   # at let them go clear.  If they are new, drop a log message
   for my $host (keys %hosts_cfg) {
      next if defined $new_hosts{$host};

      if(defined $old_hosts{$host}) {
         # Couldnt query pre-existing host, maybe temporarily unresponsive?
         %{$new_hosts{$host}} = %{$old_hosts{$host}};
      } else {
         # Throw a log message complaining
         do_log("Could not query device: $host",0);
      }
   }

   # All done, now we just need to write our hosts to the DB
   if($g{multinode} eq 'yes') {

      do_log("Updating database",1);
      # Update database
      for my $host (keys %new_hosts) {
         my $ip     = $new_hosts{$host}{ip};
         my $vendor = $new_hosts{$host}{vendor};
         my $model  = $new_hosts{$host}{model};
         my $tests  = $new_hosts{$host}{tests};
         my $cid    = $new_hosts{$host}{cid};
         my $port   = $new_hosts{$host}{port};

         $cid .= "::$port" if defined $port;

         # Update any pre-existing hosts
         if(defined $old_hosts{$host}) {
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
            if($changes ne '') {
               chop $changes;
               db_do("update devices set $changes where name='$host'");
            }

            # Go through our custom threshes and exceptions, update as needed
            for my $test (keys %{$new_hosts{$host}{thresh}}) {
               for my $oid (keys %{$new_hosts{$host}{thresh}{$test}}) {
                  for my $color (keys %{$new_hosts{$host}{thresh}{$test}{$oid}}) {
                     my $val = $new_hosts{$host}{thresh}{$test}{$oid}{$color};
                     my $old_val = $old_hosts{$host}{thresh}{$test}{$oid}{$color};

                     if (defined $val and defined $old_val and $val ne $old_val) {
                        db_do("update custom_threshs set val='$val' where " .
                           "host='$host' and test='$test' and color='$color'");
                     } elsif(defined $val and !defined $old_val) {
                        db_do("delete from custom_threshs where " .
                           "host='$host' and test='$test' and color='$color'");
                        db_do("insert into custom_threshs values " .
                           "('$host','$test','$oid','$color','$val')");
                     } elsif(!defined $val and defined $old_val) {
                        db_do("delete from custom_threshs where " .
                           "host='$host' and test='$test' and color='$color'");
                     }
                  }
               }
            }

            # Exceptions
            for my $test (keys %{$new_hosts{$host}{except}}) {
               for my $oid (keys %{$new_hosts{$host}{except}{$test}}) {
                  for my $type (keys %{$new_hosts{$host}{except}{$test}{$oid}}) {
                     my $val = $new_hosts{$host}{except}{$test}{$oid}{$type};
                     my $old_val = $old_hosts{$host}{except}{$test}{$oid}{$type};

                     if (defined $val and defined $old_val and $val ne $old_val) {
                        db_do("update custom_excepts set data='$val' where " .
                           "host='$host' and test='$test' and type='$type'");
                     } elsif(defined $val and !defined $old_val) {
                        db_do("delete from custom_excepts where " .
                           "host='$host' and test='$test' and type='$type'");
                        db_do("insert into custom_excepts values " .
                           "('$host','$test','$oid','$type','$val')");
                     } elsif(!defined $val and defined $old_val) {
                        db_do("delete from custom_excepts where " .
                           "host='$host' and test='$test' and type='$type'");
                     }
                  }
                  # Clean up exception types that may have been present in the past
                  foreach (keys %{$old_hosts{$host}{except}{$test}{$oid}}) {
                     do_log("Checking for stale exception types $_ on host $host test $test oid $oid") if $g{debug};
                     if (not defined $new_hosts{$host}{except}{$test}{$oid}{$_}) {
                        db_do("delete from custom_excepts where host='$host' and test='$test' and type='$_' and oid='$oid'");
                     }
                  }
               }
            }

         # If it wasnt pre-existing, go ahead and insert it
         } else {
            db_do("delete from devices where name='$host'");
            db_do("insert into devices values ('$host','$ip','$vendor'," .
               "'$model','$tests','$cid',0)");

            # Insert new thresholds
            for my $test (keys %{$new_hosts{$host}{thresh}}) {
               for my $oid (keys %{$new_hosts{$host}{thresh}{$test}}) {
                  for my $color (keys %{$new_hosts{$host}{thresh}{$test}{$oid}}) {
                     my $val = $new_hosts{$host}{thresh}{$test}{$oid}{$color};
                     db_do("insert into custom_threshs values " .
                        "('$host','$test','$oid','$color','$val')");
                  }
               }
            }

            # Insert new exceptions
            for my $test (keys %{$new_hosts{$host}{except}}) {
               for my $oid (keys %{$new_hosts{$host}{except}{$test}}) {
                  for my $type (keys %{$new_hosts{$host}{except}{$test}{$oid}}) {
                     my $val = $new_hosts{$host}{except}{$test}{$oid}{$type};
                     db_do("insert into custom_excepts values " .
                        "('$host','$test','$oid','$type','$val')");
                  }
               }
            }
         }
      }

      # Delete any hosts not in the xymon hosts.cfg file
      for my $host (keys %old_hosts) {
         next if defined $new_hosts{$host};
         do_log("Removing stale host '$host' from DB",2);
         db_do("delete from devices where name='$host'");
         db_do("delete from custom_threshs where host='$host'");
         db_do("delete from custom_excepts where host='$host'");
      }

   # Or write it to our dbfile if we arent in multinode mode
   } else {

      # Textual abbreviations
      my %thr_sc = ( 'red' => 'r', 'yellow' => 'y', 'green' => 'g', 'clear' => 'c', 'purple' => 'p', 'blue' => 'b' );
      my %exc_sc = ( 'ignore' => 'i', 'only' => 'o', 'alarm' => 'ao',
         'noalarm' => 'na' );
      open HOSTFILE, ">$g{dbfile}"
         or log_fatal("Unable to write to dbfile '$g{dbfile}' ($!)",0);

      for my $host (sort keys %new_hosts) {
         my $ip     = $new_hosts{$host}{ip};
         my $vendor = $new_hosts{$host}{vendor};
         my $model  = $new_hosts{$host}{model};
         my $tests  = $new_hosts{$host}{tests};
         my $cid    = $new_hosts{$host}{cid};
         my $port   = $new_hosts{$host}{port};

         $cid .= "::$port" if defined $port;

         # Custom thresholds
         my $threshes = '';
         for my $test (keys %{$new_hosts{$host}{thresh}}) {
            for my $oid (keys %{$new_hosts{$host}{thresh}{$test}}) {
               $threshes .= "$test;$oid";
               for my $color (keys %{$new_hosts{$host}{thresh}{$test}{$oid}}) {
                  my $val = $new_hosts{$host}{thresh}{$test}{$oid}{$color};
                  my $sc  = $thr_sc{$color};
                  $threshes .= ";$sc:$val";
               }
               $threshes .= ',';
            }
            $threshes .= ',' if ($threshes !~ /,$/);
         }
         $threshes =~ s/,$//;

         # Custom exceptions
         my $excepts = '';
         for my $test (keys %{$new_hosts{$host}{except}}) {
            for my $oid (keys %{$new_hosts{$host}{except}{$test}}) {
               $excepts .= "$test;$oid";
               for my $type (keys %{$new_hosts{$host}{except}{$test}{$oid}}) {
                  my $val = $new_hosts{$host}{except}{$test}{$oid}{$type};
                  my $sc  = $exc_sc{$type};
                  $excepts .= ";$sc:$val";
               }
               $excepts .= ',';
            }
            $excepts .= ',' if ($excepts !~ /,$/);
         }
         $excepts =~ s/,$//;

         print HOSTFILE "$host\e$ip\e$vendor\e$model\e$tests\e$cid\e" .
         "$threshes\e$excepts\n";
      }

      close HOSTFILE;
   }

   # Now quit
   &quit(0);
}

# Read hosts in from mysql DB in multinode mode, or else from disk
sub read_hosts {
   my %hosts = ();

   do_log("DEBUG CFG: running read_hosts",0) if $g{debug};

   # Multinode
   if($g{multinode} eq 'yes') {
      my @arr = db_get_array("name,ip,vendor,model,tests,cid from devices");
      for my $host (@arr) {
         my ($name,$ip,$vendor,$model,$tests,$cid) = @$host;
         next if ($g{hostonly} ne '' and $name !~ /$g{hostonly}/);

         my $port = $1 if $cid =~ s/::(\d+)$//;

         $hosts{$name}{ip}     = $ip;
         $hosts{$name}{vendor} = $vendor;
         $hosts{$name}{model}  = $model;
         $hosts{$name}{tests}  = $tests;
         $hosts{$name}{cid}    = $cid;
         $hosts{$name}{port}   = $port;
      }

      @arr = db_get_array("host,test,oid,type,data from custom_excepts");
      for my $except (@arr) {
         my ($name,$test,$oid,$type,$data) = @$except;
         $hosts{$name}{except}{$test}{$oid}{$type} = $data
         if defined $hosts{$name};
      }

      @arr = db_get_array("host,test,oid,color,val from custom_threshs");
      for my $thresh (@arr) {
         my ($name,$test,$oid,$color,$val) = @$thresh;
         $hosts{$name}{thresh}{$test}{$oid}{$color}  = $val
         if defined $hosts{$name};
      }

   # Singlenode
   } else {

      # Hashes containing textual shortcuts for Xymon exception & thresholds
      my %thr_sc = ( 'r' => 'red', 'y' => 'yellow', 'g' => 'green', 'c' => 'clear', 'p' => 'purple', 'b' => 'blue' );
      my %exc_sc = ( 'i' => 'ignore', 'o' => 'only', 'ao' => 'alarm',
         'na' => 'noalarm' );
      # Statistic variables (done here in singlenode, instead of syncservers)
      my $numdevs = 0;
      my $numtests = 0;

      # Check if the hosts file even exists
      return %hosts if !-e $g{dbfile};

      # Open and read in data
      open HOSTS, $g{dbfile} or
      log_fatal("Unable to open host file: $g{dbfile} ($!)", 0);

      my $num;
      FILELINE: for my $line (<HOSTS>) {
         chomp $line;
         my ($name,$ip,$vendor,$model,$tests,$cid,$threshes,$excepts)
         = split /\e/, $line;
         ++$num;

         do_log("Invalid entry in host file at line $num.",0) and next
         if !defined $cid;

         next if ($g{hostonly} ne '' and $name !~ /$g{hostonly}/);
         my $port = $1 if $cid =~ s/::(\d+)$//;

         $hosts{$name}{ip}     = $ip;
         $hosts{$name}{vendor} = $vendor;
         $hosts{$name}{model}  = $model;
         $hosts{$name}{tests}  = $tests;
         $hosts{$name}{cid}    = $cid;
         $hosts{$name}{port}   = $port;

         if(defined $threshes and $threshes ne '') {
            for my $thresh (split ',', $threshes) {
               my @args = split /;/, $thresh, 4;
               my $test = shift @args;
               my $oid  = shift @args;
               for my $valpair (@args) {
                  my ($sc, $val) = split /:/, $valpair, 2;
                  my $color = $thr_sc{$sc};
                  $hosts{$name}{thresh}{$test}{$oid}{$color} = $val;
               }
            }
         }

         if(defined $excepts and $excepts ne '') {
            for my $except (split ',', $excepts) {
               my @args = split /;/, $except, 4;
               my $test = shift @args;
               my $oid  = shift @args;
               for my $valpair (@args) {
                  my ($sc, $val) = split /:/, $valpair, 2;
                  my $type = $exc_sc{$sc};
                  $hosts{$name}{except}{$test}{$oid}{$type} = $val;
               }
            }
         }

         # Statistics
         ++$numdevs;
         $numtests += ($tests =~ tr/,/,/) + 1;
      }
      close HOSTS;

      $g{numdevs}      = $numdevs;
      $g{numtests}     = $numtests;
      $g{avgtestsnode} = 'n/a';
   }

   return %hosts;
}

# Daemonize: go to daemon mode and fork into background
# Much code shamelessly stolen from Proc::Daemon by Earl Hood
sub daemonize {
   return if !$g{daemonize};

   # Now fork our child process off
   if(my $pid = do_fork()) {
      # Parent process, we should die
      do_log("Forking to background process $pid",1);
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
   my $openmax = POSIX::sysconf( &POSIX::_SC_OPEN_MAX );
   $openmax = 64 if !defined $openmax or $openmax < 0;
   for my $i (0 .. $openmax) { POSIX::close($i) }

   # Reopen stderr, stdout, stdin to /dev/null
   open(STDIN,  "+>/dev/null");
   open(STDOUT, "+>&STDIN");
   open(STDERR, "+>&STDIN");

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
   my ($pid, $tries);
   FORK: {
      if (defined($pid = fork)) {
         return $pid;

      # If we are out of process space, wait 1 second, then try 4 more times
      } elsif ($! =~ /No more process/ and ++$tries < 5) {
         sleep 1;
         redo FORK;
      } elsif($! ne '') {
         log_fatal("Can't fork: $!",0);
      }
   }
}

# Find path to a binary file on the system
sub bin_path {
   my ($bin) = @_;

   # Determine where we should search for binaries
   my @pathdirs;
   @pathdirs = split /:/, $ENV{PATH} if defined $ENV{PATH};
   @pathdirs = ('/bin','/usr/bin','/usr/local/bin') if $#pathdirs == -1;

   # Now iterate through our dirs, and return if we find a binary
   for my $dir (@pathdirs) {

      # Remove any trailing slashes
      $dir =~ s/(.+)\/$/$1/;
      return "$dir/$bin" if -x "$dir/$bin";
   }

   # Didnt find it, return undef
   return undef;
}

# Sub called by sort, returns results numerically ascending
sub na { $a <=> $b }

# Sub called by sort, returns results numerically descending
sub nd { $b <=> $a }

# Print help
sub usage {
   die
   "Devmon v$g{version}, a device monitor for Xymon\n" .
   "\n" .
   "Usage: devmon [arguments]\n" .
   "\n" .
   "  Arguments:\n" .
   "   -c[onfigfile]  Specify config file location\n" .
   "   -db[file]      Specify database file location\n" .
   "   -f[oregrond]   Run in foreground. Prevents running in daemon mode\n" .
   "   -h[ostonly]    Poll only hosts matching the pattern that follows\n" .
   "   -p[rint]       Don't send message to display server but print it on stdout\n" .
   "   -v[erbose]     Verbose mode. The more v's, the more vebose logging\n" .
   "   -de[bug]       Print debug output (this can be quite extensive)\n" .
   "\n" .
   "  Mutually exclusive arguments:\n" .
   "   -r[eadhostscfg]   Read in data from the Xymon hosts.cfg file\n" .
   "   -syncc[onfig]    Update multinode DB with the global config options\n" .
   "                    configured on this local node\n" .
   "   -synct[emplates] Update multinode device templates with the template\n" .
   "                    data on this local node\n" .
   "   -r[esetowners]   Reset multinode device ownership data.  This will\n" .
   "                    cause all nodes to recalculate ownership data\n" .
   "\n";
}

# Sub to call when we quit, be it normally or not
sub quit {
   my ($retcode) = @_;
   $retcode = 0 if (!defined $retcode);
   if ($retcode !~ /^\d*$/) {
      if($g{parent}) {
         do_log("Master received signal $retcode, shutting down with return code 0",3);
      } else {
         do_log("Fork with pid $$ received signal $retcode, shutting down with return code 0",5);
      }
      $retcode = 0;
   }

   $g{shutting_down} = 1;

   # Only run this if we are the parent process
   if($g{parent}) {
      do_log("Shutting down",0) if $g{initialized};
      unlink $g{pidfile} if $g{initialized} and -e $g{pidfile};
      $g{log}->close if defined $g{log} and $g{log} ne '';
      $g{dbh}->disconnect() if defined $g{dbh} and $g{dbh} ne '';

      # Clean up our forks if we left any behind, first by killing them nicely
      for my $fork (keys %{$g{forks}}) {
         my $pid = $g{forks}{$fork}{pid};
         kill 15, $pid if defined $pid;
      }
      sleep 1;
      # Then, if they are still hanging around...
      for my $fork (keys %{$g{forks}}) {
         my $pid = $g{forks}{$fork}{pid};
         kill 9, $pid if defined $pid and kill 0, $pid; # Kick their asses
      }

   }

   exit $retcode;
}

END {
   &quit if !$g{shutting_down};
}
