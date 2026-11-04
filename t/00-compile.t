use strict;
use warnings;
use lib 't';
use Test::More;
use File::Find ();

# every shipped file must compile with nothing but core perl
my @files = ('oa');
File::Find::find({
    wanted => sub { push @files, $File::Find::name if /\.pm$/ },
    no_chdir => 0,
}, 'lib');

plan tests => scalar(@files);

my $perl = $^X;
for my $f (@files) {
    my $out = `$perl -Ilib -c $f 2>&1`;
    like($out, qr/syntax OK/, "$f compiles");
}
