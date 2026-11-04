use strict;
use warnings;
use lib 'lib';
use Test::More;
use IO::Socket::INET ();
use OldAgent::HTTP;
use OldAgent::Config;
use OldAgent::Provider;
use OldAgent::Util;

eval { require IO::Socket::INET; 1 } or plan(skip_all => 'no IO::Socket::INET');

plan tests => 15;

$SIG{ALRM} = sub { die "test timed out\n" };
alarm(90);

# --- a throwaway http server on 127.0.0.1, no network involved --------
my $srv = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1', Listen => 8, Proto => 'tcp', ReuseAddr => 1,
) or plan(skip_all => "cannot listen: $!");
my $port = $srv->sockport();

my $pid = fork();
if (!defined $pid) { plan(skip_all => "fork failed: $!") }
if ($pid == 0) {
    serve($srv, 10);
    exit 0;
}

sub serve {
    my ($sock, $limit) = @_;
    for (1 .. $limit) {
        my $c = $sock->accept or last;
        my $req = '';
        while ($req !~ /\r\n\r\n/) {
            my $buf;
            my $n = sysread($c, $buf, 4096);
            last if !defined $n || $n == 0;
            $req .= $buf;
        }
        my ($head, $body) = split(/\r\n\r\n/, $req, 2);
        my ($path) = $head =~ m{^[A-Z]+ (\S+)};
        my ($clen) = $head =~ /Content-Length:\s*(\d+)/i;
        $body = defined $body ? $body : '';
        while (defined $clen && length($body) < $clen) {
            my $buf;
            my $n = sysread($c, $buf, 8192);
            last if !defined $n || $n == 0;
            $body .= $buf;
        }
        my ($status, $out, $extra) = route($path, $body);
        my $res = "HTTP/1.1 $status OK\r\nContent-Type: application/json\r\n"
                . ($extra || '') . "Content-Length: " . length($out) . "\r\n\r\n$out";
        print($c $res);
        close($c);
    }
    close($sock);
}

sub route {
    my ($path, $body) = @_;
    if ($path =~ m{/fail}) {
        return (401, '{"error":{"message":"bad key"}}');
    }
    if ($path =~ m{/chat/completions$}) {
        # echo the system prompt back so the test can see what was sent
        my $marker = $body =~ /(oldagent-marker-[a-z0-9]+)/ ? $1 : 'none';
        return (200, '{"choices":[{"message":{"role":"assistant","content":"reply for '
                   . $marker . '"},"finish_reason":"stop"}],"usage":{"total_tokens":7}}');
    }
    if ($path =~ m{/models$}) {
        return (200, '{"data":[{"id":"model-a"},{"id":"model-b"}]}');
    }
    if ($path =~ m{/chunked$}) {
        my $payload = "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n";
        return (200, $payload, "Transfer-Encoding: chunked\r\n");
    }
    return (404, '{"error":"no route"}');
}

my $base = "http://127.0.0.1:$port";

# --- raw socket backend ------------------------------------------------
for my $backend ('socket', 'curl', 'wget', 'httptiny') {
    my $have = OldAgent::HTTP::_have($backend, 0);
    SKIP: {
        skip "$backend not available", 1 unless $have;
        my $r = OldAgent::HTTP::request(
            url => "$base/echo", method => 'GET', backend => $backend, timeout => 10,
        );
        is($r->{status}, 404, "$backend backend got a status line");
    }
}

my $r = OldAgent::HTTP::request(url => "$base/chunked", backend => 'socket', timeout => 10);
is($r->{body}, 'hello world', 'chunked decoding');

$r = OldAgent::HTTP::request(
    url => "$base/v1/chat/completions", method => 'POST',
    headers => { 'Content-Type' => 'application/json' },
    body => '{"x":"oldagent-marker-abc"}', backend => 'socket', timeout => 10,
);
like($r->{body}, qr/oldagent-marker-abc/, 'POST body arrived intact');

# --- the openai provider over it --------------------------------------
my $cfg = OldAgent::Config->load(no_files => 1, overrides => {
    provider => 'openai', base_url => "$base/v1", model => 'test-model',
    http => 'socket', timeout => 10,
});
my $p = OldAgent::Provider->new(config => $cfg);
my ($text, $err) = $p->chat(
    system => 'sys prompt',
    messages => [{ role => 'user', content => 'please say oldagent-marker-xyz' }],
);
ok(!$err, 'provider chat succeeded') or diag $err;
like((defined $text ? $text : ''), qr/oldagent-marker-xyz/, 'reply came back through the provider');

my ($models, $merr) = $p->list_models;
ok(!$merr, 'model list ok');
is_deeply($models, ['model-a', 'model-b'], 'model list parsed');

# --- error handling ----------------------------------------------------
my $cfg2 = OldAgent::Config->load(no_files => 1, overrides => {
    provider => 'openai', base_url => "$base/fail", model => 'x',
    http => 'socket', timeout => 10,
});
my ($t2, $e2) = OldAgent::Provider->new(config => $cfg2)->chat(system => 's', messages => []);
ok($e2, 'http 401 is an error');
like($e2, qr/401/, 'status code in the message');
like($e2, qr/bad key/, 'server message passed through');

# --- nothing listening -------------------------------------------------
my $dead = OldAgent::HTTP::request(url => 'http://127.0.0.1:1/x', backend => 'socket', timeout => 3);
ok($dead->{error}, 'connection refused is reported');
like($dead->{error}, qr/connect|refused/i, 'and says so');

kill('TERM', $pid);
waitpid($pid, 0);
alarm(0);
