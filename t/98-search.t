# oa-proxy /search - keyless web search through keenable.ai.
#
# fully hermetic: a fake keenable.ai answers on a local socket (modeled on the
# proven server in t/50-http.t), oa-proxy is pointed at it with --keenable-url,
# and OldAgent::Proxy::search drives the proxy the way an old box would.
# nothing here touches the internet.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use OldAgent::Proxy;
use OldAgent::JSON;
use IO::Socket::INET;

my $oa_proxy = "$FindBin::Bin/../oa-proxy";
plan skip_all => 'oa-proxy not found' unless -f $oa_proxy;

# every blocking step runs inside an alarm window; a regression dies in seconds
# instead of hanging the whole run. $PROXIES is reaped when the guard fires.
my @PROXIES;
my $guard = sub {
    my ($code) = @_;
    local $SIG{ALRM} = sub {
        kill 'KILL', @PROXIES if @PROXIES;
        die "search test hung\n";
    };
    alarm 30;
    my $r = &$code;
    alarm 0;
    return $r;
};

# a throwaway keenable on 127.0.0.1: reads a request, logs it, routes by path.
my $logfile = "/tmp/oa-search-$$/log";
{
    my $d = $logfile; $d =~ s{/log$}{};
    mkdir $d;
}

my $srv = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1', Listen => 16, Proto => 'tcp', ReuseAddr => 1,
) or plan(skip_all => "cannot listen: $!");
my $port = $srv->sockport();
my $base = "http://127.0.0.1:$port";

my $pid = fork();
if (!defined $pid) { plan(skip_all => "fork failed: $!") }
if ($pid == 0) {
    serve($srv, 30, $logfile);
    exit 0;
}
close $srv;

sub enc { my ($h) = @_; return OldAgent::JSON::encode($h) }

# fake keenable: /v1/search/public is keyless (needs X-Keenable-Title),
# /v1/search needs a valid X-API-Key. every request is logged so the test can
# see exactly what the proxy sent.
sub serve {
    my ($sock, $limit, $log) = @_;
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
        my ($clen) = $head =~ /Content-Length:\s*(\d+)/i;
        $body = defined $body ? $body : '';
        while (defined $clen && length($body) < $clen) {
            my $buf;
            my $n = sysread($c, $buf, 8192);
            last if !defined $n || $n == 0;
            $body .= $buf;
        }
        my ($xtitle) = $head =~ /X-Keenable-Title:\s*(.*)/i;
        my ($xkey)   = $head =~ /X-API-Key:\s*(.*)/i;
        $xtitle = '' unless defined $xtitle;
        $xtitle =~ s/\r$//;
        $xkey   = '' unless defined $xkey;
        $xkey   =~ s/\r$//;
        my ($path) = $head =~ m{^[A-Z]+ (\S+)};
        my ($status, $out) = route($path, $body, $xtitle, $xkey);
        if (open(my $lf, '>>', $log)) {
            print $lf "REQ path=$path xtitle=$xtitle xkey=$xkey body=$body\n";
            close $lf;
        }
        my $res = "HTTP/1.1 $status OK\r\nContent-Type: application/json\r\n"
                . "Content-Length: " . length($out) . "\r\n\r\n$out";
        print($c $res);
        close($c);
    }
    close($sock);
}

sub route {
    my ($path, $body, $xtitle, $xkey) = @_;
    my ($d) = eval { OldAgent::JSON::decode($body) };
    $d = {} unless ref($d) eq 'HASH';
    my $query = $d->{query};
    $query = '' unless defined $query;
    # a 429 we can induce on demand, to exercise error surfacing
    if (index($query, 'fail429') >= 0) {
        return (429, enc({ error => 'rate limited', message => 'slow down' }));
    }
    if ($path eq '/v1/search/public') {
        # keyless tier: the public endpoint only wants an app name
        if (!length($xtitle)) {
            return (400, enc({ error => 'Missing app identifier' }));
        }
        my @r;
        for my $i (1 .. 3) {
            push @r, {
                title   => "Result $i for $query",
                url     => "https://example.com/$query/$i",
                snippet => "snippet text for result $i",
            };
        }
        return (200, enc({ query => $query, mode => 'pro', results => \@r }));
    }
    if ($path eq '/v1/search') {
        # keyed tier: a real key, and it bills back a usage block
        if ($xkey ne 'k_test') {
            return (401, enc({ error => 'Authentication failed', code => 'invalid_api_key' }));
        }
        my @r = (
            { title => 'Keyed Result 1', url => 'https://example.com/k1', snippet => 'keyed snippet 1' },
            { title => 'Keyed Result 2', url => 'https://example.com/k2', snippet => 'keyed snippet 2' },
        );
        return (200, enc({
            query => $query, mode => 'pro', results => \@r,
            usage => { credits_remaining => 42, credits => 0.004 },
        }));
    }
    return (404, enc({ error => 'no route' }));
}

# start a proxy pointing at the fake; return its port, register it for reaping
sub start_proxy {
    my (%args) = @_;
    my $p = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1', Listen => 4, Proto => 'tcp', ReuseAddr => 1,
    ) or die "proxy listen: $!";
    my $pp = $p->sockport();
    my $ch = fork();
    if (!defined $ch) { die "proxy fork: $!" }
    if ($ch == 0) {
        open(STDERR, '>', '/dev/null');
        my @c = ($^X, $oa_proxy, '--host', '127.0.0.1', '--port', $pp, '--quiet',
                 '--keenable-url', $base, '--search-title', 'oa-proxy-test');
        push @c, ('--keenable-key', $args{key}) if $args{key};
        exec(@c) or exit 127;
    }
    close $p;
    push @PROXIES, $ch;
    return $pp;
}

sub slurp {
    my ($f) = @_;
    open(my $fh, '<', $f) or return '';
    my $c = do { local $/; <$fh> };
    close $fh;
    return defined $c ? $c : '';
}

my $keyless_pp = start_proxy();
my $keyed_pp   = start_proxy(key => 'k_test');

# give both proxies a moment to bind: poll each until its port accepts
sub wait_port {
    my ($pp, $sec) = @_;
    my $deadline = time + $sec;
    while (time < $deadline) {
        my $t = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$pp",
                                          Proto => 'tcp', Timeout => 0.5);
        if ($t) { close $t; return 1 }
        select(undef, undef, undef, 0.1);
    }
    return 0;
}
for my $pp ($keyless_pp, $keyed_pp) {
    $guard->( sub { die "proxy :$pp never came up" unless wait_port($pp, 25); 1 } );
}

# 1. /status reports search and that it is keyless by default
my ($st, $e) = OldAgent::Proxy::status({}, "127.0.0.1:$keyless_pp", 10);
ok(!$e, 'status: no transport error');
is($st->{ok}, 1, 'status: ok');
is($st->{search}, 1, 'status: search enabled');
is($st->{search_provider}, 'keenable', 'status: search provider is keenable');
is($st->{search_keyless}, 1, 'status: keyless by default');

# 2. keyless search: results come back, normalized to title/url/snippet
my ($res, $e2) = OldAgent::Proxy::search({}, "127.0.0.1:$keyless_pp",
    'what is the capital of France',
    max_results => 3, snippet_max_length => 200);
ok(!$e2, 'search: no transport error') or diag($e2);
ok($res, 'search: got a response object');
ok($res->{ok}, 'search: ok') or diag((defined $res->{error} ? $res->{error} : 'no error'));
is($res->{provider}, 'keenable', 'search: provider');
is($res->{keyless}, 1, 'search: keyless');
is(scalar(@{ $res->{results} }), 3, 'search: max_results honoured');
my $first = $res->{results}[0] || {};
like($first->{title}, qr{^Result 1 for}, 'search: result title');
ok(index($first->{url}, 'example.com') >= 0, 'search: result url');
ok(length($first->{snippet}), 'search: snippet present');

# 3. the proxy hit the PUBLIC endpoint, named the app, sent no key
my $log = slurp($logfile);
like($log, qr{path=/v1/search/public}, 'wire: hit the public endpoint');
like($log, qr{xtitle=oa-proxy-test}, 'wire: X-Keenable-Title names the app');
like($log, qr{path=/v1/search/public xtitle=oa-proxy-test xkey=}, 'wire: no X-API-Key when keyless');
like($log, qr{body=.*"query"\s*:\s*"what is the capital of France"}, 'wire: query in the body');
like($log, qr{"max_results"\s*:\s*3}, 'wire: max_results forwarded (as a number)');
like($log, qr{"snippet_max_length"\s*:\s*200}, 'wire: snippet_max_length forwarded');

# 4. empty query: a clear error, no upstream call
my ($noq, $e4) = OldAgent::Proxy::search({}, "127.0.0.1:$keyless_pp", '');
ok($e4, 'search: empty query errors');
like($e4, qr{no query}, 'search: empty query says why');

# 5. an upstream failure surfaces the API's message and status
my ($fail, $e5) = OldAgent::Proxy::search({}, "127.0.0.1:$keyless_pp", 'fail429 now');
ok($e5, 'search: upstream 429 errors');
like($e5, qr{429}, 'search: status in the error') or diag($e5);
like($e5, qr{slow down}, 'search: the API message is in the error');

# 6. the client text formatter is citable
my $txt = OldAgent::Proxy::search_text($res);
like($txt, qr{1\. Result 1 for}, 'search_text: numbered title');
ok(index($txt, 'example.com') >= 0, 'search_text: the url, for citation');
like($txt, qr{snippet text for result 1}, 'search_text: the snippet');

# --- keyed tier ------------------------------------------------------------
my ($kres, $ke) = OldAgent::Proxy::search({}, "127.0.0.1:$keyed_pp", 'keyed query');
ok(!$ke, 'keyed: no transport error') or diag($ke);
ok($kres, 'keyed: got a response');
ok($kres->{ok}, 'keyed: ok') or diag((defined $kres->{error} ? $kres->{error} : 'no error'));
is($kres->{keyless}, 0, 'keyed: flagged as keyed');
ok(ref($kres->{usage}) eq 'HASH', 'keyed: usage block passed through');
like(slurp($logfile), qr{path=/v1/search xtitle= xkey=k_test}, 'wire: X-API-Key sent to the keyed endpoint')
    or diag(slurp($logfile));

# --- tidy ------------------------------------------------------------------
for my $p (@PROXIES) { kill 'TERM', $p; }
$guard->( sub {
    for my $p (@PROXIES) { my $w = waitpid($p, 0); last unless $w; }
    1;
});
kill 'TERM', $pid;
$guard->( sub { waitpid($pid, 0) } );
unlink $logfile; rmdir("/tmp/oa-search-$$/");
done_testing;
