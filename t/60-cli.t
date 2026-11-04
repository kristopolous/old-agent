use strict;
use warnings;
use lib 'lib';
use Test::More;
use File::Spec ();
use OldAgent::Util;

plan tests => 19;

my $perl = $^X;
my $oa   = File::Spec->catfile('oa');
my $dir  = File::Spec->catdir(OldAgent::Util::tmpdir(), "oa-cli-$$");
mkdir $dir;

$ENV{HOME} = $dir;            # ignore whatever the developer has configured
delete $ENV{OPENAI_API_KEY};
delete $ENV{OPENROUTER_API_KEY};
delete $ENV{ANTHROPIC_API_KEY};
delete $ENV{GROQ_API_KEY};

sub run {
    my (%a) = @_;
    my @argv = @{ $a{argv} };
    my $cmd = '';
    for my $k (sort keys %{ $a{env} || {} }) {
        my $v = $a{env}{$k};
        $v =~ s/'/'\\''/g;
        $cmd .= "export $k='$v'; ";
    }
    $cmd .= "'$perl' -Ilib '$oa'";
    for my $x (@argv) {
        (my $q = $x) =~ s/'/'\\''/g;
        $cmd .= " '$q'";
    }
    $cmd .= ' 2>&1';
    $cmd .= " < $a{stdin_file}" if $a{stdin_file};
    my $out = `$cmd`;
    return ($?, $out);
}

# --- basics -----------------------------------------------------------
my ($rc, $out) = run(argv => ['version']);
is($rc, 0, 'version exits 0');
like($out, qr/oldagent \d/, 'version string');

($rc, $out) = run(argv => ['--help']);
like($out, qr/usage: oa/, 'help shows usage');
like($out, qr/doctor/, 'help lists doctor');

($rc, $out) = run(argv => ['nope']);
isnt($rc, 0, 'unknown command fails');
like($out, qr/unknown command/, 'and says so');

($rc, $out) = run(argv => ['desktop']);
like($out, qr/not built yet/, 'desktop is honest about not existing');

($rc, $out) = run(argv => ['tools']);
like($out, qr/"tool":"bash"/, 'tools shows the tool spec');

($rc, $out) = run(argv => ['config']);
like($out, qr/^provider/m, 'config shows provider');

# --- a real conversation with the built-in echo model -----------------
($rc, $out) = run(
    argv => ['--no-config', '--provider', 'echo', 'ask', 'hello there'],
);
is($rc, 0, 'ask exits 0');
like($out, qr/\(echo\) you said: hello there/, 'echo model answered');

# --- a full task, tools and all ---------------------------------------
my $script = File::Spec->catfile($dir, 'script.txt');
OldAgent::Util::spew($script, join("\n----\n",
    "```tool\n{\"tool\":\"write\",\"args\":{\"path\":\"made.txt\",\"content\":\"from the cli\\n\"}}\n```",
    "```tool\n{\"tool\":\"done\",\"args\":{\"summary\":\"wrote made.txt\"}}\n```",
) . "\n");

($rc, $out) = run(
    argv => ['--no-config', '--provider', 'echo', '--root', $dir,
             '--yes', 'do', 'make the file'],
    env  => { OA_ECHO_SCRIPT => $script },
);
is($rc, 0, 'do exits 0');
my ($data) = OldAgent::Util::slurp(File::Spec->catfile($dir, 'made.txt'));
is($data, "from the cli\n", 'the cli actually wrote the file');
like($out, qr/\[tool\] write/, 'tool use is shown');

# --- stdin ------------------------------------------------------------
my $inf = File::Spec->catfile($dir, 'in.txt');
OldAgent::Util::spew($inf, "piped question\n");
($rc, $out) = run(
    argv => ['--no-config', '--provider', 'echo', 'ask'],
    stdin_file => $inf,
);
like($out, qr/piped question/, 'prompt read from stdin');

# --- failure paths ----------------------------------------------------
($rc, $out) = run(argv => ['--no-config', '--provider', 'nonsense', 'ask', 'hi']);
isnt($rc, 0, 'bad provider fails');
like($out, qr/unknown provider|nonsense/, 'with a clear message');

($rc, $out) = run(argv => ['--no-config', '--provider', 'openai',
                           '--base-url', 'http://127.0.0.1:1',
                           '--timeout', '5', 'ask', 'hi']);
isnt($rc, 0, 'unreachable endpoint fails');
like($out, qr/failed|refused|error/i, 'and explains');

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
