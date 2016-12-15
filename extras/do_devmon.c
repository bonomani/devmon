/*----------------------------------------------------------------------------*/
/* Hobbit RRD handler module for Devmon                                       */
/*                                                                            */
/* Copyright (C) 2004-2006 Henrik Storner <henrik@hswn.dk>                    */
/* Copyright (C) 2008 Buchan Milne                                            */
/*                                                                            */
/* This program is released under the GNU General Public License (GPL),       */
/* version 2. See the file "COPYING" for details.                             */
/*                                                                            */
/*----------------------------------------------------------------------------*/

static char devmon_rcsid[] = "$Id: do_devmon.c 165 2009-12-16 10:17:11Z buchanmilne $";

int do_devmon_rrd(char *hostname, char *testname, char *msg, time_t tstamp)
{
#define MAXCOLS 20
	char *devmon_params[MAXCOLS+7];
	static char *devmon_tpl      = NULL;

	char *eoln, *curline;
	static int ptnsetup = 0;
	static pcre *inclpattern = NULL;
	static pcre *exclpattern = NULL;
	int in_devmon = 1;
	int numds = 0;
	char *rrdbasename;
	int lineno = 0;

	rrdbasename = NULL;
	curline = msg;
	while (curline)  {
		char *fsline = NULL;
		char *p;
		char *columns[MAXCOLS];
		int columncount;
		char *ifname = NULL;
		int pused = -1;
		int wanteddisk = 1;
		long long aused = 0;
		char *dsval;
		int i;

		eoln = strchr(curline, '\n'); if (eoln) *eoln = '\0';
		lineno++;

		if(!strncmp(curline, "<!--DEVMON RRD: ",16)) {
			in_devmon = 0;
			/*if(rrdbasename) {xfree(rrdbasename);rrdbasename = NULL;}*/
			rrdbasename = strtok(curline+16," ");
			if (rrdbasename == NULL) rrdbasename = xstrdup(testname);
			dbgprintf("DEVMON: changing testname from %s to %s\n",testname,rrdbasename);
			numds = 0;
			if(devmon_tpl) {xfree(devmon_tpl);devmon_tpl= NULL;}
			goto nextline;
		}
		if(in_devmon == 0 && !strncmp(curline, "-->",3)) {
			in_devmon = 1;
			goto nextline;
		}
		if (in_devmon != 0 ) goto nextline;

		for (columncount=0; (columncount<MAXCOLS); columncount++) columns[columncount] = "";
		fsline = xstrdup(curline); columncount = 0; p = strtok(fsline, " ");
		while (p && (columncount < MAXCOLS)) { columns[columncount++] = p; p = strtok(NULL, " "); }

		/* DS:ds0:COUNTER:600:0:U DS:ds1:COUNTER:600:0:U */
		if (!strncmp(curline, "DS:",3)) {
			devmon_params[0] = "rrdcreate";
		       	devmon_params[1] = rrdfn;
			dbgprintf("Looking for DS defintions in %s\n",curline);
			while ( numds < MAXCOLS) {
				dbgprintf("Seeing if column %d that has %s is a DS\n",numds,columns[numds]);
				if (strncmp(columns[numds],"DS:",3)) break;
				devmon_params[numds+2] = xstrdup(columns[numds]);
				numds++;
			}
			dbgprintf("Found %d DS definitions\n",numds);
		       	devmon_params[numds+2] = rra1;
			devmon_params[numds+3] = rra2;
		        devmon_params[numds+4] = rra3;
			devmon_params[numds+5] = rra4;
			devmon_params[numds+6] = NULL;

			if (devmon_tpl == NULL) devmon_tpl = setup_template(devmon_params);
			goto nextline;
		}

		dbgprintf("Found %d columns in devmon rrd data\n",columncount);
		if (columncount > 2) {
			dbgprintf("Skipping line %d, found %d (max 2) columns in devmon rrd data, space in repeater name?\n",lineno,columncount);
			goto nextline;
		}

		/* Now we should be on to values:
		 * eth0.0 4678222:9966777
		 */
		ifname = xstrdup(columns[0]);
		dsval = strtok(columns[1],":");
		if (dsval == NULL) {
			dbgprintf("Skipping line %d, line is malformed\n",lineno);
			goto nextline;
		}
		sprintf(rrdvalues, "%d:", (int)tstamp);
		strcat(rrdvalues,dsval);
		for (i=1;i < numds;i++) {
			dsval = strtok(NULL,":");
			if (dsval == NULL) {
				dbgprintf("Skipping line %d, %d tokens present, expecting %d\n",lineno,i,numds);
				goto nextline;
			}
			strcat(rrdvalues,":");
			strcat(rrdvalues,dsval);
		}
		/* File names in the format if_load.eth0.0.rrd */
		snprintf(rrdfn, sizeof(rrdfn)-1, "%s.%s.rrd", rrdbasename, ifname);
		rrdfn[sizeof(rrdfn)-1] = '\0';
		dbgprintf("Sending from devmon to RRD for %s %s: %s\n",rrdbasename,ifname,rrdvalues);
		create_and_update_rrd(hostname, rrdfn, devmon_params, devmon_tpl);
		if (ifname) { xfree(ifname); ifname = NULL; }

		if (eoln) *eoln = '\n';

nextline:
		if (fsline) { xfree(fsline); fsline = NULL; }
		curline = (eoln ? (eoln+1) : NULL);
	}
	if(devmon_tpl) {xfree(devmon_tpl);devmon_tpl= NULL;}
	return 0;
}
