use strict;
use warnings;
use Test::More tests => 20;

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
