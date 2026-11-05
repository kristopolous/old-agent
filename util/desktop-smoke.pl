use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Tk;
use OldAgent::Config ();
use OldAgent::Desktop ();
use OldAgent::Util ();

# isolated HOME so persistence checks never touch the real user config
my $fake_home = '/tmp/oa-desktop-smoke-' . $$;
system('rm', '-rf', $fake_home);
mkdir $fake_home or die "cannot mkdir $fake_home: $!";
$ENV{HOME} = $fake_home;
$ENV{OLDAGENT_CONFIG} = "$fake_home/rc";
END { system('rm', '-rf', $fake_home) }

my $cfg = OldAgent::Config->load(no_files => 1, overrides => {
    provider => 'echo', tools => 0,
});
my $app = OldAgent::Desktop->new(config => $cfg);

my $root = $app->{root};
my @fail;

# this Tk build: index('end') is one less than the real entry count, and
# type(i) beyond the last real entry repeats the last type - so the real
# entries are exactly 0..index('end')
sub mtypes {
    my ($m) = @_;
    my $end = $m->index('end');
    return join(",", map { $m->type($_) } (0 .. $end));
}

# ---- 1) menu bar: exactly File / Commands / Help cascades -------------
my $menu = $root->cget('-menu');
my $bar_types = mtypes($menu);
print "BAR: $bar_types\n";
push @fail, 'menus' unless $bar_types eq 'tearoff,cascade,cascade,cascade';

# ---- 2) Commands menu: every slash command present --------------------
my $cmds = $app->{cmds_menu};
my $cmds_types = mtypes($cmds);
print "COMMANDS: $cmds_types\n";
my $want_cmds = join(",", ('command') x 4, 'separator', ('command') x 7,
    'separator', ('command') x 3, 'separator', ('command') x 2,
    'cascade', 'cascade');   # 21 entries: 17 commands, 3 seps, 2 cascades
push @fail, 'cmds-shape' unless $cmds_types eq $want_cmds;

# ---- 3) File menu has the Recent cascade ------------------------------
my $file = $app->{file_menu};
my $file_types = mtypes($file);
print "FILE: $file_types\n";
push @fail, 'file-recent'
    unless $file_types eq 'command,command,command,separator,command,cascade';

my $help = $app->{help_menu};
my $help_types = mtypes($help);
print "HELP: $help_types\n";
push @fail, 'help-shape' unless $help_types eq 'command,command';

my $recent = $app->{recent};
my $recent_types = mtypes($recent);
print "RECENT: $recent_types\n";
push @fail, 'recent-shape' unless $recent_types eq 'command,command';

my $tools = $app->{tools_menu};
my $appr = $app->{appr_menu};
my $tools_types = mtypes($tools);
my $appr_types  = mtypes($appr);
print "TOOLS: $tools_types  APPROVAL: $appr_types\n";
push @fail, 'tools-shape' unless $tools_types eq 'radiobutton,radiobutton';
push @fail, 'appr-shape'  unless $appr_types  eq 'radiobutton,radiobutton';

# ---- 4) Tools toggle (same closure the radio items run) ---------------
$app->_set_tools('on');
push @fail, 'tools-on' unless $cfg->get('tools');
$app->_set_tools('off');
push @fail, 'tools-off' if $cfg->get('tools');
push @fail, 'tools-var' unless $app->{tools_var} eq 'off';

# ---- 5) dialog mechanics: the exact pump pattern _ask uses ------------
# (waitWindow is broken in this Tk build - it never returns; _ask instead
#  pumps $root->update until the dialog's winfo('exists') goes false)
my $dlg_ok;
my $d = $root->Toplevel(-title => 'smoke-dlg');
my $de = $d->Entry; $de->pack;
my $db = $d->Button(-text => 'OK', -command => sub {
    $dlg_ok = $de->get(); $d->destroy;
})->pack;
$d->after(50, sub { $de->insert(0, 'typed'); $db->invoke; });
while (eval { $d->winfo('exists') }) { $root->update; }
push @fail, 'dialog-mechanics' unless $dlg_ok eq 'typed';
print "DIALOG: got '$dlg_ok'\n";

# ---- 5b) arg command: what the Commands menu items run ----------------
# stub _ask: it no longer waits at all, it answers through a done
# callback - call it synchronously with the answer.
no warnings 'redefine';
*OldAgent::Desktop::_ask = sub { my ($s, %o) = @_; $o{done}->('new-model') };
$app->_arg_cmd('model', 'Set model', 'old-model');
push @fail, 'model-set' unless $cfg->get('model') eq 'new-model';
my $rc = OldAgent::Config::user_config_path();
my $persisted = '';
if (defined $rc && open my $fh, '<', $rc) { local $/; $persisted = <$fh>; $persisted = '' unless defined $persisted; close $fh }
push @fail, 'model-persisted' unless $persisted =~ /model = new-model/;
print "MODEL: now ", $cfg->get('model'), "  persisted: ",
      ($persisted =~ /model = new-model/ ? 'yes' : 'NO'), "\n";

# ---- 6) run menu commands through the REPL handler -------------------
# (config and history printf; the capture handle must speak PRINTF)
$app->_run_cmd('history');
$app->_run_cmd('config');
push @fail, 'config-cmd' unless $app->transcript_text =~ /^provider\s+echo/m;
push @fail, 'config-err' if $app->transcript_text =~ /PRINTF|error:/;

# ---- 7) send a message; echo provider, markdown gets tags -------------
my $entry = $app->{entry};
$entry->insert(0, '**hello world** and `some code` and *italic*');
$app->_send;

# the reply comes back from a child process: pump events until it lands
my $deadline = time + 10;
while ($app->{busy} && time < $deadline) {
    $root->update;
    sleep 0.05;
}

# ---- 8) save + reopen a session ---------------------------------------
my $sessdir = OldAgent::Desktop::session_dir();
my $path = $sessdir . '/smoke-test.json';
unlink $path;
$app->{session} = 'smoke-test';
$app->_run_cmd('save', $path);
my @hist1 = @{ $app->{agent}->history() };
my $turns = scalar(grep { $_->{role} eq 'user' } @hist1);
OldAgent::Desktop::remember_session('smoke-test', $path, $turns);
$app->new_session;
my $h2 = scalar(@{ $app->{agent}->history() });
push @fail, 'clear' if $h2 != 0;
$app->_load_path($path);
my @hist2 = @{ $app->{agent}->history() };
push @fail, 'roundtrip' unless @hist1 == @hist2 && @hist1;

# ---- 9) recent registry lists it --------------------------------------
my @reg = @{ OldAgent::Desktop::load_registry() };
my $found = grep { $_->{path} eq $path } @reg;
push @fail, 'registry' unless $found;
unlink $path;
{ my @r = OldAgent::Desktop::load_registry();
  OldAgent::Desktop::_write_json(OldAgent::Desktop::_registry_path(),
      [ grep { defined $_ && ref($_) eq 'HASH' ? ($_->{path} ne $path) : 1 } @r ]); }

# ---- 9b) geometry: entry spans its row, status has its own row below --
my $ge = $app->{entry};
my $gs = $app->{stat};
my $gb = $app->{btn_send};
my $g_ww = $root->winfo('width');
my $g_ew = $ge->winfo('width');
my $g_eh = $ge->winfo('height');
my $g_bh = $gb->winfo('height');
my $g_gy = $gs->winfo('y');
my $g_ey = $ge->winfo('y');
print "GEO: root=$g_ww entry w=$g_ew h=$g_eh send h=$g_bh (y=$g_ey) status y=$g_gy\n";
push @fail, 'entry-width'  if $g_ew < int($g_ww * 0.5);
push @fail, 'status-row'   if $g_gy <= $g_ey;
push @fail, 'entry-height' if abs($g_eh - $g_bh) > 1;
push @fail, 'input-small'  if $g_eh < 24;

# ---- 10) transcript + tags + status -----------------------------------
my $txt = $app->{txt};
print "CONTENT:\n", $app->transcript_text, "\n";
my @tags = $txt->tag('names');
print "TAGS: ", join(", ", sort @tags), "\n";
my $body = $app->transcript_text;
push @fail, 'mdbold' unless index($body, 'hello world') >= 0;
push @fail, 'status' unless $app->{stat}->cget('-text') =~ /session/;


$root->destroy;
if (@fail) {
    print "SMOKE FAILURES: @fail\n";
    exit 1;
}
print "DESKTOP SMOKE OK\n";
exit 0;
