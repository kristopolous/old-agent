package OldAgent::Provider;
# Talks to a model.  Four kinds of back end, all speaking the same tiny
# interface: chat(system, messages) -> (text, error)
#
#   openai     any OpenAI-compatible /chat/completions endpoint
#              (OpenAI, OpenRouter, Groq, vLLM, LM Studio, LocalAI,
#               llama.cpp's server, ollama's /v1, an nginx proxy, ...)
#   ollama     ollama's native /api/chat
#   anthropic  Anthropic /v1/messages
#   exec       pipe the transcript to a local command (llama-cli, ssh, a
#              script, /dev/stdin) - no key, no network, no fuss
#   echo       built-in test provider, no model at all

use strict;
use warnings;

use OldAgent::JSON ();
use OldAgent::HTTP ();
use OldAgent::Util ();

sub new {
    my ($class, %a) = @_;
    my $cfg = $a{config} or die "provider needs a config\n";
    my $self = {
        cfg       => $cfg,
        backend   => $cfg->get('http'),
        timeout   => 0 + ($cfg->get('timeout', 0) || 0),   # 0 = no limit
        last_meta => {},
    };
    return bless $self, $class;
}

sub kind { return $_[0]{cfg}->get('provider') }

sub chat {
    my ($self, %a) = @_;
    my $kind = $self->kind;
    my ($text, $err);
    if    ($kind eq 'openai' || $kind eq 'openai-compat') { ($text, $err) = $self->_openai(%a) }
    elsif ($kind eq 'ollama' && $self->{cfg}->get('openai_compat')) {
        # ollama with a /v1 base url speaks the OpenAI dialect
        ($text, $err) = $self->_openai(%a);
    }
    elsif ($kind eq 'ollama')                             { ($text, $err) = $self->_ollama(%a) }
    elsif ($kind eq 'anthropic')                          { ($text, $err) = $self->_anthropic(%a) }
    elsif ($kind eq 'exec')                               { ($text, $err) = $self->_exec(%a) }
    elsif ($kind eq 'echo')                               { ($text, $err) = $self->_echo(%a) }
    else {
        my $hint = $kind =~ m{^https?://}
            ? " -- that looks like a url; use /base-url instead" : '';
        return (undef, "unknown provider '$kind' (openai, ollama, anthropic, exec, echo)$hint");
    }
    # optional: a token callback is only meaningful while streaming; a one-shot
    # back end has no tokens to show, so it simply goes unused.
    $self->{last_meta} = { provider => $kind, error => $err };
    return ($text, $err);
}

# chat_stream(system, messages, token => CODE) -> (full_text, error)
# incremental: token->(piece) as text arrives; the same contract as chat().
# only the openai-compat and ollama dialects stream (both are line based and
# every transport can read a pipe line by line); everything else falls back
# to the one-shot chat, which still works exactly as before.
sub chat_stream {
    my ($self, %a) = @_;
    my $token = ref($a{token}) eq 'CODE' ? $a{token} : undef;
    my $kind = $self->kind;
    my ($text, $err);
    # no curl (an old box): the one-shot reply, without trying first
    $token = undef unless OldAgent::HTTP::can_stream();
    if (($kind eq 'openai' || $kind eq 'openai-compat') && $token) {
        ($text, $err) = $self->_openai_stream(%a);
        if ($err) { ($text, $err) = $self->_openai(%a) }   # fall back to one-shot
    }
    elsif (($kind eq 'ollama' && !$self->{cfg}->get('openai_compat')) && $token) {
        ($text, $err) = $self->_ollama_stream(%a);
        if ($err) { ($text, $err) = $self->_ollama(%a) }
    }
    else {
        ($text, $err) = $self->chat(%a);
    }
    $self->{last_meta} = { provider => $kind, error => $err };
    return ($text, $err);
}

# the OpenAI-dialect url for a path. an ollama base without /v1
# (http://host:11434) serves the dialect only under /v1 and 404s above it;
# once a 404 has taught us that, every later url carries the /v1.
sub _oa_url {
    my ($self, $path) = @_;
    my $base = $self->{cfg}->get('base_url');
    $base =~ s{/+$}{};
    $base .= '/v1' if $self->{need_v1} && $base !~ m{/v1$};
    return "$base$path";
}

# a 404 on a base without /v1: worth one retry under /v1
sub _retry_under_v1 {
    my ($self, $status) = @_;
    return 0 unless defined $status && $status == 404;
    return 0 if $self->{need_v1};
    my $base = $self->{cfg}->get('base_url') || '';
    return 0 if $base =~ m{/v1/?$};
    $self->{need_v1} = 1;
    return 1;
}

# ------------------------------------------------------------ streaming ---

sub _openai_stream {
    my ($self, %a) = @_;
    my $url  = $self->_oa_url('/chat/completions');
    my %payload = (
        model    => $self->{cfg}->get('model'),
        messages => [ { role => 'system',
                        content => OldAgent::JSON::str($a{system}) },
                      @{ $self->_clean_messages($a{messages}) } ],
        stream   => OldAgent::JSON::num(1),
    );
    my $t = $self->{cfg}->get('temperature');
    $payload{temperature} = OldAgent::JSON::num($t) if defined $t && length $t;
    my $mt = $self->{cfg}->get('max_tokens');
    $payload{max_tokens} = OldAgent::JSON::num($mt) if defined $mt && length $mt;

    my $full = '';
    my $serr;
    my $seen_data = 0;
    my $r = OldAgent::HTTP::stream_request(
        url     => $url,
        method  => 'POST',
        headers => $self->_headers(),
        body    => OldAgent::JSON::encode(\%payload),
        timeout => $self->{timeout},
        on_line => sub {
            my ($line) = @_;
            return unless $line =~ /\S/;
            return unless $line =~ /^data:\s*(\[?\S.*)$/s;
            $seen_data++;
            return if $1 =~ /^\s*\[/;            # [DONE] and friends
            my ($d, $derr) = OldAgent::JSON::decode($1);
            return if defined $derr;
            if (ref($d) eq 'HASH' && ref($d->{error}) eq 'HASH') {
                $serr = 'api error: ' . ($d->{error}{message} || 'unknown');
                return;
            }
            my $ch = ref($d->{choices}) eq 'ARRAY' ? $d->{choices} : [];
            return unless @$ch;
            my $delta = (ref($ch->[0]{delta}) eq 'HASH') ? $ch->[0]{delta}{content}
                      : (ref($ch->[0]{message}) eq 'HASH' ? $ch->[0]{message}{content}
                                                         : undef);
            if (defined $delta && length $delta) {
                $full .= $delta;
                $a{token}->($delta);
            }
        },
    );
    if ($serr) { return (undef, $serr) }
    if ($r->{error} && !length $full) {
        return (undef, "request to $url failed: " . $r->{error}
                     . ' (via ' . (defined $r->{backend} ? $r->{backend} : 'curl') . ')');
    }
    # a stream that never sent a data: line is an error page (curl -sS
    # streams a 404 body like anything else), not an empty reply. say so,
    # so the caller falls back to the one-shot request - which knows how
    # to find the /v1 the base is missing.
    if (!$seen_data) {
        my $body = OldAgent::Util::clip(OldAgent::Util::one_line(defined $r->{body} ? $r->{body} : ''), 120);
        # a 404 on a base without /v1: stream again under /v1. curl gives
        # no status here and ollama's 404 body is empty, so "nothing at
        # all came back" is the tell (a wrong guess costs one request and
        # the one-shot fallback still runs after it)
        return $self->_openai_stream(%a)
            if ($body =~ /\b404\b/ || !length $body) && $self->_retry_under_v1(404);
        return (undef, "request to $url returned no stream" . (length $body ? ": $body" : ''));
    }
    return ($full, undef);
}

sub _ollama_stream {
    my ($self, %a) = @_;
    my $base = $self->{cfg}->get('base_url');
    $base =~ s{/v1$}{};
    my $url = "$base/api/chat";
    my %options;
    my $t = $self->{cfg}->get('temperature');
    $options{temperature} = OldAgent::JSON::num($t) if defined $t && length $t;
    my $mt = $self->{cfg}->get('max_tokens');
    $options{num_predict} = OldAgent::JSON::num($mt) if defined $mt && length $mt;
    my $think = $self->{cfg}->get('thinking');
    $options{think} = OldAgent::JSON::num(defined $think && $think eq '1' ? 1 : 0);
    my %payload = (
        model    => $self->{cfg}->get('model'),
        # /api/chat has no top-level system field (that is /api/generate):
        # the system prompt goes in as the first message, or the model
        # never learns it has tools
        messages => [ { role => 'system', content => OldAgent::JSON::str($a{system}) },
                      map { { role => $_->{role}, content => $_->{content} } }
                      @{ $self->_clean_messages($a{messages}) } ],
        stream   => OldAgent::JSON::num(1),
    );
    $payload{options} = \%options if %options;

    my $full = '';
    my $serr;
    my $r = OldAgent::HTTP::stream_request(
        url     => $url,
        method  => 'POST',
        headers => $self->_headers(),
        body    => OldAgent::JSON::encode(\%payload),
        timeout => $self->{timeout},
        on_line => sub {
            my ($line) = @_;
            my ($d, $derr) = OldAgent::JSON::decode($line);
            return if defined $derr;
            if (ref($d) eq 'HASH' && defined $d->{error}) {
                $serr = 'ollama error: ' . $d->{error};
                return;
            }
            my $c;
            if (ref($d->{message}) eq 'HASH') {
                $c = defined $d->{message}{content} ? $d->{message}{content}
                    : $d->{message}{response};
            }
            if (defined $c && length $c) {
                $full .= $c;
                $a{token}->($c);
            }
        },
    );
    if ($serr) { return (undef, $serr) }
    if ($r->{error} && !length $full) {
        return (undef, "request to $url failed: " . $r->{error}
                     . ' (via ' . (defined $r->{backend} ? $r->{backend} : 'curl') . ')');
    }
    return ($full, undef);
}

# ------------------------------------------------------------- messages ---

# Some endpoints insist on strictly alternating user/assistant turns starting
# with user; collapse repeats and drop empties.
sub _clean_messages {
    my ($self, $msgs, $role_map) = @_;
    my @out;
    for my $m (@$msgs) {
        my $role = $role_map && $role_map->{ $m->{role} }
            ? $role_map->{ $m->{role} } : $m->{role};
        my $content = defined $m->{content} ? $m->{content} : '';
        next unless length $content;
        if (@out && $out[-1]{role} eq $role) {
            $out[-1]{content} .= "\n\n" . $content;
        } else {
            push @out, { role => $role, content => OldAgent::JSON::str($content) };
        }
    }
    unshift @out, { role => 'user', content => OldAgent::JSON::str('(continuing)') }
        if @out && $out[0]{role} ne 'user';
    return \@out;
}

sub _headers {
    my ($self, %a) = @_;
    my %h = ('Content-Type' => 'application/json');
    my $style = defined $a{style} ? $a{style} : 'bearer';
    my $key = $self->{cfg}->get('api_key');
    if (defined $key && length $key) {
        if ($style eq 'anthropic') {
            $h{'x-api-key'} = $key;
            $h{'anthropic-version'} = '2023-06-01';
        } else {
            $h{'Authorization'} = 'Bearer ' . $key;
        }
    }
    return \%h;
}

sub _post {
    my ($self, $url, $payload, %a) = @_;
    my $body = OldAgent::JSON::encode($payload);
    my $r = OldAgent::HTTP::request(
        url     => $url,
        method  => 'POST',
        headers => $self->_headers(style => ($a{style} || 'bearer')),
        body    => $body,
        timeout => $self->{timeout},
        backend => $self->{backend},
        via_proxy => $self->{cfg}->get('proxy'),
        cfg       => $self->{cfg},
    );
    $self->{last_meta} = { %{ $self->{last_meta} },
                           http => $r->{status}, transport => $r->{backend} };
    if ($r->{error} && !$r->{status}) {
        return (undef, "request to $url failed: $r->{error} (via $r->{backend})");
    }
    if ($r->{status} < 200 || $r->{status} > 299) {
        my $detail = OldAgent::Util::clip(OldAgent::Util::one_line($r->{body}), 600);
        $detail = "" if !defined $detail || !length $detail;
        return (undef, $detail
                 ? "request to $url failed (http $r->{status}): $detail"
                 : "request to $url failed (http $r->{status})");
    }
    my ($data, $err) = OldAgent::JSON::parse_ndjson($r->{body});
    if ($err) {
        ($data, $err) = OldAgent::JSON::decode($r->{body});
        if ($err) {
            return (undef, 'model reply was not valid JSON: ' . $err . ' :: '
                         . OldAgent::Util::clip($r->{body}, 400));
        }
    }
    return ($data, undef);
}

# -------------------------------------------------------------- back ends ---

sub _openai {
    my ($self, %a) = @_;
    my $url  = $self->_oa_url('/chat/completions');
    my %payload = (
        model    => $self->{cfg}->get('model'),
        messages => [ { role => 'system',
                        content => OldAgent::JSON::str($a{system}) },
                      @{ $self->_clean_messages($a{messages}) } ],
        stream   => OldAgent::JSON::num(0),
    );
    my $t = $self->{cfg}->get('temperature');
    $payload{temperature} = OldAgent::JSON::num($t) if defined $t && length $t;
    my $mt = $self->{cfg}->get('max_tokens');
    $payload{max_tokens} = OldAgent::JSON::num($mt) if defined $mt && length $mt;

    my ($data, $err) = $self->_post($url, \%payload);
    if ($err && $self->_retry_under_v1($self->{last_meta}{http})) {
        $url = $self->_oa_url('/chat/completions');
        ($data, $err) = $self->_post($url, \%payload);
    }
    return (undef, $err) if $err;
    if (ref($data) eq 'HASH' && ref($data->{error}) eq 'HASH') {
        return (undef, 'api error: ' . ($data->{error}{message} || 'unknown'));
    }
    my $ch = ref($data->{choices}) eq 'ARRAY' ? $data->{choices} : [];
    return (undef, 'no choices in response: ' . OldAgent::Util::clip(OldAgent::JSON::encode($data), 400))
        unless @$ch;
    my $msg = $ch->[0]{message};
    my $text = ref($msg) eq 'HASH' ? $msg->{content} : undef;
    if (!defined $text) {
        $text = $ch->[0]{text};
    }
    if (!defined $text || !length $text) {
        my $reason = ref($msg) eq 'HASH' ? ($msg->{reasoning_content} || '') : '';
        if (length $reason) {
            return (undef, 'the model spent its whole token budget thinking and '
                            . 'produced no reply - raise --max-tokens');
        }
    }
    if (ref($data->{usage}) eq 'HASH') {
        $self->{last_meta}{usage} = $data->{usage};
    }
    return (defined $text ? "$text" : '', undef);
}

sub _ollama {
    my ($self, %a) = @_;
    my $base = $self->{cfg}->get('base_url');
    $base =~ s{/v1$}{};
    my $url = "$base/api/chat";
    my %options;
    my $t = $self->{cfg}->get('temperature');
    $options{temperature} = OldAgent::JSON::num($t) if defined $t && length $t;
    my $mt = $self->{cfg}->get('max_tokens');
    $options{num_predict} = OldAgent::JSON::num($mt) if defined $mt && length $mt;
    # thinking models (qwen3 etc.) honour options.think; most others ignore
    # it, so it is safe to always send for the ollama dialect.  Default is
    # off: thinking burns the token budget and often empties the reply.
    my $think = $self->{cfg}->get('thinking');
    $options{think} = OldAgent::JSON::num(defined $think && $think eq '1' ? 1 : 0);
    my %payload = (
        model    => $self->{cfg}->get('model'),
        # /api/chat has no top-level system field (that is /api/generate):
        # the system prompt goes in as the first message, or the model
        # never learns it has tools
        messages => [ { role => 'system', content => OldAgent::JSON::str($a{system}) },
                      map { { role => $_->{role}, content => $_->{content} } }
                      @{ $self->_clean_messages($a{messages}) } ],
        stream   => OldAgent::JSON::num(0),
    );
    $options{temperature} = OldAgent::JSON::num(0.2) unless %options;
    $payload{options} = \%options;

    my ($data, $err) = $self->_post($url, \%payload);
    return (undef, $err) if $err;
    if (ref($data) eq 'HASH' && defined $data->{error}) {
        return (undef, 'ollama error: ' . $data->{error});
    }
    my $text = ref($data->{message}) eq 'HASH' ? $data->{message}{response} : undef;
    if (!defined $text && ref($data->{message}) eq 'HASH') {
        $text = $data->{message}{content};   # newer ollama builds use content
    }
    $text = $data->{response} unless defined $text;
    return (defined $text ? "$text" : '', undef);
}

sub _anthropic {
    my ($self, %a) = @_;
    my $base = $self->{cfg}->get('base_url');
    my $url  = "$base/v1/messages";
    my %payload = (
        model      => $self->{cfg}->get('model'),
        system     => $a{system},
        messages   => $self->_clean_messages($a{messages}, { tool => 'user' }),
        max_tokens => OldAgent::JSON::num($self->{cfg}->get('max_tokens') || 1024),
    );
    my $t = $self->{cfg}->get('temperature');
    $payload{temperature} = OldAgent::JSON::num($t) if defined $t && length $t;

    my ($data, $err) = $self->_post($url, \%payload, style => 'anthropic');
    return (undef, $err) if $err;
    if (ref($data) eq 'HASH' && ref($data->{error}) eq 'HASH') {
        return (undef, 'api error: ' . ($data->{error}{message} || 'unknown'));
    }
    my @text;
    if (ref($data->{content}) eq 'ARRAY') {
        for my $b (@{ $data->{content} }) {
            next if ref($b) ne 'HASH';
            push @text, $b->{text} if defined $b->{text};
        }
    }
    return (join("\n", @text), undef);
}

sub _exec {
    my ($self, %a) = @_;
    my $cmd = $self->{cfg}->get('exec_cmd');
    my $transcript = _render_plain($a{system}, $a{messages});
    my $r = OldAgent::Util::run_cmd(
        cmd => $cmd, timeout => $self->{timeout}, stdin => $transcript,
    );
    $self->{last_meta} = { %{ $self->{last_meta} }, exit => $r->{exit} };
    if ($r->{killed}) {
        return (undef, "exec provider timed out after $self->{timeout}s");
    }
    if ($r->{exit} != 0) {
        return (undef, "exec provider '$cmd' exited $r->{exit}: "
                     . OldAgent::Util::clip($r->{out}, 400));
    }
    my $out = defined $r->{out} ? $r->{out} : '';
    $out =~ s/\r?\n\z//;
    return ($out, undef);
}

sub _render_plain {
    my ($system, $messages) = @_;
    my $s = "### System:\n$system\n\n";
    for my $m (@$messages) {
        my $role = ucfirst($m->{role} || 'user');
        $s .= "### $role:\n" . OldAgent::JSON::plain($m->{content}) . "\n\n";
    }
    $s .= "### Assistant:\n";
    return $s;
}

sub _echo {
    my ($self, %a) = @_;
    my $script = $ENV{OA_ECHO_SCRIPT};
    if (defined $script && -f $script) {
        my ($data, $err) = OldAgent::Util::slurp($script);
        if (!defined $err) {
            my @parts = split(/^----\n/m, $data);
            my $i = $self->{turns} || 0;
            $self->{turns} = $i + 1;
            return ($i < @parts ? _trim($parts[$i]) : '(echo script exhausted)') if @parts;
        }
    }
    my $last = '';
    for my $m (@{ $a{messages} }) {
        $last = OldAgent::JSON::plain($m->{content}) if $m->{role} eq 'user';
    }
    return ("(echo) you said: " . OldAgent::Util::clip($last, 500), undef);
}

sub _trim {
    my ($s) = @_;
    $s =~ s/\A\n+//;
    $s =~ s/\n+\z//;
    return $s;
}

# ---------------------------------------------------------------- misc ----

sub list_models {
    my ($self) = @_;
    my $kind = $self->kind;
    my $base = $self->{cfg}->get('base_url');

    if ($kind eq 'exec') {
        return (undef, "provider 'exec' has no model list; set model = by hand");
    }
    my $url = $kind eq 'ollama' && $base !~ m{/v1$} ? "$base/api/tags"
                                                       : $self->_oa_url('/models');
    my $style = ($kind eq 'anthropic') ? 'anthropic' : 'bearer';
    my $get = sub {
        OldAgent::HTTP::request(
            url => $_[0], method => 'GET',
            headers => $self->_headers(style => $style),
            timeout => $self->{timeout}, backend => $self->{backend},
            via_proxy => $self->{cfg}->get('proxy'),
            cfg       => $self->{cfg},
        );
    };
    my $r = $get->($url);
    if ($kind ne 'ollama' && $self->_retry_under_v1($r->{status})) {
        $url = $self->_oa_url('/models');
        $r = $get->($url);
    }
    return (undef, "GET $url failed: " . ($r->{error} || "http $r->{status}"))
        if !$r->{status} || $r->{status} < 200 || $r->{status} > 299;
    my ($data, $err) = OldAgent::JSON::decode($r->{body});
    return (undef, "model list was not JSON: $err") if $err;
    my $list = ref($data->{data}) eq 'ARRAY' ? $data->{data}
             : ref($data->{models}) eq 'ARRAY' ? $data->{models}
             : ref($data) eq 'ARRAY' ? $data : [];
    my @names;
    for my $m (@$list) {
        if (ref($m) eq 'HASH') {
            my $n = $m->{id} || $m->{name} || $m->{model};
            push @names, $n if defined $n;
        } elsif (defined $m) {
            push @names, "$m";
        }
    }
    return (\@names, undef);
}

1;
