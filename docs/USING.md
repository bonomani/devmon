# Using
## Devmon Tags 

Add the `DEVMON` tag in the Xymon `hosts.cfg` file:
```
10.0.0.1        myrouter      # DEVMON
```

## Discover 
Devmon should discover and identify the device's vendor and model, determining which test templates to apply.  
Run a Discovery (optionally in debug mode) and look at the result: (from the devmon application dir). 
```bash
./bin/devmon -read -d 
less ./var/db/hosts.db
```

## Run in background with Systemd
```bash
systemctl start devmon
systemctl status devmon
```

## Run in background with Init.d
```bash
service devmon start
service devmon status
```

## Run in foreground
- Logs are sent to the console, not to the log file (by default)
- Xymon messages are copied to the console (but also sent to the Xymon server to be able see the 
  result)
- Graphing information are not sent to the Xymon (by default, to not mess rrd)
- You do not need to stop Xymon running in background 
```bash
./bin/devmon -f -no1                # Similar as running in background
./bin/devmon -d                    # In debug mode, will stop after 1 cycle (automatically in foreground)
./bin/devmon -t                    # In trace mode, will stop after 1 cycle (automatically in foreground)
./bin/devmon -d -no1 -p myrouter   # In debug mode, only for device: myrouter
./bin/devmon -d -p myrouter=fans   # In debug mode, 1 cycle only,only for device: myrouter and only for test:fan
```

## Verify Devmon is running correctly
- Keep an eye on Devmon's child PIDs. Changes indicate unexpected restarts: `ps -aux | grep devmon`
- Verify if your device reports the new SNMP tests.
- Check logs: `tail -f /var/log/devmon/devmon.log` 
- Verify the server running Devmon (usually the Xymon server) reports a 'dm' test that displays SNMP
  statistics.

## Options
Within the `hosts.cfg`, you can configure the `DEVMON` tag with various options:

- [cid()](#cid) for custom SNMP Community ID
- [ip()](#ip) for a custom IP address
- [port()](#port) for a custom UDP SNMP port
- [model()](#model) to manually set the device's vendor and model
- [tests()](#tests) to specify certain tests to run
- [notests()](#notests) to exclude certain tests
- [thresh()](#thresh) to override default test thresholds
- [except()](#except) to override default test exceptions

Options are case-sensitive and should follow the `DEVMON` tag without any whitespace, separated by 
commas if multiple are used. For instance following options are valid:
```
10.0.0.1        myrouter      # DEVMON:cid(mysnmpid)
10.0.0.1        myrouter      # DEVMONtests(cpu,power)
10.0.0.1        myrouter      # DEVMON:tests(power,fans,cpu),cid(testcid)
10.0.0.1        myrouter      # DEVMON:tests(cpu),thresh(cpu;CPUTotal5Min;y:50;r:90)
```
However, following options are invalid:
```
10.0.0.1        myrouter      # DEVMON:
10.0.0.1        myrouter      # DEVMON: tests(power)
10.0.0.1        myrouter      # DEVMON:tests (power)
```
### cid()

For devices with unique SNMP Community String (cids) not listed in `devmon.cfg`:

```
DEVMON:cid(mycommunity)
```

### ip()

To query devices at a secondary IP address:

```
DEVMON:ip(10.0.0.11)
```

### port()

For devices using non-standard SNMP ports:

```
DEVMON:port(5161)
```

### model()

To manually set a device's model, avoiding auto-detection:

```
DEVMON:model(cisco;2950)
```

### tests() and notests()

To limit or exclude some tests:

```
DEVMON:tests(cpu,if_err)
DEVMON:notests(fans)
```

### thresh()

To customize test thresholds, specify the test, OID, and new threshold values:

```
DEVMON:thresh(foo;opt1;r:95;y:60)
DEVMON:thresh(foo;opt1;r:80,foo;opt2;r:90)
```

Thresholds can be numeric or non-numeric, with non-numeric thresholds treated as **regular 
expressions**.

### except()

For repeater type OIDs, there are four exception types, each with its abbreviation:

- 'Only' (abbreviated as 'o'): Displays only rows with matching primary OIDs.
- 'Ignore' (abbreviated as 'i'): Shows only rows without matching primary OIDs.
- 'Alarm on' (abbreviated as 'ao'): Enables rows with matching primary OIDs to generate alarms.
- 'No alarm' (abbreviated as 'na'): Allows only rows without matching primary OIDs to generate 
  alarms.

```

DEVMON:except(if_stat;ifName;ao:Fa0/4[8-9])
DEVMON:except(if_stat;ifName;i:Vl.*|Lo.*|Nu.*)
DEVMON:except(all;ifName;ao:Gi0/[1-2])

```

Exceptions use **regular expressions** and are **anchored**, meaning they must match the OID value 
**exactly**. For more information on [templates](TEMPLATES.md)
