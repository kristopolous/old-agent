use strict;
use warnings;
use lib 'lib';
use Test::More;
use File::Spec ();
use OldAgent::Tools;
use OldAgent::Util;

plan tests => 37;

my $dir = File::Spec->catdir(OldAgent::Util::tmpdir(), "oa-tools-$$");
mkdir $dir;
mkdir File::Spec->catdir($dir, 'src');
OldAgent::Util::spew(File::Spec->catfile($dir, 'notes.txt'), "one\ntwo\nTODO fix this\nfour\n");
OldAgent::Util::spew(File::Spec->catfile($dir, 'src', 'main.c'),
    "#include <stdio.h>\nint main(void) { /* TODO */ return 0; }\n");

my $t = OldAgent::Tools->new(root => $dir, max_output => 4000);

# --- read -------------------------------------------------------------
my $r = $t->call('read', { path => 'notes.txt' });
ok($r->{ok}, 'read ok');
like($r->{output}, qr{^# .*notes\.txt lines 1-5 of 5}, 'read header');
like($r->{output}, qr/\bthree\b|\bfour\b/, 'read body');

$r = $t->call('read', { path => 'notes.txt', from => 3, lines => 1 });
ok($r->{ok}, 'read slice ok');
like($r->{output}, qr/TODO fix this/, 'slice has the line');
ok($r->{output} !~ /\bone\b/, 'slice skips earlier lines');

$r = $t->call('read', { path => 'nope.txt' });
ok(!$r->{ok}, 'missing file fails');
like($r->{output}, qr/no such file/, 'missing file message');

$r = $t->call('read', { path => 'src' });
ok(!$r->{ok}, 'reading a directory fails');

# --- write / edit -----------------------------------------------------
$r = $t->call('write', { path => 'out.txt', content => "hello\n" });
ok($r->{ok}, 'write ok');
my ($data) = OldAgent::Util::slurp(File::Spec->catfile($dir, 'out.txt'));
is($data, "hello\n", 'file contents');

$r = $t->call('write', { path => 'out.txt', content => "again\n", mode => 'append' });
ok($r->{ok}, 'append ok');
($data) = OldAgent::Util::slurp(File::Spec->catfile($dir, 'out.txt'));
is($data, "hello\nagain\n", 'appended');

$r = $t->call('write', { path => 'deep/deeper/f.txt', content => 'x' });
ok($r->{ok}, 'write creates directories');

$r = $t->call('edit', { path => 'out.txt', find => 'hello', replace => 'goodbye' });
ok($r->{ok}, 'edit ok');
($data) = OldAgent::Util::slurp(File::Spec->catfile($dir, 'out.txt'));
like($data, qr/goodbye/, 'edited on disk');

$r = $t->call('edit', { path => 'out.txt', find => 'zzz', replace => 'q' });
ok(!$r->{ok}, 'edit with no match fails');

$r = $t->call('edit', { path => 'notes.txt', find => 'o', replace => '0' });
ok(!$r->{ok}, 'ambiguous edit refused');
like($r->{output}, qr/matches \d+ times/, 'ambiguous edit explains');

$r = $t->call('edit', { path => 'notes.txt', find => 'o', replace => '0', all => 1 });
ok($r->{ok}, 'all=1 edits everything');

# --- list / find ------------------------------------------------------
$r = $t->call('list', { path => '.' });
ok($r->{ok}, 'list ok');
like($r->{output}, qr{notes\.txt}, 'list shows a file');
like($r->{output}, qr{src/}, 'list marks directories');

$r = $t->call('find', { pattern => 'TODO' });
ok($r->{ok}, 'find ok');
like($r->{output}, qr{main\.c:2:}, 'find reports file:line');
like($r->{output}, qr{notes\.txt:3:}, 'find walks directories');

# --- bash -------------------------------------------------------------
$r = $t->call('bash', { cmd => 'echo hi; echo err >&2' });
ok($r->{ok}, 'bash ok');
like($r->{output}, qr/hi\s*\n?err/, 'bash merges stderr');

$r = $t->call('bash', { cmd => 'exit 3' });
ok(!$r->{ok}, 'bash reports failure');
like($r->{output}, qr/exit status 3/, 'exit status shown');

$r = $t->call('bash', { cmd => 'sleep 5', timeout => 1 });
ok(!$r->{ok}, 'timeout stops a hung command');
like($r->{output}, qr/timed out/, 'timeout message');

# --- sandbox ----------------------------------------------------------
$r = $t->call('write', { path => File::Spec->catfile(OldAgent::Util::tmpdir(), "escape-$$"), content => 'x' });
ok(!$r->{ok}, 'writes outside the root are refused');
like($r->{output}, qr/outside the working root/, 'refusal message');

$r = $t->call('nope', {});
ok(!$r->{ok}, 'unknown tool fails');
like($r->{output}, qr/unknown tool/, 'unknown tool message');

# --- cleanup ----------------------------------------------------------
sub rmtree {
    my ($d) = @_;
    return unless -d $d;
    if (opendir(my $dh, $d)) {
        for my $f (readdir($dh)) {
            next if $f eq '.' || $f eq '..';
            my $p = File::Spec->catfile($d, $f);
            -d $p ? rmtree($p) : unlink($p);
        }
        closedir($dh);
    }
    rmdir $d;
}
rmtree($dir);
ok(!-d $dir, 'cleaned up');
