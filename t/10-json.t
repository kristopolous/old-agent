use strict;
use warnings;
use lib 'lib';
use Test::More;
use OldAgent::JSON;

plan tests => 28;

# --- decode -----------------------------------------------------------
my ($v, $err);

($v, $err) = OldAgent::JSON::decode('{"a":1,"b":"two","c":[3,true,null],"d":{"e":"f"}}');
ok(!$err, 'decode nested');
is($v->{a}, 1, 'number');
is($v->{b}, 'two', 'string');
is($v->{c}[0], 3, 'array number');
is($v->{c}[1], 1, 'true is 1');
is($v->{c}[2], undef, 'null is undef');
is($v->{d}{e}, 'f', 'nested hash');

($v, $err) = OldAgent::JSON::decode('"line\nbreak\ttab \"quoted\" \\\\ back"');
ok(!$err, 'decode escapes');
is($v, "line\nbreak\ttab \"quoted\" \\ back", 'escapes decoded');

($v, $err) = OldAgent::JSON::decode('"\u00e9\u4e2d\ud83d\ude00"');
ok(!$err, 'decode unicode');
is($v, "\xc3\xa9\xe4\xb8\xad\xf0\x9f\x98\x80", 'unicode became utf-8 bytes');

($v, $err) = OldAgent::JSON::decode('  { "n" : -1.5e3 }  ');
ok(!$err, 'whitespace and exponent');
is($v->{n}, -1500, 'number value');

($v, $err) = OldAgent::JSON::decode('{"a":1,}');
ok($err, 'trailing comma is rejected strictly');
($v, $err) = OldAgent::JSON::decode_lenient('{"tool":"read","args":{"path":"x"},}');
ok(!$err, 'lenient repairs trailing comma');
is($v->{args}{path}, 'x', 'lenient value');

($v, $err) = OldAgent::JSON::decode('{"a"');
ok($err, 'unterminated object errors');

# --- encode -----------------------------------------------------------
is(OldAgent::JSON::encode({ b => 'x', a => 'y' }), '{"a":"y","b":"x"}', 'sorted keys');
is(OldAgent::JSON::encode([1, '2']), '["1","2"]', 'plain scalars are quoted');
is(OldAgent::JSON::encode({ n => OldAgent::JSON::num(42), s => OldAgent::JSON::str('42') }),
   '{"n":42,"s":"42"}', 'num/str wrappers');
is(OldAgent::JSON::encode('a"b'), '"a\\"b"', 'quote escaped');
is(OldAgent::JSON::encode("tab\there"), '"tab\\there"', 'tab escaped');
is(OldAgent::JSON::encode(undef), 'null', 'undef is null');
is(OldAgent::JSON::encode({}), '{}', 'empty object');

# --- round trip -------------------------------------------------------
my $deep = { a => ['one', ['two', ['three', { b => 'c' }]]], d => "x\ny" };
my $text = OldAgent::JSON::encode($deep);
my ($back, $berr) = OldAgent::JSON::decode($text);
ok(!$berr, 'round trip decodes');
is_deeply($back, $deep, 'round trip matches');

# --- lenient scanning -------------------------------------------------
my @objs = OldAgent::JSON::extract_objects('prose {"a":{"b":"} not a close"}} more {"c":1}');
is(scalar(@objs), 2, 'found two objects');
is_deeply([sort map { /"(\w)"/ ? $1 : '' } @objs], ['a', 'c'], 'right objects');
