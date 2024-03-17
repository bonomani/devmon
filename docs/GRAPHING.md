# GRAPHING 

## Setup

This document outlines the implementation of graphs for Devmon in Xymon. With current versions of Xymon and Devmon, only some configuration should be necessary.

1. **Configure Devmon tests:** Ensure that for each Devmon test you want to graph with the Devmon collector, "testname=devmon" is in TEST2RRD in Xymon's xymonserver.cfg file. For example:

    ```plaintext
    TEST2RRD="cpu=la,disk ...,if_load=devmon,temp=devmon"
    ```

    By default, Xymon 4.2.2 or later should enable the Devmon collector for the if_load and temp tests. Restart Xymon (or kill the xymond_rrd task for status messages, xymonlaunch will restart it) so xymond_rrd gets the updated environment variable, if you had to make any changes.
  
2. **Graph Definitions:** Ensure that Xymon has graph definitions for the relevant tests. Graph definitions for many of the tests that have graphs enabled are provided in the file `extras/devmon-graph.cfg`. Either append this to Xymon's `xymongraph.cfg`, or create a directory to store additional graph definition files (e.g. `/etc/xymon/xymongraph.d`), add `directory /etc/xymon/xymongraph.d` to `xymongraph.cfg`, and place `extras/devmon-graph.cfg` in `/etc/xymon/xymongraph.d`.

    Ensure that Xymon knows to try and generate graphs for Devmon and the tests you have, by ensuring Devmon and the test names are included in the GRAPHS variable in `xymonserver.cfg`. If you prefer to have a single instance on graphs for a particular test, append `::1` to the test name, e.g. "if_load::1".

    By default, Xymon includes "devmon::1,if_load::1,temp" in the GRAPHS variable.

 
## Extending Devmon/Xymon Graphing to New Tests

### Graphing tests with RRD Repeater Tables

One of the useful additions to Devmon is the RRD option to repeater tables. For example, a `TABLE` line such as:

```plaintext
TABLE:rrd(DS:ds0:ifInOctets:COUNTER; DS:ds1:ifOutOctets:COUNTER)
```

will result in Devmon generating an RRD header:

```plaintext
<!--DEVMON RRD: if_load 0 0
```

followed by the DS definitions:

```plaintext
DS:ds0:DERIVE:600:0:U DS:ds1:DERIVE:600:0:U
```

followed by the values for each instance, e.g.:

```plaintext
eth0.0 3506583:637886
```

You need to map each test for which you want to collect data provided in the Devmon format to be collected by the Devmon collector, by adding `testname=devmon` to `TEST2RRD` in `xymonserver.cfg` (e.g. `if_load=devmon`).

Finally, you need a graph definition, such as the one shipped in `extras/devmon-graph.cfg`. If you use the "directory" feature in Xymon's `xymongraph.cfg`, you can simply copy the file to the directory specified.

At present, most `if_load` tests support this method, and the `compaq-server`, `cisco-6509`, and `dell-poweredge` templates support it for the 'temp' test.


## Using Xymon Features from Devmon
For specific tests, Xymon already parses information supplied in specific formats. You can (ab)use this support to have Xymon graph values from your own templates.

### The 'CPU' Test
On any device, you would like to graph CPU.
If you get CPU utilization value as a percentage, you should add the following lines to the message file in the `cpu` directory in your template:
```plaintext
<!--
<br>CPU 5 min average: {CPUTotal5Min}
-->
```

For example in:
```
cisco-asa/cpu/message
```

Where `CPUTotal5Min` is a percentage.
Wait for 2 passes, and you will get a graph.

### The 'Memory' Test
On any device, you would like to graph memory usage.
You should add the following lines to the message file in the `memory` directory in your template.
```plaintext
<!-- 
Physical {mem_used_per}%
-->    
```

For example in:
```
cisco-asa/memory/message
```

Where `mem_used_per` is a percentage.
Wait for 2 passes, and you will get a graph.

## Using NCV (e.g. the 'connects' Test)

If you have a test where the value you want to graph is not a repeater (so Devmon's RRD collector isn't useful), and it isn't for a test that Xymon already understands a specific format, then Xymon's NCV collector is probably the last remaining option. Add a Name-colon-value line to your message, surrounded by HTML tags (if you want to hide the line on the normal Xymon display).

For example, to graph the numbers of connections you should add the following lines to the message file in the `connects` directory in your template:

```plaintext
Connections: {cur_conn}
```

For example in:

```
cisco-asa/connects/message
```

Where `cur_conn` is your number of connections you want to graph.

Then, add "connects=ncv" to TEST2RRD in `xymonserver.cfg`, as well as the RRD options for connects, via:

```plaintext
NCV_connects="*:GAUGE"
```

Finally, you need a graph definition for connects, such as the one shipped in `extras/devmon-graph.cfg`.
