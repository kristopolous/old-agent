# the Commands-menu dialog path (open dialog from the main loop, answer
# it, have it applied and remembered) - the scenario that used to crash
# the desktop with "Modification of a read-only value attempted".
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
my $script = "$FindBin::RealBin/../util/desktop-dialog.pl";
my $out = `timeout 90 $xvfb -a $perl $script 2>&1`;
my $code = $? >> 8;
is($code, 0, 'menu dialog path (open, answer, persist) under xvfb') or diag($out);
done_testing();
