use strict;
use warnings;
use Test::More tests => 31;

use lib 'lib';
use OldAgent::Protocol;
use OldAgent::JSON;

# --- native qwen-style tool-call markup ---------------------------------
# some thinking models refuse the fence protocol and emit their own form.

my $c = OldAgent::Protocol::parse(
    '<|tool_call>call:bash{command: "echo HI"}<tool_call|>');
is(scalar @$c, 1, 'native call parsed');
is($c->[0]{tool}, 'bash', 'native tool name');
is($c->[0]{args}{command}, 'echo HI', 'native quoted arg');

$c = OldAgent::Protocol::parse('Sure: <|tool_call>call:read{path: "/etc/hosts"}<tool_call|> done');
is(scalar @$c, 1, 'native call with prose around it');
is($c->[0]{tool}, 'read', 'native read tool');
is($c->[0]{args}{path}, '/etc/hosts', 'native path arg');

$c = OldAgent::Protocol::parse('<|tool_call>call:bash{command: ls -la}<tool_call|>');
is(scalar @$c, 1, 'native bareword arg parsed');
is($c->[0]{args}{command}, 'ls -la', 'bareword value captured');

$c = OldAgent::Protocol::parse('<|tool_call>call:bash{command: "a", timeout: 5}<tool_call|>');
is(scalar @$c, 1, 'native multi-arg');
is($c->[0]{args}{command}, 'a', 'multi-arg first');
is($c->[0]{args}{timeout}, 5, 'multi-arg second (bare number)');

# --- NDJSON (streamed) bodies ------------------------------------------
my $nd = join("\n",
    '{"model":"m","message":{"role":"assistant","content":"He"}}',
    '{"model":"m","message":{"role":"assistant","content":"llo"}}',
    '{"model":"m","message":{"role":"assistant","content":" world"},"done":true}');
my ($obj, $err) = OldAgent::JSON::parse_ndjson($nd);
ok(!$err, 'ndjson parsed without error');
is($obj->{message}{content}, 'Hello world', 'ndjson content concatenated');

# --- OpenAI-style function calling (what modern models emit) -----------
$c = OldAgent::Protocol::parse('{"function": "bash", "args": {"command": "cat /etc/hosts"}}');
is(scalar @$c, 1, 'function-call parsed');
is($c->[0]{tool}, 'bash', 'function name -> tool');
is($c->[0]{args}{command}, 'cat /etc/hosts', 'function args');

$c = OldAgent::Protocol::parse('{"name": "read", "arguments": "{\\"path\\": \\"x\\"}"}');
is(scalar @$c, 1, 'name+arguments-string parsed');
is($c->[0]{tool}, 'read', 'name -> tool');
is($c->[0]{args}{path}, 'x', 'arguments string decoded');

$c = OldAgent::Protocol::parse('{"function": {"name": "bash", "arguments": "{}"}}');
is(scalar @$c, 1, 'openai function object parsed');

# --- OpenAI-style XML markup (<function=...>...</function>) ---
{
    my $xml = "<|tool_call>\n<function=Read>\n<parameter=file_path>\n/tmp/oa-task/fruits.txt\n</parameter>\n</function>\n</tool_call|>";
    my $calls = OldAgent::Protocol::parse($xml);
    is(scalar(@$calls), 1, 'xml: one call');
    is($calls->[0]{tool}, 'read', 'xml: tool name lowercased');
    is($calls->[0]{args}{file_path}, '/tmp/oa-task/fruits.txt', 'xml: file_path arg');
}
{
    my $xml = "<function=write>\n<parameter name=\"path\">/tmp/a.txt</parameter>\n<parameter name=\"content\">hello</parameter>\n</function>";
    my $calls = OldAgent::Protocol::parse($xml);
    is(scalar(@$calls), 1, 'xml name= form: one call');
    is($calls->[0]{tool}, 'write', 'xml name= form: tool');
    is($calls->[0]{args}{path}, '/tmp/a.txt', 'xml name= form: path arg');
    is($calls->[0]{args}{content}, 'hello', 'xml name= form: content arg');
}
{
    # visible() strips XML + native wrapper from prose
    my $xml = "<|tool_call>\n<function=Read>\n<parameter=file_path>\n/tmp/x\n</parameter>\n</function>\n</tool_call|>";
    my ($p, $t, $r) = OldAgent::Protocol::visible($xml);
    is($p, '', 'visible: xml stripped from prose');
    ok(length $t, 'visible: xml kept as tool line');
}
{
    # visible() strips a bare {"tool":...} object from prose
    my $txt = "All done here.\n{\"tool\":\"done\",\"args\":{\"summary\":\"x\"}}";
    my ($p, $t) = OldAgent::Protocol::visible($txt);
    is($p, 'All done here.', 'visible: bare tool json stripped from prose');
    ok($p !~ /tool/, 'visible: no tool json in prose');
}
