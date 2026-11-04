package OldAgent::Protocol;
# The wire format between oldagent and any model, including models that have
# never heard of function calling.  A tool call is a fenced block tagged
# `tool` holding one JSON object.  Results come back as `result` blocks.
#
#   ```tool
#   {"tool":"bash","args":{"cmd":"ls -l"}}
#   ```
#
# Parsing is deliberately forgiving: ```json, ~~~ fences, unterminated
# fences, prose around the block, and a bare `TOOL: {...}` line all work.

use strict;
use warnings;

use OldAgent::JSON ();

my %TAGS = (tool => 1, oldagent => 1, oa => 1, json => 1, '' => 1);

sub parse {
    my ($text) = @_;
    my @calls;
    return \@calls unless defined $text && length $text;

    for my $block (_fenced_blocks($text)) {
        next unless $TAGS{ $block->{tag} };
        for my $obj (OldAgent::JSON::extract_objects($block->{body})) {
            my ($val, $err) = OldAgent::JSON::decode_lenient($obj);
            next if $err || ref($val) ne 'HASH';
            push @calls, _normalize($val);
        }
    }
    for my $line (split(/\n/, $text)) {
        next unless $line =~ /^\s*(?:TOOL|OA|oldagent)\s*:\s*(\{.*\})\s*$/;
        my ($val, $err) = OldAgent::JSON::decode_lenient($1);
        next if $err || ref($val) ne 'HASH';
        push @calls, _normalize($val);
    }
    # bare objects, no fence and no TOOL: prefix: some models ignore the
    # fence instruction and emit the JSON on its own (sometimes with an
    # extra trailing brace). any object that decodes to a {tool, ...}
    # shape is a call. extract_objects brace-matches, so stray braces
    # after the object close do not break it.
    for my $obj (OldAgent::JSON::extract_objects($text)) {
        my ($val, $err) = OldAgent::JSON::decode_lenient($obj);
        next if $err || ref($val) ne 'HASH';
        my $c = _normalize($val);
        next unless length $c->{tool};
        push @calls, $c;
    }

    my %seen;
    my @uniq;
    for my $c (@calls) {
        my $key = $c->{tool} . "\0" . OldAgent::JSON::encode($c->{args});
        next if $seen{$key}++;
        push @uniq, $c;
    }
    return \@uniq;
}

sub _normalize {
    my ($h) = @_;
    my %c = (tool => undef, args => {}, raw => $h);
    for my $k ('tool', 'name', 'action', 'command') {
        if (defined $h->{$k} && !ref $h->{$k}) {
            $c{tool} = lc("$h->{$k}");
            last;
        }
    }
    for my $k ('args', 'arguments', 'input', 'params', 'parameters') {
        if (ref($h->{$k}) eq 'HASH') {
            $c{args} = $h->{$k};
            last;
        }
    }
    if (!ref($c{args}) || keys %{$c{args}} == 0) {
        # flat form: {"tool":"read","path":"x"}
        my %flat;
        for my $k (keys %$h) {
            next if $k =~ /^(?:tool|name|action|command|args|arguments|input|params|parameters)$/;
            $flat{$k} = $h->{$k};
        }
        $c{args} = \%flat if !keys %{ $c{args} } && %flat;
    }
    $c{tool} = '' unless defined $c{tool};
    return \%c;
}

# Returns a list of { tag => 'tool', body => '...' } in document order.
sub _fenced_blocks {
    my ($text) = @_;
    my @blocks;
    my @lines = split(/\n/, $text, -1);
    my $in;
    my $marker;
    my @buf;
    for my $l (@lines) {
        if (!defined $in) {
            if ($l =~ /^\s*(```+|~~~+)\s*([A-Za-z0-9_+-]*)\s*$/) {
                $in     = lc($2);
                $marker = $1;
                @buf    = ();
            }
        } else {
            if ($l =~ /^\s*\Q$marker\E\s*$/) {
                push @blocks, { tag => $in, body => join("\n", @buf) };
                $in = undef;
                @buf = ();
            } else {
                push @buf, $l;
            }
        }
    }
    push @blocks, { tag => $in, body => join("\n", @buf) } if defined $in;
    return @blocks;
}

# results: list of { tool, ok, output } -> one user message body
sub results_block {
    my ($results) = @_;
    my @lines;
    for my $r (@$results) {
        my %o = (
            tool   => $r->{tool},
            ok     => $r->{ok} ? OldAgent::JSON::num(1) : OldAgent::JSON::num(0),
            output => OldAgent::JSON::str(defined $r->{output} ? $r->{output} : ''),
        );
        $o{args} = $r->{args} if $r->{echo_args};
        push @lines, OldAgent::JSON::encode(\%o);
    }
    return "```result\n" . join("\n", @lines) . "\n```";
}

sub tool_error {
    my ($call, $msg) = @_;
    return {
        tool   => ($call->{tool} || '?'),
        ok     => 0,
        output => $msg,
    };
}

1;
