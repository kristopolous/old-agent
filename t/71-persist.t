# /model, /provider, ... must be remembered in the user config file, so
# the next session starts where this one ended.
use strict;
use warnings;
use lib 'lib';
use Test::More;
use File::Spec ();
use Cwd ();
use OldAgent::Config;
use OldAgent::Util;

plan tests => 18;

my $dir = File::Spec->catdir(OldAgent::Util::tmpdir(), "oa-persist-$$");
mkdir $dir;
local $ENV{HOME} = $dir;
delete $ENV{OLDAGENT_CONFIG};

# --- user_config_path ---------------------------------------------------
is(OldAgent::Config::user_config_path(),
   File::Spec->catfile($dir, '.oldagentrc'),
   'defaults to ~/.oldagentrc');

my $rc = File::Spec->catfile($dir, 'sub', 'dir', 'rc');
local $ENV{OLDAGENT_CONFIG} = $rc;
is(OldAgent::Config::user_config_path(), $rc,
   'OLDAGENT_CONFIG wins');

# --- remember(): merge, not clobber --------------------------------------
# an existing file with unrelated keys must survive
OldAgent::Util::spew($rc, "model = old-model\n# a comment\nhistory_chars = 1\n");
my $cfg = OldAgent::Config->load(overrides => {
    model => 'remembered-model', provider => 'echo', api_key => 'sk-test' });
my $path = $cfg->remember('model', 'provider', 'api_key');
is($path, $rc, 'remember returns the path');
ok(-f $rc, 'file written');
open my $fh, '<', $rc or fail 'rc not readable';
my $raw = do { local $/; <$fh> };
close $fh;
like($raw, qr{^model = remembered-model$}m, 'model persisted');
like($raw, qr{^provider = echo$}m, 'provider persisted');
like($raw, qr{^api_key = sk-test$}m, 'api key persisted');
like($raw, qr{^# a comment$}m, 'unrelated lines kept');
like($raw, qr{^history_chars = 1$}m, 'unrelated keys kept');

# --- round trip: a fresh load picks it up --------------------------------
my $fresh = OldAgent::Config->load(overrides => { provider => 'echo' });
is($fresh->get('model'), 'remembered-model',
   'a new session loads the remembered model');

# --- remember('key') with an empty value removes the key ----------------
$cfg->set(api_key => '');
$cfg->remember('api_key');
open $fh, '<', $rc or fail 'rc not readable (2)';
$raw = do { local $/; <$fh> };
close $fh;
unlike($raw, qr{^api_key = }m, 'empty api key removed');
like($raw, qr{^model = remembered-model$}m, 'other keys survive a removal');

# --- /version in the REPL ------------------------------------------------
my $oa = File::Spec->catfile(Cwd::getcwd(), 'oa');
my $out = `printf '/version\n/exit\n' | $^X "$oa" repl 2>&1`;
like($out, qr{oldagent \d+\.\d+\.\d+}, '/version prints the version');
like($out, qr{config file \(for /model, /provider, \.\.\.\): \S+},
     '/version shows where settings are stored');

# --- end to end: the REPL remembers a /model -----------------------------
my $home2 = File::Spec->catdir($dir, 'home2');
mkdir $home2;
my $rc2 = File::Spec->catfile($home2, 'rc');
my $out2 = `printf '/model e2e-model\n/provider echo\n/exit\n' | HOME="$home2" OLDAGENT_CONFIG="$rc2" $^X "$oa" repl 2>&1`;
like($out2, qr{\(remembered in \S+\)}, 'REPL confirms the remember');
ok(-f $rc2, 'repl wrote the config file');
open my $fh2, '<', $rc2 or fail 'rc2 not readable';
my $raw2 = do { local $/; <$fh2> };
close $fh2;
like($raw2, qr{^model = e2e-model$}m, 'repl /model persisted');
like($raw2, qr{^provider = echo$}m, 'repl /provider persisted');
