# Changelog  
**Contributors of specific features/patches are listed in parentheses next to the respective entry.**

## Devmon v0.25.03
- **New Features**:
  - Merged all polling under the new partial retry algorithm:
    - Added support for SNMPv3.
    - Default use of Net-SNMP (10% speed gain).
  - **Default Template**:
    - Longest regex match first.
- **Bug fixes**:
  - Minor bug fixes.

## Devmon v0.25.01
- **Bug fixes**:
  - Stabilized SNMP polling algorithm.
  - Corrected the description of the Fan in `extras/devmon-graphs.cfg` (Jezzaaa).
- **New Template**:
  - Added Aten (Supermicro IPMI interface).
- **Authors**:
  - Project officially transferred by the original author (eschwim).

## Devmon v0.24.03
- Converted, simplified, and updated documentation to Markdown format.
- **Bug fixes**:
  - Fixed an issue where the discovery process sometimes failed.

## Devmon v0.23.09
- **Right Table Alignment Feature**: (W. Nelis).
- **Bug fixes**.

## Devmon v0.23.07
- **Enhanced SNMP Retry Logic**:
  - Prevented memory leaks by eliminating fork failures.
  - Improved control of SNMP OID walking process using low-level `snmpgetbulk` queries.
  - Increased monitoring speed, especially for slower devices.
  - **Engine Transition**: Default engine switched to SNMP_Session (Pure Perl) as new logic is not implemented for NET-SNMP.
- **Bug fixes**.

## Devmon v0.21.09
- **Stabilized SNMPv3** (Thanks to Stef Coene).
- **New Command Line Option**:
  - Single device and test: `devmon -o 1.1.1.1=fan` 
  - No need to stop Devmon anymore.
  - Results printed to stdout and Xymon.
  - See `devmon -?` for details.
- **Logging Restructured** (Further work needed):
  - See discussion.
  - Use `devmon -t[race]` for detailed logs.

## Devmon v0.21.08
- First SNMPv3 version (refer to install instructions).
- **Template Updates**:
  - Updated template for VMware7 (Thanks to Roemer).
- **Code Updates**:
  - Tidied up code (beginning to follow best practices).
  - Updated logs.
- **Bug fixes**.

## Devmon v0.21.07
- **No new features or bug fixes**.
- Moved the Wiki (GitHub Wikis are not indexed by Google).
- Updated README and CHANGELOG.

## Devmon v0.21.06
- **New Features**:
  - **CPU Revamp** (Cisco, Huawei), focusing mainly on the "uptime" part.
    - Added reboot cause analysis with an auto-disable timer.
    - Improved uptime value calculation with SNMP and system OID.
  - **Threshold Automatch**: Now accepts multiple values.
    - Allows multiple empty (automatch) thresholds for an OID.
    - Prefers empty thresholds of the current color.
- **Bug fixes**:
  - Fixed issues with MATH transformation using constants (without other OID dependencies).
  - Resolved issues with TSWITCH calculation.
  - Fixed compatibility with Perl 5.28 (Thanks to Stef Coene).
  - Corrected threshold calculation.
  - Ensured custom thresholds in `hosts.cfg` override others.
  - Allowed BEST thresholds to override inherited errors.

## Devmon v0.16.12
- **Changes since v0.3.1-beta1**:
  - Forked from SourceForge.
  - New release versioning system: 
    - Versioning under 1, as there is room for improvement before releasing version 1.
    - Date-based versioning (e.g., v0.16.12.15 = 2016-12-15).
  - Modified "core" concept: Error propagation is the default behavior.
  - **Improved User-Friendliness**:
    - Enhanced error reporting.
    - Added new color "Blue" for tests that are "Disabled".
  - **New Transforms**:
    - `SET` and `STATISTIC` (documented in `docs/TEMPLATE`) (Thanks to W. Nelis).
  - **Work In Progress** (WIP) Transforms:
    - `COLTRE`: Collect data when there are "parent" OID values.
    - `SORT`: Sort in increasing order (string only).
  - **Template Updates**:
    - Cisco: Added support for Cisco r1800, r1900, r2800, r2900, sw2940, sw2950, sw2960, sw3750, sw3850, sw3650, swIE, rISR, ASA.
    - VMware: Added template for ESXi6.
    - Huawei: Added template support.
  - **Contributions**: Applied patches from many contributors.

`PATCH                                                                     SForge Status Github Status`  
`38 Template for cisco nexus 3500                                           open         fixed                  07.06.2018 07.06.2018`  
`37 Allow for OIDS with flag in message part of a threshold definition      open         fixed                  01.04.2017 01.04.2017`
`36 Enhance REGSUB transformation capabilities                              open         fixed(alternate)       01.04.2017 01.04.2017`   
`35 Replacement for function render_msg in module dm_tests.pm               open         wont/partial fix(bugs) 17.03.2017 24.03.2017`  
`34 Replace an OID errors flag by an empty string incase of a green colour  open         fixed                  26.02.2017 04.03.2017`  
`33 Patch for the (T)SWITCH transform to be able to assign empty string     open         fixed                  24.02.2017 24.02.2017`  
`32 Formatting of result of MATH transform                                  open         reported in todo       06.02.2017 06.02.2017`  
`31 Fix typo in function name                                               open         fixed                  16.01.2017 16.01.2017`  
`30 Support for negative numbers in (T)SWITCH                               open         reported in todo       13.01.2015 13.01.2015`  
`29 Document default in SWITCH transform                                    open         fixed                  14.11.2014 14.11.2014`  
`28 Allow function time in a MATH transform                                 open         wont(use eval trans)   22.10.2014 22.10.2014`  
`27 Add TABLE:sort option                                                   open         fixed(alternate)       26.08.2014 26.08.2014`  
`26 Add transform SET                                                       open         fixed(incompleted)     18.08.2014 18.08.2014`  
`25 Fix bug #13                                                             open         fixed(alternate)       25.06.2014 25.06.2014`  
`24 Align columns of a TABLE to the right side                              open         reported in todo       23.10.2013 23.10.2013`  
`23 Consistent notation OIDs                                                open         fixed/alternate)       04.01.2013 04.01.2013`  
`22 Templates for Cisco 7609 and ITP                                        open         fixed                  29.06.2012 29.06.2012`  
`21 Extend capabilites of transform REGSUB                                  open         fixed(alternate)       10.01.2012 10.01.2012`  
`20 Add transform STATISTIC                                                 open         fixed                  06.01.2012 21.12.2012`  
`17 Fix syntax check of the DELTA transform                                 open         fixed(alternate)       02.01.2012 02.01.2012`  
`16 Change output of SPEED transform                                        open         fixed                  02.01.2012 02.01.2012`  
`15 Improve syntax check DELTA transform                                    open         fixed(alternate)       02.01.2012 02.01.2012`  
`14 Layout of devmon statistics in Xymon, test dm                           open         fixed                  02.01.2012 02.01.2012`  
`13 Template for OpenBSD using Net-SNMP                                     open         fixed                  09.08.2011 09.08.2011`  
`12 snmpEngineTime vs sysUpTimeSecs over 497 days                           open         fixed(alternate)       07.03.2011 07.03.2011`  
`11 Brocade SAN switch template                                             open         wont(see sf comment)   07.08.2010 07.08.2010`  
`10 SUBSTR negative                                                         open-remind  wont fix(disp prob)    04.03.2010 22.01.2011`  
`9  New templates for cisco and hp                                          open         fixed(asa+ps) wont:hp  16.11.2009 16.11.2009`  
`2  Cisco Template for Class Based Weighted Fair Qeueing (QoS)              open         fixed                  06.10.2008 06.10.2008`  

`FEATURE REQUEST`  
`10 New templates for other devices                                         open         wont/part. fixed(1/3)  29.09.2016 29.09.2016`  
`9  Allow for empty repeater-type OIDs                                      open         reported in todo       05.06.2012 05.06.2012`  
`8  exceptions based on other oid values                                    open         reported in todo       19.04.2012 19.04.2012`  
`7  Share templates for similar devices                                     open         reported in todo       22.01.2010 22.01.2010`  
`3  Use OID value in threshold comparison                                   open         reported in todo       31.12.2008 04.04.2011`  
`2  SNMP V3 support                                                         open         reported in todo       17.10.2008 17.10.2008`  

`BUGs`  
`16 Some interface of cisco Router do not appear                            open         nothing to do          20.09.2015 15.03.2017`  
`15 MATH transform fails if with both repeaters and non-repeaters           open         fixed                  22.10.2014 22.10.2014`  
`14 Cisco-6509 wrong oids for serial                                        open-later   wont(cannot test)      21.12.2011 03.01.2013`  
`13 Thresholds remain undefined                                             open         fixed                  30.08.2011 30.08.2011`  
`12 New templates for Cisco 3750 switch                                     open         fixed(alternate)       01.02.2011 01.02.2011`  
`10 Many templates share "sysdesc" in specs                                 open         wont                   22.01.2010 22.01.2010`  
`9  Template exceptions sorted misleadingly                                 open-remind  reported in todo       31.12.2009 22.01.2011`  
`8  devmon goes purple                                                      open         fixed(alternate)       13.11.2009 13.11.2009`  
`6  cisco-2811 has wrong ifName oids                                        open-later   fixed                  19.02.2009 05.02.2010`  
`5  Wrong threshold calculation for Cisco templates                         open         fixed                  03.02.2009 03.02.2009`  


## Devmon v0.3.1-beta1 :: Released 2009-01-23
 Changes since 0.3.0
  - Fix loading non-standard ports from the config file
  - Fix segfault in hobbitd_rrd caused by do_devmon.c and data with spaces in 
     repeater names
  - Fix multiple custom threshholds and exceptions on the same test
  - Send messages to BB/Hobbit/Xymon in debug mode (--debug)
     For the previous behaviour (messages printed to stdout in debug
     and not sent to BB/Hobbit/Xymon), use '--debug -p'
  - Improve error handling, by opening log file immediately after forking, and
     returning non-zero exit codes when exiting due to error (e.g. log_fatal)
  - Fix thresh usage in options example in "USING" documentation
  - Add INDEX transform
  - Ensure repeaters created by CHAIN transform are tagged as such (so they can 
     be primary OID)
  - Close and re-open log files on HUP
  - Init script changes
    -Merge Mandriva init script changes:
     -run as non-root (optional, set RUNASUSER= in /etc/sysconfig/devmon)
     -use reload (or readbbhosts) argument to run --readbbhosts
     -fix return codes
    -Use better killproc (internal_killproc) on platforms without a killproc that
      takes a pid file option (makes stopping devmon more reliable)
    -Add a rotate function/argument
  - Strip spaces off names of repeaters before creating rrd section of message
  - Set a timeout on the socket to hobbit (hardcoded to 10s for now)
  - Use Hobbit/BB environment variables if present
  - Adjust init script to run devmon under Hobbit or BB environment
  - Honour Hobbit BBLOCATION / NET tag 
  - Handle line continuations in bb-hosts file (W.J.M. Nelis)
  - Support BBDATEFORMAT (should provide better dates in Hobbit/BB status messages
     by default if BBDATEFORMAT is set in hobbitserver.cfg) (W.J.M Nelis)
  - Add new STATUS: key for message file, which allows extending the first
     line of the status message
  - Filters in hobbitdboard are regex's, anchor the conn text (Simeon Berkley)

## Devmon v0.3.0 :: Released 2008-04-03
 Changes since 0.3.0-rc1
  - Ensure that send_msgs returns when display server is inaccessible.
    This change fixes the "Devmon turns purple" issue (Buchan Milne)
  - Fix Hobbit-only dont-poll-if-down feature (Buchan Milne)
  - Distribute a more complete patch for hobbit that includes do_devmon.c

## Changes since 0.3.0-beta2
  Changed:
  - Ignore hidden template directories (e.g. .svn) (Francois Lacroix)
  - Add negated regexp threshold (Nathan Hand)
  - Poll each leaf separately (Francois Lacroix)
  - Add 'plain' table option, allowing unformatted repeaters
  - Ignore rows which have empty values for one of the repeaters (to avoid some of the 
    sub-interfaces on Cisco ATM interfaces making the page clear)
  - Template changes
    - Tests for fans, power, temp, log added to compaq-server (Buchan Milne)
    - Add ciscocpu.pl-compatible lines to cpu message files for cisco devices to get cpu graphs from
      Hobbit
     - Alarm/graph on any device name that is not explicitly ignored (so Fa.+ works on 6509, 
       S.+ works on 7600 using 6509 template etc.)
     - Add temp test for cisco-6509
  
  Added:
  - Documentation on graphing (Francois Lacroix and Buchan Milne)
  - Hobbit rrd collector module for devmon (do_devmon.c) (Buchan Milne)
  - Perl extra-script equivalent (Francois Lacroix and Buchan Milne)
  - Patch for Hobbit, to enable devmon rrd collector, ensure devmon graphs work better by default 
    (use multigraphs for if_load, avoid extra broken graphs etc.)
  - Hobbit graph definitions for some devmon RRD-enabled tests (if_load,if_dsc, temp) and one for 
    the connects test (for NCV)
  - New Templates:
    - dell-poweredge for Dell PowerEdge servers running OMSA (Buchan Milne)
    - ibm-rsa2 for IBM Remote Server Adapters (Simeon Berkley)
    - apc-9617 (Simeon Berkley)
    - f5-bigip-lite and f5-bigip (Francois Lacroix)
    - cisco-asa for ASA or PIX with IOS 7.x, or FWSM 3.x (Francois Lacroix)
    - cisco-pix for PIX 6.x (Buchan Milne)
    - linux-openwrt, to demonstrate use of 'plain' option (Buchan Milne)
    - cisco-4500, cisco-msfc2, cisco-5500, cisco-6506, cisco-2811, cisco-3640 (Francois Lacroix)
    - dell-perc for older Dell PowerEdge servers running percsnmp (Buchan Milne)

  Bugfixes:
  - Fix numeric thresholds on branch OIDs (Francois Lacroix)
  - Allow FQDN in NODENAME, and use unstripped FQDN by default (so dm test for devmon node works 
    where hostname is FQDN) (Buchan Milne)


## Changes since 0.2.2

  Changed:
  - If you specify a non-absolute path to a config file (using -c)
    and the file doesn't exist in the current working dir, devmon
    will look in its own directory for the file.
  - Moved default location for PID file to /var/run/devmon.pid
  - Moved templates to their own distribution file and added several
    community-created templates (with proper kudos noted in each template)
  - Changed UNPACK transform type to support more complicated
    (and powerful) unpack expressions, and separator characters.
  - Changed the way numeric primary keys are sorted in tables
    to allow numeric ascending sorts for multi-level leaves.
  - Changed the docs/INSTALLATION to clarify how DEVMON operates.
  - Removed the .rrd OID flag and replaced it with an RRD table
    option.
  - Recoded most translation subroutines to optimize performance
  - Added more debug output, and defined the --debug flag in the help output

  Added:
  - Added a timeout watchdog for all transforms, set at 5 seconds.
  - Added ability to specify SNMP port that a particular device uses
  - Added bi-directional communication with the hobbit server, allowing
    the client to avoid testing against devices which hobbit
    recognizes as unreachable (i.e. a red 'conn' test).
  - Added CHAIN transform, which allows you to chain OIDs together
  - Added ability to display template threshold values in devmon output

  Bugfixes:
  - Fixed DBHOST config file entry so that it allows non
    alpha-numeric characters (which was preventing people from using
    FQDN hostnames).
  - Fixed cisco 3500 templates to correctly translate ifc speed
  - Fixed REGSUB transform to work leaf OIDs (Gaetan Frenoy)
  
## Devmon v0.2.2 :: Released 05/18/2006

  Changed:
  - Fixed cisco templates that had an uneccesary ifSpeed entry
    in the oids file (which was causing the ifSpeed SPEED transform
    to behave erratically).
  - Fixed the TSWITCH transform so Devmon recognizes it correctly.
  - Implemented a workaround for snmp oids that contain
    extended information in the OID variable (i.e. Windows DHCP
    server embeds the subnet address in the SNMP OID).
    This should get rid of any 'xxx is non-numeric in sort' errors.
  - Fixed the MATH transform so that doesnt misinterpret
    some numbers as a divide by zero condition and returning 0.


## Devmon v0.2 beta :: Released 05/09/2006

  Changed:
  - Changed the way the TABLE: message directive is read.
    Options can now be added to the TABLE line to alter the
    default way that Devmon handles table data. 
    Example: TABLE: noalarmsmsg,border=0,pad=10
  - Removed NONHTMLTABLE directive and replaced it with the 'nonhtml'
    TABLE option.
  - Removed the colon from the data input portion of the 
    DELTA transform, which delineated the source OID alias
    and the optional upper limit (replaced it with whitespace,
    to make it more consistent with other transform variables).
  - Removed the (yy:mm:dd) text from the ELAPSED transform.  If you
    want to see this text, specify it explicitly in your message file
  - Changed SWITCH block to give it more functionality.  Existing
    SWITCH transforms should be compatible with this new version.
    Please see the docs/TEMPLATES files for the new version.
  - Various code optimizations, which will hopefully make the
    test logic a little faster.
  - Introduced the ability to do line continuation in a transform
    file via a backslash (\) at the end of a line, thus making
    transform files a little more readable when viewed in a 
    80 column terminal
  - Modified the if_load and if_stat threshold files to include
    the interface name and alias when reporting errors
  - Changed the way tests handle duplicate OID aliaes (i.e. ifInOps
    is used in if_stat, if_load, if_err, etc).  Now tests on the 
    same devices that share an oid name with another tests will 
    only perform the transform on that alias once. This has important
    implications if you use the same OID alias across multiple tests;
    please read 'oids' and 'transform' file sections in the 
    docs/TEMPLATE file for more information.

  Added:
  - TSWITCH transform: similar to SWITCH transform except it can
    inhert threshold results from dependent OID aliases.
  - SUBSTR transform: get a substring of the specific oid
    (faster and more efficient than doing a REGSUB)
  - UNPACK transform: unpack oid data stored in binary form
  - CONVERT transform: convert either hex or octal to a
    decimal integer
  - AND transform: returns a value of 1 if ALL oids passed to
    it are non-zero.
  - OR transform: returns a value of 1 if ANY oids passed to
    it are non-zero.

  - 'border' TABLE option: change html table border value
  - 'pad' TABLE option: change html table cellpadding value
  - 'nonhtml' TABLE option: prints table in NCV format
  - 'noalarmsmsg' TABLE option:  prevents display of "Alarming on" text
    for a TABLE entry.
  - 'alarmsonbottom' TABLE option: prints "Alarming on" text at bottom
    of TABLE data, as opposed to the top.
  - Cisco 2801 template

  Bug fixes:
  - Fixed cisco CPU tests to alarm properly on reboot
  - Fixed the command line config override (Steve Aiello)
  - Fixed problem with non-HTML tables (Dan Vande More)

## Devmon v0.1.2 beta :: Not released

  Added:
  - Support for non-HTML(NCV) type tables
  - Support for embedding RRD data in HTML tables

  Bug fixes:
  - Worked around a bug in older versions of Storable.pm that would cause 
    devmon to crash when using 64bit counters
  - Fixed the order of alarm applications; now alarms by default

## Devmon v0.1.1 beta :: Released 02/28/2006

  Added:
  
  - Ability to resolve IPs from DNS for hosts in bb-hosts /w an IP of 0.0.0.0
  - Added -c command line param to override default devmon.cfg location
  - Added model() option to read_bb_hosts to override autodetection
  - Added upper limit option for DELTA transforms
  
  Bug fixes:
  - TEMPLATES: Changed if_load transform files to properly report % load 
    (Johann Eggers)
  - Fixed DELTA transform issues with 32 and 64bit counter wraps
  - Fixed 'inappropriate ioctl for device' error when forking
    (Craig Boyce & Steve Aiello)
  - Fixed extremely high polltimes when not polling any devices


## Devmon v0.1 beta   :: Released 02/23/2006

   Initial release
