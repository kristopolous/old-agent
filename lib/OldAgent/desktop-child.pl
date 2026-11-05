#!/usr/bin/env perl
# oldagent desktop child process. Launched by Desktop.pm (which forks +
# execs this) so it never shares the parent's Tk/X11 state.
#
# Contract:
#   argv: perl desktop-child.pl <libdir> <json-message>
#   out:  one JSON object per line (NDJSON), an event stream:
#           {"type":"note","text":...}    a line the agent printed
#                                         ([tool] calls, [oldagent] errors)
#           {"type":"delta","text":...}   streamed piece of the model reply
#           {"type":"round","text":...}   a full assistant reply, complete
#           {"type":"final","ok":1,...}   done; carries the updated history
# The message carries the prompt, the active settings, and the transcript
# so far; final carries the updated transcript.
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
require OldAgent::Util;

chomp $data;
my ($in, $derr) = OldAgent::JSON::decode($data);
if (!$in) {
    print OldAgent::JSON::encode({ type => 'final', ok => 0,
        err => "cannot read message: " . ($derr || '?'),
        reply => '', history => [] }), "\n";
    exit 9;
}
# start from the same file + environment the parent started from, then let
# the parent's live config win for every key it carried - so runtime changes
# (a /provider set in a menu, a key from the environment, ...) are honoured
# even when they were never written back to the file.
my $cfg = OldAgent::Config->load;
my $sent = ref($in->{cfg}) eq 'HASH' ? $in->{cfg} : {};
for my $k (sort keys %$sent) {
    $cfg->set($k, $sent->{$k}) if defined $sent->{$k};
}
$cfg->set('max_output', $in->{max_output}) if defined $in->{max_output};

# optional diagnostics: OA_CHILD_LOG=/path dumps what the child actually
# built, so a frozen desktop can be inspected without touching the GUI.
if (defined $ENV{OA_CHILD_LOG} && length $ENV{OA_CHILD_LOG}) {
    my $kind = $cfg->get('provider') || '';
    my $base = $cfg->get('base_url') || '';
    my $url  = ($kind eq 'ollama') ? "$base/api/chat"
              : ($kind eq 'anthropic') ? "$base/v1/messages"
              : "$base/chat/completions";
    my $keylen = length($cfg->get('api_key') || '');
    my %sum = map { $_ => $cfg->get($_) } qw(provider model base_url thinking max_tokens);
    $sum{api_key_len} = $keylen;
    $sum{http_backend} = $cfg->get('http');
    if (open(my $L, '>>', $ENV{OA_CHILD_LOG})) {
        print $L OldAgent::JSON::encode({ t => time(), url => $url, cfg => \%sum,
            text => OldAgent::Util::clip(defined $in->{text} ? $in->{text} : '', 120) }), "\n";
        close $L;
    }
}

my $ag = eval { OldAgent::Agent->new(config => $cfg) };
if (!$ag) {
    print OldAgent::JSON::encode({ type => 'final', ok => 0, err => $@,
        reply => '', history => [] }), "\n";
    exit 9;
}
@{ $ag->{history} } = @{ $in->{history} || [] };

# every line the agent prints goes to the parent as a note event, live
$| = 1;
$ag->{out} = sub {
    my $t = join('', @_);
    $t =~ s/\s+\z//;
    return unless length $t;
    print OldAgent::JSON::encode({ type => 'note', text => $t }), "\n";
};
# streamed pieces of the model reply, as they arrive
$ag->{token} = sub {
    my $t = shift;
    return unless defined $t && length $t;
    print OldAgent::JSON::encode({ type => 'delta', text => $t }), "\n";
};
# a complete assistant reply (the parent renders this one with markdown)
$ag->{round} = sub {
    my $t = shift;
    print OldAgent::JSON::encode({ type => 'round', text => $t }), "\n";
};

my ($reply, $err) = eval { $ag->ask($in->{text}) };
if ($@) { $err = $@; $reply = undef }
print OldAgent::JSON::encode({
    type    => 'final',
    ok      => $err ? 0 : 1,
    err     => (defined $err ? $err : ''),
    reply   => (defined $reply ? $reply : ''),
    history => [ map { { role => $_->{role}, content => $_->{content} } }
                 @{ $ag->{history} } ],
}), "\n";
exit 0;
