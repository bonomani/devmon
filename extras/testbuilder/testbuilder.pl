#!/usr/bin/perl -w

use strict;
use Data::Dumper;

$| = 1;  # Disable output buffering for immediate print

# Parse command-line arguments
my $snmpargs = "";
while (scalar @ARGV > 2) {
    $snmpargs .= (shift) . " ";
}
my $host = shift || "localhost";
my $base = shift || "ifTable";

# Hashes to store SNMP translations and enums
my %trans = ();
my %enum = ();
my @walkproc = ();
my $debug = 0;  # Set to 1 for debug output

# Function to perform OID lookup for non-dotted tail
sub OIDNumLookup {
    my ($mib, $var, $tail) = @_;
    return $trans{"${mib}::$var"} . ($tail =~ /^\..+$/ ? $tail : "${mib}::$var$tail");
}

# Fetch SNMP walk output
my @walk = `snmpwalk $snmpargs -OE $host $base`;
chomp @walk;

# Process SNMP walk output line by line
foreach my $line (@walk) {
    chomp $line;

    # Skip non-human-readable output (numeric OIDs)
    if ($line =~ /^\.\d+(\.\d+)*\s*=\s+/) {
        print "Non-human-readable output detected: $line\n" if $debug;
        next;
    }

    # Extract the OID and variable from the line
    if (my ($mib, $var, $tail) = ($line =~ /^([^:]+)::([^.]+)(.*) = /)) {
        push @walkproc, $line;
        
        # Skip already processed OIDs
        next if $trans{"${mib}::$var"};
        
        # Initialize the translation entry
        $trans{"${mib}::$var"} = "";

        # Check for INTEGER values and add them to the enum hash
        if ($line =~ /= INTEGER:\s*\w+\((\d+)\)$/) {
            print "Adding ${mib}::$var to integers to map\n" if $debug;
            $enum{"${mib}::$var"} = $1;  # Store integer value
        }
    } else {
        # Append line to the last processed entry if it doesn't match the OID pattern
        print "Adding return line to last entry: $line\n" if $debug;
        $walkproc[-1] .= "\n$line";
    }
}

# Fetch OID translations for non-dotted entries (from %trans)
my @keylist = sort grep { !/\./ } keys %trans;
foreach my $oid (@keylist) {
    my $snmpcmd = "snmptranslate -On $oid";
    print "Executing: $snmpcmd\n" if $debug;

    # Capture output from snmptranslate
    my @snmpvals = `$snmpcmd`;
    chomp @snmpvals;

    # Assign the translation if snmptranslate returned output
    if (@snmpvals) {
        $trans{$oid} = $snmpvals[0];
    } else {
        warn "No output from snmptranslate for OID $oid\n";
    }
}

# Process the enum list using snmptranslate
foreach my $oid (keys %enum) {
    my $snmpcmd = "snmptranslate -Tp $oid";
    print "Executing: $snmpcmd\n" if $debug;

    # Capture the output of snmptranslate for each enum OID
    my @snmpvals = `$snmpcmd`;
    chomp @snmpvals;

    # Check if snmptranslate returned any output and process the "Values:" line
    if (@snmpvals) {
        my ($transform) = grep { /Values:/ } @snmpvals;
        if ($transform) {
            # Extract the 'Values:' portion and update the enum hash
            $transform =~ s/.*Values:\s*//;
            $enum{$oid} = $transform;
            print "Transform for $oid ($enum{$oid}): $transform\n" if $debug;
        } else {
            warn "No 'Values:' found in snmptranslate output for OID $oid\n";
        }
    } else {
        warn "No output from snmptranslate for OID $oid\n";
    }
}

# Optional: Print out the collected data if debug is enabled
if ($debug) {
    print "Processed walk data:\n";
    print Dumper(\%trans);
    print Dumper(\%enum);




}

#!/usr/bin/perl -w

use strict;
use Data::Dumper;

$| = 1;  # Disable output buffering for immediate print

# Initialize variables
my %varprint;
my %enumprint;
my @oidprint;
my @transformprint;
my @threshprint;
my %thresh;
my @messageprint;
my @branches;
my @leaves;

foreach my $line (@walkproc) {
    print "Assessing $line\n" if $debug;

    # Match the line and extract MIB, var, tail, and rest
    my ($mib, $var, $tail, $rest) = ($line =~ /^([^:]+)::([^.]+)(.*)( = .*)$/s);
    $tail ||= "";

    # Debugging print for MIB, var, tail, rest
    printf("mib: %s var: %s tail: %s rest: %s\n", $mib, $var, $tail, $rest) if $debug;

    # Check if this OID is already processed
    unless (defined $varprint{"${mib}::$var"}) {
        # Handle leaves and branches
        if ($tail eq '.0') {
            print "$var\t: ".$trans{"${mib}::$var"}.".0\t: leaf\n" if $debug;
            push @oidprint, "$var\t: ".$trans{"${mib}::$var"}.".0\t: leaf\n";
            push @leaves, $var;
        } else {
            print "$var\t: ".$trans{"${mib}::$var"}."\t: branch\n" if $debug;
            push @oidprint, "$var\t: ".$trans{"${mib}::$var"}."\t: branch\n";
            push @branches, $var;
        }
    }

    # Mark this OID as processed
    $varprint{"${mib}::$var"} = 1;

    # Check for INTEGER values and process them
    if ($line =~ /= INTEGER:\s*\w+\((\d+)\)$/) {
        unless ($enumprint{"${mib}::$var"}) {
            $enumprint{"${mib}::$var"} = 1;
            print "Checking if I can interpret values for $var from the MIB ${mib}\n" if $debug;
            my $el = $enum{"${mib}::$var"};
            next unless defined $el;

            printf " ##ENUM %s\n", $enum{"${mib}::$var"} if $debug;

            # Clean the 'Values:' part and split it into key-value pairs
            $el =~ s/^\s*Values:\s*//;
            my @elv = map { s/^(.*)\((\-?\d+)\)/$2=$1/; $_; } split /,\s*/, $el;

            # Handle thresholds based on values
            if (my @thv = map { s/^(.*)\(\-?\d+\)/$1/; $_; } split /,\s*/, $el) {
                printf "${var}Txt\t: SWITCH\t: {$var} %s\n", join ",", @elv if $debug;
                push @transformprint, sprintf("${var}Txt\t: SWITCH\t: {$var} %s\n", join ",", @elv);
                push @threshprint, sprintf("${var}Txt\t: green  : %s\t:\n", join "|", grep /(ok|good|online|closed|locked|green)/i, @thv);
                push @threshprint, sprintf("${var}Txt\t: yellow : %s\t:\n", join "|", grep !/(ok|good|online|closed|locked|green|fail|degrade|offline|alarm|red|off)/i, @thv);
                push @threshprint, sprintf("${var}Txt\t: red    : %s\t:\n", join "|", grep /(fail|degrade|offline|alarm|red|off)/i, @thv);
                $thresh{$var} = 1;
            }
        }
    }

    # Debug print for the OID lookup
    print "${mib}::$var$tail (" . OIDNumLookup($mib, $var, $tail) . ")$rest\n" if $debug;
}

# Generate messages for leaves
if (@leaves > 1) {
    foreach my $leaf (@leaves) {
        push @messageprint, "{${leaf}.errors}\n" if $thresh{$leaf};
    }
    foreach my $leaf (@leaves) {
        push @messageprint, "$leaf: {$leaf}\n";
    }
}

# Generate messages for branches
if (@branches > 1) {
    push @messageprint, "TABLE:\n";
    push @messageprint, join('|', @branches), "\n";
    foreach my $branch (@branches) {
        if ($thresh{$branch}) {
            push @messageprint, "{${branch}Txt.color}{${branch}Txt}{${branch}Txt.errors}";
        } else {
            push @messageprint, "{$branch}";
        }
        push @messageprint, '|';
    }
    pop @messageprint;
    push @messageprint, "\n";
}

# Write collected data to files
write_file("oids", \@oidprint);
write_file("transforms", \@transformprint);
write_file("thresholds", \@threshprint);
write_file("exceptions", []);
write_file("message", \@messageprint);

# Subroutine to handle file writing
sub write_file {
    my ($file, $contents) = @_;
    print Dumper($contents) if $debug;
    if (-e $file) {
        print STDERR "#$file file exists, not overwriting it\n";
        print "===== start $file =====\n", @{$contents}, "====== end $file ======\n";
    } else {
        open my $fh, '>', $file or warn "Could not open file: $!" and return 0;
        print $fh @{$contents};
        close $fh;
    }
    return 1;
}

