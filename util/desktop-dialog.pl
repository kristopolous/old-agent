# drives the ONE path that used to crash the desktop: a Commands-menu
# item opening a one-field dialog from inside Tk's main loop, answered,
# applied, and remembered in the config file. runs under xvfb.
use strict;
use warnings;
use lib 'lib';
use Tk;
use OldAgent::Config ();
use OldAgent::Desktop ();

my $dir = "/tmp/oa-dialog-$$";
mkdir($dir) unless -d $dir;
$ENV{OLDAGENT_CONFIG} = "$dir/rc";
$ENV{OLDAGENT_HOME}   = "$dir/home";
mkdir($ENV{OLDAGENT_HOME}) unless -d $ENV{OLDAGENT_HOME};

my $cfg = OldAgent::Config->load(overrides => { provider => 'echo' });
my $app = OldAgent::Desktop->new(config => $cfg);
my $rw = $app->{root};
my $fail = 0;

# the user's real path: menu callback inside the main loop
$rw->after(400, sub { $app->_arg_cmd('model', 'Set model', 'gpt-4o-mini') });

$rw->after(1000, sub {
    my ($dlg);
    for my $child ($rw->winfo('children')) {
        my $c = eval { $child->winfo('class') };
        $dlg = $child if $c && $c eq 'Toplevel';
    }
    if (!$dlg) { print "FAIL no dialog\n"; $fail = 1; $rw->destroy; exit 1 }
    my ($e, $ok);
    for my $k ($dlg->winfo('children')) {
        my $c = eval { $k->winfo('class') };
        $e  = $k if $c && $c eq 'Entry';
        $ok = $k if $c && $c eq 'Button' && eval { $k->cget('-text') } eq 'OK';
    }
    if (!$e || !$ok) { print "FAIL dialog widgets\n"; $fail = 1; $rw->destroy; exit 1 }
    $e->delete(0, 'end');
    $e->insert(0, 'dialog-model');
    $ok->invoke;
    print "dialog answered\n";
});

$rw->after(2000, sub {
    my $m = $cfg->get('model');
    my $persisted = 'no';
    if (open my $fh, '<', $ENV{OLDAGENT_CONFIG}) {
        local $/;
        my $c = <$fh>;
        $persisted = ($c =~ /model = dialog-model/) ? 'yes' : 'NO';
        close $fh;
    }
    print "RESULT model=$m persisted=$persisted\n";
    if ($m ne 'dialog-model' || $persisted ne 'yes') { $fail = 1 }
    $rw->destroy;
});

Tk::MainLoop();
my @left = glob("$dir/*");
unlink(@left);
rmdir($dir);
exit($fail ? 1 : 0);
