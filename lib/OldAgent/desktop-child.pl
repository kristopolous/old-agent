#!/usr/bin/env perl
# oldagent desktop child process. Launched by Desktop.pm (which forks +
# execs this) so it never shares the parent's Tk/X11 state. Contract:
#   argv:  perl desktop-child.pl <libdir> <json-message>
#   out:   one JSON line on stdout (the answer)
# The message carries the prompt, the active settings, and the transcript
# so far; the answer carries the reply, the agent's printed tool lines,
# and the updated transcript.
use strict;
use warnings;
my $libdir = shift @ARGV;
my $data   = shift @ARGV;
if (!defined $data || $data eq '') {
    $data = do { local $/; <STDIN> } || '';
}
push @INC, $libdir if defined $libdir && length $libdir;
require OldAgent::Config;
require OldAgent::Agent;
require OldAgent::JSON;

chomp $data;
my ($in, $derr) = OldAgent::JSON::decode($data);
if (!$in) {
    print OldAgent::JSON::encode({ ok => 0, err => "cannot read message: " . ($derr || '?'),
        lines => '', reply => '', history => [] }), "\n";
    exit 9;
}
my $cfg = OldAgent::Config->new;
for my $k (qw(provider model base_url key api openai_base ollama_base
              ollama_model anthropic_base anthropic_key exec_cmd)) {
    $cfg->set($k, $in->{cfg}{$k}) if defined $in->{cfg}{$k};
}
$cfg->set('max_output', $in->{max_output}) if defined $in->{max_output};
my $ag = eval { OldAgent::Agent->new(config => $cfg) };
if (!$ag) {
    print OldAgent::JSON::encode({ ok => 0, err => $@,
        lines => '', reply => '', history => [] }), "\n";
    exit 9;
}
@{ $ag->{history} } = @{ $in->{history} || [] };
my @lines;
$ag->{out} = sub { push @lines, join('', @_); };
my ($reply, $err) = eval { $ag->ask($in->{text}) };
if ($@) { $err = $@; $reply = undef }
print OldAgent::JSON::encode({
    ok      => $err ? 0 : 1,
    err     => (defined $err ? $err : ''),
    lines   => join("\n", @lines),
    reply   => (defined $reply ? $reply : ''),
    history => [ map { { role => $_->{role}, content => $_->{content} } }
                 @{ $ag->{history} } ],
}), "\n";
exit 0;
