#!/usr/bin/perl
# Regression: a `code` span (or any styled run) must *close* its style.
# There was a perl precedence trap -- `grep {..} @$tags ? A : B` is parsed
# as `grep {..} (@$tags ? A : B)` so grep returned a *count* (0/1) and a
# bare `0` was printed instead of the \e[0m reset.  Result: everything
# after a code span stayed yellow.
use strict;
use warnings;
use Test::More;
plan tests => 8;   # declared up-front (5.008 Test::More wants it before the first test)
use FindBin;
use lib "$FindBin::RealBin/../lib";
use OldAgent::Textfmt ();

# a code span in the middle of a line
{
    my $m   = 'run a simple `curl` to fetch the page';
    my $out = OldAgent::Textfmt::ansify($m, 1);
    my $open  = () = $out =~ /\x1b\[33m/g;
    my $reset = () = $out =~ /\x1b\[0m/g;
    is($open,  1, 'one code colour opened');
    cmp_ok($reset, '>=', 1, 'the code colour is closed');
    like($out, qr/\x1b\[33mcurl\x1b\[0m/, 'code span opens and closes tightly');
    my $after = $out; $after =~ s/.*\x1b\[33mcurl\x1b\[0m//;
    unlike($after, qr/\x1b\[\d/, 'no style leaks past the code span');
}

# bold + italic + code all close
{
    my $m   = '**bold** *it* `code` plain';
    my $out = OldAgent::Textfmt::ansify($m, 1);
    my @esc   = $out =~ /\x1b\[(\d+(?:;\d+)*)m/g;
    my $opens  = grep { $_ ne '0' } @esc;   # style opens (code != 0)
    my $resets = grep { $_ eq '0' } @esc;   # the \e[0m resets
    is($resets, $opens, 'every colour open has a matching reset');
    my $tail = $out; $tail =~ s/.*(?<=\x1b\[0m)//;
    unlike($tail, qr/\x1b\[/, 'text after the last span is unstyled');
}

# no stray bare digits where a reset should be (the original symptom)
{
    my $m   = 'a `b` c';
    my $out = OldAgent::Textfmt::ansify($m, 1);
    unlike($out, qr/(?<!\x1b)(?<![0-9])0(?![\x1b])\s*$/m, 'no trailing bare 0');
}

# off -> untouched
{
    my $m = 'a `b` c';
    is(OldAgent::Textfmt::ansify($m, 0), $m, 'off is a no-op');
}

