## A Quick Overview of How Devmon Works

### Initialization
- Devmon starts by reading the list of hosts to monitor from its database.
- In a single-node setup, the database is stored in `hosts.db`. In a multi-node setup, it's stored in a MySQL database.
- The database must be populated at least once using the `--readbbhosts` flag before Devmon can monitor anything.

### Template Handling
- Devmon reads its templates.
- In a single-node setup, templates are read from disk at the start of each polling cycle.
- In a multi-node setup, templates are read from the database, but only if they've been updated since the last read.

### SNMP Queries
- Devmon performs SNMP queries on all devices in its database.
- Queries are optimized to avoid redundant queries for the same SNMP OID across multiple tests for a device.

### Template Logic Application
- Devmon applies template logic to the SNMP data received.
- This involves transformations, applying thresholds, and generating a message for the display server.
- The message includes a timestamp, the overall device status (red, yellow, green), and an HTML page with detailed device information.

### Message Sending
- Devmon sends the rendered messages to the display server.

### Sleep Cycle
- Devmon sleeps for the remaining time in the polling cycle.

This structured approach outlines the sequential steps Devmon takes to monitor devices and communicate status updates to the display server.
