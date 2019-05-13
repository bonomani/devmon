package Config::Abstract;

use 5.006;
use strict;
use warnings;

use Data::Dumper;

require Exporter;
#use AutoLoader qw(AUTOLOAD);

use overload qw{""} => \&_to_string;

our @ISA = qw(Exporter);
our %EXPORT_TAGS = ( 'all' => [ qw( ) ] );
our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );
our @EXPORT = qw( );

our $VERSION = '0.13';

#
# ------------------------------------------------------------------------------------------------------- structural methods -----
#

sub new {
    my($class,$initialiser) = @_;
    my $self = {
		_settings => undef,
		_settingsfile => undef
	};
    bless $self,ref $class || $class;
    $self->init($initialiser);
    return $self;
}

sub init {
	my($self,$settingsfile) = @_;
	return unless(defined($settingsfile));
	return if($settingsfile eq '');
	$self->{_settings} = $self->_read_settings($settingsfile);
	$self->{_settingsfile} = $settingsfile;
}


#
# --------------------------------------------------------------------------------------------------------- accessor methods -----
#

sub get_all_settings {
	my($self) = @_;
	# Make sure we don't crash and burn trying to return a hash from an undef reference
	return undef unless(defined($self->{_settings}));
	# Return the settings as a hash in array contect and a hash reference in scalar context
	if(wantarray){
		return %{$self->{_settings}};
	}else{
		return $self->{_settings};
	}
}

sub get_entry {
	my($self,$entryname) = @_;
	my $val;
	if($entryname =~ m|//|){
		# Getting an entry by path
		my $unpathed = $self->_unpath($entryname);
		eval("\$val = \"\${ \$self->{_settings} }$unpathed\";");
#		print("\$val = '\${ \$self->{_settings} }$unpathed ';\n");#DEBUG!!!
#		print("\$val: $val\n");#DEBUG!!!
	}else{
		$val = ${$self->{_settings}}{$entryname};
	}
	if(defined($val)){
		if(wantarray && ref($val) eq 'HASH'){
#			print STDERR ("Returning HASH in $self" . "->get_entry($entryname)\n");#DEBUG!!!
			return(%{$val});
		}else{
#			print STDERR ("Returning ref in $self" . "->get_entry($entryname)\n");#DEBUG!!!
			return($val);
		}
	}else{
		return undef;
	}
}

sub get_entry_setting {
	my($self,$entryname,$settingname,$default) = @_;
	# Return undef if the requested entry doesn't exist
	my %entry = ();
	return(undef) unless(%entry = $self->get_entry($entryname));
	if(defined($entry{$settingname})){
		return $entry{$settingname};
	}else{
		return $default;
	}
}

sub get {
	my($self,$section,$key,$default) = @_;
	# If everything up to the key is given, get a specific key
	return $self->get_entry_setting($section,$key,$default) if(defined($key));
	# If section is given, but not key, get a specific section
	return $self->get_entry($section) if(defined($section));
	# If no parameter is given, return the entire hash
	return $self->get_all_settings();
}

#
# ---------------------------------------------------------------------------------------------------------- mutator methods -----
#

sub set_all_settings {
	my($self,%allsettings) = @_;
	return %{$self->{_settings}} = %allsettings;
}

sub set_entry {
	my($self,$entryname,$entry) = @_;
	my $unpathed = $self->_unpath($entryname);
	my $val;
	eval('${$self->{_settings}}' . $unpathed . ' = $entry;');
	return $self->get_entry($entryname) ;
}

sub set_entry_setting {
	my($self,$entryname,$settingname,$setting) = @_;
	return (${${$self->{_settings}}{$entryname}}{$settingname} = $setting);
}

sub set {
	my($self,$section,$key,$value) = @_;
	# If everything up to the key is given, set a specific key
	return $self->set_entry_setting($section,$key,$value) if(defined($value));
	# If section is given, but not key, set a specific section
	return $self->set_entry($section,$key) if(defined($key));
	# If no parameter is given, return the entire hash
	return $self->set_all_settings(%{$section});
}

sub exists {
	my($self,$section,$key) = @_;
	return defined($self->{$section}) unless (defined($key));
	return defined($self->{$section}{$key});
}

sub get_entry_names {
	my($self) = @_;
	return sort(keys(%{$self->{_settings}}));
}

#
# ------------------------------------------------------------------------------------------------------- arithmetic methods -----
#

##################################################
#%name: diff
#%syntax: diff($other_config_object)
#%summary: Generates an object with overrides for entries that can be used to patch $self into $other_config_object
#%returns: a Config::Abstract object
#%NB: This method is nowhere near working atm /EWT
sub diff {
	my($self,$diff) = @_;
	my %self_pathed = $self->_pathalise_object( '',$self->{_settings} );
	my %diff_pathed = $self->_pathalise_object( '',$diff->{_settings} );
	my $result = $self->new();
	while( my($k,$v) = each(%diff_pathed) ) {
		next if( defined($self_pathed{$k}) && $self_pathed{$k} eq $v);
		$result->set($k,$v);
	}
	return $result;
}


##################################################
#%name: patch
#%syntax: patch($patch_from_other_config_object)
#%summary: Overrides all settings that are found in the $patch object with the $patch values
#%returns: Nothing
sub patch {
	my($self,$patch) = @_;
	my %patch_pathed = $self->_pathalise_object( '',$patch->{_settings} );
	while( my($k,$v) = each(%patch_pathed) ) {
		$self->set($k,$v);
	}
}



sub _unpath {
	my($self,$path) = @_;
	$path =~ s|^/+|{'|;
	$path =~ s|/+|'}{'|g;
	$path .= '\'}';
	return $path;
}
##################################################
#%name: _pathalise_object
#%syntax: _dumpobject(<$objectcaption>,<$objectref>,[<@parentobjectcaptions>])
#%summary: Recursively generates a string representation of the object referenced
#          by $objectref
#%returns: a string representation of the object

sub _pathalise_object{
	my($self,$name,$obj,@parents) = @_;
	my @result = ();
	if(ref($obj) eq 'HASH'){
		unless($name eq '' ){
			push(@parents,$name);
		}
		while(my($key,$val) = each(%{$obj})){
			push(@result,$self->_pathalise_object($key,$val,@parents));
		}
	}elsif(ref($obj) eq 'SCALAR'){
		push(@result,'//' . join('//',@parents) . "//$name",${$obj});
	}elsif(ref($obj) eq 'ARRAY'){
		push(@parents,$name);
		for(my $i = 0;scalar(@{$obj});$i++){
			push(@result,$self->_pathalise_object($i,${$obj}[$i],@parents));
		}
	}else{
		push(@result,'//' . join('//',@parents) . "//$name",$obj);
	}
	return @result;
}
#
# ------------------------------------------------------------------------------------------------ (de)serialisation methods -----
#

##################################################
#%name: _to_string
#%syntax: _to_string
#%summary: Recursively generates a string representation of the settings hash
#%returns: a string in perl source format

sub _to_string{
	my($self) = @_;
	return $self->_dumpobject();
}

##################################################
#%name: _dumpobject
#%syntax: _dumpobject(<$objectcaption>,<$objectref>,[<@parentobjectcaptions>])
#%summary: Generates a string representation of the object referenced
#          by $objectref
#%returns: a string representation of the object

sub _dumpobject{
	my($self) = @_;
	my $dumper = Data::Dumper->new([$self->{_settings}],[qw(settings)]);
	$dumper->Purity(1);
	return($dumper->Dump());
}

##################################################
#%name: _read_settings
#%syntax: _read_settings(<$settingsfilename>)
#%summary: Reads the key-values to keep track of
#%returns: a reference to a hash of $key:$value

sub _read_settings{
	my ($self,$settingdata) = @_;
	my @conflines;
	if(ref($settingdata) eq 'ARRAY'){
		@conflines = @{$settingdata};
	}else{
		my $settingsfile = $settingdata;
		# Read in the ini file we want to use
		# Probably not a good idea to die on error at this
		# point, but that's what we've got for the moment
		open(SETTINGS,$settingsfile) || die("Failed to open ini file ($settingsfile) for reading\n");
		@conflines = <SETTINGS>;
		close(SETTINGS);
	}
	my $settings = $self->_parse_settings_file(@conflines);
	return($settings);
}

##################################################
#%name: _parse_settings_file
#%syntax: _parse_settings_file(<@settings>)
#%summary: Reads the key-values into a hash
#%returns: a reference to a hash of $key:$value

sub _parse_settings_file{
	my $settings = {};
	eval(join(''.@_));
	return($settings);
}

#
# ---------------------------------------------------------------------------------------------------------- utility methods -----
#


sub expand_tilde {
	defined($ENV{'HOME'}) && do {
		$_[0] =~ s/^~/$ENV{'HOME'}/;
	};
	return $_[0];
}


# We provide a DESTROY method so that the autoloader
# doesn't bother trying to find it.
sub DESTROY {
	print STDERR ("Destroying Config::Abstract\n"); #DEBUG!!!
}

1;
__END__
=head1 NAME

Config::Abstract - Perl extension for abstracting configuration files

=head1 SYNOPSIS

 use Config::Abstract;
 my $ini = new Config::Abstract('testdata.pl');

=head1 DESCRIPTION

 Config::Abstract is the base  class for a  number of  other classes
 created to facilitate use and  handling of a  variety of  different
 configuration file formats. It uses the Data::Dumper file format to
 serialise it self and can be initialise from a file of that  format

=head1 EXAMPLES

 We assume the content of the file 'testdata.pl' to be:

  $settings = {
    'book' => {
      'chapter1' => {
        'title' => 'The First Chapter, ever',
        'file' => 'book/chapter1.txt'
      },
      'title' => 'A book of chapters',
      'chapter2' => {
        'title' => 'The Next Chapter, after the First Chapter, ever',
        'file' => 'book/chapter2.txt'
      },
      'author' => 'Me, Myself and Irene'
    }
  };

 use Config::Abstract;
 my $settingsfile = 'testdata.pl';
 my $abstract = new Config::Abstract($settingsfile);

 my %book = $abstract->get_entry('book');
 my %chap1 = $abstract->get_entry_setting('book','chapter1');
 my $chap1title = $chapter1{'title'};

 # Want to see the file?
 # If you can live without comments and blank lines ;),
 # try this:
 print("My abstract file looks like this:\n$abstract\nCool, huh?\n");

 # We can also create an ini file from it
 # A bit crude, but it does the job
 bless($abstract,'Config::Abstract::Ini');
 print($abstract);

=head1 METHODS

=item get_all_settings

Returns a hash of all settings found in the processed file

=item get ENTRYPATH

Returns the setting at the given 'path' where the path divider is '//'.

=item get_entry ENTRYNAME

Returns a hash of the settings within the entry ENTRYNAME. OBSOLETE, use get instead

=item get_entry_setting ENTRYNAME,SETTINGNAME [,DEFAULTVALUE]

Returns the value corresponding to ENTRYNAME,SETTINGSNAME. If the value isn't set it returns undef or, optionally, the DEFAULTVALUE. OBSOLETE, use get instead

=item set_all_settings SETTINGSHASH

Fill settings with data from SETTINGSHASH

=item set ENTRYPATH VALUE

Setting the entry at the given 'path', where the path divider is '//', to VALUE.

=item set_entry ENTRYNAME,ENTRYHASH

Fill the entry ENTRYNAME with data from ENTRYHASH

=item set_entry_setting ENTRYNAME,SETTINGNAME,VALUE

Set the setting ENTRYNAME,SETTINGSNAME to VALUE

=item diff OBJECT

Returns an object of type Config::Abstract that is a representation of the values in this object that needs altering to make it identical to OBJECT

=item patch OBJECT

Sets the entries in this object to whatever they are in OBJECT, creating entries as necessary. $obj_a->patch( $obj_a->diff( $obj_b ) ); should make $obj_a identical to $obj_b except for entries in obj_a that don't exist in $obj_b.

=head1 COPYRIGHT

Copyright (c) 2003 Eddie Olsson. All rights reserved.

 This library is free software; you can redistribute it
 and/or modify it under the same terms as Perl itself.


=head1 AUTHOR

Eddie Olsson <ewt@avajadi.org>

=head1 SEE ALSO

L<perl>.

=cut
