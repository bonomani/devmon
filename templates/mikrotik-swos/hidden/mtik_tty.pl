use Mtik;

use Getopt::Std;

sub usage {
  print STDERR <<EOF;
Raw interface for testing the Mikrotik API.  Examples:
>>> /interface/wireless/access-list/print
>>>
[lots of output]
>>> !done
<<< /interface/wireless/access-list/set
<<< =.id=*F
<<< =comment=SKOOBYDOO2
<<<
>>> !done
<<< quit
Terminate commands sequences with blank line.
Type 'quit' (no quotes) to quit.
usage: $0 -m mtik_host -u mtik_user -p mtik_passwd
-h : help (this message)
-m : hostname or IP of Mikrotik router
-u : admin username
-p : password
EOF
  exit;
}

my($option_str) = "hm:u:p:";
my(%options);
getopts($option_str,\%options);
my($mtik_host) =  $options{'m'};
my($mtik_user) =  $options{'u'};
my($mtik_passwd) =  $options{'p'};
if ($options{'h'} || !($mtik_host && $mtik_user && $mtik_passwd)) {
  usage();
}

$Mtik::debug = 0;
if (Mtik::login($mtik_host,$mtik_user,$mtik_passwd)) {
  my($quit) = 0;
  while (!($quit)) {
    my(@cmd);
    print "<<< ";
    while (<>) {
      chomp;
      $_ =~ s/^<<< //;
      if (/^quit$/i) {
        $quit = 1;
        last;
      }
      elsif (/^$/) {
        last;
      }
      push(@cmd,$_);
      print "<<< ";
    }
    if (!($quit))
    {
      my($retval,@results) = Mtik::raw_talk(\@cmd);
      foreach my $result (@results) {
        print ">>> $result\n";
      }
    }
  }
  Mtik::logout();
}
else {
  print "Couldn't log in to $mtik_host\n";
}
