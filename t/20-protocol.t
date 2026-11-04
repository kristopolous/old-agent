use strict;
use warnings;
use lib 'lib';
use Test::More;
use OldAgent::Protocol;

plan tests => 19;

my $c;

$c = OldAgent::Protocol::parse("let me look\n\n```tool\n{\"tool\":\"read\",\"args\":{\"path\":\"a.c\"}}\n```\n");
is(scalar(@$c), 1, 'one call');
is($c->[0]{tool}, 'read', 'tool name');
is($c->[0]{args}{path}, 'a.c', 'args');

$c = OldAgent::Protocol::parse("```json\n{\"tool\":\"bash\",\"args\":{\"cmd\":\"ls\"}}\n```");
is($c->[0]{tool}, 'bash', 'json fence works');
is($c->[0]{args}{cmd}, 'ls', 'json fence args');

$c = OldAgent::Protocol::parse("```tool\n{\"tool\":\"write\",\"path\":\"x\",\"content\":\"hi\"}\n```");
is($c->[0]{args}{path}, 'x', 'flat args are collected');
is($c->[0]{args}{content}, 'hi', 'flat content');

$c = OldAgent::Protocol::parse("```tool\n{\"name\":\"list\",\"arguments\":{\"path\":\".\"}}\n```");
is($c->[0]{tool}, 'list', 'name/arguments spelling');

$c = OldAgent::Protocol::parse("```tool\n{\"tool\":\"read\",\"args\":{\"path\":\"a\"}}\n```\nand\n```tool\n{\"tool\":\"read\",\"args\":{\"path\":\"b\"}}\n```");
is(scalar(@$c), 2, 'two calls in one reply');

$c = OldAgent::Protocol::parse("TOOL: {\"tool\":\"done\",\"args\":{\"summary\":\"all good\"}}");
is($c->[0]{tool}, 'done', 'bare TOOL: line');
is($c->[0]{args}{summary}, 'all good', 'bare TOOL: args');

$c = OldAgent::Protocol::parse("```tool\n{\"tool\":\"read\",\"args\":{\"path\":\"unterminated\"}}\n");
is(scalar(@$c), 1, 'unterminated fence still parsed');

$c = OldAgent::Protocol::parse("```tool\n{\"tool\":\"read\",\"args\":{\"path\":\"a\"}}\n```\n```tool\n{\"tool\":\"read\",\"args\":{\"path\":\"a\"}}\n```");
is(scalar(@$c), 1, 'duplicate calls collapse');

$c = OldAgent::Protocol::parse("no tools here, just talk");
is(scalar(@$c), 0, 'prose alone is not a tool call');

$c = OldAgent::Protocol::parse("```tool\n{\"tool\":\"read\",\"args\":{\"path\":\"x\"},}\n```");
is($c->[0]{args}{path}, 'x', 'trailing comma repaired');

$c = OldAgent::Protocol::parse("```tool\n{\"tool\":\"bash\",\"args\":{\"cmd\":\"echo }\"}}\n```");
is($c->[0]{args}{cmd}, 'echo }', 'brace inside a string is not a delimiter');

my $block = OldAgent::Protocol::results_block([
    { tool => 'read', ok => 1, output => "line1\nline2" },
    { tool => 'bash', ok => 0, output => 'boom' },
]);
like($block, qr/^```result/, 'results are fenced');
like($block, qr/"tool":"read"/, 'result names the tool');
like($block, qr/\\nline2/, 'newlines in results are escaped');
