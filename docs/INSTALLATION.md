<!DOCTYPE markdown>
# Installation
## The folder structure
(Was reorganized in 2024: was needed to improve installation)
- **$devmon_home**
  - **/server**
    - devmon.cfg (the config file)
    - **/bin**
      - devmon (the main software)
    - **/docs**
    - **/extras**
    - **/lib**
       - dm_config.pm
       - dm_msg.pm
       - dm_snmp.pm
       - dm_templates.pm
       - dm_snmp.pm
    - **/var**
      - **/db**
        - hosts.db
      - **/template**
        - ...
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

### Debian/Ubuntu

```bash
apt install libsnmp-session-perl
apt install snmp
```

### From Source
- Download [SNMP_Session](https://github.com/sleinen/snmp-session)
- See how to install [Net-SNMP](http://www.net-snmp.org)

## Download and unpack Devmon with git

```bash
cd ...xymon/server/ext
mkdir devmon
cd devmon
mkdir server
cd server
git clone https://github.com/bonomani/devmon.git
# Exclude your devmon.cfg to be tracked by git (to revert show git notes below)
git update-index --assume-unchanged devmon.cfg
```

## Download and unpack Devmon with wget or curl
```bash
cd ...xymon/server/ext
mkdir devmon
cd devmon
# with wget
wget --no-check-certificate --content-disposition -O devmon.zip https://github.com/bonomani/devmon/archive/refs/heads/main.zip
# or with curl
curl -LJ -o devmon.zip https://github.com/bonomani/devmon/archive/refs/heads/main.zip
# Extract and rename
unzip devmon.zip
mv devmon-main server
```

### Update ownership and group
```
# According to the user that will run Devmon (here devmon, the default user)
chown -R devmon:devmon .
```

## Configure Devmon (Single-node)

### Edit `devmon.cfg` Configuration File 
- Pay attention to options like `HOSTSCFG`, `SNMPCIDS`, `SECNAMES`, `LOGFILE`, etc.

## Install as a service 
 
### Systemd
```bash
cp /usr/lib/xymon/server/ext/devmon/server/extras/systemd/devmon.service /etc/systemd/system/devmon.service
```
Edit the /etc/systemd/system/devmon.service file and adjust the executable path as needed
```bash
systemctl daemon-reload
systemctl enable devmon
systemctl start devmon
```
The should start devmon, but you will need to discover you device before devmon can run in deamon mode
### Init.d  
- See [/extras/devmon.initd.redhat](/extras/devmon.initd.redhat)  
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
cp /var/xymon/server/ext/devmon/server/extras/devmon-graphs.cfg /var/xymon/server/etc/graphs.d/.
```
Ensure `graph.cfg` include devmon-graphs.cfg by a directive like
- directory /var/xymon/server/etc/graphs.d
- include /var/xymon/server/etc/graphs.d/devmon-graphs.cfg

## Git Notes
### Problem: `git pull` blocked: (the abandon error)
An update of devmon.cfg from the github repo and locally excluded devmon.cfg are blocking `git pull`  
Recommended: copy the complete devmon folder elsewhere (to have a backup)

```bash
cp -rf server server-dateYYMMDD
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

### If xymon hosts.cfg change (Obsolete: as `reload` do not make a discovery anymore)
Look at reload_devmon_if_hosts.cfg_changed and reload_devmon_if_hosts.cfg_changed.cfg, 
in folder: devmon/server/extras

### Devmon Purple (Obsolete)
For systemd (tested for CentOS only): in folder `devmon/server/extra/systemd`.


