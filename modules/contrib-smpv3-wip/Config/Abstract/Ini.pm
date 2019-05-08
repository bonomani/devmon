package Config::Abstract::Ini;

use 5.006;
use strict;
use warnings;

require Exporter;
use Config::Abstract;

use overload qw{""} => \&_to_string;

our @ISA = qw(Config::Abstract Exporter);
our %EXPORT_TAGS = ( 'all' => [ qw( ) ] );
our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );
our @EXPORT = qw( );

our $VERSION = '0.13';

#
# ------------------------------------------------------------------------------------------------------- structural methods -----
#

# All inherited from Config::Abstract

#
# --------------------------------------------------------------------------------------------------------- accessor methods -----
#

# All inherited from Config::Abstract

#
# ------------------------------------------------------------------------------------------------ (un)serialisation methods -----
#

##################################################
#%name: _to_string
#%syntax: _to_string
#%summary: Recursively generates a string representation of the settings hash
#%returns: a string in .ini format 

sub _to_string{
	my($self) = @_;
	return $self->_dumpobject('',$self->{_settings});
}

##################################################
#%name: _dumpobject
#%syntax: _dumpobject(<$objectcaption>,<$objectref>,[<@parentobjectcaptions>])
#%summary: Recursively generates a string representation of the object referenced
#          by $objectref
#%returns: a string representation of the object

sub _dumpobject{
	my($self,$name,$obj,@parents) = @_;
	my @result = ();
	if(ref($obj) eq 'HASH'){
		unless($name eq ''){
			push(@parents,"$name");
			push(@result,'[' . join('::',@parents) . ']');
		}
		while(my($key,$val) = each(%{$obj})){
			push(@result,$self->_dumpobject($key,$val,@parents));
		}
	}elsif(ref($obj) eq 'SCALAR'){
		push(@result,"$name = ${$obj}");
	}elsif(ref($obj) eq 'ARRAY'){
		push(@parents,"$name");
		push(@result,'[' . join('::',@parents) . ']');
		for(my $i = 0;scalar(@{$obj});$i++){
			push(@result,$self->_dumpobject($i,${$obj}[$i],@parents));
		}
	}else{
#		print("Why are we here? name: " . ( defined($name) ? $name : 'empty' ) . " obj:" . ( defined($obj) ? $obj : 'empty' ) . "\n");#DEBUG!!!
		push(@result,"$name = " . (defined($obj) ? $obj : '') ) unless(!defined($name));
	}
	return(join("\n",@result));
}


##################################################
#%name: _parse_settings_file
#%syntax: _parse_settings_file(<@settings>)
#%summary: Reads the projects to keep track of
#%returns: a hash of $projectkey:$projectlabel

sub _parse_settings_file{
	my %result = ();
	my ($entry,$subentry) = ('',undef);
	chomp(@_);
	foreach(@_){
		# Get rid of starting/ending whitespace
		s/^\s*(.*)\s*$/$1/;
		
		#Delete comments
		($_) = split(/[;#]/,$_);
		#Skip if there's no data
		next if((! defined($_)) || $_ eq '');
		/^\s*(.*?)\s*=\s*(['"]|)(.*)\2\s*/ && do {	
			my($key,$val) = ($1,$3);
			next if($key eq '' || $val eq '');
			if(! defined($subentry) || $subentry =~ /^\s*$/){
				${$result{$entry}}{$key} = $val;
			}else{
				${$result{$entry}}{$subentry}{$key} = $val;
			}
			next;
		};
		# Select a new entry if this is such a line
		/\[(.*?)\]/ && do{
			
			$_ = $1;
			($entry,$subentry) = split('::');
			if(! defined($subentry) || $subentry =~ /^\s*$/){
				$result{$entry} = {};
			}elsif($result{$entry}){
				$result{$entry}{$subentry} = {};
			}
			next;
		};
	}
	return(\%result);
}

# We provide a DESTROY method so that the autoloader
# doesn't bother trying to find it.
sub DESTROY { }

# Autoload methods go after =cut, and are processed by the autosplit program.

1;
__END__
=head1 NAME

Config::Abstract::Ini - Perl extension for handling ini style files

=head1 SYNOPSIS

 use Config::Abstract::Ini;
 my $ini = new Config::Abstract::Ini('testdata.ini');

=head1 DESCRIPTION

 Have you ever wanted an easy to use interface to your own
 config files, but ended up doing 'require  mysettings.pl'
 because you couldn't be bothered?  Config::Abstract::Ini solves
 that  for  you, giving you an object in  exchange for the
 name of your settings file.
 
 For compatibility with other config file formats, Ini can
 understand  hierarchical ini files using double colons as
 delimiters.  Just make sure you don't create name clashes
 by assigning both a value and a subentry to the same name
 in the file. This is currently supported for one sublevel
 only, which will have to be improved in future releases.

=head1 EXAMPLES

 We assume the content of the file 'testdata.ini' to be:
 [myentry]
 ;comment
 thisssetting = that
 thatsetting=this
 ;end of ini
 
 
 use Config::Abstract::Ini;
 my $settingsfile = 'testdata.ini';
 my $settings = new Config::Abstract::Ini($Settingsfile);
 
 # Get all settings
 my %allsettings = $settings->get_all_settings;
 
 # Get a subsection (called an entry here, but it's 
 # whatever's beneath a [section] header)
 my %entry = $settings->get_entry('myentry');
 
 # Get a specific setting from an entry
 my $value = $settings->get_entry_setting('myentry',
                                          'thissetting');

 # Get a specific setting from an entry, giving a default
 # to fall back on
 my value = $settings->get_entry_setting('myentry',
                                         'missingsetting',
                                         'defaultvalue');
 We can also make use of subentries, with a ini file like
 this:

 [book]
 title=A book of chapters
 author=Me, Myself and Irene

 [book::chapter1]
 title=The First Chapter, ever
 file=book/chapter1.txt

 [book::chapter2]
 title=The Next Chapter, after the First Chapter, ever
 file=book/chapter2.txt
 # btw, you can use unix style comments, too...
 ;end of ini

 use Config::Abstract::Ini;
 my $settingsfile = 'test2.ini';
 my $ini = new Config::Abstract::Ini($Settingsfile);
 
 my %book = $ini->get_entry('book');
 my %chap1 = $ini->get_entry_setting('book','chapter1');
 my $chap1title = $chapter1{'title'};
 
 # Want to see the inifile?
 # If you can live without comments and blank lines ;),
 # try this:
 print("My inifile looks like this:\n$ini\nCool, huh?\n");

=head1 METHODS

=item get_all_settings

Returns a hash of all settings found in the processed file

=item get_entry ENTRYNAME

Returns a hash of the settings within the entry ENTRYNAME

=item get_entry_setting ENTRYNAME,SETTINGNAME [,DEFAULTVALUE]

Returns the value corresponding to ENTRYNAME,SETTINGSNAME. If the value isn't set it returns undef or, optionally, the DEFAULTVALUE

=item set_all_settings SETTINGSHASH

Fill settings with data from SETTINGSHASH

=item set_entry ENTRYNAME,ENTRYHASH

Fill the entry ENTRYNAME with data from ENTRYHASH

=item set_entry_setting ENTRYNAME,SETTINGNAME,VALUE

Set the setting ENTRYNAME,SETTINGSNAME to VALUE

=head1 BUGS

* Comments have to be on their own lines, end of line comments won't work properly
* Serialisation does not take original line ordering into consideration, so comments may end up far from what they're supposed to document

=head1 COPYRIGHT

Copyright (c) 2003 Eddie Olsson. All rights reserved.

 This library is free software; you can redistribute it
 and/or modify it under the same terms as Perl itself.


=head1 AUTHOR

Eddie Olsson <ewt@avajadi.org>

=head1 SEE ALSO

L<perl>.

=cut
