package OldAgent::Proxy;
# A thin client so a legacy box (no TLS / no https-capable curl) can route
# requests through an oa-proxy running on a modern machine. All proxy traffic
# is plain http, so it reuses the box's existing HTTP backends. 5.006-safe.
#
#   my ($st, $err) = OldAgent::Proxy::status($cfg, $addr);
#   my ($text, $err) = OldAgent::Proxy::fetch($cfg, $addr, $url, %opt);
#   my ($text, $err) = OldAgent::Proxy::mcp($cfg, $addr, \%payload);
#   my ($json, $err) = OldAgent::Proxy::search($cfg, $addr, $query, %opt);
#   my ($resp, $err) = OldAgent::Proxy::request($cfg, $addr, %a);
#
# $addr is "host:port" (port defaults to 8470).

use strict;
use warnings;
use OldAgent ();
use OldAgent::Util ();
use OldAgent::JSON ();
use OldAgent::HTTP ();

sub addr_default_port {
    my ($addr) = @_;
    return $addr unless defined $addr && length $addr;
    $addr =~ s{^https?://}{};
    $addr =~ s{/.*$}{};
    $addr .= ':8470' unless $addr =~ m{:\d+$};
    return $addr;
}

sub _post_json {
    my ($cfg, $addr, $path, $payload, $timeout) = @_;
    my $a = addr_default_port($addr);
    my $url = "http://$a$path";
    my $body = OldAgent::JSON::encode($payload || {});
    my $t = defined $timeout ? $timeout : 90;
    my $r = OldAgent::HTTP::request(
        url     => $url,
        method  => 'POST',
        headers => { 'Content-Type' => 'application/json' },
        body    => $body,
        timeout => $t,
    );
    return (undef, $r->{error} || 'http error') unless $r->{ok};
    my $raw = defined $r->{content} ? $r->{content} : $r->{body};
    my ($json, $e) = OldAgent::JSON::decode($raw);
    return (undef, $e) if $e;
    return ($json, undef);
}

sub status {
    my ($cfg, $addr, $timeout) = @_;
    return _post_json($cfg, $addr, '/status', {}, (defined $timeout ? $timeout : 10));
}

sub fetch {
    my ($cfg, $addr, $url, %opt) = @_;
    return (undef, 'no url') unless defined $url && length $url;
    my ($json, $e) = _post_json($cfg, $addr, '/fetch', {
        url       => $url,
        format    => (defined $opt{format} ? $opt{format} : 'text'),
        max_bytes => $opt{max_bytes},
    }, (defined $opt{timeout} ? $opt{timeout} : 120));
    return (undef, $e) if $e;
    return (undef, $json->{error} || 'proxy error') unless $json->{ok};
    return (OldAgent::Util::one_line($json->{text}), undef);
}

sub mcp {
    my ($cfg, $addr, $payload, $timeout) = @_;
    my ($json, $e) = _post_json($cfg, $addr, '/mcp', $payload || {},
                                (defined $timeout ? $timeout : 60));
    return (undef, $e) if $e;
    return (undef, $json->{error} || 'proxy error') unless $json->{ok};
    return (OldAgent::Util::one_line($json->{text}), undef);
}

# web search through the proxy (keenable.ai on the far side). returns the
# proxy's structured result: { ok, provider, keyless, query, mode,
# results => [ { title, url, snippet, published_at, acquired_at }, ... ] }.
# %opt passes straight through to the search API (max_results, site,
# exclude_domains => [hosts], published_after, snippet_max_length, mode, ...).
sub search {
    my ($cfg, $addr, $query, %opt) = @_;
    return (undef, 'no query') unless defined $query && length $query;
    my %payload = (query => $query);
    for my $p (qw(mode site published_after published_before
                  acquired_after acquired_before query_time
                  max_results snippet_max_length safety_mode
                  objective session_id timeout)) {
        $payload{$p} = $opt{$p} if defined $opt{$p};
    }
    if (ref($opt{exclude_domains}) eq 'ARRAY' && @{ $opt{exclude_domains} }) {
        $payload{exclude_domains} = $opt{exclude_domains};
    }
    my $t = defined $opt{timeout} ? $opt{timeout} : 60;
    my ($json, $e) = _post_json($cfg, $addr, '/search', \%payload, $t);
    return (undef, $e) if $e;
    return (undef, $json->{error} || 'proxy error') unless $json->{ok};
    return ($json, undef);
}

# format a search result as a short, citable text block for the model.
sub search_text {
    my ($res) = @_;
    return '' unless ref($res) eq 'HASH' && ref($res->{results}) eq 'ARRAY';
    my @out;
    my $i = 0;
    for my $r (@{ $res->{results} }) {
        next unless ref($r) eq 'HASH';
        $i++;
        my $title = defined $r->{title} ? $r->{title} : '';
        my $url   = defined $r->{url}   ? $r->{url}   : '';
        push @out, "$i. $title\n   $url";
        if (defined $r->{snippet} && length $r->{snippet}) {
            my $s = $r->{snippet};
            $s =~ s/\s+/ /g;
            $s = substr($s, 0, 400) . '...' if length($s) > 400;
            push @out, "   $s";
        }
    }
    return join("\n", @out);
}

# generic request relay: returns the proxy's { ok, status, reason, headers, body }
sub request {
    my ($cfg, $addr, %a) = @_;
    my $t = defined $a{timeout} ? $a{timeout} : 90;
    my ($json, $e) = _post_json($cfg, $addr, '/req', {
        url     => $a{url},
        method  => (defined $a{method} ? $a{method} : 'GET'),
        headers => $a{headers} || {},
        body    => $a{body},
        timeout => $t,
    }, (defined $a{timeout} ? $a{timeout} : 120));
    return (undef, $e) if $e;
    return ($json, undef);
}

1;
