# ollama's /api/chat has no top-level "system" field (that belongs to
# /api/generate): a system prompt sent that way is silently dropped and the
# model never learns it has tools. the prompt must travel as the first
# message with role system - on the one-shot path and the streaming path.
use strict;
use warnings;
use Test::More tests => 10;
use FindBin;
use lib "$FindBin::Bin/../lib";
use OldAgent::Config ();
use OldAgent::Provider ();
use OldAgent::HTTP ();
use OldAgent::JSON ();

my @sent;
{
    no warnings 'redefine';
    *OldAgent::HTTP::request = sub {
        my %a = @_;
        push @sent, \%a;
        return { ok => 1, status => 200, backend => 'fake',
                 body => '{"message":{"role":"assistant","content":"hi"},"done":true}' };
    };
    *OldAgent::HTTP::stream_request = sub {
        my %a = @_;
        push @sent, \%a;
        $a{on_line}->('{"message":{"content":"hi"},"done":false}') if $a{on_line};
        return { ok => 1, status => 200, backend => 'fake', body => '' };
    };
    *OldAgent::HTTP::can_stream = sub { 1 };
}

my $cfg = OldAgent::Config->load(no_files => 1, overrides => {
    provider => 'ollama', base_url => 'http://127.0.0.1:11434', model => 'm', http => 'socket',
});
my $p = OldAgent::Provider->new(config => $cfg);

my ($text, $err) = $p->chat(system => 'SYS PROMPT', messages => [ { role => 'user', content => 'q' } ]);
is($err, undef, 'one-shot: no error');
is($text, 'hi', 'one-shot: reply');
my ($body) = OldAgent::JSON::decode($sent[-1]{body});
ok(!exists $body->{system}, 'one-shot: no top-level system field');
is_deeply($body->{messages}[0], { role => 'system', content => 'SYS PROMPT' }, 'one-shot: system prompt is the first message');
is($body->{messages}[1]{role}, 'user', 'one-shot: then the user');
ok(!exists $body->{options}{num_predict}, 'one-shot: no reply cap by default');

@sent = ();
($text, $err) = $p->chat_stream(system => 'SYS PROMPT', messages => [ { role => 'user', content => 'q' } ], token => sub { });
is($err, undef, 'stream: no error') or diag($err);
($body) = OldAgent::JSON::decode($sent[-1]{body});
ok(!exists $body->{system}, 'stream: no top-level system field');
is_deeply($body->{messages}[0], { role => 'system', content => 'SYS PROMPT' }, 'stream: system prompt is the first message');
ok(!exists $body->{options}{num_predict}, 'stream: no reply cap by default');
