package OldAgent::JSON;
# A small, strict-enough JSON encoder/decoder written for old perls.
# Byte oriented: strings are UTF-8 bytes, never decoded to characters.
# No dependencies (JSON.pm / JSON::PP are not available on 2000-era perls).

use strict;
use warnings;

# Numbers must be marked.  Perl scalars from the year 2000 carry no type
# flags we can read portably, so encode() quotes every plain scalar and
# num() is how you ask for a real JSON number.
sub num { return bless \(my $n = $_[0] + 0), 'OldAgent::JSON::Num' }
sub str { return bless \(my $s = defined $_[0] ? $_[0] : ''), 'OldAgent::JSON::Str' }

# Turn anything back into plain text (undo num/str wrappers).
sub plain {
    my ($v) = @_;
    return '' unless defined $v;
    my $r = ref($v);
    return $$v if $r eq 'OldAgent::JSON::Num' || $r eq 'OldAgent::JSON::Str';
    return $r ? "$v" : $v;
}

# ---------------------------------------------------------------- encode ---

sub encode {
    my ($v) = @_;
    return _enc($v, 0);
}

sub _is_number_text {
    my ($s) = @_;
    return 0 unless defined $s;
    return 0 unless $s =~ /^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?$/;
    return $s eq sprintf('%s', $s + 0) ? 1 : 0;
}

sub _enc {
    my ($v, $depth) = @_;
    return 'null' unless defined $v;
    return 'null' if $depth > 60;

    my $r = ref($v);
    if ($r) {
        if ($r eq 'OldAgent::JSON::Num') {
            my $n = $$v;
            return _is_number_text("$n") ? "$n" : '0';
        }
        if ($r eq 'OldAgent::JSON::Str') {
            return _enc_str($$v);
        }
        if ($r eq 'HASH') {
            my @keys = sort keys %$v;
            my @parts;
            for my $k (@keys) {
                push @parts, _enc_str($k) . ':' . _enc($v->{$k}, $depth + 1);
            }
            return '{' . join(',', @parts) . '}';
        }
        if ($r eq 'ARRAY') {
            my @parts = map { _enc($_, $depth + 1) } @$v;
            return '[' . join(',', @parts) . ']';
        }
        if ($r eq 'SCALAR' || $r eq 'REF') {
            return _enc($$v, $depth + 1);
        }
        if ($r eq 'JSON::PP::Boolean' || $r eq 'Types::Serialiser::Boolean') {
            return $v ? 'true' : 'false';
        }
        # blessed / coderef / glob: stringify it
        return _enc_str("$v");
    }

    return _enc_str($v);
}

sub _enc_str {
    my ($s) = @_;
    $s = '' unless defined $s;
    my $out = '"';
    my @chars = split(//, $s);
    for my $c (@chars) {
        my $o = ord($c);
        if    ($c eq '"')  { $out .= '\\"' }
        elsif ($c eq '\\') { $out .= '\\\\' }
        elsif ($c eq "\n") { $out .= '\\n' }
        elsif ($c eq "\r") { $out .= '\\r' }
        elsif ($c eq "\t") { $out .= '\\t' }
        elsif ($o == 8)    { $out .= '\\b' }
        elsif ($o == 12)   { $out .= '\\f' }
        elsif ($o < 32)    { $out .= sprintf('\\u%04x', $o) }
        else               { $out .= $c }
    }
    $out .= '"';
    return $out;
}

# ---------------------------------------------------------------- decode ---

sub decode {
    my ($text) = @_;
    return (undef, 'empty input') unless defined $text && length $text;
    my $pos = 0;
    my $len = length($text);
    _skip_ws(\$text, \$pos, \$len);
    my ($val, $err) = _value(\$text, \$pos, \$len);
    return ($val, $err) if $err;
    _skip_ws(\$text, \$pos, \$len);
    return (undef, "trailing data at offset $pos") if $pos < $len;
    return ($val, undef);
}

sub _skip_ws {
    my ($t, $p, $len) = @_;
    while ($$p < $$len) {
        my $c = substr($$t, $$p, 1);
        last unless $c eq ' ' || $c eq "\t" || $c eq "\n" || $c eq "\r";
        $$p++;
    }
}

sub _value {
    my ($t, $p, $len) = @_;
    _skip_ws($t, $p, $len);
    return (undef, 'unexpected end of input') if $$p >= $$len;
    my $c = substr($$t, $$p, 1);

    if ($c eq '{') { return _object($t, $p, $len) }
    if ($c eq '[') { return _array($t, $p, $len) }
    if ($c eq '"') { return _string($t, $p, $len) }

    if (substr($$t, $$p, 4) eq 'true')  { $$p += 4; return (1, undef) }
    if (substr($$t, $$p, 5) eq 'false') { $$p += 5; return (0, undef) }
    if (substr($$t, $$p, 4) eq 'null')  { $$p += 4; return (undef, undef) }

    if ($c =~ /[-0-9]/) {
        if (substr($$t, $$p) =~ /^(-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?)/) {
            my $n = $1;
            $$p += length($n);
            return ($n + 0, undef);
        }
        return (undef, "bad number at offset $$p");
    }
    return (undef, "unexpected character '$c' at offset $$p");
}

sub _object {
    my ($t, $p, $len) = @_;
    my %h;
    $$p++;    # {
    _skip_ws($t, $p, $len);
    if ($$p < $$len && substr($$t, $$p, 1) eq '}') { $$p++; return (\%h, undef) }
    while (1) {
        _skip_ws($t, $p, $len);
        return (undef, 'unterminated object') if $$p >= $$len;
        return (undef, 'object key must be a string') if substr($$t, $$p, 1) ne '"';
        my ($k, $err) = _string($t, $p, $len);
        return (undef, $err) if $err;
        _skip_ws($t, $p, $len);
        return (undef, "expected ':' after key at offset $$p")
            if $$p >= $$len || substr($$t, $$p, 1) ne ':';
        $$p++;
        my ($v, $e2) = _value($t, $p, $len);
        return (undef, $e2) if $e2;
        $h{$k} = $v;
        _skip_ws($t, $p, $len);
        return (undef, 'unterminated object') if $$p >= $$len;
        my $c = substr($$t, $$p, 1);
        if ($c eq ',') { $$p++; next }
        if ($c eq '}') { $$p++; return (\%h, undef) }
        return (undef, "expected ',' or '}' at offset $$p");
    }
}

sub _array {
    my ($t, $p, $len) = @_;
    my @a;
    $$p++;    # [
    _skip_ws($t, $p, $len);
    if ($$p < $$len && substr($$t, $$p, 1) eq ']') { $$p++; return (\@a, undef) }
    while (1) {
        my ($v, $err) = _value($t, $p, $len);
        return (undef, $err) if $err;
        push @a, $v;
        _skip_ws($t, $p, $len);
        return (undef, 'unterminated array') if $$p >= $$len;
        my $c = substr($$t, $$p, 1);
        if ($c eq ',') { $$p++; next }
        if ($c eq ']') { $$p++; return (\@a, undef) }
        return (undef, "expected ',' or ']' at offset $$p");
    }
}

my %ESC = ('"' => '"', '\\' => '\\', '/' => '/', 'b' => "\x08",
           'f' => "\x0c", 'n' => "\n", 'r' => "\r", 't' => "\t");

sub _string {
    my ($t, $p, $len) = @_;
    $$p++;    # opening quote
    my $out = '';
    while (1) {
        return (undef, 'unterminated string') if $$p >= $$len;
        my $c = substr($$t, $$p, 1);
        if ($c eq '"') { $$p++; return ($out, undef) }
        if ($c eq "\\") {
            $$p++;
            return (undef, 'bad escape') if $$p >= $$len;
            my $e = substr($$t, $$p, 1);
            if ($e eq 'u') {
                my $hex = substr($$t, $$p + 1, 4);
                return (undef, 'bad \\u escape') if length($hex) < 4 || $hex !~ /^[0-9a-fA-F]{4}$/;
                $$p += 5;
                my $cp = hex($hex);
                if ($cp >= 0xD800 && $cp <= 0xDBFF
                    && substr($$t, $$p, 2) eq '\\u') {
                    my $hex2 = substr($$t, $$p + 2, 4);
                    if (length($hex2) == 4 && $hex2 =~ /^[0-9a-fA-F]{4}$/) {
                        my $lo = hex($hex2);
                        if ($lo >= 0xDC00 && $lo <= 0xDFFF) {
                            $cp = 0x10000 + (($cp - 0xD800) << 10) + ($lo - 0xDC00);
                            $$p += 6;
                        }
                    }
                }
                $out .= _utf8_bytes($cp);
                next;
            }
            return (undef, "bad escape \\$e") unless exists $ESC{$e};
            $out .= $ESC{$e};
            $$p++;
            next;
        }
        $out .= $c;
        $$p++;
    }
}

sub _utf8_bytes {
    my ($cp) = @_;
    if ($cp < 0x80)     { return chr($cp) }
    if ($cp < 0x800)    { return chr(0xC0 | ($cp >> 6)) . chr(0x80 | ($cp & 0x3F)) }
    if ($cp < 0x10000)  {
        return chr(0xE0 | ($cp >> 12)) . chr(0x80 | (($cp >> 6) & 0x3F))
             . chr(0x80 | ($cp & 0x3F));
    }
    return chr(0xF0 | ($cp >> 18)) . chr(0x80 | (($cp >> 12) & 0x3F))
         . chr(0x80 | (($cp >> 6) & 0x3F)) . chr(0x80 | ($cp & 0x3F));
}

# ------------------------------------------------------- lenient scanning ---

# Pull balanced {...} objects out of arbitrary text (model replies often
# carry prose, bad fences, or trailing commas).  Returns a list of strings.
sub extract_objects {
    my ($text) = @_;
    my @found;
    return @found unless defined $text;
    my $len = length($text);
    my $i = 0;
    while ($i < $len) {
        my $open = index($text, '{', $i);
        last if $open < 0;
        my ($end, $depth) = (-1, 0);
        my $in_str = 0;
        my $esc = 0;
        for (my $j = $open; $j < $len; $j++) {
            my $c = substr($text, $j, 1);
            if ($in_str) {
                if ($esc)        { $esc = 0 }
                elsif ($c eq '\\') { $esc = 1 }
                elsif ($c eq '"') { $in_str = 0 }
                next;
            }
            if    ($c eq '"') { $in_str = 1 }
            elsif ($c eq '{') { $depth++ }
            elsif ($c eq '}') {
                $depth--;
                if ($depth == 0) { $end = $j; last }
            }
        }
        if ($end < 0) { $i = $open + 1; next }
        push @found, substr($text, $open, $end - $open + 1);
        $i = $end + 1;
    }
    return @found;
}

# Decode one object, repairing the most common model mistakes.
sub decode_lenient {
    my ($text) = @_;
    my ($val, $err) = decode($text);
    return ($val, undef) unless $err;
    my $try = $text;
    $try =~ s/,(\s*[}\]])/$1/g;               # trailing commas
    $try =~ s/^\s*//;
    ($val, $err) = decode($try);
    return ($val, undef) unless $err;
    return (undef, $err);
}
# Some endpoints (notably qwen/ollama with thinking models) return NDJSON --
# a series of JSON objects one per line, even when stream:false is requested.
# parse_ndjson decodes each line and concatenates message.content so the
# caller gets the full reply.  For a single object it behaves like decode.
sub parse_ndjson {
    my ($text) = @_;
    return (undef, 'empty input') unless defined $text && length $text;
    my @lines = split(/\n+/, $text, -1);
    my ($last, $content, $count) = (undef, '', 0);
    for my $line (@lines) {
        next if $line =~ /^\s*$/;
        next unless $line =~ /^\s*[\{\[]/;
        my ($o, $e) = decode_lenient($line);
        next if $e || ref($o) ne 'HASH';
        $last = $o;
        $count++;
        my $c = (ref $o->{message} eq 'HASH' && defined $o->{message}{content})
              ? $o->{message}{content} : undef;
        # thinking models (deepseek-r1, qwen3) may put the reply in `thinking`
        # with content empty; fall back so the text is not lost.
        if (!defined $c && ref $o->{message} eq 'HASH' && defined $o->{message}{thinking}) {
            $c = $o->{message}{thinking};
        }
        $content .= $c if defined $c;
    }
    return (undef, 'no JSON objects found') unless $count;
    return ($last, undef) if $count == 1;
    if (ref $last->{message} eq 'HASH') {
        $last->{message}{content} = $content;
    } else {
        $last->{message} = { role => 'assistant', content => $content };
    }
    $last->{_oa_content} = $content;
    return ($last, undef);
}

1;