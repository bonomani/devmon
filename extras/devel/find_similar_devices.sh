#!/bin/bash

# Default start directory if not provided
START_DIR="${1:-../../var/templates}"

# Step 1: Extract OID information and process it in memory
OID_OUTPUT=$(grep -r "1.3.6" "$START_DIR" | awk -F'[: ]+' '
{
    # Remove leading dots from OIDs
    oid = $3;
    gsub(/^\.*/, "", oid);

    # Extract only the device name from "templates/device_name"
    path = $1;
    sub(/^.*templates\//, "", path);  # Remove everything before "templates/"
    sub(/\/.*$/, "", path);           # Remove everything after the first "/"

    device_name = path;

    if (oid != "" && device_name != "") {
        if (!(oid in data)) {
            data[oid] = device_name;  # Store first device name
        } else if (index(data[oid], device_name) == 0) {
            data[oid] = data[oid] "," device_name;  # Append new unique device
        }
    }
}
END {
    for (oid in data) {
        print oid ":" data[oid];
    }
}')

# Print intermediary step: OID_OUTPUT
echo "### Intermediary Step: Extracted OID Data ###"
echo "$OID_OUTPUT"
echo "############################################"

# Step 2: Extract and compare devices per OID, process in memory
echo "$OID_OUTPUT" | awk -F: '
{
    split($2, devices, ","); 
    for (i in devices) {
        if (!(devices[i] in device_map)) {
            device_map[devices[i]] = $1;
        } else if (device_map[devices[i]] != $1) {
            device_map[devices[i]] = device_map[devices[i]] "|" $1;
        }
    }
}
END {
    for (device1 in device_map) {
        for (device2 in device_map) {
            if (device1 != device2 && device_map[device1] == device_map[device2]) {
                print device1 " is 100% similar to " device2;
            }
        }
    }
}' | sort | uniq

