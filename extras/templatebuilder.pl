#!/usr/bin/perl -w

use strict;
use Data::Dumper;

$|=1;

my $snmpargs = "";
while(scalar @ARGV > 2) {
  $snmpargs .= (shift) . " ";
}
my $host = shift || "localhost";
my $base = shift || "ifTable";

my %trans = ();
my %enum = ();
my @walkproc= ();
my $debug = 1;

sub OIDNumLookup {
  my ($mib,$var,$tail) = @_;
  if($tail =~ /^\..+$/) {
    return $trans{"${mib}::$var"}.$tail;
  } else {
    return $trans{"${mib}::$var$tail"};
  }
}

print "snmpwalk $snmpargs -OE $host $base\n";
my @walk = `snmpwalk $snmpargs -OE $host $base`;
chomp @walk;
#print Dumper @walk;
my $c = -1;
foreach my $l (@walk) {
  if(my ($mib,$var,$tail) = ($l =~ /^([^:]+)::([^.]+)(.*) = /)) {
    push @walkproc,($l);
    $c++;
    next if $trans{"${mib}::$var"};
    $trans{"${mib}::$var"} = "";
#    $trans{"${mib}::$var$tail"} = "";
    if($l =~ /= INTEGER: .*(\d+)$/) {
      print "Adding ${mib}::$var to integers to map\n" if $debug;
      $enum{"${mib}::$var"} = "";
    }
  } else {
    $walkproc[$c] .= "\n$l";
  }
}
my @keylist = sort grep !/\./,keys %trans;
#print Dumper @keylist;
my $transcmd = "snmptranslate -On ".join " ",@keylist;
my @translist = `$transcmd`;
chomp @translist;
#print Dumper @translist;
for(my $i=0;$i<=$#keylist;$i++) {
  $trans{$keylist[$i]} = $translist[2*$i];
}
my @enumlist = keys %enum;
$transcmd = "snmptranslate -Tp ".join " ",@enumlist;
#@translist = grep / (EnumVal|Values:) /,`$transcmd`;
chomp @translist;
foreach (keys %enum) {
  my $snmpcmd = "snmptranslate -Tp $_|grep Values:";
  print "Trying to translate $_ using $snmpcmd\n" if $debug;
  my @snmpvals = `$snmpcmd`;
  print "Received from snmptranslate: ",join "\n",@snmpvals;
  #my $transform = grep /Values:/,@snmpvals;
  my $transform = $snmpvals[0];
  #$transform =~ s/\s+//g;
  print "Transform for $_: $transform\n" if $debug;
  $enum{$_} = $transform;
}
print Dumper(\%enum) if $debug;
#for(my $i=0;$i<=$#enumlist;$i++) {
#  $enum{$enumlist[$i]} = $translist[1+2*$i];
#  $enum{$enumlist[$i]} =~ s/^\s+//;
#}
my %varprint;
my %enumprint;
my @oidprint = ();
my @transformprint = ();
my @threshprint = ();
my %thresh;
my @messageprint = ();
my @branches;
my @leaves;
foreach my $l (@walkproc) {
  print "Assessing $l\n" if $debug;
  my ($mib,$var,$tail,$rest) = ($l =~ /^([^:]+)::([^.]+)(.*)( = .*)$/s);
  $tail ||= "";
  printf ("mib: %s var: %s tail: %s rest: $rest\n",$mib,$var,$tail,$rest) if $debug;
  unless( defined $varprint{"${mib}::$var"} ) {
    if ($tail eq '.0') {
      print "$var\t: ".$trans{"${mib}::$var"}.".0\t: leaf\n";
      push @oidprint,("$var\t: ".$trans{"${mib}::$var"}.".0\t: leaf\n");
      push @leaves,$var;
    } else {
      print "$var\t: ".$trans{"${mib}::$var"}."\t: branch\n";
      push @oidprint,("$var\t: ".$trans{"${mib}::$var"}."\t: branch\n");
      push @branches,$var;
    }
  }
  $varprint{"${mib}::$var"} = 1;
  if($l =~ /= INTEGER: (\d+)/) {
    unless( $enumprint{"${mib}::$var"} ) {
      print "Checking if I can interpret values for $var from the MIB\n" if $debug;
      printf " ##ENUM %s\n",$enum{"${mib}::$var"};
      my $el = $enum{"${mib}::$var"};
      $el =~ s/^\s*Values:\s*//;
      my @elv = map {s/^(.*)\((\-?\d+)\)/$2=$1/; $_;} split /,\s*/,$el;
      if ( my @thv = map {s/^(.*)\(\-?\d+\)/$1/; $_;} split /,\s*/,$el) {
        #@elv =~ s/^(.*)\((\d+)\)/$2=$1/;
        printf "${var}Txt\t: SWITCH\t: {$var} %s\n",join ",",@elv;
        push @transformprint, (sprintf "${var}Txt\t: SWITCH\t: {$var} %s\n",join ",",@elv);
        push @threshprint, (sprintf "${var}Txt\t: green  : %s\t:\n",join "|",grep /(ok|good|online|closed|locked|green)/i,@thv);
        push @threshprint, (sprintf "${var}Txt\t: yellow : %s\t:\n",join "|",grep !/(ok|good|online|closed|locked||green|fail|degrade|offline|alarm|red|off)/i,@thv);
        push @threshprint, (sprintf "${var}Txt\t: red    : %s\t:\n",join "|",grep /(fail|degrade|offline|alarm|red|off)/i,@thv);
	$thresh{$var} = 1;
      }
    }
    $enumprint{"${mib}::$var"} = 1;
  }
  print "${mib}::$var$tail (".OIDNumLookup($mib,$var,$tail).")$rest\n" if $debug;
}
if (@leaves gt 1 ) {
	foreach my $leaf (@leaves) {
		print @messageprint,"{${leaf}.errors}\n" if $thresh{$leaf};
	}
	foreach my $leaf (@leaves) {
		push @messageprint,"$leaf: {$leaf}\n";
	}
}
if (@branches gt 1) {
	push @messageprint,(sprintf "TABLE:\n");
	push @messageprint, join('|',@branches), "\n";
	foreach my $branch (@branches) {
          if ( $thresh{$branch} ) {
	    push @messageprint, "{${branch}Txt.color}{${branch}Txt}{${branch}Txt.errors}"
          } else {
	    push @messageprint, "{$branch}";
          }
	  push @messageprint, '|';
	}
	pop @messageprint;
	push @messageprint,"\n";
}
write_file("oids",\@oidprint);
write_file("transforms",\@transformprint);
write_file("thresholds",\@threshprint);
write_file("exceptions",[]);
write_file("message",\@messageprint);

sub write_file {
	my ($file,$contents) = @_;
	print Dumper($contents) if $debug;
	if ( -e "$file" ) {
		print STDERR "#$file file exists, not overwriting it\n";
		print "===== start $file =====\n",@{$contents},"====== end $file ======\n";
	} else {
		open TMPL,">$file" or warn "Could not open file: $!" and return 0;
		print TMPL @{$contents};
		close TMPL;
	}
	return 1;
}
	

