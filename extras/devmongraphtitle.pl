#!/usr/bin/perl
# Script to get the interface name from the current devmon if_load test
# to use as dynamic graph title command (see hobbitgraph.cfg(5))
# Copyright (c) Buchan Milne <bgmilne@staff.telkomsa.net> 2009
# License GPLv2

use strict;
use warnings;
use Xymon::Client;

my $hostname = shift || "";
my $graphinstance = shift || "";
my $period = shift||"";
my @files = @ARGV;
my $maxdesclen = 82;
my $longheader = "Network traffic on";
my $shortheader = "Traffic on";

my $intdesc;

if (@files gt 1 or @files eq 0) {
	print "Network Traffic $period\n";
	exit 0
}
my $rrd = $files[0];
my ($testname,$intname);
if ($rrd =~ /^([^\.]+)\.(.*)\.rrd$/) {
	($testname,$intname) = ($1,$2);
}
#my ($testname,$intname) = split(/\./,$files[0],3);
$intname =~ s/_/\//g if ($intname);
print "Looking for $intname\n" if $ENV{'DEBUG'};

my $bb;
if ($ENV{'DEBUG'}) {
	$bb=Xymon::Client->new(undef,debug=>1);
} else {
	$bb=Xymon::Client->new;
}
my $result = $bb->hobbitdlog("$hostname.$testname");


#For api returning string
if (0) {
while (<$result>) {
	chomp;
	print if $ENV{'DEBUG'};
	if (m(^<tr><td>$intname ([^<]+)?<\/td><td>)) {
		$intdesc = $1;
		print generate_title($intname,$intdesc), "\n";
		exit 0;
	}
}
}
foreach (@{$result}) {
	print if $ENV{'DEBUG'};
	if (m(^<tr><td>$intname ([^<]+)?<\/td><td>)) {
		$intdesc = $1;
		print generate_title($intname,$intdesc), "\n";
		exit 0;
	}
}
print "Network Traffic on $intname $period\n";

sub generate_title {
	my ($int,$descr) = @_;
	my $title;
	$title = "$longheader $int ($descr) $period";
	return $title if (length($title) <= $maxdesclen);

	if (length($title) > $maxdesclen + length($longheader) - length($shortheader) ) {
		$period =~ s/ Hours/h/;
		$period =~ s/ Days/d/;
	}
	$title = "$shortheader $int ($descr) $period";
	return $title if (length($title) <= $maxdesclen);
	
	$title = "$int ($descr) $period";
	return $title if (length($title) <= $maxdesclen);

	$title = "$int $descr";
	if ( length($title) > $maxdesclen ) {
		substr($descr,length($descr) - length($title) +  $maxdesclen - 3,length($title) - $maxdesclen +3,"..");
		#$title = "$int ($descr) $period";
		$title = "$int $descr";
	}
	return $title;
}

