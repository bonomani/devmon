#!/usr/bin/perl

use strict;
use warnings;
use Data::Dumper;
use File::Path qw(make_path);
use Cwd qw(abs_path);
use HTTP::Tiny;

our $min_perl_version = 5.014;    # Minimum required Perl version
our $os_distribution;
our $package_manager;
our $silent_config = 0;

our %config_old;
our %config_new;
my $nesting_level      = 0;
my $indentation_spaces = 1;       # Adjust this value as needed

our $level_last_indentation = 0;
our $is_indented            = 0;

my @math_functions
    = qw(abs exp sqrt sin cos tan csc sec cot arcsin arccos arctan arccsc arcsec arccot sinh cosh tanh csch sech coth);
my @math_symbols            = qw(pi e);
my @perl_word_operators     = qw(and or not);
my @excluded_variable_names = (@math_functions, @math_symbols, @perl_word_operators);

my $debug = 1;

# Define package names for SNMP_Session and Net-SNMP module
our %package = (
    "SNMP_Session" => {
        debian  => "libsnmp-session-perl",
        ubuntu  => "libsnmp-session-perl",
        freebsd => "perl-SNMP_Session",
        openbsd => "perl-SNMP_Session",
        netbsd  => "perl-SNMP_Session",
        arch    => "perl-SNMP_Session",
        gentoo  => "net-analyzer/SNMP_Session",
        default => "perl-SNMP_Session.noarch",    # Best default entry
    },
    "SNMP utilities" => {
        debian  => "snmp",
        ubuntu  => "snmp",
        freebsd => "net-snmp",
        openbsd => "net-snmp",
        netbsd  => "net-snmp",
        arch    => "net-snmp",
        gentoo  => "net-analyzer/net-snmp",
        default => "net-snmp net-snmp-devel net-snmp-utils",    # Best default entry
    },
    git => {
        gentoo  => "dev-vcs/git",
        default => "git",                                       # Best default entry
    },
    "IO::Socket::SSL" => {
        debian => 'libio-socket-ssl-perl',
    },
    "openssl-devel" => {
        debian => 'libssl-dev',
    },
    "curl" => {
        default => 'curl',
    },

);

# Define distribution files
our %distribution_files = (
    debian      => ['/etc/debian_version'],
    ubuntu      => ['/etc/ubuntu-advantage', '/etc/debian_version'],
    rhel        => ['/etc/redhat-release'],
    centos      => ['/etc/centos-release'],
    oracle      => ['/etc/oracle-release'],
    fedora      => ['/etc/fedora-release'],
    arch        => ['/etc/arch-release'],
    gentoo      => ['/etc/gentoo-release'],
    suse        => ['/etc/SuSE-release', '/etc/SUSE-brand'],
    almalinux   => ['/etc/almalinux-release'],
    rocky       => ['/etc/rocky-release'],
    olinux      => ['/etc/olinux-release'],
    vine        => ['/etc/vine-release'],
    vyatta      => ['/etc/vyatta-release'],
    bluewhite64 => ['/etc/bluewhite64-version'],
    freebsd     => ['/etc/freebsd-update.conf'],
    openbsd     => ['/etc/installurl'],
    netbsd      => ['/etc/pkg_install.conf'],
);

# Define alternative package managers
our %alternative_package_managers = (
    debian      => ['apt', 'apt-get', 'dpkg', 'aptitude'],
    ubuntu      => ['apt', 'apt-get', 'dpkg', 'aptitude'],
    fedora      => ['dnf', 'yum',     'rpm'],
    rhel        => ['dnf', 'yum',     'rpm'],
    almalinux   => ['dnf', 'yum',     'rpm'],
    rocky       => ['dnf', 'yum',     'rpm'],
    olinux      => ['dnf', 'yum',     'rpm'],
    arch        => ['pacman'],
    gentoo      => ['emerge'],
    suse        => ['zypper'],
    vine        => ['zypper'],
    vyatta      => ['zypper'],
    freebsd     => ['pkg', 'pkg_add', 'pkg_info'],
    openbsd     => ['pkg', 'pkg_add', 'pkg_info'],
    netbsd      => ['pkg', 'pkg_add', 'pkg_info'],
    netbsd      => ['pkg', 'pkg_add', 'pkg_info'],
    bluewhite64 => ['zypper']
);

# Define search installed templates
our %search_installed_templates = (
    apt       => 'apt list --installed %s 2>&1',
    'apt-get' => 'apt-get list --installed %s 2>&1',
    dpkg      => 'dpkg -s %s 2>&1',
    aptitude  => 'aptitude search ~i %s 2>&1',
    dnf       => 'dnf -q list installed %s 2>&1',
    yum       => 'yum list installed %s 2>&1',
    rpm       => 'rpm -q %s 2>&1',
    pacman    => 'pacman -Qq %s 2>&1',
    emerge    => 'emerge --search --package %s 2>&1',
    zypper    => 'zypper search --installed-only %s 2>&1',
    pkg       => 'pkg info %s 2>&1',
    pkg_add   => 'pkg_add %s 2>&1',
    pkg_info  => 'pkg_info %s 2>&1',
);

# Define installation templates
our %install_templates = (
    apt       => 'apt install -y %s 2>&1',
    'apt-get' => 'apt-get install -y %s 2>&1',
    dpkg      => 'dpkg -i %s 2>&1',
    aptitude  => 'aptitude install -y %s 2>&1',
    dnf       => 'dnf install -y %s 2>&1',
    yum       => 'yum install -y %s 2>&1',
    rpm       => 'rpm -i %s 2>&1',
    pacman    => 'pacman -S --noconfirm %s 2>&1',
    emerge    => 'emerge %s 2>&1',
    zypper    => 'zypper install -y %s 2>&1',
    pkg       => 'pkg install -y %s 2>&1',
    pkg_add   => 'pkg_add %s 2>&1',
    pkg_info  => 'pkg_info %s 2>&1',
);
my %option;

my %option_local = (
    default_yes => {
        default => 'y',
        valids  => ['y', 'n'],
    },
    default_no => {
        default => 'n',
        valids  => ['y', 'n'],
    },
    yes_no => {
        valids => ['y', 'n'],
    },
);

my %option_global = (
    perl_version => {
        desc    => 'Check Perl Version',
        default => $min_perl_version,
        check   => \&check_perl_version,
    },
    snmp_utilities_install => {
        desc    => 'Install the SNMP utilities package',
        default => 'SNMP utilities',
        check   => \&check_package,
        fix     => [\&install_package],
    },

    snmp_session_install => {
        default => 'SNMP_Session',
        desc    => 'Install the SNMP Session package',
        check   => \&check_package,
        fix     => [\&install_package],

    },
    test_prerequisites_install => {
        pre => 'snmp_session_installed && snmp_utilities_installed || snmp_session_installed',
        valids => [0, 1],
    },
    prompt_snmp_session_install => {
        desc           => 'Prompt to install SNMP Session packages',
        prompt         => 'Do you want to install the SNMP Session package?',
        default        => 'y',
        cmd_on_success => {
            y => 'snmp_session_install',
        },

    },
    prompt_snmp_utilities_install => {
        desc           => 'Prompt to install SNMP utilities packages',
        prompt         => 'Do you want to install the SNMP utilities package?',
        default        => 'y',
        cmd_on_success => {
            y => 'snmp_utilities_install',
        }
    },
    required_prerequisites_installed => {
        desc   => 'Required prerequisites packages are installed',
        pre    => 'snmp_session_installed || snmp_utilities_installed',
        valids => [0, 1],
    },
    prompt_git_install => {
        desc           => 'Install git package',
        prompt         => 'Do you want to install git',
        default        => 'y',
        cmd_on_success => {
            y => 'git_install',
        }
    },
    git_install => {
        desc    => 'Install git package',
        default => 'git',
        check   => \&check_package,
        fix     => [\&install_package],
    },
    'user.name' => {
        prompt  => 'Enter your Git user name',
        default => sub {
            my $arg = shift;
            return check_git_local_config($arg) // check_git_global_config($arg) // check_git_local_config_me($arg)
                // check_git_global_config_me($arg) // 'your_username';
        },
    },
    'user.email' => {
        prompt  => 'Enter your Git user email',
        default => sub {
            my $arg = shift;
            return check_git_local_config($arg) // check_git_global_config($arg) // check_git_local_config_me($arg)
                // check_git_global_config_me($arg) // 'your_email@example.com';
        },
    },
    is_install_folder_empty => {
        pre     => 'install_folder',
        default => sub { return is_folder_empty(config('install_folder')) },
        valids  => [0, 1],
    },
    is_install_folder_perms_valid => {
        pre => 'install_folder',
        valids => [0, 1],
        check  => sub { return check_path_permission(config('install_folder'), 'rwx') },
    },


);

my %option_config = (
    github_ssh_private_key_prompt => {
        desc   => 'Setup a working ssh public key for your github account',
        prompt => 'Which local file is your github ssh private key?',
    },
    github_ssh_private_key_prompt_and_valid => {
        desc    => 'Setup a working ssh public key for your github account',
        check   => \&check_github_ssh_private_key,
        default => sub { return $config_new{'github_ssh_private_key_prompt'} },
    },
    github_ssh_private_key_discover_prompt => {
        desc           => 'Setup a working ssh public key for your github account',
        prompt         => 'Do you want to discover working key',
        default        => 'y',
        cmd_on_success => {
            'y' => 'github_ssh_private_key_discovered_and_valid',
        }
    },
    github_ssh_private_key_discovered_and_valid => {
        desc    => 'Discover ssh public key for your github account',
        default => \&discover_github_ssh_private_key,
        check   => \&check_github_ssh_private_key,
    },
    github_ssh_private_key_generate_prompt => {
        desc           => 'Setup a working ssh public key for your github account',
        prompt         => 'Do you want to setup a working ssh public key for your github account key',
        default        => 'y',
        cmd_on_success => {
            'y' => 'github_ssh_private_key_generated_and_valid',
        }
    },
    github_ssh_private_key_generated => {
        pre     => 'home_folder',
        desc    => 'Setup a working ssh public key for your github account',
        default => \&generate_github_ssh_private_key,
    },
    github_ssh_private_key_generated_and_valid => {
        desc    => 'Setup a working ssh public key for your github account',
        pre     => 'github_ssh_private_key_generated',
        default => sub { return $config_new{'github_ssh_private_key_generated'} },
        check   => \&check_github_ssh_private_key,
    },
    github_ssh_private_key => {
        desc    => 'Setup a working ssh public key for your github account',
        default => sub {
            return
                   prompt_option('github_ssh_private_key_prompt_and_valid')
                || prompt_option('github_ssh_private_key_generated_and_valid')
                || prompt_option('github_ssh_private_key_discovered_and_valid');
        },
    },

    install_folder => {
        desc    => 'prompt for the local installation folder',
        prompt  => "Enter your local 'installation' folder (to be created if not exists)",
        default => sub { return $config_new{'home_folder'} . '/server' },
        check   => sub { my $arg = shift; return check_folder($arg, config('home_folder')) },
        fix => [sub { my $arg = shift; return create_subfolder($arg, config('home_folder')) }],
        pre => 'username && home_folder',

    },
    home_folder => {
        desc    => 'prompt for the local installation folder',
        prompt  => "Enter your user 'home' folder",
        default => '/usr/local/lib/devmon',
        check   => \&check_get_or_is_creatable_folder,

    },
    git_installed => {
        desc   => 'Is git installed?',
        check  => sub { return check_package('git') },
        fix    => [sub { prompt_option('prompt_git_install') }],
        valids => [0, 1]
    },
    snmp_session_package_name => {
        default => 'SNMP_Session',
    },
    snmp_session_installed => {

        desc   => 'Is SNMP Session installed ?',
        check  => sub { return check_package('SNMP_Session') },
        fix    => [sub { prompt_option('prompt_snmp_session_install') }],
        valids => [0, 1]

    },
    snmp_utilities_installed => {
        desc   => 'Is SNMP utilities installed ?',
        check  => sub { return check_package('SNMP utilities') },
        fix    => [sub { prompt_option('prompt_snmp_utilities_install') }],
        valids => [0, 1]
    },

    use_git_auth => {
        pre    => 'git_ssh_status || git_http_auth_status',
        valids => [0, 1]
    },
    git_ssh_prompt => {
        desc    => 'Prompt to use git with ssh',
        prompt  => 'Do you want to use git wih ssh? ',
        default => 'auto',
        valids  =>,
        ['auto', 'y', 'n'],
        cmd_on_success => {
            'y'    => 'git_ssh_status',
            'auto' => 'git_ssh_status',
        }
    },
    git_http_auth_prompt => {
        desc           => 'Prompt to use git with http auth',
        prompt         => 'Do you want to use git authentification over http ? ',
        default        => 'auto',
        valids         => ['auto', 'y', 'n'],
        cmd_on_success => {
            'y'    => 'git_http_auth_status',
            'auto' => 'git_http_auth_status',
        }
    },
    git_ssh_status => {
        desc   => 'Setup git to use ssh',
        pre    => 'github_ssh_private_key',
        valids => [0, 1],
    },
    git_http_auth_status => {
        desc => 'Setup git to use http with token autentification',
        fix  => [\&check_git_http_auth],
        pre            => 'user.name && git_private_repo_account && git_private_repo_name && git_private_repo_token',
        valids         => [0, 1],
        cmd_on_success => {
            '0' => 'check_git_http_auth',
            '1' => 'check_git_http_auth',
        },
    },
    git_http_no_auth_status => {
        desc => 'Setup git to use http without autentification',
        fix  => [\&check_git_http],
        pre    => 'user.name && git_origin_repo_account && git_origin_repo_name',
        valids => [0, 1],
    },

    collaboration => {
        desc           => 'Prompt for collaboration',
        prompt         => 'Do you want to collaborate (using git) as much as possible?',
        default        => 'y',
        valids         => ['y', 'n'],
        cmd_on_success => {
            'y' => ['git_installed', 'use_git'],
        },
    },
    use_git => {
        pre    => 'use_git_auth || git_http_no_auth_status',
        valids => [0, 1],
    },

    git_origin_repo_account => {
        prompt  => 'Enter the devmon origin repository account',
        default => 'bonomani',
    },
    git_origin_repo_name => {
        prompt  => 'Enter the devmon origin repository name',
        default => 'devmon',
    },
    git_private_repo_account => {
        prompt => 'Enter your devmon repository account',
    },
    git_private_repo_name => {
        prompt => 'Enter your repository name',
    },
    git_private_repo_token => {
        prompt => 'Enter your repository http token',
    },
    username => {
        desc    => 'Username running devmon',
        prompt  => 'Which specific user will run the Devmon application ?',
        default => 'devmon',
        check   => \&check_username_exists,
        fix     => [\&create_username],
        pre     => 'home_folder',
    },
    configure_git_prompt => {
        desc           => 'Configure local git folder',
        prompt         => 'Do you want to configure the local installation with git',
        default        => 'y',
        pre            => 'use_git' && 'is_install_folder_empty',
        valids         => ['y', 'n'],
        cmd_on_success => {
            'y' => 'git_clone',
        },
    },
    git_clone => {
        desc => 'Configure local git folder',
        pre => 'install_folder && ',
        cmd_on_success => {
            '' => ['git_configured', sub { iprint("$option{desc}...done!") },]
        },
    },
    git_folder => {
        desc           => 'Configure local git folder',
        prompt         => 'Do you want to configure the local installation with git',
        default        => sub { return $config_new{install_folder} . '/.git' },
        pre            => 'install_folder',
        check          => \&check_folder,
        fix            => [\&create_folder],
        cmd_on_success => {
            '' => ['git_configured', sub { iprint("$option{desc}...done!") },]
        },
    },
    git_configured => {
        desc           => 'Configure local git folder',
        prompt         => 'Do you want to configure the local installation with git',
        pre            => 'use_git',
        valids         => [0, 1],
        cmd_on_success => {
            '' => 'configure_git_auth',
        },
        cmd_on_failure => {
            '' => 'configure_git_no_auth',
        },
    },
    git_auth_configured => {
        desc   => 'Configure local git folder',
        prompt => 'Do you want to configure the local installation with git',
        pre            => 'user.name && user.email',
        valids         => [0, 1],
        cmd_on_success => {
            '' => '\&git_local_config',
        },
    },
    git_no_auth_configured => {
        desc           => 'Configure local git folder',
        valids         => [0, 1],
        cmd_on_success => {
            '' => '\&git_local_config',
        },
    },
    git_http_clone_url => {
        default => sub {
            return
                  'https://github.com/'
                . config('git_origin_repo_account') . '/'
                . config('git_origin_repo_name') . '.git';
        },
        pre => 'git_origin_repo_account && git_origin_repo_name',
        fix => \&check_git_clone_tmp,
    },


);


# Merge the hashes by reference and add type for each key
foreach my $key (keys %option_local) {
    $option{$key} = {%{$option_local{$key}}, type => 'local'};
}

foreach my $key (keys %option_global) {
    $option{$key} = {%{$option_global{$key}}, type => 'global'};
}

foreach my $key (keys %option_config) {
    $option{$key} = {%{$option_config{$key}}, type => 'config'};
}

sub enter_block {
    $nesting_level++;
}

sub exit_block {
    $nesting_level-- if $nesting_level > 0;
}

sub is_array_01_or_10 {
    my @array = @_;

    # Sort the array
    @array = sort @array;

    # Check if the sorted array has exactly two elements and matches [0, 1] or [1, 0]
    return scalar(@array) == 2 && $array[0] eq '0' && $array[1] eq '1';
}


sub iprint {
    my ($string) = @_;

    # Directly print with indentation if the previous content was not indented
    print ' ' x ($nesting_level * $indentation_spaces) unless $is_indented;
    print $string;

    # Update the indentation flag based on whether the string ends with a newline
    $is_indented = $string =~ /\n\z/ ? 0 : 1;
}

sub check {
    my ($option_name, $value, $is_bool) = @_;


    # If the option name doesn't exist in the hash, return the original value
    return $value unless exists $option{$option_name}{check};

    # Retrieve the check subroutine associated with the option name
    my $check_sub = $option{$option_name}{check};

    # Perform the check on the value
    my $check_result = defined($value) && $value ne '' ? $check_sub->($value) : $check_sub->();

    # Return $value if $bool is true, or if $check_result is true and $bool is false
    if ($is_bool) {
        if (defined $check_result) {
            return ($check_result ne '0') ? 1 : 0;
        } else {
            return 0;
        }
    }

    # not a bool context
    return $check_result;
}

sub fix {
    my ($option_name, $value, $is_bool) = @_;

    # If the option name doesn't exist in the hash or no fix subroutine defined, return 1
    return ($is_bool ? $value : 1) unless exists $option{$option_name}{fix};

    # Retrieve the fix subroutines associated with the option name
    my $fix_sub = $option{$option_name}{fix};

    # Iterate through each fix subroutine
    foreach my $fix_function (@$fix_sub) {

        # Attempt to fix the value using the current fix subroutine
        if (defined($value) && $value ne '') {
            $fix_function->($value);
        } else {
            $fix_function->();
        }

        # Check the value after applying the fix
        return 1 if check($option_name, $value, $is_bool);
    }

    # If no fix is successful, return 0
    return 0;
}


sub check_and_fix {
    my ($option_name, $value) = @_;
    return 1 unless (exists $option{$option_name}{check} || exists $option{$option_name}{fix});

    if (exists $option{$option_name}{check}) {

        my $check_sub    = $option{$option_name}{check};
        my $check_result = (($value // '') eq '') ? $check_sub->('') : $check_sub->($value);

        if ($check_result) {
            return 1;
        }
    }

    my $attempt = 0;
    my $fix_result;

    foreach my $fix_function (@{$option{$option_name}{fix}}) {
        $attempt++;

        $fix_result = $value eq '' ? $fix_function->() : $fix_function->($value);

        if ($fix_result) {
            if (exists $option{$option_name}{check}) {
                my $check_sub    = $option{$option_name}{check};
                my $check_result = $value eq '' ? $check_sub->() : $check_sub->($value);

                if ($check_result) {
                    return 1;
                }
            } else {
                return 1;
            }
        }
    }
    return 0;
}

sub check_n {
    my $value = shift;
    return $value eq 'n';
}

sub check_github_ssh_key_pub {

    # Info
    # git config --local core.sshCommand "ssh -i /path/to/private/key -o IdentitiesOnly=yes"
    my ($public_key) = @_;

    # Check if the public key is provided
    unless ($public_key) {
        return undef;
    }

    # Execute ssh -vT git@github.com command to check SSH connection
    my $ssh_output = `ssh -vT git\@github.com 2>&1`;

    # Extract the private key path from the verbose output
    my ($private_key_path) = $ssh_output =~ /Server accepts key: (\S+)/;

    # Generate the public key using ssh-keygen
    my $generated_public_key = `ssh-keygen -y -f $private_key_path 2>&1`;

    # Check if the provided public key matches the generated one
    if ($public_key eq $generated_public_key) {

        iprint "Provided public key matches the generated one...";
        return $public_key;
    } else {

        iprint "Provided public key does not match the generated one...";
        return undef;
    }
}

sub check_github_ssh_private_key {
    my $private_key = shift;

    # Check if the private key exists
    unless (defined $private_key && $private_key ne '') {
        iprint("Private key not defined.\n") if $debug;
        return;
    }

    unless (-e $private_key) {
        iprint("A private key at '$private_key' does not exist\n") if $debug;
        return;
    }

    # Attempt SSH connection with the provided private key
    my $ssh_output = `ssh -i $private_key -vT git\@github.com 2>&1`;

    # Return success if the SSH connection was accepted
    return ($ssh_output =~ /Server accepts key: (\S+)/) ? $private_key : undef;

}

sub discover_github_ssh_private_key {
    my $ssh_output = `ssh -vT git\@github.com 2>&1`;
    my ($accepted_private_key) = $ssh_output =~ /Server accepts key: (\S+)/;
    return $accepted_private_key ? $accepted_private_key : undef;    # Return the key or undef if not found
                                                                     #return $accepted_private_key;
}

sub generate_github_ssh_private_key {
    my $private_key_path;
    if (prompt_option('default_yes', 'Do you want to create specific keys (recommended)?')) {
        my $hostname           = `hostname` || $ENV{HOST} || $ENV{COMPUTERNAME};        # Get the hostname
        my $private_key_name   = "id_ed25519_devmon_" . trim($hostname) . "_github";    # Name of the key file
        my $private_key_folder = config('home_folder') . "/.ssh";
        $private_key_path = "$private_key_folder/$private_key_name";

        unless (-e $private_key_folder) {
            if (prompt_option(
                'default_yes', "Private key recommended folder $private_key_folder does not exist, create it?"
            ))
            {
                create_folder($private_key_folder);
            } else {
                iprint "Private key folder $private_key_folder does not exist and will not be created. Aborting...\n";
                return;
            }
        }

        # Check if the private key folder exists
        if (-e $private_key_folder && -d $private_key_folder) {
            if (-e $private_key_path) {
                iprint "A specific private key already exists: $private_key_path, use/replace/delete it!\n";
            } else {
                my $command
                    = "ssh-keygen -t ed25519 -b 4096 -C \"$private_key_name\" -f $private_key_path -N \"\" 2>&1 >/dev/null";
                system($command);
                if ($? != 0) {
                    iprint "Failed to create the specific private key\n";
                    return;
                }
                iprint "A specific private key was generated for this purpose: $private_key_path\n";
            }

            # Extract and verify the public key in both cases
            my $public_key_output = `ssh-keygen -y -f $private_key_path`;

            # Check if ssh-keygen command executed successfully
            if ($? == 0) {

                # Check if the public key starts with 'ssh-ed25519'
                if ($public_key_output =~ /^ssh-ed25519/) {
                    iprint
                        "Public key (re)extracted successfully! To be copied in your Github account!\n$public_key_output";
                } else {
                    iprint "Error: The extracted public key is not in the expected format.\n";
                    return;
                }
            } else {

                # If ssh-keygen command failed, print the error message
                iprint "Error extracting public key: $public_key_output";
                return;
            }

        } else {
            iprint "Not a folder: $private_key_folder or does not exist\n";
            return;
        }


    } else {
        iprint "User chose not to create a specific private key\n";
    }
    return $private_key_path;
}

# Subroutine to check if the default values of options are valid
sub check_options {
    my $all_defaults_valid = 1;    # Flag to track if all default values are valid

    foreach my $option_name (keys %option) {
        my $option = $option{$option_name};

        # Check if option hash is defined
        unless (defined $option) {
            die "Error: Option hash for '$option_name' is not defined.\n";
        }

        # Skip options where default is a CODE reference
        my $default = $option->{default};
        next if ref($default) eq 'CODE';

        # Assign '' to undefined defaults
        $default //= '';

        # Extract valid values
        my @valids   = @{$option->{valids}} if defined $option->{valids};

        # Validate default values
        if (@valids && $default ne '' && !grep { $_ eq $default } @valids) {
            print STDERR "Invalid option: '$option_name'\n";
            print STDERR " - Default: '$default'\n";
            print STDERR " - Valid values: [", join(', ', @valids), "]\n";
            $all_defaults_valid = 0;
        }
    }

    unless ($all_defaults_valid) {
        die "Not all default values are valid.\n";
    }
}

# Subroutine to check if the default values of options are valid
sub check_options_old {
    my $all_defaults_valid = 1;    # Flag to track if all default values are valid
    my $all_requires_valid = 1;    # Flag to track if all required values are valid

    foreach my $option_name (keys %option) {
        my $option = $option{$option_name};

        # Check if option hash is defined
        unless (defined $option) {
            die "Error: Option hash for '$option_name' is not defined.\n";
        }

        my $default  = $option->{default} // '';     # Assigning '' if $option->{default} is undefined
        my @valids   = @{$option->{valids}} if defined $option->{valids};
        my $required = $option->{required} // '';    # Assigning '' if $option->{required} is undefined

        # Check if default value is valid
        if ($required && $default eq '') {
            $all_requires_valid = 0;
        }

        # Check if valid options are defined and if default value is among them
        if (@valids) {
            unless (grep { $_ eq $default } @valids) {
            }
        }
    }

    unless ($all_defaults_valid) {
        die "Not all default values are valid.\n";
    }

    unless ($all_requires_valid) {
        die "Not all required values are valid.\n";
    }
}

# Subroutine to read configuration from file
sub read_config {
    if (-e 'config.txt') {
        open my $fh, '<', 'config.txt' or die "Cannot open config file: $!";
        while (my $line = <$fh>) {
            chomp $line;
            my ($key, $value) = split /=/, $line;
            $value = trim($value);
            $config_old{$key} = $value eq '' ? undef : $value;
        }
        close $fh;
    }
    foreach my $key (sort keys %config_old) {
        print " $key=" . ($config_old{$key} // '') . "\n" if $debug;
    }
}

# Subroutine to print configured options
sub print_configiOLD {
    my %config = @_;
    if (%config) {
        print "Configured options:\n";
        foreach my $key (sort keys %config) {
            print "$key: " . ($config{$key} // '') . "\n";
        }
    }
}

sub trim {
    my ($value) = @_;
    $value =~ s/^\s+|\s+$//g if defined $value;    # Trim leading and trailing whitespace
    return $value;
}

sub apply_transform {
    my ($option, $value) = @_;
    if (defined $value && exists $option->{transform} && exists $option->{transform}->{$value}) {
        return $option->{transform}->{$value};
    }
    return $value;
}

sub validate_input {
    my ($name, $value) = @_;
    if (exists $option{$name}{check}) {    # More explicit check for existence
        my $check_sub = $option{$name}->{check};    # Assuming $check_sub is a code reference
        return $check_sub->($value);
    }
    return $value;                                  # Assume valid if no check is provided
}

sub process_input_value {
    my ($option_name, $value) = @_;                 # Adjusted to accept $option directly
    $config_new{$option_name} = $value if $option{$option_name}{type} ne 'local';
}

sub longest_key {
    my ($input, %variables) = @_;

    # Initialize variable to store the longest match
    my $longest_key;

    # Iterate over each variable name in the hash
    foreach my $variable (keys %variables) {

        # Check if the variable name is a substring of the input string
        if (index($input, $variable) != -1) {

            # If the variable name is a substring, update the longest match if necessary
            if (!defined $longest_key || length($variable) > length($longest_key)) {
                $longest_key = $variable;
            }
        }
    }

    # Return the longest variable name
    return $longest_key;
}

sub exec_on_check_result {
    my ($option_name, $value, $check_result) = @_;

    # Validate inputs using iprint for messaging
    iprint("First argument must be defined") unless defined $option_name;

    #iprint("Second argument must be defined") unless defined $value;
    iprint("Third argument must be a boolean")
        unless defined $check_result && ($check_result == 0 || $check_result == 1);
    $value //= 0;

    # Determine the key based on the boolean value of $check_result
    my $key = $check_result ? 'cmd_on_success' : 'cmd_on_failure';

    # Check if $option{$option_name}{$key} exists to prevent autovivification
    my $action;
    if (exists $option{$option_name} && exists $option{$option_name}{$key}) {
        my $longest_value = longest_key($value, %{$option{$option_name}{$key}});

    # If you search for a key that does not exist in the hash, the longest_key subroutine will return undef because there is no match found
        return if not defined $longest_value;
        $action = $option{$option_name}{$key}{$longest_value};

    }

    # Execute the associated action without autovivification
    if (ref $action eq 'CODE') {
        $action->($value);    # Execute the code reference
    } elsif (ref $action eq 'ARRAY') {

        # If $action is an array reference
        for my $element (@$action) {
            if (ref $element eq 'CODE') {
                $element->($value);    # Execute the code reference
            } else {
                prompt_option($element);    # Execute other types of action
            }
        }
    } elsif (defined $action) {
        prompt_option($action);             # Execute other types of action
    }
}

sub is_bool {
    my ($option_name) = @_;

    # Find the option in the options hash
    my $option = $option{$option_name};

    my @valids;
    my $valids  = '';
    my $is_bool = 0;
    if (exists $option->{valids}) {
        @valids  = @{$option->{valids}};
        $valids  = join(', ', @valids);
        $is_bool = is_array_01_or_10(@valids);
    }
    return $is_bool;
}


# Assign values to @options and $config_ref
sub prompt_option {
    my ($option_name, $override_prompt) = @_;

    iprint "$option_name\n" if $debug;

    # Find the option in the options hash
    my $option = $option{$option_name};

    # Determine if the option is a boolean one
    my $is_bool = is_bool($option_name);


    # If the option is not found, return undef
    die "$option not found" unless $option;
    my $is_config = ($option{$option_name}{type} eq 'config');
    my $prompt = $override_prompt ? $override_prompt : $option->{prompt};

    if (exists $option->{pre}) {
        my $eval = evaluate_expression($option->{pre});
        print "Eval $option_name: $eval\n" if $debug;
        if ($is_bool) {
            return process_input_value($option_name, 0) if $eval eq 0;
        } else {
            return if not defined $eval;
        }
    }

# Check if a key exists (not sur is enough, but let start with that for now): we wont ask same question again and again!
    if (exists $config_new{$option_name}) {

        return $config_new{$option_name};
    }
    print "-";
    enter_block();
    my $default = $option->{default};
    if (ref($default) eq 'CODE') {
        $default = $default->($option_name);    # Execute the code reference and reassign the value
    }

    my $configured = $config_new{$option_name} // $config_old{$option_name} // '';
    my @valids;
    my $valids = '';
    if (exists $option->{valids}) {
        @valids = @{$option->{valids}};
        $valids = join(', ', @valids);
    }

    if ($is_bool) {
        if (defined $default) {
            $default = $default ? 1 : 0;
        } else {
            $default = 1;
        }
    }

    my $info_exist = $configured || $valids;
    my $value;
    my $result;
    my $check_result;

    if ($prompt) {    # not prompt so return valid
        $prompt .= ' ';
        $prompt .= "("                         if $info_exist;
        $prompt .= "Default: $default, "       if defined $default && $default ne '' && $configured ne '';
        $prompt .= "Configured: $configured, " if $configured ne '';
        $prompt .= "Valid: $valids"            if $valids ne '';
        $prompt .= ")"                         if $info_exist;

        # Adjust prompt based on configuration status or defaults
        if ($configured ne '') {

            $prompt .= "[Configured: $configured]: ";
            $default = $configured;
        } else {
            $prompt .= $default ? "[Default: $default]: " : ": ";
        }

        # Handle silent configuration
        if ($silent_config eq 'y') {
            if (defined $default && $default eq '' && not defined $option->{fix}) {
                $result = '';
            } else {
                iprint("$prompt" . ($default // '') . "\n");

                # Check the value
                $result = check($option_name, $default, $is_bool);

                # Attempt fixing the value
                if ($is_bool && $result == 0) {

                    # Fix unconditionally if $bool is true and $result is 0
                    $result = fix($option_name, $default, $is_bool);
                } elsif (!defined $result && fix($option_name, $default, $is_bool)) {

                    # Fix conditionally if $bool is false and the initial check fails or $result is not defined
                    $result = check($option_name, $default, $is_bool);
                }

                unless (defined $result) {
                    iprint("Failed to process '" . ($option{$option_name}{desc} // $option_name) . "'.\n") if $debug;
                    $result = '';
                }
            }
        } else {

            # Interactive configuration
            do {
                iprint $prompt;
                my $input = <STDIN>;
                chomp($input);
                $is_indented = 0;                                        # Reset is_indented
                $value       = $input eq '' ? $default : trim($input);
                $value       = ' ' if $value eq '';
                if ('' ne trim($value)) {                                # skip
                    $value = @valids ? ((grep { $_ eq $value } @valids) ? $value : undef) : $value;  # Validate the data

                    # Check the value
                    $result = check($option_name, $value, $is_bool);

                    # Attempt fixing the value
                    if ($is_bool && $result == 0) {

                        # Fix unconditionally if $bool is true and $result is 0
                        $result = fix($option_name, $value, $is_bool);
                    } elsif (!defined $result && fix($option_name, $value, $is_bool)) {

                        # Fix conditionally if $bool is false and the initial check fails or $result is not defined
                        $result = check($option_name, $value, $is_bool);
                    }
                }
            } while (not defined $result);
        }
    } else {

        # Check the value
        $result = check($option_name, $default, $is_bool);

        # Attempt fixing the value
        if ($is_bool && $result == 0) {

            # Fix unconditionally if $bool is true and $result is 0
            $result = fix($option_name, $default, $is_bool);
        } elsif (!defined $result && fix($option_name, $default, $is_bool)) {

            # Fix conditionally if $bool is false and the initial check fails or $result is not defined
            $result = check($option_name, $default, $is_bool);
        }

        iprint("Failed to process '$option{$option_name}{desc}'.\n") unless $debug;
    }
    process_input_value($option_name, $result);
    exec_on_check_result($option_name, $result, $check_result // 1);
    exit_block();
    return $config_new{$option_name} // $result;

}

sub merge_hashes {
    my ($hash1_ref, $hash2_ref) = @_;
    my %merged_hash = %$hash1_ref;    # Copy contents of hash1 into merged hash

    # Iterate over the keys of the second hash
    foreach my $key (keys %$hash2_ref) {

        # Add key-value pair from hash2 to merged_hash only if the key doesn't exist
        unless (exists $merged_hash{$key}) {
            $merged_hash{$key} = $hash2_ref->{$key};
        }
    }
    return %merged_hash;              # Return only the merged hash
}

# Subroutine to write configuration to file
sub write_config {
    open my $fh, '>', 'config.txt' or die "Cannot open config file for writing: $!";
    die "Error writing to config file: $!" unless $fh;

    # Enable autoflush
    $| = 1;

    my %merged_hash = merge_hashes(\%config_new, \%config_old);
    foreach my $key (sort keys %merged_hash) {

        if (exists $option{$key}{type} && $option{$key}{type} ne 'config') {
            print " Not Writing $key=" . ($merged_hash{$key} // '') . "\n";    # Debug output
        } else {
            print " Writing $key=" . ($merged_hash{$key} // '') . "\n";        # Debug output
            print $fh "$key=" . ($merged_hash{$key} // '') . "\n" or die "Error writing to config file: $!";
        }
    }
    close $fh or die "Error closing config file: $!";
    print "Configuration written to file successfully.\n";
}

sub user2uid {
    my ($user) = @_;
    my $uid = getpwnam($user);
    unless (defined $uid) {
        warn "Failed to get user ID for user $user: $!";
        return;    # Failure
    }
    return $uid;
}

sub group2gid {
    my ($group) = @_;
    my $gid = getgrnam($group);
    unless (defined $gid) {
        warn "Failed to get group ID for group $group: $!";
        return;    # Failure
    }
    return $gid;
}

sub check_path_permission {
    my ($path, $permissions) = @_;
    my $username = config('username');

    # Get the groups the user belongs to
    my @user_groups = split(/\s/, `id -G $username`);

    my @file_stats = stat($path);
    return undef unless @file_stats;

    my ($file_uid, $file_gid, $file_permissions) = @file_stats[4, 5, 2];
    my $is_owner          = $file_uid == user2uid($username);    # $< contains the effective UID of the script
    my %symbolic_to_octal = (
        'r' => 4,
        'w' => 2,
        'x' => 1,
    );

    my $octal_permissions = 0;
    foreach my $symbol (split //, $permissions) {
        die "Invalid permission symbol: $symbol" unless exists $symbolic_to_octal{$symbol};
        $octal_permissions |= $symbolic_to_octal{$symbol};
    }

    my $is_group_member = grep { $_ == $file_gid } @user_groups;

    my $has_permissions = 0;
    if ($is_owner) {
        $has_permissions = ($file_permissions & 0700) == ($octal_permissions << 6);
    } elsif ($is_group_member) {
        $has_permissions = ($file_permissions & 0070) == ($octal_permissions << 3);
    } else {
        $has_permissions = ($file_permissions & 0007) == $octal_permissions;
    }
    return $has_permissions ? $path : undef;
}


sub fix_path_permissions {
    my ($path, $permissions) = @_;

    # Get the default umask
    my $umask = umask() // 022;

    # Set default permissions based on whether the path is a directory or a file
    if (-d $path) {

        # If it's a directory, set default directory permissions
        $permissions //= sprintf("%o", 0777 & ~$umask);
    } elsif (-f $path) {

        # If it's a file, set default file permissions
        $permissions //= sprintf("%o", 0666 & ~$umask);
    } else {
        warn "Path $path is neither a file nor a directory";
        return 0;    # Failure
    }

    # Change permissions
    if (chmod oct($permissions), $path) {
        return 1;    # Success
    } else {
        warn "Unable to change permissions for $path: $!";
        return 0;    # Failure
    }
}

sub user2group {
    my ($username) = @_;
    my $group_name = getgrgid((getpwnam($username))[3]);
    return $group_name;
}


sub fix_path_owner {
    my ($path, $owner_user, $owner_group) = @_;

    my $uid = user2uid($owner_user);
    $owner_group //= user2group($owner_user);
    my $gid = group2gid($owner_group);

    unless (defined $uid && defined $gid) {
        return 0;    # Failure
    }

    if (chown($uid, $gid, $path)) {
        return 1;    # Success
    } else {
        warn "Unable to change owner and group for $path: $!";
        return 0;    # Failure
    }
}


sub check_folder {
    my ($folder_path, $cwd) = @_;

    # If cwd is provided, prepend it to the folder_path if folder_path is not an absolute path
    if ($cwd && $folder_path !~ /^\//) {
        $folder_path = "$cwd/$folder_path";
    }

    my $abs_path = abs_path($folder_path);
    return (-d $abs_path ? $abs_path : undef);

}

sub check_get_or_is_creatable_folder {
    my ($folder_name) = @_;

    # Check if the folder exists
    if (-d $folder_name) {

        # If the folder exists, obtain its absolute path
        my $abs_path = abs_path($folder_name);

        # Return the absolute path of the folder
        return $abs_path;
    } else {

        # Create the folder if it doesn't exist
        print "Creating folder temporarily: mkdir $folder_name...";
        unless (mkdir $folder_name) {

            # If failed to create the folder, print error message and return undef
            print "mkdir error: $! ... Failed\n";
            return undef;
        }

        # Get the absolute path of the newly created folder
        my $abs_path = abs_path($folder_name);

        # Print folder creation message and indicate deletion
        print "Folder created: $abs_path... Deleting: rmdir $folder_name...";

        # Delete the folder (cleanup)
        rmdir $folder_name or die "rmdir error: $! ... Failed";    # Error message here

        # Print success message
        print "Done\n";

        # Return the absolute path of the folder
        return $abs_path;
    }
}


sub check_file {
    my ($file_path) = @_;
    return (-f $file_path ? $file_path : undef);
}

sub create_file {
    my ($file_path) = @_;
    print("Creating file $file_path...");

    # Attempt to create file
    if (open(my $fh, '>', $file_path)) {
        close $fh;
        print("Created: $file_path\n");
        return $file_path;
    } else {
        print("Failed to create file: $!\n");
        return undef;
    }
}

# Function to create a folder, which also creates any non-existing directories in its path
sub create_folder {
    my ($folder_path) = @_;

    # Check if the folder already exists
    if (-d $folder_path) {
        print("Folder already exists: $folder_path\n");
        return 1;    # Return 1 to indicate success
    }

    # Attempt to create the folder
    print("Creating folder: $folder_path...");
    eval {
        make_path($folder_path, {error => \my $err});
        if (@$err) {
            for my $diag (@$err) {
                my ($folder, $message) = %$diag;
                if ($folder eq '') {
                    print "General error: $message\n";
                } else {
                    print "Failed to create $folder: $message\n";
                }
            }
            return 0;    # Return 0 on failure
        }
        1;               # Ensure true is returned on success
    } or do {
        my $error = $@ || 'Unknown error';
        print("Failed to create folder: $error\n");
        return 0;
    };

    print("Done. \n");
    if (config('username') && config('group')) {
        print("Setting owner to " . config('username') . ":" . config('group') . " ...");

        fix_path_owner($folder_path, config('username'), config('group'));
        print("Done.\n");
    }

    return 1;    # Return 1 to indicate success
}

sub make_subfolder_path {
    my ($subfolder, $parent_folder) = @_;
    return $subfolder =~ /^\// ? $subfolder : "$parent_folder/$subfolder";
}


sub is_subfolder {
    my ($folder, $parent_folder) = @_;
    return index($folder, $parent_folder) == 0 && length($folder) > length($parent_folder);
}

sub create_subfolder {
    my ($subfolder, $parent_folder) = @_;

    my $abs_parent_folder = abs_path($parent_folder);
    my $subfolder_path    = make_subfolder_path($subfolder, $parent_folder);

    if (is_subfolder($subfolder_path, $parent_folder)) {
        return create_folder($subfolder_path);
    } else {
        print "Subfolder '$subfolder_path' is not a subfolder of '$parent_folder'\n";
        return 0;
    }
}

# Subroutine to get OS distribution
sub get_os_distribution {

    # Call get_os_from_os_release_ID
    print "Getting OS distribution...";    # Notify that OS distribution detection is starting
    my $os = get_os_from_os_release_ID();

    # Check if $os is defined
    if (!defined $os) {

        my %distribution_matches;          # Hash to store distribution matches

        for my $distribution (keys %distribution_files) {    # Iterate through each distribution
            my $matches = 0;                                 # Initialize match counter for current distribution
            foreach my $file (@{$distribution_files{$distribution}}) {    # Iterate through files for each distribution
                $matches++ if -e $file;                                   # Increment match counter if file exists
            }
            if ($matches) {    # If there are matches for current distribution
                $distribution_matches{$distribution} = [$matches, scalar @{$distribution_files{$distribution}}]
                    ;          # Store number of matches and number of files to match for current distribution
                print " $distribution($matches)";    # Print distribution name and number of matches
            }
        }

        # Redefine $os here to avoid shadowing the outer $os variable
        ($os) = sort {

            # Sort distributions based on number of matches
            $distribution_matches{$b}[0] <=> $distribution_matches{$a}[0] ||

                # If number of matches are equal, prioritize distribution with fewer files to match
                $distribution_matches{$a}[1] <=> $distribution_matches{$b}[1]
            } keys %distribution_matches
            ;    # Sort distributions based on matches and files to match, and get the one with the highest matches

        die "Unable to determine OS distribution" unless $os;    # Die if unable to determine OS distribution
    }
    print ". Found: $os\n";                                      # Print discovered OS distribution
    return $os;                                                  # Return discovered OS distribution
}

sub get_os_from_os_release_ID {
    my $os_release_file = '/etc/os-release';

    # Check if the os-release file exists
    if (-e $os_release_file) {

        # Open the file for reading
        open(my $fh, '<', $os_release_file) or die "Cannot open $os_release_file: $!";

        # Read each line and look for the ID line
        while (my $line = <$fh>) {
            chomp $line;
            if ($line =~ /^\s*ID\s*=\s*"?(.*?)"?\s*$/) {
                close($fh);
                return $1;    # Return the value of the 'ID' key
            }
        }
        close($fh);
    }
    return;    # Return undef if the ID is not found or if the file does not exist
}

sub check_package {

    my ($package_name) = @_;    # Accept OS distribution and package manager as input parameters
    iprint "Checking if $package_name is installed for OS $os_distribution using $package_manager..."
        ;                       # Print message indicating checking package installation
    my $package_to_check = $package{$package_name}{$os_distribution}
        || $package{$package_name}{default};    # Get package name for the specified OS distribution
    unless ($package_to_check) {
        iprint "Package name not available, provide us if it exists!\n"
            unless $package_to_check;           # Die if package name is not provided
        return undef;
    }

    my $output;                                 # Initialize output variable

    my $cmd = sprintf($search_installed_templates{$package_manager}, $package_to_check)
        ;                                       # Construct command to check package installation
    iprint "Executing '$cmd'... ";
    $output = `$cmd`;                                  # Execute command to check package installation
    die "Error executing command: $cmd" if $? != 0;    # Die if error occurs while executing command

    my $is_installed = $output =~ /$package_to_check/; # Check if package is installed
    iprint "" . ($is_installed ? "Done.\n" : "...");   # Print result
        #return $is_installed;    # Return true if package is installed, false otherwise
    return $is_installed ? $package_name : undef;
}

sub install_package {

    my ($package_name) = @_;    # Accept package name, OS distribution, and package manager as input parameters
    iprint "Installing $package_name for OS $os_distribution using $package_manager...\n"
        ;                       # Print message indicating package installation
    my $package_to_install = $package{$package_name}{$os_distribution}
        || $package{$package_name}{default};    # Get package name for the specified OS distribution

    unless ($package_to_install) {              # Die if package name is not provided
        iprint "Package name not provided...";
        return 0;
    }

    my $install_cmd = $install_templates{$package_manager};
    unless ($install_cmd) {
        iprint "Installation instructions not available for $package_manager";
        return 0;
    }

    my $cmd = sprintf($install_cmd, $package_to_install);
    system($cmd);                               # Execute command to install package

    if ($? != 0) {
        iprint "Error installing package: $package_to_install";    # Die if error occurs while installing package
        return 0;
    }
    return 1;

}

# Function to prompt user for package installation
sub prompt_install {
    my ($package_name, $os_distribution, $pkg_manager)
        = @_;    # Accept package name, OS distribution, and package manager as input parameters
    my $install = prompt(
        "The package $package_name is not installed for OS $os_distribution using $pkg_manager. Do you want to install it?",
        'y'
    );           # Prompt user to install the package
    if (lc($install) eq 'y') {
        install_package($package_name, $os_distribution, $pkg_manager);    # Install the package
    } else {
        print "You chose not to install $package_name. Continuing...\n"
            ;    # Print message indicating user chose not to install the package
    }
}

# Function to check if Perl version meets the requirement
sub check_perl_version {
    my ($min_perl_version) = @_;

    # Print Perl version information
    iprint "Checking Perl version... Current: $]; Min Required: $min_perl_version...";

    # Check if current Perl version meets the minimum requirement
    if ($] <= $min_perl_version) {

        return 0;
    } else {
        iprint "OK\n";
        return 1;
    }
}

# Function to check if a command exists
sub command_exists {
    my ($command) = @_;
    return system("command -v $command >/dev/null 2>&1") == 0;
}

# Function to check if GitHub CLI is installed
sub check_if_github_cli_installed {
    return command_exists('gh');
}

# Function to check if gh is authenticated
sub check_if_gh_is_authenticated {
    my $output = `gh auth status`;
    return $output =~ /Logged in to GitHub/;
}

# Function to authenticate with GitHub using GitHub CLI
sub authenticate_with_github {
    print "Authentication with GitHub is required to proceed.\n";
    system("gh auth login");
}

# Function to create a GitHub repository using GitHub CLI
sub create_github_repo {
    print "Enter repository name: ";
    chomp(my $repo_name = <STDIN>);

    print "Enter repository description: ";
    chomp(my $description = <STDIN>);

    my $visibility = prompt('Is the repository private?', 'n');
    $visibility = lc($visibility) eq 'y' ? 'private' : 'public';

    my $private_flag = ($visibility eq 'private') ? '--private' : '';

    my $command = "gh repo create $repo_name --description \"$description\" $private_flag";
    system($command);
}

sub check_and_prompt_install {
    my ($package_name, $os_distribution, $pkg_manager)
        = @_;    # Accept package name, OS distribution, and package manager as input parameters
    my $package_is_installed = check_package_installed($package_name, $os_distribution, $pkg_manager);

    if (defined $package_is_installed and not $package_is_installed) {    # Check if package is not installed
        prompt_install($package_name, $os_distribution, $pkg_manager);    # Prompt to install the package
    } else {
        return $package_is_installed;
    }

}

sub install_github_cli_if_needed {
    unless (check_if_github_cli_installed()) {
        print "GitHub CLI (gh) is not installed.\n";
        my $response = prompt("Do you want to install it?", 'y');
        if (lc($response) eq 'y') {
            install_package('git');
            install_package('gh');
        } else {
            print "You chose not to install GitHub CLI. Continuing...\n";
        }
    }
}

sub collaboration_options {

    my $use_auth = prompt_option('use_auth');

    if ($use_auth) {
        my $use_ssh = ssh_collaboration_options();
        return ($use_auth, $use_ssh);
    } else {
        print "You can join later. Restart the installation process to collaborate.\n";
        print
            "Without git authentication, you can still collaborate, but enabling git authentication will provide additional features:\n";
        print "- Create issues or requests for changes in the original repo.\n";
        print "- Send an email!\n";
        return ($use_auth, 0);
    }
}

sub ssh_collaboration_options {
    print "You can collaborate in multiple ways, sorted by effectiveness:\n";
    print "1. Fork Devmon on GitHub, update it with git (SSH), and submit pull requests to the forked original repo.\n";
    print
        "2. Fork Devmon on GitHub, update it with git (HTTP), and submit pull requests to the forked original repo.\n";
    my $use_ssh = prompt_option('use_ssh');
    print "Using " . ($use_ssh ? "SSH" : "HTTP") . " for Git.\n";
    return $use_ssh;
}


sub gid2group {
    my ($gid) = @_;

    # Open /etc/group file for reading
    open my $group_fh, '<', '/etc/group' or die "Unable to open /etc/group: $!";

    # Iterate through each line in /etc/group
    while (my $line = <$group_fh>) {
        chomp $line;
        my ($name, undef, $etc_group_gid) = split /:/, $line;
        return $name if $etc_group_gid eq $gid;
    }

    # Close /etc/group file
    close $group_fh;

    # Return undefined if group ID is not found
    return;
}

sub check_username_exists {
    my ($username) = @_;

    # Check if the user exists in /etc/passwd and retrieve their home directory
    my $user_entry = `grep "^$username:" /etc/passwd`;
    if ($user_entry) {


        # Extract the home directory and store it in the configuration
        my @user_fields = split /:/, $user_entry;
        $config_new{group}       = gid2group($user_fields[3]);
        $config_new{home_folder} = $user_fields[5];

        return $username;    # User exists and config is updated
    } else {
        iprint "User $username does not exist.\n";
        return undef;        # User does not exist
    }
}

sub create_username {
    my ($username) = @_;
    my $expected_folder = $config_new{home_folder};
    die unless (defined $expected_folder || $username);
    my $expected_folder_preexists = -d $expected_folder;

    # Check if the user already exists in /etc/passwd
    my $user_entry = `grep "^$username:" /etc/passwd`;
    if ($user_entry) {
        die "User $username already exists.\n";
        return 1;    # Return 1 if the user exists
    }
    return 0 unless prompt_option('default_yes', "Do you want to create the user '$username'");

    # The user does not exist, create the user with the specified home directory
    my $command = "sudo useradd -d $expected_folder $username 2>&1";
    iprint "Executing command: $command\n";
    my $output    = `$command`;
    my $exit_code = $? >> 8;
    if ($exit_code != 0) {
        die "Error: Failed to create user. Exit code: $exit_code, Error message: $output \n";
        return 0;
    }
    unless ($expected_folder_preexists) {
        create_folder($expected_folder);
        fix_path_owner($expected_folder, $username);
    }
    return 1;
}


# Main subroutine to configure Git account and repository
sub configure_git {
    my ($install_folder, $use_auth, $use_ssh) = @_;

    # Set up Git user information
    setup_git_user_info();

    # Set up authentication based on options
    if ($use_ssh) {
        check_and_prompt_configure_ssh_key();
    } elsif ($use_auth) {
        setup_git_token_authentication();
    }

    # Prompt for repository details
    my ($repo_account, $repo_name) = prompt_repository_details();

    # Clone the repository if it's not already cloned
    clone_repository($repo_account, $repo_name, $install_folder, $use_auth, $use_ssh);
}

# Function to set up Git user information
sub setup_git_user_info {
    my $git_user_name  = prompt_option('git_user_name');
    my $git_user_email = prompt_option('git_user_email');
    system("git config --global user.name \"$git_user_name\"") == 0   or die "Failed to set Git user name\n";
    system("git config --global user.email \"$git_user_email\"") == 0 or die "Failed to set Git user email\n";
}

# Function to set up Git authentication
sub setup_git_token_authentication {
    my $auth_token = prompt("Enter your Git authentication token");
    system("git config --global credential.helper store") == 0 or die "Failed to set Git credential helper\n";
}

# Function to prompt for repository details
sub prompt_repository_details {
    my $repo_account = prompt_option('original_repo_account');
    my $repo_name    = prompt_option('original_repo_name');
    return ($repo_account, $repo_name);
}

sub clone_repository {
    my ($repo_account, $repo_name, $repo_path_folder, $use_auth, $use_ssh) = @_;
    my $git_clone_url;

    if ($use_auth) {
        if ($use_ssh) {
            $git_clone_url = "git\@github.com:$repo_account/$repo_name.git";
        } else {
            $git_clone_url = "https://github.com/$repo_account/$repo_name.git";
        }
    } else {
        $git_clone_url = "https://$repo_account:$repo_name\@github.com/$repo_account/$repo_name.git";
    }

    # Check if the repository directory is empty
    if (glob("$repo_path_folder/*")) {
        die "The repository directory is not empty: $repo_path_folder\n";
    } else {

        # Clone the repository if it is empty
        system("git clone $git_clone_url $repo_path_folder") == 0 or die "Failed to clone repository\n";
    }
}

# Function to check if Git authentication was successfully configured
sub check_git_auth_successfully_configured {
    my $git_config_name  = `git config --global user.name`;
    my $git_config_email = `git config --global user.email`;
    return ($git_config_name =~ /\w+/ && $git_config_email =~ /\w+/);
}

# Function to check if Git was successfully configured
sub check_git_successfully_configured {
    my $git_config_repo = `git config --get remote.origin.url`;
    return ($git_config_repo =~ /^https:\/\/github\.com\//);
}

sub check_git_configured_with_ssh {
    my $git_config_remote_url = `git config --get remote.origin.url`;
    return $git_config_remote_url =~ /^git\@/;
}

# Function to check if Git is configured with an authentication token
sub check_git_configured_with_auth_token {
    my $git_config_remote_url = `git config --get remote.origin.url`;
    return $git_config_remote_url =~ /^https:\/\/.*[@]github\.com.*/;
}

sub check_ssh_key {
    my $github_key_added = 0;

    # Check if the SSH config file exists
    my $ssh_config_path = "$ENV{HOME}/.ssh/config";
    if (-e $ssh_config_path) {

        # Read the contents of the SSH config file
        open(my $config_fh, '<', $ssh_config_path) or die "Cannot open $ssh_config_path: $!";
        my @config_lines = <$config_fh>;
        close($config_fh);

        # Check if there is a configuration for the devmon repository
        foreach my $line (@config_lines) {
            if ($line =~ /^\s*Host\s+github\.com\s*$/ ... $line =~ /^\s*$/ && $line =~ /devmon/) {
                iprint "SSH key is configured for the devmon repository in $ssh_config_path.\n";
                $github_key_added = 1;
                last;
            }
        }
    } else {
        iprint "SSH config file $ssh_config_path not found.\n";
    }
    return $github_key_added;
}

sub configure_ssh_key {
    my $email = 'your_email@example.com';    # Provide your email here

    my $choice = prompt_option('choice');
    if (lc($choice) eq 'y') {

        # Generate new SSH key pair
        system("ssh-keygen -t rsa -b 4096 -C \"$email\"");
    } else {
        print "Paste your existing SSH private key below:\n";
        my $private_key = <STDIN>;
        print "Paste your existing SSH public key below:\n";
        my $public_key = <STDIN>;

        # Write the keys to current directory
        open(my $private_key_fh, '>', "id_rsa");
        print $private_key_fh $private_key;
        close($private_key_fh);

        open(my $public_key_fh, '>', "id_rsa.pub");
        print $public_key_fh $public_key;
        close($public_key_fh);

        # Add the existing private key to SSH agent
        system("eval $(ssh-agent -s)");
        system("ssh-add id_rsa");

        # Remove keys from the current directory
        unlink "id_rsa", "id_rsa.pub";
    }

    # Print SSH public key to be added to the Git provider (e.g., GitHub, GitLab)
    print "Your SSH public key:\n";
    system("cat ~/.ssh/id_rsa.pub");

    # Inform user about next steps
    print "Add this SSH key to your Git provider account for authentication.\n";
    print "Once added, you can test your connection to Git using the following command:\n";
    print "ssh -T git\@<git_provider_url>\n";
}

sub check_and_prompt_configure_ssh_key {
    my $github_key_added = check_ssh_key();

    unless ($github_key_added) {
        print "No SSH key configured for the devmon repository on GitHub.\n";
        my $choice = prompt_option('defaut_yes', 'No SSH key configured for the devmon repository on GitHub, Creating');
        if (lc($choice) eq 'y') {
            configure_ssh_key();
        }
    }
}

sub get_package_manager {
    my ($os_distribution) = @_;
    print "Getting '$os_distribution' package manager... ";    # Print message indicating getting package manager
    foreach my $pkg_manager (@{$alternative_package_managers{$os_distribution}}) {
        if (command_exists($pkg_manager)) {
            print "Found: $pkg_manager\n";                     # Print message indicating found package manager
            return $pkg_manager;
        }
    }
    die "No suitable package manager found for $os_distribution"
        ;    # Print message indicating no suitable package manager found
}

sub clone_git_http {
    my ($private, $temp_dir) = @_;
    my ($username, $token, $account, $repo_name, $clone_url);

    if ($private) {
        $username  = $config_new{git_user_name};
        $token     = $config_new{git_private_repo_token};
        $account   = $config_new{git_private_repo_account};
        $repo_name = $config_new{git_private_repo_name};
        $clone_url = "https://$username:$token\@github.com/$account/$repo_name.git";

    } else {
        $account   = $config_new{git_origin_repo_account};
        $repo_name = $config_new{git_origin_repo_name};
        $clone_url = "https://github.com/$account/$repo_name.git";
    }

    my $clone_command = "git clone $clone_url $temp_dir";

    # Execute clone command and capture error output
    my $error_output = `$clone_command 2>&1`;
    my $exit_code    = $? >> 8;
    my $is_cloned    = $exit_code ? 0 : 1;      # Get exit code of clone command

    unless ($is_cloned) {
        $config_new{'git_url'} = '';
        return 0;
    }

    $config_new{'git_url'} = $clone_url;
    return 1;
}


sub check_git_http {
    my $temp_dir_auth = shift;
    my $private       = (defined $temp_dir_auth && $temp_dir_auth ne '') ? 1              : 0;
    my $temp_dir      = $private                                         ? $temp_dir_auth : `mktemp -d`;
    chomp($temp_dir);

    die "Failed to create temporary directory" unless -d $temp_dir;

    my $is_cloned = clone_git_http($private, $temp_dir);
    system("rm -rf $temp_dir") unless $private;
    return $is_cloned;
}

sub check_git_http_auth {
    my $temp_dir = `mktemp -d`;
    chomp($temp_dir);
    my $is_cloned = check_git_http($temp_dir);
    unless ($is_cloned) {
        system("rm -rf $temp_dir");
        return 0;
    }
    my $dry_run_command = "git -C $temp_dir push --dry-run 2>&1";
    my $error_output    = `$dry_run_command`;
    system("rm -rf $temp_dir");
    if ($error_output =~ /fatal: Authentication failed/) {
        iprint "Authentication failed\n";
        return 0;
    }
    return 1;
}

# Function to evaluate expressions in mathematical mode
sub evaluate_mathematical_expression {

    # TODO: MISSIN: not and logX()
    # Devmon
    # '+'           (Addition)
    # '-'           (Subtraction)
    # '*'           (Muliplication)
    # '/'           (Division)
    # '^'           (Exponentiation)      Not Perl
    # '%'           (Modulo or Remainder) Not Perl
    # '&'           (bitwise AND)
    # '|'           (bitwise OR)
    # ' . '         (string concatenation - note white space each side) (**deprecated**)
    # '(' and ')'   (Expression nesting)

    my ($expression) = @_;

    # List of recognized mathematical functions
    my @math_functions
        = qw(abs exp sqrt sin cos tan csc sec cot arcsin arccos arctan arccsc arcsec arccot sinh cosh tanh csch sech coth);

    # Handle recognized mathematical functions
    foreach my $func (@math_functions) {
        $expression =~ s/\b$func\s*\(([^()]*)\)/$func($1)/g;
    }

    # Clean up and prepare the expression
    $expression =~ s/\band\b/&&/g;
    $expression =~ s/\bor\b/||/g;

    # Convert Unicode mathematical symbols to ASCII representations
    $expression =~ s/\N{U+2260}/!=/g;                         # ≠ (not equal)
    $expression =~ s/\N{U+2264}/<=/g;                         # ≤ (less than or equal to)
    $expression =~ s/\N{U+2265}/>=/g;                         # ≥ (greater than or equal to)
    $expression =~ s/\N{U+221A}(\d+|\([^)]+\))/sqrt($1)/g;    # Square root with or without parentheses

    # Convert Unicode representations of mathematical constants and symbols
    $expression =~ s/\N{U+03C0}/pi/g;                         # π (pi)
    $expression =~ s/\N{U+212F}/exp/g;                        # ℯ (e)
    $expression =~ s/\N{U+00AC}/!/g;                          # Logical NOT

    # Handle recognized mathematical functions
    foreach my $func (@math_functions) {
        $expression =~ s/\b$func\s*\(([^()]*)\)/$func($1)/g;
    }

    # Convert alternative ASCII representations
    $expression =~ s/\b(\d+)\s*<>(\d+)\b/$1!=$2/g;
    $expression =~ s/\b(\d+)\s*=\s*(\d+)\b/$1==$2/g;
    $expression =~ s/\^/\*\*/g;                               # Exponentiation
    $expression =~ s/×/\*/g;                                  # Multiplication (alternative ASCII representation)
    $expression =~ s/÷/\//g;                                  # Division (alternative ASCII representation)
    $expression =~ s/(\d+)!/$1*factorial($1)/g;               # Factorial
    $expression =~ s/∧/&&/g;                                  # Logical AND
    $expression =~ s/∨/||/g;                                  # Logical OR
     #$expression =~ s/\|([^|]+)\|/abs($1)/g;            # Absolute value  (Should not work becaus of bitwise operator....
    $expression
        =~ s/(?<!\|)\|([^|]+)\|(?!\|)/abs($1)/g;    # Absolute value  (Should not work becaus of bitwise operator....
    $expression =~ s/\be\b/exp/g;

# Check for invalid characters (anything other than digits, operators, parentheses, whitespace, and recognized mathematical functions)
#die "Invalid input for mathematical mode" if $expression =~ /[^0-9\+\-\*\/\%\(\)\s<>=!a-z]+/i;


    # Remove potentially dangerous characters or substrings
    $expression
        =~ s/[;`'"\\]//g;    # Remove semicolons, backticks, single quotes, double quotes, backslashes, and curly braces
    $expression =~ s/(?![ ])\p{Z}//g;    # Replace zero-width but space
                                         #print "3-  $expression\n";

    # Split the expression at '||'
    my @parts = split /\|\|/, $expression;

    # Evaluate each part sequentially
    my $result;
    for my $part (@parts) {
        $result = evaluate_expression_part($part);
        return $result if $result;    # If the result is true, return it
    }

    # If none of the parts are true, return false or undefined (depending on context)
    return $result;
}

# Function to evaluate a part of the expression
sub evaluate_expression_part {
    my ($value) = @_;

    # Create a hash of replacements for variables
    my %replacements;
    while ($value =~ /\b([a-zA-Z_]\w*\.?\w+)\b/g) {
        my $variable_name = $1;
        next if grep { $variable_name eq $_ } @excluded_variable_names;    # Skip if variable is excluded
            #if (exists $config_new{$variable_name} && defined $config_new{$variable_name}) {
        if (exists $config_new{$variable_name}) {
            if (defined $config_new{$variable_name}) {
                $replacements{$variable_name} = $config_new{$variable_name} unless $config_new{$variable_name} eq '';
                $replacements{$variable_name} = 1
                    unless $replacements{$variable_name} =~ /^[+-]?\d*\.?\d+(?:[Ee][+-]?\d+)?$/;
            } else {
                $replacements{$variable_name} = 0;
            }
        } else {
            my $prompt = prompt_option($variable_name);
            if (defined $prompt && $prompt ne '') {


                $replacements{$variable_name} = $prompt;
                $replacements{$variable_name} = 1
                    unless $replacements{$variable_name} =~ /^[+-]?\d*\.?\d+(?:[Ee][+-]?\d+)?$/;
            } else {
                $replacements{$variable_name} = 0;
            }
        }
    }

    # Substitute variables in the value
    $value =~ s/\b([a-zA-Z_]\w*\.?\w+)\b/$replacements{$1}/ge if %replacements;

    # Evaluate the modified expression
    eval { $value = eval $value; };

    # Set $value to undef if there's an error during evaluation
    $value = undef if $@;
    return $value;
}


# Function to evaluate expressions
sub evaluate_expression {
    my ($expression) = @_;

    # Next, evaluate any expressions within parentheses
    return evaluate_parenthesis_expression($expression);
}

# Function to evaluate expressions within parentheses
sub evaluate_parenthesis_expression {
    my ($expression) = @_;

    # Base case: If the expression contains no parentheses, evaluate directly
    if ($expression !~ /\(/) {
        return evaluate_mathematical_expression($expression);
    }

    while ($expression =~ /\(([^()]*)\)/) {
        my $innermost = $1;    # Extract the innermost nested expression

        # Evaluate the innermost expression
        my $result = evaluate_mathematical_expression($innermost);

        # Replace the innermost expression with its result
        $expression =~ s/\Q($innermost)/$result/;
    }

    # Evaluate the modified expression recursively (if needed)
    return evaluate_parenthesis_expression($expression);
}

# Function to evaluate variable expressions
sub evaluate_variable_expression {
    my ($value) = @_;

    # If the value contains an expression, perform variable substitution and evaluate the expression
    $value
        =~ s/([a-zA-Z_]\w*\.?\w+)/exists($option{$1}) ? $option{$1} : (not grep { $1 eq $_ } @excluded_variable_names) ? prompt_option($1) : $1/ge;

    return $value;
}

sub intersection1 {
    my ($list1_ref, $list2_ref) = @_;

    my $common_element;

    # Loop over the first list
    for my $element1 (@$list1_ref) {

        # Loop over the second list
        for my $element2 (@$list2_ref) {

            # Check if the elements are equal
            if ($element1 eq $element2) {

                # If the element is common, check if it's the only common element
                if (defined $common_element && $common_element != $element1) {
                    die "More than one common element found\n";
                }
                $common_element = $element1;
            }
        }
    }

    # If no common element or multiple common elements found, return undef
    return undef unless defined $common_element;

    return $common_element;
}

# Subroutine to fix local Git configuration for a specified key,
sub fix_git_local_config_install_folder {
    my ($config_key) = @_;

    # Retrieve the folder from the global configuration hash %config_hash
    my $folder = config('install_folder');

    # Call the fix_git_local_config subroutine with the specified key and folder
    fix_git_local_config($config_key, $folder);
}

# Generic fix subroutine for setting Git configuration
sub fix_cmd {
    my ($config_key, $folder) = @_;

    # Retrieve the value of the configuration key
    my $value    = config($config_key);
    my $username = config('username');

    # Extract the command and action from the subroutine name
    my ($command, $right_of_command) = (caller(1))[3] =~ /^.*?::(.*?)_(.*)$/;

    # Check if the command is 'git'
    if ($command eq 'git') {

        # Extract the scope and action from the right of the command
        my ($scope, $action) = $right_of_command =~ /^([^_]+)_([^_]+)$/;

        # Ensure scope and action are defined
        if ($scope && $action) {

            # Construct the git command
            my $git_command = "$command $action";
            my $git_cmd     = "$git_command --$scope $config_key \"$value\"";

            # Execute the git command as the specified user
            execute_as_user($username, $git_cmd, $folder);

            # Print a message indicating the configuration was set
            print "$git_command configuration set: $config_key = $value\n";
        } else {
            print "Invalid Git scope, action, or config key\n";
        }
    } else {
        print "Unsupported command: $command\n";
    }
}

# Subroutine to get the value of a key from a hash
sub config {
    my ($config_key) = @_;
    return $config_new{$config_key};
}

# Check Git configuration
sub cmd {
    my ($config_key, $folder, $use_current_user) = @_;    # Get configuration key and folder
    my $config_value = config($config_key);               # Retrieve configuration value

    # Extract command, left_cmd, and right_cmd
    my ($left_cmd, $cmd, $right_cmd) = (caller(1))[3] =~ /^.*?::([^_]+)_([^_]+)_(.+)$/;

    if ($cmd eq 'git') {                                  # Check if the command is 'git'
        my @scopes  = ('local',  'global');               # Define Git scopes
        my @actions = ('config', 'clone');                # Define Git actions

        my @sub_cmds = split /_/, $right_cmd;             # Split sub-commands
            #my $scope    = intersection1(\@sub_cmds, \@scopes);         # Find common scope
            #$scope = defined $scope ? '--' . $scope : '';               # Prefix scope with '--' if defined
        my $action     = intersection1(\@sub_cmds, \@actions) // '';         # Find common action
        my $git_folder = defined $folder ? "--git-dir=$folder/.git" : '';    # Define git folder
                                                                             #my $git_cmd;
        my $cmd_result;

        if ($action eq 'config') {
            my $scope = intersection1(\@sub_cmds, \@scopes);                 # Find common scope
            $scope = defined $scope ? '--' . $scope : '';                    # Prefix scope with '--' if defined

            if ($left_cmd eq 'fix') {                                        # Expect a bool as return value
                my $config_key_val
                    = (defined $config_key && defined $config_value && $config_value ne '')
                    ? "$config_key \"$config_value\""
                    : '';
                my $git_cmd = "$cmd $git_folder $action $scope $config_key_val";    # Construct git command
                $cmd_result = cmd_git($git_cmd, $folder, 1, $use_current_user);     # Execute git command


            } else {    # So check! expect the value as return info
                $config_key = defined $config_key ? "--get $config_key" : '';
                my $git_cmd = "$cmd $git_folder $action $scope $config_key";       # Construct git command
                $cmd_result = cmd_git($git_cmd, $folder, 0, $use_current_user);    # Execute git command

            }
        } elsif ($action eq 'clone') {
            if ($left_cmd eq 'fix') {                                              # Expect a bool as return value
                die;
                my $config_key_val
                    = (defined $config_key && defined $config_value && $config_value ne '')
                    ? "$config_key \"$config_value\""
                    : '';
                my $git_cmd = "$cmd $action $config_key_val $folder";            # Construct git command
                $cmd_result = cmd_git($git_cmd, undef, 1, $use_current_user);    # Execute git command


            } else {    # So check! expect the value as return info
                        #$config_key = defined $config_key ? "set-url $config_key" : '';
                my $git_cmd = "$cmd $action $config_key $folder";    # Construct git command
                $cmd_result = cmd_git($git_cmd, undef, 0, $use_current_user);    # Execute git command

            }
        } else {
            print "Action not supported or not specified.\n";
        }

        return $cmd_result;
    } else {
        print "Unsupported command: $cmd\n";    # Print error message for unsupported command
    }

    return;                                     # Return from subroutine
}


sub construct_command {
    my ($command, $folder, $use_current_user) = @_;
    my $username;
    if ($use_current_user) {
        $username = getpwuid($<);
    } else {
        $username = config('username');    # Retrieve username
    }

    my $command_to_execute;
    if ($username ne getpwuid($<)) {

        # If sudo is used, wrap the command in sh -c and escape single quotes
        my $sh_escaped_command = defined $folder ? "cd '$folder' && $command" : $command;
        $sh_escaped_command =~ s/'/'\\''/g;
        $command_to_execute = qq(sudo -u $username sh -c '$sh_escaped_command 2>&1');
    } else {

        # If sudo is not needed, execute the command directly
        $command_to_execute = defined $folder ? "cd '$folder' && $command" : $command;
        $command_to_execute .= ' 2>&1';
    }
    return $command_to_execute;
}

sub exec_cmd {
    my ($command_to_execute, $is_bool) = @_;
    my $result;

    # Execute the command and capture output
    $result = `$command_to_execute`;
    my $error = $?;

    # Check for errors
    if ($error) {
        warn "Command failed with exit code: $error. Output: $result";
        $result = undef;    # Set result to undefined if there was an error
    }

    # Return boolean result if requested
    if ($is_bool) {
        return $error == 0 ? 1 : 0;    # Return true if command was successful, false otherwise
    } else {
        chomp $result if defined $result;
        return $result;                # Return the output of the command
    }
}

sub cmd_git {
    my ($command, $folder, $is_bool, $use_current_user) = @_;

    # Validate and sanitize input
    unless ($command) {
        die "Command is required";
    }
    # Check and normalize folder path
    $folder = undef unless $folder && -d $folder;

    # Construct the command to execute
    my $command_to_execute = construct_command($command, $folder, $use_current_user);

    # Print command if in debug mode
    print "CMD:$command_to_execute\n" if $debug;

    # Execute the command and capture output
    return exec_cmd($command_to_execute, $is_bool);
}


sub check_git_local_config {
    my ($config_key) = @_;
    my $folder = config('install_folder');
    return cmd($config_key, $folder, 0);
}


sub check_git_local_config_me {
    my ($config_key) = @_;
    my $folder = config('install_folder');
    return cmd($config_key, $folder, 1);
}

sub check_git_global_config {
    my ($config_key) = @_;
    my $folder = config('install_folder');
    return cmd($config_key, $folder, 0);
}


sub check_git_global_config_me {
    my ($config_key) = @_;
    my $folder = config('install_folder');
    return cmd($config_key, $folder, 1);
}

sub fix_git_local_config {
    my ($config_key) = @_;
    my $folder = config('install_folder');
    return cmd($config_key, $folder, 0);
}


sub fix_git_local_config_me {
    my ($config_key) = @_;
    my $folder = config('install_folder');
    return cmd($config_key, $folder, 1);
}

sub fix_git_global_config {
    my ($config_key) = @_;
    my $folder = config('install_folder');
    return cmd($config_key, $folder, 0);
}


sub fix_git_global_config_me {
    my ($config_key) = @_;
    my $folder = config('install_folder');
    return cmd($config_key, $folder, 1);
}

sub check_git_clone_tmp {
    my $url      = shift;
    my $temp_dir = `mktemp -d`;
    chomp($temp_dir);
    die "Failed to create temporary directory" unless -d $temp_dir;
    my $check_result = check_git_clone($url, $temp_dir, undef);
    system("rm -rf $temp_dir");
    return $check_result;
}

sub check_git_clone {
    my ($url, $dir) = @_;
    my $check_result = cmd($url, $dir, undef);
    return $check_result;
}


sub is_folder_empty {
    my $folder = shift;

    opendir(my $dh, $folder) or die "Could not open directory '$folder': $!";
    my @files = grep { !/^\.{1,2}$/ } readdir($dh);
    closedir($dh);

    return scalar(@files) == 0 ? 1 : 0;
}

sub check_url {
    my $remote_repo_url = shift;

    # Run the git ls-remote command
    my $output = `git ls-remote --exit-code $remote_repo_url 2>&1`;

    # Check the exit code to determine success or failure
    my $exit_code = $? >> 8;

    # Return the URL of the remote repository if the command succeeded
    # Otherwise, return undef and the error message
    if ($exit_code == 0) {
        return ($remote_repo_url, undef);
    } else {
        return (undef, $output);
    }
}


## Main script logic
sub main {

    # check the consistency of our options hash.
    check_options();

    # check perl version
    die "invalid version" unless prompt_option('perl_version');

    # Read configuration options from file
    read_config();

    # Ask for recommended setup
    $silent_config = prompt_option('default_yes', 'Proceed with recommended setup?');
    $os_distribution = get_os_distribution();
    $package_manager = get_package_manager($os_distribution);

    # Command
    #prompt_option('test_prerequisites_install');
    my $res = prompt_option('test_prerequisites_install');
    unless ($res) {
        iprint "Unable to have the minimum required packages: Failed: $res";
    }

    #unless (prompt_option('required_prerequisites_installed')) {
    #    iprint "Unable to have the minimum required packages: Failed.";
    #}

    prompt_option('install_folder');
    prompt_option('username') . "\n";
    unless (prompt_option('username')) {
        iprint "Unable to have a valid username";
        die;
    }

    prompt_option('is_install_folder_perms_valid');
    prompt_option('collaboration');
    print(prompt_option('git_http_clone_url'));

    # Write configuration options to file
    print "Writing configuration to file...\n";
    write_config(\%config_new);

}

# Call the main function to execute the script
main();

