# TEMPLATES
 
## Rolling your own test
Devmon's templates let you create your own test: You don't need to write a 
single line of code! But having a bit of know-how with regular expressions 
helps: http://www.regular-expressions.info/. You will have to: 

- Select the SNMP OIDs to query
- Transform data gathered through SNMP or previously transformed
- Define thresholds and alarm messages
- Define how the test will be displayed in Xymon (output message)

## The templates folder
Template data is stored in the `templates` folder of your Devmon installation. 
For a single server, the folder is read regularly; for multiple servers, the 
database is utilized.

Note: If you have multiple servers, it's best to keep only one copy of your 
templates folder, preferably on your main server. Remove any extra template 
folders on your other servers. This avoids confusion when syncing templates 
to your database, making sure everything matches up.

## The vendor-model folders
Inside the `templates` folder, there are subfolders for each vendor-model, 
like `Cisco 2950` or `Cisco 3750`. The names of these subfolders don't matter
because each one must have a `specs` file that specifies the template

## The specs file
The `specs` file holds data specific to the vendor-model ans should look like
```
vendor   : cisco
model    : 2950
snmpver  : 2
sysdesc  : C2950
```
- The `sysdesc` variable is utilized in Devmon's discovery process when 
reading the Xymon hosts.cfg file (using `devmon -readhostscfg`).
This value MUST be unique and can handle complex patterns because it's 
treated as a regular expression.
- The `snmpver` variable is no longer in use and has been deprecated. It 
can be safely removed from all templates.

## The test folders
Each subfolder in a vendor-model folder is a separate test. **The folder's 
name is important as this is the test name reported to your Xymon server**. For example, 
a folder named `cpu` defines the `cpu` test in Xymon. 
Each test folder MUST contains five files:
- oids
- transforms
- thresholds
- exceptions
- message

## Example: a `cpu` test on a `Cisco 2950`
```
templates/cisco-2950/specs  
templates/cisco-2950/cpu/oids  
templates/cisco-2950/cpu/transforms  
templates/cisco-2950/cpu/thresholds  
templates/cisco-2950/cpu/exceptions  
templates/cisco-2950/cpu/message  
```
Note: 
- The thresholds, transforms and exceptions files can be empty.
- A line beginning with `#` is a comment. Comments are supported by all these files except 
the `message` file.

## The `oids` file 

The `oids` file contains the SNMP queries you want to make for this device 
type. It should look something like this:

```
sysDescr        : .1.3.6.1.2.1.1.1.0               : leaf
sysReloadReason : .1.3.6.1.4.1.9.2.1.2.0           : leaf
sysUpTime       : .1.3.6.1.2.1.1.3.0               : leaf
CPUTotal5Min    : .1.3.6.1.4.1.9.9.109.1.1.1.1.5.1 : leaf
```

There are three values per line
1. The **targetOID** (case sensitive): the variable name that will contains the result of the polling. The names can be similar to the **textual** representation of a OID, but do not have to. 
2. The **numericOID**: the standard form of OID (The official **textual** OID representation that you can find in MIBS do not work) 
3. The repeater **type**: `leaf`(= a non-repeater oid), `branch`(= a repeater oid)

Notes:
- If the same targetOID is used in multiple tests within a template, the complete line (targetOID: numericOID: type) MUST be duplicated in those tests to avoid inconsistent results.

OIDs, or Object Identifiers, are fundamental concepts in both SNMP and Devmon.

- In SNMP, we distinguish between `table` and `scalar` OIDs.
- In Devmon, we classify OIDs as either `branch` or `leaf`.

The relationship between them is:

- A `branch` OID corresponds to an SNMP `table`
- A `leaf` OID can represent either:
  - A SNMP `scalar` OID (ending with 0)
  - An element of a SNMP `table` OID (usually not ending with 0)

Let's analyse a SNMP request for the numeric OID `.1.3.4.6.9` that could be defined as type `branch`: 
```
snmpwalk -v2c -c public MYDEVICE .1.3.4.6.9
.1.3.4.6.9.4.3.1.20.3 = 8732588786
.1.3.4.6.9.4.3.1.20.4 = 5858738454
<-numOID-> <- index-> = <- value ->
```
- There are muliple result, 1 per line, all those will be stored in the `targetOID`
- Each line carries 2 new information: 
  - The `value` can have various types: String, Integer, numericOID, etc.
  - The `index`, is of type numeric OID, often simply an Integer.
- For a `leaf`, there is only 1 targetOID (=value) (and no index as it is not needed)

Note: 
- The meaning of the OID can be confusiong as everything is called `OID`: the targetOID, the numericOID and also the index
- If a leaf OID is not a scalar (do not end by 0), the complete table will be retrieved (du to the way snmp work): This is very similar has using the parent OID of type `branch`...

## The 'transforms' file

The transforms file in your template details the data changes Devmon makes to collected 
SNMP data, before setting thresholds and creating the message.

The cisco 2950 cpu test uses a very simple transforms file:

```
sysUpTimeSecs   : MATH          : {sysUpTime} / 100
UpTimeTxt       : ELAPSED       : {sysUpTimeSecs}
```
In a generic form
```
targetOID       : TRANSFORM      : {sourceOID1} ... {sourceOID2} ...
```
In the 'transform context' we use slightly different terms that help to be more precise. Three values per line:
1. The **targetOID** (case sensitive): unique compared to those in the 'oids' file. For example, 
'sysUpTimeSecs' originates from 'sysUpTime' in the oids file, gathering SNMP data. 
Throughout, 'alias' refers to either SNMP-collected or transformed data.  
2. The **transform** : (case insensitive, e.g., 'MATH' or 'math')
3. The **input data**: a string with **one or more sourceOID(s)**, enclosed in {}, defined elsewhere

Notes
- The **primaryOID** = **sourceOID1** (the first sourceOID that is a repeater, so it should be also sourceOID2), from left to right
- The **targetOID** has the **same indexes** as **the primaryOID**
- Mixing repeater and non-repeater type result in a repeater type OID.
- Like for the `oid` file, the same consideration for targetOID across multiple tests should be taken (duplicate the line!)

### BEST transform
The BEST transform selects the OID that has the **best alarm color** (green as 'best', red as 'worst')  
Mainly use in the `msg` file with its color and error parts only : {targetOID.color} {targetOID.error}  
```
targetOid   : BEST    : {sourceOID1} {sourceOID2}
```
Notes
- SourceOIDs present in the BEST transform **are excluded from the globale page color calculation** (the worst color of the page)

### CHAIN transform
Sometimes, a device saves a numeric SNMP identifier as a string under 
a different OID, resulting has **having 2 OIDs** to poll to reach the values. 
The CHAIN transform combines these 2 OIDs:
```
chainedOid   : CHAIN    : {OID1} {OID2}
```

Example: In your oids file, you have defined:
```
OID1  : .1.1.2     : branch
OID2  : .1.1.3     : branch
```

Walking the OID1 and OID2 return the values and results when combining to:
```
OID1:
.1.1.2.1 = .1.1.3.1194
.1.1.2.2 = .1.1.3.2342
 
OID2:
            .1.1.3.1194 = CPU is above nominal temperature
            .1.1.3.2342 = System fans are non-operational

chainedOid:
.1.1.2.1                = CPU is above nominal temperature
.1.1.2.2                = System fans are non-operational
```


### CONVERT transform
**Convert** a string in **hexadecimal** or **octal** to the **decimal** equivalent.
Two arguments:
- an `OID` 
- a conversion type: `hex` or `oct`

To convert the hex string '07d6' to its decimal equivalent (2006, as it so happens):
```
intYear : CONVERT: {hexYear} hex
```

### DELTA transform
The DELTA transform **compares** the **previous values** to the **current 
one** changes **over the time** and shows the change in **unit per second** rate.  
  
You can give it a maximum value (upper limit): the limit helps prevent 
incorrect results by setting a maximum value of the rate, that can occure when
OID values are reset in th device. Without a specified limit, the system will 
choose an appropriate maximum based on whether it's dealing with 32-bit or 64-bit data. 
  
The DELTA transform takes at least two poll cycles to return meaningful data.
In the mean time you will get a `wait` result stored in the targetOID alias.

This method doesn't allow for measuring decreases (negative changes) in the data.

Delta examples:
```
changeInValue  : DELTA : {value}
changeInValue  : DELTA : {value} 2543456983
```

### DATE transform
This transform converts Unix time (seconds since January 1, 1970, 00:00:00 GMT) 
into a readable date and time format. It changes the input of seconds into a 
text string that shows the date and time as "YYYY-MM-DD, HH:MM:SS" (using 24-hour time).

### ELAPSED transform
This transform converts a given number of seconds into a text string that shows 
the equivalent amount of time in years, days, hours, minutes, and seconds.


### INDEX transform
This transform allows you to access the index part of repeater OID. For example, 
walking the cdpCacheDevicePort OID returns :
```
CISCO-CDP-MIB::cdpCacheDevicePort.4.3 = STRING: GigabitEthernet4/41
CISCO-CDP-MIB::cdpCacheDevicePort.9.1 = STRING: GigabitEthernet2/16
CISCO-CDP-MIB::cdpCacheDevicePort.12.14 = STRING: Serial2/2
```
The value is the interface on the remote side. To get the interface on the local side, 
you must use the last value in the index (e.g. 3 for GigabitEthernet4/41) and look in
the ifTable:
```
IF-MIB::ifName.3 = STRING: Fa0/0
```
The index transform allows you to get the index value `4.3` as an OID value. You can use 
the REGSUB transform to further extract the `3` value

### MATCH transform
This transform addresses the issue found in MIBs that mix different data types 
in just two columns. It either separates these mixed tables into distinct ones 
or rearranges them to have more columns.   
For example, the MIB for the TRIDIUM building management system contains a table 
with two columns: outputName and outputValue.
```
TRIDIUM-MIB::outputName.1  = STRING: "I_Inc4_Freq"
TRIDIUM-MIB::outputName.2  = STRING: "I_Inc4_VaN"
TRIDIUM-MIB::outputName.3  = STRING: "I_Inc4_VbN"
TRIDIUM-MIB::outputName.4  = STRING: "I_Inc4_VcN"

TRIDIUM-MIB::outputValue.1 = STRING: "50.06"
TRIDIUM-MIB::outputValue.2 = STRING: "232.91"
TRIDIUM-MIB::outputValue.3 = STRING: "233.39"
TRIDIUM-MIB::outputValue.4 = STRING: "233.98"
```
To split the frequences out as a separate repeater, use:
```
outputFreqRow  : MATCH  : {outputName} /.*_Freq$/
outputVaRow    : MATCH  : {outputName} /.*_VaN$/
```  

`outputFreqRow` will contain as its values the indexes of outputName that matched the
regular expression, e.g. 1,5,9,...  
`outputVaRow` will contain 2,6,10...  
To construct a table, use the chain transform to create repeaters using the
matched indexes:
```
outputFreq     : CHAIN  : {outputFreqRow} {outputValue}
outputVa       : CHAIN  : {outputVaRow} {outputValue}
```

To create the primary repeater for a table, we do the same on outputName:
```
IncomerRowName : CHAIN  : {outputFreqRow} {outputName}   
```
In this case, it is preferable to clean up the outputFreq for display:
```
IncomerName    : REGSUB : {IncomerRowName} /(.*)_Freq/$1/
```
A table created as follows:
```
Incomer|Frequency (Hz)|Voltage A|Voltage B|Voltage C
```
Would now contain in its first row:
```
I_Inc4|50.06|232.91|233.39|233.98   
```

### MATH transform:
The MATH transform performs a mathematical expression defined by the
supplied data. It can use the following mathematical operators:
```
'+'           (Addition)
'-'           (Subtraction)
'*'           (Muliplication)
' x '         (Multiplication - note white space on each side) (deprecated)
'/'           (Division)
'^'           (Exponentiation)
'%'           (Modulo or Remainder)
'&'           (bitwise AND)
'|'           (bitwise OR)
' . '         (string concatenation - note white space each side)
'(' and ')'   (Expression nesting)
```
This transform is not whitespace sensitive, except in the case of ' x ' and
' . ' , so both:
```
{sysUpTime} / 100
```
and
```
{sysUpTime}/100
```
...would be accepted, and are functionally equivalent. However:
```
{ifInOps} x 8
```
will work, while:
```
{ifInOps}x8
```
will not. This is to avoid problems with oid names containing the character
'x'. New templates should rather use the '*' operator to avoid problems, e.g.:
```
{ifInOps}*8
```
The mathematical expressions you can perform can be
quite complex, such as:
```
((({sysUpTime}/100) ^ 2 ) x 15) + 10
```
Note that the syntax of the MATH transform is not stringently checked at
the time the template is loaded, so if there are any logic errors, they
will not be apparent until you attempt to use the template for the first
time (any errors will be dumped to the devmon.log file on the node that
they occurred on).

Decimal precision can also be controlled via an additional variable seperated
from the main expression via a colon:
```
transTime : MATH : ((({sysUpTime}/100) ^ 2 ) x 15) + 10 : 4 
```

This would ensure that the transTime alias would have a precision value (zero
padded, if needed) of exactly 4 characters (i.e. 300549.3420). The default
value is 2 precision characters. To remove the decimal characters
alltogether, specify a value of 0.

### UNPACK transform 
The inverse of the 'PACK' transform.

### REGSUB transform
One of the most powerful and complicated transforms, the regsub transform
allows you to perform a regular expression substitution against a single data
alias input. The data input for a regsub transform should consist of a single
data alias, followed by a regular expression substitution (the leading 's'
for the expression should be left off). For example:
```
ifAliasBox : REGSUB  : {ifAlias} /(\S+.*)/ [$1]/
```
The transform above takes the input from the ifAlias data alias and, assuming
that it is not an empty string (ifAlias has to have at least one non-
whitespace character in it) it puts square braces around the value and puts a
space in front of it. This example is used by all of the Cisco interface
templates included with Devmon, to include the ifAlias information for an
interface, but only if it has a value defined. A very powerful, but easily
misused transform. If you are interested in using it but don't know much
about substitution, you might want to google 'regular expression
substitution' and try reading up on it.

### SET transform

The SET transform creates a repeater-type OID, and presets it with a sequence
of constants. The indexes of the individual values of the OID created by SET
are numbered starting from 1. The constants are defined in the third field.
The constants are separated by a comma, optionally surrounded by zero or more
spaces. Leading and trailing spaces in the list of constants are ignored. At
least one constant must be specified. A constant is either a number or a
string of characters, which should not include ',', '{' or '}'. It is not
possible to define spaces at the start or at the end of the string.

Like the MATCH transform, the SET transform is meant to be used for a badly
designed MIB. While MATCH is used if two branches are used, containing the
name and the value, SET is used if only one branch is used, containing a list
of values.

For example, the MIB for the McAfee MEB 4500 contains a section describing (a
part of) the file systems. For each file system, the utilisation of space,
the size, the free space, the utilisation of the i-nodes, the total number of
i-nodes and the number of free i-nodes are available. A better representation
is a table with 6 columns. The following configuration is used to map the
single column onto 6 columns.
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

The OIDs named fsb.+ can be used in transforms and in the TABLE directive in
file 'message'.

From a theoretical stand point, the SET transform complements the set of
transforms. There was already the possibility to set a leaf-type OID to a
constant value, using a statement like:
```
AScalar  : MATH   : 123
```

The SET transform introduces the same possibility for a repeater-type OID.

### SPEED transform
This transform takes a single data alias as input, which it assumes to be a
speed in bits. It then stores a value in the transformed data alias,
corresponding to the largest whole speed measurement. So a value of 1200
would render the string '1.2 Kbps', a value of 13000000 will return a value
of '13 Mbps', etc.

### STATISTIC transform
This transform takes a repeater type data alias as the input for the
transform and computes a non-repeater type data alias. The STATISTIC
transform can compute the minimum value, the maximum value, the average value
and the sum of the values of the repeater type data alias. Moreover it can
count the number of values of the repeater type data alias.

If the input is a non-repeater data alias, the transform returns the value of
the input data. However, if the number of values is to be counted the
returned value is 1.

If for example the average temperature in a device with multiple temperature
sensors is to be monitored, the transformation could be:
```
TempAvg : STATISTIC : {ciscoEnvMonTemperatureStatusValue} AVG
```
As the example shows, the last keyword determines the value to be returned. The 
possible keywords are:
- `AVG` : Average value
- `CNT` : Number of values
- `MAX` : Maximum value
- `MIN` : Minimum value
- `SUM` : Sum of the values

### SUBSTR transform
The substr transform is used to extract a portion of the text (aka a
'substring') stored in the target OID alias. This transform takes as
arguments: a target alias, a starting position (zero based, i.e. the first
position is 0, not 1), and an optional length value. If a length value is
not specified, substr will copy up to the end of the target string.

So, if you had an OID alias 'systemName' that contained the value 'Cisco
master switch', you could do the following:
```
switchName : SUBSTR : {systemName} 0 12
```
stores 'Cisco master' in the 'switchName' alias, or
```
switchName : SUBSTR : {systemName} 6
```
stores 'master switch' in the 'switchName' alias

### SWITCH transform
The switch transform transposes one data value for another. This is most
commonly used to transform a numeric value returned by an snmp query into its
textual equivalent. The first argument in the transform input should be the
oid to be transformed. Following this should be a list of comma- delimited
pairs of values, with each pair of values being separated by an equals sign.

For example: 
```
upsBattRep : SWITCH : {battRepNum} 1 = Battery OK, 2 = Replace battery
```
So this transform would take the input from the 'upsBattRepNum'
data alias and compare it to its list of switch values. If
the value of upsBattRepNum was 1, it would store a 'Battery OK'
value in the 'upsBattRep' data alias. 

You can use simple mathematical tests on the values of the source OID
alias, as well as assigning values for different OIDs to the target alias.
For instance:
```
dhcpStatus : SWITCH : {dhcpPoolSize} 0 = No DHCP, >0 = DHCP available
```
The format for the tests are as follows (assuming 'n','a' and 'b' are
floating point numerical value [i.e. 1, 5.33, 0.001, etc], and 's' is a
alphanumeric string):
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
    default : Default value for the target alias, used in cas of undefined
              values or any unmatch statement (specially usefull for incomplet
              oids, prefer ".*" if there is no reason to use it!
```
Note that switch statements are applied in a left to right order; so if you
have a value that matches the source value on multiple switch statements, the
leftmost statement will be the one applied.

The switch statement can also assign values from another OID to the target
OID alias, depending on the value of the source OID alias, like this:
```
dhcpStatus : SWITCH : {dhcpPoolSize} 0 = No DHCP, >0 = {dhcpAvail}
```
This would assign the value 'No DHCP' to the 'dhcpStatus' alias if and only
if the 'dhcpPoolSize' alias contained a value equal to zero. Otherwise, the
value of the 'dhcpAvail' alias would be assigned to dhcpStatus. 

### UNPACK transform
The unpack transform is used to unpack binary data into any one of a number
of different data types (all of which are eventually stored as a string by
Devmon). This transform requires a target OID alias and an unpack type (case
sensitive), separated by a space.

As an example, to unpack a hex string (high nybble first), try this:
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
This transform takes two data aliases as input, and stores the values for the
one with the 'worst' alarm color (red being the 'worst' and green being the
'best') in the transformed data alias. The oids can either be comma or space
delimited.

## The 'thresholds' file
The thresholds file defines the limits against which the various data aliases
that you have created in your 'oids' and 'transforms' files are measured
against. An example thresholds file is as follows:
```
upsLoadOut  : red     : 90          : UPS load is very high
upsLoadOut  : yellow  : 70          : UPS load is high

upsBattStat : red     : Battery low : Battery time remaining is low
upsBattStat : yellow  : Unknown     : Battery status is unknown

upsOutStat  : red     : On battery|Off|Bypass              : {upsOutStat}
upsOutStat  : yellow  : Unknown|voltage|Sleeping|Rebooting : {upsOutStat}

upsBattRep  : red     : replacing : {upsBattRep}
```

As you can see, the thresholds file consists of one entry per line, with each
entry consisting of three to four fields separated by colons. The first field
in an entry is the data alias that the threshold is to be applied against.
The second field is the color that will be assigned to the data alias should
it match this threshold. The third field has the threshold values, which are
the values that the data alias in the first field will be compared against.
You can have multiple values, delimited by vertical bars, in the third field.
The fourth field is the threshold message, which will be assigned to the data
alias in the first field if it matches this threshold.

The threshold message can contain other data alias(es) (oids): if they are of a 
branch type they have to share indexes with the first field. If they are leafs
they do not need as there is only one value. The threshold field cannot use
data aliases (oids) value (this is feature request). 

### The evaluation order
2 levels: the precision level is evaluated first  
#### A 'precise' threshold has a higher priority
- Priority 7: =, eq
- Priority 6: > >= < >=
- Priority 5: ~= (smart match)
- Priority 4: !~  (negative smart match)
- Priority 3: !=, ne
- Priority 2: _AUTOMATCH_
- Priority 1: (empty)
 
#### A 'highest severity' has a higher priority 
- Priority from higher to lower:  red->yellow->clear->green 

One thing to note about thresholds is that they are lumped into one of two
categories: numeric and non-numeric
- Some operateur like Smart match only appy to non-numeric. 
- Numeric operator are evaluated first

If no math operator is defined in the threshold, Devmon assumes that it is a
'greater than' type threshold. That is, if the value obtained via SNMP is
greater than this threshold value, the threshold is considered to be met
and Devmon will deal with it accordingly. This is ambiguous with '='. This 
should be avoid and replace with the '>' operator. (Should raised a warning 
TODO: make a deprecation notice)

If a threshold value contains even one non-numeric character (other than the
math operators illustrated above), it is considered a non-numeric threshold.

Regular expressions in threshold matches are non-anchored, which means they
can match any substring of the compared data. So be careful how you define
your thresholds, as you could match more than you intend to! If you want to
make sure your pattern matches explicitly, precede it with a '^' and
terminate it with a '$'.


## The 'exceptions' file

The exceptions file is contains rules which are only applied against repeater
type data aliases.

An example of a exceptions file is as follows:

```
ifName : alarm  : Gi.+
ifName : ignore : Nu.+|Vl.+
```

You can see that each entry is on its on line, with three fields separated by
colons. The first field is the primary data alias that the exception should
be applied against. The second field is the exception type, and the third
field is the regular expression that the primary alias is matched against.
Exception regular expressions (unlike non-numeric thresholds) ARE anchored,
and thus need to match the primary oid EXACTLY.

Exceptions are only applied against the first (primary) alias in a repeater
table (which is described below). There are four types of exceptions types
that you can use, they are:

- ignore

The 'ignore' exception type causes Devmon to not display rows in a repeater
table which have a primary oid that matches the exception regexp.

- only

The 'only' exception type causes Devmon to only display rows in a repeater
table which have a primary oid that matches the exception regexp.

- alarm

The 'alarm' exception causes Devmon to only generate alarms for rows in a
repeater table that have a primary oid that matches the exception regexp.

- noalarm

The 'noalarm' exception causes Devmon to not generate alarms for rows in a
repeater table that have a primary oid that matches the exception regexp.

The exceptions are applied in the order above, and one primary alias can
match multiple exceptions. So if you have a primary alias that matches both
an 'ignore' and an 'alarm' exception, no alarm will be generated (in fact,
the row won't even be displayed in the repeater table).

The example file listed above, from a cisco 2950 if_stat test, tells Devmon
to only alarm on repeater table rows which have a primary oid (in this case,
ifName) that starts with 'Gi' and has any number of characters after that
(which will match any Gigabit interfaces on the switch). Also, it tells
Devmon not to display any rows with a primary alias that has a value that
behind with Nu (a Null interface) or Vl (A VLAN interface).


## The 'messages' file

The messages file is what brings all the data collected from the other files
in the template together in a single cohesive entry. It is basically a web
page (indeed, you can add html to it, if you like) with some special macros
embedded in it.

An example of a simple messages file is as follows:
```
{upsStatus.errors}
{upsBattStat.errors}
{upsLoadOut.errors}
{upsBattRep.errors}

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

You can see in this file that it is just a bunch of data aliases, with one or
two special exceptions. Most of these will just be replaced with their
corresponding values. You can see at the top of the file, however, that there
are a few weird looking data aliases (the ones that end in .errors). These
are just normal data aliases with a special flag appended to them, that lets
Devmon know that you want something from them than just their data value.

### The OIDs flags

- color

This flag will print out the xymon color string assigned to this
data alias by the thresholds (this string looks like '&red' or '&green',
etc). This color string will be interpreted by xymon as a colored icon, which
makes alarm conditions much easier to recognize. Like the 'errors' flag, it
will also modify the global color.

- errors 

The errors flag on a data alias will list any errors on this data alias. In
this case, 'errors' refers to the message assigned to the alias from a non-
green threshold match (the message is the value assigned in the fourth field
of an entry in the thresholds file, remember?). If the value assigned to a
data alias is green, then the value that replaces this flag will be blank.

Error messages will always be printed at the TOP of the message file,
regardless of where they are defined within it. This is done to make sure
that the user sees any errors that might have occurred, which they might miss
if the messages file is too long.

The errors flag will also modify the global color of the message. So if this
error flag reports a yellow error, and the global color is currently green,
it will increase the global color to yellow. If the error flag reports a red
error, it will increase the global color to red. The global color of a
message defaults to green, and is modified upwards (if you consider more
severe colors to be 'up') depending on the contents of the 'error' and
'color' flags.
 
- msg

The msg flag prints out the message assigned to the data alias by its
threshold. Unlike the errors flag, it prints the message even if the data
alias matches a green threshold and it also does NOT modify the global color
of the message.

- thresh

The syntax for the thresh flag is {oid.thresh:<color>}. It displays the value
in the threshold file (or custom threshold) that corresponds with the
supplied color. So, {CPUTotal5Min.thresh:yellow} would display the template
value for the yellow threshold for the CPUTotal5Min oid, or a per-device
custom threshold if one was defined.

A more complicated message file is this one, taken from a Cisco 2950 switch
if_stat test:
```
TABLE:
Ifc name|Ifc speed|Ifc status
{ifName}{ifAliasBox}|{ifSpeed}|{ifStat.color}{ifStat}{ifStat.errors}
```

In this message file, we are using a repeater table. Repeater tables are used
to display repeater-type data aliases (which ultimately stem from 'branch'
type snmp oids). The 'TABLE:' keyword (case sensitive, no leading whitespace
allowed) is what alerts Devmon that the next one to two lines are a repeater
table definition.

Devmon basically just builds an HTML table out of the repeater data. It can
have an optional header, which should be specified on the line immediately
after the 'TABLE:' tag. If no table header is desired, the line after the
table tag should be the row data identifier. The column separator in the
header line is a '|'. By default the content of a column will be left
aligned. If the content should be aligned on the right side, use '|>' rather
than '|' as the separator. Note that the leftmost column cannot be right
aligned in this way.

The row data identifier is the one that contains one or more data aliases.
The first of these aliases is referred to as the 'primary' alias, and must be
a repeater-type alias. Any other repeater type aliases in the row will be
keyed off the primary alias; that is, if the primary aliases has leaves
numbered '100,101,102,103,104', the table will have five rows, with the first
row having all repeater aliases using leaf 100, the second row having all
repeaters using leaf 101, etc. Any non-repeaters defined in the table will
have a constant value throughout all of the rows.

The TABLE: key can have one or more, comma-delimited options following it
that allow you to modify the way in which Devmon will display the data. These
options can have values assigned to them if they are not boolean ('nonhtml',
for example, is boolean, while 'border' is not boolean).

The TABLE options

- nonhtml

Don't use HTML tags when displaying the table. Instead all columns will
be separated by a colon (:). This is useful for doing NCV rrd graphing
in hobbit.

- plain

Don't do any formatting. This allows repeater data (each item on it's own
line), without colons or HTML tables. One use of this option is to format
repeater data with compatibility with a format Hobbit already understands. An
example is available in the disk test for the linux-openwrt template.

- noalarmsmsg

Prevent Devmon from displaying the 'Alarming on' header at the top of a
table.

- alarmsonbottom

Cause Devmon to display the 'Alarming on' message at the bottom of the table
data, as opposed to the top.

- border=n

Set the HTML table border size that Devmon will use
(a value of 0 will disable the border)

- pad=n

Set the HTML table cellpadding size that Devmon will use

- rrd

See the GRAPHING document in this directory for explanation

An example of some TABLE options in use:
```
TABLE: alarmsonbottom,border=0,pad=10
```
The STATUS: key allows you to extend the first line of the status message
that Devmon sends to BB/Hobbit/Xymon. For example, if you need to get data
to a Xymon rrd collector module that evaluates data in the first line of the
message (such as the Hobbit la collector which expects "up: <time>, %d
users, %d procs load=%d.%d" you can use this key as follows to get a load
average graph:
```
STATUS: up: load={laLoadFloat2}
```

### Error Propagation
Starting with the github version of devmon, we decide to 'propagate' errors
and their messages from a transform to the next one. Why? 
- There is a need to : tswitch was aleardy doing so 
- We would like to catch also other errors and see were they come from 
Errors generated by threshold are in fact just alarms. But we have also:
- Connectivity error: Not any value or some "undefined" value -> Undef 
- Computational error: Impossible result                      -> NaN
- Impcompaible matrix: holes in a table                       -> n/a
About the severity: 
- During the threshold processing, the color(=severityi) and the error are set 
  - if yellow, red, clear: the error is set (and will be raised)
  - if green or blue: no error are raised
- if error is set: furher transform will bypass the threshold processing 
- Transform usually just transforms data, but if a problem is detected it can:
  - Set a severity (without setting the error), usually yellow (minor) 
  - The threshold processing is done, so the severity can be override
  - If not overriden, the error is set at the end of the threshold processing
- A connectivity error is currently put in severity = 'gray' or 'no report'
- A processing error is currenty put in 'yellow' and set the value to 'NaN'


### Done!

That's it! Once you've completed the five files mentioned above, you should,
in theory, have a working template. I would recommend building the template
under a separate 'test' installation of Devmon, as the single-node version
of Devmon re-reads the template directory once per poll period, and having
an incomplete or broken template will cause Devmon to throw error messages
into its log.

Try extracting the Devmon tarball to somewhere like "/usr/local/devmontest",
and fiddle with the templates from there. Run Devmon from this directory in
single-node mode, using a dummy bb-hosts file (even if your production Devmon
cluster runs in multi-node mode, running the test Devmon in single node mode
prevents you from having to create an additional database for your Devmon
"test" installation). With the -vv and -p flags (i.e. devmon -vv -p), you
will get verbose output from Devmon, and if you have a host in the bb-hosts
file that matches the sysdesc in the specs file of the the model-vendor for
the new template you created, you will also get textual output of your new
template! (The -p flag causes Devmon to not run in the background and to
print messages to STDOUT as opposed to sending them to the display server,
and the -vv flag causes Devmon to log verbosely.)

Once you are satisfied that your template is working correctly, you can put
it to work in your production installation. In a single-node installation,
this is as simple as copying the template directory to the appropriate
subdirectory of your templates/ dir. On the next poll cycle, Devmon will pick
up the new template, and any new hosts discovered by your readbbhosts cron
job will be added to the Devmon database using this new template.

In a multinode installation, adding a new template is only slightly more
difficult. Copy the template directory to the appropriate place on the
machine where you keep all your templates (earlier we recommended using your
display server, and deleting all the template directories on the node
machines). Once you have it in place, run devmon with the --synctemplates
flag. This will read in the templates, update the database as necessary, and
then notify all the Devmon nodes that they need to reload their templates. A
full template reload on all your machines can take up to twice the interval
of your polling cycle, so be patient!
