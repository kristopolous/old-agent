#!/usr/bin/env perl
# launch the real desktop pointed at the live ollama, keep it alive.
# run in the background; a separate snap.pl captures it.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Tk;
use OldAgent::Config ();
use OldAgent::Desktop ();

$ENV{OA_CHILD_LOG} = '/tmp/oa-desk-child.log';
system('rm', '-f', '/tmp/oa-desk-child.log');

# the live config: direct to the ollama the user pointed us at
my $cfg = OldAgent::Config->load(overrides => {
    provider => 'ollama',
    base_url => 'http://10.0.0.1:11434',
    model    => 'qwen3.8',
    thinking => '0',
    tools    => '1',
    approve  => 'auto',
    max_tokens => '2048',
    api_key  => '',
});

my $app = OldAgent::Desktop->new(config => $cfg);
print "DESKTOP UP provider=", $cfg->get('provider'),
      " base=", $cfg->get('base_url'), " model=", $cfg->get('model'), "\n";
Tk::MainLoop();
