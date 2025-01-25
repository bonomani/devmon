package dm_templates;
require Exporter;
@ISA       = qw(Exporter);
@EXPORT    = qw(read_templates sync_templates);
@EXPORT_OK = qw(%c);

#    Devmon: An SNMP data collector & page generator for the
#    Xymon network monitoring systems
#    Copyright (C) 2005-2006  Eric Schwimmer
#    Copyright (C) 2007  Francois Lacroix
#
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.  Please see the file named
#    'COPYING' that was included with the distrubition for more details.

# Modules
use strict;
use Storable qw(dclone);
use Data::Dumper;
use Time::HiRes qw(time);
require dm_config;
use dm_config qw(FATAL ERROR WARN INFO DEBUG TRACE);
dm_config->import();

# The global option hash. Be afraid!
use vars qw(%g);
*g = \%dm_config::g;

# Global array and hash by descending priority/severity
my %colors      = ( 'red' => 6, 'yellow' => 5, 'clear' => 4, 'purple' => 3, 'green' => 2, 'blue' => 1 );
my @color_order = sort { $colors{$b} <=> $colors{$a} } keys %colors;
my $color_list  = join '|', @color_order;

# Read templates from DB or from disk, depending on our multinode type
sub read_templates {
    do_log( 'Reading devices templates', INFO );
    if ( $g{multinode} eq 'yes' ) {
        read_template_db();
    } else {
        read_template_files();
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
    my $num_templates = scalar( keys %{ $g{templates} } );
    return if ( $num_templates != 0
        and $g{node_status}{nodes}{ $g{my_nodenum} }{read_temps} eq 'n' );
    do_log( 'Reading template data from DB', INFO );

    # Read in our model index
    my @models = db_get_array( 'id,vendor,model,sysdesc from template_models' );
    for my $row ( @models ) {
        my ( $id, $vendor, $model, $sysdesc ) = @$row;
        $model_index{$id} = {
            'vendor' => $vendor,
            'model'  => $model
        };
        $g{templates}{$vendor}{$model}{sysdesc} = $sysdesc;
    }

    # Read in our test index
    my @tests = db_get_array( 'id,mod_id,test from template_tests' );
    for my $row ( @tests ) {
        my ( $id, $mod_id, $test ) = @$row;
        $test_index{$id} = {
            'vendor' => $model_index{$mod_id}{vendor},
            'model'  => $model_index{$mod_id}{model},
            'test'   => $test
        };
    }

    # Read oids from the database
    my @results = db_get_array( 'test_id,name,num,`repeat`,t_type,t_data from template_oids' );

    for my $oid_row ( @results ) {
        my ( $id, $name, $num, $repeat, $trans_type, $trans_data ) = @$oid_row;
        my $vendor = $test_index{$id}{vendor};
        my $model  = $test_index{$id}{model};
        my $test   = $test_index{$id}{test};
        my $tmpl   = \%{ $g{templates}{$vendor}{$model}{tests}{$test} };
        $tmpl->{oids}{$name}{number}     = $num        if defined $num;
        $tmpl->{oids}{$name}{repeat}     = $repeat     if defined $repeat;
        $tmpl->{oids}{$name}{trans_type} = $trans_type if defined $trans_type;
        $tmpl->{oids}{$name}{trans_data} = $trans_data if defined $trans_data;
    }

    # Read thresholds from the database
    @results = db_get_array( 'test_id,oid,color,thresh,msg from template_thresholds' );

    for my $oid_row ( @results ) {
        my ( $id, $oid, $color, $threshes, $msg ) = @$oid_row;
        my $vendor = $test_index{$id}{vendor};
        my $model  = $test_index{$id}{model};
        my $test   = $test_index{$id}{test};
        my $tmpl   = \%{ $g{templates}{$vendor}{$model}{tests}{$test} };
        $tmpl->{oids}{$oid}{threshold}{$color}{$threshes} = undef;
        $tmpl->{oids}{$oid}{threshold}{$color}{$threshes}{msg} = $msg if defined $msg;
    }

    # Read exceptions from the database
    @results = db_get_array( 'test_id,oid,type,data from template_exceptions' );

    for my $oid_row ( @results ) {
        my ( $id, $oid, $type, $data ) = @$oid_row;
        my $vendor = $test_index{$id}{vendor};
        my $model  = $test_index{$id}{model};
        my $test   = $test_index{$id}{test};
        my $tmpl   = \%{ $g{templates}{$vendor}{$model}{tests}{$test} };
        $tmpl->{oids}{$oid}{except}{$type} = $data;
    }

    # Read messages from database
    @results = db_get_array( 'test_id,msg from template_messages' );

    for my $oid_row ( @results ) {
        my ( $id, $msg ) = @$oid_row;
        my $vendor = $test_index{$id}{vendor};
        my $model  = $test_index{$id}{model};
        my $test   = $test_index{$id}{test};
        my $tmpl   = \%{ $g{templates}{$vendor}{$model}{tests}{$test} };

        # Convert newline placeholders
        $msg =~ s/\\n/\n/;
        $msg =~ s/~~n/\\n/;
        $tmpl->{msg} = $msg;
    }

    # Now update our read_temps flag in the node config DB
    db_do( "update nodes set read_temps='n' where node_num=$g{my_nodenum}" );
}

# Read in user-definable templates from disk
sub read_template_files {

    # Get all dirs in templates subdir
    #my $template_dir = $g{homedir} . "/templates";
    my $templates_dir = $g{templates_dir};
    opendir TEMPLATES, $templates_dir
        or log_fatal( "Template error: Unable to open template directory ($!)", 1 );

    my @dirs;
    for my $entry ( readdir TEMPLATES ) {
        my $dir = "$templates_dir/$entry";
        do_log( "Folder $dir is not readable, skipping this template", ERROR )
            and next
            if !-r $dir;
        push @dirs, $dir if -d $dir and $entry !~ /^\..*$/;    # . and .svn or .cvs
    }

    # Go through each directory
MODEL: for my $dir ( @dirs ) {
        my $tmpl = {};

        # Read in our specs file
        my ( $vendor, $model, $sysdesc ) = read_specs_file( $dir );

        # No info? Go to the next one
        next MODEL if !defined $vendor or !defined $model or !defined $sysdesc;

        # Our model specific snmp info
        $g{templates}{$vendor}{$model}{sysdesc} = $sysdesc;
        $g{templates}{$vendor}{$model}{dir}     = $dir;

        # Now go though our subdirs which contain our tests
        opendir MODELDIR, $dir or

            do_log( "Unable to open template directory ($!), skipping this template", ERROR )
            and next MODEL;

    TEST: for my $test ( readdir MODELDIR ) {

            # Only if this is a test dir
            my $testdir = "$dir/$test";
            if ( ( $test eq 'README' ) or ( $test eq 'hidden' ) or ( $test eq 'specs' ) or ( $test eq '.' ) or ( $test eq '..' ) ) {
                next;
            } elsif ( !-d $testdir ) {
                do_log( "$testdir is not a folder, skipping this test", ERROR );
                next;
            } elsif ( $test =~ /^\./ ) {
                do_log( "Test folder $testdir start with a '.' , skipping this test", INFO );
                next;
            } elsif ( !-r $testdir ) {
                do_log( "Unable to read test folder $testdir, skipping this test", ERROR );
                next;
            }

            # Honor 'probe' and 'match' command line: Filter unmatch template
            if ( defined $g{match_test} and $test !~ /$g{match_test}/ and $g{match_test} ne '' ) {
                next;
            }

            # Barf if we are trying to define a pre-existing template
            if ( defined $g{templates}{$vendor}{$model}{dir} and $g{templates}{$vendor}{$model}{dir} ne $dir ) {
                do_log( "Attempting to redefine $vendor/$model template when reading data from $dir", ERROR );
                next TEST;
            }
            my $critic_tmpl_valid;

            # Create template shortcut
            $tmpl = \%{ $g{templates}{$vendor}{$model}{tests}{$test} };

            # Read the template file: at least a oids or transform file is needed
            $critic_tmpl_valid = read_oids_file( $testdir, $tmpl ) + read_transforms_file( $testdir, $tmpl );
            if ( $critic_tmpl_valid ) {
                read_thresholds_file( $testdir, $tmpl );
                my $oids_file   = "$testdir/oids";
                my $trans_file  = "$testdir/transforms";
                my $thresh_file = "$testdir/thresholds";
                if ( $tmpl->{file}{$oids_file}{changed} or $tmpl->{file}{$trans_file}{changed} or $tmpl->{file}{$thresh_file}{changed} ) {

                    # Compute dependencies
                    if ( calc_template_test_deps( $testdir, $tmpl ) ) {
                        do_log( "Dependency calc for test '$vendor:$model:$test' successfull", TRACE ) if $g{debug};
                    } else {

                        # delete test template if something went wrong
                        delete $g{templates}{$vendor}{$model}{tests}{$test};
                        do_log( "Test '$vendor:$model:$test' skipped", WARN );
                        next TEST;
                    }
                }
                read_exceptions_file( $testdir, $tmpl );
                read_message_file( $testdir, $tmpl );
                do_log( "Test '$vendor:$model:$test' loaded", DEBUG ) if $g{debug};
            } else {
                do_log( "Test '$vendor:$model:$test' skipped", WARN );
            }
        }

        # If we don't have any tests, warn
        if ( not scalar keys %{ $g{templates}{$vendor}{$model}{tests} } ) {

            # dont warn if it this because test are filtered by honoring 'probe' and 'match'
            if ( not defined $g{match_test} ) {
                do_log( "Template '$vendor:$model' has not any valid test", WARN );
            }
        }
    }
    return;
}

# Do various post-load stuff on templates
sub post_template_load {
    do_log( 'Running post_template_load()', DEBUG ) if $g{debug};
    for my $vendor ( keys %{ $g{templates} } ) {
        for my $model ( keys %{ $g{templates}{$vendor} } ) {
            for my $test ( keys %{ $g{templates}{$vendor}{$model}{tests} } ) {
                my $tmpl = \%{ $g{templates}{$vendor}{$model}{tests}{$test} };

            PTL_OID: for my $oid ( keys %{ $tmpl->{oids} } ) {
                    my $oid_h      = \%{ $tmpl->{oids}{$oid} };
                    my $trans_type = $oid_h->{trans_type};

                    # For now we aren't doing anything to non-translated oids; skip them
                    next if !defined $trans_type;

                    # Pre-compute the switch-style case tables, so we don't have
                    # to do it on a per-oid basis later
                    if ( $trans_type eq 'switch' or $trans_type eq 'tswitch' ) {
                        my ( $dep_oid, $switch_data ) = ( $1, $2 )
                            if $oid_h->{trans_data} =~ /\{(.+?)\}\s*(.+)/;
                        next if !defined $dep_oid;

                        $oid_h->{trans_edata} = {};
                        my $trans_data = \%{ $oid_h->{trans_edata} };
                        my $cases      = \%{ $trans_data->{cases} };
                        my $case_num   = 0;
                        my $default;
                        $trans_data->{dep_oid} = $dep_oid;

                        for my $val_pair ( split /\s*,\s*/, $switch_data ) {
                            if ( $val_pair =~ /^\s*(["'].*["'])\s*=\s*(.*?)\s*$/ ) {
                                my ( $if, $then ) = ( $1, $2 );
                                my $type = '';
                                if ( $if =~ /^'(.+)'$/ ) {
                                    $type = 'str';
                                    $if   = $1;
                                } elsif ( $if =~ /^"(.+)"$/ ) {
                                    $type = 'reg';
                                    $if   = $1;
                                }
                                $cases->{ ++$case_num }{if} = $if;
                                $cases->{$case_num}{type}   = $type;
                                $cases->{$case_num}{then}   = $then;

                            } elsif ( $val_pair =~ /^\s*([><]?.+?)\s*=\s*(.*?)\s*$/ ) {
                                my ( $if, $then ) = ( $1, $2 );
                                my $type = '';
                                if ( $if =~ /^=?(\d+)$/ ) {
                                    $if   = $1;
                                    $type = 'num';
                                } elsif ( $if =~ /^>\s*([+-]?\d+(?:\.\d+)?)$/ ) {
                                    $if   = $1;
                                    $type = 'gt';
                                } elsif ( $if =~ /^>=\s*([+-]?\d+(?:\.\d+)?)$/ ) {
                                    $if   = $1;
                                    $type = 'gte';
                                } elsif ( $if =~ /^<\s*([+-]?\d+(?:\.\d+)?)$/ ) {
                                    $if   = $1;
                                    $type = 'lt';
                                } elsif ( $if =~ /^<=\s*([+-]?\d+(?:\.\d+)?)$/ ) {
                                    $if   = $1;
                                    $type = 'lte';
                                } elsif ( $if =~ /^([+-]?\d+(?:\.\d+)?)\s*-\s*([+-]?\d+(?:\.\d+)?)$/ ) {
                                    $if   = "$1-$2";
                                    $type = 'rng';
                                } elsif ( $if =~ /^default$/i ) {
                                    $default = $then;
                                    next;
                                }
                                $cases->{ ++$case_num }{if} = $if;
                                $cases->{$case_num}{type}   = $type;
                                $cases->{$case_num}{then}   = $then;

                            } else {
                                do_log( "Could not parse $dep_oid : " . uc( $trans_type ) . " option '$val_pair'", ERROR );
                                next PTL_OID;
                            }
                        }

                        # Sort our case numbers this once
                        @{ $trans_data->{case_nums} } = sort { $a <=> $b } keys %$cases;

                        # Make sure we have a default value
                        $trans_data->{default} = $default // 'Unknown';
                    }
                }
            }
        }
    }
}

# Read in 'type' file
sub read_specs_file {
    my ( $dir ) = @_;
    no strict 'refs';

    # Define the file; make sure it exists and is readable
    my $specs_file = "$dir/specs";

    open FILE, "$specs_file"
        or do_log( "Failed to open $specs_file ($!), skipping this test.", ERROR )
        and return 0;

    # Define our applicable variables
    my %vars = ( 'vendor' => '', 'model' => '', sysdesc => '' );

    # Read in file
    while ( my $line = <FILE> ) {
        chomp $line;

        # Skip whitespace and comments
        next if $line =~ /^\s*(#.*)?$/;

        # Seperate variable and assigned value (colon delimited)
        my ( $var, $val ) = split /\s*:\s*/, $line, 2;
        $var = lc $var;

        # Make sure we got all our variables and they are non-blank and valid
        if ( !defined $val ) {
            do_log( "Undefined value in $specs_file at line $.", ERROR );
            next;
        } else {

            # Trim right (left done by split)
            do_log( "Trailing space(s) in $specs_file at line $.", WARN ) if $val =~ s/\s$//;
            if ( $val eq '' ) {
                do_log( "Missing spec value in $specs_file at line $.", ERROR );
                next;
            }
        }

        # Assign the value in our temp hash
        $vars{$var} = $val;
    }

    close FILE;

    # Make sure we got all our necessary vars
    for my $var ( keys %vars ) {
        my $val = $vars{$var};
        do_log( "'$var' not defined in $specs_file, skipping this test.", ERROR ) and return 0
            if !defined $val or $val eq '';
    }

    # Now return out anon hash ref
    my $vendor  = $vars{vendor};
    my $model   = $vars{model};
    my $sysdesc = $vars{sysdesc};
    return ( $vendor, $model, $sysdesc );
}

# Read in oids file
sub read_oids_file {
    my ( $dir, $tmpl ) = @_;

    # Define the file; make sure it exists and is readable
    my $oids_file = "$dir/oids";

    if ( !-e $oids_file ) {
        do_log( "Missing 'oids' file in $dir, skipping this test.", ERROR );
        return 0;    #
    } elsif ( ( defined $tmpl->{file}{$oids_file}{mtime} ) and ( stat( $oids_file ) )[9] == $tmpl->{file}{$oids_file}{mtime} ) {

        # File did not change so we do not need to reparse it
        $tmpl->{file}{$oids_file}{changed} = 0;
        return 1;
    }
    open FILE, "$oids_file"
        or do_log( "Failed to open $oids_file ($!), skipping this test.", ERROR )
        and return 0;
    delete $tmpl->{file}{$oids_file};
    $tmpl->{file}{$oids_file}{mtime} = ( stat( $oids_file ) )[9];
    do_log( "Parsing file $oids_file", TRACE ) if $g{debug};

    # Go through file, read in oids
    while ( my $line = <FILE> ) {
        chomp $line;

        # Skip whitespace and comments
        next if $line =~ /^\s*(#.*)?$/;

        my ( $oid, $number, $repeat ) = split /\s*:\s*/, $line, 3;

        # Make sure we got all our variables and they are non-blank and valid
        if ( !defined $number ) {
            do_log( "Missing colon separator near oid value in $oids_file at line $.", ERROR );
            next;
        } else {
            if ( $number eq '' ) {
                do_log( "Missing oid value in $oids_file at line $.", ERROR );
                next;
            }

            # TODO: We should valide also OID format and that the oid was not used before
        }
        if ( !defined $repeat ) {
            do_log( "Missing colon separator near repeater type in $oids_file at line $.", ERROR );
            next;
        } else {

            # Trim right (left done by split)
            do_log( "Trailing space(s) in $oids_file at line $.", ERROR ) if $repeat =~ s/\s$//;
            if ( $repeat eq '' ) {
                do_log( "Missing repeater type in $oids_file at line $.", ERROR );
                next;

                # Make sure repeater variable is valid
            } elsif ( $repeat !~ /^leaf$|^branch$/ ) {
                do_log( "Invalid repeater type '$repeat' for $oid in $oids_file", ERROR );
                next;
            }
        }

        # Make sure this oid hasnt been defined before
        do_log( "$oid defined more than once in $oids_file", ERROR ) and next
            if defined $tmpl->{new_oids}{$oid};

        # Make repeater variable boolean
        $repeat = ( $repeat eq 'branch' ) ? 1 : 0;

        # Remove leading dot from oid, if any
        $number =~ s/^\.//;

        # Assign variables to global hash
        $tmpl->{file}{$oids_file}{oids}{$oid}{number} = $number;
        $tmpl->{file}{$oids_file}{oids}{$oid}{repeat} = $repeat;

        # Mark template as non-empty
        $tmpl->{file}{$oids_file}{non_empty} = 1;
    }

    if ( exists $tmpl->{file}{$oids_file}{oids} ) {
        $tmpl->{new_oids} = dclone $tmpl->{file}{$oids_file}{oids};
        do_log( "$oids_file successfully parsed", TRACE );
    } else {
        do_log( "$oids_file is empty", WARN );
        return 0;
    }
    $tmpl->{file}{$oids_file}{changed} = 1;

    close FILE;
    return 1;
}

# Read in transforms file
sub read_transforms_file {
    my ( $dir, $tmpl ) = @_;

    # Define our valid transforms functions
    my %trans        = ();
    my $infls        = {};
    my $deps         = {};
    my $infls_thresh = {};
    my $deps_thresh  = {};
    my $path         = [];

    # Define the file; make sure it exists and is readable
    # Delete the global hash, too
    my $trans_file = "$dir/transforms";
    my $oids_file  = "$dir/oids";

    if ( !-e $trans_file ) {
        do_log( "Missing 'transforms' file in $dir, skipping this test.", ERROR );
        return 0;
    } elsif ( ( defined $tmpl->{file}{$trans_file}{mtime} ) and ( stat( $trans_file ) )[9] == $tmpl->{file}{$trans_file}{mtime} ) {

        # File did not change so we do not need to reparse it but check that if the 'oids file' was changed there are not redefined oids
        $tmpl->{file}{$trans_file}{changed} = 0;
        return 1;
    }
    open FILE, "$trans_file"
        or do_log( "Failed to open $trans_file ($!), skipping this test.", ERROR )
        and return 0;

    delete $tmpl->{file}{$trans_file};
    $tmpl->{file}{$trans_file}{mtime} = ( stat( $trans_file ) )[9];
    do_log( "Parsing file $trans_file", TRACE ) if $g{debug};

    # Go through file, read in oids
    my @text = <FILE>;
    close FILE;
    my $l_num = 0;

LINE: while ( my $line = shift @text ) {
        ++$l_num;
        my $adjust = 0;
        chomp $line;

        # Skip whitespace and comments
        next if $line =~ /^\s*(#.*)?$/;

        # Concatenate lines that have a continuation char \ at the end of the line,
        # remove \$ and adjust the current number of the line
        while ( $line =~ s/\s*\\$// ) {
            my $cont_line = shift @text;
            if ( defined $cont_line ) {
                chomp $cont_line;
                ++$adjust;
                $cont_line =~ s/^\s+//;
                $line .= $cont_line;
            } else {
                do_log( "The continuation char \ is not follow by a line $trans_file at line $l_num", ERROR );
            }
        }

        # Validate curly bracket
        my $curly_bracket = $line;
        $curly_bracket =~ s/\{([^{}\s]+)\}//g;
        do_log( "Curly brackets are not balanced/conform or contain space char in $trans_file at line $l_num", ERROR )
            and next
            if $curly_bracket =~ /{|}/;

        # Render oid & function
        my ( $oid, $func_type, $func_data ) = split /\s*:\s*/, $line, 3;

        # Make sure we got all our variables and they are non-blank and valid
        if ( !defined $func_type ) {
            do_log( "Missing colon separator near function type in $trans_file at line $l_num", ERROR );
            next;
        } else {
            if ( $func_type eq '' ) {
                do_log( "Missing function type in $trans_file at line $l_num", ERROR );
                next;
            }

            # TODO: We should valide format
        }
        if ( !defined $func_data ) {
            do_log( "Missing colon separator near function data in $trans_file at line $l_num", ERROR );
            next;
        } else {

            # Trim right (left done by split)
            do_log( "Trailing space(s) in $trans_file at line $l_num", WARN ) if $func_data =~ s/\s$//;
            if ( $func_data eq '' ) {
                do_log( "Missing function data in $trans_file at line $l_num", ERROR );
                next;
            }
        }

        # Make sure this oid hasnt been defined before
        # TODO: Would be nice to check that if it was defined
        # before, both oid are realy the same
        do_log( "Cant redefine $oid  in $trans_file", ERROR ) and next
            if defined $tmpl->{new_oids}{$oid};

        # Make sure function is a real one and that it is formatted correctly
        # 1. It is already trimed both sides
        # 2. Curly bracket are valid
        # 3. Empty space are not allow

        my $temp = $func_data;
        $func_type = lc $func_type;
    CASE: {
            $func_type eq 'best' and do {
                $temp =~ s/\{\S+\}|\s*,\s*//g;
                do_log( "BEST transform uses only comma-delimited oids at $trans_file, line $l_num", ERROR )
                    and next LINE
                    if $temp ne '';
                last CASE;
            };

            $func_type eq 'chain' and do {
                $temp =~ s/^\{\S+\}\s*\{\S+\}//;
                do_log( "CHAIN uses exactly two dependent oids at $trans_file, line $l_num", ERROR )
                    and next LINE
                    if $temp ne '';
                last CASE;
            };

            $func_type eq 'coltre' and do {
                $temp =~ s/^\{\S+\}\s*\{\S+?\}($|\s*:\s*\S+?$|\s*:\s*\S*?(|\s*,)\s*[rl]\d*[({].[)}])//;
                do_log( "COLTRE uses two dependent oids and optional arguments at $trans_file, line $l_num", ERROR )
                    and next LINE
                    if $temp ne '';
                last CASE;
            };

            $func_type eq 'convert' and do {
                $temp =~ s/^\{\S+\}\s+(hex|oct)(?:\s*\d*)//i;
                my ( $type ) = ( $1 );    #??
                do_log( "CONVERT transform uses only a single oid, a valid conversion type & an option pad length at $trans_file, line $l_num", ERROR )
                    and next LINE
                    if $temp ne '';
                last CASE;
            };

            $func_type eq 'date' and do {
                $temp =~ s/^\{\S+\}//;
                do_log( "DATE transform uses only a single oid at $trans_file, line $l_num", ERROR )
                    and next LINE
                    if $temp ne '';
                last CASE;
            };

            $func_type eq 'delta' and do {
                $temp =~ s/^\{\S+\}(?:$|\s+\d+$)//;
                do_log( "DELTA transform  only a single oid (plus an optional limit) at $trans_file, line $l_num", ERROR )
                    and next LINE
                    if $temp ne '';
                last CASE;
            };

            $func_type eq 'elapsed' and do {
                $temp =~ s/^\{\S+\}//;
                do_log( "ELAPSED transform uses only a single oid at $trans_file, line $l_num", ERROR )
                    and next LINE
                    if $temp ne '';
                last CASE;
            };

            $func_type eq 'sort' and do {
                $temp =~ s/^\{\S+\}//;
                do_log( "SORT transform uses only a single oid at $trans_file, line $l_num", ERROR )
                    and next LINE
                    if $temp ne '';
                last CASE;
            };

            $func_type eq 'index' and do {
                $temp =~ s/^\{\S+\}//;
                do_log( "INDEX transform uses only a single oid at $trans_file, line $l_num", ERROR )
                    and next LINE
                    if $temp ne '';
                last CASE;
            };

            $func_type eq 'match' and do {
                $temp =~ s/^\{\S+\}\s+\/.+\///;
                do_log( "MATCH transform should be a perl regex match at $trans_file, line $l_num", ERROR )
                    and next LINE
                    if $temp ne '';
                last CASE;
            };

            $func_type eq 'math' and do {
                $temp =~ s/:\s*\d+\s*$//;
                $temp =~ s/\{\S+\}|\s\.\s|\s+x\s+|\*|\+|\/|-|\^|%|\||&|<=?|>=?|!?=|or|and|\|\||$$|\d+(?:\.\d+)?|\(|\)//g;
                $temp =~ s/\s*//;
                do_log( "MATH transform uses only math/numeric symbols and an optional precision number, $temp did not pass, at $trans_file, line $l_num", ERROR )
                    and next LINE
                    unless $temp eq '';    # Check if temp is not empty
                                           #if $temp !~ /^\s*$/;
                last CASE;
            };

            $func_type eq 'pack' and do {
                $temp =~ s/^\{\S+\}\s+(\S+)(\s+.+)?//;
                my $type       = $1;
                my $validChars = 'aAbBcCdDfFhHiIjJlLnNsSvVuUwxZ';
                do_log( "PACK transform uses only a single oid,an encode type, and an optional seperator at $trans_file, line $l_num", ERROR )
                    and next LINE
                    if $temp ne '';
                do_log( "No encode type at $trans_file, line $l_num", ERROR )
                    and next LINE
                    if !defined $type;
                while ( $type =~ s/\((.+?)\)(\d+|\*)?// ) {
                    my $bit = $1;
                    do_log( "Bad encode type ($bit) at $trans_file, line $l_num", ERROR )
                        and next LINE
                        if $bit !~ /^([$validChars](\d+|\*)?)+$/i;
                }
                do_log( "Bad encode type ($type) at $trans_file, line $l_num", ERROR )
                    and next LINE
                    if $type ne ''
                    and $type !~ /^([$validChars](\d+|\*)?)+$/i;
                last CASE;
            };

            $func_type eq 'regsub' and do {
                $temp =~ s/^\{\S+\}\s*\/.+\/.*\/[eg]*//;
                do_log( "REGSUB transform should be a perl regex substitution at $trans_file, line $l_num", ERROR )
                    and next LINE
                    if $temp ne '';
                last CASE;
            };

            $func_type eq 'set' and do {
                my $pattern = qr/(\{[^}]*\}|\"[^\"]*\"|\d+(\.\d+)?([eE][+-]?\d+)?)(?=\s*,|\s*$)/;
                do_log( "SET transform requires a non-empty list of constant values at $trans_file, line $l_num", ERROR )
                    and next LINE
                    unless (
                    ( $temp =~ s/$pattern//g )      # Remove Patten
                    && ( $temp =~ s/\s*,\s*//g )    # Remove Comma
                    && ( $temp =~ /^\s*$/ )
                    );                              # Remove white space
                last CASE;
            };

            $func_type eq 'speed' and do {
                $temp =~ s/^\{\S+}//;
                do_log( "SPEED transform uses only a single oid at $trans_file, line $l_num", ERROR )
                    and next LINE
                    if $temp ne '';
                last CASE;
            };

            $func_type eq 'statistic' and do {
                $temp =~ s/^\{\S+\}\s+(?:avg|cnt|max|min|sum)//i;
                do_log( "STATISTIC transform uses only a single oid at $trans_file, line $l_num", ERROR )
                    and next LINE
                    if $temp ne '';
                last CASE;
            };

            $func_type eq 'substr' and do {
                $temp =~ s/^\{\S+\}\s+\d+(?:$|\s+\d+)//;
                do_log( "SUBSTR transform uses only a single oid, a numeric offset and an optional shift value at $trans_file, line $l_num", ERROR )
                    and next LINE
                    if $temp ne '';
                last CASE;
            };

            ( $func_type eq 'switch' or $func_type eq 'tswitch' ) and do {
                if ( $func_type eq 'tswitch' ) {
                    do_log( "'TSWITCH' is deprecated and should be replaced by 'SWITCH' transform in $trans_file at line $l_num", ERROR );
                    $func_type = 'switch';
                }
                $temp =~ s/^\{\S+\}\s*//;
                my $temp2 = '';
                for my $val ( split /\s*,\s*/, $temp ) {
                    my ( $if, $then );
                    ( $if, $then ) = ( $1, $2 ) if $val =~ s/^\s*(["'].*["'])\s*=\s*(.*?)\s*$//;
                    if ( !defined( $if ) ) {
                        ( $if, $then ) = ( $1, $2 ) if $val =~ s/^\s*([><]?.+?)\s*=\s*(.*?)\s*$//;
                    }
                    do_log( "Bad SWITCH value pair ($val) at $trans_file, line $l_num", ERROR )
                        and next
                        if !defined $if;
                    my $type;
                    if ( $if =~ /^=?\d+$/ ) {
                        $type = 'num';
                    } elsif ( $if =~ /^>\s*\d+(\.\d+)?$/ ) {
                        $type = 'gt';
                    } elsif ( $if =~ /^>=\s*\d+(\.\d+)?$/ ) {
                        $type = 'gte';
                    } elsif ( $if =~ /^<\s*\d+(\.\d+)?$/ ) {
                        $type = 'lt';
                    } elsif ( $if =~ /^<=\s*\d+(\.\d+)?$/ ) {
                        $type = 'lte';
                    } elsif ( $if =~ /^[+-]?\d+(\.\d+)?\s*-\s*\d+(\.\d+)?$/ ) {
                        $type = 'rng';
                    } elsif ( $if =~ /^'(.+)'$/ ) {
                        $type = 'str';
                    } elsif ( $if =~ /^"(.+)"$/ ) {
                        $type = 'reg';
                    } elsif ( $if =~ /^default$/i ) {
                        $type = 'default';
                    } else {
                        do_log( "Bad SWITCH case type ($if) at $trans_file, line $l_num", ERROR );
                        next;
                    }

                    $temp2 .= $val;
                }
                do_log( "SWITCH transform uses a comma delimited list of values in 'case = value' format at $trans_file, line $l_num", ERROR )
                    and next LINE
                    if $temp2 ne '';
                last CASE;
            };

            $func_type eq 'unpack' and do {
                $temp =~ s/^\{\S+\}\s+(\S+)(?:\s+.+)?//;
                my $type       = $1;
                my $validChars = 'aAbBcCdDfFhHiIjJlLnNsSvVuUwxZ';
                do_log( "UNPACK transform uses only a single oid,a decode type, and an optional seperator at $trans_file, line $l_num", ERROR )
                    and next LINE
                    if $temp ne '';
                do_log( "No decode type at $trans_file, line $l_num", ERROR )
                    and next LINE
                    if !defined $type;
                while ( $type =~ s/\((.+?)\)(\d+|\*)?// ) {
                    my $bit = $1;
                    do_log( "Bad decode type ($bit) at $trans_file, line $l_num", ERROR )
                        and next LINE
                        if $bit !~ /^([$validChars](\d+|\*)?)+$/i;
                }
                do_log( "Bad decode type ($type) at $trans_file, line $l_num", ERROR )
                    and next LINE
                    if $type ne ''
                    and $type !~ /^([$validChars](\d+|\*)?)+$/i;
                last CASE;
            };

            $func_type eq 'worst' and do {
                $temp =~ s/\{\S+\}|\s*,\s*//g;
                do_log( "WORST transform uses only comma-delimited oids at $trans_file, line $l_num", ERROR )
                    and next LINE
                    if $temp ne '';
                last CASE;
            };

            do_log( "Unknown function '$func_type' at $trans_file, line $l_num", ERROR );
            next LINE;
        }

        # Stick in our temporary hash
        $tmpl->{file}{$trans_file}{oids}{$oid}{trans_data} = $func_data;
        $tmpl->{file}{$trans_file}{oids}{$oid}{trans_type} = $func_type;

        # Adjust our line number if we had continuation character
        $l_num += $adjust;
    }
    $tmpl->{file}{$trans_file}{changed} = 1;
    return 1;
}

sub calc_template_test_deps {
    my ( $dir, $tmpl ) = @_;
    my $deps  = {};
    my $infls = {};
    my %trans_data;    #for sort from W. Nelis
    my $infls_thresh = {};

    my $oids_file   = "$dir/oids";
    my $trans_file  = "$dir/transforms";
    my $thresh_file = "$dir/thresholds";

    # Load oid from oid_file
    $tmpl->{new_oids} = dclone $tmpl->{file}{$oids_file}{oids} if defined $tmpl->{file}{$oids_file}{oids};

    # load oid from trans_file
    foreach my $oid ( keys %{ $tmpl->{file}{$trans_file}{oids} } ) {
        if ( exists $tmpl->{new_oids}{$oid} ) {
            do_log( "Attenpt to redefined $oid", ERROR );
            next;
        }
        $tmpl->{new_oids}{$oid} = dclone $tmpl->{file}{$trans_file}{oids}{$oid};
    }

    # load dep_oid from trans_file
    foreach my $oid ( keys %{ $tmpl->{new_oids} } ) {
        if ( ( exists $tmpl->{new_oids}{$oid}{trans_data} ) and ( $tmpl->{new_oids}{$oid}{trans_data} =~ /\{.+?\}/ ) ) {
            my $data = $tmpl->{new_oids}{$oid}{trans_data};
            while ( $data =~ s/\{(.+?)\}// ) {
                ( my $dep_oid, my $dep_oid_sub ) = split /\./, $1;    # add sub oid value (like var.color) as possible oid dependency
                                                                      # Validate oid
                if ( !defined $tmpl->{new_oids}{$dep_oid} ) {
                    do_log( "Undefined oid '$dep_oid' referenced in $trans_file", ERROR );
                    next;
                }

                # Create a direct dependency hash for each oid
                $tmpl->{new_oids}{$oid}{deps}{$dep_oid} = {};

                # Create influences (contrary of dependecies) hash for the topological sort
                $tmpl->{new_oids}{$dep_oid}{infls}{$oid} = {};

                # Create influences (contrary of dependecies) hash for global worst thresh calc
                if ( $tmpl->{new_oids}{$oid}{trans_type} =~ /^best$|worst/i ) {
                    $tmpl->{new_oids}{$dep_oid}{infls_thresh}{$oid} = {};
                }
            }
        }
    }

    # load oid from thresh_file
    foreach my $oid ( keys %{ $tmpl->{file}{$thresh_file}{oids} } ) {
        if ( exists $tmpl->{new_oids}{$oid} ) {

            # Validate any oids in the threshold and in the message
        COLOR: foreach my $color ( keys %{ $tmpl->{file}{$thresh_file}{oids}{$oid}{threshold} } ) {
                foreach my $thresh ( keys %{ $tmpl->{file}{$thresh_file}{oids}{$oid}{threshold}{$color} } ) {
                    my $tmp_threshold = $thresh;
                    while ( ( defined $tmp_threshold ) and ( $tmp_threshold =~ s/\{(.+?)\}// ) ) {
                        my $dep_oid = $1;
                        $dep_oid =~ s/\..+$//;    # Remove flag, if any
                        if ( defined $tmpl->{new_oids}{$dep_oid} ) {

                            # add it as a dependancy
                            $tmpl->{new_oids}{$oid}{deps}{$dep_oid}  = {};
                            $tmpl->{new_oids}{$dep_oid}{infls}{$oid} = {};
                        } else {
                            do_log( "Undefined oid '$dep_oid' referenced in $thresh_file ", ERROR );
                            next COLOR;
                        }
                    }
                    my $tmp_msg = $tmpl->{file}{$thresh_file}{oids}{$oid}{threshold}{$color}{$thresh};
                    while ( ( defined $tmp_msg ) and ( $tmp_msg =~ s/\{(.+?)\}// ) ) {
                        my $msg_oid = $1;
                        $msg_oid =~ s/\..+$//;
                        if ( !defined $tmpl->{new_oids}{$msg_oid} ) {
                            do_log( "Undefined oid '$msg_oid' referenced in $thresh_file ", ERROR );
                            next COLOR;
                        }
                    }
                    $tmpl->{new_oids}{$oid}{threshold}{$color}{$thresh} = $tmpl->{file}{$thresh_file}{oids}{$oid}{threshold}{$color}{$thresh};
                }
            }
        } else {
            do_log( "Undefined oid '$oid' referenced in $thresh_file", ERROR );
            next;
        }
    }
    foreach my $oid ( keys %{ $tmpl->{new_oids} } ) {
        $infls->{$oid}        = $tmpl->{new_oids}{$oid}{infls};
        $infls_thresh->{$oid} = $tmpl->{new_oids}{$oid}{infls_thresh};

        #$deps->{$oid}         = $tmpl->{new_oids}{$oid}{deps};
        #$trans_data{$oid}     = $tmpl->{new_oids}{$oid}{trans_data} if ( exists $tmpl->{new_oids}{$oid}{trans_data} )
    }

    # call the topological sort function to have ordered dependecies from W Nelis
    my $sorted_oids = sort_oids( \$infls, \%trans_data );
    if ( not @{$sorted_oids} ) {
        do_log( "Empty oids list", WARN );
        return 0;
    }

    # Add the results as a ref (the supported scalar type) so we can have an
    # array into the template hash of hash
    $tmpl->{sorted_oids} = $sorted_oids;
    $tmpl->{oids}        = dclone $tmpl->{new_oids};
    delete $tmpl->{new_oids};

    # For each oids in a test find all oids that depend on it and have it in
    # in a sorted liste (this is used for the worst_color calc in render_msg
    my %all_infls_thresh;
    for my $oid ( reverse( @{$sorted_oids} ) ) {

        for my $oid_infl ( keys %{ $infls_thresh->{$oid} } ) {
            if ( exists $all_infls_thresh{$oid_infl} ) {
                push @{ $all_infls_thresh{$oid} }, @{ $all_infls_thresh{$oid_infl} };
            } else {
                push @{ $all_infls_thresh{$oid} }, $oid_infl;
            }
            $tmpl->{oids}{$oid}{sorted_oids_thresh_infls} = $all_infls_thresh{$oid};
        }
    }
    return 1;
}

# Function sort-oid sorts the OIDs used in the transformations in a order
# in which they are to be calculated: each OID is sorted after the OIDs it
# depends on.
# At the same time, it checks the dependencies for any circular chains. If no
# such chain is found, this function returns a reference to the sorted list of
# OIDs. If at least one circular chain is found, the returned value is undef.
# This function uses the topological sort method.
#
sub sort_oids($) {
    my ( $infls_ref, $trans_data_ref ) = @_;
    my $infls      = $$infls_ref;
    my %trans_data = %$trans_data_ref;
    my @Sorted     = ();                 # Sorted list of OIDs
    my %Cnt        = ();                 # Dependency counters
    my ( $oid, $mods );                  # Loop control variables

    # Complete the list of OIDs to include those OIDs which do not depend
    # on another OID, like the SET transform. They have to be added for the
    # this algo to work : Commented as it seems not needed (but to be tested) !

    # Build table %Cnt. It specifies for each OID the number of other OIDs which
    # are needed to compute the OID.
    #
    foreach $oid ( keys %$infls ) {
        $Cnt{$oid} = 0 unless exists $Cnt{$oid};
        foreach ( keys %{ $$infls{$oid} } ) {
            $Cnt{$_} = 0 unless exists $Cnt{$_};
            $Cnt{$_}++;
        }    # of foreach
    }    # of foreach

    #
    # Sort the OIDs. If for a given OID no other OIDs are needed to compute its
    # value, move that OID to the sorted list and decrease the counts of each OID
    # which is computed using this OID. This process is repeated until no OIDs can
    # be moved any more. Any remaining OIDs, mentioned in %Cnt, must be in a
    # circular chain of dependencies.
    #
    $mods = 1;    # End-of-loop indicator
    while ( $mods > 0 ) {
        $mods = 0;    # Preset mod-count of this pass
        foreach $oid ( keys %Cnt ) {
            next unless $Cnt{$oid} == 0;
            if ( exists $$infls{$oid} ) {
                $Cnt{$_}-- foreach keys %{ $$infls{$oid} };
                $mods++;    # A counter is changed
            }    # of if
            push @Sorted, $oid;    # Move OID to sorted list
            delete $Cnt{$oid};
        }    # of foreach
    }    # of while

    if ( keys %Cnt ) {
        do_log( "The following OIDs are in one or more circular depency chains: " . join( ', ', sort keys %Cnt ), ERROR );
        return undef;    # Circular dependency chain found
    } else {
        return \@Sorted;    # No circular dependency chains found
    }    # of else
}

# Optimize dependency calculation more WIP
sub sort_oids2 {
    my ( $list_ref, $deps_ref, $infls_ref ) = @_;
    my @list  = @$list_ref;
    my $deps  = $$deps_ref;
    my $infls = $$infls_ref;
    my @temp_sorted_list;
    my @sorted_list;
    my @stack;
    my %treated;    # if exists then it is treated, parent info put in value
                    # to detect cycle (modify of the standard DFM algo)
    my %nb_deps;
    my %nb_infls;
    my $node;

    # Precompute number of deps
    foreach $node ( keys %{$deps} ) {    #Deprecated feature with perl 2.28 (RHEL 8)
        $nb_deps{$node}  = keys %{ $deps->{$node} };
        $nb_infls{$node} = keys %{ $infls->{$node} };
    }

NODE: foreach my $node ( @list ) {
        do_log( "stage1 Start with $node and list: @sorted_list" );
        if ( !exists $treated{$node} ) {

            do_log( "stage2 $node is not treated" );
            push @stack, $node;
            $treated{$node} = ();

            while ( @stack ) {

                my $stack = shift( @stack );
                do_log( "stage3 Unstack $stack, $nb_deps{$stack} dependencies" );

                foreach my $stack_dep ( keys %{ $deps->{$stack} } ) {
                    do_log( "stage4 Start with dependency $stack_dep" );

                    if ( !exists $treated{$stack_dep} ) {
                        do_log( "stage5 $stack_dep is not treated, put it on the stack" );
                        unshift @stack, $stack_dep;

                        # Modify version of the DFG algo to contain parent
                        $treated{$stack_dep} = $stack;
                    }
                }

                # I think I have to creat a tree with the depencies
                do_log( "stage6 $stack has $nb_infls{$stack} influences" );
                foreach my $stack_infl ( keys %{ $infls->{$stack} } ) {
                    do_log( "stage7 node $stack influences $stack_infl" );
                    $nb_deps{$stack_infl}--;
                    if ( exists $deps->{$stack_infl}{$stack} ) {
                        do_log( "stage8 decrement node $stack_infl" );
                        $nb_deps{$stack_infl}--;
                        if ( $nb_deps{$stack_infl} == 0 ) {
                            do_log( "stage9 $stack_infl has no more dependcies, put it on the sorted list" );
                            push @sorted_list, $stack_infl;
                        } elsif ( $nb_deps{$stack_infl} == -1 ) {
                            do_log( "Loop detected :@sorted_list $stack_infl" );
                        }
                    }
                }
            }
            do_log( "stage10 @sorted_list" );
        }
    }
    do_log( "stage11 @sorted_list" );
    return @sorted_list;
}

# Subroutine to read in the thresholds file
sub read_thresholds_file {
    my ( $dir, $tmpl ) = @_;

    # Define our valid transforms functions
    my %colors = ( 'red' => 1, 'yellow' => 1, 'green' => 1, 'clear' => 1, 'blue' => 1, 'purple', => 1 );

    # Define the file; make sure it exists and is readable
    # Delete the global hash, too
    my $thresh_file = "$dir/thresholds";

    if ( !-e $thresh_file ) {
        do_log( "Missing 'thresholds' file in $dir, skipping this test.", ERROR );
        return 0;

    } elsif ( ( defined $tmpl->{file}{$thresh_file}{mtime} ) and ( stat( $thresh_file ) )[9] == $tmpl->{file}{$thresh_file}{mtime} ) {

        # File did not change so we do not need to reparse it
        $tmpl->{file}{$thresh_file}{changed} = 0;
        return 1;
    }
    open FILE, "$thresh_file"
        or do_log( "Failed to open $thresh_file ($!), skipping this test.", ERROR )
        and return 0;

    delete $tmpl->{file}{$thresh_file};
    $tmpl->{file}{$thresh_file}{mtime} = ( stat( $thresh_file ) )[9];
    do_log( "Parsing file $thresh_file", TRACE ) if $g{debug};

    # Go through file, read in oids
    while ( my $line = <FILE> ) {
        chomp $line;

        # Skip whitespace and comments
        next if $line =~ /^\s*(#.*)?$/;

        # Validate curly bracket
        my $curly_bracket = $line;
        $curly_bracket =~ s/\{([^{}\s]+)\}//g;
        do_log( "Curly bracket error in $thresh_file at line $.", ERROR ) and next if $curly_bracket =~ /{|}/;

        # Render variables
        my ( $oid, $color, $threshes, $msg ) = split /\s*:\s*/, $line, 4;

        # Make sure we got all our variables and they are non-blank and valid
        if ( !defined $color ) {
            do_log( "Missing colon separator near color value in $thresh_file at line $.", ERROR );
            next;
        } else {
            if ( $color eq '' ) {
                do_log( "Missing color value in $thresh_file at line $.", ERROR );
                next;

                # Validate colors
            } elsif ( !defined $colors{$color} ) {
                do_log( "Invalid color value in $thresh_file at line $.", ERROR );
                next;
            }
        }
        if ( !defined $threshes or $threshes eq '' ) {

            # If a threshold is blank, it should automatch any value
            $threshes = "_AUTOMATCH_";
        }
        if ( !defined $msg ) {
            if ( !defined $threshes ) {

                # Trim right (left done by split)
                do_log( "Trailing space(s) in $thresh_file at line $.", WARN ) if $color =~ s/\s$//;
            } else {

                # Trim right (left done by split)
                do_log( "Trailing space(s) in $thresh_file at line $.", WARN ) if $threshes =~ s/\s$//;
            }
        } else {

            # Trim right (left done by split)
            do_log( "Trailing space(s) in $thresh_file at line $.", WARN ) if $msg =~ s/\s$//;
        }

        # Add the threshold to the global hash
        $tmpl->{file}{$thresh_file}{oids}{$oid}{threshold}{$color}{$threshes} = ( ( defined $msg ) and ( $msg ne '' ) ) ? $msg : undef;
        $tmpl->{new_oids}{$oid}{threshold} = dclone $tmpl->{file}{$thresh_file}{oids}{$oid}{threshold};

    }
    close FILE;

    if ( exists $tmpl->{file}{$thresh_file}{oids} ) {
        do_log( "$thresh_file successfully parsed", TRACE );
    } else {
        do_log( "$thresh_file is empty", TRACE );
    }
    $tmpl->{file}{$thresh_file}{changed} = 1;
    return 1;
}

# Subroutine to read in the exceptions file
sub read_exceptions_file {
    my ( $dir, $tmpl ) = @_;

    # Define our valid exception types
    my %excepts = (
        'ignore'  => 1,
        'only'    => 1,
        'noalarm' => 1,
        'alarm'   => 1
    );

    # Define the file; make sure it exists and is readable
    # Delete the global hash, too
    my $except_file = "$dir/exceptions";

    if ( !-e $except_file ) {
        do_log( "Missing 'exceptions' file in $dir, skipping this test.", ERROR );
        return 0;
    } elsif ( ( defined $tmpl->{file}{$except_file}{mtime} ) and ( stat( $except_file ) )[9] == $tmpl->{file}{$except_file}{mtime} ) {

        # File did not change so we do not need to reparse it
        $tmpl->{file}{$except_file}{changed} = 0;
        return 1;
    }

    open FILE, "$except_file"
        or do_log( "Failed to open $except_file ($!), skipping this test.", ERROR )
        and return 0;
    delete $tmpl->{file}{$except_file};
    $tmpl->{file}{$except_file}{mtime} = ( stat( $except_file ) )[9];
    do_log( "Parsing file $except_file", TRACE ) if $g{debug};

    # Go through file, read in oids
    while ( my $line = <FILE> ) {
        chomp $line;

        # Skip whitespace and comments
        next if $line =~ /^\s*(#.*)?$/;

        # Validate curly bracket
        my $curly_bracket = $line;
        $curly_bracket =~ s/\{([^{}\s]+)\}//g;
        do_log( "Curly bracket error in $except_file at line $.", ERROR ) and next if $curly_bracket =~ /{|}/;

        # Render variables
        my ( $oid, $type, $data ) = split /\s*:\s*/, $line, 3;

        # Make sure we got all our variables and they are non-blank
        if ( !defined $type ) {
            do_log( "Missing colon separator near exception type in $except_file at line $.", ERROR );
            next;
        } else {
            if ( $type eq '' ) {
                do_log( "Missing oid value in $except_file at line $.", ERROR );
                next;

                # Validate exception type
            } elsif ( !defined $excepts{$type} ) {
                do_log( "Invalid exception type '$type' for $oid in $except_file", ERROR );
                next;
            }
        }
        if ( !defined $data ) {
            do_log( "Missing colon separator near exception data in $except_file at line $.", ERROR );
            next;
        } else {

            # Trim right (left done by split)
            do_log( "Trailing space(s) in $except_file at line $.", WARN ) if $data =~ s/\s$//;
            if ( $data eq '' ) {
                do_log( "Missing exception data $except_file at line $.", ERROR );
                next;
            }
        }

        # Validate oid
        do_log( "Undefined oid '$oid' in $except_file at line $.", ERROR )
            and next
            if !defined $tmpl->{oids}{$oid};

        # Make sure we don't have an except defined twice
        do_log( "Exception for $oid redefined in $except_file at " . "line $.", ERROR ) and next
            if defined $tmpl->{oids}{$oid}{except}{$type};

        # Add the threshold to the global hash
        $tmpl->{oids}{$oid}{except}{$type} = $data;

    }
    if ( exists $tmpl->{file}{$except_file}{oid} ) {
        do_log( "$except_file successfully parsed", TRACE );
    } else {
        do_log( "$except_file is empty", TRACE );
    }

    close FILE;
    $tmpl->{file}{$except_file}{changed} = 1;
    return 1;
}

# Read in the message that will be sent to the xymon server
sub read_message_file {
    my ( $dir, $tmpl ) = @_;

    my $oid_tags = "color|msg|errors|thresh:(?:$color_list)";
    my $msg;

    # Define the file; make sure it exists and is readable
    # Delete the global hash, too
    my $msg_file = "$dir/message";

    if ( !-e $msg_file ) {
        do_log( "Missing 'message' file in $dir, skipping this test.", ERROR );
        return 0;
    } elsif ( ( defined $tmpl->{file}{$msg_file}{mtime} ) and ( stat( $msg_file ) )[9] == $tmpl->{file}{$msg_file}{mtime} ) {

        # File did not change so we do not need to reparse it
        $tmpl->{file}{$msg_file}{changed} = 0;
        return 1;
    }

    open FILE, "$msg_file"
        or do_log( "Failed to open $msg_file ($!), skipping this test.", ERROR )
        and return 0;
    delete $tmpl->{file}{$msg_file};
    $tmpl->{file}{$msg_file}{mtime} = ( stat( $msg_file ) )[9];
    do_log( "Parsing file $msg_file", TRACE );

    # Go through file, read in oids
    my $table_at = 0;
    my $header   = 0;
    for my $line ( <FILE> ) {

        # Skip comments
        next if $line =~ /^\s*#.*$/;

        # Add our line to our current message
        $msg .= $line;

        # Verify oids
        for my $oid ( $line =~ /\{(.+?)\}/g ) {

            # Remove tags
            $oid =~ s/.($oid_tags)$//;

            do_log( "Undefined oid '$oid' at line $. of $msg_file, skipping this test.", ERROR )
                and return
                if !defined $tmpl->{oids}{$oid};
        }

        # If we have seen a table header, try and read in the info
        if ( $table_at ) {

            # Skip whitespace
            next if $line =~ /^\s*$/;

            # Allow one line of header info
            if ( $line !~ /\{.+\}/ ) { $header = 1; next }

            # Complain if we havent found any oids yet
            do_log( "Table definition at line $table_at of $msg_file has no OIDs defined. Skipping this test.", ERROR )
                and return
                if $header
                and $line !~ /\{.+\}/;

            # Otherwise verify each oid in the table data
            for my $col ( split /\s*\|\s*/, $line ) {
                for my $oid ( $col =~ /\{(.+?)}/g ) {
                    $oid =~ s/\.($oid_tags)$//;
                    do_log( "Undefined oid '$oid' at line $. of $msg_file, skipping this test.", ERROR )
                        and return
                        if !defined $tmpl->{oids}{$oid};
                }
            }

            # Reset our indicators
            $table_at = $header = 0;
        }

        # If we found a table placeholder, validate its options, then make note
        # and skip to next line
        if ( $line =~ /^\s*(?:TABLE|NONHTMLTABLE):\s*(.*)/ ) {
            my $opts = $1;
            do_log( "NONHTMLTABLE tag used in $msg_file is deprecated, use the 'nonhtml' TABLE option instead.", WARN )
                and $line =~ s/NONHTMLTABLE/TABLE/
                if $1 eq 'NONHTMLTABLE';
            my %t_opts;

            for my $optval ( split /\s*,\s*/, $opts ) {
                my ( $opt, $val ) = ( $1, $2 ) if $optval =~ /(\w+)(?:\((.+)\))?/;
                $val = 1 if !defined $val;
                push @{ $t_opts{$opt} }, $val;
            }

            # Check our table options for validity
            for my $opt ( keys %t_opts ) {
                if (   $opt eq 'nonhtml'
                    or $opt eq 'plain'
                    or $opt eq 'sort'
                    or $opt eq 'border'
                    or $opt eq 'pad'
                    or $opt eq 'noalarmsmsg'
                    or $opt eq 'alarmsonbottom' )
                {
                } elsif ( $opt eq 'rrd' ) {
                    for my $rrd_opt ( @{ $t_opts{$opt} } ) {
                        my $got_ds = 0;
                        for my $sub_opt ( split /\s*;\s*/, $rrd_opt ) {
                            if ( lc $sub_opt eq 'all' ) {
                            } elsif ( lc $sub_opt eq 'dir' ) {
                            } elsif ( lc $sub_opt eq 'max' ) {
                            } elsif ( lc $sub_opt =~ /^name:(\S+)$/ ) {
                            } elsif ( lc $sub_opt =~ /^pri:(\S+)$/ ) {
                                do_log( "Undefined rrd oid '$1' at $msg_file line $.", ERROR )
                                    and return
                                    if !defined $tmpl->{oids}{$1};
                            } elsif ( $sub_opt =~ /^DS:(\S+)$/ ) {
                                my ( $ds, $oid, $type, $time, $min, $max ) = split /:/, $1;
                                do_log( "Invalid rrd ds name '$ds' at $msg_file line $.", ERROR )
                                    and return
                                    if defined $ds
                                    and $ds =~ /\W/;
                                do_log( "No RRD oid defined at $msg_file line $.", ERROR )
                                    and return
                                    if !defined $oid;
                                do_log( "Undefined rrd oid '$oid' at $msg_file line $.", ERROR )
                                    and return
                                    if !defined $tmpl->{oids}{$oid};
                                do_log( "Bad rrd datatype '$type' at $msg_file line $.", ERROR )
                                    and return
                                        if defined $type
                                    and $type ne ''
                                    and $type !~ /^(GAUGE|COUNTER|DERIVE|ABSOLUTE)$/;
                                do_log( "Bad rrd maxtime '$time' at $msg_file line $.", ERROR )
                                    and return
                                        if defined $time
                                    and $time ne ''
                                    and ( $time !~ /^\d+/ or $time < 1 );
                                do_log( "Bad rrd min value '$min' at $msg_file line $.", ERROR )
                                    and return
                                        if defined $min
                                    and $min ne ''
                                    and $min !~ /^[-+]?(\d+)$/;
                                do_log( "Bad rrd max value '$max' at $msg_file line $.", ERROR )
                                    and return
                                        if defined $max
                                    and $max ne ''
                                    and $max !~ /^([-+]?(\d+)|U$)/;
                                do_log( "Rrd max value > min value at $msg_file line $.", ERROR ) and return
                                    if (defined $min
                                    and $min ne ''
                                    and defined $max
                                    and $max ne ''
                                    and $max <= $min )
                                    or ( defined $max and $max ne '' and $max < 0 );
                                $got_ds = 1;
                            } else {
                                do_log( "Bad rrd option '$sub_opt' at $msg_file line $.", ERROR );
                                return;
                            }
                        }

                        do_log( "No dataset included for RRD at $msg_file line $.", ERROR )
                            and return
                            if !$got_ds;
                    }
                } else {
                    do_log( "Invalid option '$opt' for table at line $. in $msg_file", ERROR );
                    return;
                }
            }
            $table_at = $.;
        }
    }

    # Assign the msg
    $tmpl->{file}{$msg_file}{msg} = $msg;
    $tmpl->{msg} = $msg;

    close FILE;

    if ( ( defined $msg ) and ( $msg ne "" ) ) {
        do_log( "$msg_file successfully parsed", TRACE );
    } else {
        do_log( "$msg_file is empty", TRACE );
    }
    $tmpl->{file}{$msg_file}{changed} = 1;
    return 1;
}

# Sync the global db to our local template structure
sub sync_templates {
    my %index;
    my $model_id = 0;
    my $test_id  = 0;

    # Make sure we are in multinode mode
    die "--synctemplates flag only applies if you have the local 'MULTINODE'\n" . "option set to 'YES'\n"
        if $g{multinode} ne 'yes';

    # Read templates in from disk
    read_template_files();

    # Connect to the DB
    db_connect();

    # Erase our model index
    db_do( "delete from template_models" );

    # Erase our tests index
    db_do( "delete from template_tests" );

    # Erase our oids DB
    db_do( "delete from template_oids" );

    # Now erase our thresholds DB
    db_do( "delete from template_thresholds" );

    # Now erase our exceptions DB
    db_do( "delete from template_exceptions" );

    # Erase our messages DB
    db_do( "delete from template_messages" );

    # Create our template index
    for my $vendor ( sort keys %{ $g{templates} } ) {

        for my $model ( sort keys %{ $g{templates}{$vendor} } ) {

            # Increment our model index number
            ++$model_id;

            # Add our test index info
            my $sysdesc = $g{templates}{$vendor}{$model}{sysdesc};

            # Make the sysdesc mysql-safe
            db_do( "insert into template_models values ($model_id, '$vendor','$model','$sysdesc')" );

            # Now go through all our tests and add them
            for my $test ( sort keys %{ $g{templates}{$vendor}{$model}{tests} } ) {

                # Increment our test index number
                ++$test_id;

                # Add our test index info
                db_do( "insert into template_tests values ($test_id, $model_id,'$test')" );

                # Template shortcut
                my $tmpl = \%{ $g{templates}{$vendor}{$model}{tests}{$test} };

                # Insert our oids into the DB
                for my $oid ( keys %{ $tmpl->{oids} } ) {

                    # Prepare our data for insert
                    my $number = $tmpl->{oids}{$oid}{number};
                    my $repeat = $tmpl->{oids}{$oid}{repeat};
                    my $t_type = $tmpl->{oids}{$oid}{trans_type};
                    my $t_data = $tmpl->{oids}{$oid}{trans_data};
                    $number = ( defined $number ) ? "'$number'" : 'NULL';
                    $repeat = ( defined $repeat ) ? "'$repeat'" : 'NULL';
                    $t_type = ( defined $t_type ) ? "'$t_type'" : 'NULL';
                    $t_data = ( defined $t_data ) ? "'$t_data'" : 'NULL';

                    # Insert our oids into DB
                    db_do( "insert into template_oids values " . "($test_id, '$oid', $number, $repeat, $t_type, $t_data)" );

                    # Insert our thresholds into the DB
                    for my $color ( keys %{ $tmpl->{oids}{$oid}{thresh} } ) {

                        # Prepare our data for insert
                        for my $threshes ( keys %{ $tmpl->{oids}{$oid}{thresh}{$color} } ) {
                            my $msg = $tmpl->{oids}{$oid}{thresh}{$color}{$threshes}{msg};
                            $msg = ( defined $msg ) ? "'$msg'" : 'NULL';

                            # Insert our thresholds into DB
                            db_do( "insert into template_thresholds values " . "($test_id,'$oid','$color','$threshes',$msg)" );
                        }
                    }

                    # Insert our exceptions into the DB
                    for my $type ( keys %{ $tmpl->{oids}{$oid}{except} } ) {

                        # Prepare our data for insert
                        my $data = $tmpl->{oids}{$oid}{except}{$type};

                        # Insert our thresholds into DB
                        db_do( "insert into template_exceptions values " . "($test_id,'$oid','$type','$data')" );
                    }

                }    # End of for my $oid

                # Now insert our messages into the DB
                my $msg = $tmpl->{msg};

                # Convert newlines into placeholders
                $msg =~ s/\\n/~~n/;
                $msg =~ s/\n/\\n/;

                db_do( "insert into template_messages values ($test_id, '$msg')" );
            }
        }
    }

    # Update our nodes DB to let all nodes know to reload template data
    db_do( "update nodes set read_temps='y'" );

    # Now quit
    do_log( "Template synchronization complete", INFO );
    exit 0;
}
