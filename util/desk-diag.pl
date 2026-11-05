use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Tk;
use OldAgent::Config ();
use OldAgent::Desktop ();

# isolated HOME so we never clobber the real user config
my $fake_home = '/tmp/oa-desk-diag-' . $$;
system('rm', '-rf', $fake_home);
mkdir $fake_home or die "mkdir: $!";
$ENV{HOME} = $fake_home;
$ENV{OLDAGENT_CONFIG} = "$fake_home/rc";
system('rm', '-f', '/tmp/oa-desk-child.log');
$ENV{OA_CHILD_LOG}    = '/tmp/oa-desk-child.log';
END { system('rm', '-rf', $fake_home) }

my $which = $ENV{OA_DIAG_KIND} || 'ollama';
my %cfgs = (
    ollama  => { provider => 'ollama',  base_url => 'http://10.0.0.1:11434',
                 model => 'qwen3.8', thinking => '0', tools => '1',
                 approve => 'auto', max_tokens => '2048', api_key => '' },
    proxy   => { provider => 'openai-compat', base_url => 'https://9ol.es/11434',
                 model => 'qwen3.8',
                 api_key => ($ENV{OPENROUTER_API_KEY} || 'none'),
                 tools => '1', approve => 'auto', max_tokens => '2048' },
);
my $cfg = OldAgent::Config->load(no_files => 1, overrides => $cfgs{$which});
print "KIND=$which  provider=", $cfg->get('provider'),
      " base=", $cfg->get('base_url'), " model=", $cfg->get('model'), "\n";

my $app = OldAgent::Desktop->new(config => $cfg);

my $text = 'Read the file /tmp/oa-task/fruits.txt and tell me its contents.';
$app->{entry}->insert(0, $text);
$app->_send;

my $started = time();
my $polled = 0;
my $h = $app->{root}->after(150, sub {
    $polled++;
    my $hist = $app->{agent}{history};
    my $last = @$hist ? $hist->[-1]{role} : '';
    if (!$app->{busy} && $last eq 'assistant') {
        print "REPLY ARRIVED after ~", time() - $started, "s; history=", scalar(@$hist), " msgs\n";
        $app->{root}->after('end', sub { exit 0 });
    } elsif (time() - $started > 120) {
        print "TIMEOUT: busy=", ($app->{busy} ? 1 : 0),
              " history=", scalar(@$hist), " last=", $last, "\n";
        $app->{root}->after('end', sub { exit 3 });
    }
});
Tk::MainLoop();
print "exited main loop\n";
