package OldAgent::HTTP;
# Pluggable HTTP. On a 2000-era box there is usually no HTTP::Tiny and no
# IO::Socket::SSL, but there is almost always curl or wget, so those come
# first for https.  A raw IO::Socket::INET client is the last-resort
# fallback that works on any perl for plain http (local proxies, ollama).

use strict;
use warnings;

use OldAgent::Util ();
use File::Basename ();
use File::Spec ();

my @ORDER = ('curl', 'wget', 'httptiny', 'lwp', 'socket');

sub backends { return @ORDER }

sub available {
    my ($url) = @_;
    my $ssl = ($url && $url =~ /^https:/i) ? 1 : 0;
    my @ok;
    for my $b (@ORDER) {
        next if $b eq 'socket' && $ssl;
        push @ok, $b if _have($b, $ssl);
    }
    return @ok;
}

sub _have {
    my ($b, $ssl) = @_;
    if ($b eq 'curl') { return defined OldAgent::Util::which('curl') }
    if ($b eq 'wget') { return defined OldAgent::Util::which('wget') }
    if ($b eq 'httptiny') {
        return 0 unless eval { require HTTP::Tiny; 1 };
        return 1 unless $ssl;
        return eval { require IO::Socket::SSL; 1 } ? 1 : 0;
    }
    if ($b eq 'lwp') {
        return 0 unless eval { require LWP::UserAgent; require HTTP::Request; 1 };
        return 1 unless $ssl;
        return eval { require IO::Socket::SSL; 1 } || eval { require Net::SSLeay; 1 }
            ? 1 : 0;
    }
    if ($b eq 'socket') {
        return 0 if $ssl;      # no TLS in a bare socket
        return eval { require IO::Socket::INET; 1 } ? 1 : 0;
    }
    return 0;
}

sub pick_backend {
    my (%a) = @_;
    my $want = $a{backend};
    if (defined $want && $want ne 'auto') {
        return ($want, undef) if _have($want, $a{url} =~ /^https:/i ? 1 : 0);
        return (undef, "http backend '$want' is not available on this machine");
    }
    my @ok = available($a{url});
    return ($ok[0], undef) if @ok;
    return (undef,
        'no usable HTTP transport: install curl or wget, '
      . 'or run a local http:// proxy (see `oa doctor`)');
}

# request(url, method, headers, body, timeout, backend)
# -> { ok, status, body, backend, error }
sub request {
    my (%a) = @_;
    my $url = $a{url} or return { ok => 0, error => 'no url given' };
    my $method  = uc(defined $a{method} ? $a{method} : 'GET');
    my $headers = $a{headers} || {};
    my $body    = $a{body};
    my $timeout = defined $a{timeout} ? $a{timeout} : 60;

    my ($backend, $err) = pick_backend(url => $url, backend => $a{backend});
    return { ok => 0, error => $err } if $err;

    my %call = (
        url => $url, method => $method, headers => $headers,
        body => $body, timeout => $timeout,
    );
    my $r;
    if    ($backend eq 'curl')     { $r = _curl(%call) }
    elsif ($backend eq 'wget')     { $r = _wget(%call) }
    elsif ($backend eq 'httptiny') { $r = _tiny(%call) }
    elsif ($backend eq 'lwp')      { $r = _lwp(%call) }
    else                           { $r = _socket(%call) }
    $r->{backend} = $backend;
    return $r;
}

# ---------------------------------------------------------------- curl ---

sub _curl {
    my (%a) = @_;
    my $bin = OldAgent::Util::which('curl');
    my $outf = OldAgent::Util::tmpfile('body-out');
    my @argv = ($bin, '-sS', '--max-time', $a{timeout}, '-o', $outf,
                '-w', '%{http_code}');
    push @argv, '-L';
    push @argv, '-X', $a{method} if $a{method} ne 'GET' || defined $a{body};
    my $in;
    if (defined $a{body}) {
        $in = OldAgent::Util::tmpfile('body');
        my $err = OldAgent::Util::spew($in, $a{body});
        return { ok => 0, error => $err } if $err;
        push @argv, '--data-binary', '@' . $in;
    }
    for my $k (sort keys %{ $a{headers} }) {
        push @argv, '-H', "$k: $a{headers}{$k}";
    }
    push @argv, $a{url};

    # stdout carries only the status code, so no deadlock and no mixing
    my $r = OldAgent::Util::capture(argv => \@argv, timeout => $a{timeout} + 10);
    unlink($in) if defined $in;
    my $code = OldAgent::Util::strip($r->{out});
    my $status = $code =~ /^(\d{3})/ ? $1 + 0 : 0;
    my ($body, $berr) = OldAgent::Util::slurp($outf);
    unlink($outf);
    $body = '' unless defined $body;
    if ($r->{killed}) {
        return { ok => 0, error => "curl timed out after $a{timeout}s" };
    }
    if (!$status) {
        my $msg = OldAgent::Util::strip($r->{err});
        $msg = "curl exited $r->{exit}" unless length $msg;
        return { ok => 0, error => $msg, status => 0, body => $body };
    }
    return { ok => ($status >= 200 && $status < 300) ? 1 : 0,
             status => $status, body => $body, error => undef };
}

# ---------------------------------------------------------------- wget ---

sub _wget {
    my (%a) = @_;
    if ($a{method} ne 'GET' && $a{method} ne 'POST') {
        return { ok => 0, error => "wget cannot do $a{method}; use curl" };
    }
    my $bin  = OldAgent::Util::which('wget');
    my $outf = OldAgent::Util::tmpfile('wget');
    # -nv keeps the "HTTP/1.1 404" line on stderr while staying quiet
    my @argv = ($bin, '-nv', '-S', '-T', $a{timeout}, '-t', '1', '-O', $outf);
    for my $k (sort keys %{ $a{headers} }) {
        push @argv, "--header=$k: $a{headers}{$k}";
    }
    my $in;
    if (defined $a{body}) {
        $in = OldAgent::Util::tmpfile('body');
        my $err = OldAgent::Util::spew($in, $a{body});
        return { ok => 0, error => $err } if $err;
        push @argv, '--post-file=' . $in;
    }
    push @argv, $a{url};

    my $r = OldAgent::Util::capture(argv => \@argv, timeout => $a{timeout} + 10);
    unlink($in) if defined $in;

    my ($body, undef) = OldAgent::Util::slurp($outf);
    unlink($outf);
    $body = '' unless defined $body;

    my $status = 0;
    if (defined $r->{err}) {
        for my $m ($r->{err} =~ m{HTTP/[0-9.]+\s+(\d{3})}g) {
            $status = $m + 0;   # last one wins, redirects are followed
        }
    }
    if (!$status && $r->{ok}) { $status = 200 }
    if (!$status) {
        my $msg = OldAgent::Util::one_line($r->{err});
        $msg = "wget exited $r->{exit}" unless length $msg;
        return { ok => 0, error => $msg, status => 0, body => $body };
    }
    return { ok => ($status >= 200 && $status < 300) ? 1 : 0,
             status => $status, body => $body, error => undef };
}

# ----------------------------------------------------------- HTTP::Tiny ---

sub _tiny {
    my (%a) = @_;
    my $h = HTTP::Tiny->new(
        timeout => $a{timeout},
        agent   => 'oldagent/' . ($OldAgent::VERSION || '0'),
    );
    my $r = eval {
        $h->request($a{method}, $a{url}, {
            headers => $a{headers},
            (defined $a{body} ? (content => $a{body}) : ()),
        });
    };
    return { ok => 0, error => "HTTP::Tiny failed: $@" } if $@ || !$r;
    return {
        ok     => $r->{success} ? 1 : 0,
        status => $r->{status} ? $r->{status} + 0 : 0,
        body   => defined $r->{content} ? $r->{content} : '',
        error  => $r->{success} ? undef : ($r->{reason} || 'http error'),
    };
}

# ------------------------------------------------------------------ LWP ---

sub _lwp {
    my (%a) = @_;
    my $ua = LWP::UserAgent->new(
        timeout => $a{timeout},
        agent   => 'oldagent/' . ($OldAgent::VERSION || '0'),
    );
    $ua->max_redirect(5);
    my $req = HTTP::Request->new($a{method}, $a{url});
    for my $k (sort keys %{ $a{headers} }) {
        $req->header($k, $a{headers}{$k});
    }
    $req->content($a{body}) if defined $a{body};
    my $res = eval { $ua->request($req) };
    return { ok => 0, error => "LWP failed: $@" } if $@ || !$res;
    return {
        ok     => $res->is_success ? 1 : 0,
        status => $res->code ? $res->code + 0 : 0,
        body   => defined $res->content ? $res->content : '',
        error  => $res->is_success ? undef : $res->status_line,
    };
}

# -------------------------------------------------- raw socket (http only) ---

sub _socket {
    my (%a) = @_;
    IO::Socket::INET->import() unless defined &IO::Socket::INET::new;
    my ($scheme, $host, $port, $path) =
        $a{url} =~ m{^(https?)://([^/:]+)(?::(\d+))?(/.*)?$}i
        or return { ok => 0, error => "bad url: $a{url}" };
    return { ok => 0, error => 'raw socket client cannot do https' }
        if lc($scheme) eq 'https';
    $port = defined $port ? $port + 0 : 80;
    $path = defined $path ? $path : '/';

    my $sock = IO::Socket::INET->new(
        PeerAddr => $host, PeerPort => $port, Proto => 'tcp',
        Timeout  => $a{timeout},
    );
    return { ok => 0, error => "connect $host:$port failed: $!" } if !$sock;
    $sock->autoflush(1);

    my $req = "$a{method} $path HTTP/1.0\r\n";
    $req .= "Host: $host" . ($port != 80 ? ":$port" : '') . "\r\n";
    $req .= "Connection: close\r\n";
    for my $k (sort keys %{ $a{headers} }) {
        $req .= "$k: $a{headers}{$k}\r\n";
    }
    if (defined $a{body}) {
        $req .= 'Content-Length: ' . length($a{body}) . "\r\n";
    }
    $req .= "\r\n";
    print($sock $req);
    print($sock $a{body}) if defined $a{body};

    my $raw = '';
    my $deadline = time() + $a{timeout};
    while (time() < $deadline) {
        my $chunk;
        my $n = sysread($sock, $chunk, 8192);
        last if !defined $n || $n == 0;
        $raw .= $chunk;
    }
    close($sock);

    return { ok => 0, error => "no response from $host:$port" }
        if !length $raw;

    my ($head, $body) = split(/\r\n\r\n/, $raw, 2);
    $body = '' unless defined $body;
    my ($status_line) = split(/\r\n/, $head, 2);
    my $status = $status_line =~ m{^HTTP/[0-9.]+ (\d{3})} ? $1 + 0 : 0;

    if ($head =~ /^(?:Transfer-Encoding|Content-Encoding):\s*chunked\s*$/mi) {
        $body = _dechunk($body);
    }
    return {
        ok     => ($status >= 200 && $status < 300) ? 1 : 0,
        status => $status,
        body   => $body,
        error  => ($status >= 200 && $status < 300) ? undef : "http $status",
    };
}

sub _dechunk {
    my ($s) = @_;
    my $out = '';
    my $pos = 0;
    while ($pos < length($s)) {
        my $nl = index($s, "\r\n", $pos);
        last if $nl < 0;
        my $hex = substr($s, $pos, $nl - $pos);
        $hex =~ s/;.*$//;
        last if $hex !~ /^[0-9a-fA-F]+$/;
        my $n = hex($hex);
        last if $n == 0;
        $out .= substr($s, $nl + 2, $n);
        $pos = $nl + 2 + $n + 2;
    }
    return $out;
}

1;
