<!DOCTYPE markdown>
<!DOCTYPE markdown>
## Devmon Installation Guide

### Single-node Installation

1. **Install Required Modules**:
   - Install the SNMP_Session Perl module:
     - `yum install perl-SNMP_Session.noarch` (RHEL)
     - `apt install libsnmp-session-perl` (Debian)
     - or [Download](https://github.com/sleinen/snmp-session)
     - Provides SNMPv1 and SNMPv2c
   - Install Net-SNMP (C lib):
     - `yum install net-snmp net-snmp-devel net-snmp-utils` (RHEL)
     - `apt install snmp` (Debian)
     - Provides SNMPv2c and SNMPv3
   - Both are recommended for compatibility with all SNMP versions.

2. **Unpack Devmon**:
   - Extract the Devmon tarball into `/var/xymon/server/ext/devmon` or your preferred directory.
     - `mkdir /var/xymon/server/ext/devmon`
     - `mv devmon-0.3.1-beta1/* /var/xymon/server/ext/devmon`
   - Update ownership and group if necessary (e.g., for Xymon user):
     - `chown xymon /var/xymon/server/ext/devmon`
     - `chgrp xymon /var/xymon/server/ext/devmon`

3. **Edit Configuration**:
   - Modify the `devmon.cfg` file according to your preferences.
   - Pay attention to options like `HOSTSCFG`, `SNMPCIDS`, `SECNAMES`, `LOGFILE`, etc.
   - Adjust the `CYCLETIME` variable if needed (default is 60 sec).

4. **Configure Xymon Hosts File**:
   - Add the Devmon tag (specified by `XYMONTAG`, defaults to 'DEVMON') to hosts you want to monitor in the `HOSTSCFG` file.
     - Example: `10.0.0.1 myrouter # badconn:1:1:2 DEVMON`


5. **Update Xymon**:
   - In the `xymon/etc` folder:
     - Modify `cgioptions.cfg`:
       ```
       CGI_SVC_OPTS="--env=$XYMONENV --no-svcid --history=top --multigraphs=,disk,inode,qtree,quotas,snapshot,TblSpace,cpu_dm,disk_dm,mem_dm,if_col,if_dsc,if_err,if_load,fans,temp"
       ```
     - Modify `xymonserver.cfg`:
       ```
       TEST2RRD="cpu_dm=devmon,cpu=la,disk,dm=ncv,disk_dm=devmon,inode,qtree,memory,mem_dm=devmon,$PINGCOLUMN=tcp,http=tcp,dns=tcp,dig=tcp,time=ntpstat,vmstat,iostat,netstat,temperature,apache,bind,sendmail,mailq,nmailq=mailq,socks,bea,iishealth,citrix,bbgen,bbtest,bbproxy,hobbitd,files,procs=processes,ports,clock,lines,deltalines,ops,stats,cifs,JVM,JMS,HitCache,Session,JDBCConn,ExecQueue,JTA,TblSpace,RollBack,MemReq,InvObj,snapmirr,snaplist,snapshot,cpul=devmon,if_col=devmon,if_dsc=devmon,if_err=devmon,if_load=devmon,temp=devmon,paging,mdc,mdchitpct,cics,dsa,getvis,maxuser,nparts,xymongen,xymonnet,xymonproxy,xymond"
       ```
     - Add to `xymonserver.cfg`:
       ```
       NCV_dm="*:GAUGE"
       ```
     - Modify `graph.cfg`:
       ```
       directory /var/xymon/server/etc/graphs.d
       ```
     - Create folder and copy configuration file:
       ```
       mkdir /var/xymon/server/etc/graphs.d
       cp /var/xymon/server/ext/devmon/extras/devmon-graphs.cfg /var/xymon/server/etc/graphs.d/.
       ```


6. **Run Discovery or Set up Cron Job** (Not Recommended):
   - Schedule a cron job to run Devmon with the `--read` flag.
     - Example: `*/5 * * * * /usr/local/devmon/devmon --read`

7. **Start Devmon**:
   - Launch Devmon and check logs for any errors.
   - Verify if new tests are being shown on your display server.

8. **Install Start/Stop Script**:
   - For init.d (CentOS or Red Hat with init.d):
     - Follow the provided steps.
   - For systemd (CentOS 7, Ubuntu, etc.):
     - Add the systemd file to `devmon/extras/systemd`.

9. **Devmon Purple** (Obsolete):
   - For systemd (tested for CentOS only), find it in `devmon/extra/systemd`.
```

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
