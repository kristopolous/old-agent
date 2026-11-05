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

# A tied handle: while it is the selected filehandle, every plain `print`
# in the oldagent code lands in the owner's capture buffer instead of the
# terminal. _run_cmd turns the buffer into feed items afterwards.
package OldAgent::Desktop::_Out;
sub TIEHANDLE {
    my ($class, $owner) = @_;
    return bless { owner => $owner }, $class;
}
sub _put {
    my ($s, $str) = @_;
    return unless defined $str && length $str;
    $s->{owner}{capbuf} .= $str;
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
    # Scrolled() would pack an x-scrollbar in as well, but the text wraps
    # (word), so it can never scroll horizontally - build the y-scrollbar
    # by hand and let the text claim everything else.
    my $vsb = $rw->Scrollbar(-bg => '#eeeeee')->pack(-side => 'right', -fill => 'y');
    my $txt = $rw->Text(
        -wrap   => 'word',
        -font   => 'Helvetica 11',
        -bg     => '#ffffff',
        -fg     => '#111111',
        -height => 20,
        -width  => 40,
        -state  => 'normal',
        -yscrollcommand => [$vsb, 'set'],
    )->pack(-side => 'top', -fill => 'both', -expand => 1);
    $vsb->configure(-command => [$txt, 'yview']);

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
    # chat bubbles: user = blue bubble hugging the text, pushed to the
    # right edge with spaces; agent = off-white bubble hugging the text on
    # the left. (a -justify tag would paint its background across the whole
    # display line - a band, not a bubble.) the spacing options pad INSIDE
    # the bubble (spacing1 = top, spacing3 = bottom; spacing2 sits between
    # wrapped lines of one logical line and does nothing for the box
    # bottom). the bubble tags are created AFTER the markdown tags, so
    # markdown backgrounds (code blocks) win over the bubble's.
    $txt->tag('configure', 'userb', -spacing1 => 5, -spacing3 => 5,
        -background => '#4c8bf5', -foreground => '#ffffff');
    $txt->tag('configure', 'agb', -spacing1 => 5, -spacing3 => 5,
        -background => '#f2f1ea');
    $txt->tag('configure', 'tool',     -font => 'Helvetica 10', -foreground => '#777777');
    $txt->tag('configure', 'sys',      -foreground => '#666666');
    $txt->tag('configure', 'note',     -foreground => '#555555', -font => 'Helvetica 10 italic');
    $txt->tag('configure', 'err',      -foreground => '#b00020');
    $self->{txt} = $txt;

    # a resize changes the bubble width: re-render the whole transcript
    # (it is plain text, so this is cheap) and every user bubble re-pads
    # itself for the new width. throttle: one re-render 120ms after the
    # last configure event of a drag.
    # (afterCancel via the widget's method table - this Tk build has no
    # package-level Tk::afterCancel)
    my $pend;
    $txt->bind('<Configure>', sub {
        my ($w) = @_;
        my $wd = $w->winfo('width');
        return if $wd == $self->{last_width} || $self->{rendering};
        $self->{last_width} = $wd;
        $w->afterCancel($pend) if defined $pend;
        $pend = $rw->after(120, sub { $pend = undef; $self->_render_all() });
    });
    $self->{feed}      = [];
    $self->{capbuf}    = '';
    $self->{rendering} = 0;
    $self->{last_width} = 0;

    # ---- input row + status line --------------------------------------
    # this Tk build's pack is broken for widgets inside an intermediate
    # frame (the frame collapses to 1px and its children stop stretching),
    # so everything here is a direct child of the root window, packed in
    # this order: status takes the bottom row, the buttons claim the right
    # of the row above it, and the entry fills the rest of that row.
    my $stat = $rw->Label(-anchor => 'w',
        -bg => '#eeeeee', -fg => '#555555', -font => 'Helvetica 10', -padx => 8)
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
# capturing its output as feed items (rendered as quiet sys lines).
sub _run_cmd {
    my ($self, $c, $rest) = @_;
    $rest = defined $rest ? $rest : '';
    $self->{capbuf} = '';
    unless (tie(*OA_CAP_1, 'OldAgent::Desktop::_Out', $self)) {
        $self->_flash('cannot capture output');
        return;
    }
    my $prev = select(OA_CAP_1);
    my $r = eval { OldAgent::CLI::repl_command($c, $rest,
        agent => $self->{agent}, config => $self->{cfg}, term => undef) };
    select($prev);
    for my $line (split(/\n/, $self->{capbuf} || '')) {
        next unless length $line;
        push @{ $self->{feed} }, ['sys', $line];
    }
    $self->{capbuf} = '';
    push @{ $self->{feed} }, ['err', "error: $@"] if $@;
    $self->_render_all();
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

    push @{ $self->{feed} }, ['user', $text];
    $self->_render_all();

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
        push @{ $self->{feed} }, ['err', "error: cannot spawn agent: $e"];
        $self->_render_all();
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
        push @{ $self->{feed} }, ['err', "error: cannot fork: $e"];
        $self->_render_all();
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

# one JSON line from the agent child: note / delta / round / final.
# everything lands in the feed and the transcript is re-rendered as a
# whole; the live bubble is just a feed item, so a resize mid-stream
# re-pads everything and the stream continues seamlessly.
sub _ask_event {
    my ($self, $line) = @_;
    $line =~ s/\r?\n\z//;
    return unless length $line;
    my ($ev, $err) = eval { OldAgent::JSON::decode($line) };
    if (!$ev || ref($ev) ne 'HASH') {
        # child printed something that is not protocol: show it, keep going
        push @{ $self->{feed} }, ['err', $line];
        $self->_render_all();
        return;
    }
    my $type = $ev->{type} || 'final';        # no type: one-shot legacy line
    if ($type eq 'note') {
        my $t = _decode(defined $ev->{text} ? $ev->{text} : '');
        return unless length $t;
        push @{ $self->{feed} }, ['note', $t];
        $self->_render_all();
    }
    elsif ($type eq 'delta') {
        my $t = _decode(defined $ev->{text} ? $ev->{text} : '');
        return unless length $t;
        my $f = $self->{feed};
        if (@$f && $f->[-1][0] eq 'live') { $f->[-1][1] .= $t }
        else                              { push @$f, ['live', $t] }
        $self->_render_all();
    }
    elsif ($type eq 'round') {
        # the streamed bubble (if any) is raw tokens; swap it in place for
        # the finished reply, which renders as a markdown bubble + tool lines
        my $t = _decode(defined $ev->{text} ? $ev->{text} : '');
        my $f = $self->{feed};
        my $swapped = 0;
        for (my $i = $#$f; $i >= 0 && !$swapped; $i--) {
            if ($f->[$i][0] eq 'live') { $f->[$i] = ['assistant', $t]; $swapped = 1 }
        }
        push @$f, ['assistant', $t] unless $swapped;
        $self->_render_all();
    }
    elsif ($type eq 'final') {
        $self->_ask_final($ev);
    }
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
    $self->{busy} = 0;
    $self->{btn_send}->configure(-state => 'normal', -text => 'Send');

    # fold the child's conversation back in (it ran with our history);
    # the feed is what the child already produced, so it is absorbed too
    if (ref($msg->{history}) && @{$msg->{history}}) {
        $self->{agent}{history} = [ map { { role => $_->{role}, content => $_->{content} } } @{ $msg->{history} } ];
        $self->{feed} = [];
    }

    if (!$msg->{ok}) {
        # only surface the error if no assistant reply made it on screen
        my $rendered = grep { $_->{role} eq 'assistant' } @{ $self->{agent}{history} };
        unless ($rendered) {
            push @{ $self->{feed} },
                ['err', _decode(defined $msg->{err} ? $msg->{err} : 'unknown')];
        }
    }
    $self->_render_all();
    $self->_status();
}

# ---------------------------------------------------------------- render --
# the transcript is a pure function of (history, feed). feed holds what
# has not been folded into the history yet: /command output, notes, the
# in-flight user message, the live streamed bubble. re-rendering the whole
# thing is what keeps the bubbles honest across a resize - every user
# bubble is re-padded for the new width.

sub _render_all {
    my ($self) = @_;
    return if $self->{rendering};
    $self->{rendering} = 1;
    my $txt = $self->{txt};
    $self->{last_width} = $txt->winfo('width');

    # measure every user bubble we are about to draw (in isolation, on
    # line 1) so the right-push is arithmetic, not a live probe. this
    # leaves the transcript empty; the rebuild below fills it back in.
    $self->_ensure_bubble_widths($self->_collect_user_bubble_lines());

    $txt->delete('1.0', 'end');
    my @h = @{ $self->{agent}->history() };
    if (!@h && !@{ $self->{feed} }) {
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
    }
    for my $m (@h) {
        $self->_render_msg($m->{role}, $m->{content}) if defined $m->{content};
    }
    for my $it (@{ $self->{feed} }) {
        $self->_render_item($it);
    }
    $txt->see('end');
    $self->{rendering} = 0;
}

# the bubble line strings currently on screen (history + feed), so the
# measurement pass knows exactly what to measure before the rebuild.
sub _collect_user_bubble_lines {
    my ($self) = @_;
    my @lines;
    for my $m (@{ $self->{agent}->history() }) {
        next unless ($m->{role} || '') eq 'user';
        next unless defined $m->{content};
        my $c = _decode($m->{content});
        next unless $self->_is_user_bubble($c);
        push @lines, $self->_bubble_lines($c);
    }
    for my $it (@{ $self->{feed} }) {
        next unless $it->[0] eq 'user';
        my $c = _decode($it->[1]);
        next unless $self->_is_user_bubble($c);
        push @lines, $self->_bubble_lines($c);
    }
    return @lines;
}

# one feed item: [type, payload]
sub _render_item {
    my ($self, $it) = @_;
    my ($type, $p) = @$it;
    my $txt = $self->{txt};
    if ($type eq 'user' || $type eq 'assistant') {
        $self->_render_msg($type, $p);
    }
    elsif ($type eq 'live') {
        # the raw streamed bubble; the round event re-renders it properly
        my $t = _decode($p);
        $txt->insert('end', $t, 'agb');
        $txt->insert('end', "\n", 'plain');
    }
    elsif ($type eq 'err') {
        $txt->insert('end', _decode($p) . "\n", 'err');
    }
    else {    # note / sys: quiet lines between the bubbles
        $txt->insert('end', _decode($p) . "\n", 'sys');
    }
}

sub _render_msg {
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
            $txt->insert('end', "  (kept the model moving - no action yet)\n", 'note');
            return;
        }
        $self->_render_user_bubble($text);
    } else {
        # the assistant's tool/result fences are protocol, not prose: show
        # the prose as an off-white bubble and one quiet line per tool call
        my ($prose, $tools, $results) = OldAgent::Protocol::visible($text);
        if (length OldAgent::Util::strip($prose)) {
            $self->_render_md($prose, 'agb');
        }
        $self->_render_tools($tools) if length OldAgent::Util::strip($tools);
        $self->_render_results($results) if length OldAgent::Util::strip($results);
    }
}

# a blue bubble hugging the text, pushed to the right edge with spaces.
# the leading spaces are plain (the transcript's white background shows
# through), and only the bubble itself carries the blue tag - so the
# bubble hugs its text instead of painting a band across the line.
# each line pads itself, so even a multi-line message keeps its right edge
# correct; a line wider than the window simply wraps like any other text
sub _render_user_bubble {
    my ($self, $text) = @_;
    my $txt = $self->{txt};
    my $tab = $self->_bubble_table();
    my $cap = defined $tab->{_cap} ? $tab->{_cap} : 0;
    my $sp  = (defined $tab->{_sp} && $tab->{_sp} > 0) ? $tab->{_sp} : 4;
    for my $line (split(/\n/, $text, -1)) {
        my $bubble = ' ' . $line . ' ';
        my $lead   = 0;
        my $e      = $tab->{$bubble};
        if ($e && $e->[1]) {                 # fits one line: push it right
            $lead = int(($cap - $e->[0]) / $sp);
            $lead -= 2;                      # safety margin: a bubble sitting
            $lead = 0 if $lead < 0;          # exactly on the line capacity wraps
        }
        $txt->insert('end', ' ' x $lead);
        # tag the bubble text but NOT the newline: a tag that covers the
        # end-of-line newline paints its background across the whole
        # display line (a band). leaving the newline untagged keeps the
        # bubble hugging its text.
        $txt->insert('end', $bubble, 'userb');
        $txt->insert('end', "\n");
    }
}

# is a user message a bubble (vs a tool result / an internal nudge)?
sub _is_user_bubble {
    my ($self, $text) = @_;
    return 0 if $text =~ /^```result\b/s;
    return 0 if $text =~ /No tool call was emitted, so nothing was executed/;
    return 1;
}

# the bubble line strings a user message renders as (with the one-space
# padding each side the bubble carries), so measurement and render agree
# on exactly what is being measured.
sub _bubble_lines {
    my ($self, $text) = @_;
    return map { ' ' . $_ . ' ' } split(/\n/, $text, -1);
}

# cache of measured bubble widths, keyed by the transcript's pixel width
# (a resize invalidates it) and then by the exact bubble string.
sub _bubble_table {
    my ($self) = @_;
    my $w = $self->{txt}->winfo('width');
    $self->{bub}     = {}  unless defined $self->{bub};
    $self->{bub}{$w} = {}  unless defined $self->{bub}{$w};
    return $self->{bub}{$w};
}

# make sure every bubble line about to be drawn has a cached [width, fits]
# entry. each measurement is done in isolation on line 1 of the transcript
# (always visible, so bbox is valid) and the transcript is wiped back to
# empty afterwards - the caller re-renders the real content next. this is
# the only way that survives this Tk build: probing at 'end' and deleting
# with a computed index both silently fail, leaving thousands of spaces.
sub _ensure_bubble_widths {
    my ($self, @lines) = @_;
    my $tab = $self->_bubble_table();
    $self->_measure_geom($tab)
        unless defined $tab->{_cap} && defined $tab->{_sp};
    my %seen;
    for my $l (@lines) {
        next if $seen{$l}++;
        next if defined $tab->{$l};
        $tab->{$l} = $self->_measure_bubble($l);
    }
}

# one-time (per width) geometry: the pixel width of a full display line
# and the pixel width of a single space, measured with runs of spaces so
# there is no proportional-font guesswork.
sub _measure_geom {
    my ($self, $tab) = @_;
    my $txt = $self->{txt};
    $txt->delete('1.0', 'end');
    # capacity: space-separated tokens so word-wrap CAN break the line.
    # a run of bare spaces is one unbreakable word and never wraps, so the
    # scan would walk off-screen and bbox would clip to a bogus width.
    $txt->insert('end', ('x ' x 200) . "\n");
    $self->{root}->update;
    my @f = eval { $txt->bbox('1.0') };
    if (@f == 4) {
        my $y0  = $f[1];
        my $cap = 0;
        for my $i (1 .. 400) {
            my @b = eval { $txt->bbox('1.' . ($i - 1)) };
            last if @b < 4 || $b[1] != $y0;
            $cap = $b[0] + $b[2];
        }
        $tab->{_cap} = $cap;
    }
    $txt->delete('1.0', 'end');
    $txt->insert('end', (' ' x 40) . "\n");
    $self->{root}->update;
    my @sf = eval { $txt->bbox('1.0') };
    my @sl = eval { $txt->bbox('1.39') };
    $tab->{_sp} = (@sf == 4 && @sl == 4)
        ? (($sl[0] + $sl[2] - $sf[0]) / 40) : 4;
    $txt->delete('1.0', 'end');
}

# measure one bubble on line 1: its pixel width and whether it fits on a
# single display line (first and last char share a y0). a bubble wider
# than the line fits=0 and gets no right push (it wraps like normal text).
sub _measure_bubble {
    my ($self, $l) = @_;
    my $txt = $self->{txt};
    $txt->delete('1.0', 'end');
    $txt->insert('end', $l . "\n");
    $self->{root}->update;
    my $n  = length $l;
    my @f  = eval { $txt->bbox('1.0') };
    my @la = eval { $txt->bbox('1.' . ($n - 1)) };
    my $w  = (@f == 4 && @la == 4) ? ($la[0] + $la[2] - $f[0]) : 0;
    my $ok = (@f == 4 && @la == 4) ? ($f[1] == $la[1] ? 1 : 0) : 0;
    $txt->delete('1.0', 'end');
    return [$w, $ok];
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
    my ($self, $text, $bubble) = @_;
    my $txt = $self->{txt};
    # a bubble tag only paints the cells it owns, so the bubble hugs the
    # text by construction. the padding spaces (first and last cell of
    # every line) carry the bubble tag too, which keeps the text off the
    # bubble's edges and gives short last lines a padded right side
    for my $line (OldAgent::Textfmt::tokens(_decode($text))) {
        if ($bubble) { $txt->insert('end', ' ', $bubble) }
        for my $tok (@$line) {
            my ($tags, $str) = @$tok;
            next unless defined $str && length $str;
            $txt->insert('end', $str, join(',', @$tags));
        }
        # the trailing padding space carries the bubble tag, but the
        # newline is left untagged so the bubble hugs its text instead of
        # painting a band to the right edge (a tag over the newline fills
        # the whole display line in Tk).
        if ($bubble) { $txt->insert('end', ' ', $bubble); $txt->insert('end', "\n") }
        else         { $txt->insert('end', "\n", 'plain') }
    }
    $txt->see('end');
}

# repaint the whole transcript (new session, undo, load, clear)
sub _redraw {
    my ($self) = @_;
    $self->{feed}   = [];
    $self->{capbuf} = '';
    $self->_render_all();
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
