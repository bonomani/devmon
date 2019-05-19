package dm_templates;
require Exporter;
@ISA	   = qw(Exporter);
@EXPORT    = qw(read_templates sync_templates);
@EXPORT_OK = qw(%c);

#    Devmon: An SNMP data collector & page generator for the
#    Xymon network monitoring systems
#    Copyright (C) 2005-2006  Eric Schwimmer
#    Copyright (C) 2007  Francois Lacroix
#
#    $URL: svn://svn.code.sf.net/p/devmon/code/trunk/modules/dm_templates.pm $
#    $Revision: 246 $
#    $Id: dm_templates.pm 246 2014-11-27 13:19:01Z buchanmilne $
#
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.  Please see the file named
#    'COPYING' that was included with the distrubition for more details.

# Modules
use strict;
require dm_config;
dm_config->import();

# The global option hash. Be afraid!
use vars qw(%g);
*g = \%dm_config::g;

# Global array and hash by descending priority/severity
my %colors = ('red' => 6, 'yellow' => 5, 'clear' => 4, 'purple' => 3, 'green' => 2, 'blue' => 1);
my @color_order = sort {$colors{$b} <=> $colors{$a}} keys %colors;
my $color_list = join '|', @color_order;

# Read templates from DB or from disk, depending on our multinode type
sub read_templates {
   do_log('DEBUG TEMPLATES: running read_templates()',0) if $g{debug};
   if($g{multinode} eq 'yes') {
      read_template_db() ;
   } else {
      read_template_files() ;
   }

   # Do various post-load template mucking
   post_template_load();
}

# Read templates from db
sub read_template_db {
   my %model_index;
   my %test_index;
   my $read_temps = 'n';

   # Only do a read if we need to (empty temp hash or update flag set true)
   my $num_templates = scalar (keys %{$g{templates}});
   return if ($num_templates != 0 and
      $g{node_status}{nodes}{$g{my_nodenum}}{read_temps} eq 'n');

   do_log('Reading template data from DB',1);

   # Reset templates
   %{$g{templates}} = ();

   # Read in our model index
   my @models = db_get_array('id,vendor,model,snmpver,sysdesc ' .
      'from template_models');
   for my $row (@models) {
      my ($id, $vendor, $model, $snmpver, $sysdesc) = @$row;

      $model_index{$id} = { 'vendor'  => $vendor,
         'model'   => $model };

      $g{templates}{$vendor}{$model}{snmpver} = $snmpver;
      $g{templates}{$vendor}{$model}{sysdesc} = $sysdesc;
   }

   # Read in our test index
   my @tests = db_get_array('id,mod_id,test from template_tests');
   for my $row (@tests) {
      my ($id, $mod_id, $test) = @$row;

      $test_index{$id} = { 'vendor'  => $model_index{$mod_id}{vendor},
         'model'   => $model_index{$mod_id}{model},
         'test'    => $test };
   }

   # Read oids from the database
   my @results = db_get_array(
      'test_id,name,num,`repeat`,t_type,t_data from template_oids'
   );

   for my $oid_row (@results) {
      my ($id,$name,$num,$repeat, $trans_type, $trans_data) = @$oid_row;

      my $vendor = $test_index{$id}{vendor};
      my $model  = $test_index{$id}{model};
      my $test   = $test_index{$id}{test};

      my $tmpl = \%{$g{templates}{$vendor}{$model}{tests}{$test}};

      $tmpl->{oids}{$name}{number}     = $num if defined $num;
      $tmpl->{oids}{$name}{repeat}     = $repeat if defined $repeat;
      $tmpl->{oids}{$name}{trans_type} = $trans_type if defined $trans_type;
      $tmpl->{oids}{$name}{trans_data} = $trans_data if defined $trans_data;
   }

   # Read thresholds from the database
   @results = db_get_array(
      'test_id,oid,color,thresh,msg from template_thresholds'
   );

   for my $oid_row (@results) {
      my ($id,$oid,$color,$thresh,$msg) = @$oid_row;

      my $vendor = $test_index{$id}{vendor};
      my $model  = $test_index{$id}{model};
      my $test   = $test_index{$id}{test};

      my $tmpl = \%{$g{templates}{$vendor}{$model}{tests}{$test}};

      $tmpl->{oids}{$oid}{thresh}{$color}{val} = $thresh;
      $tmpl->{oids}{$oid}{thresh}{$color}{msg} = $msg if defined $msg;
   }

   # Read exceptions from the database
   @results = db_get_array('test_id,oid,type,data from template_exceptions');

   for my $oid_row (@results) {
      my ($id,$oid,$type,$data) = @$oid_row;

      my $vendor = $test_index{$id}{vendor};
      my $model  = $test_index{$id}{model};
      my $test   = $test_index{$id}{test};

      my $tmpl = \%{$g{templates}{$vendor}{$model}{tests}{$test}};

      $tmpl->{oids}{$oid}{except}{$type} = $data;
   }

   # Read messages from database
   @results = db_get_array('test_id,msg from template_messages');

   for my $oid_row (@results) {
      my ($id,$msg) = @$oid_row;

      my $vendor = $test_index{$id}{vendor};
      my $model  = $test_index{$id}{model};
      my $test   = $test_index{$id}{test};

      my $tmpl = \%{$g{templates}{$vendor}{$model}{tests}{$test}};

      # Convert newline placeholders
      $msg =~ s/\\n/\n/;
      $msg =~ s/~~n/\\n/;

      $tmpl->{msg} = $msg;
   }

   # Now update our read_temps flag in the node config DB
   db_do("update nodes set read_temps='n' where node_num=$g{my_nodenum}");
}

# Read in user-definable templates from disk
sub read_template_files {
   # Reset templates
   %{$g{templates}} = ();

   # Get all dirs in templates subdir
   my $template_dir = $g{homedir} . "/templates";
   opendir TEMPLATES, $template_dir or
   log_fatal("Unable to open template directory ($!)",0);

   my @dirs;
   for my $entry (readdir TEMPLATES) {
      my $dir = "$template_dir/$entry";
      push @dirs, $dir if -d $dir and $entry !~ /^\..*$/; # . and .svn or .cvs
   }

   # Go through each directory
   MODEL: for my $dir (@dirs) {
      my $tmpl = {};

      # Read in our specs file
      my ($vendor, $model, $snmpver, $sysdesc) = read_specs_file($dir);

      # No info? Go to the next one
      next MODEL if !defined $vendor  or !defined $model or
      !defined $snmpver or !defined $sysdesc;

      # Our model specific snmp info
      $g{templates}{$vendor}{$model}{snmpver} = $snmpver;
      $g{templates}{$vendor}{$model}{sysdesc} = $sysdesc;

      # Now go though our subdirs which contain our tests
      opendir MODELDIR, $dir or
      log_fatal("Unable to open template directory ($!)",0);

      TEST: for my $test (readdir MODELDIR) {
         # Only if this is a test dir
         my $testdir = "$dir/$test";
         next if !-d $testdir or $test =~ /^\..*$/; # . and .svn or .cvs

         # Barf if we are trying to define a pre-existing template
         if(defined $g{templates}{$vendor}{$model}{tests}{$test}) {
            do_log("Attempting to redefine $vendor/$model/$test template " .
               "when reading data from $dir.");
            next TEST;
         }

         # Create template shortcut
         $g{templates}{$vendor}{$model}{tests}{$test} = {};
         $tmpl = \%{$g{templates}{$vendor}{$model}{tests}{$test}};

         # Read in the other files files, if all previous reads have succeeded
         read_oids_file($testdir, $tmpl) and
         read_transforms_file($testdir, $tmpl) and
         read_thresholds_file($testdir, $tmpl) and
         read_exceptions_file($testdir, $tmpl) and
         read_message_file($testdir, $tmpl);

         # Make sure we dont have any partial templates hanging around
         delete $g{templates}{$vendor}{$model}{tests}{$test}
         if !defined $tmpl->{msg};

         do_log("DEBUG TEMPLATES: read $vendor:$model:$test template")
         if $g{debug};
      }

      # If we dont have any tests, delete the model info
      delete $g{templates}{$vendor}{$model}
      if (scalar keys %{$g{templates}{$vendor}{$model}{tests}}) == 0;
   }
   return;
}

# Do various post-load stuff on templates
sub post_template_load {
   do_log('DEBUG TEMPLATES: running post_template_load()', 0) if $g{debug};
   for my $vendor (keys %{$g{templates}}) {
      for my $model (keys %{$g{templates}{$vendor}}) {
         for my $test (keys %{$g{templates}{$vendor}{$model}{tests}}) {
            my $tmpl = \%{$g{templates}{$vendor}{$model}{tests}{$test}};

            PTL_OID: for my $oid (keys %{$tmpl->{oids}}) {
               my $oid_h = \%{$tmpl->{oids}{$oid}};
               my $trans_type = $oid_h->{trans_type};

               # For now we arent doing anything to non-translated oids; skip them
               next if !defined $trans_type;

               # Pre-compute the switch-style case tables, so we dont have
               # to do it on a per-oid basis later
               if($trans_type eq 'switch' or $trans_type eq 'tswitch') {
                  my ($dep_oid, $switch_data) = ($1, $2) if
                  $oid_h->{trans_data} =~ /\{(.+?)}\s*(.+)/;
                  next if !defined $dep_oid;

                  $oid_h->{trans_edata} = {};
                  my $trans_data = \%{$oid_h->{trans_edata}};
                  my $cases      = \%{$trans_data->{cases}};
                  my $case_num   = 0;
                  my $default;

                  $trans_data->{dep_oid} = $dep_oid;

                  for my $val_pair (split /\s*,\s*/, $switch_data) {
                     if( $val_pair =~ /^\s*(["'].*["'])\s*=\s*(.*?)\s*$/) {
                        my ($if, $then) = ($1, $2);
                        my $type = '';
                        if($if =~ /^'(.+)'$/) {
                           $type = 'str';
                           $if = $1
                        } elsif($if =~ /^"(.+)"$/) {
                           $type = 'reg';
                           $if = $1
                        }
                        $cases->{++$case_num}{if} = $if;
                        $cases->{$case_num}{type} = $type;
                        $cases->{$case_num}{then} = $then;

                     } elsif( $val_pair =~ /^\s*([><]?.+?)\s*=\s*(.*?)\s*$/) {
                        my ($if, $then) = ($1, $2);
                        my $type = '';
                        if($if =~ /^\d+$/) {
                           $type = 'num'
                        } elsif($if =~ /^>\s*([+-]?\d+(?:\.\d+)?)$/) {
                           $if = $1;
                           $type = 'gt';
                        } elsif($if =~ /^>=\s*([+-]?\d+(?:\.\d+)?)$/) {
                           $if = $1;
                           $type = 'gte';
                        } elsif($if =~ /^<\s*([+-]?\d+(?:\.\d+)?)$/) {
                           $if = $1;
                           $type = 'lt';
                        } elsif($if =~ /^<=\s*([+-]?\d+(?:\.\d+)?)$/) {
                           $if = $1;
                           $type = 'lte';
                        } elsif ( $if =~ /^([+-]?\d+(?:\.\d+)?)\s*-\s*([+-]?\d+(?:\.\d+)?)$/) {
                           $if = "$1-$2";
                           $type = 'rng';
                        } elsif($if =~ /^default$/i) {
                           $default = $then;
                           next;
                        }
                        $cases->{++$case_num}{if} = $if;
                        $cases->{$case_num}{type} = $type;
                        $cases->{$case_num}{then} = $then;

                     } else {
                        do_log("Could not parse $dep_oid : ".uc($trans_type)." option '$val_pair'");
                        next PTL_OID;
                     }
                  }

                  # Sort our case numbers this once
                  @{$trans_data->{case_nums}} = sort {$a <=> $b} keys %$cases;

                  # Make sure we have a default value
                  $trans_data->{default} = $default || 'Unknown';
               }

            }

         }
      }
   }
}

# Read in 'type' file
sub read_specs_file {
   my ($dir) = @_;

   no strict 'refs';

   # Define the file; make sure it exists and is readable
   my $specs_file = "$dir/specs";
   do_log ("Missing 'specs' file in $dir, skipping this test.", 0)
      and return 0 if !-e $specs_file;

   open FILE, "$specs_file"
      or do_log("Failed to open $specs_file ($!), skipping this test.", 0)
      and return 0;

   # Define our applicable variables
   my %vars = ('vendor' => '', 'model' => '', snmpver => '', sysdesc => '');

   # Read in file
   while (my $line = <FILE>) {
      chomp $line;

      # Skip whitespace and comments
      next if $line =~ /^\s*(#.*)?$/;

      # Seperate variable and assigned value (colon delimited)
      my ($var, $val) = split /\s*:\s*/, $line, 2;
      $var = lc $var;
      # Make sure we got all our variables and they are non-blank and valid
      if (!defined $val) {
         do_log("Syntax error: Undefined value in $specs_file at line $.", 0);
         next ;
      } else {
         # Trim right (left done by split)
         do_log("Syntax warning: Trailing space(s) in $specs_file at line $.", 0) if $val =~ s/\s$//;
         if ($val eq '') {
            do_log("Syntax error: Missing spec value in $specs_file at line $.", 0);
            next;
         # Check our snmp version
         } elsif($var eq 'snmpver') {
            $val = '2' if $val eq '2c';
            if ($val !~ /^1|2$/) {
               do_log("Syntax error: Bad snmp version ($val) in $specs_file, line $." .
                  "(only ver. 1/2c supported).  Skipping this test", 0);
               return;
            }
         }
      }
      # Assign the value in our temp hash
      $vars{$var} = $val;
   }

   close FILE;

   # Make sure we got all our necessary vars
   for my $var (keys %vars) {
      my $val = $vars{$var};
      do_log("'$var' not defined in $specs_file, skipping this test.", 0)
         and return 0 if !defined $val or $val eq '';
   }
   # Now return out anon hash ref
   my $vendor  = $vars{vendor};
   my $model   = $vars{model};
   my $snmpver = $vars{snmpver};
   my $sysdesc = $vars{sysdesc};
   return ($vendor, $model, $snmpver, $sysdesc);
}

# Read in oids file
sub read_oids_file {
   my ($dir, $tmpl) = @_;

   # Define the file; make sure it exists and is readable
   my $oid_file = "$dir/oids";
   do_log ("Missing 'oids' file in $dir, skipping this test.", 0)
      and return 0 if !-e $oid_file;
   open FILE, "$oid_file"
      or do_log("Failed to open $oid_file ($!), skipping this test.", 0)
      and return 0;

   # Go through file, read in oids
   while (my $line = <FILE>) {
      chomp $line;

      # Skip whitespace and comments
      next if $line =~ /^\s*(#.*)?$/;

      my ($oid, $number, $repeat) = split /\s*:\s*/, $line, 3;

      # Make sure we got all our variables and they are non-blank and valid
      if (!defined $number) {
         do_log("Syntax error: Missing colon separator near oid value in $oid_file at line $.", 0);
         next ;
      } else {
         if ($number eq '') {
            do_log("Syntax error: Missing oid value in $oid_file at line $.", 0);
            next;
         }
         # TODO: We should valide also OID format
      }
      if (!defined $repeat) {
         do_log("Syntax error: Missing colon separator near repeater type in $oid_file at line $.", 0);
         next;
      } else {
         # Trim right (left done by split)
         do_log("Syntax warning: Trailing space(s) in $oid_file at line $.", 0) if $repeat =~ s/\s$//;
         if ($repeat eq '') {
            do_log("Syntax error: Missing repeater type in $oid_file at line $.", 0);
            next;
         # Make sure repeater variable is valid
         } elsif ($repeat !~ /^leaf$|^branch$/) {
            do_log("Syntax error: Invalid repeater type '$repeat' for $oid in $oid_file", 0);
            next;
         }
      }

      # Make sure this oid hasnt been defined before
      do_log("$oid defined more than once in $oid_file", 0) and next
      if defined $tmpl->{oids}{$oid};

      # Make repeater variable boolean
      $repeat = ($repeat eq 'branch') ? 1 : 0;

      # Remove leading dot from oid, if any
      $number =~ s/^\.//;

      # Assign variables to global hash
      $tmpl->{oids}{$oid}{number} = $number;
      $tmpl->{oids}{$oid}{repeat} = $repeat;

      # Reverse oid map
      $tmpl->{map}{$number} = $oid;
   }

   close FILE;
   return 1;
}

# Read in transforms file
sub read_transforms_file {
   my ($dir, $tmpl) = @_;

   # Define our valid transforms functions
   my %trans = ();
   my $deps  = {};
   my $path  = [];

   # Define the file; make sure it exists and is readable
   # Delete the global hash, too
   my $trans_file = "$dir/transforms";
   do_log ("Missing 'transforms' file in $dir, skipping this test.", 0)
      and return 0 if !-e $trans_file;
   open FILE, "$trans_file"
      or do_log("Failed to open $trans_file ($!), skipping this test.", 0)
      and return 0;

   # Go through file, read in oids
   my @text  = <FILE>;
   close FILE;
   my $l_num = 0;
   LINE: while (my $line = shift @text) {
      ++$l_num;
      my $adjust = 0;
      chomp $line;

      # Skip whitespace and comments
      next if $line =~ /^\s*(#.*)?$/;

      # Concatenate lines that have a continuation char \ at the end of the line,
      # remove \$ and adjust the current number of the line
      while($line =~ s/\s*\\$//) {
         my $cont_line  = shift @text;
         if (defined $cont_line) {
            chomp $cont_line;
            ++$adjust;
            $cont_line =~ s/^\s+//;
            $line .= $cont_line;
         } else {
            do_log("The continuation char \ is not follow by a line $trans_file at line $l_num", 0);
         }
      }
      # Validate curly bracket
      my $curly_bracket = $line;
      $curly_bracket =~ s/\{([^{}\s]+)\}//g;
      do_log("Curly brackets are not balanced/conform or contain space char in $trans_file at line $l_num", 0)
         and next if $curly_bracket =~ /{|}/;

      # Render oid & function
      my ($oid, $func_type, $func_data) = split /\s*:\s*/, $line, 3;

      # Make sure we got all our variables and they are non-blank and valid
      if (!defined $func_type) {
         do_log("Syntax error: Missing colon separator near function type in $trans_file at line $l_num", 0);
         next ;
      } else {
         if ($func_type eq '') {
            do_log("Syntax error: Missing function type in $trans_file at line $l_num", 0);
            next;
         }
         # TODO: We should valide format
      }
      if (!defined $func_data) {
         do_log("Syntax error: Missing colon separator near function data in $trans_file at line $l_num", 0);
         next;
      } else {
         # Trim right (left done by split)
         do_log("Syntax warning: Trailing space(s) in $trans_file at line $l_num", 0) if $func_data =~ s/\s$//;
         if ($func_data eq '') {
            do_log("Syntax error: Missing function data in $trans_file at line $l_num", 0);
            next;
         }
      }

      # Make sure this oid hasnt been defined before
      # TODO: Would be nice to check that if it was defined
      # before, both oid are realy the same
      do_log("Cant redefine $oid  in $trans_file", 0) and next
      if defined $tmpl->{oids}{$oid};

      # Make sure function is a real one and that it is formatted correctly
      # 1. It is already trimed both sides
      # 2. Curly bracket are valid
      # 3. Empty space are not allow

      my $temp   = $func_data;
      $func_type = lc $func_type;
      CASE: {
         $func_type eq 'best' and do {
            #          $temp =~ s/\s*\{\s*\S+?\s*\}|\s*,\s*//g;
            $temp =~ s/\{\S+\}|\s*,\s*//g;
            do_log("BEST transform uses only comma-delimited oids at " .
               "$trans_file, line $l_num", 0)
               and next LINE if $temp ne '';
            last CASE;
         };

         $func_type eq 'chain' and do {
            #          $temp =~ s/\s*\{\s*\S+?\s*\}\s*\{\s*\S+?\s*\}\s*//g;
            $temp =~ s/^\{\S+\}\s*\{\S+\}//;
            do_log("CHAIN uses exactly two dependent oids at " .
               "$trans_file, line $l_num", 0)
               and next LINE if $temp ne '';
            last CASE;
         };

         $func_type eq 'coltre' and do {
            #          $temp =~ s/\s*\{\s*\S+?\s*\}\s*\{\s*\S+?\s*\}\s*($|:\s*\S+?\s*$|:\s*\S*?\s*(|,)\s*[rl]\d*[({].[)}]\s*$)//g;
            #          $temp =~ s/^\{\S+?\}\s*\{\S+?\}\s*(|:\s*\S+?|:\s*\S*?\s*(|,)\s*[rl]\d*[({].[)}])//;
            $temp =~ s/^\{\S+\}\s*\{\S+?\}($|\s*:\s*\S+?$|\s*:\s*\S*?(|\s*,)\s*[rl]\d*[({].[)}])//;
            do_log("COLTRE uses two dependent oids and optional arguments at " .
               "$trans_file, line $l_num", 0)
               and next LINE if $temp ne '';
            last CASE;
         };

         $func_type eq 'convert' and do {
            #          $temp =~ s/\s*\{\s*\S+?\s*\}\s+(hex|oct)(\s*\d*)\s*//i;
            $temp =~ s/^\{\S+\}\s+(hex|oct)(?:\s*\d*)//i;
            my ($type) = ($1); #??
            do_log("CONVERT transform uses only a single oid, a valid " .
               "conversion type & an option pad length at " .
               "$trans_file, line $l_num", 0)
               and next LINE if $temp ne '';
            last CASE;
         };

         $func_type eq 'date' and do {
            #          $temp =~ s/\s*\{\s*\S+?\s*\}|\s*,\s*//g;
            $temp =~ s/^\{\S+\}//;
            do_log("DATE transform uses only a single oid at " .
               "$trans_file, line $l_num", 0)
               and next LINE if $temp ne '';
            last CASE;
         };

         $func_type eq 'delta' and do {
            #          $temp =~ s/\s*\{\s*\S+?\}(\s*\d*)\s*//;
            $temp =~ s/^\{\S+\}(?:$|\s+\d+$)//;
            do_log("DELTA transform  only a single oid (plus an " .
               "optional limit) at $trans_file, line $l_num", 0)
               and next LINE if $temp ne '';
            last CASE;
         };

         $func_type eq 'elapsed' and do {
            #          $temp =~ s/\s*\{\s*\S+?\s*\}\s*//g;
            $temp =~ s/^\{\S+\}//;
            do_log("ELAPSED transform uses only a single oid at " .
               "$trans_file, line $l_num", 0)
               and next LINE if $temp ne '';
            last CASE;
         };

         $func_type eq 'sort' and do {
            $temp =~ s/^\{\S+\}//;
            do_log("SORT transform uses only a single oid at " .
               "$trans_file, line $l_num", 0)
               and next LINE if $temp ne '';
            last CASE;
         };

         $func_type eq 'index' and do {
            #          $temp =~ s/\s*\{\s*\S+?\s*\}|\s*,\s*//g;
            $temp =~ s/^\{\S+\}//;
            do_log("INDEX transform uses only a single oid at " .
               "$trans_file, line $l_num", 0)
               and next LINE if $temp ne '';
            last CASE;
         };

         $func_type eq 'match' and do {
            #	  $temp =~ s/^\{\s*\S+?\s*\}\s*\/.+\/\s*$//g;
            $temp =~ s/^\{\S+\}\s+\/.+\///;
            do_log("MATCH transform should be a perl regex match at " .
               "$trans_file, line $l_num", 0)
               and next LINE if $temp ne '';
            last CASE;
         };

         $func_type eq 'math' and do {
            $temp =~ s/:\s*\d+\s*$//;
            #          $temp =~ s/\{\s*\S+?\s*\}|\s\.\s|\s+x\s+|\*|\+|\/|-|\^|%|\||&|\d+(\.\d*)?|\(|\)|abs\(//g;
            $temp =~ s/\{\S+\}|\s\.\s|\s+x\s+|\*|\+|\/|-|\^|%|\||&|\d+(?:\.\d+)?|\(|\)//g;
            $temp =~ s/\s*//;
            do_log("MATH transform uses only math/numeric symbols and an " .
               "optional precision number, $temp did not pass, at $trans_file, line $l_num", 0)
               and next LINE if $temp !~ /^\s*$/;
            last CASE;
         };

         $func_type eq 'eval' and do {
            #          $temp =~ s/^.+\s*$//g;
            #          do_log("EVAL transform should be a perl regex match at " .
            #                 "$trans_file, line $l_num", 0)
            #            and next LINE if $temp ne '';
            last CASE;
         };

         $func_type eq 'pack' and do {
            #          $temp =~ s/^\s*\{\s*\S+?\s*\}\s+(\S+)(\s+.+)?//;
            $temp =~ s/^\{\S+\}\s+(\S+)(\s+.+)?//;
            my $type = $1;
            my $validChars = 'aAbBcCdDfFhHiIjJlLnNsSvVuUwxZ';
            do_log("PACK transform uses only a single oid,an encode type, " .
               "and an optional seperator at $trans_file, line $l_num", 0)
               and next LINE if $temp ne '';
            do_log("No encode type at $trans_file, line $l_num", 0)
               and next LINE if !defined $type;
            while($type =~ s/\((.+?)\)(\d+|\*)?//) {
               my $bit = $1;
               do_log("Bad encode type ($bit) at $trans_file, line $l_num", 0)
                  and next LINE if $bit !~ /^([$validChars](\d+|\*)?)+$/i;
            }
            do_log("Bad encode type ($type) at $trans_file, line $l_num", 0)
               and next LINE if $type ne '' and
            $type !~ /^([$validChars](\d+|\*)?)+$/i;
            last CASE;
         };

         $func_type eq 'regsub' and do {
            #          $temp =~ s/^\{\s*\S+?\s*\}\s*\/.+\/.*\/[eg]*\s*$//;
            $temp =~ s/^\{\S+\}\s*\/.+\/.*\/[eg]*//;
            do_log("REGSUB transform should be a perl regex substitution at " .
               "$trans_file, line $l_num", 0)
               and next LINE if $temp ne '';
            last CASE;
         };

         $func_type eq 'set' and do {
            $temp = '{}'		if $temp =~ m/^\s*$/ ;
            $temp =~ tr/{}//cd ;		# Check for OID references
            do_log("SET transform requires a non-empty list of constant values at " .
               "$trans_file, line $l_num", 0)
               and next LINE	if $temp ne '' ;
            last CASE ;
         };

         $func_type eq 'speed' and do {
            #          $temp =~ s/\s*\{\s*\S+?\s*\}|\s*,\s*//g;
            $temp =~ s/^\{\S+}//;
            do_log("SPEED transform uses only a single oid at " .
               "$trans_file, line $l_num", 0)
               and next LINE if $temp ne '';
            last CASE;
         };

         $func_type eq 'statistic' and do {
            $temp =~ s/^\{\S+\}\s+(?:avg|cnt|max|min|sum)//i;
            do_log("STATISTIC transform uses only a single oid at " .
               "$trans_file, line $l_num", 0)
               and next LINE if $temp ne '';
            last CASE;
         };

         $func_type eq 'substr' and do {
            #          $temp =~ s/\s*\{\s*\S+?\s*\}\s+(\d+)\s*(\d*)\s*//;
            $temp =~ s/^\{\S+\}\s+\d+(?:$|\s+\d+)//;
            do_log("SUBSTR transform uses only a single oid, a numeric offset " .
               "and an optional shift value at $trans_file, line $l_num", 0)
               and next LINE if $temp ne '';
            last CASE;
         };

         $func_type eq 'switch' and do {
            #          $temp =~ s/^\s*\{\s*\S+?\s*\}\s*//g;
            $temp =~ s/^\{\S+\}\s*//;
            my $temp2 = '';
            for my $val (split /\s*,\s*/, $temp) {
               my ($if, $then);
               ($if, $then) = ($1, $2) if $val =~ s/^\s*(["'].*["'])\s*=\s*(.*?)\s*$//;
               if (!defined($if)) {
                  ($if, $then) = ($1, $2) if $val =~ s/^\s*([><]?.+?)\s*=\s*(.*?)\s*$//;
               }
               do_log("Bad SWITCH value pair ($val) at $trans_file, line $l_num",0)
                  and next if !defined $if;
               my $type;
               if($if =~ /^\d+$/) {
                  $type = 'num';
               } elsif($if =~ /^>\s*\d+(\.\d+)?$/)  {
                  $type = 'gt';
               } elsif($if =~ /^>=\s*\d+(\.\d+)?$/) {
                  $type = 'gte';
               } elsif($if =~ /^<\s*\d+(\.\d+)?$/)  {
                  $type = 'lt';
               } elsif($if =~ /^<=\s*\d+(\.\d+)?$/) {
                  $type = 'lte';
               } elsif($if =~ /^\d+(\.\d+)?\s*-\s*\d+(\.\d+)?$/) {
                  $type = 'rng';
               } elsif($if =~ /^'(.+)'$/) {
                  $type = 'str';
               } elsif($if =~ /^"(.+)"$/) {
                  $type = 'reg';
               } elsif($if =~ /^default$/i) {
                  $type = 'default';
               } else {
                  do_log("Bad SWITCH case type ($if) at $trans_file, line $l_num",0);
                  next ;
               }

               $temp2 .= $val
            }
            do_log("SWITCH transform uses a comma delimited list of values " .
               "in 'case = value' format at $trans_file, line $l_num", 0)
               and next LINE if $temp2 ne '';
            last CASE;
         };

         $func_type eq 'tswitch' and do {
            #          $temp =~ s/^\s*\{\s*\S+?\s*\}\s*//g;
            $temp =~ s/^\{\S+\}\s*//;
            my $temp2 = '';
            for my $val (split /\s*,\s*/, $temp) {
               my ($if, $then);
               ($if, $then) = ($1, $2) if $val =~ s/^\s*(["'].*["'])\s*=\s*(.*?)\s*$//;
               if (!defined($if)) {
                  ($if, $then) = ($1, $2) if $val =~ s/^\s*([><]?.+?)\s*=\s*(.*?)\s*$//;
               }
               do_log("Bad TSWITCH value pair ($val) at $trans_file, " .
                  "line $l_num",0) and next if !defined $if;
               my $type;
               if($if =~ /^\d+$/) {
                  $type = 'num'
               } elsif($if =~ /^>\s*\d+(\.\d+)?$/)  {
                  $type = 'gt'
               } elsif($if =~ /^>=\s*\d+(\.\d+?)$/) {
                  $type = 'gte'
               } elsif($if =~ /^<\s*\d+(\.\d+)?$/)  {
                  $type = 'lt'
               } elsif($if =~ /^<=\s*\d+(\.\d+)?$/) {
                  $type = 'lte'
               } elsif($if =~ /^\d+(\.\d+)?\s*-\s*\d+(\.\d+)?$/) {
                  $type = 'rng'
               } elsif($if =~ /^'(.+)'$/) {
                  $type = 'str'
               } elsif($if =~ /^"(.+)"$/) {
                  $type = 'reg'
               } elsif($if =~ /^default$/i) {
                  $type = 'default'
               } else {
                  do_log("Bad TSWITCH case type ($if) at $trans_file, line $l_num",0);
                  next ;
               }

               $temp2 .= $val
            }
            do_log("TSWITCH transform uses a comma delimited list of values " .
               "in 'case = value' format at $trans_file, line $l_num", 0)
               and next LINE if $temp2 ne '';
            last CASE;
         };

         $func_type eq 'unpack' and do {
            #          $temp =~ s/^\s*\{\s*\S+?\s*\}\s+(\S+)(\s+".+")?//;
            $temp =~ s/^\{\S+\}\s+(\S+)(?:\s+.+)?//;
            my $type = $1;
            my $validChars = 'aAbBcCdDfFhHiIjJlLnNsSvVuUwxZ';
            do_log("UNPACK transform uses only a single oid,a decode type, " .
               "and an optional seperator at $trans_file, line $l_num", 0)
               and next LINE if $temp ne '';
            do_log("No decode type at $trans_file, line $l_num", 0)
               and next LINE if !defined $type;
            while($type =~ s/\((.+?)\)(\d+|\*)?//) {
               my $bit = $1;
               do_log("Bad decode type ($bit) at $trans_file, line $l_num", 0)
                  and next LINE if $bit !~ /^([$validChars](\d+|\*)?)+$/i;
            }
            do_log("Bad decode type ($type) at $trans_file, line $l_num", 0)
               and next LINE if $type ne '' and
            $type !~ /^([$validChars](\d+|\*)?)+$/i;
            last CASE;
         };

         $func_type eq 'worst' and do {
            #          $temp =~ s/\s*\{\s*\S+?\s*\}|\s*,\s*//g;
            $temp =~ s/\{\S+\}|\s*,\s*//g;
            do_log("WORST transform uses only comma-delimited oids at " .
               "$trans_file, line $l_num", 0)
               and next LINE if $temp ne '';
            last CASE;
         };

         do_log("Syntax error: Unknown function '$func_type' at $trans_file, line $l_num", 0);
         next LINE;
      }

      # Stick in our temporary hash
      $trans{$oid}{data} = $func_data;
      $trans{$oid}{type} = $func_type;

      # Adjust our line number if we had continuation character
      $l_num += $adjust;
   }

   # Now go through our translations and make sure all the dependent oids exist
   for my $oid (keys %trans) {
      my $data = $trans{$oid}{data};
      while($data =~ s/\{(.+?)\}//) {
         my $dep_oid = $1;

         # Validate oid
         do_log("Undefined oid '$dep_oid' referenced in $trans_file", 0)
            and delete $trans{$oid} and next
         if !defined $tmpl->{oids}{$dep_oid} and !defined $trans{$dep_oid};

         #        $deps->{$oid}{$dep_oid} = {};
         $deps->{$dep_oid}{$oid} = {};
      }
   }

   #   # Find dependency loops (tricky!)
   #    my $val = find_deps($deps, \%trans, $path);
   #    return 0 if $val == 0;
   # Complete the list of dependecies to include those OIDs which do not depend
   # on another OID, and which are not used in any transformation rule. They too
   # should be included in the sorted list, used to evaluate the OIDs.
   for my $oid ( keys %trans ) {
      next			if $trans{$oid}{data}=~ m/\{.+?\}/ ;
      next			if exists $deps->{$oid} ;
      $deps->{$oid}= {} ;		# Create entry
   }  # of for

   # Sort the OIDs in a order in which they need to be calculated. At the same
   # time any dependency loop is found and reported.
   my $val = sort_oid( $deps );
   return 0			unless defined $val;
   $tmpl->{sort} = $val;

   # Now add the translations to the global hash
   for my $oid (keys %trans) {
      my $type = $trans{$oid}{type};
      my $data = $trans{$oid}{data};
      $tmpl->{oids}{$oid}{trans_type} = $type;
      $tmpl->{oids}{$oid}{trans_data} = $data;
   }

   return 1;
}

# Build a dependency tree for translated oids and find any loops
# or missing oids that defined ones may be dependent on
sub find_deps {
   my ($deps, $trans, $path) = @_;

   # Our path variable keeps track of where in the tree we are
   @$path = () if !defined $path;

   # pointer variable to act as a placeholder for our current spot in the tree
   my $pointer = \%{$deps};
   for my $pt (@$path) {$pointer = \%{$pointer->{$pt}}}

   # Now iterate through the oids in our current spot in the tree
   for my $oid (keys %$pointer) {

      # Update our path
      push @$path, $oid;

      # Determine our root id, used later for troubleshooting
      my $root_oid = $path->[0];

      # See if this variable is preset in the translation hash
      if(defined $trans->{$oid}) {
         # If it is, see if it has other oids that it depends on
         my $data = $trans->{$oid}{data};
         while($data =~ s/\{(.+?)\}//) {

            # It depends on other oids; iterate into them to make sure that
            # they are defined and that we dont loop back and depend on a
            # oid defined somewhere earlier in our path
            my $dep_oid = $1;
            my @temp = @$path;
            while (my $path_oid = shift @temp) {
               next if $path_oid ne $dep_oid;
               do_log("$root_oid has a looped dependency: " .
                  join('->', @$path), 0);
               return 0;
            }
            $pointer->{$oid}{$dep_oid} = {}
            if !defined $pointer->{$oid}{$dep_oid};
            my $val = find_deps($deps, $trans, $path);
            return 0 if $val == 0;
         }
      }
      pop @$path;
   }

   return 1;
}

# Function sort-oid sorts the OIDs used in the transformations in a order
# in which they are to be calculated: each OID is sorted after the OIDs it
# depends on.
# At the same time, it checks the dependencies for any circular chains. If no
# such chain is found, this function returns a reference to the sorted list of
# OIDs. If at least one circular chain is found, the returned value is undef.
#
# This function uses the topological sort method.
#
sub sort_oid($) {
   my $deps= $_[0] ;
   my @Sorted= () ;			# Sorted list of OIDs
   my %Cnt= () ;			# Dependency counters
   my ($oid,$mods) ;			# Loop control variables

   #
   # Build table %Cnt. It specifies for each OID the number of other OIDs which
   # are needed to compute the OID.
   #
   foreach $oid ( keys %$deps ) {
      $Cnt{$oid}= 0		unless exists $Cnt{$oid} ;
      foreach ( keys %{$$deps{$oid}} ) {
         $Cnt{$_}= 0		unless exists $Cnt{$_} ;
         $Cnt{$_}++ ;
      }  # of foreach
   }  # of foreach

   #
   # Sort the OIDs. If for a given OID no other OIDs are needed to compute its
   # value, move that OID to the sorted list and decrease the counts of each OID
   # which is computed using this OID. This process is repeated until no OIDs can
   # be moved any more. Any remaining OIDs, mentioned in %Cnt, must be in a
   # circular chain of dependencies.
   #
   $mods= 1 ;				# End-of-loop indicator
   while ( $mods > 0 ) {
      $mods= 0 ;				# Preset mod-count of this pass
      foreach $oid ( keys %Cnt ) {
         next			unless $Cnt{$oid} == 0 ;
         if ( exists $$deps{$oid} ) {
            $Cnt{$_}--		foreach keys %{$$deps{$oid}} ;
            $mods++ ;			# A counter is changed
         }  # of if
         push @Sorted, $oid ;		# Move OID to sorted list
         delete $Cnt{$oid} ;
      }  # of foreach
   }  # of while

   if ( keys %Cnt ) {
      do_log( "The following OIDs are in one or more circular depency chains: " .
         join(', ',sort keys %Cnt), 0 ) ;
      return undef ;			# Circular dependency chain found
   } else {
      return \@Sorted ;			# No circular dependency chains found
   }  # of else
}

# Subroutine to read in the thresholds file
sub read_thresholds_file {
   my ($dir, $tmpl) = @_;

   # Define our valid transforms functions
   my %colors = ('red' => 1, 'yellow' => 1, 'green' => 1, 'clear' => 1, 'blue' => 1, 'purple', =>1);

   # Define the file; make sure it exists and is readable
   # Delete the global hash, too
   my $thresh_file = "$dir/thresholds";
   do_log("Missing 'thresholds' file in $dir, skipping this test.", 0)
      and return 0 if !-e $thresh_file;
   open FILE, "$thresh_file"
      or do_log("Failed to open $thresh_file ($!), skipping this test.", 0)
      and return 0;
   # Go through file, read in oids
   while (my $line = <FILE>) {
      chomp $line;

      # Skip whitespace and comments
      next if $line =~ /^\s*(#.*)?$/;

      # Validate curly bracket
      my $curly_bracket = $line;
      $curly_bracket =~ s/\{([^{}\s]+)\}//g;
      do_log("Curly bracket error in $thresh_file at line $.", 0) and next if $curly_bracket =~ /{|}/;

      # Render variables
      my ($oid, $color, $threshold, $msg) = split /\s*:\s*/, $line, 4;

      # Make sure we got all our variables and they are non-blank and valid
      if (!defined $color) {
         do_log("Syntax error:  Missing colon separator near color value in $thresh_file at line $.", 0);
         next ;
      } else {
         if ($color eq '') {
            do_log("Syntax error: Missing color value in $thresh_file at line $.", 0);
            next;
         # Validate colors
         } elsif (!defined $colors{$color}) {
            do_log("Syntax error: Invalid color value in $thresh_file at line $.", 0);
            next;
         }
      }
      if (!defined $threshold) {
         # If a threshold is blank, it should automatch any value
         $threshold = "_AUTOMATCH_";
      } else {
         if ($threshold eq '') {
            # If a threshold is blank, it should automatch any value
            $threshold = "_AUTOMATCH_";
         }
      }
      if (!defined $msg) {
         if (!defined $threshold) {
            # Trim right (left done by split)
            do_log("Syntax warning: Trailing space(s) in $thresh_file at line $.", 0) if $color  =~ s/\s$//;
         } else {
            # Trim right (left done by split)
            do_log("Syntax warning: Trailing space(s) in $thresh_file at line $.", 0) if $threshold =~ s/\s$//;
         }
      } else {
         # Trim right (left done by split)
         do_log("Syntax warning: Trailing space(s) in $thresh_file at line $.", 0) if $msg  =~ s/\s$//;
      }

      # Validate oid
      do_log("Undefined oid '$oid' referenced in $thresh_file at line $.", 0)
         and next if !defined $tmpl->{oids}{$oid};

      # Validate any oids in the message
      my $tmp = $msg;
      while(defined $tmp and $tmp =~ s/\{(.+?)}//) {
         my $oid  = $1;
         $oid=~ s/\..+$//;     # Remove flag, if any
         do_log("Undefined oid '$1' referenced in " .
            "$thresh_file at line $.", 0)
         if !defined $tmpl->{oids}{$oid};
      }

      # Add the threshold to the global hash
      $tmpl->{oids}{$oid}{thresh}{$color}{val} = $threshold;
      $tmpl->{oids}{$oid}{thresh}{$color}{msg} = $msg;
   }
   close FILE;

   return 1;
}

# Subroutine to read in the exceptions file
sub read_exceptions_file {
   my ($dir, $tmpl) = @_;

   # Define our valid exception types
   my %excepts = (
      'ignore'  => 1,
      'only'    => 1,
      'noalarm' => 1,
      'alarm'   => 1);

   # Define the file; make sure it exists and is readable
   # Delete the global hash, too
   my $except_file = "$dir/exceptions";
   do_log ("Missing 'exceptions' file in $dir, skipping this test.", 0)
      and return 0 if !-e $except_file;
   open FILE, "$except_file"
      or do_log("Failed to open $except_file ($!), skipping this test.", 0)
      and return 0;

   # Go through file, read in oids

   while (my $line = <FILE>) {
      chomp $line;

      # Skip whitespace and comments
      next if $line =~ /^\s*(#.*)?$/;

      # Validate curly bracket
      my $curly_bracket = $line;
      $curly_bracket =~ s/\{([^{}\s]+)\}//g;
      do_log("Curly bracket error in $except_file at line $.", 0) and next if $curly_bracket =~ /{|}/;

      # Render variables
      my ($oid, $type, $data) = split /\s*:\s*/, $line, 3;

      #     # Trim right (left done by split)
      #      $data =~ s/\s+$//;

      # Make sure we got all our variables and they are non-blank
      if (!defined $type) {
         do_log("Syntax error: Missing colon separator near exception type in $except_file at line $.", 0);
         next ;
      } else {
         if ($type eq '') {
            do_log("Syntax error: Missing oid value in $except_file at line $.", 0);
            next;
         # Validate exception type
         } elsif (!defined $excepts{$type}) {
            do_log("Syntax error: Invalid exception type '$type' for $oid in $except_file", 0);
            next;
         }
      }
      if (!defined $data) {
         do_log("Syntax error: Missing colon separator near exception data in $except_file at line $.", 0);
         next;
      } else {
         # Trim right (left done by split)
         do_log("Syntax warning: Trailing space(s) in $except_file at line $.", 0) if $data =~ s/\s$//;
         if ($data eq '') {
            do_log("Syntax error: Missing typption data $except_file at line $.", 0);
            next;
         }
      }
      # Make sure we dont have an except defined twice
      do_log("Exception for $oid redefined in $except_file at " .
         "line $.",0) and next
      if defined $tmpl->{oids}{$oid}{except}{$type};

      # Validate oid
      do_log("Undefined oid '$oid' in $except_file at line $.", 0)
         and next if !defined $tmpl->{oids}{$oid};

      # Add the threshold to the global hash
      $tmpl->{oids}{$oid}{except}{$type} = $data;

   }

   close FILE;
   return 1;
}

# Read in the message that will be sent to the xymon server
sub read_message_file {
   my ($dir, $tmpl) = @_;

   my $oid_tags = "color|msg|errors|thresh:(?:$color_list)";
   my $msg;

   # Define the file; make sure it exists and is readable
   # Delete the global hash, too
   my $msg_file = "$dir/message";
   do_log ("Missing 'message' file in $dir, skipping this test.", 0)
      and return 0 if !-e $msg_file;

   open FILE, "$msg_file"
      or do_log("Failed to open $msg_file ($!), skipping this test.", 0)
      and return 0;

   # Go through file, read in oids
   my $table_at = 0;
   my $header   = 0;
   for my $line (<FILE>) {

      # Skip comments
      next if $line =~ /^\s*#.*$/;

      # Add our line to our current message
      $msg .= $line;

      # Verify oids
      for my $oid ($line =~ /\{(.+?)\}/g) {
         # Remove tags
         $oid =~ s/.($oid_tags)$//;

         do_log("Undefined oid '$oid' at line $. of $msg_file, " .
            "skipping this test.", 0) and return 0
         if !defined $tmpl->{oids}{$oid};
      }

      # If we have seen a table header, try and read in the info
      if($table_at) {

         # Skip whitespace
         next if $line =~ /^\s*$/;

         # Allow one line of header info
         if ($line !~ /\{.+\}/) {$header = 1; next}

         # Complain if we havent found any oids yet
         do_log("Table definition at line $table_at of $msg_file has no " .
            "OIDs defined. Skipping this test.", 0)
            and return 0 if $header and $line !~ /\{.+\}/;

         # Otherwise verify each oid in the table data
         for my $col (split /\s*\|\s*/, $line) {
            for my $oid ($col =~ /\{(.+?)}/g) {
               $oid =~ s/\.($oid_tags)$//;
               do_log ("Undefined oid '$oid' at line $. of " .
                  "$msg_file, skipping this test.", 0)
                  and return 0 if !defined $tmpl->{oids}{$oid};
            }
         }

         # Reset our indicators
         $table_at = $header = 0;
      }

      # If we found a table placeholder, validate its options, then make note
      # and skip to next line
      if ($line =~ /^\s*(?:TABLE|NONHTMLTABLE):\s*(.*)/) {
         my $opts = $1;
         do_log("NONHTMLTABLE tag used in $msg_file is deprecated, use " .
            "'nonhtml' TABLE option instead.") and $line =~ s/NONHTMLTABLE/TABLE/
         if $1 eq 'NONHTMLTABLE';
         my %t_opts;

         for my $optval (split /\s*,\s*/, $opts) {
            my ($opt,$val) = ($1,$2) if $optval =~ /(\w+)(?:\((.+)\))?/;
            $val = 1 if !defined $val;
            push @{$t_opts{$opt}}, $val;
         }

         # Check our table options for validity
         for my $opt (keys %t_opts) {
            if ($opt eq 'nonhtml' or
               $opt eq 'plain' or
               $opt eq 'sort' or
               $opt eq 'border' or
               $opt eq 'pad' or
               $opt eq 'noalarmsmsg' or
               $opt eq 'alarmsonbottom') {
            } elsif($opt eq 'rrd') {
               for my $rrd_opt (@{$t_opts{$opt}}) {
                  my $got_ds = 0;
                  for my $sub_opt (split /\s*;\s*/, $rrd_opt) {
                     if(lc $sub_opt eq 'all')    {
                     } elsif(lc $sub_opt eq 'dir') {
                     } elsif(lc $sub_opt eq 'max') {
                     } elsif(lc $sub_opt =~ /^name:(\S+)$/) {
                     } elsif(lc $sub_opt =~ /^pri:(\S+)$/) {
                        do_log("Undefined rrd oid '$1' at $msg_file line $.")
                           and return 0 if !defined $tmpl->{oids}{$1};
                     } elsif($sub_opt =~ /^DS:(\S+)$/) {
                        my ($ds,$oid,$type,$time,$min,$max) = split /:/, $1;
                        do_log("Invalid rrd ds name '$ds' at $msg_file line $.")
                           and return 0 if defined $ds and $ds =~ /\W/;
                        do_log("No RRD oid defined at $msg_file line $.")
                           and return 0 if !defined $oid;
                        do_log("Undefined rrd oid '$oid' at $msg_file line $.")
                           and return 0 if !defined $tmpl->{oids}{$oid};
                        do_log("Bad rrd datatype '$type' at $msg_file line $.")
                           and return 0 if defined $type and $type ne ''
                           and $type !~ /^(GAUGE|COUNTER|DERIVE|ABSOLUTE)$/;
                        do_log("Bad rrd maxtime '$time' at $msg_file line $.")
                           and return 0 if defined $time and $time ne ''
                           and ($time !~ /^\d+/ or $time < 1);
                        do_log("Bad rrd min value '$min' at $msg_file line $.")
                           and return 0 if defined $min and $min ne ''
                           and $min !~ /^[-+]?(\d+)$/;
                        do_log("Bad rrd max value '$max' at $msg_file line $.")
                           and return 0 if defined $max and $max ne ''
                           and $max !~ /^([-+]?(\d+)|U$)/;
                        do_log("rrd max value > min value at $msg_file line $.")
                           and return 0 if (defined $min and $min ne '' and
                           defined $max and $max ne '' and $max <= $min) or
                        (defined $max and $max ne '' and $max < 0);
                        $got_ds = 1;
                     } else {
                        do_log("Bad rrd option '$sub_opt' at $msg_file line $.");
                        return 0;
                     }
                  }

                  do_log("No dataset included for RRD at $msg_file line $.")
                     and return 0 if !$got_ds;
               }
            } else {
               do_log("Invalid option '$opt' for table at line $. in $msg_file");
               return 0;
            }
         }

         $table_at = $.;
      }

   }

   # Assign the msg
   $tmpl->{msg} = $msg;

   close FILE;
   return 1;
}

# Sync the global db to our local template structure
sub sync_templates {
   my %index;
   my $model_id = 0;
   my $test_id  = 0;

   # Make sure we are in multinode mode
   die "--synctemplates flag only applies if you have the local 'MULTINODE'\n" .
   "option set to 'YES'\n" if $g{multinode} ne 'yes';

   # Read templates in from disk
   read_template_files();

   # Connect to the DB
   db_connect();

   # Erase our model index
   db_do("delete from template_models");
   # Erase our tests index
   db_do("delete from template_tests");
   # Erase our oids DB
   db_do("delete from template_oids");
   # Now erase our thresholds DB
   db_do("delete from template_thresholds");
   # Now erase our exceptions DB
   db_do("delete from template_exceptions");
   # Erase our messages DB
   db_do("delete from template_messages");

   # Create our template index
   for my $vendor (sort keys %{$g{templates}}) {

      for my $model (sort keys %{$g{templates}{$vendor}}) {
         # Increment our model index number
         ++$model_id;

         # Add our test index info
         my $snmpver = $g{templates}{$vendor}{$model}{snmpver};
         my $sysdesc = $g{templates}{$vendor}{$model}{sysdesc};

         # Make the sysdesc mysql-safe
         db_do("insert into template_models values " .
            "($model_id, '$vendor','$model',$snmpver,'$sysdesc')");

         # Now go through all our tests and add them
         for my $test (sort keys %{$g{templates}{$vendor}{$model}{tests}}) {
            # Increment our test index number
            ++$test_id;

            # Add our test index info
            db_do("insert into template_tests values ($test_id, $model_id,'$test')");

            # Template shortcut
            my $tmpl = \%{$g{templates}{$vendor}{$model}{tests}{$test}};

            # Insert our oids into the DB
            for my $oid (keys %{$tmpl->{oids}}) {

               # Prepare our data for insert
               my $number = $tmpl->{oids}{$oid}{number};
               my $repeat = $tmpl->{oids}{$oid}{repeat};
               my $t_type = $tmpl->{oids}{$oid}{trans_type};
               my $t_data = $tmpl->{oids}{$oid}{trans_data};
               $number = (defined $number) ? "'$number'" : 'NULL';
               $repeat = (defined $repeat) ? "'$repeat'" : 'NULL';
               $t_type = (defined $t_type) ? "'$t_type'" : 'NULL';
               $t_data = (defined $t_data) ? "'$t_data'" : 'NULL';

               # Insert our oids into DB
               db_do("insert into template_oids values " .
                  "($test_id, '$oid', $number, $repeat, $t_type, $t_data)");

               # Insert our thresholds into the DB
               for my $color (keys %{$tmpl->{oids}{$oid}{thresh}}) {

                  # Prepare our data for insert
                  my $val = $tmpl->{oids}{$oid}{thresh}{$color}{val};
                  my $txt = $tmpl->{oids}{$oid}{thresh}{$color}{msg};

                  $txt = (defined $txt) ? "'$txt'" : 'NULL';

                  # Insert our thresholds into DB
                  db_do("insert into template_thresholds values " .
                     "($test_id,'$oid','$color','$val',$txt)");
               }

               # Insert our exceptions into the DB
               for my $type (keys %{$tmpl->{oids}{$oid}{except}}) {

                  # Prepare our data for insert
                  my $data = $tmpl->{oids}{$oid}{except}{$type};

                  # Insert our thresholds into DB
                  db_do("insert into template_exceptions values " .
                     "($test_id,'$oid','$type','$data')");
               }

            } # End of for my $oid

            # Now insert our messages into the DB
            my $msg = $tmpl->{msg};

            # Convert newlines into placeholders
            $msg =~ s/\\n/~~n/;
            $msg =~ s/\n/\\n/;

            db_do("insert into template_messages values ($test_id, '$msg')");

         }

      }

   }

   # Update our nodes DB to let all nodes know to reload template data
   db_do("update nodes set read_temps='y'");

   # Now quit
   do_log("Template synchronization complete",0);
   exit 0;
}
