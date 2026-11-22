# the agent side of web search: oa and oa1 talk to an oa-proxy, which does the
# keenable https call. this drives the real oa and oa1 REPLs (piped, no tty)
# against a hermetic oa-proxy pointed at a fake keenable - nothing touches the
# internet. a search must come back from both editions, formatted and citable.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use OldAgent::JSON;
use OldAgent::Util;
use IO::Socket::INET;

my $repo     = "$FindBin::Bin/..";
my $oa       = "$repo/oa";
my $oa1      = "$repo/oa1";
my $oa_proxy = "$repo/oa-proxy";
plan skip_all => 'oa / oa1 / oa-proxy not found'
    unless -f $oa && -f $oa1 && -f $oa_proxy;

my $tmp  = OldAgent::Util::tmpdir() . "/oa-search-agent-$$";
mkdir $tmp or plan skip_all => "cannot make tmp: $!";
my $log  = "$tmp/keenable.log";

# a throwaway keenable: reads a request, logs it, answers /v1/search/public
my $srv = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1', Listen => 16, Proto => 'tcp', ReuseAddr => 1,
) or plan skip_all => "cannot listen: $!";
my $base = "http://127.0.0.1:" . $srv->sockport();

my $fake = fork();
if (!defined $fake) { plan skip_all => "fork failed: $!" }
if ($fake == 0) { fake_keenable($srv, 40, $log); exit 0 }
close $srv;

sub enc { my ($h) = @_; return OldAgent::JSON::encode($h) }

sub fake_keenable {
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
        my ($path)   = $head =~ m{^[A-Z]+ (\S+)};
        my ($xtitle) = $head =~ /X-Keenable-Title:\s*(.*)/i;
        $xtitle = '' unless defined $xtitle;
        $xtitle =~ s/\r$//;
        if (open(my $lf, '>>', $log)) {
            print $lf "REQ path=$path xtitle=$xtitle body=$body\n";
            close $lf;
        }
        my ($d) = eval { OldAgent::JSON::decode($body) };
        $d = {} unless ref($d) eq 'HASH';
        my $q = $d->{query};
        $q = '' unless defined $q;
        my @r;
        for my $i (1 .. 3) {
            push @r, {
                title   => "Result $i for $q",
                url     => "https://example.com/$q/$i",
                snippet => "snippet text for result $i",
            };
        }
        my $out = enc({ query => $q, mode => 'pro', results => \@r });
        my $res = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                . "Content-Length: " . length($out) . "\r\n\r\n$out";
        print($c $res);
        close($c);
    }
    close($sock);
}

# reap everything if a blocking step hangs
my @PIDS = ($fake);
my $guard = sub {
    my ($code) = @_;
    local $SIG{ALRM} = sub {
        kill 'KILL', @PIDS if @PIDS;
        die "agent search test hung\n";
    };
    alarm 40;
    my $r = &$code;
    alarm 0;
    return $r;
};

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

# start an oa-proxy pointed at the fake keenable; return its port
sub start_proxy {
    my $p = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1', Listen => 4, Proto => 'tcp', ReuseAddr => 1,
    ) or die "proxy listen: $!";
    my $pp = $p->sockport();
    my $ch = fork();
    if (!defined $ch) { die "proxy fork: $!" }
    if ($ch == 0) {
        open(STDERR, '>', '/dev/null');
        exec($^X, $oa_proxy, '--host', '127.0.0.1', '--port', $pp, '--quiet',
             '--keenable-url', $base, '--search-title', 'oa-agent-test')
            or exit 127;
    }
    close $p;
    push @PIDS, $ch;
    return $pp;
}

my $pp = start_proxy();
$guard->( sub { die "proxy never came up" unless wait_port($pp, 25); 1 } );

# run a REPL: fork it with the given command, feed @cmds from stdin, and
# capture stdout/stderr. no model call happens (/search is a command, not a
# message), so the fake endpoint and a dummy base-url are all that is needed.
sub run_repl {
    my ($cmd, $cmds) = @_;
    my $in  = "$tmp/in";
    my $out = "$tmp/out";
    my $err = "$tmp/err";
    open(my $ih, '>', $in) or die "write in: $!";
    print $ih join("\n", @$cmds), "\n";
    close $ih;
    my $pid = fork();
    if (!defined $pid) { die "repl fork: $!" }
    if ($pid == 0) {
        open(STDIN,  "<$in");
        open(STDOUT, ">$out");
        open(STDERR, ">$err");
        $ENV{OA_SESSION_DIR} = $tmp;      # keep oa1's transcript out of /tmp/oa
        exec($^X, @$cmd) or exit 127;
    }
    my $rc = 0;
    $guard->( sub { $rc = waitpid($pid, 0) >> 8; 1 } );
    my ($o, $e) = ('', '');
    if (open(my $fh, '<', $out)) { local $/; my $c = <$fh>; close $fh; $o = defined $c ? $c : '' }
    if (open(my $fh, '<', $err)) { local $/; my $c = <$fh>; close $fh; $e = defined $c ? $c : '' }
    return ($o, $e, $rc);
}

# --- oa: the full, multi-file agent ---------------------------------------
# `oa repl` is the pipeable interactive form (`oa chat` deliberately stays
# silent on a piped stdin, by design). the proxy is on the wire through /search.
my ($o, $e) = run_repl(
    [ $oa, 'repl', '--no-config', '--base-url', 'http://127.0.0.1:1', '--model', 'x' ],
    [ "/proxy 127.0.0.1:$pp", "/search capital-of-France", "/quit" ]);
like($o, qr{proxy = 127\.0\.0\.1:$pp}, 'oa /proxy: accepted the proxy') or diag($e);
like($o, qr{searching via 127\.0\.0\.1:$pp}, 'oa /search: reached the proxy') or diag("$o\n$e");
like($o, qr{Result 1 for capital-of-France}, 'oa /search: a result title came back') or diag("$o\n$e");
ok(index($o, 'example.com') >= 0, 'oa /search: the url, citable');
like($o, qr{snippet text for result 1}, 'oa /search: the snippet');
like($o, qr{3 result\(s\) via 127\.0\.0\.1:$pp, keenable keyless}, 'oa /search: count + keyless');

# --- oa1: the one-file edition --------------------------------------------
my ($o1, $e1) = run_repl(
    [ $oa1, '--no-config', '--base-url', 'http://127.0.0.1:1', '--model', 'x', '-q' ],
    [ "/proxy 127.0.0.1:$pp", "/search capital-of-France", "/quit" ]);
like($o1, qr{proxy = 127\.0\.0\.1:$pp}, 'oa1 /proxy: accepted the proxy') or diag($e1);
like($o1, qr{Result 1 for capital-of-France}, 'oa1 /search: a result title came back') or diag("$o1\n$e1");
ok(index($o1, 'example.com') >= 0, 'oa1 /search: the url, citable');
like($o1, qr{snippet text for result 1}, 'oa1 /search: the snippet');
like($o1, qr{3 result\(s\) via 127\.0\.0\.1:$pp, keenable keyless}, 'oa1 /search: count + keyless');

# --- the wire: both editions reached the keyless public endpoint -----------
my $klog = '';
if (open(my $fh, '<', $log)) { local $/; my $c = <$fh>; close $fh; $klog = defined $c ? $c : '' }
my $hits = () = $klog =~ /path=\/v1\/search\/public/g;
ok($hits >= 2, 'wire: both oa and oa1 hit the public keyless endpoint') or diag($klog);
like($klog, qr{xtitle=oa-agent-test}, 'wire: the app was named');
like($klog, qr{"query":"capital-of-France"}, 'wire: the query went to keenable');

# --- no proxy set: a clear, offline error ---------------------------------
my ($on, $en) = run_repl(
    [ $oa, 'repl', '--no-config', '--base-url', 'http://127.0.0.1:1', '--model', 'x' ],
    [ "/search something", "/quit" ]);
like($on, qr{no proxy set}, 'oa /search with no proxy: tells you to set one');

my ($on1, $en1) = run_repl(
    [ $oa1, '--no-config', '--base-url', 'http://127.0.0.1:1', '--model', 'x', '-q' ],
    [ "/search something", "/quit" ]);
like($on1, qr{no proxy set}, 'oa1 /search with no proxy: tells you to set one');

# --- tidy ------------------------------------------------------------------
for my $p (@PIDS) { kill 'TERM', $p; }
$guard->( sub { for my $p (@PIDS) { my $w = waitpid($p, 0); last unless $w; } 1 } );
rmdir $tmp;
done_testing;
