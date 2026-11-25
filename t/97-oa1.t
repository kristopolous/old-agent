# oa1 - the one-file perl 5.001 agent - against a fake ollama on a local
# socket: streaming NDJSON in, tool calls out, result blocks back; plus
# its JSON round trip and a lint for constructs perl 5.001 does not have.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use OldAgent::Util ();
use IO::Socket::INET;
use File::Spec ();
use File::Copy ();

my $oa1 = "$FindBin::Bin/../oa1";
plan skip_all => 'oa1 not found' unless -f $oa1;

# --- 1. the dialect: nothing perl 5.001 cannot parse -------------------
{
    open(my $fh, '<', $oa1) or die "$oa1: $!";
    my @bad;
    my $n = 0;
    while (my $l = <$fh>) {
        $n++;
        next if $l =~ /^\s*#/;
        $l =~ s/#.*$// unless $l =~ /["']\s*#/;
        for my $re (
            qr/\bour\b/, qr/\bfor(?:each)?\s+my\b/, qr/->\s*\(/, qr/\bqr\//,
            qr/open\s*\(\s*my\b/, qr/open\s+my\b/, qr/\$SIG\{\w+\}\s*=\s*sub\b/,
            qr/__PACKAGE__/, qr/->can\(/, qr/->isa\(/, qr/SUPER::/,
            qr/\buse\s+(?:vars|constant|warnings|POSIX|File::Spec|IO::|Getopt|IPC::)/,
            qr/\bdie\s*\{/, qr/\bexists\s*&/, qr/%\*[sd]/, qr/\s\/\/\s/, qr/\bsysopen\b/,
            qr/O_NONBLOCK/, qr/\bsubstr\s*\([^;()]*,[^;()]*,[^;()]*,/,
            qr/\bsub\s+\w+\s*\([\$\@%;\\]*\)/,         # prototypes
            qr/\bmy\s*\(\s*\$a\b|\bmy\s+\$a\b|\bmy\s+\$b\b/,
        ) {
            push @bad, "$n: $l" if $l =~ $re;
        }
    }
    close $fh;
    ok(!@bad, 'no post-5.001 constructs in oa1') or diag(join('', @bad));
}

# --- 2. json round trip, via require -------------------------------------
{
    local @ARGV = ();
    require $oa1;
    my ($v, $e) = main::json_dec('{"a":[1,2.5,-3e2,"x\\ny\\u00e9\\ud83d\\ude00",true,false,null],"b":{"c":""}}');
    is($e, '', 'decode: no error');
    is(ref $v, 'HASH', 'decode: hash');
    is($v->{a}[0], 1, 'decode: int');
    is($v->{a}[1], 2.5, 'decode: float');
    is($v->{a}[2], -300, 'decode: exponent');
    is($v->{a}[3], "x\ny\xc3\xa9\xf0\x9f\x98\x80", 'decode: escapes, \\u, surrogate pair as utf-8 bytes');
    is($v->{a}[4], 1, 'decode: true');
    is($v->{a}[5], 0, 'decode: false');
    ok(!defined $v->{a}[6], 'decode: null');
    is($v->{b}{c}, '', 'decode: empty string');
    ($v, $e) = main::json_dec('{"a":');
    ok($e, "decode: truncated input is an error ($e)");
    ($v, $e) = main::json_dec('[1] x');
    ok($e, 'decode: trailing garbage is an error');
    is(main::json_enc({ s => "a\"b\\c\n\t\x01", n => \'3', l => [1, 'x', undef], h => {} }),
       '{"h":{},"l":["1","x",null],"n":3,"s":"a\"b\\\\c\\n\\t\\u0001"}', 'encode');
    my $calls = main::parse_calls("Let me look.\n```tool\n{\"tool\":\"list\",\"args\":{\"path\":\".\"}}\n```\n");
    is($calls->[0]{tool}, 'list', 'parse_calls: fenced tool block');
    is($calls->[0]{args}{path}, '.', 'parse_calls: args');
    $calls = main::parse_calls("```json\n{\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}\n```");
    is($calls->[0]{tool}, 'bash', 'parse_calls: openai style name/arguments string');
    is($calls->[0]{args}{command}, 'ls', 'parse_calls: arguments decoded');
    $calls = main::parse_calls("just chatting, no fences here");
    is(scalar @$calls, 0, 'parse_calls: prose has no calls');
    $calls = main::parse_calls("`uname -a`\n");
    is($calls->[0]{tool}, 'bash', 'parse_calls: a bare backticked command is a bash proposal');
    is($calls->[0]{args}{command}, 'uname -a', 'parse_calls: the command');
    $calls = main::parse_calls("run `uname -a` to see");
    is(scalar @$calls, 0, 'parse_calls: inline code inside prose is not a call');
    is(main::visible("hi\n```tool\n{}\n```\nbye"), "hi\nbye", 'visible: fences stripped');
    ok(main::looks_like_intent("Let me read the file first."), 'intent: narrated step');
    ok(!main::looks_like_intent("Done. Let me know if you need more."), 'intent: sign-off is not a step');
    main::set_cfg("ascii", 1);
    is(main::fold("a\xe2\x80\x94b \xe2\x80\x9cq\xe2\x80\x9d \xe2\x80\xa6 \xc3\xa9"), "a-b \"q\" ... ?", 'fold: dashes, quotes, ellipsis, other multibyte');
    main::set_cfg("ascii", 0);
    is(main::fold("a\xe2\x80\x94b"), "a\xe2\x80\x94b", 'fold: off leaves utf-8 alone');
    is(main::utf8_tail("ab\xe2\x80"), 2, 'utf8_tail: a split three-byte sequence is held');
    is(main::utf8_tail("ab\xe2\x80\x94"), 0, 'utf8_tail: a complete one is not');
    is(main::utf8_tail("abc"), 0, 'utf8_tail: ascii');
}

# --- 3. a fake ollama: two turns, a tool call, a done block -------------
my $dir = OldAgent::Util::tmpdir() . "/oa1-test-$$";
mkdir $dir or die "mkdir $dir: $!";
my $parent = $$;
END { if ($$ == $parent && defined $dir && -d $dir) { unlink glob("$dir/*"); rmdir $dir } }   # not in the forked server
open(my $h, '>', "$dir/hello.txt") or die; print $h "hello\n"; close $h;
my $log = "$dir/requests.log";

my $srv = IO::Socket::INET->new(Listen => 5, LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp', ReuseAddr => 1)
    or plan skip_all => "cannot listen on a local socket: $!";
my $port = $srv->sockport;

my @replies = (
    "I'll list the directory.\n```tool\n{\"tool\":\"list\",\"args\":{\"path\":\".\"}}\n```\n",
    "There is one file, hello.txt.\n```tool\n{\"tool\":\"done\",\"args\":{\"summary\":\"The directory holds hello.txt.\"}}\n```\n",
);
my $pid = fork;
die "fork: $!" unless defined $pid;
if (!$pid) {
    # the server: read one HTTP/1.0 request, stream the scripted reply as
    # NDJSON in small pieces (the way ollama does), close.
    open(my $lg, '>', $log) or die;
    $lg->autoflush(1);
    for my $reply (@replies) {
        my $c = $srv->accept or last;
        my ($hdr, $len) = ('', 0);
        while (defined(my $l = <$c>)) { $hdr .= $l; $len = $1 if $l =~ /^Content-Length:\s*(\d+)/i; last if $l =~ /^\r?\n$/ }
        my $body = '';
        read($c, $body, $len) if $len;
        print $lg "=== request\n$hdr$body\n";
        print $c "HTTP/1.0 200 OK\r\nContent-Type: application/x-ndjson\r\n\r\n";
        for my $piece (split(/(?<=[ \n])/, $reply)) {
            (my $j = $piece) =~ s/(["\\])/\\$1/g; $j =~ s/\n/\\n/g;
            print $c "{\"model\":\"fake\",\"message\":{\"role\":\"assistant\",\"content\":\"$j\"},\"done\":false}\n";
        }
        print $c "{\"model\":\"fake\",\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true}\n";
        close $c;
    }
    exit 0;
}
close $srv;

my $out = `cd $dir && perl $oa1 --no-config --provider ollama --base-url http://127.0.0.1:$port --model fake -y do "what is in this directory?" 2>&1`;
my $rc = $? >> 8;
waitpid($pid, 0);
is($rc, 0, 'oa1 do: exit 0') or diag($out);
like($out, qr/I'll list the directory/, 'the streamed reply was printed');
like($out, qr/\*\*list\*\* `\{.*"path":"\.",?\}` ok/, 'the tool line shows the call as json');
like($out, qr/hello\.txt\s+6/, 'the listing shows the file and its size');
like($out, qr/\[done\]/, 'the done block ended the task');
like($out, qr/There is one file, hello\.txt/, 'the final prose was printed');
unlike($out, qr/```/, 'no raw fences in the transcript');

open(my $lf, '<', $log) or die; my $reqs = do { local $/; <$lf> }; close $lf;
like($reqs, qr/POST \/api\/chat HTTP\/1\.0/, 'request: POST /api/chat, HTTP/1.0');
like($reqs, qr/"stream":true/, 'request: streaming on');
unlike($reqs, qr/"think"/, 'request: no think option unless configured');
like($reqs, qr/"messages":\[\{"content":"You are oldagent.*?","role":"system"\},\{"content":"what is in this directory\?","role":"user"\}/s, 'request: the system prompt is the first message (ollama ignores a top-level system field)');
unlike($reqs, qr/"system":/, 'request: no top-level system field');
my @bodies = ($reqs =~ /=== request\n.*?\r?\n\r?\n(.*?)\n(?==== request|\z)/gs);
is(scalar @bodies, 2, 'two model calls');
like($bodies[1], qr/```result\\n\{\\"ok\\":1,\\"output\\":\\"hello\.txt/, 'second call carries the result block with the listing');
like($bodies[1], qr/"content":"I'll list the directory.*?","role":"assistant"/s, 'second call carries the assistant turn');

# --- 4. a plain chat reply ends the turn, no tools ---------------------
my $srv2 = IO::Socket::INET->new(Listen => 5, LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp', ReuseAddr => 1) or die;
my $port2 = $srv2->sockport;
my $pid2 = fork;
if (!$pid2) {
    my $c = $srv2->accept;
    my $hdr = ''; my $len = 0;
    while (defined(my $l = <$c>)) { $len = $1 if $l =~ /^Content-Length:\s*(\d+)/i; last if $l =~ /^\r?\n$/ }
    my $body = ''; read($c, $body, $len) if $len;
    print $c "HTTP/1.0 200 OK\r\n\r\n";
    print $c "{\"message\":{\"content\":\"`\"},\"done\":false}\n{\"message\":{\"content\":\"hostname` tells you \xe2\x80\"},\"done\":false}\n{\"message\":{\"content\":\"\x94 Hello! I am a tiny agent.\"},\"done\":false}\n{\"message\":{\"content\":\"\"},\"done\":true}\n";
    close $c;
    $srv2->accept;    # a second call would be a bug: hang the test instead of passing
    exit 0;
}
close $srv2;
local $SIG{ALRM} = sub { kill 'KILL', $pid2; die "oa1 ask made a second model call\n" };
alarm 20;
my $out2 = `perl $oa1 --no-config --base-url http://127.0.0.1:$port2 --model fake -q --ascii ask hello`;
alarm 0;
kill 'TERM', $pid2; waitpid($pid2, 0);
is($out2, "`hostname` tells you - Hello! I am a tiny agent.\n", 'ask -q --ascii: just the answer, one call; a leading backtick is not a fence; an em dash split across tokens folds to -');

# --- 5. errors are errors ---------------------------------------------
my $out3 = `perl $oa1 --no-config --base-url http://127.0.0.1:1 --model fake --timeout 5 ask hi 2>&1`;
isnt($? >> 8, 0, 'unreachable endpoint: non-zero exit');
like($out3, qr/error: connect to 127\.0\.0\.1:1/, 'unreachable endpoint: says so');

# https is no longer refused up front: oa1 borrows a curl or wget when one
# exists (opportunistic TLS), and balks with a pointer to the fix (oa-proxy,
# or a local http endpoint) only when no TLS tool is on the box. to test the
# balk deterministically, put a perl on a PATH that has neither curl nor wget.
my $perlbin = `$^X -V:installbin 2>/dev/null | sed -n 's/^installbin: //p'`;
chomp $perlbin;
my $pbin = File::Spec->catdir($dir, 'nobin');
mkdir $pbin;
my $pl = File::Spec->catfile($pbin, 'perl');
{ my $tg = File::Spec->catfile($perlbin, 'perl');
  my ($r, $e) = File::Copy::copy($tg, $pl);
  if (!$r) { symlink($tg, $pl) or do { plan_skip_all("cannot stage a perl for the https-balk test: $e"); }; } }
my $out4 = `PATH=$pbin $^X $oa1 --no-config --base-url https://example.invalid --model fake ask hi 2>&1`;
like($out4, qr/no TLS in this perl, and no curl or wget/, 'https with no TLS tool: balks with a pointer, not a hang');
like($out4, qr/oa-proxy|http endpoint/, 'https balk: points at the fix');

# --- 6. oa hands over to oa1 on a perl that cannot compile the tree ------
{
    local $ENV{OA_MINIMAL} = 1;
    my $v = `perl $FindBin::Bin/../oa --no-config --version 2>&1`;
    like($v, qr/^oa1 \d+\.\d+\.\d+ \(perl/, 'OA_MINIMAL=1: oa execs oa1 (the same check fires on perl < 5.006)');
    my $d = `perl $FindBin::Bin/../oa --no-config --base-url http://127.0.0.1:1 --timeout 3 doctor 2>&1`;
    like($d, qr/one-file edition.*\n.*provider/s, 'oa1 doctor: settings');
    like($d, qr/endpoint\s+http:\/\/127\.0\.0\.1:1: connect/, 'oa1 doctor: reports the endpoint failure');
}
my $head = do { open(my $fh, "<", "$FindBin::Bin/../oa") or die; local $/; <$fh> };
like($head, qr/^BEGIN \{\n    if \(\$\] < 5\.006/m, 'oa: the version check is the first code in the file, before any use');
ok($head !~ /^use /m || index($head, "BEGIN {\n    if ($] < 5.006") < index($head, "\nuse "), 'oa: no use statement precedes the check');

# --- 7. /help in a session lists what a session can do -----------------
# the complaint this guards: /help in the repl printed the whole command line
# usage, so the first screenful was flags you could not pass from a session,
# and the handful of commands you could pass were one squashed line. session
# help leads with the session, and says nothing the session does not do.
{
    local @ARGV = ();
    require $oa1;
    my $h = main::repl_help();
    like($h, qr{^in the session:\n}, 'session /help leads with the session');
    unlike($h, qr/--base-url|--timeout|--no-config|usage: oa1/, 'session /help lists no command-line flags');

    # every command it names has to be one the repl actually dispatches
    my ($repl_src) = do { open(my $fh, '<', $oa1) or die; local $/; <$fh> };
    my ($dispatch) = $repl_src =~ /sub repl \{(.*?)\n\}/s;
    ok($dispatch, 'found the repl dispatcher to check against');
    my @listed = $h =~ m{^  /([\w-]+)}gm;
    cmp_ok(scalar(@listed), '>=', 8, 'session /help lists the commands one per line');
    my @phantom;
    my $c;
    for $c (@listed) {
        my $found = 0;
        $found = 1 if index($dispatch, "\$cmd eq '$c'") >= 0;
        $found = 1 if $c eq 'quit' && index($dispatch, 'quit|exit|q') >= 0;
        push @phantom, $c unless $found;
    }
    is_deeply(\@phantom, [], 'every command the session help lists is dispatched');

    # and the settings still follow it, which is what /help was asked to
    # show. (in-process, not piped: the repl prefers /dev/tty when it can
    # open one, so a pipe would not be read here)
    my $out = '';
    {
        local *STDOUT;
        open(STDOUT, '>', \$out) or die "stdout: $!";
        print main::repl_help();
        print "\nsettings in use:\n";
        main::show_config();
    }
    like($out, qr{in the session:\n  /help}, 'session /help: the session list comes first');
    like($out, qr{settings in use:\n  provider  = }, 'session /help: ends with the settings in use');
    like($out, qr{/model NAME\s.*\n\s*/base URL\s}m, 'session /help: one command per line');
}

# --- 12. `oa1 oa`: the full agent, when this perl can run the tree --------
{
    my $oa = "$FindBin::Bin/../oa";
    if (-f $oa && $] >= 5.006) {
        # everything after `oa` belongs to the full agent, so its --version
        # must reach it (oa1 must not print its own version instead)
        my $r = `$^X $oa1 oa --version 2>&1`;
        like($r, qr{oldagent \d}, 'oa1 oa: delegates --version to the full agent');
        # and it really execs the sibling, not itself
        like($r, qr{running the full agent}, 'oa1 oa: says it is running the full agent');
        # oa1-level flags before `oa` are still honoured (no rc read here)
        my $r2 = `$^X $oa1 --no-config oa --version 2>&1`;
        like($r2, qr{oldagent \d}, 'oa1 oa: honours rc flags before the subcommand');
    } else {
        # too old a perl, or no sibling: it says so and does not hang
        my $r = `$^X $oa1 oa --version 2>&1`;
        like($r, qr{oa1 oa: (this perl|no full agent)}, 'oa1 oa: explains when it cannot delegate');
    }
    # the hand-off guard: if the full agent is already handing back, do not
    # exec it again (that would loop)
    my $loop = `OA1_HANDOFF=1 $^X $oa1 oa --version 2>&1`;
    like($loop, qr{not for this perl|the edition here}, 'oa1 oa: does not re-exec on the way back');
}

# --- 13. the session is a file: appended as it happens, resumed later ------
#
# the transcript is a jsonl file, appended to one message at a time as the
# conversation grows. nothing in it is only in memory, so a Ctrl-C, a crash,
# or the box dying loses nothing - `oa1 resume <file>` picks it up. these
# tests run the real binary end to end and inspect the file it writes.
{
    # a throwaway session dir (the env override oa1 honours), so the test never
    # reads or clobbers the user's real /tmp/oa/<uid> sessions
    my $sdir = File::Spec->catdir($dir, 'sess');
    mkdir $sdir;
    my $saved_env = $ENV{OA_SESSION_DIR};
    $ENV{OA_SESSION_DIR} = $sdir;

    # a fake ollama: serves canned replies, self-terminates on its own alarm so
    # it can never keep a waitpid below blocked
    my $srv = IO::Socket::INET->new(Listen => 4, LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp', ReuseAddr => 1) or die;
    my $port = $srv->sockport;
    my $pid = fork;
    if (!$pid) {
        # serve until the parent says stop (TERM) or this backstop fires, so it
        # can never keep a waitpid below blocked
        local $SIG{ALRM} = sub { exit 0 };
        alarm 30;
        my $c;
        for (1..8) {
            $c = $srv->accept or last;
            my $len = 0;
            while (defined(my $l = <$c>)) { $len = $1 if $l =~ /^Content-Length:\s*(\d+)/i; last if $l =~ /^\r?\n$/ }
            my $body = ''; read($c, $body, $len) if $len;
            print $c "HTTP/1.0 200 OK\r\n\r\n";
            print $c "{\"message\":{\"content\":\"ok.\"},\"done\":false}\n{\"message\":{\"content\":\"\"},\"done\":true}\n";
            close $c;
        }
        exit 0;
    }
    close $srv;

    # every blocking step below runs inside an alarm window (via a code ref, so
    # the alarm is set before the step runs), and a regression fails the test in
    # seconds instead of hanging the whole run
    my $guard = sub {
        my ($code) = @_;
        local $SIG{ALRM} = sub { kill 'KILL', $pid; die "oa1 hung in the session test\n" };
        alarm 20;
        my $r = &$code;
        alarm 0;
        return $r;
    };

    # first run: two messages in, a transcript file must appear on disk.
    # the server child stays up (it serves the resume run next), so we do not
    # waitpid here - that would block until it is done.
    my $out = $guard->( sub { my $r = `printf 'first\nsecond\n' | perl $oa1 --no-config --base-url http://127.0.0.1:$port --model fake --ascii 2>&1`; $r } );

    ok(-d $sdir, 'session: the per-user session directory was created');
    my @files = glob "$sdir/*.jsonl";
    my $latest = (sort { (stat($a))[9] <=> (stat($b))[9] } @files)[-1];
    ok(defined $latest && -f $latest, 'session: a transcript file was written during the run');

    my $log = '';
    if (defined $latest && open(my $fh, '<', $latest)) { my $c = do { local $/; <$fh> }; $log = defined $c ? $c : ''; close $fh }
    my @lines = grep { length } split(/\n/, $log);
    my %seen;
    my $okjson = 1;
    for my $l (@lines) {
        my ($d, $e) = main::json_dec($l);
        $okjson = 0 unless ref $d eq 'HASH' && defined $d->{role} && defined $d->{content};
        $seen{ $d->{role} . '\0' . $d->{content} }++;
    }
    ok(scalar(@lines) >= 4, 'session: the transcript holds both user turns and both replies');
    ok($okjson, 'session: every transcript line is a {role,content} json object');
    ok(defined $seen{'user\0first'} && defined $seen{'user\0second'}, 'session: the user\'s words are on disk, in order');
    like($out, qr{session: \Q$latest\E}o, 'session: the banner names the transcript file');
    like($out, qr{resume it with:\s+oa1 resume \Q$latest\E}o, 'session: it tells you how to get it back');

    # resume: a fresh process reads the file and keeps the same one
    my $out2 = $guard->( sub { my $r = `printf 'third\n' | perl $oa1 resume \Q$latest\E --no-config --base-url http://127.0.0.1:$port --model fake --ascii 2>&1`; $r } );
    my $log2 = '';
    if (open(my $fh, '<', $latest)) { my $c = do { local $/; <$fh> }; $log2 = defined $c ? $c : ''; close $fh }
    like($out2, qr{resumed \d+ messages from \Q$latest\E}o, 'resume: says how many messages it picked up');
    ok($log2 =~ /first/ && $log2 =~ /second/ && $log2 =~ /third/, 'resume: appends to the same file, keeping the earlier turns');

    # resume with nothing there: a clear error, no hang
    my $miss = `perl $oa1 resume /no/such/file --no-config 2>&1`;
    like($miss, qr{resume needs a session file}, 'resume: missing file is a clear error');
    isnt($? >> 8, 0, 'resume: missing file is a non-zero exit');

    # tidy: restore the env, stop the server (it is idle in accept now that the
    # runs are done), reap it, and clean the throwaway dir
    $ENV{OA_SESSION_DIR} = $saved_env;
    delete $ENV{OA_SESSION_DIR} unless defined $saved_env;
    kill 'TERM', $pid;
    $guard->( sub { waitpid($pid, 0) } );
    unlink glob("$sdir/*.jsonl"); rmdir $sdir;
}

done_testing;
