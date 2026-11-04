# line history is saved to a plain text file so a fresh session recalls
# previous `oa> ` lines with the up arrow.
use strict;
use warnings;
use Test::More;
plan tests => 10;  # declared up-front (5.008 Test::More wants it before the first test)
use lib 'lib';
use OldAgent::Config ();
use OldAgent::Term ();

my $dir = "/tmp/oa-hist-$$";
mkdir($dir) unless -d $dir;
my $hf = "$dir/history";
$ENV{OLDAGENT_HISTORY} = $hf;

# ---- history_path ---------------------------------------------------
is(OldAgent::Config::history_path(), $hf, 'OLDAGENT_HISTORY is honoured');
delete $ENV{OLDAGENT_HISTORY};
$ENV{OLDAGENT_CONFIG} = "$dir/rc";
like(OldAgent::Config::history_path(), qr{^$dir/history$},
    'default is next to the config file');
delete $ENV{OLDAGENT_CONFIG};

# ---- load from file -------------------------------------------------
open my $w, '>', $hf or die;
print $w "first line\nsecond line\n\nfourth line\n";
close $w;

my $t = OldAgent::Term->new(no_tty => 1, history_file => $hf);
ok($t, 'term builds without a tty for tests');
my @h = @{ $t->{history} };
is_deeply(\@h, [ 'first line', 'second line', 'fourth line' ],
    'file lines load into history, blank lines skipped');

# ---- addhistory appends to file, dedupes consecutive ------------------
$t->addhistory('third line again');
open my $r, '<', $hf or die;
my @lines = <$r>;
close $r;
chomp @lines;
@lines = grep { length } @lines;
is_deeply(\@lines, [ 'first line', 'second line', 'fourth line', 'third line again' ],
    'accepted line appended to the file');
$t->addhistory('third line again');
open my $r2, '<', $hf or die;
my @lines2 = grep { length } map { chomp; $_ } <$r2>;
close $r2;
is_deeply(\@lines2, [ 'first line', 'second line', 'fourth line', 'third line again' ],
    'consecutive duplicate not re-saved');

# ---- recency wins on reload, cap at 200 ------------------------------
open my $w2, '>', $hf or die;
print $w2 "$_\n" for map { "line $_" } 1 .. 250;
close $w2;
my $t2 = OldAgent::Term->new(no_tty => 1, history_file => $hf);
is(scalar @{ $t2->{history} }, 200, 'history capped at 200');
is((@{ $t2->{history} })[-1], 'line 250', 'newest line is last');
is($t2->{history}[0], 'line 51', 'oldest kept line is 51');

# ---- no file, no crash ----------------------------------------------
my $hf2 = "$dir/none";
my $t3 = OldAgent::Term->new(no_tty => 1, history_file => $hf2);
is_deeply([ @{ $t3->{history} } ], [], 'missing file means empty history');

# cleanup
unlink("$dir/history", "$dir/rc", "$dir/none");
rmdir($dir);
