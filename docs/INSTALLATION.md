<!DOCTYPE markdown>
# Installation
## Prerequisits
- Perl v5.10.0
- SNMP_Session (Perl module)
  - Support for SNMPv1 and SNMPv2c
- Net-SNMP (Perl module + C lib)
  - Optional, Support for SNMPv2c and SNMPv3


### RHEL 

```bash
yum install perl-SNMP_Session.noarch
yum install net-snmp net-snmp-devel net-snmp-utils
```

### Debian

```bash
apt install libsnmp-session-perl
apt install snmp
```

### From Source
- Download [SNMP_Session](https://github.com/sleinen/snmp-session)
- See how to install [Net-SNMP](http://www.net-snmp.org)

## Download and unpack
### With you prefered tool
- Git
```bash
cd .....xymon/server/ext
mkdir devmon
cd devmon
git clone https://github.com/bonomani/devmon.git
# Exclude your devmon.cfg to be follow (to revert show below)
git update-index --assume-unchanged devmon.cfg
```

- wget
```bash
cd .....xymon/server/ext
wget --no-check-certificate --content-disposition -O devmon.zip https://github.com/bonomani/devmon/archive/refs/heads/main.zip
unzip devmon.zip
mv devmon-main devmon
```

- curl
```bash
cd .....xymon/server/ext
curl -LJ -o devmon.zip https://github.com/bonomani/devmon/archive/refs/heads/main.zip
unzip devmon.zip
mv devmon-main devmon 
```

### Update ownership and group
```
According to the user that will run Devmon (here xymon)
chown -R xymon ./devmon
chgrp -R xymon ./devmon
```

## Prepare Xymon 
In the Xymon server 'etc' folder  
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
Add Devmon graphs configuration file:
```
mkdir /var/xymon/server/etc/graphs.d
cp /var/xymon/server/ext/devmon/extras/devmon-graphs.cfg /var/xymon/server/etc/graphs.d/.
```
Ensure `graph.cfg` include devmon-graphs.cfg by a directive like
- directory /var/xymon/server/etc/graphs.d
- include /var/xymon/server/etc/graphs.d/devmon-graphs.cfg

## Install and configure Devmon (Single-node)

### Edit `devmon.cfg` Configuration File 
- Pay attention to options like `HOSTSCFG`, `SNMPCIDS`, `SECNAMES`, `LOGFILE`, etc.

### Configure Xymon Hosts File
- Add the Devmon tag (specified by `XYMONTAG`, defaults to 'DEVMON') to hosts you want to monitor in the xymon `HOSTSCFG` file.
- Example: `10.0.0.1 myrouter # badconn:1:1:2 DEVMON`

### Run a Discovery (in debug mode)
```bash
./devmon --read -de 
```

### Start Devmon
- Launch Devmon and check logs for any errors
- Monitor Devmon child PIDs to see if they change over time. If the PIDs change, it indicates that child processes are being killed and restarted, which should not occur
```bash
ps -aux | grep devmon
```
- Verify if new 'tests' are being shown on your display server.
- Verity if a 'dm' test exist on your monitoring server and look at the stats

### Install Start/Stop Script
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

## Git Notes
### Problem: `git pull` blocked: (abandon)
An update of devmon.cfg from the github repo and locally excluded devmon.cfg are blocking the `git pull`  
Recommended: copy the complete devmon folder elsewhere (so you have a backup in case somthing goes wrong)  
```bash
cp -rf devmon devmon-dateYYMMDD
```

Take a backup of your local config and pull all modifs including devmon.cfg  
```bash
cp devmon.cfg devmon.cfg-old
```

Revert exclusion of your devmon.cfg from git to be able to update it
Put your local modif (else than devmon.cfg if any) on the stash
```bash
git stash 
```

Reset git to head (as it was originally when downloaded)
```bash
git reset --hard
```

Pull modif from repo
```bash
git pull
```

Update your devmon.cfg  
Reapply **manually** your local modif and re-exclude devmon.cfg from modif.
```bash
git update-index --assume-unchanged devmon.cfg
```
Reapply your modif
```bash
git stash apply
```

## Obsolete or additional steps 

### If xymon hosts.cfg change (Obsolete, should be adjusted as reload do not make a discovery anymore)
Look at reload_devmon_if_hosts.cfg_changed and reload_devmon_if_hosts.cfg_changed.cfg, in folder: devmon/extra

### Devmon Purple (Obsolete)
For systemd (tested for CentOS only): in folder `devmon/extra/systemd`.




