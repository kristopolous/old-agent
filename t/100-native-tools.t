# oa1 native tool calling - the tools array goes out, the tool_calls come
# back (streamed fragments on ollama, one message on openai), the results
# go back as role:tool messages naming their call, and the loop ends when
# the model answers with no tool call. when the endpoint refuses the tools
# parameter, the session falls back to the fence protocol on its own.
# fully hermetic: fake endpoints on local sockets; nothing touches the net.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use OldAgent::Util ();
use IO::Socket::INET;
use File::Spec ();

my $oa1 = "$FindBin::Bin/../oa1";
plan skip_all => 'oa1 not found' unless -f $oa1;

my $dir = File::Spec->catdir(OldAgent::Util::tmpdir(), "oa1-native-$$");
mkdir $dir or die "mkdir: $!";
my $sessdir = File::Spec->catdir($dir, 'sessions');
mkdir $sessdir or die "mkdir sessdir: $!";
my $parent = $$;
END {
    if ($$ == $parent && defined $dir && -d $dir) {
        unlink glob("$sessdir/*");
        unlink glob("$dir/*.log");
        unlink glob("$dir/a.txt");
        unlink glob("$dir/hello.txt");
        rmdir $sessdir;
        rmdir $dir;
    }
}

my @PIDS;
sub guard {
    my ($code) = @_;
    local $SIG{ALRM} = sub { kill 'KILL', @PIDS if @PIDS; die "test hung\n" };
    alarm 30;
    my $r = &$code;
    alarm 0;
    return $r;
}

sub read_request {
    my ($c) = @_;
    my ($req, $head, $body, $clen, $buf, $n);
    $req = '';
    while ($req !~ /\r\n\r\n/) {
        $n = sysread($c, $buf, 4096);
        last if !defined $n || $n == 0;
        $req .= $buf;
    }
    ($head, $body) = split(/\r\n\r\n/, $req, 2);
    ($clen) = $head =~ /Content-Length:\s*(\d+)/i;
    $body = defined $body ? $body : '';
    while (defined $clen && length($body) < $clen) {
        $n = sysread($c, $buf, 8192);
        last if !defined $n || $n == 0;
        $body .= $buf;
    }
    return ($head, $body);
}

sub slurp {
    my ($path) = @_;
    my $fh;
    open($fh, '<', $path) or return '';
    my $all = do { local $/; <$fh> };
    close $fh;
    return defined $all ? $all : '';
}

sub bodies_of {
    my ($path) = @_;
    my $all = slurp($path);
    my @parts = ($all =~ /=== request \d+\n(.*?)(?==== request|\z)/gs);
    return @parts;
}

sub spawn {
    my ($code) = @_;
    my $pid = fork;
    die "fork: $!" unless defined $pid;
    push @PIDS, $pid;
    if (!$pid) { &$code; exit 0 }
    return $pid;
}

sub run_oa1 {
    my ($dir, $port, $provider, $flags, $task) = @_;
    my $out = guard(sub {
        my $r = `cd $dir && perl $oa1 --no-config --provider $provider --base-url http://127.0.0.1:$port --model fake $flags do "$task" 2>&1`;
        return $r;
    });
    return ($out, $? >> 8);
}

# ---------------------------------------------------------------------------
# 1. native on ollama. the tools array goes out; the model answers with a
#    tool call streamed the way ollama streams them (name and id on the
#    first fragment, the arguments json string split across fragments); the
#    result comes back as a role:tool message naming its call; the task ends
#    the way a natively trained model ends one - a plain answer, no tools.
# ---------------------------------------------------------------------------
{
    my $log = File::Spec->catfile($dir, 'ollama.log');
    my $srv = IO::Socket::INET->new(
        Listen => 8, LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp', ReuseAddr => 1,
    ) or plan skip_all => "cannot listen: $!";
    my $port = $srv->sockport;
    my $pid = spawn(sub {
        my ($n, $c, $head, $body);
        my $LOG;
        open($LOG, '>', $log) or exit 1;
        $LOG->autoflush(1);
        for $n (1 .. 2) {
            $c = $srv->accept or last;
            ($head, $body) = read_request($c);
            print $LOG "=== request $n\n$body\n";
            print $c "HTTP/1.0 200 OK\r\nContent-Type: application/x-ndjson\r\n\r\n";
            if ($n == 1) {
                # a streamed native tool call, fragmented like ollama's
                print $c '{"message":{"role":"assistant","tool_calls":[{"id":"call_1","function":{"name":"write","arguments":"{\"path\":"}}]},"done":false}
';
                print $c '{"message":{"role":"assistant","tool_calls":[{"function":{"arguments":"\"a.txt\",\"content\":\"hi\"}"}}]},"done":false}
';
                print $c '{"message":{"role":"assistant","content":""},"done":true}
';
            } else {
                # the way a natively trained model ends a task: a plain
                # answer with no tool call. no done block, no fence.
                print $c '{"message":{"role":"assistant","content":"All set."},"done":false}
';
                print $c '{"message":{"role":"assistant","content":""},"done":true}
';
            }
            close $c;
        }
    });
    close $srv;

    local $ENV{OA_SESSION_DIR} = $sessdir;
    my ($out, $rc) = run_oa1($dir, $port, 'ollama', '-y', 'write hi to a.txt');
    kill 'TERM', $pid; waitpid($pid, 0);
    is($rc, 0, 'native ollama: exit 0') or diag($out);
    like($out, qr/\*\*write\*\* `\{.*"path":"a\.txt".*\}` ok/, 'the tool status shows the call as json, braces intact');
    like($out, qr/All set\./, 'the final answer was printed');
    my $aw = slurp(File::Spec->catfile($dir, 'a.txt'));
    is($aw, 'hi', 'the write tool ran through the streamed native tool call');

    my @bodies = bodies_of($log);
    is(scalar(@bodies), 2, 'native ollama: two model calls - the loop ended on an answer with no tool call, no done block');
    like($bodies[0], qr/"tools":\[\{.*"type":"function"/s, 'first call: the tools array was sent');
    unlike($bodies[0], qr/"role":"tool"/s, 'first call: no tool results yet');
    like($bodies[1], qr/"tool_calls":\[\{"function":\{.*"name":"write".*\},"id":"call_1","type":"function"\}\]/s, 'second call: the assistant echo keeps the calls in wire shape');
    like($bodies[1], qr/"content":"wrote 2 chars to a\.txt","role":"tool","tool_call_id":"call_1"/s, 'second call: the result goes back as a role:tool message naming its call');

    my @sess = glob(File::Spec->catfile($sessdir, 'sess-*.jsonl'));
    is(scalar(@sess), 1, 'one session file');
    my $sa = slurp($sess[0]);
    like($sa, qr/"role":"tool","tool_call_id":"call_1"/, 'the transcript keeps the role:tool result, resumable');
}

# ---------------------------------------------------------------------------
# 2. native on the openai path: tools out, one message of tool_calls in.
# ---------------------------------------------------------------------------
{
    my $h;
    open($h, '>', File::Spec->catfile($dir, 'hello.txt')) or die "hello.txt: $!";
    print $h "hello\n";
    close $h;

    my $log = File::Spec->catfile($dir, 'openai.log');
    my $srv = IO::Socket::INET->new(
        Listen => 8, LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp', ReuseAddr => 1,
    ) or plan skip_all => "cannot listen: $!";
    my $port = $srv->sockport;
    my $pid = spawn(sub {
        my ($n, $c, $head, $body);
        my $LOG;
        open($LOG, '>', $log) or exit 1;
        $LOG->autoflush(1);
        for $n (1 .. 2) {
            $c = $srv->accept or last;
            ($head, $body) = read_request($c);
            print $LOG "=== request $n\n$body\n";
            print $c "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n";
            if ($n == 1) {
                print $c '{"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[{"id":"call_9","type":"function","function":{"name":"list","arguments":"{\"path\":\".\"}"}}]}}]}
';
            } else {
                print $c '{"choices":[{"index":0,"message":{"role":"assistant","content":"The directory holds hello.txt."}}]}
';
            }
            close $c;
        }
    });
    close $srv;

    my ($out, $rc) = run_oa1($dir, $port, 'openai', '-y', 'what is in this directory?');
    kill 'TERM', $pid; waitpid($pid, 0);
    is($rc, 0, 'native openai: exit 0') or diag($out);
    like($out, qr/\*\*list\*\* `\{"path":"\."\}` ok/, 'the list call ran through native tool_calls');
    like($out, qr/hello\.txt\s+6/, 'the listing shows the file and its size');
    like($out, qr/The directory holds hello\.txt\./, 'the final answer was printed');

    my @bodies = bodies_of($log);
    is(scalar(@bodies), 2, 'native openai: two model calls');
    like($bodies[0], qr/"tools":\[\{.*"type":"function"/s, 'first request: the tools array');
    like($bodies[1], qr/"tool_calls":\[\{"function":\{.*"name":"list".*\},"id":"call_9","type":"function"\}\]/s, 'second request: the assistant echo keeps the calls in wire shape');
    like($bodies[1], qr/"role":"tool","tool_call_id":"call_9"/, 'second request: the result is a role:tool message');
}

# ---------------------------------------------------------------------------
# 3. the fallback. an endpoint that refuses the tools parameter (an old
#    server, a gateway that drops unknown fields) gets one fight: oa1 drops
#    native for the rest of the session and finishes on the fence protocol.
# ---------------------------------------------------------------------------
{
    my $h;
    open($h, '>', File::Spec->catfile($dir, 'hello.txt')) or die "hello.txt: $!";
    print $h "hello\n";
    close $h;

    my $log = File::Spec->catfile($dir, 'fallback.log');
    my $srv = IO::Socket::INET->new(
        Listen => 8, LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp', ReuseAddr => 1,
    ) or plan skip_all => "cannot listen: $!";
    my $port = $srv->sockport;
    my $pid = spawn(sub {
        my ($n, $c, $head, $body);
        my $LOG;
        open($LOG, '>', $log) or exit 1;
        $LOG->autoflush(1);
        for $n (1 .. 3) {
            $c = $srv->accept or last;
            ($head, $body) = read_request($c);
            print $LOG "=== request $n\n$body\n";
            if ($body =~ /"tools"/) {
                # the refusal that triggers the fallback
                print $c "HTTP/1.0 400 Bad Request\r\nContent-Type: application/json\r\n\r\n";
                print $c '{"error":"unknown field: tools"}
';
            } else {
                print $c "HTTP/1.0 200 OK\r\nContent-Type: application/x-ndjson\r\n\r\n";
                if ($n == 2) {
                    print $c '{"message":{"role":"assistant","content":"Let me look.\n```tool\n{\"tool\":\"list\",\"args\":{\"path\":\".\"}}\n```\n"},"done":false}
';
                } else {
                    print $c '{"message":{"role":"assistant","content":"There is hello.txt.\n```tool\n{\"tool\":\"done\",\"args\":{\"summary\":\"It holds hello.txt.\"}}\n```\n"},"done":false}
';
                }
                print $c '{"message":{"role":"assistant","content":""},"done":true}
';
            }
            close $c;
        }
    });
    close $srv;

    my ($out, $rc) = run_oa1($dir, $port, 'ollama', '-y', 'what is in this directory?');
    kill 'TERM', $pid; waitpid($pid, 0);
    is($rc, 0, 'fallback: exit 0') or diag($out);
    like($out, qr/hello\.txt\s+6/, 'the fence protocol finished the task');
    like($out, qr/\[done\]/, 'the done block ended the fence task, as it does there');

    my @bodies = bodies_of($log);
    is(scalar(@bodies), 3, 'fallback: one refused native call, then the fence protocol');
    like($bodies[0], qr/"tools":\[/, 'first request tried native (and was refused)');
    unlike($bodies[1], qr/"tools":\[/, 'second request: the session runs on the fence protocol now');
    unlike($bodies[2], qr/"tools":\[/, 'third request stays on the fence protocol');
    like($bodies[1], qr/```tool/, 'second request: the system prompt teaches the fence protocol again');
}

# ---------------------------------------------------------------------------
# 4. a conversational native reply ends the turn with no nudge: the model
#    was trained to answer questions without calling tools, and oa1 must
#    not make it explain why.
# ---------------------------------------------------------------------------
{
    my $srv = IO::Socket::INET->new(
        Listen => 8, LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp', ReuseAddr => 1,
    ) or plan skip_all => "cannot listen: $!";
    my $port = $srv->sockport;
    my $pid = spawn(sub {
        my ($c, $head, $body);
        $c = $srv->accept or return;
        ($head, $body) = read_request($c);
        print $c "HTTP/1.0 200 OK\r\nContent-Type: application/x-ndjson\r\n\r\n";
        print $c '{"message":{"role":"assistant","content":"Hello there."},"done":false}
';
        print $c '{"message":{"role":"assistant","content":""},"done":true}
';
        close $c;
        # a second request would be a nudge loop; the alarm below catches it
    });
    close $srv;

    my ($out, $rc) = run_oa1($dir, $port, 'ollama', '-q', 'hello');
    kill 'TERM', $pid; waitpid($pid, 0);
    is($rc, 0, 'conversational native: exit 0') or diag($out);
    like($out, qr/Hello there\./, 'the answer was printed with no nudge, one call only');
}

done_testing;
