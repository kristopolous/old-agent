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
use OldAgent::Protocol ();
eval { require Errno; 1 } or require Errno;
eval { require OldAgent::CLI; 1 } or require OldAgent::CLI;

# utf8 bytes from the wire are inserted into Tk as decoded characters,
# not as latin-1 bytes (the classic "Whatâs up" mojibake).
sub _decode {
    my ($s) = @_;
    return '' unless defined $s;
    return $s if utf8::is_utf8($s);
    my $u = $s;
    my $ok = eval { no warnings 'utf8'; utf8::decode($u); 1 };
    return $ok ? $u : $s;
}

# ------------------------------------------------------------------ output

# A tied handle: while it is the selected filehandle, every plain
# `print` in the oldagent code lands in the transcript widget instead
# of the terminal.
package OldAgent::Desktop::_Out;
sub TIEHANDLE {
    my ($class, $w, $tag) = @_;
    return bless { w => $w, tag => $tag }, $class;
}
sub _put {
    my ($s, $str) = @_;
    return unless defined $str && length $str;
    $s->{w}->insert('end', $str, $s->{tag});
    $s->{w}->see('end');
}
# print HANDLE 'a', 'b'      -> PRINT, one call per argument (list)
sub PRINT { my ($s, @rest) = @_; $s->_put($_) for @rest; return 1 }
# print HANDLE $scalar       -> WRITE, one call with the scalar
sub WRITE { my ($s, $str) = @_; $s->_put($str); return 1 }
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
    $txt->tag('configure', 'tool',     -font => 'Helvetica 10', -foreground => '#555555');
    $txt->tag('configure', 'userhead', -font => 'Helvetica 10 bold', -foreground => '#8a8a8a');
    $txt->tag('configure', 'sys',      -foreground => '#666666');
    $txt->tag('configure', 'note',     -foreground => '#555555', -font => 'Helvetica 10 italic');
    $txt->tag('configure', 'err',      -foreground => '#b00020');
    $self->{txt} = $txt;

    # ---- input row + status line --------------------------------------
    # this Tk build's pack is broken for widgets inside an intermediate
    # frame (the frame collapses to 1px and its children stop stretching),
    # so everything here is a direct child of the root window, packed in
    # this order: status takes the bottom row, the buttons claim the right
    # of the row above it, and the entry fills the rest of that row.
    my $stat = $rw->Label(-anchor => 'w', -relief => 'sunken',
        -bg => '#eeeeee', -font => 'Helvetica 10', -padx => 8)
        ->pack(-side => 'bottom', -fill => 'x');
    # only Send sits beside the entry: Undo and Clear are conversation
    # commands, not input actions - they live in the Commands menu, next
    # to the other /commands.
    $self->{btn_send} = $rw->Button(-text => 'Send', -default => 'active',
        -command => sub { $self->_send })
        ->pack(-side => 'right', -padx => [2, 10], -pady => 6);
    my $entry = $rw->Entry(-font => 'Helvetica 12', -relief => 'sunken', -bg => '#fffef5')
        ->pack(-side => 'bottom', -fill => 'x', -padx => [8, 4], -pady => 6);
    # in this Tk build the entry's natural height is a few px shorter than
    # the button's, and Entry does not accept -height at all - so measure
    # the gap after the first layout and close it with internal padding,
    # which does change the widget's real height.
    $rw->update;
    my $dh = $self->{btn_send}->winfo('height') - $entry->winfo('height');
    $entry->packConfigure(-ipady => int($dh / 2)) if $dh > 0;
    $entry->bind('<Return>', sub { $self->_send });
    $entry->focus;
    $self->{entry} = $entry;

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

# real prompts for the one-field dialogs; the menu items pass a window
# title, this is what the label inside the dialog says.
my %ARG_PROMPT = (
    model     => 'model name (e.g. gpt-4o-mini)',
    provider  => 'provider name or endpoint URL (openai, ollama, https://host/v1)',
    'base-url'=> 'endpoint URL (e.g. http://localhost:11434/v1)',
    turns     => 'max tool round trips per message (number)',
    system    => 'standing instructions for the model',
    cd        => 'new working directory',
    sh        => 'shell command to run now, outside the conversation',
);

sub _arg_cmd {
    my ($self, $c, $title, $default) = @_;
    $self->_ask(title => $title, prompt => $ARG_PROMPT{$c} || $title,
        default => $default,
        done => sub {
            my ($a) = @_;
            $self->_run_cmd($c, $a);
            my $keys = $PERSIST_KEYS{$c};
            if ($keys) {
                my $p = $self->{cfg}->remember(@$keys);
                $self->_flash("remembered in $p") if $p;
            }
            $self->_status();
        });
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
    $self->_ask(title => 'Save session',
        prompt  => 'session name (stored in ' . OldAgent::Desktop::session_dir() . ')',
        default => $self->{session} eq 'untitled' ? 'session' : $self->{session},
        done => sub {
            my ($name) = @_;
            return unless length $name;
            $name =~ s{[^A-Za-z0-9_.-]+}{_}g;
            my $path = OldAgent::Desktop::session_dir() . '/' . $name . '.json';
            $self->_run_cmd('save', $path);
            my $n = scalar(@{ $self->{agent}->history() });
            OldAgent::Desktop::remember_session($name, $path, scalar(grep { $_->{role} eq 'user' } @{ $self->{agent}->history() }));
            $self->{session} = $name;
            $self->_rebuild_recent();
            $self->_status();
            $self->_flash('saved ' . $n . ' messages as ' . $path);
        });
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

# a one-field dialog. NON-BLOCKING: returns immediately; when the user
# clicks OK (or presses Return), $o{done} is called with the text,
# scheduled one main-loop tick after the window is destroyed. Cancel and
# the window close never call it.
#
# Why no wait: in this Tk build waitWindow and waitVariable never wake up
# (verified: the main loop stays parked forever), and pumping update()
# inline from a menu callback re-enters the event loop and crashes
# ("Modification of a read-only value attempted"). A dialog that parks
# the main loop is a dialog that locks the app - so the app stays in the
# main loop, and the answer rides back through it.
sub _ask {
    my ($self, %o) = @_;
    my $rw   = $self->{root};
    my $done = $o{done} or return;
    my $t = eval { $rw->Toplevel(-title => $o{title} || 'oldagent') };
    if (!$t) { $self->_flash("dialog failed: $@"); return }

    # direct children of the toplevel - same frame-pack quirk as the
    # input row: an intermediate frame would collapse to 1px here too.
    my $lab = $t->Label(-text => $o{prompt} || '', -justify => 'left')
        ->pack(-anchor => 'w', -padx => [12, 4], -pady => [12, 6]);
    my $e = $t->Entry(-width => 44, -relief => 'sunken')
        ->pack(-fill => 'x', -expand => 1, -padx => 12, -pady => 4);
    $e->insert(0, $o{default} || '');
    my $finish = sub {
        my $v = $e->get;
        $v = '' unless defined $v;
        $t->destroy;
        $rw->after(10, sub { $done->($v) });
    };
    $t->Button(-text => 'OK', -command => $finish)
        ->pack(-side => 'right', -padx => [4, 12], -pady => 10);
    $t->Button(-text => 'Cancel', -command => sub { $t->destroy })
        ->pack(-side => 'right', -padx => 4, -pady => 10);
    $e->bind('<Return>', $finish);
    $t->bind('<Return>', $finish);
    $e->focus;
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

    # The model call runs in a SEPARATE PROCESS. This Tk build's main loop
    # is the only thing that can process events; a blocking ask() in it is
    # a frozen window (dead buttons, no repaint). So we fork+exec a fresh
    # perl that rebuilds the agent from the same settings and transcript,
    # answers, and pipes one JSON line back. The parent keeps pumping
    # events the whole time. The message travels by argv, the answer by a
    # single pipe on the child's stdout.
    my ($rd, $wr);
    pipe($rd, $wr) or do {
        my $e = $!;
        $self->{txt}->insert('end', "\nagent> ", 'sys');
        $self->{txt}->insert('end', "error: cannot spawn agent: $e\n", 'err');
        return;
    };

    my $selfpath = __FILE__;
    if ($selfpath !~ m{^/}) {
        my $cwd = (eval { require POSIX; POSIX::getcwd() }) || '';
        $selfpath = $cwd . '/' . $selfpath if $cwd;
    }
    my ($libdir) = $selfpath =~ m{^(.*)[/\\]OldAgent[/\\]Desktop\.pm$}s or do {
        close $rd; close $wr;
        $self->{txt}->insert('end', "error: cannot locate lib dir\n", 'err');
        return;
    };
    my $child = $libdir . '/OldAgent/desktop-child.pl';

    # send the whole current config, not a hand-picked subset: the child
    # rebuilds the agent from this, so a key left out here (api_key,
    # max_tokens, thinking, timeout, ...) silently falls back to its default
    # and the request goes out wrong - e.g. unauthenticated to a proxy.
    my $msg = OldAgent::JSON::encode({
        text       => $text,
        cfg        => $self->{agent}{cfg}->all(),
        max_output => $self->{agent}{cfg}->get('max_output') || 3000,
        history    => [ map { { role => $_->{role}, content => $_->{content} } }
                        @{ $self->{agent}{history} } ],
    });

    my $kid = fork();
    if (!defined $kid) {
        my $e = $!;
        close $rd; close $wr;
        $self->{txt}->insert('end', "\nagent> ", 'sys');
        $self->{txt}->insert('end', "error: cannot fork: $e\n", 'err');
        return;
    }
    if ($kid == 0) {
        # child: its stdout becomes the answer pipe; drop the read end and
        # the parent's write-end copy; exec a clean perl (no Tk, no X).
        open(STDOUT, '>&=', $wr) or exit 9;
        close $rd;
        close $wr;
        exec('perl', $child, $libdir, $msg) or exit 9;
        exit 9;
    }
    close $wr;
    # non-blocking read end: sysread must never hold up the Tk event loop
    if (eval { require Fcntl; 1 }) {
        my $fl = eval { Fcntl::fcntl($rd, Fcntl::F_GETFL(), 0) };
        eval { Fcntl::fcntl($rd, Fcntl::F_SETFL(), $fl | Fcntl::O_NONBLOCK()) } if defined $fl;
    }
    $self->{busy}    = 1;
    $self->{btn_send}->configure(-state => 'disabled', -text => 'Thinking');
    $self->{acc}     = '';
    $self->{ask_rd}  = $rd;
    $self->{ask_kid} = $kid;
    $self->{live}    = 0;      # 1 while a streamed round is on screen
    $self->_status('busy');
    $self->{root}->after(50, sub { $self->_ask_poll() });
}

sub _ask_poll {
    my ($self) = @_;
    my $rd = $self->{ask_rd};
    return unless defined $rd;
    my $n = sysread($rd, my $chunk, 65536);
    if (!defined $n) {
        if ($!{EAGAIN} || $!{EWOULDBLOCK} || $!{EINTR}) {  # no data yet
            $self->{root}->after(50, sub { $self->_ask_poll() });
            return;
        }
        close $rd;
        $self->{ask_rd} = undef;
        $self->_ask_final({ ok => 0, err => 'agent connection lost',
            reply => '', history => [ map { { role => $_->{role}, content => $_->{content} } } @{ $self->{agent}{history} } ] });
        return;
    }
    if ($n == 0) {                            # pipe closed
        close $rd;
        $self->{ask_rd} = undef;
        if (length $self->{acc}) {
            $self->_ask_event($self->{acc});
            $self->{acc} = '';
        }
        $self->_ask_final({ ok => 0, err => 'agent died before finishing',
            reply => '', history => [ map { { role => $_->{role}, content => $_->{content} } } @{ $self->{agent}{history} } ] })
            if !$self->{ask_final_seen};
        return;
    }
    $self->{acc} .= $chunk;
    while ($self->{acc} =~ s/^(.*?\n)//s) {
        $self->_ask_event($1);
    }
    $self->{root}->after(50, sub { $self->_ask_poll() })
        if defined $self->{ask_rd} && !$self->{ask_final_seen};
    return;
}

# one JSON line from the agent child: note / delta / round / final
sub _ask_event {
    my ($self, $line) = @_;
    $line =~ s/\r?\n\z//;
    return unless length $line;
    my ($ev, $err) = eval { OldAgent::JSON::decode($line) };
    if (!$ev || ref($ev) ne 'HASH') {
        # child printed something that is not protocol: show it, keep going
        $self->{txt}->insert('end', $line . "\n", 'err');
        return;
    }
    my $type = $ev->{type} || 'final';        # no type: one-shot legacy line
    if ($type eq 'note') {
        my $t = _decode(defined $ev->{text} ? $ev->{text} : '');
        return unless length $t;
        if ($self->{live}) { $self->_close_live() }    # keep order: round first
        $self->{txt}->insert('end', $t . "\n", 'sys');
        $self->{txt}->see('end');
    }
    elsif ($type eq 'delta') {
        my $t = _decode(defined $ev->{text} ? $ev->{text} : '');
        return unless length $t;
        my $txt = $self->{txt};
        if (!$self->{live}) {
            $self->{live} = 1;
            $self->{live_at} = $txt->index('end-1c');
            $txt->insert('end', "\nagent> ", 'sys');
        }
        $txt->insert('end', $t, 'plain');
        $txt->see('end');
    }
    elsif ($type eq 'round') {
        # the streamed bubble (if any) is raw tokens; replace it with the
        # finished reply rendered as markdown + quiet tool lines
        $self->_close_live() if $self->{live};
        my $t = _decode(defined $ev->{text} ? $ev->{text} : '');
        if (length OldAgent::Util::strip($t)) {
            $self->_append_msg('assistant', $t);
        }
    }
    elsif ($type eq 'final') {
        $self->_ask_final($ev);
    }
}

# delete the raw streamed bubble; the formatted version takes its place
sub _close_live {
    my ($self) = @_;
    my $txt = $self->{txt};
    if (defined $self->{live_at}) {
        eval { $txt->delete($self->{live_at}, 'end-1c'); 1 } or 0;
    }
    $self->{live} = 0;
    $self->{live_at} = undef;
}

sub _ask_final {
    my ($self, $msg) = @_;
    return if $self->{ask_final_seen};
    $self->{ask_final_seen} = 1;
    if (defined $self->{ask_rd}) { close $self->{ask_rd}; $self->{ask_rd} = undef }
    if (defined $self->{ask_kid}) {
        my $w = 1;
        while ($w && ($w = waitpid($self->{ask_kid}, 1)) > 0) {}   # reap
        $self->{ask_kid} = undef;
    }
    $self->_close_live() if $self->{live};
    $self->{busy} = 0;
    $self->{btn_send}->configure(-state => 'normal', -text => 'Send');

    # fold the child's conversation back in (it ran with our history)
    if (ref($msg->{history}) && @{$msg->{history}}) {
        $self->{agent}{history} = [ map { { role => $_->{role}, content => $_->{content} } } @{ $msg->{history} } ];
    }

    if (!$msg->{ok}) {
        # only surface the error if nothing was rendered at all this turn
        if (!defined $self->{rendered_this_turn} || !$self->{rendered_this_turn}) {
            $self->{txt}->insert('end', "\nagent> ", 'sys');
            $self->{txt}->insert('end', "error: " . _decode(defined $msg->{err} ? $msg->{err} : 'unknown') . "\n", 'err');
            $self->{txt}->see('end');
        }
    }
    $self->{rendered_this_turn} = 0;
    $self->_status();
}

# ---------------------------------------------------------------- render --

sub _append_msg {
    my ($self, $role, $text) = @_;
    my $txt = $self->{txt};
    $text = _decode($text);
    if ($role eq 'user') {
        # tool results and nudges are protocol traffic, not things the human
        # typed: give each result a single unobtrusive line instead of the
        # raw JSON, and skip internal nudges entirely.
        if ($text =~ /^```result\b/s) {
            $self->_render_results($text);
            return;
        }
        if ($text =~ /No tool call was emitted, so nothing was executed/) {
            $txt->insert('end', "\n  (kept the model moving - no action yet)\n", 'note');
            return;
        }
        $txt->insert('end', "\n", 'plain');
        $txt->insert('end', "you> ", 'userhead');
        $txt->insert('end', $text, 'user');
        $txt->insert('end', "\n", 'plain');
    } else {
        $txt->insert('end', "\n", 'plain');
        $txt->insert('end', "agent> ", 'sys');
        # the assistant's tool/result fences are protocol, not prose: show
        # the prose as markdown and one quiet line per tool call
        my ($prose, $tools, $results) = OldAgent::Protocol::visible($text);
        if (length OldAgent::Util::strip($prose)) {
            $self->_render_md($prose);
        }
        $self->_render_tools($tools) if length OldAgent::Util::strip($tools);
        $self->_render_results($results) if length OldAgent::Util::strip($results);
    }
    $txt->see('end');
}

# one quiet line per tool call:  [tool] read  path=fruits.txt
sub _render_tools {
    my ($self, $tools) = @_;
    my $txt = $self->{txt};
    for my $t (split(/\n/, $tools)) {
        next unless length $t;
        my ($d, $err) = OldAgent::JSON::decode($t);
        if (!$err && ref($d) eq 'HASH' && defined $d->{tool}) {
            # collapse to one quiet line: [tool] read  path=fruits.txt
            my $name = $d->{tool};
            my $arg  = $d->{args};
            my $brief = '';
            if (ref($arg) eq 'HASH') {
                my @bits;
                for my $k (sort keys %$arg) {
                    my $v = $arg->{$k};
                    next unless defined $v && !ref $v;
                    $v = OldAgent::Util::one_line(OldAgent::Util::strip("$v"));
                    $v = OldAgent::Util::clip($v, 40);
                    push @bits, "$k=$v";
                }
                $brief = '  ' . join(' ', @bits) if @bits;
            }
            my $line = OldAgent::Util::clip("$name$brief", 110);
            $txt->insert('end', '  [tool] ' . _decode($line) . "\n", 'tool');
        } else {
            # not JSON (e.g. an <function=...> summary line): show as-is
            my $line = OldAgent::Util::clip(OldAgent::Util::one_line(OldAgent::Util::strip($t)), 110);
            $txt->insert('end', '  [tool] ' . _decode($line) . "\n", 'tool');
        }
    }
}

# one quiet line per tool result:  [read] ok - 12 bytes
sub _render_results {
    my ($self, $results) = @_;
    my $txt = $self->{txt};
    for my $r (split(/\n/, $results)) {
        next unless length $r;
        my ($d, $err) = OldAgent::JSON::decode($r);
        if (!$err && ref($d) eq 'HASH' && defined $d->{tool}) {
            my $out = defined $d->{output} ? $d->{output} : '';
            my $note = $d->{ok}
                ? 'ok' . (length OldAgent::Util::strip($out) ? ' - ' . OldAgent::Util::clip(OldAgent::Util::one_line(OldAgent::Util::strip($out)), 70) : '')
                : 'failed' . (length $out ? ' - ' . OldAgent::Util::clip(OldAgent::Util::one_line(OldAgent::Util::strip($out)), 70) : '');
            $txt->insert('end', '  [' . $d->{tool} . '] ' . _decode($note) . "\n", 'tool');
            next;
        }
        $txt->insert('end', '  [tool] ' . _decode(OldAgent::Util::clip(OldAgent::Util::one_line(OldAgent::Util::strip($r)), 110)) . "\n", 'tool');
    }
}

sub _render_md {
    my ($self, $text) = @_;
    my $txt = $self->{txt};
    for my $line (OldAgent::Textfmt::tokens(_decode($text))) {
        for my $tok (@$line) {
            my ($tags, $str) = @$tok;
            next unless defined $str && length $str;
            $txt->insert('end', $str, join(',', @$tags));
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
        $txt->insert('end',
            "start: type a message below and press Enter\n", 'note');
        $txt->insert('end',
            "commands: the menu bar above is the /commands - pick from"
            . " Commands (Model, Provider, Base URL, Tools, Approve...), "
            . "or type /help below for the full list.\n", 'note');
        $txt->insert('end',
            "ready: $prov / $model" . ($base ? " at $base" : '') . "\n", 'note');
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
