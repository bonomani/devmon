<!DOCTYPE markdown>
## Devmon Installation Guide

### Single-node Installation

1. **Install Required Modules**:
   - Install the SNMP_Session Perl module
     - yum install perl-SNMP_Session.noarch (Rhel)
     - apt install libsnmp-session-perl (Debian) 
     - or [Download](https://github.com/sleinen/snmp-session)
     - Provides SNMPv1 an SNMPv2c
   - Install Net-SNMP (C lib) using:
     - `yum install net-snmp net-snmp-devel net-snmp-utils` (Rhel)
     - `apt install snmp` (Debian)
    - Provides SNMPv2c an SNMPv3
   - We recommend installing both for compatibility with all SNMP versions.

2. **Unpack Devmon**:
   - Extract the Devmon tarball into your preferred directory.
   - Consider using `/var/xymon/server/ext/devmon` or any directory of your choice.

3. **Edit Configuration**:
   - Modify the `devmon.cfg` file according to your preferences.
   - Pay attention to options like `HOSTSCFG`, `SNMPCIDS`, `SECNAMES`, `LOGFILE`, ...
   - Adjust the `CYCLETIME` variable if needed (default is 60 sec).

4. **Configure Xymon Hosts File**:
   - Add the Devmon tag (specified by `XYMONTAG` variable, defaults to 'DEVMON') to hosts you want to monitor in the `HOSTSCFG` file.
   - Example: `10.0.0.1 myrouter # badconn:1:1:2 DEVMON`

5. **Run a discovery or/and Set up Cron Job**: (Cron Job have side effect: NOT REALLY RECOMMENDED)
   - Schedule a cron job to run Devmon with the `--read` flag.
   - Example: `*/5 * * * * /usr/local/devmon/devmon --read`

6. **Start Devmon**:
   - Launch Devmon and check logs for any errors.
   - Verify if new tests are being shown on your display server.

### Multi-node Installation (NOT WORKING)

1. **Node Setup**:
   - Follow steps 1 to 6 on all machines in your Devmon cluster.

2. **Database Server Setup**:
   - Download and install MySQL server and client packages from [here](http://dev.mysql.com/downloads/).
   - Start MySQL server and ensure it boots at startup.
   - Change the root user password using `mysqladmin -u root password 'CHANGETHIS'`.
   - Delete unneeded default MySQL accounts with `mysql -p -e 'delete from mysql.user where password=""'`.
   - Create the Devmon database and import its structure.

3. **Display Server Setup**:
   - Install required modules, unpack Devmon, and edit `devmon.cfg`.
   - Import template data into the Devmon database.
   - Configure `bb-hosts` file and set up a cron job to run Devmon.
  
4. **Global Node Configuration**:
   - Edit `devmon.cfg` on one node and adjust global variables.
   - Synchronize global config with other nodes using `/usr/local/devmon/devmon -v --syncconfig`.
  
5. **Start Devmon Nodes**:
   - Launch Devmon on all nodes and monitor logs for any anomalies.

For advanced multi-node cluster setup, refer to the `docs/MULTINODE` file.
