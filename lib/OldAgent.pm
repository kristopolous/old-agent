package OldAgent;
# oldagent - a tiny text-only agent for old Perls and older machines.
# Pure Perl. No XS. No CPAN. Runs on perl 5.006 (2000) and newer.

use strict;
use warnings;

use 5.006;

use OldAgent::Util ();

$OldAgent::VERSION = '0.1.0';

# The one hard rule of this codebase: everything must parse and run on a
# perl from around the year 2000.  util/compat-lint.pl enforces it.
#
#   NO  say // //= state signatures ->%* given/when ~~ ... try class
#   NO  List::Util Scalar::Util Time::HiRes File::Temp Encode JSON*
#   YES strict warnings Cwd File::Spec File::Basename File::Path File::Copy
#   YES Getopt::Long POSIX IPC::Open3 IO::Socket::INET Config Sys::Hostname

sub version { $OldAgent::VERSION }

sub home_dir {
    my $h = $ENV{HOME} || $ENV{USERPROFILE};
    return $h if $h;
    my $d = OldAgent::Util::cwd();
    return $d;
}

sub config_candidates {
    my @c;
    push @c, $ENV{OLDAGENT_CONFIG} if $ENV{OLDAGENT_CONFIG};
    push @c, OldAgent::Util::cwd() . '/oldagentrc';
    my $h = home_dir();
    push @c, "$h/.oldagentrc" if $h;
    push @c, "$h/.config/oldagent/rc" if $h;
    push @c, '/etc/oldagentrc';
    return @c;
}

1;
