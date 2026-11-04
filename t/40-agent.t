use strict;
use warnings;
use lib 'lib';
use Test::More;
use File::Spec ();
use OldAgent;
use OldAgent::Config;
use OldAgent::Agent;
use OldAgent::Tools;
use OldAgent::Util;

plan tests => 22;

# a scripted stand-in for a model
package Fake;
sub new {
    my ($class, %a) = @_;
    return bless { replies => $a{replies}, i => 0, calls => 0, error => $a{error} }, $class;
}
sub chat {
    my ($self, %a) = @_;
    $self->{calls}++;
    $self->{last} = { system => $a{system}, messages => $a{messages} };
    return (undef, $self->{error}) if $self->{error};
    my $r = $self->{replies}[ $self->{i}++ ];
    return (undef, 'script exhausted') unless defined $r;
    return ($r, undef);
}
sub kind { 'fake' }
package main;

my $dir = File::Spec->catdir(OldAgent::Util::tmpdir(), "oa-agent-$$");
mkdir $dir;

sub agent {
    my (%a) = @_;
    my $cfg = OldAgent::Config->load(no_files => 1, overrides => {
        provider => 'echo', root => $dir, tools => 1,
        approve => (defined $a{mode} ? $a{mode} : 'auto'),
        max_turns => $a{max_turns} || 6,
    });
    my $tools = OldAgent::Tools->new(root => $dir);
    return OldAgent::Agent->new(
        config => $cfg, tools => $tools, provider => $a{provider},
        quiet => 1, approve => $a{approve},
    );
}

# --- a full task ------------------------------------------------------
my $p = Fake->new(replies => [
    "writing it\n```tool\n{\"tool\":\"write\",\"args\":{\"path\":\"a.txt\",\"content\":\"first\\n\"}}\n```",
    "reading it back\n```tool\n{\"tool\":\"read\",\"args\":{\"path\":\"a.txt\"}}\n```",
    "finished\n```tool\n{\"tool\":\"done\",\"args\":{\"summary\":\"wrote a.txt\"}}\n```",
    "this should never run\n",
]);
my $ag = agent(provider => $p);
my ($reply, $err) = $ag->ask('make a.txt');
ok(!$err, 'no error');
like($reply, qr/finished/, 'last reply returned');
my ($data) = OldAgent::Util::slurp(File::Spec->catfile($dir, 'a.txt'));
is($data, "first\n", 'tool actually wrote the file');
is($p->{calls}, 3, 'done stopped the loop early');
is($ag->stats->{calls}, 3, 'three tool calls counted');

# results were fed back
my $h = $ag->history;
like($h->[2]{content}, qr/```result/, 'results went back to the model');
like($h->[2]{content}, qr/"tool":"write"/, 'result names the tool');
like($h->[3]{content}, qr/read/, 'model saw the result before asking again');

# --- the human says no ------------------------------------------------
my $p2 = Fake->new(replies => [
    "```tool\n{\"tool\":\"bash\",\"args\":{\"cmd\":\"touch bad-file\"}}\n```",
    "ok, stopping\n```tool\n{\"tool\":\"done\",\"args\":{\"summary\":\"denied\"}}\n```",
]);
my $asked = 0;
$ag = agent(provider => $p2, mode => 'ask', approve => sub { $asked++; return 0 });
($reply, $err) = $ag->ask('delete everything');
is($asked, 1, 'approval was requested');
ok(!-e File::Spec->catfile($dir, 'bad-file'), 'denied command never ran');
is($ag->stats->{denied}, 1, 'denial counted');
like($ag->history->[2]{content}, qr/human said no/, 'model was told why');

# --- unknown tool, then recovery -------------------------------------
$p = Fake->new(replies => [
    "```tool\n{\"tool\":\"frobnicate\",\"args\":{}}\n```",
    "sorry\n```tool\n{\"tool\":\"done\",\"args\":{\"summary\":\"no such tool\"}}\n```",
]);
$ag = agent(provider => $p);
$ag->ask('go');
like($ag->history->[2]{content}, qr/unknown tool/, 'unknown tool reported');
ok($ag->history->[2]{content} !~ /"ok":1/, 'and marked as a failure');

# --- provider failure -------------------------------------------------
$p = Fake->new(error => 'http 500 from model');
$ag = agent(provider => $p);
($reply, $err) = $ag->ask('hello?');
ok($err, 'error returned');
like($err, qr/http 500/, 'error text passed through');
is(scalar(@{ $ag->history }), 0, 'nothing added to history on a failed first call');

# --- turn budget ------------------------------------------------------
my @loop = map { "turn $_\n```tool\n{\"tool\":\"list\",\"args\":{\"path\":\".\"}}\n```" } (1 .. 9);
$p = Fake->new(replies => \@loop);
$ag = agent(provider => $p, max_turns => 3);
$ag->ask('loop forever');
is($p->{calls}, 3, 'turn budget respected');

# --- prompt and display ----------------------------------------------
$p = Fake->new(replies => ['plain answer']);
$ag = agent(provider => $p);
$ag->ask('hi');
my $sys = $p->{last}{system};
like($sys, qr/oldagent/, 'system prompt introduces itself');
like($sys, qr/\{"tool":"read","args":\{/, 'system prompt shows the tool format');
like($sys, qr/```result/, 'system prompt explains results');
like(OldAgent::Agent::_strip_blocks("before\n```tool\n{}\n```\nafter"), qr/^before\nafter$/, 'tool blocks hidden from the human');

sub rmtree {
    my ($d) = @_;
    return unless -d $d;
    if (opendir(my $dh, $d)) {
        for my $f (readdir($dh)) {
            next if $f eq '.' || $f eq '..';
            my $x = File::Spec->catfile($d, $f);
            -d $x ? rmtree($x) : unlink($x);
        }
        closedir($dh);
    }
    rmdir $d;
}
rmtree($dir);
