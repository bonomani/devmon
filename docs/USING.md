## Using
## Devmon Tags in the bb-hosts File

After installing Devmon and setting it up to run periodically with the `--readbbhosts` flag, you can start monitoring remote hosts by adding the `devmon` tag to their entries in the `bb-hosts` file.

A typical entry looks like this:

```
10.0.0.1        myrouter # badconn:1:1:2 NAME:"My router" DEVMON
```

The `DEVMON` tag signals Devmon to monitor this host. It will auto-discover the device's vendor and model, determining which test templates to apply. Devmon will then run all relevant tests for that device type.

## Using Options with a Devmon Tag

You can configure Devmon using various options within the `bb-hosts` tag, such as:

- `cid()` for custom SNMP Community ID
- `ip()` for a custom IP address
- `port()` for a custom UDP SNMP port
- `model()` to manually set the device's vendor and model
- `tests()` to specify certain tests to run
- `notests()` to exclude certain tests
- `thresh()` to override default test thresholds
- `except()` to override default test exceptions

Options are case-sensitive and should follow the `DEVMON` tag without any whitespace, separated by commas if multiple are used.

### Examples of Devmon Tag Options

### cid()

For devices with unique SNMP Community IDs not listed in `devmon.cfg`:

```
badconn:1:1:2 DEVMON:cid(uniqueID)
```

### ip()

To query devices at a secondary IP address:

```
10.0.0.10 multihomehost # conn=worst,10.0.0.11 DEVMON:ip(10.0.0.11)
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

To limit tests to certain ones or exclude some:

```
DEVMON:tests(cpu,if_err)
DEVMON:notests(fans)
```

### thresh()

To customize test thresholds, specify the test, OID, and new threshold values:

```
DEVMON:thresh(foo;bar;r:95;y:60)
```

Thresholds can be numeric or non-numeric, with non-numeric thresholds treated as regular expressions.

### except()

For repeater type OIDs, to set exceptions on what rows to display or alarm:

```
# No specific example provided in the original text
```

Exceptions use regular expressions and are anchored, meaning they must match the OID value exactly.

--- 

This version condenses the guide to its essential instructions and examples, making it more straightforward to follow.
