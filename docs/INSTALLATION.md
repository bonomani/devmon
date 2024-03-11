<!DOCTYPE markdown>
## Prerequisits
### 1. Install Dependant Libs: SNMP_Session (Perl module) and Net-SNMP (Perl module + C lib) 
RHEL 
```bash
yum install perl-SNMP_Session.noarch
yum install net-snmp net-snmp-devel net-snmp-utils
```
Debian
```bash
apt install libsnmp-session-perl
apt install snmp
```
From Source
- Download [SNMP_Session](https://github.com/sleinen/snmp-session)
- See how to install [Net-SNMP](http://www.net-snmp.org)
- Both are recommended but not mandatory for compatibility with all SNMP versions.
  - SNMP_Session provides SNMPv1 and SNMPv2c 
  - Net-SNMP provides SNMPv2c and SNMPv3 

### 2. Unpack Devmon
Extract the Devmon tarball

With git
```bash
cd .....xymon/server/ext
mkdir devmon
cd devmon
git clone https://github.com/bonomani/devmon.git
# Exclude your devmon.cfg to be follow (to revert show below)
git update-index --assume-unchanged devmon.cfg
```
Or with wget
```bash
cd .....xymon/server/ext
wget --no-check-certificate --content-disposition -O devmon.zip https://github.com/bonomani/devmon/archive/refs/heads/main.zip
curl -LJ -o devmon.zip https://github.com/bonomani/devmon/archive/refs/heads/main.zip
unzip devmon.zip
mv devmon-main devmon
```
Or with curl
```bash
cd .....xymon/server/ext
curl -LJ -o devmon.zip https://github.com/bonomani/devmon/archive/refs/heads/main.zip
unzip devmon.zip
mv devmon-main devmon 
```

### 3. Prepare Xymon (Files are located in the xymon server etc folder)
Modify `cgioptions.cfg`:
```
CGI_SVC_OPTS="--env=$XYMONENV --no-svcid --history=top --multigraphs=,disk,inode,qtree,quotas,snapshot,TblSpace,cpu_dm,disk_dm,mem_dm,if_col,if_dsc,if_err,if_load,fans,temp"
```
Modify `xymonserver.cfg`:
```
TEST2RRD="cpu_dm=devmon,cpu=la,disk,dm=ncv,disk_dm=devmon,inode,qtree,memory,mem_dm=devmon,$PINGCOLUMN=tcp,http=tcp,dns=tcp,dig=tcp,time=ntpstat,vmstat,iostat,netstat,temperature,apache,bind,sendmail,mailq,nmailq=mailq,socks,bea,iishealth,citrix,bbgen,bbtest,bbproxy,hobbitd,files,procs=processes,ports,clock,lines,deltalines,ops,stats,cifs,JVM,JMS,HitCache,Session,JDBCConn,ExecQueue,JTA,TblSpace,RollBack,MemReq,InvObj,snapmirr,snaplist,snapshot,cpul=devmon,if_col=devmon,if_dsc=devmon,if_err=devmon,if_load=devmon,temp=devmon,paging,mdc,mdchitpct,cics,dsa,getvis,maxuser,nparts,xymongen,xymonnet,xymonproxy,xymond"
GRAPHS="la,disk,inode,qtree,files,processes,memory,users,vmstat,iostat,tcp.http,tcp,ncv,netstat,ifstat,mrtg::1,ports,temperature,ntpstat,apache,bind,sendmail,mailq,socks,bea,iishealth,citrix,bbgen,bbtest,bbproxy,hobbitd,clock,lines,deltalines,ops,stats,cifs,JVM,JMS,HitCache,Session,JDBCConn,ExecQueue,JTA,TblSpace,RollBack,MemReq,InvObj,snapmirr,snaplist,snapshot,devmon::1,cpu_dm,disk_dm,if_col,if_dsc,if_err,if_load,mem_dm,temp,paging,mdc,mdchitpct,cics,dsa,getvis,maxuser,nparts,xymongen,xymonnet,xymonproxy,xymond"
NCV_dm="*:GAUGE"
```
Add devmon graphs configuration file:
```
mkdir /var/xymon/server/etc/graphs.d
cp /var/xymon/server/ext/devmon/extras/devmon-graphs.cfg /var/xymon/server/etc/graphs.d/.
```
Ensure `graph.cfg` include devmon-graphs.cfg by a directive like
- directory /var/xymon/server/etc/graphs.d
- include /var/xymon/server/etc/graphs.d/devmon-graphs.cfg


## Single-node Installation

### 1. Edit `devmon.cfg` Configuration File 
- Pay attention to options like `HOSTSCFG`, `SNMPCIDS`, `SECNAMES`, `LOGFILE`, etc.

### 2. Configure Xymon Hosts File
- Add the Devmon tag (specified by `XYMONTAG`, defaults to 'DEVMON') to hosts you want to monitor in the xymon `HOSTSCFG` file.
- Example: `10.0.0.1 myrouter # badconn:1:1:2 DEVMON`

### 3. Run a Discovery (in debug mode)
```bash
./devmon --read -de 
```

### 4. Start Devmon
- Launch Devmon and check logs for any errors, see if the PIDS of devmon processes are stable.
- Verify if new tests are being shown on your display server.
- Verity if a 'dm' test exist on your monitoring server and look at the stats

### 5. Install Start/Stop Script
using init.d: [devmon.initd.redhat](/extras/devmon.initd.redhat)   
using systemd: [extras/systemd/](/extras/systemd/)
```bash
cp /usr/lib/xymon/server/ext/devmon/extras/systemd/devmon.service /etc/systemd/system/devmon.service
```
Edit the /etc/systemd/system/devmon.service file and adjust the executable path as needed
```bash
systemctl daemon-reload
systemctl enable devmon
systemctl start devmon
```

### 6. If xymon hosts.cfg change
Look at reload_devmon_if_hosts.cfg_changed and reload_devmon_if_hosts.cfg_changed.cfg (devmon/extras)

### 7. Devmon Purple (Obsolete):
   - For systemd (tested for CentOS only), find it in `devmon/extra/systemd`.
   - You will find the generic in devmon/extra folder 

## Additional step possibilities (NOT NEEDED, BUT KEPT FOR INFO: NEED CLEANING)
Create a directory for devmon:
```bash
mkdir /var/run/devmon
chown xymon /var/run/devmon
chgrp xymon /var/run/devmon
 ```
Copy the devmon init.d script to the appropriate directory:
```bash
cp /var/xymon/server/ext/devmon/extras/devmon.initd.redhat /etc/init.d/devmon
```
Edit the devmon init.d script:
```bash
vi /etc/init.d/devmon
```
Update the `prog` variable to point to the correct devmon location:
```diff
-prog="/usr/local/devmon/devmon"
+prog="/var/xymon/server/ext/devmon/devmon"
```
Update the `RUNASUSER` variable to the appropriate user (xymon):
```diff
-#RUNASUSER=devmon
+RUNASUSER=xymon
```
Add devmon to the system startup and start the service:
```bash
chkconfig --add devmon
chkconfig devmon on
service devmon start
```
Update ownership and group if necessary (e.g., for Xymon user):
```bash
chown xymon /var/xymon/server/ext/devmon
chgrp xymon /var/xymon/server/ext/devmon
```
### Revert exclusion of your devmon.cfg from git to be able to update it
Put your local modif elsewhere (the stash) if any 
```bash
git stash 
```
Reset git to head
```bash
git reset --hard
```
Take a backup of your local config and pull all modifs including devmon.cfg  
```bash
cp devmon.cfg devmon.cfg-old
git pull
```
Update your devmon.cfg
Reapply your local modif and re-exclude devmon.cfg from modif.
```bash
git stash apply
git update-index --assume-unchanged devmon.cfg
```
