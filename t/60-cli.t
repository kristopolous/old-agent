use strict;
use warnings;
use lib 'lib';
use Test::More;
use File::Spec ();
use OldAgent::Util;

plan tests => 30;

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

($rc, $out) = run(argv => ['desktop'], env => { DISPLAY => '' });
like($out, qr/desktop error|couldn.t connect|Tk/i,
     'desktop needs Tk/a display, and says so');

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

# --- the interactive session, piped (scripts, tmux, tests) -------------
my $repl_in = File::Spec->catfile($dir, 'repl.txt');

# /provider <url>: one line sets both, and it is remembered
OldAgent::Util::spew($repl_in, "/provider https://9ol.es/11434\n/quit\n");
($rc, $out) = run(
    argv => ['--no-config', '--provider', 'echo', 'repl'],
    stdin_file => $repl_in,
);
is($rc, 0, 'piped repl exits 0');
like($out, qr/provider = ollama, base_url = https:\/\/9ol\.es\/11434/,
     '/provider <url> infers the provider from the url');
like($out, qr/\(remembered in \S+\)/, '/provider <url> is remembered');

# /provider (no argument): the three-step wizard, driven through a pipe
OldAgent::Util::spew($repl_in, join("",
    "/provider\n",             # start the wizard
    "3\n",                     # protocol: 3 = ollama
    "https://9ol.es/11434\n",  # base url
    "none\n",                  # api key: none
    "/quit\n"));
($rc, $out) = run(
    argv => ['--no-config', 'repl'],
    stdin_file => $repl_in,
);
is($rc, 0, 'wizard repl exits 0');
like($out, qr/\(1\) protocol/, 'wizard asks for the protocol');
like($out, qr/\(2\) base url/, 'wizard asks for the base url');
like($out, qr/\(3\) api key/, 'wizard asks for the key');
like($out, qr/provider = ollama, base_url = https:\/\/9ol\.es\/11434, key = \(none\)/,
     'wizard summary');

OldAgent::Util::spew($repl_in, "hello from a pipe\n/quit\n");
($rc, $out) = run(
    argv => ['--no-config', '--provider', 'echo', 'repl'],
    stdin_file => $repl_in,
);
like($out, qr/\(echo\) you said: hello from a pipe/, 'piped message got answered');

OldAgent::Util::spew($repl_in, join("\n",
    '/provider gpt-4',
    '/base-url http://127.0.0.1:9999/v1',
    '/base-url',
    '/quit',
) . "\n");
($rc, $out) = run(
    argv => ['--no-config', '--provider', 'echo', 'repl'],
    stdin_file => $repl_in,
);
like($out, qr/not a known provider/, 'rejects a provider that is neither name nor url');
like($out, qr/base_url = http:\/\/127\.0\.0\.1:9999\/v1/, '/base-url sets and shows');

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
