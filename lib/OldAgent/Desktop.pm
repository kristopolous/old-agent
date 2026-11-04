package OldAgent::Desktop;
# A Tk front end on top of the same agent loop the terminal uses.
# Tk is not core perl, so this is loaded lazily and never on the
# critical path: without Tk, everything else in oldagent still works.
#
# The window has a menu bar whose items are the REPL's slash commands,
# run through the very same OldAgent::CLI::repl_command handler the
# terminal uses - so the menus can never drift from /help.  Sessions
# (the /save, /load files) get File > New / Save / Open / Recent,
# and a status line shows the current session, provider and model.

use strict;
use warnings;

use OldAgent ();
use OldAgent::Agent ();
use OldAgent::Textfmt ();
use OldAgent::Util ();
use OldAgent::JSON ();
eval { require OldAgent::CLI; 1 } or require OldAgent::CLI;

# ------------------------------------------------------------------ output

# A tied handle: while it is the selected filehandle, every plain
# `print` in the oldagent code lands in the transcript widget instead
# of the terminal.
package OldAgent::Desktop::_Out;
sub TIEHANDLE {
    my ($class, $w, $tag) = @_;
    return bless { w => $w, tag => $tag }, $class;
}
sub WRITE {
    my ($s, $str) = @_;
    return 1 unless length $str;
    $s->{w}->insert('end', $str, $s->{tag});
    $s->{w}->see('end');
    return 1;
}
sub CLOSE { return 1 }

# ---------------------------------------------------------------- sessions

package OldAgent::Desktop;

sub session_dir {
    my $home = $ENV{HOME} ? $ENV{HOME}
              : ($ENV{USERPROFILE} ? $ENV{USERPROFILE} : '.');
    my $dir = $home . '/.oldagent/sessions';
    _mkdir_p($dir);
    return $dir;
}

# mkdir -p, without File::Path (not in every old perl)
sub _mkdir_p {
    my ($path) = @_;
    return 1 if -d $path;
    my $parent = ($path =~ m{^(.*)/[^/]+$}) ? $1 : '';
    _mkdir_p($parent) if length $parent && $parent ne '/' && !-d $parent;
    return mkdir($path) || -d $path;
}

sub _registry_path { OldAgent::Desktop::session_dir() . '/.index.json' }

sub _read_json {
    my ($path) = @_;
    open(my $fh, '<', $path) or return undef;
    my $s = do { local $/; <$fh> };
    close($fh);
    my ($d, $err) = eval { OldAgent::JSON::decode($s) };
    return $@ ? undef : ($err ? undef : $d);
}

sub _write_json {
    my ($path, $data) = @_;
    my $tmp = $path . '.tmp' . $$;
    OldAgent::Util::spew($tmp, OldAgent::JSON::encode($data));
    rename($tmp, $path) or die "cannot write $path: $!\n";
}

sub load_registry {
    my $r = OldAgent::Desktop::_read_json(OldAgent::Desktop::_registry_path());
    return ref($r) eq 'ARRAY' ? $r : [];
}

sub remember_session {
    my ($name, $path, $turns) = @_;
    my @reg = @{ OldAgent::Desktop::load_registry() };
    @reg = grep { $_->{path} ne $path } @reg;
    unshift @reg, { name => $name, path => $path, mtime => time(), turns => $turns };
    @reg = @reg[0 .. 9] if @reg > 10;
    OldAgent::Desktop::_write_json(OldAgent::Desktop::_registry_path(), \@reg);
}

# --------------------------------------------------------------------- app

sub new {
    my ($class, %a) = @_;
    my $cfg = $a{config} or die "desktop needs a config\n";

    eval { require Tk; 1 } or do {
        die "Tk is not installed on this perl (try: apt-get install perl-tk / "
          . "cpan Tk). the terminal interface needs no Tk and still works.\n";
    };

    my $self = {
        cfg     => $cfg,
        agent   => OldAgent::Agent->new(config => $cfg),
        root    => Tk::MainWindow->new(-title => "oldagent " . OldAgent::version()),
        session => 'untitled',
        busy    => 0,
    };
    bless $self, $class;
    $self->_build();
    $self->_redraw();
    return $self;
}

sub _build {
    my ($self) = @_;
    my $rw = $self->{root};

    # ---- menu bar: File / Commands / Help -----------------------------
    # this Tk build's ->Cascade returns a stub with no ->add, and
    # Menu(-label) is rejected. the recipe that works (verified under
    # xvfb): a plain menubar, the three top-level submenus declared back
    # to back, then each menu filled depth-first - a menu's nested
    # submenu is created as soon as its plain items are done, before
    # touching the next top-level menu. interleaving loses entries.
    # (also: in this build index('end') is one less than the real count)
    my $menubar = $rw->Menu();
    my $file    = _bar($menubar, 'File');
    my $cmds    = _bar($menubar, 'Commands');
    my $help    = _bar($menubar, 'Help');
    $self->{menubar}   = $menubar;
    $self->{file_menu} = $file;
    $self->{cmds_menu} = $cmds;
    $self->{help_menu} = $help;
    $rw->configure(-menu => $menubar);

    # File - plain items only (the Recent submenu is created at the end)
    $self->_item($file, 'New session',     sub { $self->new_session() });
    $self->_item($file, 'Save session...', sub { $self->save_session() });
    $self->_item($file, 'Open session...', sub { $self->open_session() });
    $file->Separator();
    $self->_item($file, 'Quit', sub { $rw->destroy });

    # File's nested submenu, while File is still the active menu
    $self->{recent} = _bar($file, 'Recent');
    $self->_rebuild_recent();

    # Commands - one item per slash command, same handler as the REPL
    $self->_item($cmds, 'Help',                 sub { $self->_show_help() });
    $self->_item($cmds, 'History',              sub { $self->_run_cmd('history') });
    $self->_item($cmds, 'Undo last exchange',   sub { $self->_run_cmd('undo');  $self->_redraw() });
    $self->_item($cmds, 'Clear conversation',   sub { $self->_run_cmd('clear'); $self->_redraw() });
    $cmds->Separator();
    $self->_item($cmds, 'Model...',             sub { $self->_arg_cmd('model', 'Set model', $self->{cfg}->get('model')) });
    $self->_item($cmds, 'Provider or URL...',   sub { $self->_arg_cmd('provider', 'Set provider (name or url)', $self->{cfg}->get('provider')) });
    $self->_item($cmds, 'Base URL...',          sub { $self->_arg_cmd('base-url', 'Set base url', $self->{cfg}->get('base_url') || '') });
    $self->_item($cmds, 'Max turns...',         sub { $self->_arg_cmd('turns', 'Max tool round trips per message', $self->{cfg}->get('max_turns')) });
    $self->_item($cmds, 'Extra instructions...', sub { $self->_arg_cmd('system', 'Standing instructions for the model', '') });
    $self->_item($cmds, 'Working directory...', sub { $self->_arg_cmd('cd', 'Change working directory to', OldAgent::Util::cwd()) });
    $self->_item($cmds, 'Shell command...',     sub { $self->_arg_cmd('sh', 'Run a shell command now (outside the conversation)', '') });
    $cmds->Separator();
    $self->_item($cmds, 'Doctor (environment report)', sub { $self->_run_cmd('doctor') });
    $self->_item($cmds, 'Show config',                sub { $self->_run_cmd('config') });
    $self->_item($cmds, 'Version',                    sub { $self->_run_cmd('version') });
    $cmds->Separator();
    $self->_item($cmds, 'Save session...',           sub { $self->save_session() });
    $self->_item($cmds, 'Open session...',           sub { $self->open_session() });

    # Commands' nested submenus, while Commands is still the active menu
    my $tools = _bar($cmds, 'Tools');
    $self->{tools_menu} = $tools;
    $self->{tools_var} = $self->{cfg}->get('tools') ? 'on' : 'off';
    $tools->add('radiobutton', -label => 'On',
        -variable => \$self->{tools_var}, -value => 'on',
        -command  => sub { $self->_set_tools('on') });
    $tools->add('radiobutton', -label => 'Off',
        -variable => \$self->{tools_var}, -value => 'off',
        -command  => sub { $self->_set_tools('off') });

    my $appr = _bar($cmds, 'Bash approval');
    $self->{appr_menu} = $appr;
    $self->{appr_var} = ($self->{cfg}->get('approve') eq 'auto') ? 'auto' : 'ask';
    $appr->add('radiobutton', -label => 'Ask first',
        -variable => \$self->{appr_var}, -value => 'ask',
        -command  => sub { $self->_set_approve('ask') });
    $appr->add('radiobutton', -label => 'Run without asking',
        -variable => \$self->{appr_var}, -value => 'auto',
        -command  => sub { $self->_set_approve('auto') });

    # Help
    $self->_item($help, 'REPL reference', sub {
        $self->_show_text('oldagent REPL reference', OldAgent::CLI::_repl_help());
    });
    $self->_item($help, 'About oldagent', sub {
        $self->_show_text('About oldagent',
            "oldagent " . OldAgent::version() . "\n\n"
            . "a pure-perl agent that runs on a perl from around 2000.\n"
            . "this window and the terminal share one agent loop;\n"
            . "the menus below are the /commands, run by the same code.\n"
            . "sessions are plain files: " . OldAgent::Desktop::session_dir() . "\n");
    });

    # ---- transcript -----------------------------------------------------
    my $txt = $rw->Scrolled('Text',
        -wrap   => 'word',
        -font   => 'Helvetica 11',
        -bg     => '#fdfdfd',
        -fg     => '#111111',
        -height => 20,
        -width  => 82,
        -state  => 'normal',
    )->pack(-side => 'top', -fill => 'both', -expand => 1);

    my %defs = OldAgent::Textfmt::tk_tagdefs();
    for my $name (sort keys %defs) {
        my %o   = %{ $defs{$name} };
        my %opt;
        $opt{-font}       = delete $o{font}      if defined $o{font};
        $opt{-foreground} = delete $o{fg}        if defined $o{fg};
        $opt{-background} = delete $o{bg}        if defined $o{bg};
        $opt{-underline}  = delete $o{underline} if defined $o{underline};
        $txt->tag('configure', $name, %opt);
    }
    $txt->tag('configure', 'user',     -font => 'Helvetica 11 bold', -foreground => '#0a58ca');
    $txt->tag('configure', 'userhead', -font => 'Helvetica 10 bold', -foreground => '#8a8a8a');
    $txt->tag('configure', 'sys',      -foreground => '#666666');
    $txt->tag('configure', 'note',     -foreground => '#555555', -font => 'Helvetica 10 italic');
    $txt->tag('configure', 'err',      -foreground => '#b00020');
    $self->{txt} = $txt;

    # ---- input row --------------------------------------------------------
    my $bar = $rw->Frame()->pack(-side => 'bottom', -fill => 'x');
    my $entry = $rw->Entry(-font => 'Helvetica 11', -relief => 'sunken', -bg => '#fffef5')
        ->pack(-side => 'left', -fill => 'x', -expand => 1, -padx => [8, 4], -pady => 6);
    $self->{btn_send} = $rw->Button(-text => 'Send', -default => 'active',
        -command => sub { $self->_send })->pack(-side => 'right', -padx => 2, -pady => 6);
    $rw->Button(-text => 'Clear',
        -command => sub { $self->_run_cmd('clear'); $self->_redraw() })->pack(-side => 'right', -padx => 2, -pady => 6);
    $rw->Button(-text => 'Undo',
        -command => sub { $self->_run_cmd('undo'); $self->_redraw() })->pack(-side => 'right', -padx => [2, 8], -pady => 6);
    $entry->bind('<Return>', sub { $self->_send });
    $entry->focus;
    $self->{entry} = $entry;

    # ---- status line ------------------------------------------------------
    my $stat = $rw->Label(-anchor => 'w', -relief => 'sunken',
        -bg => '#eeeeee', -font => 'Helvetica 10', -padx => 8)
        ->pack(-side => 'bottom', -fill => 'x');
    $self->{stat} = $stat;
    $self->_status();
}

# -------------------------------------------------------------- menu items

# add a command item to a menu
sub _item {
    my ($self, $menu, $label, $cb) = @_;
    return $menu->add('command', -label => $label, -command => $cb);
}

# build a labelled submenu bar (works around this Tk build's stub Cascade)
sub _bar {
    my ($parent, $label) = @_;
    my $m = $parent->Menu(-tearoff => 0);
    $parent->add('cascade', -label => $label, -menu => $m);
    return $m;
}

sub _set_tools {
    my ($self, $v) = @_;
    $self->{cfg}->set(tools => $v eq 'on' ? 1 : 0);
    $self->{agent}{tools_on} = $v eq 'on' ? 1 : 0;
    my $p = $self->{cfg}->remember('tools');
    $self->_status();
    $self->_flash("tools $v" . ($p ? "  (remembered in $p)" : ''));
}

sub _set_approve {
    my ($self, $v) = @_;
    $self->{cfg}->set(approve => $v);
    my $p = $self->{cfg}->remember('approve');
    my $s = $v eq 'auto' ? 'bash runs without asking' : 'bash asks first';
    $self->_flash($s . ($p ? "  (remembered in $p)" : ''));
}

sub _rebuild_recent {
    my ($self) = @_;
    my $m = $self->{recent} or return;
    $m->delete(0, 'end');
    my @reg = @{ OldAgent::Desktop::load_registry() };
    unless (@reg) {
        $m->add('command', -label => '(no sessions yet)', -state => 'disabled');
    }
    for my $e (@reg) {
        my $e = $e;
        $m->add('command',
            -label => $e->{name} . '  (' . ($e->{turns} || 0) . ' turns)',
            -command => sub { $self->_load_path($e->{path}) });
    }
    $m->add('command', -label => 'Refresh',
        -command => sub { $self->_rebuild_recent() });
}

# ------------------------------------------------- commands via the REPL --

# run one of the /commands through the same handler the terminal uses,
# capturing its output into the transcript.
sub _run_cmd {
    my ($self, $c, $rest) = @_;
    $rest = defined $rest ? $rest : '';
    my $cap;
    unless (tie(*OA_CAP_1, 'OldAgent::Desktop::_Out', $self->{txt}, 'sys')) {
        $self->_flash('cannot capture output');
        return;
    }
    my $prev = select(OA_CAP_1);
    my $r = eval { OldAgent::CLI::repl_command($c, $rest,
        agent => $self->{agent}, config => $self->{cfg}, term => undef) };
    select($prev);
    if ($@) {
        my $txt = $self->{txt};
        $txt->insert('end', "error: $@\n", 'err');
        $txt->see('end');
    }
    $self->_status();
    return $r;
}

# a command that asks for an argument first
# slash command -> config keys to persist after it changes them
my %PERSIST_KEYS = (
    model      => [qw(model)],
    provider   => [qw(provider base_url api_key key_env)],
    'base-url' => [qw(base_url)],
    turns      => [qw(max_turns)],
    system     => [qw(system_extra)],
);

sub _arg_cmd {
    my ($self, $c, $title, $default) = @_;
    my $a = $self->_ask(title => $title, prompt => '/$c ...', default => $default);
    return unless defined $a && length $a;
    $self->_run_cmd($c, $a);
    my $keys = $PERSIST_KEYS{$c};
    if ($keys) {
        my $p = $self->{cfg}->remember(@$keys);
        $self->_flash("remembered in $p") if $p;
    }
    $self->_status();
}

# --------------------------------------------------------------- sessions --

sub new_session {
    my ($self) = @_;
    $self->{agent}->reset;
    $self->{session} = 'untitled';
    $self->_redraw();
    $self->_flash('new session');
    $self->{entry}->focus;
}

sub save_session {
    my ($self) = @_;
    my $name = $self->_ask(title => 'Save session',
        prompt  => 'session name (stored in ' . OldAgent::Desktop::session_dir() . ')',
        default => $self->{session} eq 'untitled' ? 'session' : $self->{session});
    return unless defined $name && length $name;
    $name =~ s{[^A-Za-z0-9_.-]+}{_}g;
    my $path = OldAgent::Desktop::session_dir() . '/' . $name . '.json';
    $self->_run_cmd('save', $path);
    my $n = scalar(@{ $self->{agent}->history() });
    OldAgent::Desktop::remember_session($name, $path, scalar(grep { $_->{role} eq 'user' } @{ $self->{agent}->history() }));
    $self->{session} = $name;
    $self->_rebuild_recent();
    $self->_status();
    $self->_flash('saved ' . $n . ' messages as ' . $path);
}

sub open_session {
    my ($self) = @_;
    my $f = Tk::getOpenFile(-title => 'Open session',
        -filetypes => [['json sessions', '.json'], ['all files', '*']],
        -initialdir => OldAgent::Desktop::session_dir());
    $self->_load_path($f) if $f;
    return;
}

sub _load_path {
    my ($self, $path) = @_;
    return unless $path && length $path;
    $self->_run_cmd('load', $path);
    my ($name) = $path =~ m{([^/\\]+)\.json$};
    $self->{session} = $name || 'session';
    $self->_redraw();
    $self->_status();
    $self->_flash('loaded ' . $path);
}

# ------------------------------------------------------------------ dialog --

# a one-field dialog; returns the text, or undef on cancel
sub _ask {
    my ($self, %o) = @_;
    my $rw  = $self->{root};
    my $ans = undef;
    my $t = eval { $rw->Toplevel(-title => $o{title} || 'oldagent') };
    if (!$t) { $self->_flash("dialog failed: $@"); return undef }

    my $frm = $t->Frame()->pack(-fill => 'both', -expand => 1, -padx => 12, -pady => 10);
    $frm->Label(-text => $o{prompt} || '', -justify => 'left')
        ->pack(-anchor => 'w', -padx => 4, -pady => [4, 6]);
    my $e = $frm->Entry(-width => 48, -relief => 'sunken')
        ->pack(-fill => 'x', -padx => 2, -pady => 6);
    $e->insert(0, $o{default} || '');
    my $bar = $frm->Frame()->pack(-fill => 'x');
    $bar->Button(-text => 'OK', -command => sub {
        $ans = $e->get(); $t->destroy;
    })->pack(-side => 'right', -padx => 4, -pady => 8);
    $bar->Button(-text => 'Cancel', -command => sub { $t->destroy })
        ->pack(-side => 'right', -pady => 8);

    # every exit path destroys $t. this Tk build's waitWindow never
    # wakes up when the window goes away (verified), so pump the event
    # loop ourselves until the dialog is gone - the same loop that makes
    # after() timers and button invokes work.
    my $ret = sub { $ans = $e->get(); $t->destroy; };
    $e->bind('<Return>', $ret);
    $t->bind('<Return>', $ret);
    $e->focus;
    eval { $t->grab_set; 1 };
    while (eval { $t->winfo('exists') }) {
        $rw->update if eval { $rw->winfo('exists') };
        select(0, 0, 0, 0.02);
    }
    return $ans;
}

# a read-only text window
sub _show_text {
    my ($self, $title, $body) = @_;
    my $t = $self->{root}->Toplevel(-title => $title);
    my $tx = $t->Scrolled('Text', -wrap => 'none', -font => 'Courier 10',
        -width => 74, -height => 26, -state => 'disabled')
        ->pack(-fill => 'both', -expand => 1);
    $tx->configure(-state => 'normal');
    $tx->insert('1.0', $body);
    $tx->configure(-state => 'disabled');
    $tx->tag('configure', 'sel', -background => '#c8e0ff');
    $t->Button(-text => 'Close',
        -command => sub { $t->destroy })
        ->pack(-side => 'bottom', -fill => 'x', -pady => 6);
}

sub _show_help {
    my ($self) = @_;
    $self->_show_text('oldagent REPL reference', OldAgent::CLI::_repl_help());
}

# ------------------------------------------------------------------- I/O --

sub _send {
    my ($self) = @_;
    my $text = $self->{entry}->get();
    return unless length $text;
    $self->{entry}->delete(0, 'end');
    return if $self->{busy};

    $self->_append_msg('user', $text);
    $self->{busy} = 1;
    $self->{btn_send}->configure(-state => 'disabled', -text => 'Thinking');
    $self->_status('busy');
    $self->{root}->update;    # paint before the (blocking) model call

    # capture the agent's own prints (tool lines) into the transcript
    my ($reply, $err);
    if (tie(*OA_CAP_2, 'OldAgent::Desktop::_Out', $self->{txt}, 'sys')) {
        my $prev = select(OA_CAP_2);
        ($reply, $err) = $self->{agent}->ask($text);
        select($prev);
    } else {
        ($reply, $err) = $self->{agent}->ask($text);
    }

    $self->{busy} = 0;
    $self->{btn_send}->configure(-state => 'normal', -text => 'Send');

    if ($err) {
        my $txt = $self->{txt};
        $txt->insert('end', "\nagent> ", 'sys');
        $txt->insert('end', "error: $err\n", 'err');
        $txt->see('end');
        $self->{agent}->undo;
    } else {
        $self->_append_msg('assistant', $reply);
    }
    $self->_status();
}

# ---------------------------------------------------------------- render --

sub _append_msg {
    my ($self, $role, $text) = @_;
    my $txt = $self->{txt};
    $txt->insert('end', "\n", 'plain');
    if ($role eq 'user') {
        $txt->insert('end', "you> ", 'userhead');
        $txt->insert('end', $text, 'user');
        $txt->insert('end', "\n", 'plain');
    } else {
        $txt->insert('end', "agent> ", 'sys');
        $self->_render_md($text);
        $txt->insert('end', "\n", 'plain');
    }
    $txt->see('end');
}

sub _render_md {
    my ($self, $text) = @_;
    my $txt = $self->{txt};
    for my $line (OldAgent::Textfmt::tokens($text)) {
        for my $tok (@$line) {
            my ($tags, $str) = @$tok;
            next unless defined $str && length $str;
            $txt->insert('end', $str, @$tags);
        }
        $txt->insert('end', "\n", 'plain');
    }
    $txt->see('end');
}

# repaint the whole transcript from the agent's history
sub _redraw {
    my ($self) = @_;
    my $txt = $self->{txt};
    $txt->delete('1.0', 'end');
    my @h = @{ $self->{agent}->history() };
    if (!@h) {
        my $prov  = $self->{cfg}->get('provider');
        my $model = $self->{cfg}->get('model');
        my $base  = $self->{cfg}->get('base_url');
        $txt->insert('end', "\n", 'plain');
        $self->_render_md(
            "ready: **$prov** / *$model*"
            . ($base ? " at `$base`" : '')
            . "\n\n**Commands** in the menu bar are the `/commands` - same code as the terminal.\n"
            . "Start with a message below, or **File > New session**.\n");
        return;
    }
    for my $m (@h) {
        $self->_append_msg($m->{role}, $m->{content}) if defined $m->{content};
    }
    $self->_status();
}

# ----------------------------------------------------------------- status --

sub _status {
    my ($self, $msg, $mode) = @_;
    $mode = '' unless defined $mode;
    my $cfg = $self->{cfg};
    my $s = 'session ' . $self->{session}
        . '    ' . $cfg->get('provider') . ' -> ' . $cfg->get('model')
        . '    ' . ($cfg->get('base_url') || 'no base url')
        . '    ' . scalar(@{ $self->{agent}->history() }) . ' messages';
    $s .= '    THINKING...' if $mode eq 'busy';
    $s .= '    ' . $msg if defined $msg && length $msg;
    $self->{stat}->configure(-text => $s);
}

sub _flash {
    my ($self, $s) = @_;
    $self->{stat}->configure(-text => $s);
    $self->{root}->after(2500, sub { $self->_status() if !$self->{busy} });
}

sub main_loop {
    my ($self) = @_;
    Tk::MainLoop();
    return 0;
}

1;
