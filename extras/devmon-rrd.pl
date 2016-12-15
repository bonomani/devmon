#!/usr/bin/perl -w
#    $URL: svn://svn.code.sf.net/p/devmon/code/trunk/extras/devmon-rrd.pl $
#    $Revision
#    $Id: devmon-rrd.pl 95 2008-12-07 19:58:38Z buchanmilne $
# See http://me.kaya.fr/howto_devmon_hobbit.txt
use strict;

# Input parameters: Hostname, testname (column), and messagefile
my $HOSTNAME=$ARGV[0];
my $TESTNAME=$ARGV[1];
my $FNAME=$ARGV[2];

# Read the entire files
open (FILEHANDLE,$FNAME) || die ("cant read file\n");
my @input = <FILEHANDLE>;
close (FILEHANDLE);
my $inrrd=0;
my @ds;
my ($line,$test);

#if ( $TESTNAME eq "if_load" || $TESTNAME eq "temperature" ) {

	# Devmon with the TABLE:rrd(DS:var1:rrdtype; DS:var2:rrdtype2;...)
	# option in the messages file creates output like this:
	# <!--DEVMON RRD: testname 0 0
	# DS:ds0:GAUGE:600:0:U DS:ds1:GAUGE:600:0:U
	# 1 35:62
	# 2 38:80
	# -->
        foreach $line (@input) {
		chomp $line;
		if ($line =~ /^<!--DEVMON RRD: (\w+).*/) {
			$test=$1;
			$inrrd=1;
			next;}
		if ($inrrd == 1) {
			if ($line =~ /^-->/) {
				$inrrd=0;
				next;
			}
			if ($line =~ /^DS/) {
				@ds = split / /, $line;
				foreach (@ds) {print "$_\n";};
				next;
			}
			if ($line =~ /^(\S+)\s*(\d+)(.*)$/) {
				print "${test}.${1}.rrd\n";
                        	print "${2}${3}\n";
			}
		}
        }
#}
