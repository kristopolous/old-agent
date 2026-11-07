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
like($out, qr/\[list \.\] ok/, 'the tool line shows the call');
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
my $out4 = `perl $oa1 --no-config --base-url https://example.invalid --model fake ask hi 2>&1`;
like($out4, qr/http only/, 'https: refused with a pointer, not a hang');

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

done_testing;
