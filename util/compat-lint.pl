#!/usr/bin/env perl
# compat-lint - keep oldagent loadable by a perl from around 2000.
#
# It is a linter, not a proof: it looks for syntax and library use that did
# not exist in perl 5.006, plus things that only became core in 5.8/5.10+.
# Literals are scrubbed first so that s///, strings, and regexes do not
# produce phantom hits.  A delimited quote-like that is left open at the end
# of a line (a multi-line qr{...}x, for example) is carried across lines, so
# the ~~ inside a strikeout pattern is not mistaken for the 5.010 smartmatch
# operator.  Run it with `make lint`.

use strict;
use warnings;
use File::Find ();
use File::Spec ();

my @RULES = (
    [qr/GetOptionsFromArray/,  'GetOptionsFromArray is 5.010+',      1],
    [qr/done_testing\s*\(/,    'Test::More::done_testing is 5.011+',  1],
    [qr/%[ \t]+%\{/,           'stray % before %{ deref (5.008 parse error)', 1],
    [qr/\bsay\s/,              'say() is 5.010+',                    1],
    [qr/\bstate\s+\w/,         'state variables are 5.010+',         1],
    [qr/\/\/(?!=)/,            'defined-or // is 5.010+',            1],
    [qr/~~/,                   'smartmatch is 5.010+',               1],
    [qr/\bgiven\s*\(/,         'given/when is 5.010+',               1],
    [qr/\bwhen\s*\(/,          'given/when is 5.010+',               1],
    [qr/\.\.\.(?!\.)/,         'yada-yada ... is 5.012+',            1],
    [qr/->[\@\$\%]\*/,         'postfix dereference is 5.020+',      1],
    [qr/->\*\{/,               'block dereference is 5.020+',        1],
    [qr/\btry\s*\{/,           'try blocks are 5.034+',              1],
    [qr/\bcatch\s*\(/,         'try/catch is 5.034+',                1],
    [qr/\bsub\s+\w+\s*\(/,     'sub signatures are 5.020+',          1],
    [qr/\bsub\s+\w+\s*:/,      'sub attributes need a newer perl',   1],
    [qr/\buse\s+v?5\.0*(?:[1-9][0-9])\d*\s*;/, 'needs perl newer than 5.006', 1],
    [qr/\buse\s+(?:feature|experimental|builtin|utf8|autobox)\b/, 'modern pragma', 1],
    [qr/\bpackage\s+[\w:]+\s+[\w:]+.*\{/, 'package with version/block is 5.012+', 1],
    [qr/\?\->/,                'optional chaining is 5.036+',        1],
    [qr/\bclass\s+\w+\s*\{/,   'class syntax is 5.020+',             1],
    [qr/\bour\s/,              'our() works in 5.006 but prefer file my', 0],
);

# modules that were not in perl 5.006 core
my %LATE = (
    'List::Util'      => '5.008 core',
    'Scalar::Util'    => '5.008 core',
    'Time::HiRes'     => '5.008 core',
    'File::Temp'      => '5.008 core (5.006.1 only)',
    'Encode'          => '5.008 core',
    'MIME::Base64'    => '5.008 core',
    'Storable'        => 'not guaranteed on old builds',
    'JSON'            => 'never core; oldagent has its own',
    'JSON::PP'        => '5.014 core; oldagent has its own',
    'Path::Tiny'      => 'CPAN only',
    'Try::Tiny'       => 'CPAN only',
    'Moo'             => 'CPAN only',
    'Moose'           => 'CPAN only',
    'LWP::UserAgent'  => 'dropped from core in 5.014; keep optional',
    'HTTP::Tiny'      => '5.014 core; keep optional',
    'IO::Socket::SSL' => 'CPAN only; keep optional',
    'Net::SSLeay'     => 'CPAN only; keep optional',
);

# allowed as long as the code only reaches for them inside eval { require }
my %OPTIONAL = map { $_ => 1 } qw(HTTP::Tiny IO::Socket::SSL Net::SSLeay LWP::UserAgent);

my @files;
File::Find::find({
    wanted => sub {
        return unless -f $_;
        # skip build-artifact dirs in the project tree (blib, .git)
        return if $File::Find::dir =~ m{(^|/)(?:\.git|blib)(?:/|$)};
        # skip project-root tmp/ but NOT the system /tmp/ (absolute)
        return if $File::Find::dir !~ m{^/} && $File::Find::dir =~ m{^tmp/};
        return unless /\.(pm|pl|t)$/ || $_ eq 'oa';
        return if $File::Find::name =~ /compat-lint\.pl$/;   # the linter is not linted
        push @files, $File::Find::name;
    },
}, @ARGV ? @ARGV : ('.'));

my $problems = 0;
my $shown    = 0;
for my $file (sort @files) {
    my $fh;
    open($fh, '<', $file) or do { print "cannot read $file: $!\n"; next };
    my @lines = <$fh>;
    close($fh);

    my $in_pod  = 0;
    my $heredoc;
    my $carry;                 # a quote-like left open on a previous line
    my $n       = 0;

    for my $raw (@lines) {
        $n++;
        my $line = $raw;
        chomp($line);

        if (defined $heredoc) {
            $heredoc = undef if $line =~ /^$heredoc$/;
            next;
        }
        next if $line =~ /no lint/;
        if ($line =~ /^=\w/) { $in_pod = $in_pod ? 0 : 1; next }
        next if $in_pod;
        next if $line =~ /^\s*(?:#|$)/;

        # resume a literal that a previous line left open
        my $start = 0;
        if ($carry) {
            my $end = _find_close($line, 0, $carry);
            if (!defined $end) { next }        # whole line is still the literal
            $start = $end;
            $carry = undef;
        }

        my ($code, $open) = _scrub($line, $start);
        $carry = $open if $open;

        # remember heredocs so their text (usage strings full of URLs) is skipped
        if ($line =~ /<<\s*['"`]?(\w+)['"`]?/) {
            my $term = $1;
            $heredoc = $term unless $line =~ /\b$term\b\s*[;)]?\s*$/;
        }

        if ($code =~ /^\s*(?:use|require)\s+((?:[A-Z]\w*::)*[A-Z]\w*)/) {
            my $mod = $1;
            next if $mod =~ /^OldAgent/;
            if ($LATE{$mod} && !$OPTIONAL{$mod}) {
                print "$file:$n: module $mod is $LATE{$mod}\n";
                $problems++;
            }
            if ($OPTIONAL{$mod} && $line !~ /require/) {
                print "$file:$n: $mod is $LATE{$mod} - load it with eval { require ... }\n";
                $problems++;
            }
        }

        for my $r (@RULES) {
            my ($re, $msg, $fatal) = @$r;
            next unless $code =~ $re;
            my $c = $line;
            $c =~ s/^\s+//;
            print "$file:$n: $msg\n    $c\n";
            $problems++ if $fatal;
            $shown++;
        }
    }
}

if ($problems) {
    print "\n$problems compatibility problem(s) in " . scalar(@files) . " file(s)\n";
    exit 1;
}
print "compat-lint: " . scalar(@files) . " file(s), nothing newer than perl 5.006 found\n";
exit 0;

# ---------------------------------------------------------------- scrubber

# Paired delimiters.
my %PAIR = ('{' => '}', '(' => ')', '[' => ']', '<' => '>');

# Walk forward from $i looking for the close of an open literal described by
# $st = { open => $o, close => $c, same => bool }.  Returns the index just past
# the close, or undef if it is still open at end of line.  Handles backslash
# escapes and, for paired delimiters, nesting.
sub _find_close {
    my ($s, $i, $st) = @_;
    my $len = length($s);
    my $open  = $st->{open};
    my $close = $st->{close};
    my $depth = $st->{depth} || 1;
    while ($i < $len) {
        my $c = substr($s, $i, 1);
        if ($c eq "\\") { $i += 2; next }
        if ($st->{same}) {
            return $i + 1 if $c eq $close;
            $i++;
            next;
        }
        $depth++ if $c eq $open;
        if ($c eq $close) {
            $depth--;
            return $i + 1 if $depth == 0;
        }
        $i++;
    }
    $st->{depth} = $depth;
    return undef;
}

# Turn one line of code into a placeholder-scrubbed string.  Returns
# ($cleaned, $open_state_or_undef).  $start is where to begin (after a
# carried-over literal close).
sub _scrub {
    my ($s, $start) = @_;
    $start ||= 0;

    # split(//, $x) is the null-split idiom, not defined-or
    $s =~ s{(\bsplit\s*\(?\s*)//\s*\)?}{$1SPLITNULL}g;

    my $out  = substr($s, 0, $start);
    my $i    = $start;
    my $len  = length($s);
    my $prev = $start ? substr($s, $start - 1, 1) : ' ';

    while ($i < $len) {
        my $c = substr($s, $i, 1);

        # a comment runs to end of line; nothing after it is code
        if ($c eq '#' && ($prev =~ /[\s(,;{]/ || $i == 0)) { last }

        # quoted string: single, double, backtick
        if ($c eq "'" || $c eq '"' || $c eq '`') {
            $i = _skip_quote($s, $i, $c);
            $out .= ' X ';
            $prev = 'X';
            next;
        }

        # quote-like operators: s/// m// tr/// y/// qr// q() qw() qx()
        if ($prev =~ /^[\s;({=~&|!,]$/ && substr($s, $i) =~ /^\b(s|tr|m|y|qr|qw|q|qx)\s*([^\w\s])/) {
            my $op    = $1;
            my $dpos  = $i + length($op);
            while ($dpos < $len && substr($s, $dpos, 1) =~ /\s/) { $dpos++ }
            my $d     = substr($s, $dpos, 1);
            my $after = $dpos + 1;

            my $st;
            if (exists $PAIR{$d}) {
                $st = { open => $d, close => $PAIR{$d}, same => 0, depth => 1 };
            }
            else {
                $st = { open => $d, close => $d, same => 1, depth => 1 };
            }

            my $j = _find_close($s, $after, $st);
            if (!defined $j) { return ($out, $st) }        # spans to next line

            # s///, tr///, y/// have a second (replacement) section; for an
            # empty replacement its closing delimiter sits exactly at $j
            if ($op eq 's' || $op eq 'tr' || $op eq 'y') {
                my $st2 = exists $PAIR{$d}
                    ? { open => $d, close => $PAIR{$d}, same => 0, depth => 1 }
                    : { open => $d, close => $d, same => 1, depth => 1 };
                my $j2 = _find_close($s, $j, $st2);
                if (!defined $j2) { return ($out, $st2) }
                $j = $j2;
            }

            while ($j < $len && substr($s, $j, 1) =~ /[a-z]/) { $j++ }   # flags
            $out .= ' RE ';
            $prev = 'E';
            $i    = $j;
            next;
        }

        $out .= $c;
        $prev = $c;
        $i++;
    }
    return ($out, undef);
}

sub _skip_quote {
    my ($s, $i, $q) = @_;
    my $len = length($s);
    $i++;
    while ($i < $len) {
        my $c = substr($s, $i, 1);
        if ($c eq "\\") { $i += 2; next }
        return $i + 1 if $c eq $q;
        $i++;
    }
    return $len;
}
