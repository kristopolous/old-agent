# the Tk desktop needs an X server; run under xvfb when available, skip
# otherwise (the terminal interface is the default and is covered fully
# by the other tests).
use strict;
use warnings;
use Test::More;
use FindBin;

my $have_tk = eval { require Tk; 1 };
my @xvfb = map { "$_/xvfb-run" } split /:/, ($ENV{PATH} || '');
my $xvfb = (grep { -x $_ } @xvfb)[0];

plan skip_all => 'Tk not installed' unless $have_tk;
plan skip_all => 'no xvfb-run (install xvfb to test the desktop)' unless $xvfb;

my $perl = $^X;
my $script = "$FindBin::RealBin/../util/desktop-smoke.pl";
my $out = `timeout 90 $xvfb -a $perl $script 2>&1`;
my $code = $? >> 8;
is($code, 0, 'desktop smoke under xvfb') or diag($out);
done_testing();
