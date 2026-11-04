#!/usr/bin/perl
# End-to-end proof that the bash-approval prompt actually reads the human's
# answer instead of auto-denying.
#
# The REPL's line editor leaves the tty in raw mode with a short read timeout
# ("min 0 time 1"), under which a plain `<STDIN>` returns immediately (empty)
# -- so the tool used to be denied before the user could type.  The fix
# restores blocking line mode before the read.  This test puts the tty in that
# raw+timeout state, feeds a "y", and checks the agent approves it.
#
# Needs a controlling tty:
#   printf 'y\n' | script -qec 'perl t/82-approval.t' /dev/null
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::RealBin/../lib";

# not worth running without a real terminal -- the point is tty behaviour
unless (-t STDIN) {
    plan skip_all => 'needs a controlling tty';
    exit 0;
}
plan tests => 2;

use OldAgent::Config;
use OldAgent::Agent;

# we leave the tty in raw mode below; restore it even on a hard die, but
# only if we actually got far enough to change it (a no-tty skip must not
# run stty, which Test::More would then flag as a failure).
my $RAW = 0;
END { system('stty', 'icanon', 'echo', 'isig', 'min', '1', 'time', '0') if $RAW; }

# put the tty in the editor's raw+timeout state (the state that made the
# prompt unanswerable) so a "y" delivered now would be lost to the 100ms
# window unless _approved restores blocking mode first.
system('stty', '-icanon', '-echo', 'min', '0', 'time', '1');
$RAW = 1;

my $cfg = OldAgent::Config->new(config_file => '/dev/null');
$cfg->set(approve => 'ask');
my $agent = OldAgent::Agent->new(config => $cfg, out => \*STDOUT);

# "y\n" is the user's answer; with the editor's raw+timeout settings still in
# force it would be read as empty and the call denied.  The fix makes this a
# normal blocking read that returns "y".
my $r = $agent->_approved({ cmd => 'echo approved' });
is($r, 1, "'y' is read (blocking), not auto-denied");
is($cfg->get('approve'), 'ask', "mode stays 'ask' (only 'a' would flip it)");
