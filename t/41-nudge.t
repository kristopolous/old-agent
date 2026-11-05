# a reply with no tool call: a plain answer ends the turn; narrated
# intent or a stall mid-task gets a nudge. and clip() on a short limit is
# a plain truncation (the old head+tail form mangled one-line summaries).
use strict;
use warnings;
use lib 'lib';
use Test::More;
use File::Spec ();
use OldAgent::Config;
use OldAgent::Agent;
use OldAgent::Tools;
use OldAgent::Util;

plan tests => 12;

package Fake;
sub new { my ($c, %a) = @_; bless { replies => $a{replies}, i => 0, calls => 0 }, $c }
sub chat {
    my ($self) = @_;
    $self->{calls}++;
    my $r = $self->{replies}[ $self->{i}++ ];
    return (undef, 'script exhausted') unless defined $r;
    return ($r, undef);
}
sub kind { 'fake' }
package main;

my $dir = File::Spec->catdir(OldAgent::Util::tmpdir(), "oa-nudge-$$");
mkdir $dir;
OldAgent::Util::spew(File::Spec->catfile($dir, 'a.txt'), "x\n");

sub agent {
    my ($p) = @_;
    my $cfg = OldAgent::Config->load(no_files => 1, overrides => {
        provider => 'echo', root => $dir, tools => 1, approve => 'auto', max_turns => 6,
    });
    return OldAgent::Agent->new(config => $cfg, provider => $p, quiet => 1,
        tools => OldAgent::Tools->new(root => $dir));
}

# --- a chat reply is the end of the turn ------------------------------
my $p = Fake->new(replies => [ "Hey! What can I do for you?", "SHOULD NOT RUN" ]);
my $ag = agent($p);
my ($reply, $err) = $ag->ask('hello');
ok(!$err, 'no error');
is($reply, 'Hey! What can I do for you?', 'the plain answer is the reply');
is($p->{calls}, 1, 'no nudge for a plain answer');
is(scalar @{ $ag->history }, 2, 'history is just the exchange');

# --- narrated intent gets a nudge --------------------------------------
$p = Fake->new(replies => [
    "Let me read the file first.",
    "```tool\n{\"tool\":\"read\",\"args\":{\"path\":\"a.txt\"}}\n```",
    "done\n```tool\n{\"tool\":\"done\",\"args\":{\"summary\":\"read it\"}}\n```",
]);
$ag = agent($p);
($reply, $err) = $ag->ask('what is in a.txt');
ok(!$err, 'no error');
is($p->{calls}, 3, 'nudged once, then it acted, then finished');
like($ag->history->[2]{content}, qr/No tool call was emitted/, 'the nudge went in');
is($ag->stats->{calls}, 2, 'read + done ran');

# --- a prose answer after a tool ran is the end of the turn ------------
$p = Fake->new(replies => [
    "```tool\n{\"tool\":\"read\",\"args\":{\"path\":\"a.txt\"}}\n```",
    "The file contains x.",
    "SHOULD NOT RUN",
]);
$ag = agent($p);
($reply, $err) = $ag->ask('read a.txt');
is($p->{calls}, 2, 'answered after the tool ran: no nudge, no done needed');

# --- sign-off phrases are not intent ------------------------------------
$p = Fake->new(replies => [ "You're welcome! Let me know if you need anything else.", "SHOULD NOT RUN" ]);
$ag = agent($p);
$ag->ask('thanks, that is all');
is($p->{calls}, 1, '"let me know" is a sign-off, not a step');

# --- clip ----------------------------------------------------------------
my $long = 'done  summary=User greeted me with hello. No task given, so I acknowledged and am ready for instructions.';
is(OldAgent::Util::clip($long, 40), substr($long, 0, 37) . '...', 'short limit: plain truncation');
unlike(OldAgent::Util::clip($long, 40), qr/clipped/, 'no clip marker on a short limit');

unlink File::Spec->catfile($dir, 'a.txt'); rmdir $dir;
