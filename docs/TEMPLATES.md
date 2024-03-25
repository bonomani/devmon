# TEMPLATES
 
## Custom Templates Made Easy
Devmon's templates allow you to effortlessly craft your own monitoring templates using declarative
configuration files. This means there's no need for complex coding! Some knowledge of 
[regular expressions](http://www.regular-expressions.info) can boost your skills.

To begin crafting your custom templates, get ready to:

- Select the SNMP OIDs to query
- Transform data gathered through SNMP
- Define thresholds and alarm messages
- Define how tests are displayed in Xymon (output message)

### The templates folder
Template configuration files are stored in the `templates` folder of your Devmon installation. For a
single server, the folder is read regularly; for multiple servers, the database is utilized.

Notes: 
- If you have multiple servers, it's best to keep only one copy of your templates folder, preferably
  on your main server. Remove any extra template folders on your other servers. This avoids 
  confusion when syncing templates to your database, making sure everything matches up.

### The vendor-model folders
- Inside the `templates` folder, there are subfolders for each `vendor-model`, 
like `Cisco 2950` or `Cisco 3750`. 
- This folder's name don't matter.  Each test have a `specs` file that specifies the template.

### The test folders
- Inside the `vendor-model` folder there are subfolders for each `test`.
- The **name** of each `test` folder **matters** as they are the test names displayed on your Xymon 
  server.

### Example
A `cpu` test on a `Cisco 2950` requires:
```
templates/cisco-2950/specs  
templates/cisco-2950/cpu/oids  
templates/cisco-2950/cpu/transforms  
templates/cisco-2950/cpu/thresholds  
templates/cisco-2950/cpu/exceptions  
templates/cisco-2950/cpu/message  
```
Notes: 
- The thresholds, transforms and exceptions files can be empty.
- A line beginning with `#` is a comment. Comments are supported by all these files except the 
  `message` file.


## The specs file
The `specs` file holds data specific to the vendor-model. This file is used in the discovery process
`./devmon -readhostscfg`, where Devmon identifies the hosts it should handle by using the `sysdesc` 
variable. This (non-anchored regular expression) pattern should match the SNMP system description, 
ensuring the classification.

### Format
```
vendor   : cisco
model    : 2950
snmpver  : 2 (**deprecated**)
sysdesc  : C2950
```

## The oids file 
The `oids` file contains the SNMP OIDS to query and their type. 

### Format
```
sysDescr        : .1.3.6.1.2.1.1.1.0               : leaf
sysReloadReason : .1.3.6.1.4.1.9.2.1.2.0           : leaf
sysUpTime       : .1.3.6.1.2.1.1.3.0               : leaf
CPUTotal5Min    : .1.3.6.1.4.1.9.9.109.1.1.1.1.5.1 : leaf
```

- Field #1: The **target OID** (case sensitive):  a **textual OID alias** (not required to be from 
  MIBs). Contains the response to the SNMP query.
- Field #2: The **numeric OID**: the OID requested in the SNMP query
- Field #3: The **type**:
  - `branch`= a **repeater** type OID
  - `leaf`  = a **non-repeater** (a scalar) type OID.

Notes:
- Prefer using the terms **repeater/non-repeater** over **branch/leaf** as they are self-explanatory
  and closer to SNMP terminology
- If the **same target OID** is used **in multiple tests** within a template, **the line** with the 
  target OID **MUST be duplicated** in those tests to avoid inconsistent results.
- The **numeric OID** cannot be replaced with its equivalent **textual OID alias**, as defined in 
  MIBs, because Devmon does not load MIBs. 


### OIDs or Object Identifiers
- In SNMP, OIDs are categorized into `table` and `scalar` OIDs.
- In Devmon, OIDs are classified as either `repeater` and `non-repeater` OIDs.

The relationship between them is as follows:
- A `repeater` OID corresponds to an SNMP `table` OID
- A `non-repeater` OID can is either:
  - A SNMP `scalar` (Its numeric OID does end with .0)
  - An `instance` (an element) of a SNMP `table` (Its numeric OID does not end with .0)

Let's execute and analyze an SNMP request to numeric OID of type `repeater`: 
```
snmpwalk -v2c -c public MYDEVICE .1.3.4.6.9
```
Outputs:
```
.1.3.4.6.9.4.3.1.20.3 = 8732588786
.1.3.4.6.9.4.3.1.20.4 = 5858738454
<-numOID-> <- index-> = <- value ->
```
Key points:
- There are multiple results, one per line, with each being stored in the `target OID` as
  `key-value` pairs.
- Each line contains two pieces of information:
  - The `index` acts as the `key` and must remain `unique`. It's a sequence of integers, separated 
    by dots, like a numeric OID. Often it is simply a single integer.
  - The `value` which can be of various types: String, Integer, numeric OID, etc. as defined in SNMP
- In a `non-repeater`, as it is a scalar:
  - There is **no** `index`
  - There is only **one** `value`
   
Notes: 
- In Devmon, the term `OID` is abused: `OID alias`, `target OID`, `numeric OID`, `index`, 
  `repeater OID`,... all can be simply designated by the name `OID`.
- If a `non-repeater OID` does not end with `.0`, indicating it is not a real SNMP scalar, 
  retrieving it results in getting the `parent OID` that is of type `repeater`. This behavior is 
  part of SNMP's design...

## The transforms file
The transforms file describes manipulations on SNMP data.

### Format
```
target_OID      : TRANSFORM     : {source_OID1} ... {source_OID2} ...
```
Example:
```
sysUpTimeSecs   : MATH          : {sysUpTime} / 100
UpTimeTxt       : ELAPSED       : {sysUpTimeSecs}
```
- Field #1: The **target OID** (case sensitive): MUST be unique name compared to those in the `oids`
  file and other target OIDs in the `transform` file 
- Field #2: The **transform** (case insensitive): e.g. MATH or math.
- Field #3: The **input data**: a string with **one or more source OID(s)** enclosed in `{}`.

Notes:
- The **primary OID**, typically `source_OID1`, is the first `source OID` of type `repeater` found
  from left to right
- The **target OID** have the **same indexes** as the **primary OID**
- Mixing `repeater` and `non-repeater` type result in a `repeater` type.
- Like for the `oid` file, the same consideration for `target OID` across multiple tests should be
  taken (duplicate the line!)

### Errors
Catching errors and determining their origins is essential. Errors generated by thresholds are 
indeed just `alarms`, well identify by the color value. They are no need for an error value in this 
case. But real errors can also exists.

Alarm and error are propagated from source oids to targets oids. If the error `flag' set true, the 
threshold processing is skipped and the error, the color and the message are just copied to be 
target OID.

#### Connectivity error
The first error that can occur is an SNMP error involving `getting no response from the device`
- If the OID is not defined in the device, it results in a global value of the OID being set to 
  `NoOID`.
- In the event of partial SNMP polling failure, this leads to some (if not all) values of the OIDs 
  being set to `NoOID`, there indexes are based on the previous successful polling.

#### Computational error: 
Occurs when the result is impossible. For example for a numerical result the value is set to `NaN`

#### Handling error as alarm
Errors trigger a "clear" alarm status color, defined as "no report" in Xymon
During threshold processing, the color (severity) and the error are set as follows:
- If yellow, red, or clear: the error is set to true, and generally, a message is associated (and 
  will be raised).
- If green or blue: no error is raised.
- Default thresholds like `clear` or `blue` can be overridden, just having a threshold that match 
  the value as soon as possible.


### BEST transform
- The BEST transform selects the OID that has the **best alarm color** (green as `best`, red as 
`worst`)  
- Mainly use in the `message` file with its color and msg flags only : {target_OID.color} 
{target_OID.msg}  
```
target_OID  : BEST    : {source_OID1} {source_OID2}
```
Notes:
- `Source OIDs` present in the BEST transform **are excluded from the globale page color 
  calculation** (the worst color of the page)

### CHAIN transform
Sometimes, a device saves a numeric SNMP identifier as a string under a different OID, resulting has
**having 2 OIDs** to poll to reach the values. The CHAIN transform combines these 2 OIDs:
```
target_OID   : CHAIN    : {source_OID1} {source_OID2}
```

Example: In your oids file, you have defined:
```
source_OID1  : .1.1.2     : branch
source_OID2  : .1.1.3     : branch
```

Walking the OID1 and OID2 return the values and results when combining to:
```
source_OID1:
.1.1.2.1 = .1.1.3.1194
.1.1.2.2 = .1.1.3.2342
 
source_OID2:
            .1.1.3.1194 = CPU is above nominal temperature
            .1.1.3.2342 = System fans are non-operational

target_OID:
.1.1.2.1                = CPU is above nominal temperature
.1.1.2.2                = System fans are non-operational
```

### CONVERT transform
**Convert** a string in **hexadecimal** or **octal** to the **decimal** equivalent.

Requires:
- an `OID` 
- a conversion type: `hex` or `oct`

To convert the hex string `07d6` to its decimal equivalent `2006`:
```
intYear : CONVERT: {hexYear} hex
```

### DELTA transform
The DELTA transform **compares** the **previous values** to the **current one** changes **over the 
time** and shows the change in **unit per second** rate.  
  
- You can set a maximum value (upper limit) to prevent incorrect results that may occur when OID 
  values reset in the device. Without a specified limit, the system will automatically choose a 
  suitable maximum based on whether it's handling 32-bit or 64-bit data.
- This transform takes at least `two poll cycles` to return meaningful data. In the mean time you 
  will get a `wait` result stored in the `target OID`.

Examples:
```
changeInValue  : DELTA : {value}
changeInValue  : DELTA : {value} 2543456983
```
Notes:
- This trasnform doesn't allow for measuring decreases (negative changes) in the data.

### DATE transform
This transform converts Unix time (seconds since January 1, 1970, 00:00:00 GMT) into a readable date
and time format. It changes the input of seconds into a text string that shows the date and time as 
`YYYY-MM-DD, HH:MM:SS` (using 24-hour time).

### ELAPSED transform
This transform converts a given number of seconds into a text string that shows the equivalent 
amount of time in years, days, hours, minutes, and seconds.

### INDEX transform
This transform allows you to access the index part of repeater OID. For example, walking the 
`cdpCacheDevicePort` OID returns :
```
CISCO-CDP-MIB::cdpCacheDevicePort.4.3 = STRING: GigabitEthernet4/41
CISCO-CDP-MIB::cdpCacheDevicePort.9.1 = STRING: GigabitEthernet2/16
CISCO-CDP-MIB::cdpCacheDevicePort.12.14 = STRING: Serial2/2
```
The value is the interface on the remote side. To get the interface on the local side, you must use 
the last value in the index (e.g. 3 for GigabitEthernet4/41) and look in the ifTable:
```
IF-MIB::ifName.3 = STRING: Fa0/0
```
The index transform allows you to get the index value `4.3` as an OID value. You can use the REGSUB 
transform to further extract the `3` value.

### MATCH transform
This transform allow the `target OID` to have :
- A `new index`: An `incremental index`, starting from `1`   
- A `value` that is the `index` of the matched `source OID` value

This transform addresses an issue found in MIBs that mix different data types in just two columns. 
It either separates these mixed tables into distinct ones or rearranges them to have more columns.   

Example: 
The MIB for the TRIDIUM building management system contains a table 
with two columns: outputName and outputValue.
```
TRIDIUM-MIB::outputName.1  = STRING: "I_Inc4_Freq"
TRIDIUM-MIB::outputName.2  = STRING: "I_Inc4_VaN"

TRIDIUM-MIB::outputValue.1 = STRING: "50.06"
TRIDIUM-MIB::outputValue.2 = STRING: "232.91"

```
To split the frequences and the voltage out as a separate repeater, use:
```
outputFreqRow  : MATCH  : {outputName} /.*_Freq$/
outputVaNRow   : MATCH  : {outputName} /.*_VaN$/
```  
- `outputFreqRow` will contains 1,... as `values`  
- `outputVaNRow` will contains 2,... as `values`  
- There indexes start from 1  

To construct a table, use the chain transform to create repeaters using the matched indexes:
```
outputNameFreq      : CHAIN  : {outputFreqRow} {outputName}
outputValueFreq     : CHAIN  : {outputFreqRow} {outputValue}
outputNameVaN       : CHAIN  : {outputVaNRow} {outputName}
outputValueVaN      : CHAIN  : {outputVaNRow} {outputValue}
```
A table created as follows:
```
Freq Name       |Frequency (Hz)   |Voltage Name   |Voltage A
{outputNameFreq}|{outputValueFreq}|{outputNameVaN}|{outputValueVaN}
```
Outputs: 
```
Freq Name  |Frequency (Hz)|Voltage Name|Voltage A
I_Inc4_Freq|         50.06|  I_Inc4_VaN|   232.91   
```
You can further improve it for example not repeating I_Inc4 and to have:
```
Name  |Frequency (Hz)|Voltage A
I_Inc4|         50.06|   232.91   
```


### MATH transform:
The MATH transform performs a mathematical expression defined by the supplied data. It can use the 
following mathematical operators:
```
'+'           (Addition)
'-'           (Subtraction)
'*'           (Muliplication)
'/'           (Division)
'^'           (Exponentiation)
'%'           (Modulo or Remainder)
'&'           (bitwise AND)
'|'           (bitwise OR)
' . '         (string concatenation - note white space each side) (**deprecated**)
'(' and ')'   (Expression nesting)
```
This transform is not whitespace sensitive, except in the case of ' . ', which is **deprecated**.     
The mathematical expressions you can perform can be quite complex, such as:
```
((({sysUpTime}/100) ^ 2 ) x 15) + 10
```
Notes:
The MATH transform syntax isn't rigorously checked upon template loading. Any errors will only 
surface when you first use the template, logged in the devmon.log file.

Decimal precision can also be controlled via an additional variable seperated from the main 
expression via a colon:
```
transTime : MATH : ((({sysUpTime}/100) ^ 2 ) x 15) + 10 : 4 
```

This ensures that the transTime OID has a precision of exactly 4 characters, padded with zeros if 
necessary (e.g., 300549.3420). By default, it has 2 precision characters. To eliminate decimals 
entirely, specify a value of 0.

### UNPACK transform 
The inverse of the `PACK` transform.

### REGSUB transform
The regsub transform is a powerful yet complex technique that allows you to replace segments of a 
single `source OID` using regular expressions (the leading `s` for the expression should be left 
off). For example:
```
ifAliasBox : REGSUB  : {ifAlias} /(\S+.*)/ [$1]/
```
If `ifAlias` contain at least one non-whitespace character, square brackets are added around its 
value with a space in front. This example is used in all Cisco interface templates in Devmon to 
include `ifAlias` information for an interface, but only if it's defined. If you're unfamiliar with 
substitution, consider looking up `regular expression substitution` for more information.

### SET transform
The SET transform generates a `repeater` OID with preset values. 
- Each value's index starts from 1.
- Each value's MUST be separated by commas optionally surrounded by spaces.
- At least one constant MUST be provided, which can be either a number or a character  string 
  excluding `,{}`. Leading and trailing spaces are ignored.

For example, in the McAfee MEB 4500 MIB, there's a section detailing file systems. Each file system 
includes space utilization, size, free space, i-node utilization, total i-nodes, and free i-nodes. A
more organized approach is to represent this information in a table with 6 columns. The provided 
configuration accomplishes this by mapping the single column into 6 columns.
```
fsInfo    : .1.3.6.1.4.1.1230.2.4.1.2.3.1 : branch

fsiUtil   : SET    : 11.0,17.0,23.0,29.0,35.0,41.0
fsiSize   : SET    : 12.0,18.0,24.0,30.0,36.0,42.0
fsiFree   : SET    : 13.0,19.0,25.0,31.0,37.0,43.0
fsiIUtil  : SET    : 14.0,20.0,26.0,32.0,38.0,44.0
fsiISize  : SET    : 15.0,21.0,27.0,33.0,39.0,45.0
fsiIFree  : SET    : 16.0,22.0,28.0,34.0,40.0,46.0

fsbName   : SET    : deferred,quaratine,scandir,logs,var,working
fsbUtil   : CHAIN  : {fsiUtil} {fsInfo}
fsbSize   : CHAIN  : {fsiSize} {fsInfo}
fsbFree   : CHAIN  : {fsiFree} {fsInfo}
fsbIUtil  : CHAIN  : {fsiIUtil} {fsInfo}
fsbISize  : CHAIN  : {fsiISize} {fsInfo}
fsbIFree  : CHAIN  : {fsiIFree} {fsInfo}
```

There is the possibility to set a `non-repeater` OID to constant value
```
AScalar  : MATH   : 123
```


### SPEED transform

This transform converts speed values in bits to the largest whole speed measurement. For example, 
`1200` would become `1.2 Kbps`, and `13000000` would become `13 Mbps`.


### STATISTIC transform
This transformation computes statistics. The result type is a non-repeater.

Example:  
The average temperature in a device with multiple temperature sensors is to be monitored, the 
transformation could be:
```
TempAvg : STATISTIC : {ciscoEnvMonTemperatureStatusValue} AVG
```
As the example shows, the last keyword determines the value to be returned. The possible keywords 
are:
- `AVG` : Average value
- `CNT` : Number of values
- `MAX` : Maximum value
- `MIN` : Minimum value
- `SUM` : Sum of the values

### SUBSTR transform
The substr transform extracts a portion of text  
Requires:
- an `OID`, 
- a `starting position` (zero-based)
- a `length` value (optional). If not provided, substr copies until the end of the string.

Example:  
systemName contains `Cisco master switch`
```
switchName : SUBSTR : {systemName} 0 12
```
The transformed value is `Cisco master` 
```
switchName : SUBSTR : {systemName} 6
```
The transformed value is `master switch`

### SWITCH transform
The switch transform substitutes one data value with another. It's often used to convert a numeric 
value from an SNMP query to its corresponding text. The statements are applied in a left to right
order.

Examples: 
```
upsBattRep : SWITCH : {battRepNum} 1 = Battery OK, 2 = Replace battery
```
```
dhcpStatus : SWITCH : {dhcpPoolSize} 0 = No DHCP, >0 = DHCP available
```
The format for the tests are as follows (assuming `n`,`a` and `b` are floating point numerical value
i.e. `1`, `5.33`, `0.001`, ... and `s` is a alphanumeric string):
```
    n       : Source alias is equal to this amount
    >n      : Source alias is greater than this amount
    >=n     : Source alias is greater than or equal to this amount
    <n      : Source alias is less than this amount
    <=n     : Source alias is less than or equal to this amount
    a - b   : Source alias is between 'a' and 'b', inclusive
    's'     : Source alias matches this string exactly (case sensitive)
    "s"     : Source alias matches this regular expression (non-anchored)
              ".*" match anything! (similar to default: prefer it)
    default : Default value for the target alias, used in case of undefined
              values or any unmatch statement (specially usefull for incomplet
              oids, prefer ".*" if there is no reason to use it!
```
The switch statement can use values from other OIDs, like this:
```
dhcpStatus : SWITCH : {dhcpPoolSize} 0 = No DHCP, >0 = {dhcpAvail}
```
This would assign the value `No DHCP` to `dhcpStatus` if and only if the `dhcpPoolSize` contained a 
value equal to zero. Otherwise, the value of the `dhcpAvail`  would be assigned to `dhcpStatus`. 

### UNPACK transform
The unpack transform is used to unpack binary data into any one of a number of different data types.  
This transform requires
- an OID 
- unpack type (case sensitive), separated by a space.

As an example, to unpack a hex string (high nybble first):
```
hexString : UNPACK : {binaryHex} H
```
The unpack types are as follows:
```
    Type  |  Description              
    ---------------------------------------------------
       a  | ascii string, null padded
       A  | ascii string, space padded
       b  | bit string, low to high order
       B  | bit string, high to low order
       c  | signed char value
       C  | unsigned char value
       d  | double precision float
       D  | single precision float
       h  | hex string, low nybble first
       H  | hex string, high nybble first
       i  | signed integer
       i  | unsigned integer
       l  | signed long value
       L  | unsigned long value
       n  | short integer in big-endian order
       N  | long integer in big-endian order
       s  | signed short integer
       S  | unsigned short integer
       v  | short integer in little-endian order
       V  | long integer in little-endian order
       u  | uuencoded string
       x  | null byte
```       

### WORST transform
The transform takes two `source OIDs` and stores the value associated with the worst alarm color 
(red as the worst, green as the best) in the `target oid`.

## The thresholds file
Specify `threshold` limits for the OIDs, including their corresponding alarm `color` levels and 
`messages`

### Format
```
upsLoadOut  : red     : 90          : UPS load is very high
upsLoadOut  : yellow  : 70          : UPS load is high

upsBattStat : red     : Battery low : Battery time remaining is low
upsBattStat : yellow  : Unknown     : Battery status is unknown

upsOutStat  : red     : On battery|Off|Bypass              : {upsOutStat}
upsOutStat  : yellow  : Unknown|voltage|Sleeping|Rebooting : {upsOutStat}

upsBattRep  : red     : replacing : {upsBattRep}
```

The thresholds file comprises one entry per line, each containing three to four fields separated by 
colons:
- The first field: The `OID` for which the threshold is applied
- The second field: The `color` assigned if the threshold is met
- The third field: contains threshold values
  - **OID templating is not supported** (this is a feature request, please vote for it!)
- The fourth field: is the threshold message: a string that can contains OIDs, enclosed in {}
  - If the message contains an OID of type `repeater`: They have to share indexes with the first 
    field
  - The alarm message can also contain an OID of type `non-repeater`

### The evaluation order
The operator `precision` is evaluated **first**: A higher precision holds higher priority.
- Priority 7: `=` `eq`
- Priority 6: `>` `>=` `<` `>=`
- Priority 5: `~=` (smart match)
- Priority 4: `!~`  (negative smart match)
- Priority 3: `!=` `ne`
- Priority 2: `_AUTOMATCH_`
- Priority 1: `(empty)`
 
 `Severity` is evaluated **second**, from highest to lowest severity..
- `red`
- `yellow`
- `clear`
- `green` 

Notes:
- Numeric operators are evaluated first.
- Some operators, like Smart match, only apply to non-numeric values. 
- If **no operator** is specified in the threshold field, Devmon assumes it's a `greater than`
  threshold. If the SNMP value exceeds this threshold, Devmon treats it as met. 
  This behavior is **deprecated**: Use the `>` operator for clarity and self-documentation.
  (TODO: Add a deprecation notice)
- Regular expressions in threshold matches are non-anchored. If you want to ensure
  your pattern matches explicitly, precede it with a `^` and terminate it with a `$`.


## The exceptions file
The exceptions file contains rules that are only applied to the primary OID of tables in the 
`messages` file

### Format
```
ifName : alarm  : Gi.+
ifName : ignore : Nu.+|Vl.+
```
- Field #1: The `primary OID` against which the exception is applied. 
- Field #2: The exception type. Applied in the following order:
  - `ignore`: Do not display rows that match the regexp  
  - `only`: Only display rows that match the regexp
  - `alarm`: Only generate alarms for rows that match the regexp
  - `noalarm`: Do not generate alarms for rows that match the regexp
- Field #3: The regular expression used to match the primary OID. Regexp is 
  anchored and must match exactly.

In the example above, from a cisco 2950 if_stat test, it tells Devmon to:
- Trigger alarms only for repeater table rows starting with `Gi` (Gigabit interfaces) 
- Exclude rows starting with `Nu` (Null interfaces) or `Vl` (VLAN interfaces).


## The message file
The message file consolidates data from the other template files. 
- It operates as a templating engine containing special keywords for specific functionalities 
- It allows the use of HTML.
- It enables the rendering of a message that can be understood by Xymon.

### Format
Example#1: with only **non-repeater OIDs**:
```
{upsStatus.msg}
{upsBattStat.msg}
{upsLoadOut.msg}
{upsBattRep.msg}

UPS status:

Vendor:              apc
Model:               {upsModel}

UPS Status:          {upsOutStat}
Battery Status:      {upsBattStat}

Runtime Remaining:   {upsMinsRunTime} minutes
Battery Capacity:    {upsBattCap}%
UPS Load:            {upsLoadOut}%

Voltage in:          {upsVoltageIn}v
Voltage out:         {upsVoltageOut}v

Last failure due to: {upsFailCause}
Time on battery:     {upsSecsOnBatt} secs
```
- OIDs enclosed in `{}` are replaced with their values.
- Some OIDs have a special flag attached: `.msg` indicating to Devmon a special behaviour.

Example#2: The TABLE keyword for **repeater OIDs**:
```
TABLE:alarmsonbottom,border=0,pad=10
Ifc name|Ifc speed|Ifc status
{ifName}{ifAliasBox}|{ifSpeed}|{ifStat.color}{ifStat}{ifStat.msg}
```
- Line #1: Start with the keyword `TABLE:`(case sensitive, no leading whitespace allowed) which 
  alerts Devmon that the we are in a table definition. Table options MUST be set immediately after 
  the `TABLE:` tag on the same line.  

- Line #2: The `table header`: The column separator is `|`.  By default, column content is 
  left-aligned. To align content on the right side, use `|>` instead of `|`. Note that the leftmost 
  column cannot be right-aligned in this way.
  
- Line #3: The `table content`. The row contains one or more OIDs. The first is the `primary OID`. 
  Other OIDs in the row are linked to the primary OID, by their indexes (key). For example, if the 
  primary OID has leaves indexed as `100,101,102,103,104`, the table will have five rows, theses 
  indexes will be display for any OIDs even if they do not exist for some OIDs. A `non-repeater` OID
  in the table will be constant in all rows. 

### The OIDs flags
- `color` 
  - Prints the alarm color of the OID in a format recognized by Xymon.
  - Modifies the global color of the page, if not used in a `BEST` transform.
- `errors` (**deprecated**: use msg)
  - Prints the alarm message of the OID and at the top/bottom of the message 
  - Modifies the global color of the page, if not used in a `BEST` transform.
- `msg`
  - Prints the alarm message of the OID and at the top/bottom of the message 
  - Modifies the global color of the page, if not used in a `BEST` transform.
- `thresh` 
  - The syntax for the thresh flag is {oid.thresh:<color>}
  - Print the theshold value that corresponds with the supplied color. 

### The TABLE options
The `TABLE:` keyword can have one or more, comma-delimited options following it. These options can 
have values assigned to them if they are not boolean:
- `nonhtml`: Don't use HTML tags when displaying the table. Instead all columns will be separated by
  a colon (:). This is useful for doing NCV rrd graphing in Xymon.
- `plain`: Don't do any formatting. This allows repeater data (each item on it's own line), without 
  colons or HTML tables. One use of this option is to format repeater data with compatibility with a
  format Xymon already understands. An example is available in the disk test for the `linux-openwrt` 
  template.
- `noalarmsmsg`: Prevent Devmon from displaying the `Alarming on` header at the top of a table.
- `alarmsonbottom`: Cause Devmon to display the `Alarming on` message at the bottom of the table
  data, as opposed to the top.
- `border=n`: Set the HTML table border size that Devmon will use (a value of 0 will disable the 
  border)
- `pad=n`: Set the HTML table cellpadding size that Devmon will use
- `rrd`: See [GRAPHING](GRAPHING.md) 

### Special Keyword
- `STATUS`: key allows you to extend the first line of the status message that Devmon sends to 
  Xymon. For example, if you need to get data to a Xymon rrd collector module that evaluates data in
  the first line of the message (such as the Xymon `la` collector which expects "up: <time>, 
  %d users, %d procs load=%d.%d". You can use this keyword as follows to get a load average graph:
```
STATUS: up: load={laLoadFloat2}
```
