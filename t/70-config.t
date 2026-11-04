use strict;
use warnings;
use lib 'lib';
use Test::More;
use File::Spec ();
use OldAgent::Config;
use OldAgent::Util;

plan tests => 18;

my $dir = File::Spec->catdir(OldAgent::Util::tmpdir(), "oa-cfg-$$");
mkdir $dir;
my $file = File::Spec->catfile($dir, 'oldagentrc');

# --- line parsing -----------------------------------------------------
my ($k, $v) = OldAgent::Config::parse_line('model = gpt-4o-mini');
is($k, 'model', 'key parsed');
is($v, 'gpt-4o-mini', 'value parsed');
($k, $v) = OldAgent::Config::parse_line('  base_url = "http://x:11434/v1" ');
is($v, 'http://x:11434/v1', 'quotes stripped');
($k, $v) = OldAgent::Config::parse_line('# comment = x');
is($k, undef, 'comments ignored');
($k, $v) = OldAgent::Config::parse_line('garbage');
is($k, undef, 'garbage ignored');
($k, $v) = OldAgent::Config::parse_line('MODEL=upper');
is($k, 'model', 'keys are lowercased');

# --- files ------------------------------------------------------------
OldAgent::Util::spew($file, join("\n",
    '# a config',
    'provider = ollama',
    'model = llama3',
    'approve = yes',
    'max_turns = 3',
    '',
));
my $c = OldAgent::Config->load(no_files => 1);
is($c->get('provider'), 'openai', 'default provider');
is($c->get('approve'), 'ask', 'default approval');

$c = OldAgent::Config->load(no_files => 1);
$c->load_file($file);
$c->finalize;
is($c->get('model'), 'llama3', 'file value wins over default');
is($c->get('approve'), 'auto', 'approve=yes normalises to auto');
is($c->get('base_url'), 'http://127.0.0.1:11434', 'ollama gets a default url');

# --- environment ------------------------------------------------------
{
    local $ENV{OA_MODEL} = 'from-env';
    local $ENV{OA_TIMEOUT} = '7';
    my $c2 = OldAgent::Config->load(no_files => 1);
    is($c2->get('model'), 'from-env', 'environment beats the file/default');
    is($c2->get('timeout'), 7, 'numbers stay numbers');
}

# --- flags beat everything -------------------------------------------
my $c3 = OldAgent::Config->load(no_files => 1, overrides => {
    model => 'from-flag', provider => 'ollama',
});
is($c3->get('model'), 'from-flag', 'flags win');
like($c3->get('base_url'), qr{127\.0\.0\.1}, 'provider defaults still applied');

# --- secrets ----------------------------------------------------------
my $c4 = OldAgent::Config->load(no_files => 1, overrides => { api_key => 'sk-secret-1234567890' });
my $r = $c4->redacted;
ok($r->{api_key} !~ /secret/, 'keys are redacted for display');
my $w = File::Spec->catfile($dir, 'out.rc');
$c4->write_file($w);
my ($text) = OldAgent::Util::slurp($w);
ok($text !~ /sk-secret/, 'written config has no key');
like($text, qr/api_key/, 'but mentions where the key goes');

sub rmtree {
    my ($d) = @_;
    return unless -d $d;
    if (opendir(my $dh, $d)) {
        for my $f (readdir($dh)) {
            next if $f eq '.' || $f eq '..';
            my $x = File::Spec->catfile($d, $f);
            -d $x ? rmtree($x) : unlink($x);
        }
        closedir($dh);
    }
    rmdir $d;
}
rmtree($dir);
