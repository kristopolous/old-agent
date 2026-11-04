use strict;
use warnings;
use lib 'lib';
use Test::More;
use File::Spec ();
use OldAgent::Util;

plan tests => 6;

my $lint = File::Spec->catfile('util', 'compat-lint.pl');

my $out = `$^X '$lint' 2>&1`;
my $rc  = $?;
is($rc, 0, 'compat-lint passes on the shipped code') or diag $out;
like($out, qr/nothing newer than perl 5\.006/, 'clean report');

# the linter has to actually catch things, or it is decoration
my $dir = File::Spec->catdir(OldAgent::Util::tmpdir(), "oa-lint-$$");
mkdir $dir;
OldAgent::Util::spew(File::Spec->catfile($dir, 'bad.pm'), <<'EOPERL');
package Bad;
use strict;
use warnings;
use List::Util qw(first);
sub x {
    my ($a, $b) = @_;
    say "hi";
    my $c = $a // $b;
    return $c;
}
1;
EOPERL

$out = `$^X '$lint' '$dir' 2>&1`;
$rc = $?;
isnt($rc, 0, 'bad code is rejected');
like($out, qr/say\(\) is 5\.010/, 'catches say');
like($out, qr/defined-or/, 'catches defined-or');
like($out, qr/List::Util/, 'catches non-core modules');

rmdir $dir;
