<!DOCTYPE markdown>
## Devmon Installation Guide

### Prerequisits
#### 1. Install the SNMP_Session Perl module and Net-SNMP (C lib) ####
   - **RHEL**:
     ```bash
     yum install perl-SNMP_Session.noarch
     yum install net-snmp net-snmp-devel net-snmp-utils
     ```
   - **Debian**:
     ```bash
     apt install libsnmp-session-perl
     apt install snmp
     ```
   - From Source
     - SNMP_Session [download](https://github.com/sleinen/snmp-session) from source 
     - Net-SNMP http://www.net-snmp.org/ 
   - Both are recommended but not mandatory for compatibility with all SNMP versions.
     - SNMP_Session provides SNMPv1 and SNMPv2c 
     - Net-SNMP provides SNMPv2c and SNMPv3 

#### 2. Unpack Devmon ####
   - Extract the Devmon tarball into `/var/xymon/server/ext/devmon` or your preferred directory:
     ```bash
     mkdir /var/xymon/server/ext/devmon
     mv devmon-0.3.1-beta1/* /var/xymon/server/ext/devmon
     ```
   - Update ownership and group if necessary (e.g., for Xymon user):
     ```bash
     chown xymon /var/xymon/server/ext/devmon
     chgrp xymon /var/xymon/server/ext/devmon
     ```
#### 3. Prepare Xymon (xymon/etc folder) ####

   - Modify `cgioptions.cfg`:
     ```
     CGI_SVC_OPTS="--env=$XYMONENV --no-svcid --history=top --multigraphs=,disk,inode,qtree,quotas,snapshot,TblSpace,cpu_dm,disk_dm,mem_dm,if_col,if_dsc,if_err,if_load,fans,temp"
     ```

   - Modify `xymonserver.cfg`:
     ```
     TEST2RRD="cpu_dm=devmon,cpu=la,disk,dm=ncv,disk_dm=devmon,inode,qtree,memory,mem_dm=devmon,$PINGCOLUMN=tcp,http=tcp,dns=tcp,dig=tcp,time=ntpstat,vmstat,iostat,netstat,temperature,apache,bind,sendmail,mailq,nmailq=mailq,socks,bea,iishealth,citrix,bbgen,bbtest,bbproxy,hobbitd,files,procs=processes,ports,clock,lines,deltalines,ops,stats,cifs,JVM,JMS,HitCache,Session,JDBCConn,ExecQueue,JTA,TblSpace,RollBack,MemReq,InvObj,snapmirr,snaplist,snapshot,cpul=devmon,if_col=devmon,if_dsc=devmon,if_err=devmon,if_load=devmon,temp=devmon,paging,mdc,mdchitpct,cics,dsa,getvis,maxuser,nparts,xymongen,xymonnet,xymonproxy,xymond"
     GRAPHS="la,disk,inode,qtree,files<Plug>PeepOpenrocesses,memory,users,vmstat,iostat,tcp.http,tcp,ncv,netstat,ifstat,mrtg::1<Plug>PeepOpenorts,temperature,ntpstat,apache,bind,sendmail,mailq,socks,bea,iishealth,citrix,bbgen,bbtest,bbproxy,hobbitd,clock,lines,deltalines,ops,stats,cifs,JVM,JMS,HitCache,Session,JDBCConn,ExecQueue,JTA,TblSpace,RollBack,MemReq,InvObj,snapmirr,snaplist,snapshot,devmon::1,cpu_dm,disk_dm,if_col,if_dsc,if_err,if_load,mem_dm,temp<Plug>PeepOpenaging,mdc,mdchitpct,cics,dsa,getvis,maxuser,nparts,xymongen,xymonnet,xymonproxy,xymond"
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

### Single-node Installation

1. **Edit Configuration**:
   - Modify the `devmon.cfg` file according to your preferences.
   - Pay attention to options like `HOSTSCFG`, `SNMPCIDS`, `SECNAMES`, `LOGFILE`, etc.
   - Adjust the `CYCLETIME` variable if needed (default is 60 sec).

2. **Configure Xymon Hosts File**:
   - Add the Devmon tag (specified by `XYMONTAG`, defaults to 'DEVMON') to hosts you want to monitor in the `HOSTSCFG` file.
     - Example: `10.0.0.1 myrouter # badconn:1:1:2 DEVMON`


4. **Run a Discovery**:
   - /usr/local/devmon/devmon --read 

5. **Start Devmon**:
   - Launch Devmon and check logs for any errors.
   - Verify if new tests are being shown on your display server.

6. **Install Start/Stop Script** on CentOS or RedHat using init.d:

    6.1. Create a directory for devmon:

    ```bash
    mkdir /var/run/devmon
    chown xymon /var/run/devmon
    chgrp xymon /var/run/devmon
    ```

    6.2. Copy the devmon init.d script to the appropriate directory:

    ```bash
    cp /var/xymon/server/ext/devmon/extras/devmon.initd.redhat /etc/init.d/devmon
    ```

    6.3. Edit the devmon init.d script:

    ```bash
    vi /etc/init.d/devmon
    ```

    6.4. Update the `prog` variable to point to the correct devmon location:

    ```diff
    -prog="/usr/local/devmon/devmon"
    +prog="/var/xymon/server/ext/devmon/devmon"
    ```

    6.5. Update the `RUNASUSER` variable to the appropriate user (xymon):

    ```diff
    -#RUNASUSER=devmon
    +RUNASUSER=xymon
    ```

    6.6. Add devmon to the system startup and start the service:

    ```bash
    chkconfig --add devmon
    chkconfig devmon on
    service devmon start
    ```

    This procedure assumes that you have devmon installed in `/var/xymon/server/ext/devmon/devmon` and that the user `xymon` exists. Adjust the paths and user as necessary based on your specific setup.

   - For systemd (CentOS 7, Ubuntu, etc.):
     - Add the systemd file to `devmon/extras/systemd`.

7. **If xymon hosts.cfg change**:
  - Look at reload_devmon_if_hosts.cfg_changed and reload_devmon_if_hosts.cfg_changed.cfg (devmon/extras)

8. **Devmon Purple** (Obsolete):
   - For systemd (tested for CentOS only), find it in `devmon/extra/systemd`.
   - You will find the generic in devmon/extra folder 

