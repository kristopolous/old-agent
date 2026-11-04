#!/usr/bin/env perl
# compat-lint - keep oldagent loadable by a perl from around 2000.
#
# It is a linter, not a proof: it looks for syntax and library use that did
# not exist in perl 5.006, plus things that only became core in 5.8/5.10+.
# Literals are scrubbed first so that s///, strings, and regexes do not
# produce phantom hits.  Run it with `make lint`.

use strict;
use warnings;
use File::Find ();
use File::Spec ();

my @RULES = (
    [qr/\bsay\s/,              'say() is 5.010+',                    1],
    [qr/\bstate\s+\w/,         'state variables are 5.010+',         1],
    [qr/\/\/(?!=)/,            'defined-or // is 5.010+',            1],
    [qr/~~/,                   'smartmatch is 5.010+',               1],  # no lint
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
        return if $File::Find::dir =~ m{(?:^|/)(?:\.git|blib|tmp)$};
        return unless /\.(pm|pl|t)$/ || $_ eq 'oa';
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
    my $in_pod = 0;
    my $heredoc;
    my $n      = 0;
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

        my $code = _scrub($line);

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

# Replace string/regex literals with placeholders so the rules above only
# see real code.
sub _scrub {
    my ($s) = @_;
    # split(//, $x) is the null-split idiom, not defined-or
    $s =~ s{(\bsplit\s*\(?\s*)//\s*\)?}{$1SPLITNULL}g;
    my $out  = '';
    my $i    = 0;
    my $len  = length($s);
    my $prev = ' ';
    while ($i < $len) {
        my $c = substr($s, $i, 1);

        # comment
        if ($c eq '#' && ($prev =~ /[\s(,;{]/ || $i == 0)) { last }

        if ($c eq "'" || $c eq '"' || $c eq '`') {
            $i = _skip_quote($s, $i, $c);
            $out .= ' X ';
            $prev = 'X';
            next;
        }

        # quote-like operators: s/// m// tr/// qr// q() qw()
        if ($prev =~ /^[\s;({=~&|!,]$/ && substr($s, $i) =~ /^\b(s|tr|m|y|qr|qw|q|qx)\s*([^\w\s])/) {
            my $op   = $1;
            my $dpos = $i + length($op);
            while ($dpos < $len && substr($s, $dpos, 1) =~ /\s/) { $dpos++ }
            my $d = substr($s, $dpos, 1);
            my $j = _skip_delim($s, $dpos + 1, $d);
            if ($op eq 's' || $op eq 'tr' || $op eq 'y') {
                $j = _skip_delim($s, $j, $d);
            }
            while ($j < $len && substr($s, $j, 1) =~ /[a-z]/) { $j++ }
            $out .= ' RE ';
            $prev = 'E';
            $i    = $j;
            next;
        }

        $out .= $c;
        $prev = $c;
        $i++;
    }
    return $out;
}

sub _skip_quote {
    my ($s, $i, $q) = @_;
    my $len = length($s);
    $i++;
    while ($i < $len) {
        my $c = substr($s, $i, 1);
        if ($c eq "\\") { $i += 2; next }
        if ($c eq $q)   { return $i + 1 }
        $i++;
    }
    return $len;
}

# Walk past one delimited pattern that started just after delimiter $d.
sub _skip_delim {
    my ($s, $i, $d) = @_;
    my $len = length($s);
    return $i if $i > $len;
    my %pair = ('{' => '}', '(' => ')', '[' => ']', '<' => '>');
    my $close = exists $pair{$d} ? $pair{$d} : $d;
    my $nested = ($close ne $d) ? 1 : 0;
    my $depth = 1;
    while ($i < $len) {
        my $c = substr($s, $i, 1);
        if ($c eq "\\") { $i += 2; next }
        if ($nested) {
            $depth++ if $c eq $d;
            if ($c eq $close) {
                $depth--;
                return $i + 1 if $depth == 0;
            }
            $i++;
            next;
        }
        return $i + 1 if $c eq $close;
        $i++;
    }
    return $len;
}
