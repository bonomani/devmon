
 DEVMON GRAPHING IN HOBBIT
=====================================================================

  ----------------------------------
  Quick start
  ----------------------------------
  The rest of this document covers the implementation of graphs for 
  Devmon in Hobbit/Xymon, however with current versions of Xymon and
  Devmon, only some configuration should be required.

  For new Xymon installations of 4.2.2 or later, the only step that
  you should need to do is the first part of (3), to have graphs
  working for the Devmon if_load and temp tests. The other steps
  are provided here to allow users to ensure that they have all the
  required configuration, as well as how to enable graphs for other
  tests.

  1)Install Xymon 4.2.2 or later. The rrd collector for devmon was
    merged into Xymon before the release of 4.2.2. No additional
    patches or scripts are required.
  2)Ensure (for each devmon test you want to graph with the devmon 
    collector) "testname=devmon" is in TEST2RRD in Xymon's
    hobbitserver.cfg file. E.g.:

    TEST2RRD="cpu=la,disk ... ,if_load=devmon,temp=devmon"

    By default, Xymon 4.2.2 or later should enable the devmon
    collector for the if_load and temp tests.

    Restart Xymon (or, kill the hobbitd_rrd task for status messages, 
    hobbitlaunch will restart it) so hobbitd_rrd gets the updated 
    environment variable, if you had to make any changes.

  At this point, you should find that Xymon is generating RRD files
  for any test using the devmon collector for which it has received
  status updates, e.g. $BBVAR/rrd/<hostname>/<testname>.<instancename>.rrd,
  such as $BBVAR/rrd/router/if_load.Se0_1.rrd

  3)Ensure that Xymon has graph definitions for the relevant tests.
    Graph defintions for many of the tests that have graphs enabled
    are provided in the file extras/devmon-graph.cfg. Either append
    this to Xymon's hobbitgraph.cfg, or create a directory to store
    additional graph definition files (e.g. /etc/xymon/hobbitgraph.d),
    add "directory /etc/xymon/hobbitgraph.d" to hobbitgraph.cfg, 
    and place extras/devmon-graph.cfg in /etc/xymon/hobbitgraph.d.

    Ensure that Xymon knows to try and generate graphs for devmon and
    the tests you have, by ensuring devmon and the test names are included
    in the GRAPHS variable in hobbitserver.cfg. If you prefer to have
    a single instance on graphs for a particular test, appent ::1 to the
    test name, e.g. "if_load::1".

    By default, Xymon 4.2.2 includes "devmon::1,if_load::1,temp" in the
    GRAPHS variable.

 
  ---------------------------------------------------------
  Extending the existing Devmon/Xymon graphing to new tests
  ---------------------------------------------------------

  -- Graphing tests with rrd repeater tables
  ----------------------------------
  -------------------------------------------------------------------

  One of the useful additions to devmon 0.3 is the rrd option to 
  repeater tables. For example, a TABLE line such as:

	TABLE:rrd(DS:ds0:ifInOctets:COUNTER; DS:ds1:ifOutOctets:COUNTER)

  will result in Devmon generatingan RRD header:
  <!--DEVMON RRD: if_load 0 0

  followed by the DS definitions:
  DS:ds0:DERIVE:600:0:U DS:ds1:DERIVE:600:0:U

  followed by the values for each instance, e.g.:
  eth0.0 3506583:637886
   
  Xymon 4.2.2 and later ship with an RRD collector module for devmon,
  no patches or scripts are necessary, however Xymon needs to know
  which tests should have their status messages sent to this module, so
  the changes to hobbitserver.cfg should be verified.

  In order for Hobbit to collect the values and update the RRD files, you 
  need to either use a script with the --extra-script option to 
  hobbitd_rrd (such as extras/devmon-rrd.pl) or use the supplied devmon
  rrd collector module (extras/do_devmon.c) and the patch (
  extras/hobbit-4.2.0-devmon.patch) which adds the collector to do_rrd.c.

  The rrd collector module is the recommended approach, and has been merged
  into Xymon 4.2.2.

  Finally, you need to map each test for which you want to collect data
  provided in the devmon format to be collected by the devmon collector,
  by adding testname=devmon to TEST2RRD in hobbitserver.cfg (e.g. 
  if_load=devmon).

  Finally, you need a graph definition, such as the one shipped in
  extras/devmon-graph.cfg. If you use the "directory" feature in
  Hobbit's hobbitgraph.cfg, you can simply copy the file to the 
  directory specified.

  At present, most if_load tests support this method, and the compaq-server,
  cisco-6509, and dell-poweredge templates support it for the 'temp' test.

---------------------------------------------------------------------

 USING HOBBIT FEATURES FROM DEVMON
=====================================================================
 For specific tests, Hobbit already parses information supplied in
 specific formats (typically from old BigBrother extensions). You can
 (ab)use this support to have Hobbit graph values from your own templates.

  ----------------------------------
  -- The 'CPU' test
  ----------------------------------
  -------------------------------------------------------------------
  
    On any device, you would like to graph CPU.

  If you get CPU usilisation value as a percentage, you should add 
  the following lines to the message file in the cpu directory in your 
  template:

	<!--
        <br>CPU 5 min average: {CPUTotal5Min}
	-->

  For example in:

	cisco-asa/cpu/message

  Where CPUTotal5Min is a percentage.
  Wait for 2 passes, and you will get a graph

  ----------------------------------
  -- The 'memory' test
  ----------------------------------
  -------------------------------------------------------------------

  On any device, you would like to graph memory usage.
  You should add the following lines to the message file in the memory 
  directory in your template.

  	<!-- 
        Physical {mem_used_per}%
	-->    

  For example in:

	cisco-asa/memory/message

  Where mem_used_per is a percentage.
  Way for 2 passes, and you will get a graph.

  ----------------------------------
  -- Using ncv (e.g. the 'connects' test)
  ----------------------------------
  -------------------------------------------------------------------

  If you have a test where the value you want to graph is not a repeater
  (so Devmon's RRD collector isn't useful), and it isn't for a test
  that Hobbit already understands a specific format, then Hobbit's NCV
  collector is probably the last remaining option. Add a Name-colon-value
  line to your message, surrounded by HTML tags (if you want to hide the
  line on the normal Hobbit display.

  For example, to graph the numbers of connections you should add the
  following lines to the message file in the connects directory in your
  template:

	Connections: {cur_conn}

  For example in:
	
	cisco-asa/connects/message

  Where cur_conn is your number of connections you want to graph.

  Then, add "connects=ncv" to TEST2RRD in hobbitserver.cfg, as well as the
  RRD options for connects, via:
  NCV_connects="*:GAUGE"

  Finally, you need a graph definition for connects, such as the one shipped in 
  extras/devmon-graph.cfg
  ----------------------------------

$Id: GRAPHING 132 2009-04-02 07:26:21Z buchanmilne $
